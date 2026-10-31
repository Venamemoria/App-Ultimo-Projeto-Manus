BEGIN;
SET LOCAL lock_timeout = '5s';

-- Preserve legacy eight-place fields for existing integrations and historical
-- snapshots. The new computed unit cost rounds a division to 24 places; all
-- subsequent multiplication is exact until the money boundary.
CREATE TEMP TABLE vm_cost_views ON COMMIT DROP AS
SELECT c.relname AS name,pg_get_viewdef(c.oid,true) AS definition,
       c.reloptions,c.relacl,pg_get_userbyid(c.relowner) AS owner_name,
       obj_description(c.oid,'pg_class') AS comment
FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public' AND c.relkind='v' AND c.relname=ANY(ARRAY[
 'vm_materials_read','vm_material_purchases_read','vm_suppliers_read','vm_products_read',
 'vm_product_components_read','vm_product_versions_read','vm_order_items_read'
]);
DO $guard$
BEGIN
 IF (SELECT count(*) FROM vm_cost_views)<>7 OR EXISTS(SELECT 1 FROM vm_cost_views
    WHERE reloptions IS DISTINCT FROM ARRAY['security_invoker=true']::text[] OR owner_name<>current_user) THEN
   RAISE EXCEPTION 'Unexpected view definitions or ownership; review unit-cost migration';
 END IF;
END;
$guard$;
DROP VIEW public.vm_materials_read,public.vm_material_purchases_read,public.vm_suppliers_read,
 public.vm_products_read,public.vm_product_components_read,public.vm_product_versions_read,public.vm_order_items_read;

ALTER TABLE public.vm_materials ADD COLUMN unit_cost_precise numeric(36,24)
 GENERATED ALWAYS AS (((package_cost * 1.000000000000000000000000000000::numeric) / package_quantity)::numeric(36,24)) STORED;
ALTER TABLE public.vm_material_purchases ADD COLUMN unit_cost_precise numeric(36,24)
 GENERATED ALWAYS AS (((total_amount * 1.000000000000000000000000000000::numeric) / quantity_acquired)::numeric(36,24)) STORED;

-- Existing recipes retain their saved eight-place costs and previously rounded
-- line values. New recipe versions snapshot 24-place material unit costs and
-- preserve the complete 32-place quantity × cost product.
DO $product_costs$
DECLARE t text;
BEGIN
 FOREACH t IN ARRAY ARRAY['vm_product_components','vm_product_variant_components'] LOOP
   EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT %I, DROP CONSTRAINT %I, DROP COLUMN line_cost',
     t,t||'_unit_cost_valid_ck',t||'_line_cost_valid_ck');
   EXECUTE format('ALTER TABLE public.%I ALTER COLUMN unit_cost_snapshot TYPE numeric(36,24),
     ADD COLUMN cost_precision_version smallint NOT NULL DEFAULT 0 CHECK (cost_precision_version IN (0,1)),
     ADD COLUMN line_cost numeric(20,8) GENERATED ALWAYS AS ((quantity * unit_cost_snapshot)::numeric(20,8)) STORED,
     ADD COLUMN line_cost_precise numeric(44,32) GENERATED ALWAYS AS
       ((CASE WHEN cost_precision_version=0 THEN ((quantity * unit_cost_snapshot)::numeric(20,8)) ELSE quantity * unit_cost_snapshot END)::numeric(44,32)) STORED,
     ADD CONSTRAINT %I CHECK (vm_private.vm_numeric_valid(unit_cost_snapshot,24,999999999999.99999999,true)),
     ADD CONSTRAINT %I CHECK (vm_private.vm_numeric_valid(line_cost,8,999999999999.99999999,true)),
     ADD CONSTRAINT %I CHECK (vm_private.vm_numeric_valid(line_cost_precise,32,999999999999.99999999,true))',
     t,t||'_unit_cost_valid_ck',t||'_line_cost_valid_ck',t||'_line_cost_precise_valid_ck');
   EXECUTE format('ALTER TABLE public.%I ALTER COLUMN cost_precision_version SET DEFAULT 1',t);
 END LOOP;
END;
$product_costs$;
ALTER TABLE public.vm_product_versions
 DROP CONSTRAINT vm_product_versions_numeric_ck,
 ALTER COLUMN composition_cost TYPE numeric(44,32),
 ADD CONSTRAINT vm_product_versions_numeric_ck CHECK (
   vm_private.vm_numeric_valid(price,8,999999999999.99999999,true)
   AND (promo_price IS NULL OR (vm_private.vm_numeric_valid(promo_price,8,999999999999.99999999,true) AND promo_price <= price))
   AND vm_private.vm_numeric_valid(minimum_quantity,8,999999999999.99999999,true) AND minimum_quantity > 0
   AND vm_private.vm_numeric_valid(composition_cost,32,999999999999.99999999,true)
 );

-- Up to 36 decimal places of consumption × 24 places of unit cost.
DO $order_costs$
DECLARE t text;
BEGIN
 FOREACH t IN ARRAY ARRAY['vm_order_items','vm_quote_items'] LOOP
   EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT %I, DROP CONSTRAINT %I,
     ALTER COLUMN unit_composition_cost TYPE numeric(56,32), ALTER COLUMN total_composition_cost TYPE numeric(84,60),
     ADD CONSTRAINT %I CHECK (vm_private.vm_numeric_valid(unit_composition_cost,32,999999999999999999999999.9999999999999999,true)),
     ADD CONSTRAINT %I CHECK (vm_private.vm_numeric_valid(total_composition_cost,60,999999999999999999999999.9999999999999999,true))',
     t,t||'_unit_composition_cost_check',t||'_total_composition_cost_check',
     t||'_unit_composition_cost_check',t||'_total_composition_cost_check');
 END LOOP;
 FOREACH t IN ARRAY ARRAY['vm_order_item_materials','vm_quote_item_materials'] LOOP
   EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT %I, DROP CONSTRAINT %I,
     ALTER COLUMN unit_cost_snapshot TYPE numeric(36,24), ALTER COLUMN consumption_cost TYPE numeric(84,60),
     ADD CONSTRAINT %I CHECK (vm_private.vm_numeric_valid(unit_cost_snapshot,24,999999999999.99999999,true)),
     ADD CONSTRAINT %I CHECK (vm_private.vm_numeric_valid(consumption_cost,60,999999999999999999999999.9999999999999999,true))',
     t,t||'_unit_cost_snapshot_check',t||'_consumption_cost_check',t||'_unit_cost_snapshot_check',t||'_consumption_cost_check');
 END LOOP;
END;
$order_costs$;

-- Only reviewed source sites change; abort rather than guess if another
-- deployment changed an RPC. Function OIDs, ACLs and SECURITY DEFINER remain.
CREATE TEMP TABLE vm_cost_patches(function_name text,old_text text,new_text text,expected int) ON COMMIT DROP;
INSERT INTO vm_cost_patches VALUES
 ('public.vm_create_material','m.unit_cost','m.unit_cost_precise',2),
 ('public.vm_receive_material','m.unit_cost','m.unit_cost_precise',2),
 ('public.vm_create_material_purchase','p.unit_cost::text','p.unit_cost_precise::text',2),
 ('public.vm_upsert_product_v2','c.quantity::numeric(20,8),m.unit_cost','c.quantity::numeric(20,8),m.unit_cost_precise',2),
 ('public.vm_upsert_product_v2','COALESCE(pg_catalog.sum(c.quantity * c.unit_cost_snapshot),0)::numeric(20,8)','COALESCE(pg_catalog.sum(c.line_cost_precise),0)::numeric(44,32)',1),
 ('public.vm_upsert_product_v2','vm_numeric_valid(v_composition_cost,8,','vm_numeric_valid(v_composition_cost,32,',1),
 ('public.vm_upsert_product_v2','pg_catalog.sum(vc.line_cost)','pg_catalog.sum(vc.line_cost_precise)',1),
 ('public.vm_upsert_product_v2', '''line_cost'',vc.line_cost::text','''line_cost'',vc.line_cost_precise::text',1),
 ('public.vm_upsert_product_v2', '''line_cost'',c.line_cost::text','''line_cost'',c.line_cost_precise::text',1),
 ('vm_private.vm_order_resolve_item','vm_order_number(v_unit_cost,16,','vm_order_number(v_unit_cost,32,',1),
 ('vm_private.vm_order_resolve_item','vm_order_number(v_total_cost,44,','vm_order_number(v_total_cost,60,',1);
DO $patch$
DECLARE p record; v_oid oid; v_def text;
BEGIN
 FOR p IN SELECT * FROM vm_cost_patches LOOP
   SELECT pr.oid INTO v_oid FROM pg_catalog.pg_proc pr JOIN pg_catalog.pg_namespace ns ON ns.oid=pr.pronamespace
    WHERE ns.nspname=split_part(p.function_name,'.',1) AND pr.proname=split_part(p.function_name,'.',2)
      AND (SELECT count(*) FROM pg_catalog.pg_proc x WHERE x.pronamespace=ns.oid AND x.proname=pr.proname)=1;
   IF v_oid IS NULL THEN RAISE EXCEPTION 'Missing or ambiguous function %',p.function_name; END IF;
   v_def:=pg_catalog.pg_get_functiondef(v_oid);
   IF (length(v_def)-length(replace(v_def,p.old_text,'')))/length(p.old_text)<>p.expected THEN
     RAISE EXCEPTION 'Unexpected source in function %',p.function_name;
   END IF;
   EXECUTE replace(v_def,p.old_text,p.new_text);
 END LOOP;
END;
$patch$;

DO $restore_views$
DECLARE v record; a record; view_def text; original text; replacement text; expected integer;
BEGIN
 FOR v IN SELECT * FROM vm_cost_views ORDER BY name LOOP
   view_def:=v.definition;
   -- Text output keeps the existing API contract while returning the precise
   -- cost. Supplier stock quantities must not cast fractional balances to 8.
   IF v.name='vm_materials_read' THEN original:='unit_cost::text AS unit_cost';replacement:='unit_cost_precise::text AS unit_cost';
   ELSIF v.name='vm_material_purchases_read' THEN original:='p.unit_cost::text AS unit_cost';replacement:='p.unit_cost_precise::text AS unit_cost';
   ELSIF v.name='vm_suppliers_read' THEN
     original:='sum(m.stock_quantity * m.unit_cost)::numeric(20,8)';replacement:='sum(m.stock_quantity * m.unit_cost_precise)::numeric(84,60)';
   ELSIF v.name='vm_products_read' THEN
     original:='sum(c.quantity * m.unit_cost), 0::numeric)::numeric(20,8)';replacement:='sum(c.quantity * m.unit_cost_precise), 0::numeric)::numeric(44,32)';
   ELSIF v.name='vm_product_components_read' THEN original:='line_cost::text AS line_cost';replacement:='line_cost_precise::text AS line_cost';
   ELSE original:=NULL;replacement:=NULL;
   END IF;
   IF original IS NOT NULL THEN
     expected:=(length(view_def)-length(replace(view_def,original,'')))/length(original);
     IF expected<>1 THEN RAISE EXCEPTION 'Unexpected cost expression in view %',v.name; END IF;
     view_def:=replace(view_def,original,replacement);
   END IF;
   IF v.name='vm_suppliers_read' THEN
     original:='sum(m2.stock_quantity)::numeric(20,8)';
     IF (length(view_def)-length(replace(view_def,original,'')))/length(original)<>1 THEN RAISE EXCEPTION 'Unexpected supplier stock cast'; END IF;
     view_def:=replace(view_def,original,'sum(m2.stock_quantity)::numeric(48,36)');
   END IF;
   EXECUTE format('CREATE VIEW public.%I WITH (security_invoker=true) AS %s',v.name,view_def);
   EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC',v.name);
   FOR a IN SELECT DISTINCT acl.grantee FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
     CROSS JOIN LATERAL pg_catalog.aclexplode(c.relacl) acl
     WHERE n.nspname='public' AND c.relname=v.name
       AND acl.grantee<>(SELECT oid FROM pg_catalog.pg_roles WHERE rolname=v.owner_name)
   LOOP
     EXECUTE format('REVOKE ALL ON TABLE public.%I FROM %s',v.name,
       CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_catalog.quote_ident(pg_catalog.pg_get_userbyid(a.grantee)) END);
   END LOOP;
   FOR a IN SELECT * FROM pg_catalog.aclexplode(v.relacl) WHERE grantee<>(SELECT oid FROM pg_catalog.pg_roles WHERE rolname=v.owner_name) LOOP
     EXECUTE format('GRANT %s ON TABLE public.%I TO %s%s',a.privilege_type,v.name,
       CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_catalog.quote_ident(pg_catalog.pg_get_userbyid(a.grantee)) END,
       CASE WHEN a.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END);
   END LOOP;
   IF v.comment IS NOT NULL THEN EXECUTE format('COMMENT ON VIEW public.%I IS %L',v.name,v.comment); END IF;
 END LOOP;
END;
$restore_views$;
INSERT INTO public.vm_schema_migrations(version,description)
VALUES('20261030011000_fractional_unit_cost','Custo unitário fracionário e custo exato de composições e pedidos') ON CONFLICT(version) DO NOTHING;
NOTIFY pgrst, 'reload schema';
COMMIT;
