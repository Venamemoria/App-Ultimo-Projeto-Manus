BEGIN;
SET LOCAL lock_timeout='5s';

-- Fail closed if a reviewed view, role guard, policy, owner or grant changed.
DO $guard$
DECLARE v record;
BEGIN
 FOR v IN SELECT * FROM (VALUES
  ('vm_products_read','264631d19ec7ebca13f826de17475f4f'),
  ('vm_product_components_read','3eaad1e5f00fb01b781897eb0953ab54'),
  ('vm_product_variants_read','69730a506ff9aecdf1cfca55dd4e7475'),
  ('vm_product_versions_read','acd16b7d27d49589594834b2265adfe4')
 ) AS views(name,hash) LOOP
  IF pg_catalog.md5(pg_catalog.pg_get_viewdef(pg_catalog.to_regclass('public.'||v.name),true)) IS DISTINCT FROM v.hash
   OR NOT EXISTS(SELECT 1 FROM pg_catalog.pg_class WHERE oid=pg_catalog.to_regclass('public.'||v.name) AND reloptions @> ARRAY['security_invoker=true'])
   OR pg_catalog.has_table_privilege('anon',pg_catalog.to_regclass('public.'||v.name),'SELECT') THEN
   RAISE EXCEPTION 'Reviewed product view % differs',v.name;
  END IF;
 END LOOP;
 FOR v IN SELECT * FROM (VALUES
  ('vm_products','033be63a2076587129887b95b85c58c4'),
  ('vm_product_components','7504476d29c78f9d3167f0a357cac504'),
  ('vm_product_variants','fdf5fa94a8292c2887ced672966c9e58'),
  ('vm_product_variant_components','e9ff875fcba66b4dd44846fb21257ec4'),
  ('vm_product_versions','70e61b7b42d8174272f45ceb2772ce10')
 ) AS tables(name,hash) LOOP
  IF (SELECT count(*) FROM pg_catalog.pg_policy WHERE polrelid=pg_catalog.to_regclass('public.'||v.name) AND polcmd IN ('r','*'))<>1
   OR NOT EXISTS(SELECT 1 FROM pg_catalog.pg_policy WHERE polrelid=pg_catalog.to_regclass('public.'||v.name)
     AND polname=v.name||'_member_select' AND polcmd='r' AND polpermissive
     AND polroles=ARRAY[(SELECT oid FROM pg_catalog.pg_roles WHERE rolname='authenticated')]
     AND pg_catalog.md5(pg_catalog.pg_get_expr(polqual,polrelid))=v.hash)
   OR NOT EXISTS(SELECT 1 FROM pg_catalog.pg_class WHERE oid=pg_catalog.to_regclass('public.'||v.name) AND relrowsecurity AND NOT relforcerowsecurity)
   OR pg_catalog.has_table_privilege('anon',pg_catalog.to_regclass('public.'||v.name),'SELECT')
   OR NOT pg_catalog.has_table_privilege('authenticated',pg_catalog.to_regclass('public.'||v.name),'SELECT')
   OR pg_catalog.has_table_privilege('authenticated',pg_catalog.to_regclass('public.'||v.name),'INSERT,UPDATE,DELETE') THEN
   RAISE EXCEPTION 'Unexpected product policies, grants or RLS on %',v.name;
  END IF;
 END LOOP;
 IF EXISTS(SELECT 1 FROM pg_catalog.pg_class c WHERE c.oid IN ('public.vm_products'::regclass,'public.vm_product_components'::regclass,
   'public.vm_product_variants'::regclass,'public.vm_product_variant_components'::regclass,'public.vm_product_versions'::regclass,'public.vm_materials'::regclass,
   'public.vm_products_read'::regclass,'public.vm_product_components_read'::regclass,'public.vm_product_variants_read'::regclass,'public.vm_product_versions_read'::regclass)
   AND c.relowner<>(SELECT relowner FROM pg_catalog.pg_class WHERE oid='public.vm_products'::regclass)) THEN
  RAISE EXCEPTION 'Unexpected product ownership';
 END IF;
 FOR v IN SELECT * FROM (VALUES
  ('vm_product_media_select','r','2326aec5c370428e5fab71be80473a8c','d41d8cd98f00b204e9800998ecf8427e'),
  ('vm_product_media_insert','a','d41d8cd98f00b204e9800998ecf8427e','67e4425b7f405fe07b6babe722ba74c2'),
  ('vm_product_media_delete','d','67e4425b7f405fe07b6babe722ba74c2','d41d8cd98f00b204e9800998ecf8427e')
 ) AS policies(name,command,qual_hash,check_hash) LOOP
  IF NOT EXISTS(SELECT 1 FROM pg_catalog.pg_policy WHERE polrelid='storage.objects'::regclass AND polname=v.name
    AND polcmd=v.command::"char" AND polpermissive AND polroles=ARRAY[(SELECT oid FROM pg_catalog.pg_roles WHERE rolname='authenticated')]
    AND pg_catalog.md5(COALESCE(pg_catalog.pg_get_expr(polqual,polrelid),''))=v.qual_hash
    AND pg_catalog.md5(COALESCE(pg_catalog.pg_get_expr(polwithcheck,polrelid),''))=v.check_hash) THEN
   RAISE EXCEPTION 'Reviewed product storage policy % differs',v.name;
  END IF;
 END LOOP;
END;
$guard$;

-- Clone the reviewed implementation privately, retaining its validation,
-- precision and idempotency. Financial callers use the public RPCs; the
-- operational wrapper below alone may call the private implementation.
DO $patch$
DECLARE d text; clone text; old_roles text:=$old$ARRAY['owner','admin','production']::text[]$old$;
BEGIN
 d:=pg_catalog.pg_get_functiondef('public.vm_upsert_product_v2(uuid,text,text,jsonb,text,text,text,text,integer,text,numeric,numeric,numeric,text,boolean,boolean,jsonb,numeric,numeric,numeric,numeric,text,text,jsonb,jsonb,jsonb,uuid,uuid)'::regprocedure);
 IF pg_catalog.md5(d)<>'30725f6ce550dd3734c027668efa7a28' OR (length(d)-length(replace(d,old_roles,'')))/length(old_roles)<>1 THEN RAISE EXCEPTION 'Reviewed product v2 differs'; END IF;
 clone:=replace(replace(d,'CREATE OR REPLACE FUNCTION public.vm_upsert_product_v2(',
   'CREATE OR REPLACE FUNCTION vm_private.vm_upsert_product_v2_internal('),old_roles,$all$ARRAY['owner','admin','finance','production']::text[]$all$);
 EXECUTE clone;
 EXECUTE replace(d,old_roles,$financial$ARRAY['owner','admin','finance']::text[]$financial$);

 d:=pg_catalog.pg_get_functiondef('public.vm_upsert_product_v3(uuid,jsonb,text,uuid)'::regprocedure);
 IF pg_catalog.md5(d)<>'c1861b6963dc74ea6481621f21e62bb3' OR (length(d)-length(replace(d,old_roles,'')))/length(old_roles)<>1 THEN RAISE EXCEPTION 'Reviewed product v3 differs'; END IF;
 clone:=replace(replace(replace(d,'CREATE OR REPLACE FUNCTION public.vm_upsert_product_v3(',
   'CREATE OR REPLACE FUNCTION vm_private.vm_upsert_product_v3_internal('),
   'public.vm_upsert_product_v2(','vm_private.vm_upsert_product_v2_internal('),old_roles,$all$ARRAY['owner','admin','finance','production']::text[]$all$);
 EXECUTE clone;
 EXECUTE replace(d,old_roles,$financial$ARRAY['owner','admin','finance']::text[]$financial$);

 d:=pg_catalog.pg_get_functiondef('public.vm_register_product_file(uuid,uuid,text,text,text,bigint,text)'::regprocedure);
 IF pg_catalog.md5(d)<>'0bfc7ab15540094f387b69878db72801' OR (length(d)-length(replace(d,old_roles,'')))/length(old_roles)<>1 THEN RAISE EXCEPTION 'Reviewed file registration differs'; END IF;
 EXECUTE replace(d,old_roles,$all$ARRAY['owner','admin','finance','production']::text[]$all$);
END;
$patch$;
REVOKE ALL ON FUNCTION vm_private.vm_upsert_product_v2_internal(uuid,text,text,jsonb,text,text,text,text,integer,text,numeric,numeric,numeric,text,boolean,boolean,jsonb,numeric,numeric,numeric,numeric,text,text,jsonb,jsonb,jsonb,uuid,uuid),
 vm_private.vm_upsert_product_v3_internal(uuid,jsonb,text,uuid) FROM PUBLIC,anon,authenticated;

ALTER POLICY vm_products_member_select ON public.vm_products USING ((SELECT vm_private.vm_has_role(organization_id,ARRAY['owner','admin','finance']::text[])));
ALTER POLICY vm_product_components_member_select ON public.vm_product_components USING ((SELECT vm_private.vm_has_role(organization_id,ARRAY['owner','admin','finance']::text[])));
ALTER POLICY vm_product_variants_member_select ON public.vm_product_variants USING ((SELECT vm_private.vm_has_role(organization_id,ARRAY['owner','admin','finance']::text[])));
ALTER POLICY vm_product_variant_components_member_select ON public.vm_product_variant_components USING ((SELECT vm_private.vm_has_role(organization_id,ARRAY['owner','admin','finance']::text[])));
ALTER POLICY vm_product_versions_member_select ON public.vm_product_versions USING ((SELECT vm_private.vm_has_role(organization_id,ARRAY['owner','admin','finance']::text[])));

-- Whitelist JSON snapshots rather than removing known keys: legacy or future
-- versions may contain extra financial attributes.
CREATE FUNCTION vm_private.vm_operational_components(p_components jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path='' AS $fn$
 SELECT COALESCE(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
  'material_id',CASE WHEN pg_catalog.jsonb_typeof(e.value->'material_id')='string' THEN e.value->'material_id' END,
  'quantity',CASE WHEN pg_catalog.jsonb_typeof(e.value->'quantity') IN ('string','number') THEN e.value->'quantity' END,
  'unit',CASE WHEN pg_catalog.jsonb_typeof(e.value->'unit')='string' THEN e.value->'unit' END) ORDER BY e.ord),'[]'::jsonb)
 FROM pg_catalog.jsonb_array_elements(p_components) WITH ORDINALITY e(value,ord)
$fn$;
CREATE FUNCTION vm_private.vm_operational_variants(p_variants jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path='' AS $fn$
 SELECT COALESCE(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
  'id',CASE WHEN pg_catalog.jsonb_typeof(e.value->'id')='string' THEN e.value->'id' END,
  'name',CASE WHEN pg_catalog.jsonb_typeof(e.value->'name')='string' THEN e.value->'name' END,
  'sku',CASE WHEN pg_catalog.jsonb_typeof(e.value->'sku')='string' THEN e.value->'sku' END,
  'active',CASE WHEN pg_catalog.jsonb_typeof(e.value->'active')='boolean' THEN e.value->'active' END,
  'minimum_quantity',CASE WHEN pg_catalog.jsonb_typeof(e.value->'minimum_quantity') IN ('string','number') THEN e.value->'minimum_quantity' END,
  'composition_mode',CASE WHEN pg_catalog.jsonb_typeof(e.value->'composition_mode')='string' THEN e.value->'composition_mode' END,
  'version',CASE WHEN pg_catalog.jsonb_typeof(e.value->'version') IN ('string','number') THEN e.value->'version' END,
  'components',vm_private.vm_operational_components(CASE WHEN pg_catalog.jsonb_typeof(e.value->'components')='array' THEN e.value->'components' ELSE '[]'::jsonb END)) ORDER BY e.ord),'[]'::jsonb)
 FROM pg_catalog.jsonb_array_elements(p_variants) WITH ORDINALITY e(value,ord)
$fn$;
REVOKE ALL ON FUNCTION vm_private.vm_operational_components(jsonb),vm_private.vm_operational_variants(jsonb) FROM PUBLIC,anon,authenticated;
-- View expressions execute with the querying role; these pure allowlist helpers read no tables.
GRANT EXECUTE ON FUNCTION vm_private.vm_operational_components(jsonb),vm_private.vm_operational_variants(jsonb) TO authenticated,service_role;

CREATE OR REPLACE VIEW public.vm_products_read WITH(security_invoker=false,security_barrier=true) AS
SELECT p.id,p.organization_id,p.name,p.category,p.categories,p.subcategory,p.description,p.material_info,p.personalization_info,
 p.production_days::text AS production_days,p.pricing_mode,
 CASE WHEN (current_user='service_role' AND auth.role()='service_role') OR vm_private.vm_has_role(p.organization_id,ARRAY['owner','admin','finance']::text[]) THEN p.price::text END AS price,
 CASE WHEN (current_user='service_role' AND auth.role()='service_role') OR vm_private.vm_has_role(p.organization_id,ARRAY['owner','admin','finance']::text[]) THEN p.promo_price::text END AS promo_price,
 p.minimum_quantity::text AS minimum_quantity,p.billing_unit,p.is_catalog_visible,p.is_featured,p.custom_questions,
 p.weight_kg::text AS weight_kg,p.width_cm::text AS width_cm,p.height_cm::text AS height_cm,p.depth_cm::text AS depth_cm,p.sku,p.barcode,
 CASE WHEN (current_user='service_role' AND auth.role()='service_role') OR vm_private.vm_has_role(p.organization_id,ARRAY['owner','admin','finance']::text[]) THEN p.wholesale_tiers END AS wholesale_tiers,
 p.current_version::text AS current_version,
 CASE WHEN (current_user='service_role' AND auth.role()='service_role') OR vm_private.vm_has_role(p.organization_id,ARRAY['owner','admin','finance']::text[]) THEN v.composition_cost::text END AS current_composition_cost,
 CASE WHEN (current_user='service_role' AND auth.role()='service_role') OR vm_private.vm_has_role(p.organization_id,ARRAY['owner','admin','finance']::text[])
  THEN (SELECT COALESCE(sum(c.quantity*m.unit_cost_precise),0)::numeric(44,32)::text FROM public.vm_product_components c JOIN public.vm_materials m ON m.organization_id=c.organization_id AND m.id=c.material_id
   WHERE c.organization_id=p.organization_id AND c.product_id=p.id AND c.product_version=p.current_version) END AS current_material_cost,
 p.created_at,p.updated_at,p.inventory_mode
FROM public.vm_products p LEFT JOIN public.vm_product_versions v ON v.organization_id=p.organization_id AND v.product_id=p.id AND v.product_version=p.current_version
WHERE (current_user='service_role' AND auth.role()='service_role') OR (auth.role()='authenticated' AND (SELECT vm_private.vm_is_member(p.organization_id)));

CREATE OR REPLACE VIEW public.vm_product_components_read WITH(security_invoker=false,security_barrier=true) AS
SELECT c.organization_id,c.product_id,c.product_version::text AS product_version,c.material_id,c.component_unit,c.quantity::text AS quantity,
 CASE WHEN (current_user='service_role' AND auth.role()='service_role') OR vm_private.vm_has_role(c.organization_id,ARRAY['owner','admin','finance']::text[]) THEN c.unit_cost_snapshot::text END AS unit_cost,
 CASE WHEN (current_user='service_role' AND auth.role()='service_role') OR vm_private.vm_has_role(c.organization_id,ARRAY['owner','admin','finance']::text[]) THEN c.line_cost_precise::text END AS line_cost,c.created_at
FROM public.vm_product_components c
WHERE (current_user='service_role' AND auth.role()='service_role') OR (auth.role()='authenticated' AND (SELECT vm_private.vm_is_member(c.organization_id)));

CREATE OR REPLACE VIEW public.vm_product_variants_read WITH(security_invoker=false,security_barrier=true) AS
SELECT v.id,v.organization_id,v.product_id,v.name,v.sku,
 CASE WHEN (current_user='service_role' AND auth.role()='service_role') OR vm_private.vm_has_role(v.organization_id,ARRAY['owner','admin','finance']::text[]) THEN v.price::text END AS price,
 CASE WHEN (current_user='service_role' AND auth.role()='service_role') OR vm_private.vm_has_role(v.organization_id,ARRAY['owner','admin','finance']::text[]) THEN v.promo_price::text END AS promo_price,
 v.active,v.minimum_quantity::text AS minimum_quantity,v.composition_mode,v.current_version::text AS current_version,v.created_at,v.updated_at
FROM public.vm_product_variants v
WHERE (current_user='service_role' AND auth.role()='service_role') OR (auth.role()='authenticated' AND (SELECT vm_private.vm_is_member(v.organization_id)));

CREATE OR REPLACE VIEW public.vm_product_versions_read WITH(security_invoker=false,security_barrier=true) AS
SELECT v.organization_id,v.product_id,v.product_version::text AS product_version,v.name,v.category,v.categories,v.subcategory,
 v.description,v.material_info,v.personalization_info,v.production_days::text AS production_days,v.pricing_mode,v.billing_unit,
 CASE WHEN (current_user='service_role' AND auth.role()='service_role') OR vm_private.vm_has_role(v.organization_id,ARRAY['owner','admin','finance']::text[]) THEN v.price::text END AS price,
 CASE WHEN (current_user='service_role' AND auth.role()='service_role') OR vm_private.vm_has_role(v.organization_id,ARRAY['owner','admin','finance']::text[]) THEN v.promo_price::text END AS promo_price,
 v.minimum_quantity::text AS minimum_quantity,v.is_catalog_visible,v.is_featured,v.custom_questions,v.weight_kg::text AS weight_kg,
 v.width_cm::text AS width_cm,v.height_cm::text AS height_cm,v.depth_cm::text AS depth_cm,v.sku,v.barcode,
 CASE WHEN (current_user='service_role' AND auth.role()='service_role') OR vm_private.vm_has_role(v.organization_id,ARRAY['owner','admin','finance']::text[]) THEN v.wholesale_tiers END AS wholesale_tiers,
 CASE WHEN (current_user='service_role' AND auth.role()='service_role') OR vm_private.vm_has_role(v.organization_id,ARRAY['owner','admin','finance']::text[]) THEN v.composition_snapshot ELSE vm_private.vm_operational_components(v.composition_snapshot) END AS composition_snapshot,
 CASE WHEN (current_user='service_role' AND auth.role()='service_role') OR vm_private.vm_has_role(v.organization_id,ARRAY['owner','admin','finance']::text[]) THEN v.variants_snapshot ELSE vm_private.vm_operational_variants(v.variants_snapshot) END AS variants_snapshot,
 CASE WHEN (current_user='service_role' AND auth.role()='service_role') OR vm_private.vm_has_role(v.organization_id,ARRAY['owner','admin','finance']::text[]) THEN v.composition_cost::text END AS composition_cost,
 CASE WHEN (current_user='service_role' AND auth.role()='service_role') OR vm_private.vm_has_role(v.organization_id,ARRAY['owner','admin','finance']::text[]) THEN v.snapshot_metadata END AS snapshot_metadata,v.created_by,v.created_at
FROM public.vm_product_versions v
WHERE (current_user='service_role' AND auth.role()='service_role') OR (auth.role()='authenticated' AND (SELECT vm_private.vm_is_member(v.organization_id)));

-- Existing storage policies must not query the newly restricted base table.
-- Finance gains media access along with financial catalog editing; production
-- retains operational attachments and all members retain private reads.
ALTER POLICY vm_product_media_select ON storage.objects USING (
 bucket_id='vm-product-media' AND vm_private.vm_product_storage_path_valid(name)
 AND EXISTS (SELECT 1 FROM public.vm_products_read p WHERE p.organization_id::text=split_part(storage.objects.name,'/',1)
  AND p.id::text=split_part(storage.objects.name,'/',2) AND vm_private.vm_is_member(p.organization_id)));
ALTER POLICY vm_product_media_insert ON storage.objects WITH CHECK (
 bucket_id='vm-product-media' AND vm_private.vm_product_storage_path_valid(name)
 AND EXISTS (SELECT 1 FROM public.vm_products_read p WHERE p.organization_id::text=split_part(storage.objects.name,'/',1)
  AND p.id::text=split_part(storage.objects.name,'/',2) AND vm_private.vm_has_role(p.organization_id,ARRAY['owner','admin','finance','production']::text[])));
ALTER POLICY vm_product_media_delete ON storage.objects USING (
 bucket_id='vm-product-media' AND vm_private.vm_product_storage_path_valid(name)
 AND EXISTS (SELECT 1 FROM public.vm_products_read p WHERE p.organization_id::text=split_part(storage.objects.name,'/',1)
  AND p.id::text=split_part(storage.objects.name,'/',2) AND vm_private.vm_has_role(p.organization_id,ARRAY['owner','admin','finance','production']::text[])));

CREATE TABLE vm_private.vm_product_operation_requests (
 organization_id uuid NOT NULL, idempotency_key uuid NOT NULL, product_id uuid NOT NULL,
 expected_version integer NOT NULL, payload jsonb NOT NULL, inventory_mode text NOT NULL,
 result_version integer NOT NULL, component_count integer NOT NULL,
 PRIMARY KEY(organization_id,idempotency_key),
 FOREIGN KEY(organization_id,product_id,result_version) REFERENCES public.vm_product_versions(organization_id,product_id,product_version) ON DELETE RESTRICT
);
ALTER TABLE vm_private.vm_product_operation_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON vm_private.vm_product_operation_requests FROM PUBLIC,anon,authenticated;

-- Only operational data crosses this interface. Current prices and commercial
-- settings are fetched under the organization lock and never returned.
CREATE FUNCTION public.vm_update_product_operations(p_organization_id uuid,p_product_id uuid,p_expected_version integer,p_data jsonb,p_inventory_mode text,p_idempotency_key uuid)
RETURNS TABLE(product_id uuid,version text,component_count integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE prod public.vm_products%ROWTYPE; prior vm_private.vm_product_operation_requests%ROWTYPE; full_data jsonb; full_variants jsonb; result record;
BEGIN
 IF auth.uid() IS NULL OR auth.role() IS DISTINCT FROM 'authenticated'
  OR NOT vm_private.vm_has_role(p_organization_id,ARRAY['owner','admin','finance','production']::text[]) THEN
  RAISE EXCEPTION 'Sem permissão para alterar dados operacionais' USING ERRCODE='42501';
 END IF;
 IF p_product_id IS NULL OR p_expected_version IS NULL OR p_expected_version<1 OR p_idempotency_key IS NULL
  OR p_inventory_mode IS NULL OR p_inventory_mode NOT IN ('materials','no_stock') OR pg_catalog.jsonb_typeof(p_data) IS DISTINCT FROM 'object'
  OR (p_data - ARRAY['description','material_info','personalization_info','production_days','components','variants']) <> '{}'::jsonb
  OR NOT (p_data ?& ARRAY['description','material_info','personalization_info','production_days','components','variants'])
  OR pg_catalog.jsonb_typeof(p_data->'components') IS DISTINCT FROM 'array' OR pg_catalog.jsonb_typeof(p_data->'variants') IS DISTINCT FROM 'array'
  OR NOT vm_private.vm_components_json_valid(p_data->'components') THEN
  RAISE EXCEPTION 'Dados operacionais inválidos' USING ERRCODE='22023';
 END IF;
 IF EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(p_data->'components') e WHERE pg_catalog.jsonb_typeof(e) IS DISTINCT FROM 'object'
    OR (e-ARRAY['material_id','quantity','unit'])<>'{}'::jsonb)
  OR EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(p_data->'variants') e WHERE pg_catalog.jsonb_typeof(e) IS DISTINCT FROM 'object'
    OR (e-ARRAY['id','composition_mode','components'])<>'{}'::jsonb OR NOT (e ?& ARRAY['id','composition_mode','components'])
    OR pg_catalog.jsonb_typeof(e->'components') IS DISTINCT FROM 'array' OR e->>'composition_mode' NOT IN ('own','inherit_base')
    OR NOT vm_private.vm_components_json_valid(e->'components')
    OR (e->>'composition_mode'='inherit_base' AND pg_catalog.jsonb_array_length(e->'components')<>0)
    OR EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(e->'components') c WHERE pg_catalog.jsonb_typeof(c) IS DISTINCT FROM 'object'
      OR (c-ARRAY['material_id','quantity','unit'])<>'{}'::jsonb)) THEN
  RAISE EXCEPTION 'Composição operacional inválida' USING ERRCODE='22023';
 END IF;
 PERFORM 1 FROM public.vm_organizations o WHERE o.id=p_organization_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Organização não encontrada' USING ERRCODE='23503'; END IF;
 SELECT * INTO prior FROM vm_private.vm_product_operation_requests r WHERE r.organization_id=p_organization_id AND r.idempotency_key=p_idempotency_key;
 IF FOUND THEN
  IF prior.product_id<>p_product_id OR prior.expected_version<>p_expected_version OR prior.payload IS DISTINCT FROM p_data OR prior.inventory_mode<>p_inventory_mode THEN
   RAISE EXCEPTION 'Chave reutilizada com dados diferentes' USING ERRCODE='23505';
  END IF;
  RETURN QUERY SELECT prior.product_id,prior.result_version::text,prior.component_count; RETURN;
 END IF;
 SELECT p.* INTO prod FROM public.vm_products p WHERE p.organization_id=p_organization_id AND p.id=p_product_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Produto não encontrado nesta organização' USING ERRCODE='23503'; END IF;
 IF prod.current_version<>p_expected_version THEN RAISE EXCEPTION 'Produto atualizado: recarregue a versão antes de editar' USING ERRCODE='40001'; END IF;
 IF (SELECT count(*) FROM pg_catalog.jsonb_array_elements(p_data->'variants'))<>(SELECT count(*) FROM public.vm_product_variants v WHERE v.organization_id=p_organization_id AND v.product_id=p_product_id)
  OR (SELECT count(DISTINCT e->>'id') FROM pg_catalog.jsonb_array_elements(p_data->'variants') e)<>pg_catalog.jsonb_array_length(p_data->'variants')
  OR EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(p_data->'variants') e WHERE NOT EXISTS (
    SELECT 1 FROM public.vm_product_variants v WHERE v.organization_id=p_organization_id AND v.product_id=p_product_id AND v.id::text=e->>'id')) THEN
  RAISE EXCEPTION 'Variações não correspondem ao produto atual' USING ERRCODE='22023';
 END IF;
 SELECT COALESCE(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
  'id',v.id::text,'name',v.name,'sku',v.sku,'price',v.price::text,'promo_price',v.promo_price::text,'active',v.active,
  'minimum_quantity',v.minimum_quantity::text,'composition_mode',e->>'composition_mode','components',e->'components') ORDER BY v.id),'[]'::jsonb)
 INTO full_variants FROM pg_catalog.jsonb_array_elements(p_data->'variants') e
 JOIN public.vm_product_variants v ON v.organization_id=p_organization_id AND v.product_id=p_product_id AND v.id::text=e->>'id';
 full_data:=pg_catalog.jsonb_build_object(
  'p_name',prod.name,'p_category',prod.category,'p_categories',prod.categories,'p_subcategory',prod.subcategory,
  'p_description',p_data->>'description','p_material_info',p_data->>'material_info','p_personalization_info',p_data->>'personalization_info',
  'p_production_days',p_data->>'production_days','p_pricing_mode',prod.pricing_mode,'p_price',prod.price::text,'p_promo_price',prod.promo_price::text,
  'p_minimum_quantity',prod.minimum_quantity::text,'p_billing_unit',prod.billing_unit,'p_is_catalog_visible',prod.is_catalog_visible,
  'p_is_featured',prod.is_featured,'p_custom_questions',prod.custom_questions,'p_weight_kg',prod.weight_kg::text,'p_width_cm',prod.width_cm::text,
  'p_height_cm',prod.height_cm::text,'p_depth_cm',prod.depth_cm::text,'p_sku',prod.sku,'p_barcode',prod.barcode,
  'p_wholesale_tiers',prod.wholesale_tiers,'p_components',p_data->'components','p_variants',full_variants,'p_product_id',prod.id);
 SELECT * INTO result FROM vm_private.vm_upsert_product_v3_internal(p_organization_id,full_data,p_inventory_mode,p_idempotency_key);
 INSERT INTO vm_private.vm_product_operation_requests(organization_id,idempotency_key,product_id,expected_version,payload,inventory_mode,result_version,component_count)
 VALUES(p_organization_id,p_idempotency_key,p_product_id,p_expected_version,p_data,p_inventory_mode,result.version::integer,result.component_count);
 RETURN QUERY SELECT result.product_id,result.version,result.component_count;
END;
$fn$;
REVOKE ALL ON FUNCTION public.vm_update_product_operations(uuid,uuid,integer,jsonb,text,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.vm_update_product_operations(uuid,uuid,integer,jsonb,text,uuid) TO authenticated;

INSERT INTO public.vm_schema_migrations(version,description)
VALUES('20261031006000_product_financial_access','Protege valores do catálogo e mantém edição operacional sem preços') ON CONFLICT(version) DO NOTHING;
NOTIFY pgrst,'reload schema';
COMMIT;
