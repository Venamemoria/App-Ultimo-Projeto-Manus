BEGIN;
SET LOCAL lock_timeout = '5s';

-- User-entered quantities and prices remain capped at eight decimal places.
-- A square-meter factor may require 20 places; billed quantity 28; and a
-- material fraction multiplied by that quantity 36. Costs then require 44.
-- Preserve every existing value and widen, never round a stock movement.
-- Views are recreated transactionally with their existing definitions and ACLs.
CREATE TEMP TABLE vm_fractional_views ON COMMIT DROP AS
SELECT c.relname AS name, pg_get_viewdef(c.oid,true) AS definition,
       c.reloptions, c.relacl, pg_get_userbyid(c.relowner) AS owner_name,
       obj_description(c.oid,'pg_class') AS comment
FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public' AND c.relkind='v' AND c.relname=ANY(ARRAY[
  'vm_materials_read','vm_suppliers_read','vm_stock_movements_read',
  'vm_order_items_read','vm_order_consumptions_read','vm_order_returns_read'
]);
DO $views_guard$
BEGIN
  IF (SELECT count(*) FROM vm_fractional_views) <> 6 OR EXISTS (
    SELECT 1 FROM vm_fractional_views WHERE reloptions IS DISTINCT FROM ARRAY['security_invoker=true']::text[]
      OR owner_name <> current_user
  ) THEN
    RAISE EXCEPTION 'View definitions or ownership changed; review precision migration';
  END IF;
END;
$views_guard$;
DROP VIEW public.vm_materials_read,public.vm_suppliers_read,public.vm_stock_movements_read,
          public.vm_order_items_read,public.vm_order_consumptions_read,public.vm_order_returns_read;

ALTER TABLE public.vm_materials
  DROP CONSTRAINT vm_materials_stock_quantity_valid_ck,
  ALTER COLUMN stock_quantity TYPE numeric(48,36),
  ADD CONSTRAINT vm_materials_stock_quantity_valid_ck CHECK (vm_private.vm_numeric_valid(stock_quantity,36,999999999999.99999999,true));
ALTER TABLE public.vm_stock_movements
  DROP CONSTRAINT vm_stock_movements_quantity_delta_valid_ck,
  DROP CONSTRAINT vm_stock_movements_stock_after_valid_ck,
  ALTER COLUMN quantity_delta TYPE numeric(48,36),
  ALTER COLUMN stock_after TYPE numeric(48,36),
  ADD CONSTRAINT vm_stock_movements_quantity_delta_valid_ck CHECK (vm_private.vm_numeric_valid(quantity_delta,36,999999999999.99999999,false)),
  ADD CONSTRAINT vm_stock_movements_stock_after_valid_ck CHECK (vm_private.vm_numeric_valid(stock_after,36,999999999999.99999999,true));
ALTER TABLE public.vm_order_consumptions
  DROP CONSTRAINT vm_order_consumptions_quantity_check,
  ALTER COLUMN quantity TYPE numeric(48,36),
  ADD CONSTRAINT vm_order_consumptions_quantity_check CHECK (quantity>0 AND vm_private.vm_numeric_valid(quantity,36,999999999999.99999999,true));
ALTER TABLE public.vm_order_return_events
  DROP CONSTRAINT vm_order_return_events_returned_quantity_check,
  ALTER COLUMN returned_quantity TYPE numeric(48,36),
  ADD CONSTRAINT vm_order_return_events_returned_quantity_check CHECK (returned_quantity>0 AND vm_private.vm_numeric_valid(returned_quantity,36,999999999999.99999999,true));
ALTER TABLE public.vm_order_return_lines
  DROP CONSTRAINT vm_order_return_lines_quantity_check,
  ALTER COLUMN quantity TYPE numeric(48,36),
  ADD CONSTRAINT vm_order_return_lines_quantity_check CHECK (quantity>0 AND vm_private.vm_numeric_valid(quantity,36,999999999999.99999999,true));

-- Orders and quotes share the same pricing/recipe resolver; their frozen
-- snapshots must support the same exact arithmetic and approval conversion.
DO $widen$
DECLARE table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY['vm_order_items','vm_quote_items'] LOOP
    EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT %I, DROP CONSTRAINT %I, DROP CONSTRAINT %I, DROP CONSTRAINT %I',
      table_name,table_name||'_dimensions_factor_check',table_name||'_billed_quantity_check',
      table_name||'_line_amount_raw_check',table_name||'_total_composition_cost_check');
    EXECUTE format('ALTER TABLE public.%I ALTER COLUMN dimensions_factor TYPE numeric(48,36), ALTER COLUMN billed_quantity TYPE numeric(48,36), ALTER COLUMN line_amount_raw TYPE numeric(60,36), ALTER COLUMN total_composition_cost TYPE numeric(68,44)',table_name);
    EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I CHECK (dimensions_factor>0 AND vm_private.vm_numeric_valid(dimensions_factor,36,999999999999.99999999,true)), ADD CONSTRAINT %I CHECK (billed_quantity>0 AND vm_private.vm_numeric_valid(billed_quantity,36,999999999999.99999999,true)), ADD CONSTRAINT %I CHECK (vm_private.vm_numeric_valid(line_amount_raw,36,999999999999999999999999.9999999999999999,true)), ADD CONSTRAINT %I CHECK (vm_private.vm_numeric_valid(total_composition_cost,44,999999999999999999999999.9999999999999999,true))',
      table_name,table_name||'_dimensions_factor_check',table_name||'_billed_quantity_check',
      table_name||'_line_amount_raw_check',table_name||'_total_composition_cost_check');
  END LOOP;
  FOREACH table_name IN ARRAY ARRAY['vm_order_item_materials','vm_quote_item_materials'] LOOP
    EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT %I, DROP CONSTRAINT %I',
      table_name,table_name||'_consumption_quantity_check',table_name||'_consumption_cost_check');
    EXECUTE format('ALTER TABLE public.%I ALTER COLUMN consumption_quantity TYPE numeric(48,36), ALTER COLUMN consumption_cost TYPE numeric(68,44)',table_name);
    EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I CHECK (consumption_quantity>0 AND vm_private.vm_numeric_valid(consumption_quantity,36,999999999999.99999999,true)), ADD CONSTRAINT %I CHECK (vm_private.vm_numeric_valid(consumption_cost,44,999999999999999999999999.9999999999999999,true))',
      table_name,table_name||'_consumption_quantity_check',table_name||'_consumption_cost_check');
  END LOOP;
END;
$widen$;

-- Patch only the exact, reviewed validation sites in existing functions; fail
-- closed if any expected source is absent or occurs more than once. CREATE OR
-- REPLACE retains SECURITY DEFINER, search_path, function identity and grants.
CREATE TEMP TABLE vm_fractional_patches(function_name text, old_text text, new_text text) ON COMMIT DROP;
INSERT INTO vm_fractional_patches VALUES
('vm_private.vm_order_resolve_item','vm_order_number(v_factor,8,','vm_order_number(v_factor,36,'),
('vm_private.vm_order_resolve_item','vm_order_number(v_billed,8,','vm_order_number(v_billed,36,'),
('vm_private.vm_order_resolve_item','vm_order_number(v_consumption,8,','vm_order_number(v_consumption,36,'),
('vm_private.vm_order_resolve_item','vm_order_number(v_raw,16,','vm_order_number(v_raw,36,'),
('vm_private.vm_order_resolve_item','vm_order_number(v_total_cost,16,','vm_order_number(v_total_cost,44,'),
('vm_private.vm_order_consume','vm_order_number(v_material.quantity,8,','vm_order_number(v_material.quantity,36,'),
('vm_private.vm_order_consume','vm_order_number(v_new,8,','vm_order_number(v_new,36,'),
('vm_private.vm_order_build','vm_order_number(v_aggregate.quantity,8,','vm_order_number(v_aggregate.quantity,36,'),
('public.vm_create_quote','vm_order_number(v_aggregate.quantity,8,','vm_order_number(v_aggregate.quantity,36,'),
('public.vm_receive_material','vm_numeric_valid(v_new,8,','vm_numeric_valid(v_new,36,'),
('public.vm_adjust_material_stock_safe','vm_numeric_valid(v_new,8,','vm_numeric_valid(v_new,36,'),
('public.vm_create_material_purchase','vm_numeric_valid(v_new,8,','vm_numeric_valid(v_new,36,'),
('vm_private.vm_order_return_canonical','vm_order_number(v_quantity,8,','vm_order_number(v_quantity,36,'),
('public.vm_record_order_return','vm_order_number(v_new_stock,8,','vm_order_number(v_new_stock,36,');
DO $patch$
DECLARE p record; v_oid oid; v_def text; v_replaced text;
BEGIN
  FOR p IN SELECT * FROM vm_fractional_patches LOOP
    SELECT pr.oid INTO v_oid FROM pg_catalog.pg_proc pr
      JOIN pg_catalog.pg_namespace ns ON ns.oid=pr.pronamespace
      WHERE ns.nspname=split_part(p.function_name,'.',1) AND pr.proname=split_part(p.function_name,'.',2)
      AND (SELECT count(*) FROM pg_catalog.pg_proc x WHERE x.pronamespace=ns.oid AND x.proname=pr.proname)=1;
    IF v_oid IS NULL THEN RAISE EXCEPTION 'Missing or ambiguous function %',p.function_name; END IF;
    v_def:=pg_catalog.pg_get_functiondef(v_oid);
    IF (length(v_def)-length(replace(v_def,p.old_text,'')))/length(p.old_text) <> 1 THEN
      RAISE EXCEPTION 'Unexpected function source in %',p.function_name;
    END IF;
    v_replaced:=replace(v_def,p.old_text,p.new_text);
    EXECUTE v_replaced;
  END LOOP;
  SELECT pg_catalog.pg_get_functiondef(pr.oid) INTO v_def FROM pg_catalog.pg_proc pr
    JOIN pg_catalog.pg_namespace ns ON ns.oid=pr.pronamespace
    WHERE ns.nspname='public' AND pr.proname='vm_record_order_return';
  IF (length(v_def)-length(replace(v_def,'::numeric(20,8)','')))/length('::numeric(20,8)') <> 2
     OR (length(v_def)-length(replace(v_def,'::numeric(40,8)','')))/length('::numeric(40,8)') <> 2 THEN
    RAISE EXCEPTION 'Unexpected return result casts';
  END IF;
  EXECUTE replace(replace(v_def,'::numeric(20,8)','::numeric(48,36)'),'::numeric(40,8)','::numeric(60,36)');
END;
$patch$;

DO $restore_views$
DECLARE v record; grant_row record; view_def text;
BEGIN
  FOR v IN SELECT * FROM vm_fractional_views ORDER BY name LOOP
    view_def:=v.definition;
    IF v.name='vm_order_returns_read' THEN
      IF (length(view_def)-length(replace(view_def,'::numeric(20,8)','')))/length('::numeric(20,8)') <> 2 THEN
        RAISE EXCEPTION 'Unexpected return-view casts';
      END IF;
      view_def:=replace(view_def,'::numeric(20,8)','::numeric(48,36)');
    END IF;
    EXECUTE format('CREATE VIEW public.%I WITH (security_invoker=true) AS %s',v.name,view_def);
    -- A hosted project can grant anon/authenticated/service_role automatically
    -- on newly created views. Remove every new default grant before restoring
    -- the prior ACL, not just PUBLIC, or recreation could widen access.
    EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC',v.name);
    FOR grant_row IN
      SELECT DISTINCT a.grantee FROM pg_catalog.pg_class c
      JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
      CROSS JOIN LATERAL pg_catalog.aclexplode(c.relacl) a
      WHERE n.nspname='public' AND c.relname=v.name
        AND a.grantee <> (SELECT oid FROM pg_catalog.pg_roles WHERE rolname=v.owner_name)
    LOOP
      EXECUTE format('REVOKE ALL ON TABLE public.%I FROM %s',v.name,
        CASE WHEN grant_row.grantee=0 THEN 'PUBLIC' ELSE pg_catalog.quote_ident(pg_catalog.pg_get_userbyid(grant_row.grantee)) END);
    END LOOP;
    FOR grant_row IN SELECT * FROM pg_catalog.aclexplode(v.relacl) WHERE grantee <> (SELECT oid FROM pg_catalog.pg_roles WHERE rolname=v.owner_name) LOOP
      EXECUTE format('GRANT %s ON TABLE public.%I TO %s%s',grant_row.privilege_type,v.name,
        CASE WHEN grant_row.grantee=0 THEN 'PUBLIC' ELSE pg_catalog.quote_ident(pg_catalog.pg_get_userbyid(grant_row.grantee)) END,
        CASE WHEN grant_row.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END);
    END LOOP;
    IF v.comment IS NOT NULL THEN EXECUTE format('COMMENT ON VIEW public.%I IS %L',v.name,v.comment); END IF;
  END LOOP;
END;
$restore_views$;

INSERT INTO public.vm_schema_migrations(version,description)
VALUES('20261030010000_fractional_multiplication','Multiplicação fracionária exata de pedidos, orçamentos, estoque e devoluções')
ON CONFLICT(version) DO NOTHING;
NOTIFY pgrst, 'reload schema';
COMMIT;
