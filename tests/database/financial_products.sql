SET CONSTRAINTS ALL DEFERRED;
RESET ROLE;
-- Preserve exact financial values for comparisons after operational edits.
CREATE TEMP TABLE qa_before_product ON COMMIT DROP AS
SELECT id,current_version,price,promo_price,wholesale_tiers,minimum_quantity,pricing_mode FROM public.vm_products WHERE id=(SELECT product_id FROM qa_products WHERE kind='variant');
CREATE TEMP TABLE qa_before_variants ON COMMIT DROP AS
SELECT id,price,promo_price,minimum_quantity,active FROM public.vm_product_variants WHERE product_id=(SELECT id FROM qa_before_product);
GRANT SELECT ON qa_before_product,qa_before_variants TO authenticated,anon;
UPDATE public.vm_memberships SET role='production' WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)) AND user_id=(SELECT user_b FROM qa_identity);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_b::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','authenticated')::text,true);
SELECT pg_temp.assert_true((SELECT count(*)=0 FROM public.vm_products WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)))
 AND (SELECT count(*)=0 FROM public.vm_product_components WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)))
 AND (SELECT count(*)=0 FROM public.vm_product_variants WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)))
 AND (SELECT count(*)=0 FROM public.vm_product_variant_components WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)))
 AND (SELECT count(*)=0 FROM public.vm_product_versions WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))), 'raw catalog financial tables deny production');
SELECT pg_temp.assert_true((SELECT price IS NULL AND promo_price IS NULL AND wholesale_tiers IS NULL AND current_composition_cost IS NULL AND current_material_cost IS NULL
 FROM public.vm_products_read WHERE id=(SELECT product_id FROM qa_products WHERE kind='variant'))
 AND (SELECT count(*)=2 FROM public.vm_product_variants_read WHERE product_id=(SELECT product_id FROM qa_products WHERE kind='variant') AND price IS NULL AND promo_price IS NULL)
 AND (SELECT count(*)>0 FROM public.vm_product_components_read WHERE product_id=(SELECT product_id FROM qa_products WHERE kind='variant') AND unit_cost IS NULL AND line_cost IS NULL), 'operational product views mask amounts without hiding recipes');
SELECT pg_temp.assert_true((SELECT price IS NULL AND promo_price IS NULL AND wholesale_tiers IS NULL AND composition_cost IS NULL AND snapshot_metadata IS NULL
 AND NOT (composition_snapshot::text ~ 'unit_cost|line_cost|price|cost') AND NOT (variants_snapshot::text ~ 'unit_cost|line_cost|price|cost')
 AND jsonb_array_length(composition_snapshot)>0 AND jsonb_array_length(variants_snapshot)=2
 FROM public.vm_product_versions_read WHERE product_id=(SELECT product_id FROM qa_products WHERE kind='variant') ORDER BY product_version::integer DESC LIMIT 1),
 'production gets allowlisted snapshot JSON without prices or costs');
SELECT pg_temp.assert_raises('production cannot invoke priced v3','42501',format($sql$SELECT * FROM public.vm_upsert_product_v3(%L::uuid,'{}'::jsonb,'materials',gen_random_uuid())$sql$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.assert_raises('production cannot invoke priced v2','42501',format($sql$SELECT * FROM public.vm_upsert_product_v2(%L::uuid,'x','x')$sql$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.assert_raises('production cannot call private product implementation','42501',format($sql$SELECT * FROM vm_private.vm_upsert_product_v3_internal(%L::uuid,'{}'::jsonb,'materials',gen_random_uuid())$sql$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.assert_true(NOT (vm_private.vm_operational_components('[{"material_id":{"price":"999"},"quantity":{"cost":"999"},"unit":{"price":"999"}}]'::jsonb)::text ~ '999')
 AND NOT (vm_private.vm_operational_variants('[{"id":{"price":"999"},"name":{"cost":"999"},"components":[{"unit":{"price":"999"}}]}]'::jsonb)::text ~ '999'),
 'nested unexpected JSON objects cannot bypass the snapshot allowlist');
SELECT pg_temp.pass_test('production sees allowlisted product recipes and no raw financial values');

CREATE TEMP TABLE qa_ops_input ON COMMIT DROP AS
SELECT jsonb_build_object('description','Updated local production description','material_info','Cut and fold',
 'personalization_info',NULL,'production_days',3,
 'components',jsonb_build_array(jsonb_build_object('material_id',(SELECT material_id FROM qa_materials WHERE kind='main'),'quantity','0.33333333','unit','g')),
 'variants',(SELECT jsonb_agg(jsonb_build_object('id',v.id,'composition_mode',v.composition_mode,
   'components',CASE WHEN v.composition_mode='own' THEN jsonb_build_array(jsonb_build_object('material_id',(SELECT material_id FROM qa_materials WHERE kind='main'),'quantity','0.25','unit','g')) ELSE '[]'::jsonb END) ORDER BY v.id)
 FROM public.vm_product_variants_read v WHERE v.product_id=(SELECT product_id FROM qa_products WHERE kind='variant'))) AS data;
GRANT SELECT ON qa_ops_input TO authenticated,anon;
CREATE TEMP TABLE qa_ops_result ON COMMIT DROP AS SELECT * FROM public.vm_update_product_operations(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT product_id FROM qa_products WHERE kind='variant'),
 (SELECT current_version FROM qa_before_product),(SELECT data FROM qa_ops_input),'materials','40000000-0000-0000-0000-000000000960');
GRANT SELECT ON qa_ops_result TO authenticated,anon,service_role;
SELECT pg_temp.assert_true((SELECT version::integer=(SELECT current_version+1 FROM qa_before_product) AND component_count=1 FROM qa_ops_result)
 AND (SELECT description='Updated local production description' AND production_days='3' AND price IS NULL FROM public.vm_products_read WHERE id=(SELECT product_id FROM qa_ops_result))
 AND (SELECT quantity::numeric=0.33333333 FROM public.vm_product_components_read WHERE product_id=(SELECT product_id FROM qa_ops_result) AND product_version=(SELECT version FROM qa_ops_result)),
 'production changes operational fields and fractional recipe with no financial output');
SELECT pg_temp.assert_true((SELECT version=(SELECT version FROM qa_ops_result) FROM public.vm_update_product_operations(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT product_id FROM qa_products WHERE kind='variant'),
 (SELECT current_version FROM qa_before_product),(SELECT data FROM qa_ops_input),'materials','40000000-0000-0000-0000-000000000960')),
 'identical operation retry returns same version');
SELECT pg_temp.assert_raises('same nonce with altered operation','23505',format($sql$SELECT * FROM public.vm_update_product_operations(%L::uuid,%L::uuid,%s,%L::jsonb,'materials','40000000-0000-0000-0000-000000000960')$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT product_id FROM qa_products WHERE kind='variant'),(SELECT current_version FROM qa_before_product),(SELECT (data||'{"production_days":4}'::jsonb)::text FROM qa_ops_input)));
SELECT pg_temp.assert_raises('stale version is rejected','40001',format($sql$SELECT * FROM public.vm_update_product_operations(%L::uuid,%L::uuid,%s,%L::jsonb,'materials',gen_random_uuid())$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT product_id FROM qa_products WHERE kind='variant'),(SELECT current_version FROM qa_before_product),(SELECT data::text FROM qa_ops_input)));
RESET ROLE;
SELECT pg_temp.assert_true((SELECT p.price=b.price AND p.promo_price IS NOT DISTINCT FROM b.promo_price AND p.wholesale_tiers=b.wholesale_tiers AND p.minimum_quantity=b.minimum_quantity AND p.pricing_mode=b.pricing_mode
 FROM public.vm_products p JOIN qa_before_product b ON b.id=p.id)
 AND NOT EXISTS(SELECT 1 FROM public.vm_product_variants v JOIN qa_before_variants b USING(id) WHERE v.price<>b.price OR v.promo_price IS DISTINCT FROM b.promo_price OR v.minimum_quantity IS DISTINCT FROM b.minimum_quantity OR v.active<>b.active),
 'operational edit preserves product and variant prices and commercial terms');
SELECT pg_temp.pass_test('operational editing preserves prices, precision, optimistic locking and idempotency');

SET LOCAL ROLE authenticated;
SELECT pg_temp.assert_raises('top-level financial field is rejected','22023',format($sql$SELECT * FROM public.vm_update_product_operations(%L::uuid,%L::uuid,%s,%L::jsonb,'materials',gen_random_uuid())$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT product_id FROM qa_products WHERE kind='variant'),(SELECT version::integer FROM qa_ops_result),(SELECT (data||'{"price":"0"}'::jsonb)::text FROM qa_ops_input)));
SELECT pg_temp.assert_raises('nested financial field is rejected','22023',format($sql$SELECT * FROM public.vm_update_product_operations(%L::uuid,%L::uuid,%s,%L::jsonb,'materials',gen_random_uuid())$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT product_id FROM qa_products WHERE kind='variant'),(SELECT version::integer FROM qa_ops_result),
 (SELECT jsonb_set(data,'{components,0,unit_cost}','"0"'::jsonb,true)::text FROM qa_ops_input)));
SELECT pg_temp.assert_raises('no-stock recipe is rejected atomically','VM002',format($sql$SELECT * FROM public.vm_update_product_operations(%L::uuid,%L::uuid,%s,%L::jsonb,'no_stock',gen_random_uuid())$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT product_id FROM qa_products WHERE kind='variant'),(SELECT version::integer FROM qa_ops_result),(SELECT data::text FROM qa_ops_input)));
SELECT pg_temp.assert_true((SELECT current_version=(SELECT version FROM qa_ops_result) FROM public.vm_products_read WHERE id=(SELECT product_id FROM qa_ops_result)), 'invalid attempts do not create a new version');
SELECT pg_temp.assert_raises('variant financial injection is rejected','22023',format($sql$SELECT * FROM public.vm_update_product_operations(%L::uuid,%L::uuid,%s,%L::jsonb,'materials',gen_random_uuid())$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT product_id FROM qa_products WHERE kind='variant'),(SELECT version::integer FROM qa_ops_result),
 (SELECT jsonb_set(data,'{variants,0,price}','"0"'::jsonb,true)::text FROM qa_ops_input)));
SELECT pg_temp.pass_test('financial field injection and inconsistent no-stock classification are rejected atomically');

RESET ROLE;
UPDATE public.vm_memberships SET role='viewer' WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)) AND user_id=(SELECT user_b FROM qa_identity);
SET LOCAL ROLE authenticated;
SELECT pg_temp.assert_true((SELECT price IS NULL AND current_composition_cost IS NULL FROM public.vm_products_read WHERE id=(SELECT product_id FROM qa_ops_result)), 'viewer sees no catalog amounts');
SELECT pg_temp.assert_raises('downgraded viewer cannot replay operation','42501',format($sql$SELECT * FROM public.vm_update_product_operations(%L::uuid,%L::uuid,%s,%L::jsonb,'materials','40000000-0000-0000-0000-000000000960')$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT product_id FROM qa_products WHERE kind='variant'),(SELECT current_version FROM qa_before_product),(SELECT data::text FROM qa_ops_input)));
RESET ROLE;
UPDATE public.vm_memberships SET role='finance' WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)) AND user_id=(SELECT user_b FROM qa_identity);
SET LOCAL ROLE authenticated;
SELECT pg_temp.assert_true((SELECT price::numeric=10 AND current_composition_cost IS NOT NULL FROM public.vm_products_read WHERE id=(SELECT product_id FROM qa_ops_result))
 AND (SELECT count(*)=2 FROM public.vm_product_variants WHERE product_id=(SELECT product_id FROM qa_ops_result))
 AND (SELECT variants_snapshot::text ~ 'price' AND composition_snapshot::text ~ 'unit_cost' FROM public.vm_product_versions_read WHERE product_id=(SELECT product_id FROM qa_ops_result) ORDER BY product_version::integer DESC LIMIT 1),
 'finance sees full original snapshot and raw catalog');
SELECT pg_temp.assert_true((SELECT normal_price::numeric=7 FROM public.vm_upsert_product_v2(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)), 'Finance new product','qa','[]'::jsonb,
 NULL,NULL,NULL,NULL,0,'unit',7,NULL,1,'unit',false,false,'[]'::jsonb,NULL,NULL,NULL,NULL,NULL,NULL,'[]'::jsonb,
 '[]'::jsonb,'[]'::jsonb,NULL,'40000000-0000-0000-0000-000000000961')),
 'finance can edit commercial catalog');
-- Finanças pode usar a API v3 também, e anexar arquivos como Produção.
SELECT pg_temp.assert_true((SELECT version='1' AND normal_price::numeric=9 FROM public.vm_upsert_product_v3(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('p_name','Finance v3','p_category','qa','p_categories','[]'::jsonb,'p_subcategory',NULL,
 'p_description',NULL,'p_material_info',NULL,'p_personalization_info',NULL,'p_production_days',0,'p_pricing_mode','unit',
 'p_price','9','p_promo_price',NULL,'p_minimum_quantity','1','p_billing_unit','unit','p_is_catalog_visible',false,
 'p_is_featured',false,'p_custom_questions','[]'::jsonb,'p_weight_kg',NULL,'p_width_cm',NULL,'p_height_cm',NULL,'p_depth_cm',NULL,
 'p_sku',NULL,'p_barcode',NULL,'p_wholesale_tiers','[]'::jsonb,'p_components','[]'::jsonb,'p_variants','[]'::jsonb,'p_product_id',NULL),
 'materials','40000000-0000-0000-0000-000000000962')), 'finance can call full v3 commercial API');
INSERT INTO storage.objects(bucket_id,name,owner_id,metadata)
VALUES ('vm-product-media',(SELECT organization_id::text FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)) || '/' || (SELECT product_id::text FROM qa_ops_result) || '/finance.pdf',
 (SELECT user_b FROM qa_identity),'{"mimetype":"application/pdf","size":"10"}'::jsonb);
SELECT pg_temp.assert_true((SELECT file_id IS NOT NULL FROM public.vm_register_product_file(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT product_id FROM qa_ops_result),'production',
 (SELECT organization_id::text FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)) || '/' || (SELECT product_id::text FROM qa_ops_result) || '/finance.pdf','application/pdf',10,'finance.pdf')),
 'finance can register a private product file');
SELECT pg_temp.pass_test('viewer cannot mutate and finance retains complete catalog access');

RESET ROLE;
UPDATE public.vm_memberships SET role='production' WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)) AND user_id=(SELECT user_b FROM qa_identity);
SET LOCAL ROLE authenticated;
-- Base-table RLS must not break production media insert/select or registration.
INSERT INTO storage.objects(bucket_id,name,owner_id,metadata)
VALUES ('vm-product-media',(SELECT organization_id::text FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)) || '/' || (SELECT product_id::text FROM qa_ops_result) || '/production.pdf',
 (SELECT user_b FROM qa_identity),'{"mimetype":"application/pdf","size":"11"}'::jsonb);
SELECT pg_temp.assert_true((SELECT file_id IS NOT NULL FROM public.vm_register_product_file(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT product_id FROM qa_ops_result),'production',
 (SELECT organization_id::text FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)) || '/' || (SELECT product_id::text FROM qa_ops_result) || '/production.pdf','application/pdf',11,'production.pdf'))
 AND (SELECT count(*)=2 FROM storage.objects WHERE bucket_id='vm-product-media'), 'production can register and view operational files');
SELECT pg_temp.pass_test('private media remains available for production and finance');
SELECT set_config('request.jwt.claim.role','service_role',true);
SELECT pg_temp.assert_true((SELECT count(*)=0 FROM public.vm_products_read WHERE id=(SELECT product_id FROM qa_ops_result) AND price IS NOT NULL), 'spoofed service claim cannot reveal price');
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','authenticated')::text,true);
SELECT pg_temp.assert_true((SELECT count(*)=0 FROM public.vm_products_read WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_b FROM qa_identity))), 'no cross-tenant products');
SET LOCAL ROLE anon;
SELECT pg_temp.assert_raises('anon cannot read product view','42501','SELECT * FROM public.vm_products_read');
SELECT pg_temp.assert_raises('anon cannot read product versions','42501','SELECT * FROM public.vm_product_versions_read');
RESET ROLE;
SELECT pg_temp.assert_true((SELECT bool_and(reloptions @> ARRAY['security_invoker=false','security_barrier=true']) FROM pg_class WHERE oid IN ('public.vm_products_read'::regclass,'public.vm_product_components_read'::regclass,'public.vm_product_variants_read'::regclass,'public.vm_product_versions_read'::regclass)), 'product views are security barriers');
SELECT pg_temp.pass_test('product views isolate tenants, anonymous users and forged service claims');

-- Existing order snapshots remain immutable; new financial orders use the new recipe.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','authenticated')::text,true);
CREATE TEMP TABLE qa_post_edit_order ON COMMIT DROP AS SELECT order_id FROM public.vm_create_order(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='active2'),'title','Updated recipe','order_date',CURRENT_DATE),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_ops_result),'variant_id',(SELECT variant_id FROM qa_variants WHERE kind='own'),'quantity','1')),
 '40000000-0000-0000-0000-000000000963');
SELECT pg_temp.assert_true((SELECT quantity_snapshot=0.25 FROM public.vm_order_item_materials WHERE order_id=(SELECT order_id FROM qa_post_edit_order))
 AND (SELECT quantity_snapshot=3 FROM public.vm_order_item_materials WHERE order_id=(SELECT order_id FROM qa_resolution WHERE kind='own')),
 'new orders use edited variant recipe without rewriting old orders');
SELECT pg_temp.pass_test('new orders use new operational recipes while frozen orders stay unchanged');

RESET ROLE;
GRANT SELECT ON public.vm_products_read,public.vm_product_components_read,public.vm_product_variants_read,public.vm_product_versions_read TO service_role;
SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claim.role','service_role',true);
SELECT set_config('request.jwt.claims','{"role":"service_role"}',true);
SELECT pg_temp.assert_true((SELECT price::numeric=10 FROM public.vm_products_read WHERE id=(SELECT product_id FROM qa_ops_result))
 AND (SELECT variants_snapshot::text ~ 'price' FROM public.vm_product_versions_read WHERE product_id=(SELECT product_id FROM qa_ops_result) ORDER BY product_version::integer DESC LIMIT 1),
 'genuine service role still sees integration data');
RESET ROLE;
SELECT pg_temp.pass_test('genuine privileged integration access remains available');
