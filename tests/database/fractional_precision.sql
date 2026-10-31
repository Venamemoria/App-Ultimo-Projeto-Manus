-- Appended to orders.sql by the marked local fractional_precision suite.
-- Exercises the actual RPCs and ledger, never the connected production project.
SET CONSTRAINTS ALL DEFERRED;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','owner')::text,true);

INSERT INTO qa_products
SELECT 'tiny',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),p.product_id
FROM public.vm_upsert_product_v2(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 'Produto fracionário QA','orders','[]'::jsonb,NULL,NULL,NULL,NULL,0,'unit',
 1::numeric,NULL,0.00000001::numeric,'unit',false,false,
 '[]'::jsonb,NULL,NULL,NULL,NULL,'ORD-TINY',NULL,'[]'::jsonb,
 jsonb_build_array(jsonb_build_object('material_id',(SELECT material_id FROM qa_materials WHERE kind='main'),'quantity','0.00001','unit','g')),
 '[]'::jsonb,NULL,'40000000-0000-0000-0000-000000000301'::uuid) p;
CREATE TEMP TABLE qa_fraction_before ON COMMIT DROP AS
SELECT stock_quantity FROM public.vm_materials WHERE id=(SELECT material_id FROM qa_materials WHERE kind='main');
INSERT INTO qa_orders
SELECT 'tiny',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),r.order_id,'40000000-0000-0000-0000-000000000302'::uuid
FROM public.vm_create_order(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='active2'),'title','QA tiny exact','order_date','2026-10-29','initial_status','Em Produção'),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_products WHERE kind='tiny'),'quantity','0.0001')),
 '40000000-0000-0000-0000-000000000302'::uuid) r;
SELECT pg_temp.assert_true(
 (SELECT quantity FROM public.vm_order_consumptions WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='tiny'))=0.000000001::numeric
 AND (SELECT quantity_delta FROM public.vm_stock_movements WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='tiny') AND movement_type='order_deduction')=-0.000000001::numeric
 AND (SELECT stock_quantity FROM qa_fraction_before)-(SELECT stock_quantity FROM public.vm_materials WHERE id=(SELECT material_id FROM qa_materials WHERE kind='main'))=0.000000001::numeric,
 'nine-decimal product and real stock deduction remain exact');
SELECT pg_temp.pass_test('fractional recipe times fractional quantity deducts a nonzero ninth decimal');

-- An ordinary stock adjustment must still work after a sub-eight-place balance.
SELECT * FROM public.vm_adjust_material_stock_safe(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 (SELECT material_id FROM qa_materials WHERE kind='main'),0.1::numeric,'ajuste QA',
 '40000000-0000-0000-0000-000000000303'::uuid);
SELECT pg_temp.assert_true(
 (SELECT stock_quantity FROM public.vm_materials WHERE id=(SELECT material_id FROM qa_materials WHERE kind='main'))=(SELECT stock_quantity FROM qa_fraction_before)-0.000000001::numeric+0.1::numeric,
 'adjustment preserves a high-precision existing balance');
SELECT * FROM public.vm_receive_material(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 (SELECT material_id FROM qa_materials WHERE kind='main'),0.2::numeric,20::numeric,10::numeric,'entrada QA',
 '40000000-0000-0000-0000-000000000309'::uuid);
SELECT * FROM public.vm_create_material_purchase(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 (SELECT material_id FROM qa_materials WHERE kind='main'),0.3::numeric,1.20::numeric,DATE '2026-10-29','pending',NULL::date,
 '40000000-0000-0000-0000-000000000310'::uuid,NULL::uuid,'compra QA');
SELECT pg_temp.assert_true(
 (SELECT stock_quantity FROM public.vm_materials WHERE id=(SELECT material_id FROM qa_materials WHERE kind='main'))=(SELECT stock_quantity FROM qa_fraction_before)-0.000000001::numeric+0.6::numeric,
 'receipt and purchase preserve a high-precision existing balance');
SELECT * FROM public.vm_set_order_status(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 (SELECT order_id FROM qa_orders WHERE kind='tiny'),'Concluído',NULL,'40000000-0000-0000-0000-000000000304'::uuid);
SELECT pg_temp.assert_true((SELECT count(*) FROM public.vm_stock_movements WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='tiny') AND movement_type='order_deduction')=1,
 'later completion does not deduct twice');
SELECT * FROM public.vm_set_order_status(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 (SELECT order_id FROM qa_orders WHERE kind='tiny'),'Cancelado','QA retorno físico','40000000-0000-0000-0000-000000000305'::uuid);
SELECT * FROM public.vm_record_order_return(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 (SELECT order_id FROM qa_orders WHERE kind='tiny'),'material conferido',
 jsonb_build_array(jsonb_build_object('material_id',(SELECT material_id FROM qa_materials WHERE kind='main'),'quantity','0.000000001')),
 '40000000-0000-0000-0000-000000000306'::uuid);
SELECT pg_temp.assert_true(
 (SELECT stock_quantity FROM public.vm_materials WHERE id=(SELECT material_id FROM qa_materials WHERE kind='main'))=(SELECT stock_quantity FROM qa_fraction_before)+0.6::numeric
 AND (SELECT returned_quantity::numeric FROM public.vm_order_returns_read WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='tiny'))=0.000000001::numeric,
 'return restores the exact ninth decimal and read view retains it');
SELECT pg_temp.pass_test('fractional balance supports adjustment status replay and exact physical return');

-- Four eight-place inputs can generate 36 fractional places for material use.
INSERT INTO qa_products
SELECT 'fractional_m2',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),p.product_id
FROM public.vm_upsert_product_v2(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 'Área fracionária QA','orders','[]'::jsonb,NULL,NULL,NULL,NULL,0,'m2',
 1::numeric,NULL,0.00000001::numeric,'m2',false,false,
 '[]'::jsonb,NULL,NULL,NULL,NULL,'ORD-FRACTION-M2',NULL,'[]'::jsonb,
 jsonb_build_array(jsonb_build_object('material_id',(SELECT material_id FROM qa_materials WHERE kind='main'),'quantity','0.00000001','unit','g')),
 '[]'::jsonb,NULL,'40000000-0000-0000-0000-000000000307'::uuid) p;
INSERT INTO qa_orders
SELECT 'fractional_m2',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),r.order_id,'40000000-0000-0000-0000-000000000308'::uuid
FROM public.vm_create_order(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='active2'),'title','QA fractional area','order_date','2026-10-29','initial_status','Concluído'),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_products WHERE kind='fractional_m2'),'quantity','1.00000001',
   'dimensions',jsonb_build_object('width_cm','100.00000001','height_cm','100.00000001'))),
 '40000000-0000-0000-0000-000000000308'::uuid) r;
SELECT pg_temp.assert_true(
 (SELECT consumption_quantity FROM public.vm_order_item_materials WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='fractional_m2'))
 = 0.00000001::numeric*1.00000001::numeric*100.00000001::numeric*100.00000001::numeric*0.0001::numeric
 AND (SELECT quantity FROM public.vm_order_consumptions WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='fractional_m2'))
 = 0.00000001::numeric*1.00000001::numeric*100.00000001::numeric*100.00000001::numeric*0.0001::numeric,
 'area and four fractional inputs retain every decimal through direct completion');
SELECT pg_temp.pass_test('area factor billed quantity recipe and direct completion retain 36-place arithmetic');

CREATE TEMP TABLE qa_fraction_quote(quote_id uuid,token uuid) ON COMMIT DROP;
CREATE TEMP TABLE qa_fraction_accept(order_id uuid,tracking_token uuid) ON COMMIT DROP;
GRANT SELECT,INSERT ON qa_fraction_quote,qa_fraction_accept TO authenticated,anon;
INSERT INTO qa_fraction_quote
SELECT q.quote_id,q.public_token FROM public.vm_create_quote(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='active2'),'title','QA quote tiny','order_date',CURRENT_DATE),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_products WHERE kind='tiny'),'quantity','0.0001')),
 CURRENT_DATE+7,NULL,'40000000-0000-0000-0000-000000000311'::uuid,NULL::uuid) q;
RESET ROLE;
SELECT pg_temp.assert_true((SELECT consumption_quantity FROM public.vm_quote_item_materials WHERE quote_id=(SELECT quote_id FROM qa_fraction_quote))=0.000000001::numeric,
 'quote stores the exact fractional recipe');
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.role','anon',true);
INSERT INTO qa_fraction_accept SELECT order_id,tracking_token FROM public.vm_approve_quote((SELECT token FROM qa_fraction_quote));
RESET ROLE;
SELECT pg_temp.assert_true(
 (SELECT consumption_quantity FROM public.vm_order_item_materials WHERE order_id=(SELECT order_id FROM qa_fraction_accept))=0.000000001::numeric
 AND (SELECT count(*) FROM public.vm_order_consumptions WHERE order_id=(SELECT order_id FROM qa_fraction_accept))=0,
 'approval copies precise snapshot and does not consume prematurely');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','owner')::text,true);
SELECT * FROM public.vm_set_order_status(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 (SELECT order_id FROM qa_fraction_accept),'Concluído',NULL,'40000000-0000-0000-0000-000000000312'::uuid);
SELECT pg_temp.assert_true((SELECT quantity FROM public.vm_order_consumptions WHERE order_id=(SELECT order_id FROM qa_fraction_accept))=0.000000001::numeric,
 'approved quote direct completion deducts its exact frozen fraction');
SELECT pg_temp.pass_test('public approval preserves fractional recipe until exactly-once direct completion');
RESET ROLE;
SET CONSTRAINTS ALL IMMEDIATE;

-- The following groups require 20261030011000_fractional_unit_cost and exercise
-- precise division through the real material, product, order and quote RPCs.
SET CONSTRAINTS ALL DEFERRED;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','owner')::text,true);
INSERT INTO qa_materials
SELECT 'cost_third',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),m.material_id,m.opening_movement_id,m.stock_quantity,m.unit_cost
FROM public.vm_create_material(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 'Material custo terço QA','g',1::numeric,3::numeric,100::numeric,0::numeric,
 'orders',NULL::uuid,'40000000-0000-0000-0000-000000000401'::uuid) m;
SELECT pg_temp.assert_true(
 (SELECT unit_cost FROM qa_materials WHERE kind='cost_third')=0.333333333333333333333333::numeric
 AND (SELECT unit_cost::numeric FROM public.vm_materials_read WHERE id=(SELECT material_id FROM qa_materials WHERE kind='cost_third'))=0.333333333333333333333333::numeric,
 'material RPC and text read view return 24-place rounded unit cost');
SELECT pg_temp.pass_test('material division and read API retain 24 decimal places');

INSERT INTO qa_products
SELECT 'cost_m2',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),p.product_id
FROM public.vm_upsert_product_v2(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 'Produto custo m2 QA','orders','[]'::jsonb,NULL,NULL,NULL,NULL,0,'m2',
 1::numeric,NULL,0.00000001::numeric,'m2',false,false,
 '[]'::jsonb,NULL,NULL,NULL,NULL,'ORD-COST-M2',NULL,'[]'::jsonb,
 jsonb_build_array(jsonb_build_object('material_id',(SELECT material_id FROM qa_materials WHERE kind='cost_third'),'quantity','0.00000001','unit','g')),
 '[]'::jsonb,NULL,'40000000-0000-0000-0000-000000000402'::uuid) p;
SELECT pg_temp.assert_true(
 (SELECT unit_cost_snapshot FROM public.vm_product_components WHERE product_id=(SELECT product_id FROM qa_products WHERE kind='cost_m2'))=0.333333333333333333333333::numeric
 AND (SELECT line_cost_precise FROM public.vm_product_components WHERE product_id=(SELECT product_id FROM qa_products WHERE kind='cost_m2'))=0.00000000333333333333333333333333::numeric
 AND (SELECT line_cost::numeric FROM public.vm_product_components_read WHERE product_id=(SELECT product_id FROM qa_products WHERE kind='cost_m2'))=0.00000000333333333333333333333333::numeric
 AND (SELECT composition_cost FROM public.vm_product_versions WHERE product_id=(SELECT product_id FROM qa_products WHERE kind='cost_m2'))=0.00000000333333333333333333333333::numeric
 AND (SELECT (composition_snapshot->0->>'line_cost')::numeric FROM public.vm_product_versions WHERE product_id=(SELECT product_id FROM qa_products WHERE kind='cost_m2'))=0.00000000333333333333333333333333::numeric,
 'new product version saves the exact 32-place recipe instead of zero');
SELECT pg_temp.pass_test('fractional product snapshots preserve precise unit and line costs');

INSERT INTO qa_orders
SELECT 'cost_m2',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),r.order_id,'40000000-0000-0000-0000-000000000403'::uuid
FROM public.vm_create_order(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='active2'),'title','QA cost m2','order_date','2026-10-29','initial_status','Concluído'),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_products WHERE kind='cost_m2'),
   'quantity','0.12345678','dimensions',jsonb_build_object('width_cm','9.87654321','height_cm','1.23456789'))),
 '40000000-0000-0000-0000-000000000403'::uuid) r;
SELECT pg_temp.assert_true(
 (SELECT consumption_cost FROM public.vm_order_item_materials WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='cost_m2'))=
  (0.00000001::numeric*0.12345678::numeric*9.87654321::numeric*1.23456789::numeric*0.0001::numeric*0.333333333333333333333333::numeric)
 AND (SELECT total_composition_cost FROM public.vm_order_items WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='cost_m2'))=
  (SELECT consumption_cost FROM public.vm_order_item_materials WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='cost_m2'))
 AND (SELECT consumption_cost FROM public.vm_order_item_materials WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='cost_m2'))<>
  round((SELECT consumption_cost FROM public.vm_order_item_materials WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='cost_m2')),44)
 AND (SELECT count(*) FROM public.vm_order_consumptions WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='cost_m2'))=1,
 'm2 order preserves significant cost digits beyond the old 44-place limit and deducts once');
SELECT pg_temp.pass_test('m2 order preserves 60-place cost arithmetic and completes once');

CREATE TEMP TABLE qa_cost_quote(quote_id uuid,token uuid) ON COMMIT DROP;
CREATE TEMP TABLE qa_cost_accepted(order_id uuid,tracking_token uuid) ON COMMIT DROP;
GRANT SELECT,INSERT ON qa_cost_quote,qa_cost_accepted TO authenticated,anon;
INSERT INTO qa_cost_quote
SELECT q.quote_id,q.public_token FROM public.vm_create_quote(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='active2'),'title','QA cost quote','order_date',CURRENT_DATE),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_products WHERE kind='cost_m2'),
   'quantity','0.12345678','dimensions',jsonb_build_object('width_cm','9.87654321','height_cm','1.23456789'))),
 CURRENT_DATE+7,NULL,'40000000-0000-0000-0000-000000000404'::uuid,NULL::uuid) q;
RESET ROLE;
SELECT pg_temp.assert_true(
 (SELECT consumption_cost FROM public.vm_quote_item_materials WHERE quote_id=(SELECT quote_id FROM qa_cost_quote))=
  (0.00000001::numeric*0.12345678::numeric*9.87654321::numeric*1.23456789::numeric*0.0001::numeric*0.333333333333333333333333::numeric),
 'quote keeps the full precise composition cost');
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.role','anon',true);
INSERT INTO qa_cost_accepted SELECT order_id,tracking_token FROM public.vm_approve_quote((SELECT token FROM qa_cost_quote));
RESET ROLE;
SELECT pg_temp.assert_true(
 (SELECT consumption_cost FROM public.vm_order_item_materials WHERE order_id=(SELECT order_id FROM qa_cost_accepted))=
 (SELECT consumption_cost FROM public.vm_quote_item_materials WHERE quote_id=(SELECT quote_id FROM qa_cost_quote)),
 'approval copies 60-place quote costs without truncating');
SELECT pg_temp.pass_test('public approval preserves precise quote costs in the order');

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','owner')::text,true);
CREATE TEMP TABLE qa_cost_purchase ON COMMIT DROP AS SELECT * FROM public.vm_create_material_purchase(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 (SELECT material_id FROM qa_materials WHERE kind='cost_third'),3::numeric,1::numeric,DATE '2026-10-29','pending',NULL::date,
 '40000000-0000-0000-0000-000000000405'::uuid,NULL::uuid,'compra custo QA');
SELECT pg_temp.assert_true(
 (SELECT unit_cost::numeric FROM qa_cost_purchase)=0.333333333333333333333333::numeric
 AND (SELECT unit_cost::numeric FROM public.vm_material_purchases_read WHERE id=(SELECT purchase_id FROM qa_cost_purchase))=0.333333333333333333333333::numeric,
 'purchase RPC and view expose the precise unit cost');
SELECT * FROM public.vm_receive_material(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 (SELECT material_id FROM qa_materials WHERE kind='cost_third'),1::numeric,2::numeric,3::numeric,'nova compra QA',
 '40000000-0000-0000-0000-000000000406'::uuid);
SELECT pg_temp.assert_true(
 (SELECT unit_cost::numeric FROM public.vm_materials_read WHERE id=(SELECT material_id FROM qa_materials WHERE kind='cost_third'))=0.666666666666666666666667::numeric
 AND (SELECT unit_cost_snapshot FROM public.vm_product_components WHERE product_id=(SELECT product_id FROM qa_products WHERE kind='cost_m2'))=0.333333333333333333333333::numeric
 AND (SELECT composition_cost FROM public.vm_product_versions WHERE product_id=(SELECT product_id FROM qa_products WHERE kind='cost_m2'))=0.00000000333333333333333333333333::numeric,
 'new material cost does not rewrite the earlier frozen product version');
SELECT pg_temp.pass_test('purchase, receipt and frozen snapshots retain separate precise costs');
RESET ROLE;
SET CONSTRAINTS ALL IMMEDIATE;

SET CONSTRAINTS ALL DEFERRED;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','owner')::text,true);
INSERT INTO qa_products
SELECT 'cost_variant',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),p.product_id
FROM public.vm_upsert_product_v2(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 'Produto custo variante QA','orders','[]'::jsonb,NULL,NULL,NULL,NULL,0,'variation',
 1::numeric,NULL,0.00000001::numeric,'unit',false,false,
 '[]'::jsonb,NULL,NULL,NULL,NULL,'ORD-COST-VARIANT',NULL,'[]'::jsonb,
 jsonb_build_array(jsonb_build_object('material_id',(SELECT material_id FROM qa_materials WHERE kind='cost_third'),'quantity','0.00000001','unit','g')),
 jsonb_build_array(
   jsonb_build_object('name','Herdada','price','1','composition_mode','inherit_base'),
   jsonb_build_object('name','Própria','price','1','composition_mode','own','components',
     jsonb_build_array(jsonb_build_object('material_id',(SELECT material_id FROM qa_materials WHERE kind='cost_third'),'quantity','0.00000002','unit','g')))),
 NULL,'40000000-0000-0000-0000-000000000407'::uuid) p;
INSERT INTO qa_variants
SELECT 'cost_own',organization_id,id FROM public.vm_product_variants WHERE product_id=(SELECT product_id FROM qa_products WHERE kind='cost_variant') AND name='Própria';
SELECT pg_temp.assert_true(
 (SELECT unit_cost_snapshot FROM public.vm_product_variant_components WHERE variant_id=(SELECT variant_id FROM qa_variants WHERE kind='cost_own'))=0.666666666666666666666667::numeric
 AND (SELECT line_cost_precise FROM public.vm_product_variant_components WHERE variant_id=(SELECT variant_id FROM qa_variants WHERE kind='cost_own'))=0.00000001333333333333333333333334::numeric
 AND (SELECT (v->>'composition_cost')::numeric FROM public.vm_product_versions p, jsonb_array_elements(p.variants_snapshot) v
      WHERE p.product_id=(SELECT product_id FROM qa_products WHERE kind='cost_variant') AND v->>'name'='Própria')=0.00000001333333333333333333333334::numeric,
 'own variant stores precise unit and composition costs in its frozen snapshot');
INSERT INTO qa_orders
SELECT 'cost_variant',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),r.order_id,'40000000-0000-0000-0000-000000000408'::uuid
FROM public.vm_create_order(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='active2'),'title','QA cost variant','order_date','2026-10-29','initial_status','Concluído'),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_products WHERE kind='cost_variant'),
  'variant_id',(SELECT variant_id FROM qa_variants WHERE kind='cost_own'),'quantity','0.12345678')),
 '40000000-0000-0000-0000-000000000408'::uuid) r;
SELECT pg_temp.assert_true(
 (SELECT consumption_cost FROM public.vm_order_item_materials WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='cost_variant'))=
  0.00000002::numeric*0.12345678::numeric*0.666666666666666666666667::numeric
 AND (SELECT count(*) FROM public.vm_order_consumptions WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='cost_variant'))=1,
 'order for own variation multiplies its precise cost and consumes once');
SELECT pg_temp.pass_test('own-variant snapshot and completed order use precise cost');
RESET ROLE;
SET CONSTRAINTS ALL IMMEDIATE;
