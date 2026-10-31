-- Appended to orders.sql only in the marked, isolated local PostgreSQL cluster.
RESET ROLE;
SET CONSTRAINTS ALL DEFERRED;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','authenticated')::text,true);
INSERT INTO qa_products
SELECT 'no_recipe',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),p.product_id
FROM public.vm_upsert_product_v2(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 'Local product without recipe','qa','[]'::jsonb,NULL,NULL,NULL,NULL,0,'unit',1::numeric,NULL,1::numeric,'unit',false,false,
 '[]'::jsonb,NULL,NULL,NULL,NULL,NULL,NULL,'[]'::jsonb,'[]'::jsonb,'[]'::jsonb,NULL,gen_random_uuid()) p;
RESET ROLE;
CREATE TEMP TABLE qa_recipe_before ON COMMIT DROP AS
SELECT (SELECT count(*) FROM public.vm_orders) AS orders,
 (SELECT count(*) FROM public.vm_quotes) AS quotes,
 (SELECT count(*) FROM public.vm_stock_movements) AS movements,
 (SELECT stock_quantity FROM public.vm_materials WHERE id=(SELECT material_id FROM qa_materials WHERE kind='main')) AS stock;
GRANT SELECT ON qa_recipe_before TO authenticated,anon;
SET LOCAL ROLE authenticated;
SELECT pg_temp.assert_raises('new pending physical order requires recipe','VM001',format($sql$
 SELECT * FROM public.vm_create_order(%L::uuid,jsonb_build_object('client_id',%L::uuid,'title','Local no recipe pending','order_date',CURRENT_DATE),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',%L::uuid,'quantity','1')),gen_random_uuid())$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT client_id FROM qa_clients WHERE kind='active2'),(SELECT product_id FROM qa_products WHERE kind='no_recipe')));
SELECT pg_temp.assert_raises('new physical order cannot start production without recipe','VM001',format($sql$
 SELECT * FROM public.vm_create_order(%L::uuid,jsonb_build_object('client_id',%L::uuid,'title','Local no recipe production','order_date',CURRENT_DATE,'initial_status','Em Produção'),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',%L::uuid,'quantity','1')),gen_random_uuid())$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT client_id FROM qa_clients WHERE kind='active2'),(SELECT product_id FROM qa_products WHERE kind='no_recipe')));
SELECT pg_temp.assert_raises('new physical order cannot complete directly without recipe','VM001',format($sql$
 SELECT * FROM public.vm_create_order(%L::uuid,jsonb_build_object('client_id',%L::uuid,'title','Local no recipe completed','order_date',CURRENT_DATE,'initial_status','Concluído'),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',%L::uuid,'quantity','1')),gen_random_uuid())$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT client_id FROM qa_clients WHERE kind='active2'),(SELECT product_id FROM qa_products WHERE kind='no_recipe')));
SELECT pg_temp.assert_raises('new quote cannot freeze empty product recipe','VM001',format($sql$
 SELECT * FROM public.vm_create_quote(%L::uuid,jsonb_build_object('client_id',%L::uuid,'title','Local no recipe quote','order_date',CURRENT_DATE),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',%L::uuid,'quantity','1')),CURRENT_DATE+1,NULL,gen_random_uuid(),NULL)$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT client_id FROM qa_clients WHERE kind='active2'),(SELECT product_id FROM qa_products WHERE kind='no_recipe')));
RESET ROLE;
SELECT pg_temp.assert_true((SELECT count(*) FROM public.vm_orders)=(SELECT orders FROM qa_recipe_before)
 AND (SELECT count(*) FROM public.vm_quotes)=(SELECT quotes FROM qa_recipe_before)
 AND (SELECT count(*) FROM public.vm_stock_movements)=(SELECT movements FROM qa_recipe_before)
 AND (SELECT stock_quantity FROM public.vm_materials WHERE id=(SELECT material_id FROM qa_materials WHERE kind='main'))=(SELECT stock FROM qa_recipe_before),
 'failed order and quote requests write nothing and do not touch stock');
SELECT pg_temp.pass_test('physical empty recipe rejected at order and quote creation without side effects');

SET LOCAL ROLE authenticated;
INSERT INTO qa_products
SELECT 'empty_own',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),p.product_id
FROM public.vm_upsert_product_v2(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 'Local variants with own empty','qa','[]'::jsonb,NULL,NULL,NULL,NULL,0,'variation',1::numeric,NULL,1::numeric,'unit',false,false,
 '[]'::jsonb,NULL,NULL,NULL,NULL,NULL,NULL,'[]'::jsonb,
 jsonb_build_array(jsonb_build_object('material_id',(SELECT material_id FROM qa_materials WHERE kind='main'),'quantity','0.5','unit','g')),
 jsonb_build_array(jsonb_build_object('name','Own empty','price','2','composition_mode','own','components','[]'::jsonb),
                   jsonb_build_object('name','Inherited real','price','2','composition_mode','inherit_base')),
 NULL,gen_random_uuid()) p;
INSERT INTO qa_variants SELECT 'own_empty',organization_id,id FROM public.vm_product_variants
 WHERE product_id=(SELECT product_id FROM qa_products WHERE kind='empty_own') AND name='Own empty';
INSERT INTO qa_variants SELECT 'inherited_valid',organization_id,id FROM public.vm_product_variants
 WHERE product_id=(SELECT product_id FROM qa_products WHERE kind='empty_own') AND name='Inherited real';
SELECT pg_temp.assert_raises('own variant cannot borrow base recipe','VM001',format($sql$
 SELECT * FROM public.vm_create_order(%L::uuid,jsonb_build_object('client_id',%L::uuid,'title','Local own empty','order_date',CURRENT_DATE),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',%L::uuid,'variant_id',%L::uuid,'quantity','1')),gen_random_uuid())$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT client_id FROM qa_clients WHERE kind='active2'),
 (SELECT product_id FROM qa_products WHERE kind='empty_own'),(SELECT variant_id FROM qa_variants WHERE kind='own_empty')));
CREATE TEMP TABLE qa_recipe_valid_order ON COMMIT DROP AS
SELECT order_id FROM public.vm_create_order((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='active2'),'title','Local inherited valid','order_date',CURRENT_DATE,'initial_status','Concluído'),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_products WHERE kind='empty_own'),
 'variant_id',(SELECT variant_id FROM qa_variants WHERE kind='inherited_valid'),'quantity','1')),gen_random_uuid());
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM public.vm_order_consumptions WHERE order_id=(SELECT order_id FROM qa_recipe_valid_order)),
 'valid inherited variant still consumes its base recipe');
SELECT pg_temp.pass_test('own empty variant is blocked while a real inherited recipe consumes');

CREATE TEMP TABLE qa_service_quote ON COMMIT DROP AS
SELECT quote_id,public_token FROM public.vm_create_quote((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='active2'),'title','Local manual quote','order_date',CURRENT_DATE),
 jsonb_build_array(jsonb_build_object('kind','manual_service','title','Local service','quantity','1','unit_price','2','price_override',true,'price_override_reason','local service')),
 CURRENT_DATE+1,NULL,gen_random_uuid(),NULL);
GRANT SELECT ON qa_service_quote TO anon,authenticated;
RESET ROLE;
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub','',true);
SELECT set_config('request.jwt.claim.role','anon',true);
SELECT set_config('request.jwt.claims','{"role":"anon"}',true);
CREATE TEMP TABLE qa_service_accept ON COMMIT DROP AS SELECT order_id,tracking_token FROM public.vm_approve_quote((SELECT public_token FROM qa_service_quote));
GRANT SELECT ON qa_service_accept TO authenticated,anon;
SELECT pg_temp.assert_true(public.vm_get_tracking((SELECT tracking_token FROM qa_service_accept)) IS NOT NULL,'manual quote produces a usable tracking link');
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','authenticated')::text,true);
SELECT pg_temp.assert_true((SELECT status='Concluído' FROM public.vm_set_order_status(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT order_id FROM qa_service_accept),'Concluído',NULL,gen_random_uuid())),
 'approved manual-service order can complete directly without a recipe');
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM public.vm_order_consumption_runs WHERE order_id=(SELECT order_id FROM qa_service_accept))
 AND (SELECT count(*)=0 FROM public.vm_order_consumptions WHERE order_id=(SELECT order_id FROM qa_service_accept)),
 'manual service records an idempotent zero-material run rather than fabricated stock movements');
RESET ROLE;
SELECT pg_temp.pass_test('manual quote approval, tracking and direct completion remain functional');

-- Explicit no-stock classification is a product decision, not an inference
-- from an empty recipe. It is frozen into each new order/quote snapshot.
RESET ROLE;
CREATE FUNCTION pg_temp.qa_product_input(p_name text,p_product_id uuid,p_components jsonb)
RETURNS jsonb LANGUAGE sql AS $f$
 SELECT jsonb_build_object('p_name',p_name,'p_category','qa','p_categories','[]'::jsonb,
 'p_subcategory',NULL,'p_description',NULL,'p_material_info',NULL,'p_personalization_info',NULL,
 'p_production_days',0,'p_pricing_mode','unit','p_price','5','p_promo_price',NULL,'p_minimum_quantity','1',
 'p_billing_unit','unit','p_is_catalog_visible',false,'p_is_featured',false,'p_custom_questions','[]'::jsonb,
 'p_weight_kg',NULL,'p_width_cm',NULL,'p_height_cm',NULL,'p_depth_cm',NULL,'p_sku',NULL,'p_barcode',NULL,
 'p_wholesale_tiers','[]'::jsonb,'p_components',p_components,'p_variants','[]'::jsonb,'p_product_id',p_product_id)
$f$;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','authenticated')::text,true);
CREATE TEMP TABLE qa_no_stock_product ON COMMIT DROP AS
SELECT product_id,version FROM public.vm_upsert_product_v3(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 pg_temp.qa_product_input('Local explicit no stock',NULL,'[]'::jsonb),'no_stock','40000000-0000-0000-0000-000000000801');
GRANT SELECT ON qa_no_stock_product TO authenticated,anon;
SELECT pg_temp.assert_true((SELECT inventory_mode='no_stock' FROM public.vm_products_read WHERE id=(SELECT product_id FROM qa_no_stock_product)),
 'explicit exemption is visible in the live product');
SELECT pg_temp.assert_true((SELECT product_id=(SELECT product_id FROM qa_no_stock_product) AND version='1' FROM public.vm_upsert_product_v3(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 pg_temp.qa_product_input('Local explicit no stock',NULL,'[]'::jsonb),'no_stock','40000000-0000-0000-0000-000000000801')),
 'v3 retry preserves product and version');
SELECT pg_temp.assert_raises('same nonce with different stock mode collides','23505',format($sql$
 SELECT * FROM public.vm_upsert_product_v3(%L::uuid,pg_temp.qa_product_input('Local explicit no stock',NULL,'[]'::jsonb),'materials','40000000-0000-0000-0000-000000000801')$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
CREATE TEMP TABLE qa_frozen_no_stock_order ON COMMIT DROP AS
SELECT order_id FROM public.vm_create_order((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='active2'),'title','Local frozen no stock','order_date',CURRENT_DATE),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_no_stock_product),'quantity','2')),gen_random_uuid());
GRANT SELECT ON qa_frozen_no_stock_order TO authenticated,anon;
SELECT pg_temp.assert_true((SELECT product_snapshot->>'inventory_mode'='no_stock' AND jsonb_array_length(recipe_snapshot)=0
 FROM public.vm_order_items_read WHERE order_id=(SELECT order_id FROM qa_frozen_no_stock_order)),
 'explicit no-stock mode is frozen into the pending order');
-- Edit the product back to tracked without a recipe. The old order retains
-- its exemption, while newly created orders must now supply a recipe.
SELECT * FROM public.vm_upsert_product_v3((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 pg_temp.qa_product_input('Local explicit no stock',(SELECT product_id FROM qa_no_stock_product),'[]'::jsonb),'materials',gen_random_uuid());
SELECT pg_temp.assert_true((SELECT inventory_mode='materials' FROM public.vm_products_read WHERE id=(SELECT product_id FROM qa_no_stock_product)),
 'changing classification applies to current product');
SELECT pg_temp.assert_raises('new tracked order does not inherit old no-stock exemption','VM001',format($sql$
 SELECT * FROM public.vm_create_order(%L::uuid,jsonb_build_object('client_id',%L::uuid,'title','Local changed to tracked','order_date',CURRENT_DATE),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',%L::uuid,'quantity','1')),gen_random_uuid())$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT client_id FROM qa_clients WHERE kind='active2'),(SELECT product_id FROM qa_no_stock_product)));
SELECT pg_temp.assert_true((SELECT status='Concluído' FROM public.vm_set_order_status(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT order_id FROM qa_frozen_no_stock_order),'Concluído',NULL,gen_random_uuid())),
 'earlier no-stock order can complete after product classification changes');
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM public.vm_order_consumption_runs WHERE order_id=(SELECT order_id FROM qa_frozen_no_stock_order))
 AND (SELECT count(*)=0 FROM public.vm_order_consumptions WHERE order_id=(SELECT order_id FROM qa_frozen_no_stock_order)),
 'explicit no-stock completion has a durable run and no fabricated stock movement');
SELECT pg_temp.pass_test('explicit no-stock classification is idempotent and frozen in old orders');

SELECT pg_temp.assert_raises('no-stock mode rejects active component recipe atomically','VM002',format($sql$
 SELECT * FROM public.vm_upsert_product_v3(%L::uuid,pg_temp.qa_product_input('Local inconsistent mode',NULL,
 jsonb_build_array(jsonb_build_object('material_id',%L::uuid,'quantity','1','unit','g'))),'no_stock',gen_random_uuid())$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT material_id FROM qa_materials WHERE kind='main')));
SELECT pg_temp.assert_true((SELECT count(*)=0 FROM public.vm_products WHERE name='Local inconsistent mode'),
 'inconsistent classification rolls back the entire product save');
SELECT * FROM public.vm_upsert_product_v3((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 pg_temp.qa_product_input('Local explicit no stock',(SELECT product_id FROM qa_no_stock_product),'[]'::jsonb),'no_stock',gen_random_uuid());
CREATE TEMP TABLE qa_no_stock_quote ON COMMIT DROP AS
SELECT public_token FROM public.vm_create_quote((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='active2'),'title','Local no stock quote','order_date',CURRENT_DATE),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_no_stock_product),'quantity','1')),
 CURRENT_DATE+1,NULL,gen_random_uuid(),NULL);
GRANT SELECT ON qa_no_stock_quote TO anon,authenticated;
RESET ROLE;
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub','',true);
SELECT set_config('request.jwt.claim.role','anon',true);
SELECT set_config('request.jwt.claims','{"role":"anon"}',true);
CREATE TEMP TABLE qa_no_stock_accept ON COMMIT DROP AS
SELECT order_id,tracking_token FROM public.vm_approve_quote((SELECT public_token FROM qa_no_stock_quote));
GRANT SELECT ON qa_no_stock_accept TO anon,authenticated;
SELECT pg_temp.assert_true(public.vm_get_tracking((SELECT tracking_token FROM qa_no_stock_accept)) IS NOT NULL,'no-stock quote approval yields tracking');
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','authenticated')::text,true);
SELECT pg_temp.assert_true((SELECT product_snapshot->>'inventory_mode'='no_stock' FROM public.vm_order_items_read WHERE order_id=(SELECT order_id FROM qa_no_stock_accept)),
 'approval copies the frozen no-stock decision');
SELECT pg_temp.assert_true((SELECT status='Concluído' FROM public.vm_set_order_status(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT order_id FROM qa_no_stock_accept),'Concluído',NULL,gen_random_uuid())),
 'approved no-stock product can complete without deductions');
RESET ROLE;
SELECT pg_temp.pass_test('no-stock recipe conflicts roll back; public approval and tracking preserve the explicit mode');

-- Permission, tenant, and direct-write boundaries for the new classified RPC.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_b::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','authenticated')::text,true);
SELECT pg_temp.assert_raises('viewer cannot set product mode','42501',format($sql$
 SELECT * FROM public.vm_upsert_product_v3(%L::uuid,pg_temp.qa_product_input('Local viewer denied',NULL,'[]'::jsonb),'no_stock',gen_random_uuid())$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.assert_raises('direct product mode update forbidden','42501',format($sql$
 UPDATE public.vm_products SET inventory_mode='no_stock' WHERE id=%L::uuid$sql$,(SELECT product_id FROM qa_products WHERE kind='base')));
RESET ROLE;
SELECT pg_temp.assert_true(has_function_privilege('authenticated','public.vm_upsert_product_v3(uuid,jsonb,text,uuid)','EXECUTE')
 AND NOT has_function_privilege('anon','public.vm_upsert_product_v3(uuid,jsonb,text,uuid)','EXECUTE')
 AND NOT has_table_privilege('authenticated','vm_private.vm_product_inventory_requests','SELECT'),
 'new function and nonce table have least-privilege grants');
SELECT pg_temp.pass_test('product classification requires an authorized organization member and forbids direct writes');
-- A legacy v2 edit must not silently keep a no-stock exemption on a new
-- version; a v3 replay must not change a later explicit classification.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','authenticated')::text,true);
SELECT * FROM public.vm_upsert_product_v2(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 'Local explicit no stock','qa','[]'::jsonb,NULL,NULL,NULL,NULL,0,'unit',5::numeric,NULL,1::numeric,'unit',false,false,
 '[]'::jsonb,NULL,NULL,NULL,NULL,NULL,NULL,'[]'::jsonb,'[]'::jsonb,'[]'::jsonb,
 (SELECT product_id FROM qa_no_stock_product),gen_random_uuid());
SELECT pg_temp.assert_true((SELECT inventory_mode='materials' FROM public.vm_products_read WHERE id=(SELECT product_id FROM qa_no_stock_product)),
 'old v2 client resets a product edit to tracked');
SELECT * FROM public.vm_upsert_product_v3((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 pg_temp.qa_product_input('Local explicit no stock',NULL,'[]'::jsonb),'no_stock','40000000-0000-0000-0000-000000000801');
SELECT pg_temp.assert_true((SELECT inventory_mode='materials' FROM public.vm_products_read WHERE id=(SELECT product_id FROM qa_no_stock_product)),
 'old v3 replay must not restore a prior classification after a later edit');
RESET ROLE;
SELECT pg_temp.pass_test('legacy v2 edit fails closed and old v3 replay never reclassifies current product');
