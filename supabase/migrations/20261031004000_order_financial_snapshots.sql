BEGIN;
SET LOCAL lock_timeout='5s';

-- A definer view is intentionally used only for this sanitized projection.
-- It must explicitly enforce membership because its owner bypasses base RLS.
-- The security barrier prevents caller predicates from observing private input
-- values before the CASE projections have been applied. The privileged
-- service_role keeps its existing machine-to-machine read access; merely
-- spoofing a service_role claim under authenticated never activates it.
DO $guard$
DECLARE expected record;
BEGIN
  FOR expected IN SELECT * FROM (VALUES
    ('vm_orders_read','fb7c512f04028bf52c9a8f9921bfd5df'),
    ('vm_order_items_read','10fba6a96c549e51e7112d81f39932fb'),
    ('vm_clients_read','49d5031614fd858f811ef468e20005da')
  ) AS views(view_name,definition_md5) LOOP
    IF pg_catalog.md5(pg_catalog.pg_get_viewdef(pg_catalog.to_regclass('public.'||expected.view_name),true))<>expected.definition_md5
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class WHERE oid=pg_catalog.to_regclass('public.'||expected.view_name)
         AND reloptions @> ARRAY['security_invoker=true']) THEN
      RAISE EXCEPTION 'Reviewed view % differs',expected.view_name;
    END IF;
  END LOOP;
  -- Definer projections rely on the reviewed common owner and original grants;
  -- fail closed if a schema owner, RLS flag or anonymous privilege drifted.
  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_class c WHERE c.oid IN (
      'public.vm_orders'::regclass,'public.vm_order_items'::regclass,'public.vm_order_item_materials'::regclass,
      'public.vm_clients'::regclass,'public.vm_order_payments'::regclass,'public.vm_orders_read'::regclass,'public.vm_order_items_read'::regclass)
      AND c.relowner<>(SELECT relowner FROM pg_catalog.pg_class WHERE oid='public.vm_orders'::regclass)
  ) OR EXISTS (
    SELECT 1 FROM pg_catalog.pg_class c WHERE c.oid IN ('public.vm_orders'::regclass,'public.vm_order_items'::regclass,'public.vm_order_item_materials'::regclass)
      AND (NOT c.relrowsecurity OR c.relforcerowsecurity)
  ) OR pg_catalog.has_table_privilege('anon','public.vm_orders_read','SELECT')
    OR pg_catalog.has_table_privilege('anon','public.vm_order_items_read','SELECT') THEN
    RAISE EXCEPTION 'Unexpected order ownership, RLS or view privileges';
  END IF;
  FOR expected IN SELECT * FROM (VALUES
    ('vm_orders','e1e59c9edd201d3cd494522e2819673e'),
    ('vm_order_items','973f007d42561dae055f75829b098bbb'),
    ('vm_order_item_materials','7aa917d64efbbe0a9ab842e1282a52c9')
  ) AS policies(table_name,qual_md5) LOOP
    IF (SELECT count(*) FROM pg_catalog.pg_policy WHERE polrelid=pg_catalog.to_regclass('public.'||expected.table_name) AND polcmd IN ('r','*'))<>1
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_policy WHERE polrelid=pg_catalog.to_regclass('public.'||expected.table_name)
         AND polname='vm_orders_member_select' AND polcmd='r' AND polpermissive
         AND polroles=ARRAY[(SELECT oid FROM pg_catalog.pg_roles WHERE rolname='authenticated')]
         AND pg_catalog.md5(pg_catalog.pg_get_expr(polqual,polrelid))=expected.qual_md5) THEN
      RAISE EXCEPTION 'Unexpected order read policies on %',expected.table_name;
    END IF;
  END LOOP;
END;
$guard$;

-- Hosted Supabase may grant service_role access to the existing views.
-- It already bypasses RLS, but must be able to evaluate these two predicates.
-- Some isolated Postgres installations do not define that platform role.
DO $service$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='service_role') THEN
    GRANT USAGE ON SCHEMA vm_private TO service_role;
    GRANT EXECUTE ON FUNCTION vm_private.vm_is_member(uuid),vm_private.vm_has_role(uuid,text[]) TO service_role;
  END IF;
END;
$service$;

-- Direct rows contain prices and costs; they remain available to financial
-- roles only. Operational users receive tenant-filtered projections below.
ALTER POLICY vm_orders_member_select ON public.vm_orders
  USING ((SELECT vm_private.vm_has_role(organization_id,ARRAY['owner','admin','finance']::text[])));
ALTER POLICY vm_orders_member_select ON public.vm_order_items
  USING ((SELECT vm_private.vm_has_role(organization_id,ARRAY['owner','admin','finance']::text[])));
ALTER POLICY vm_orders_member_select ON public.vm_order_item_materials
  USING ((SELECT vm_private.vm_has_role(organization_id,ARRAY['owner','admin','finance']::text[])));

CREATE OR REPLACE VIEW public.vm_orders_read WITH (security_invoker=false,security_barrier=true) AS
SELECT o.id,o.organization_id,o.code,o.client_id,c.name AS client_name,o.client_name_snapshot,o.title,
  o.status,o.status_version::text AS status_version,o.order_date,o.production_date,o.delivery_date,
  o.responsible_membership_id,o.public_notes,o.internal_notes,
  CASE WHEN CASE WHEN current_user='service_role' AND auth.role()='service_role' THEN true ELSE vm_private.vm_has_role(o.organization_id,ARRAY['owner','admin','finance']::text[]) END THEN o.subtotal::text END AS subtotal,
  CASE WHEN CASE WHEN current_user='service_role' AND auth.role()='service_role' THEN true ELSE vm_private.vm_has_role(o.organization_id,ARRAY['owner','admin','finance']::text[]) END THEN o.discount_type END AS discount_type,
  CASE WHEN CASE WHEN current_user='service_role' AND auth.role()='service_role' THEN true ELSE vm_private.vm_has_role(o.organization_id,ARRAY['owner','admin','finance']::text[]) END THEN o.discount_value::text END AS discount_value,
  CASE WHEN CASE WHEN current_user='service_role' AND auth.role()='service_role' THEN true ELSE vm_private.vm_has_role(o.organization_id,ARRAY['owner','admin','finance']::text[]) END THEN o.discount_amount::text END AS discount_amount,
  CASE WHEN CASE WHEN current_user='service_role' AND auth.role()='service_role' THEN true ELSE vm_private.vm_has_role(o.organization_id,ARRAY['owner','admin','finance']::text[]) END THEN o.shipping_amount::text END AS shipping_amount,
  CASE WHEN CASE WHEN current_user='service_role' AND auth.role()='service_role' THEN true ELSE vm_private.vm_has_role(o.organization_id,ARRAY['owner','admin','finance']::text[]) END THEN o.total_amount::text END AS total_amount,
  CASE WHEN CASE WHEN current_user='service_role' AND auth.role()='service_role' THEN true ELSE vm_private.vm_has_role(o.organization_id,ARRAY['owner','admin','finance']::text[]) END THEN COALESCE(p.paid_amount,0)::numeric(20,2)::text END AS paid_amount,
  CASE WHEN CASE WHEN current_user='service_role' AND auth.role()='service_role' THEN true ELSE vm_private.vm_has_role(o.organization_id,ARRAY['owner','admin','finance']::text[]) END THEN (o.total_amount-COALESCE(p.paid_amount,0))::numeric(20,2)::text END AS balance_amount,
  o.currency,(o.consumed_at IS NOT NULL) AS inventory_deducted,o.consumed_at,
  (SELECT count(*)::text FROM public.vm_order_items i WHERE i.organization_id=o.organization_id AND i.order_id=o.id) AS item_count,
  o.created_by,o.created_at,o.updated_at
FROM public.vm_orders o
JOIN public.vm_clients c ON c.organization_id=o.organization_id AND c.id=o.client_id
LEFT JOIN LATERAL (SELECT sum(pay.amount) AS paid_amount FROM public.vm_order_payments pay
  WHERE pay.organization_id=o.organization_id AND pay.order_id=o.id) p ON true
WHERE CASE WHEN current_user='service_role' AND auth.role()='service_role' THEN true
  WHEN auth.role()='authenticated' THEN (SELECT vm_private.vm_is_member(o.organization_id)) ELSE false END;

CREATE OR REPLACE VIEW public.vm_order_items_read WITH (security_invoker=false,security_barrier=true) AS
SELECT i.id,i.organization_id,i.order_id,i.position::text AS position,i.kind,i.product_id,i.product_version::text AS product_version,
  i.variant_id,i.variant_version::text AS variant_version,i.title,i.quantity::text AS quantity,i.billing_unit,i.dimensions,
  i.dimensions_factor::text AS dimensions_factor,i.billed_quantity::text AS billed_quantity,
  CASE WHEN CASE WHEN current_user='service_role' AND auth.role()='service_role' THEN true ELSE vm_private.vm_has_role(i.organization_id,ARRAY['owner','admin','finance']::text[]) END THEN i.unit_price::text END AS unit_price,
  CASE WHEN CASE WHEN current_user='service_role' AND auth.role()='service_role' THEN true ELSE vm_private.vm_has_role(i.organization_id,ARRAY['owner','admin','finance']::text[]) END THEN i.price_source END AS price_source,
  CASE WHEN CASE WHEN current_user='service_role' AND auth.role()='service_role' THEN true ELSE vm_private.vm_has_role(i.organization_id,ARRAY['owner','admin','finance']::text[]) END THEN i.price_override_reason END AS price_override_reason,
  CASE WHEN CASE WHEN current_user='service_role' AND auth.role()='service_role' THEN true ELSE vm_private.vm_has_role(i.organization_id,ARRAY['owner','admin','finance']::text[]) END THEN i.line_amount_raw::text END AS line_amount_raw,
  CASE WHEN CASE WHEN current_user='service_role' AND auth.role()='service_role' THEN true ELSE vm_private.vm_has_role(i.organization_id,ARRAY['owner','admin','finance']::text[]) END THEN i.line_amount::text END AS line_amount,
  i.recipe_mode,
  CASE WHEN CASE WHEN current_user='service_role' AND auth.role()='service_role' THEN true ELSE vm_private.vm_has_role(i.organization_id,ARRAY['owner','admin','finance']::text[]) END THEN i.unit_composition_cost::text END AS unit_composition_cost,
  CASE WHEN CASE WHEN current_user='service_role' AND auth.role()='service_role' THEN true ELSE vm_private.vm_has_role(i.organization_id,ARRAY['owner','admin','finance']::text[]) END THEN i.total_composition_cost::text END AS total_composition_cost,
  CASE WHEN CASE WHEN current_user='service_role' AND auth.role()='service_role' THEN true ELSE vm_private.vm_has_role(i.organization_id,ARRAY['owner','admin','finance']::text[]) END THEN i.product_snapshot
       ELSE jsonb_build_object('product_id',i.product_snapshot->'product_id','product_version',i.product_snapshot->'product_version',
         'name',i.product_snapshot->'name','category',i.product_snapshot->'category','sku',i.product_snapshot->'sku',
         'billing_unit',i.product_snapshot->'billing_unit','production_days',i.product_snapshot->'production_days',
         'variant_id',i.product_snapshot->'variant_id','variant_version',i.product_snapshot->'variant_version',
         'variant_name',i.product_snapshot->'variant_name','variant_sku',i.product_snapshot->'variant_sku',
         'recipe_mode',i.product_snapshot->'recipe_mode','inventory_mode',i.product_snapshot->'inventory_mode') END AS product_snapshot,
  CASE WHEN CASE WHEN current_user='service_role' AND auth.role()='service_role' THEN true ELSE vm_private.vm_has_role(i.organization_id,ARRAY['owner','admin','finance']::text[]) END THEN i.price_snapshot END AS price_snapshot,
  COALESCE((SELECT jsonb_agg(jsonb_build_object('material_id',s.material_id,'material_name',s.material_name_snapshot,
    'quantitySnapshot',s.quantity_snapshot::text,'unit',s.unit,'consumption_quantity',s.consumption_quantity::text)
    || CASE WHEN CASE WHEN current_user='service_role' AND auth.role()='service_role' THEN true ELSE vm_private.vm_has_role(i.organization_id,ARRAY['owner','admin','finance']::text[]) END THEN
      jsonb_build_object('unit_cost_snapshot',s.unit_cost_snapshot::text,'consumption_cost',s.consumption_cost::text) ELSE '{}'::jsonb END
    ORDER BY s.material_id)
    FROM public.vm_order_item_materials s WHERE s.organization_id=i.organization_id AND s.order_id=i.order_id AND s.item_id=i.id),'[]'::jsonb) AS recipe_snapshot,
  i.details,i.personalization,i.production_date,i.delivery_date,i.created_at
FROM public.vm_order_items i
WHERE CASE WHEN current_user='service_role' AND auth.role()='service_role' THEN true
  WHEN auth.role()='authenticated' THEN (SELECT vm_private.vm_is_member(i.organization_id)) ELSE false END;

-- Counts must remain operational when raw order rows are restricted.
CREATE OR REPLACE VIEW public.vm_clients_read WITH(security_invoker=true) AS
SELECT c.id,c.organization_id,c.name,c.email,c.phone,c.notes,c.person_type,c.tax_id,c.birth_date,c.address,c.archived_at,c.created_at,c.updated_at,
  (SELECT count(*)::text FROM public.vm_orders_read o WHERE o.organization_id=c.organization_id AND o.client_id=c.id) AS order_count,
  (SELECT count(*)::text FROM public.vm_orders_read o WHERE o.organization_id=c.organization_id AND o.client_id=c.id AND o.status IN ('Pendente','Em Produção','Concluído')) AS open_order_count
FROM public.vm_clients c;

INSERT INTO public.vm_schema_migrations(version,description)
VALUES('20261031004000_order_financial_snapshots','Protege valores e snapshots financeiros de pedidos') ON CONFLICT(version) DO NOTHING;
NOTIFY pgrst,'reload schema';
COMMIT;
