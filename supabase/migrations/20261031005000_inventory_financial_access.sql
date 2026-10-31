BEGIN;
SET LOCAL lock_timeout='5s';

-- Reviewed definitions and permissive policies must not drift silently.
DO $guard$
DECLARE v record;
BEGIN
 FOR v IN SELECT * FROM (VALUES
  ('vm_materials_read','899250db72c2e4866e6e026f997043be'),
  ('vm_stock_movements_read','7e120116abd276a8bf137c19612fa5a8'),
  ('vm_suppliers_read','e9857dd5cd466aca37c2adcaa237ffec'),
  ('vm_products_read','905890d5ea734a9d89dbc6d3cb595ec9'),
  ('vm_order_consumptions_read','d6f0b5f63cb9039489ac98dd23df6db6'),
  ('vm_order_returns_read','d9a2fab971389463bd6a0dc5c84f2c04')
 ) AS views(name,hash) LOOP
  IF pg_catalog.md5(pg_catalog.pg_get_viewdef(pg_catalog.to_regclass('public.'||v.name),true))<>v.hash
    OR NOT EXISTS(SELECT 1 FROM pg_catalog.pg_class WHERE oid=pg_catalog.to_regclass('public.'||v.name) AND reloptions @> ARRAY['security_invoker=true']) THEN
   RAISE EXCEPTION 'Reviewed inventory-dependent view % differs',v.name;
  END IF;
 END LOOP;
 IF pg_catalog.md5(pg_catalog.pg_get_functiondef('public.vm_receive_material(uuid,uuid,numeric,numeric,numeric,text,uuid)'::regprocedure))<>'78e6832bc9cf959c230de8a915e6ede9' THEN
  RAISE EXCEPTION 'Reviewed receive RPC differs';
 END IF;
 FOR v IN SELECT * FROM (VALUES
  ('vm_materials','vm_materials_member_select','c281e310f908450cfeef2683462e89a2'),
  ('vm_stock_movements','vm_stock_movements_member_select','9261ef7667c7d0b9dc705f3d2af91dc3')
 ) AS policies(name,policy,hash) LOOP
  IF (SELECT count(*) FROM pg_catalog.pg_policy WHERE polrelid=pg_catalog.to_regclass('public.'||v.name) AND polcmd IN ('r','*'))<>1
   OR NOT EXISTS(SELECT 1 FROM pg_catalog.pg_policy WHERE polrelid=pg_catalog.to_regclass('public.'||v.name) AND polname=v.policy AND polcmd='r'
    AND polpermissive AND polroles=ARRAY[(SELECT oid FROM pg_catalog.pg_roles WHERE rolname='authenticated')]
    AND pg_catalog.md5(pg_catalog.pg_get_expr(polqual,polrelid))=v.hash) THEN
   RAISE EXCEPTION 'Unexpected inventory policies on %',v.name;
  END IF;
 END LOOP;
 IF EXISTS(SELECT 1 FROM pg_catalog.pg_class c WHERE c.oid IN ('public.vm_materials'::regclass,'public.vm_stock_movements'::regclass)
    AND (NOT c.relrowsecurity OR c.relforcerowsecurity))
   OR EXISTS(SELECT 1 FROM pg_catalog.pg_class c WHERE c.oid IN ('public.vm_materials'::regclass,'public.vm_stock_movements'::regclass,
    'public.vm_materials_read'::regclass,'public.vm_stock_movements_read'::regclass)
    AND c.relowner<>(SELECT relowner FROM pg_catalog.pg_class WHERE oid='public.vm_materials'::regclass))
   OR pg_catalog.has_table_privilege('anon','public.vm_materials_read','SELECT')
   OR pg_catalog.has_table_privilege('anon','public.vm_stock_movements_read','SELECT') THEN
  RAISE EXCEPTION 'Unexpected inventory ownership, RLS, or privileges';
 END IF;
END;
$guard$;

-- The existing receipt changes and returns costs. Finance can perform it;
-- production must no longer be able to invoke it even by bypassing the UI.
DO $patch$
DECLARE definition text; old_text text := $old$ARRAY['owner','admin','production']::text[]$old$;
BEGIN
 definition:=pg_catalog.pg_get_functiondef('public.vm_receive_material(uuid,uuid,numeric,numeric,numeric,text,uuid)'::regprocedure);
 IF (length(definition)-length(replace(definition,old_text,'')))/length(old_text)<>1 THEN RAISE EXCEPTION 'Unexpected receipt role guard'; END IF;
 EXECUTE replace(definition,old_text,$new$ARRAY['owner','admin','finance']::text[]$new$);
END;
$patch$;

ALTER POLICY vm_materials_member_select ON public.vm_materials
 USING ((SELECT vm_private.vm_has_role(organization_id,ARRAY['owner','admin','finance']::text[])));
ALTER POLICY vm_stock_movements_member_select ON public.vm_stock_movements
 USING ((SELECT vm_private.vm_has_role(organization_id,ARRAY['owner','admin','finance']::text[])));

-- Deliberate barrier/definer projections: check tenant explicitly, since the
-- owner bypasses RLS, and return NULL rather than manufacturing zero cost.
CREATE OR REPLACE VIEW public.vm_materials_read WITH(security_invoker=false,security_barrier=true) AS
SELECT m.id,m.organization_id,m.name,m.category,m.unit,
 CASE WHEN (current_user='service_role' AND auth.role()='service_role') OR vm_private.vm_has_role(m.organization_id,ARRAY['owner','admin','finance']::text[]) THEN m.package_cost::text END AS package_cost,
 m.package_quantity::text AS package_quantity,
 CASE WHEN (current_user='service_role' AND auth.role()='service_role') OR vm_private.vm_has_role(m.organization_id,ARRAY['owner','admin','finance']::text[]) THEN m.unit_cost_precise::text END AS unit_cost,
 m.stock_quantity::text AS stock_quantity,m.reorder_level::text AS reorder_level,(m.stock_quantity<=m.reorder_level) AS is_low_stock,
 m.supplier_id,m.created_at,m.updated_at
FROM public.vm_materials m
WHERE (current_user='service_role' AND auth.role()='service_role') OR (auth.role()='authenticated' AND (SELECT vm_private.vm_is_member(m.organization_id)));

CREATE OR REPLACE VIEW public.vm_stock_movements_read WITH(security_invoker=false,security_barrier=true) AS
SELECT sm.id,sm.organization_id,sm.material_id,sm.movement_type,sm.quantity_delta::text AS quantity_delta,sm.stock_after::text AS stock_after,
 CASE WHEN (current_user='service_role' AND auth.role()='service_role') OR vm_private.vm_has_role(sm.organization_id,ARRAY['owner','admin','finance']::text[]) THEN sm.package_cost::text END AS package_cost,
 sm.package_quantity::text AS package_quantity,sm.note,sm.purchase_id,sm.idempotency_key,sm.created_by,sm.created_at,sm.order_id,sm.return_line_id
FROM public.vm_stock_movements sm
WHERE (current_user='service_role' AND auth.role()='service_role') OR (auth.role()='authenticated' AND (SELECT vm_private.vm_is_member(sm.organization_id)));

CREATE OR REPLACE VIEW public.vm_order_consumptions_read WITH(security_invoker=true) AS
SELECT c.organization_id,c.order_id,c.material_id,c.unit,c.quantity::text AS quantity,c.movement_id,m.stock_after,c.created_at
FROM public.vm_order_consumptions c JOIN public.vm_stock_movements_read m ON m.organization_id=c.organization_id AND m.id=c.movement_id;

CREATE OR REPLACE VIEW public.vm_order_returns_read WITH(security_invoker=true) AS
SELECT e.id AS return_id,e.organization_id,e.order_id,e.status,e.reason,e.idempotency_key,e.line_count::text AS return_line_count,
 e.returned_quantity::text AS event_returned_quantity,e.created_by,e.created_at,l.id AS return_line_id,l.material_id,
 l.material_name_snapshot AS material_name,l.unit,c.quantity::text AS original_consumed_quantity,l.quantity::text AS returned_quantity,
 (SELECT COALESCE(sum(l2.quantity),0)::numeric(48,36)::text FROM public.vm_order_return_lines l2
   WHERE l2.organization_id=l.organization_id AND l2.order_id=l.order_id AND l2.material_id=l.material_id) AS returned_quantity_total,
 (c.quantity-(SELECT COALESCE(sum(l2.quantity),0) FROM public.vm_order_return_lines l2
   WHERE l2.organization_id=l.organization_id AND l2.order_id=l.order_id AND l2.material_id=l.material_id))::numeric(48,36)::text AS remaining_quantity,
 l.stock_movement_id,sm.stock_after,m.stock_quantity AS current_stock_quantity,l.created_by AS line_created_by,l.created_at AS line_created_at
FROM public.vm_order_return_events e JOIN public.vm_order_return_lines l ON l.organization_id=e.organization_id AND l.return_event_id=e.id
JOIN public.vm_order_consumptions c ON c.organization_id=l.organization_id AND c.order_id=l.order_id AND c.material_id=l.material_id AND c.movement_id=l.source_consumption_movement_id
JOIN public.vm_stock_movements_read sm ON sm.organization_id=l.organization_id AND sm.id=l.stock_movement_id
JOIN public.vm_materials_read m ON m.organization_id=l.organization_id AND m.id=l.material_id;

CREATE OR REPLACE VIEW public.vm_suppliers_read WITH(security_invoker=true) AS
SELECT s.id,s.organization_id,s.name,s.email,s.phone,s.notes,s.person_type,s.tax_id,s.address,s.website,s.archived_at,s.created_at,s.updated_at,
 count(m.id)::text AS material_count,
 CASE WHEN (current_user='service_role' AND auth.role()='service_role') OR vm_private.vm_has_role(s.organization_id,ARRAY['owner','admin','finance']::text[])
  THEN COALESCE((sum(m.stock_quantity::numeric*m.unit_cost::numeric))::numeric(84,60)::text,'0') END AS current_stock_cost,
 COALESCE((SELECT pg_catalog.jsonb_object_agg(unit_totals.unit,unit_totals.quantity::text)
  FROM (SELECT m2.unit,sum(m2.stock_quantity::numeric)::numeric(48,36) AS quantity FROM public.vm_materials_read m2
   WHERE m2.organization_id=s.organization_id AND m2.supplier_id=s.id GROUP BY m2.unit) unit_totals)::text,'{}') AS stocks_by_unit
FROM public.vm_suppliers s LEFT JOIN public.vm_materials_read m ON m.organization_id=s.organization_id AND m.supplier_id=s.id
GROUP BY s.id,s.organization_id,s.name,s.email,s.phone,s.notes,s.person_type,s.tax_id,s.address,s.website,s.archived_at,s.created_at,s.updated_at;

CREATE OR REPLACE VIEW public.vm_products_read WITH(security_invoker=true) AS
SELECT p.id,p.organization_id,p.name,p.category,p.categories,p.subcategory,p.description,p.material_info,p.personalization_info,
 p.production_days::text AS production_days,p.pricing_mode,p.price::text AS price,p.promo_price::text AS promo_price,
 p.minimum_quantity::text AS minimum_quantity,p.billing_unit,p.is_catalog_visible,p.is_featured,p.custom_questions,
 p.weight_kg::text AS weight_kg,p.width_cm::text AS width_cm,p.height_cm::text AS height_cm,p.depth_cm::text AS depth_cm,
 p.sku,p.barcode,p.wholesale_tiers,p.current_version::text AS current_version,v.composition_cost::text AS current_composition_cost,
 CASE WHEN (current_user='service_role' AND auth.role()='service_role') OR vm_private.vm_has_role(p.organization_id,ARRAY['owner','admin','finance']::text[])
  THEN (SELECT COALESCE(sum(c.quantity*m.unit_cost::numeric),0)::numeric(44,32)::text
  FROM public.vm_product_components c JOIN public.vm_materials_read m ON m.organization_id=c.organization_id AND m.id=c.material_id
  WHERE c.organization_id=p.organization_id AND c.product_id=p.id AND c.product_version=p.current_version) END AS current_material_cost,
 p.created_at,p.updated_at,p.inventory_mode
FROM public.vm_products p LEFT JOIN public.vm_product_versions v ON v.organization_id=p.organization_id AND v.product_id=p.id AND v.product_version=p.current_version;

INSERT INTO public.vm_schema_migrations(version,description)
VALUES('20261031005000_inventory_financial_access','Protege custos de estoque e restringe recebimento financeiro') ON CONFLICT(version) DO NOTHING;
NOTIFY pgrst,'reload schema';
COMMIT;
