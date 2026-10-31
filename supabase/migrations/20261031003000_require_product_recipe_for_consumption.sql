BEGIN;
SET LOCAL lock_timeout='5s';

-- The default is deliberately tracked: legacy products are never silently
-- classified as stock-exempt. The current choice is frozen into every order
-- and quote at resolution time, not retroactively inferred from the catalog.
ALTER TABLE public.vm_products ADD COLUMN inventory_mode text NOT NULL DEFAULT 'materials'
  CHECK (inventory_mode IN ('materials','no_stock'));

-- Old v2 clients cannot accidentally keep an exemption after editing a
-- product. v3 below sets the explicit mode in the same transaction.
CREATE FUNCTION vm_private.vm_reset_product_inventory_mode()
RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $fn$
BEGIN
  IF NEW.current_version IS DISTINCT FROM OLD.current_version THEN
    NEW.inventory_mode := 'materials';
  END IF;
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION vm_private.vm_reset_product_inventory_mode() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER vm_reset_product_inventory_mode BEFORE UPDATE ON public.vm_products
FOR EACH ROW EXECUTE FUNCTION vm_private.vm_reset_product_inventory_mode();

CREATE TABLE vm_private.vm_product_inventory_requests (
  organization_id uuid NOT NULL,
  idempotency_key uuid NOT NULL,
  inventory_mode text NOT NULL CHECK(inventory_mode IN ('materials','no_stock')),
  product_id uuid NOT NULL,
  product_version integer NOT NULL,
  PRIMARY KEY (organization_id,idempotency_key),
  FOREIGN KEY (organization_id,product_id,product_version)
    REFERENCES public.vm_product_versions(organization_id,product_id,product_version) ON DELETE RESTRICT
);
ALTER TABLE vm_private.vm_product_inventory_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON vm_private.vm_product_inventory_requests FROM PUBLIC,anon,authenticated;

DO $view_guard$
BEGIN
  IF md5(pg_get_viewdef('public.vm_products_read'::regclass,true))<>'8d24508641f9b1cc2f520496e127acce' THEN
    RAISE EXCEPTION 'Reviewed product view differs';
  END IF;
  IF md5(pg_get_functiondef('public.vm_upsert_product_v2(uuid,text,text,jsonb,text,text,text,text,integer,text,numeric,numeric,numeric,text,boolean,boolean,jsonb,numeric,numeric,numeric,numeric,text,text,jsonb,jsonb,jsonb,uuid,uuid)'::regprocedure))<>'30725f6ce550dd3734c027668efa7a28' THEN
    RAISE EXCEPTION 'Reviewed product upsert differs';
  END IF;
END;
$view_guard$;
CREATE OR REPLACE VIEW public.vm_products_read WITH (security_invoker=true) AS
SELECT p.id,p.organization_id,p.name,p.category,p.categories,p.subcategory,p.description,p.material_info,p.personalization_info,
 p.production_days::text AS production_days,p.pricing_mode,p.price::text AS price,p.promo_price::text AS promo_price,
 p.minimum_quantity::text AS minimum_quantity,p.billing_unit,p.is_catalog_visible,p.is_featured,p.custom_questions,
 p.weight_kg::text AS weight_kg,p.width_cm::text AS width_cm,p.height_cm::text AS height_cm,p.depth_cm::text AS depth_cm,
 p.sku,p.barcode,p.wholesale_tiers,p.current_version::text AS current_version,
 v.composition_cost::text AS current_composition_cost,
 (SELECT COALESCE(sum(c.quantity*m.unit_cost_precise),0)::numeric(44,32)::text
  FROM public.vm_product_components c JOIN public.vm_materials m ON m.organization_id=c.organization_id AND m.id=c.material_id
  WHERE c.organization_id=p.organization_id AND c.product_id=p.id AND c.product_version=p.current_version) AS current_material_cost,
 p.created_at,p.updated_at,p.inventory_mode
FROM public.vm_products p LEFT JOIN public.vm_product_versions v
 ON v.organization_id=p.organization_id AND v.product_id=p.id AND v.product_version=p.current_version;

-- v2 remains supported. This wrapper uses its complete validation and nonce,
-- plus its own mode-aware replay guard, in a single database transaction.
CREATE FUNCTION public.vm_upsert_product_v3(p_organization_id uuid,p_data jsonb,p_inventory_mode text,p_idempotency_key uuid)
RETURNS TABLE(product_id uuid,version text,pricing_mode text,normal_price text,promo_price text,minimum_quantity text,component_count integer,composition_cost text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE prior vm_private.vm_product_inventory_requests%ROWTYPE; result record; version_row public.vm_product_versions%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR auth.role() IS DISTINCT FROM 'authenticated'
    OR NOT vm_private.vm_has_role(p_organization_id,ARRAY['owner','admin','production']::text[]) THEN
    RAISE EXCEPTION 'Sem permissão para alterar produto' USING ERRCODE='42501';
  END IF;
  IF p_idempotency_key IS NULL OR p_inventory_mode IS NULL OR p_inventory_mode NOT IN ('materials','no_stock')
    OR pg_catalog.jsonb_typeof(p_data) IS DISTINCT FROM 'object'
    OR (p_data - ARRAY['p_name','p_category','p_categories','p_subcategory','p_description','p_material_info','p_personalization_info',
      'p_production_days','p_pricing_mode','p_price','p_promo_price','p_minimum_quantity','p_billing_unit','p_is_catalog_visible',
      'p_is_featured','p_custom_questions','p_weight_kg','p_width_cm','p_height_cm','p_depth_cm','p_sku','p_barcode',
      'p_wholesale_tiers','p_components','p_variants','p_product_id']) <> '{}'::jsonb THEN
    RAISE EXCEPTION 'Dados de produto ou classificação de estoque inválidos' USING ERRCODE='22023';
  END IF;
  PERFORM 1 FROM public.vm_organizations o WHERE o.id=p_organization_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Organização não encontrada' USING ERRCODE='23503'; END IF;
  SELECT * INTO prior FROM vm_private.vm_product_inventory_requests r
    WHERE r.organization_id=p_organization_id AND r.idempotency_key=p_idempotency_key;
  IF FOUND AND prior.inventory_mode<>p_inventory_mode THEN
    RAISE EXCEPTION 'Chave reutilizada com classificação diferente' USING ERRCODE='23505';
  END IF;
  IF prior.idempotency_key IS NULL AND EXISTS (SELECT 1 FROM vm_private.vm_product_upsert_requests r
      WHERE r.organization_id=p_organization_id AND r.idempotency_key=p_idempotency_key) THEN
    RAISE EXCEPTION 'Chave já utilizada por versão anterior da API' USING ERRCODE='23505';
  END IF;
  SELECT * INTO result FROM public.vm_upsert_product_v2(
    p_organization_id,p_data->>'p_name',p_data->>'p_category',p_data->'p_categories',p_data->>'p_subcategory',
    p_data->>'p_description',p_data->>'p_material_info',p_data->>'p_personalization_info',
    (p_data->>'p_production_days')::integer,p_data->>'p_pricing_mode',(p_data->>'p_price')::numeric,
    (p_data->>'p_promo_price')::numeric,(p_data->>'p_minimum_quantity')::numeric,p_data->>'p_billing_unit',
    (p_data->>'p_is_catalog_visible')::boolean,(p_data->>'p_is_featured')::boolean,p_data->'p_custom_questions',
    (p_data->>'p_weight_kg')::numeric,(p_data->>'p_width_cm')::numeric,(p_data->>'p_height_cm')::numeric,
    (p_data->>'p_depth_cm')::numeric,p_data->>'p_sku',p_data->>'p_barcode',p_data->'p_wholesale_tiers',
    p_data->'p_components',p_data->'p_variants',(p_data->>'p_product_id')::uuid,p_idempotency_key);
  IF prior.idempotency_key IS NULL THEN
    SELECT v.* INTO version_row FROM public.vm_product_versions v
      WHERE v.organization_id=p_organization_id AND v.product_id=result.product_id AND v.product_version=result.version::integer;
    IF NOT FOUND THEN RAISE EXCEPTION 'Versão do produto não encontrada' USING ERRCODE='23503'; END IF;
    IF p_inventory_mode='no_stock' AND (pg_catalog.jsonb_array_length(version_row.composition_snapshot)>0 OR EXISTS (
      SELECT 1 FROM pg_catalog.jsonb_array_elements(version_row.variants_snapshot) variant(value)
      WHERE (variant.value->>'active')::boolean IS TRUE
        AND pg_catalog.jsonb_array_length(COALESCE(variant.value->'components','[]'::jsonb))>0
    )) THEN
      RAISE EXCEPTION 'Produto sem estoque não pode ter composição ativa de insumos' USING ERRCODE='VM002';
    END IF;
    UPDATE public.vm_products p SET inventory_mode=p_inventory_mode
      WHERE p.organization_id=p_organization_id AND p.id=result.product_id AND p.current_version=result.version::integer;
    IF NOT FOUND THEN RAISE EXCEPTION 'Versão corrente mudou durante a operação' USING ERRCODE='40001'; END IF;
    INSERT INTO vm_private.vm_product_inventory_requests(organization_id,idempotency_key,inventory_mode,product_id,product_version)
    VALUES(p_organization_id,p_idempotency_key,p_inventory_mode,result.product_id,result.version::integer);
  ELSIF prior.product_id<>result.product_id OR prior.product_version<>result.version::integer THEN
    RAISE EXCEPTION 'Tentativa de produto inconsistente' USING ERRCODE='23514';
  END IF;
  RETURN QUERY SELECT result.product_id,result.version,result.pricing_mode,result.normal_price,result.promo_price,
    result.minimum_quantity,result.component_count,result.composition_cost;
END;
$fn$;
REVOKE ALL ON FUNCTION public.vm_upsert_product_v3(uuid,jsonb,text,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.vm_upsert_product_v3(uuid,jsonb,text,uuid) TO authenticated;

-- Keep the reviewed precision, lock ordering, idempotency and function ACLs.
-- Abort rather than silently patch an unexpected remote implementation.
DO $patch$
DECLARE definition text; old_text text; new_text text;
BEGIN
  definition:=pg_catalog.pg_get_functiondef('vm_private.vm_order_resolve_item(uuid,jsonb)'::regprocedure);
  IF pg_catalog.md5(definition)<>'41e8b9975d10b0312a236d91eeeb4ee4' THEN
    RAISE EXCEPTION 'Reviewed order item resolver differs';
  END IF;
  old_text:=$old$  v_raw numeric; v_line numeric; v_product_snapshot jsonb:='{}'; v_price_snapshot jsonb;$old$;
  new_text:=$new$  v_raw numeric; v_line numeric; v_product_snapshot jsonb:='{}'; v_price_snapshot jsonb; v_inventory_mode text:='materials';$new$;
  IF (length(definition)-length(replace(definition,old_text,'')))/length(old_text)<>1 THEN RAISE EXCEPTION 'Unexpected resolver declaration'; END IF;
  definition:=replace(definition,old_text,new_text);
  old_text:='    v_billing:=v_product.billing_unit; v_normal:=v_product.price; v_promo:=v_product.promo_price;';
  new_text:='    SELECT p.inventory_mode INTO v_inventory_mode FROM public.vm_products p WHERE p.organization_id=p_organization_id AND p.id=v_product_id;'
    ||pg_catalog.chr(10)||old_text;
  IF (length(definition)-length(replace(definition,old_text,'')))/length(old_text)<>1 THEN RAISE EXCEPTION 'Unexpected resolver product lookup'; END IF;
  definition:=replace(definition,old_text,new_text);
  old_text:=$old$      'recipe_mode',v_mode,'snapshot_metadata',v_product.snapshot_metadata);$old$;
  new_text:=$new$      'recipe_mode',v_mode,'inventory_mode',v_inventory_mode,'snapshot_metadata',v_product.snapshot_metadata);$new$;
  IF (length(definition)-length(replace(definition,old_text,'')))/length(old_text)<>1 THEN RAISE EXCEPTION 'Unexpected resolver product snapshot'; END IF;
  definition:=replace(definition,old_text,new_text);
  old_text:='  PERFORM vm_private.vm_order_number(v_unit_cost,32,';
  new_text:=$body$  -- Catalog products need a real frozen recipe. Manual services do not.
  IF v_kind='product' AND v_inventory_mode='materials' AND pg_catalog.jsonb_array_length(v_recipe)=0 THEN
    RAISE EXCEPTION 'Produto sem composição: cadastre insumos antes de emitir pedido ou orçamento' USING ERRCODE='VM001';
  END IF;
  IF v_kind='product' AND v_inventory_mode='no_stock' AND pg_catalog.jsonb_array_length(v_recipe)>0 THEN
    RAISE EXCEPTION 'Produto sem estoque não pode conter composição de insumos' USING ERRCODE='VM002';
  END IF;
  PERFORM vm_private.vm_order_number(v_unit_cost,32,$body$;
  IF (length(definition)-length(replace(definition,old_text,'')))/length(old_text)<>1 THEN RAISE EXCEPTION 'Unexpected resolver patch point'; END IF;
  EXECUTE replace(definition,old_text,new_text);

  definition:=pg_catalog.pg_get_functiondef('vm_private.vm_order_consume(uuid,uuid,uuid)'::regprocedure);
  IF pg_catalog.md5(definition)<>'3b0ba0714df6ab38e4f48f9f56149270' THEN
    RAISE EXCEPTION 'Reviewed order consumption differs';
  END IF;
  old_text:='  -- First lock and validate ALL balances; no stock mutation in this loop.';
  new_text:=$body$  -- Older pending orders or approved quotes may have no frozen recipe.
  -- Do not consume any item, write a run, or change status in that case.
  IF EXISTS (
    SELECT 1 FROM public.vm_order_items i
    WHERE i.organization_id=p_organization_id AND i.order_id=p_order_id AND i.kind='product'
      AND (i.product_snapshot->>'inventory_mode') IS DISTINCT FROM 'no_stock'
      AND NOT EXISTS (SELECT 1 FROM public.vm_order_item_materials m
        WHERE m.organization_id=i.organization_id AND m.order_id=i.order_id AND m.item_id=i.id)
  ) THEN
    RAISE EXCEPTION 'Produto do pedido sem composição congelada: revise ou recrie o pedido' USING ERRCODE='VM001';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.vm_order_items i
    WHERE i.organization_id=p_organization_id AND i.order_id=p_order_id AND i.kind='product'
      AND i.product_snapshot->>'inventory_mode'='no_stock'
      AND EXISTS (SELECT 1 FROM public.vm_order_item_materials m
        WHERE m.organization_id=i.organization_id AND m.order_id=i.order_id AND m.item_id=i.id)
  ) THEN
    RAISE EXCEPTION 'Produto sem estoque possui composição congelada inconsistente' USING ERRCODE='VM002';
  END IF;
  -- First lock and validate ALL balances; no stock mutation in this loop.$body$;
  IF (length(definition)-length(replace(definition,old_text,'')))/length(old_text)<>1 THEN RAISE EXCEPTION 'Unexpected consumption patch point'; END IF;
  EXECUTE replace(definition,old_text,new_text);
END;
$patch$;

INSERT INTO public.vm_schema_migrations(version,description)
VALUES('20261031003000_require_product_recipe_for_consumption','Impede baixa fictícia de produto sem composição') ON CONFLICT(version) DO NOTHING;
NOTIFY pgrst,'reload schema';
COMMIT;
