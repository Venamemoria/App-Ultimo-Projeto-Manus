-- Orders contract suite. The runner applies the complete cumulative migration chain
-- through Orders in the marked local vm_test only. It never seeds Supabase,
-- calls the application, sends notifications, or writes an external service.
-- Diagnostics in assertion labels are local QA labels only; no PII is printed.

CREATE TEMP TABLE qa_test_results (
  ordinal integer GENERATED ALWAYS AS IDENTITY,
  label text NOT NULL
) ON COMMIT PRESERVE ROWS;

CREATE OR REPLACE FUNCTION pg_temp.assert_true(p_condition boolean, p_label text)
RETURNS void LANGUAGE plpgsql AS $function$
BEGIN
  IF NOT COALESCE(p_condition,false) THEN
    RAISE EXCEPTION 'assertion failed: %',p_label USING ERRCODE='P0001';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION pg_temp.assert_raises(p_label text,p_sqlstate text,p_statement text)
RETURNS void LANGUAGE plpgsql AS $function$
DECLARE v_sqlstate text;
BEGIN
  BEGIN
    EXECUTE p_statement;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate=RETURNED_SQLSTATE;
    IF p_sqlstate IS NULL OR v_sqlstate=p_sqlstate THEN RETURN; END IF;
    RAISE EXCEPTION 'assertion failed: % (unexpected SQLSTATE)',p_label USING ERRCODE='P0001';
  END;
  RAISE EXCEPTION 'assertion failed: % (expected error)',p_label USING ERRCODE='P0001';
END;
$function$;

CREATE OR REPLACE FUNCTION pg_temp.pass_test(p_label text)
RETURNS void LANGUAGE sql AS $function$
  INSERT INTO pg_temp.qa_test_results(label) VALUES (p_label)
$function$;
GRANT INSERT ON qa_test_results TO authenticated,anon;

CREATE TEMP TABLE qa_identity(user_a uuid NOT NULL,user_b uuid NOT NULL) ON COMMIT DROP;
INSERT INTO qa_identity VALUES
 ('00000000-0000-0000-0000-0000000000a1'::uuid,
  '00000000-0000-0000-0000-0000000000b2'::uuid);
CREATE TEMP TABLE qa_orgs(
  user_id uuid NOT NULL, organization_id uuid PRIMARY KEY, membership_id uuid NOT NULL
) ON COMMIT DROP;
CREATE TEMP TABLE qa_clients(
  kind text PRIMARY KEY, organization_id uuid NOT NULL, client_id uuid NOT NULL
) ON COMMIT DROP;
CREATE TEMP TABLE qa_materials(
  kind text PRIMARY KEY, organization_id uuid NOT NULL, material_id uuid NOT NULL,
  opening_movement_id uuid, stock_quantity numeric, unit_cost numeric
) ON COMMIT DROP;
CREATE TEMP TABLE qa_products(
  kind text PRIMARY KEY, organization_id uuid NOT NULL, product_id uuid NOT NULL
) ON COMMIT DROP;
CREATE TEMP TABLE qa_variants(
  kind text PRIMARY KEY, organization_id uuid NOT NULL, variant_id uuid NOT NULL
) ON COMMIT DROP;
CREATE TEMP TABLE qa_orders(
  kind text PRIMARY KEY, organization_id uuid NOT NULL, order_id uuid NOT NULL,
  idempotency_key uuid NOT NULL
) ON COMMIT DROP;
CREATE TEMP TABLE qa_payments(
  kind text PRIMARY KEY, payment_id uuid NOT NULL, cash_entry_id uuid NOT NULL
) ON COMMIT DROP;

GRANT SELECT ON qa_identity,qa_orgs,qa_clients,qa_materials,qa_products,qa_variants,qa_orders,qa_payments
  TO authenticated,anon;
GRANT INSERT ON qa_orgs,qa_clients,qa_materials,qa_products,qa_variants,qa_orders,qa_payments
  TO authenticated;

-- All write fixtures below use the actual Auth helper contract and public RPCs.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','authenticated')::text,true);
INSERT INTO qa_orgs
SELECT i.user_a,c.organization_id,c.membership_id
FROM qa_identity i CROSS JOIN LATERAL public.vm_create_organization('Orders tenant A') c;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_b::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','authenticated')::text,true);
INSERT INTO qa_orgs
SELECT i.user_b,c.organization_id,c.membership_id
FROM qa_identity i CROSS JOIN LATERAL public.vm_create_organization('Orders tenant B') c;
SELECT pg_temp.assert_true((SELECT count(*) FROM qa_orgs)=2,'orders fixtures create two tenants through organization RPC');

-- Tenant A receives a real second membership that is changed between production,
-- finance and viewer checks. Membership identity and tenant are never spoofed.
RESET ROLE;
INSERT INTO public.vm_memberships(organization_id,user_id,role)
VALUES((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
       (SELECT user_b FROM qa_identity),'production');
SELECT pg_temp.assert_true((SELECT count(*) FROM public.vm_memberships)=3,'owner production and owner memberships exist locally');

-- Active and archived clients in A, plus an active client in the other tenant.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','owner')::text,true);
INSERT INTO qa_clients
SELECT 'active',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),c.contact_id
FROM public.vm_upsert_contact(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 'client','{"name":"Cliente Orders Ativo","email":"orders@example.test","person_type":"individual"}'::jsonb,
 NULL,'40000000-0000-0000-0000-000000000001'::uuid) c;
INSERT INTO qa_clients
SELECT 'archived',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),c.contact_id
FROM public.vm_upsert_contact(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 'client','{"name":"Cliente Orders Arquivado","person_type":"individual"}'::jsonb,
 NULL,'40000000-0000-0000-0000-000000000002'::uuid) c;
SELECT pg_temp.assert_true(
 (SELECT archived FROM public.vm_archive_contact(
   (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
   'client',(SELECT client_id FROM qa_clients WHERE kind='archived'),true,'fixture arquivado')),
 'archived client fixture is real and auditable');

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_b::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','owner')::text,true);
INSERT INTO qa_clients
SELECT 'cross_tenant',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_b FROM qa_identity)),c.contact_id
FROM public.vm_upsert_contact(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_b FROM qa_identity)),
 'client','{"name":"Cliente Orders Tenant B","person_type":"individual"}'::jsonb,
 NULL,'40000000-0000-0000-0000-000000000003'::uuid) c;
SELECT pg_temp.pass_test('real roles tenants and active archived cross-tenant client fixtures');

-- Material A costs 2 per unit and has ample stock. Material B deliberately has
-- one unit only so the short recipe exercises all-or-nothing consumption.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','owner')::text,true);
INSERT INTO qa_materials
SELECT 'main',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),m.material_id,m.opening_movement_id,m.stock_quantity,m.unit_cost
FROM public.vm_create_material(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 'Material Orders A','g',20::numeric,10::numeric,100::numeric,0::numeric,
 'orders',NULL::uuid,'40000000-0000-0000-0000-000000000010'::uuid) m;
INSERT INTO qa_materials
SELECT 'short',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),m.material_id,m.opening_movement_id,m.stock_quantity,m.unit_cost
FROM public.vm_create_material(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 'Material Orders B','g',10::numeric,10::numeric,1::numeric,0::numeric,
 'orders',NULL::uuid,'40000000-0000-0000-0000-000000000011'::uuid) m;
SELECT pg_temp.assert_true((SELECT unit_cost FROM qa_materials WHERE kind='main')=2.00000000::numeric,'main material cost is exact two');
SELECT pg_temp.assert_true((SELECT stock_quantity FROM qa_materials WHERE kind='short')=1.00000000::numeric,'short material starts with one unit');

-- Base product: price/promo/MOQ/tier and one shared component. Two lines of
-- quantity one therefore total 2 and exact composition cost 16.
INSERT INTO qa_products
SELECT 'base',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),p.product_id
FROM public.vm_upsert_product_v2(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 'Produto Orders Base','orders','[]'::jsonb,NULL,NULL,NULL,NULL,0,'unit',
 1.00000000::numeric,0.90000000::numeric,1.00000000::numeric,'unit',false,false,
 '[]'::jsonb,NULL,NULL,NULL,NULL,'ORD-BASE',NULL,
 '[{"minimum_quantity":"5","unit_price":"0.75000000"}]'::jsonb,
 jsonb_build_array(jsonb_build_object('material_id',(SELECT material_id FROM qa_materials WHERE kind='main'),'quantity','4.00000000','unit','g')),
 '[]'::jsonb,NULL,'40000000-0000-0000-0000-000000000020'::uuid) p;

-- Variation product contains both inherit_base and own recipes. Its pricing mode
-- makes variant selection mandatory and preserves variant version snapshots.
INSERT INTO qa_products
SELECT 'variant',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),p.product_id
FROM public.vm_upsert_product_v2(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 'Produto Orders Variantes','orders','[]'::jsonb,NULL,NULL,NULL,NULL,0,'variation',
 10.00000000::numeric,NULL,1.00000000::numeric,'unit',false,false,
 '[]'::jsonb,NULL,NULL,NULL,NULL,'ORD-VAR',NULL,'[]'::jsonb,
 jsonb_build_array(jsonb_build_object('material_id',(SELECT material_id FROM qa_materials WHERE kind='main'),'quantity','2.00000000','unit','g')),
 jsonb_build_array(
   jsonb_build_object('name','Inherit','price','4.00000000','promo_price','3.50000000','minimum_quantity','2.00000000','composition_mode','inherit_base'),
   jsonb_build_object('name','Own','price','5.00000000','minimum_quantity','1.00000000','composition_mode','own','components',jsonb_build_array(jsonb_build_object('material_id',(SELECT material_id FROM qa_materials WHERE kind='main'),'quantity','3.00000000','unit','g')))
 ),NULL,'40000000-0000-0000-0000-000000000021'::uuid) p;
INSERT INTO qa_variants
SELECT 'inherit',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),id
FROM public.vm_product_variants
WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))
  AND product_id=(SELECT product_id FROM qa_products WHERE kind='variant') AND name='Inherit';
INSERT INTO qa_variants
SELECT 'own',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),id
FROM public.vm_product_variants
WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))
  AND product_id=(SELECT product_id FROM qa_products WHERE kind='variant') AND name='Own';

-- m2 product is used for exact dimensions-factor/billed-quantity assertions.
INSERT INTO qa_products
SELECT 'm2',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),p.product_id
FROM public.vm_upsert_product_v2(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 'Produto Orders M2','orders','[]'::jsonb,NULL,NULL,NULL,NULL,0,'m2',
 10.00000000::numeric,NULL,0.50000000::numeric,'m2',false,false,
 '[]'::jsonb,NULL,NULL,NULL,NULL,'ORD-M2',NULL,'[]'::jsonb,
 jsonb_build_array(jsonb_build_object('material_id',(SELECT material_id FROM qa_materials WHERE kind='short'),'quantity','0.50000000','unit','g')),
 '[]'::jsonb,NULL,'40000000-0000-0000-0000-000000000022'::uuid) p;

-- Short product is deliberately impossible to consume with stock B=1.
INSERT INTO qa_products
SELECT 'short',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),p.product_id
FROM public.vm_upsert_product_v2(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 'Produto Orders Insuficiente','orders','[]'::jsonb,NULL,NULL,NULL,NULL,0,'unit',
 1.00000000::numeric,NULL,1.00000000::numeric,'unit',false,false,
 '[]'::jsonb,NULL,NULL,NULL,NULL,'ORD-SHORT',NULL,'[]'::jsonb,
 jsonb_build_array(jsonb_build_object('material_id',(SELECT material_id FROM qa_materials WHERE kind='short'),'quantity','2.00000000','unit','g')),
 '[]'::jsonb,NULL,'40000000-0000-0000-0000-000000000023'::uuid) p;
SELECT pg_temp.assert_true((SELECT count(*) FROM qa_products)=4,'base variant m2 and insufficient products exist');
SELECT pg_temp.assert_true((SELECT count(*) FROM qa_variants)=2,'inherit and own variants exist');
SELECT pg_temp.pass_test('catalog fixtures cover base variant inherit own m2 and short recipe');

-- Owner creates a pending multi-item order. Both lines share material A: the
-- aggregate is 8, cost is 16, subtotal/total is 2, and no deduction occurs yet.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','owner')::text,true);
INSERT INTO qa_orders
SELECT 'core',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),r.order_id,'40000000-0000-0000-0000-000000000100'::uuid
FROM public.vm_create_order(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='active'),'title','QA core pending','order_date','2026-10-29','initial_status','Pendente','discount_type','none','discount_value','0','shipping_amount','0'),
 jsonb_build_array(
   jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_products WHERE kind='base'),'quantity','1','unit_price','1','price_override',true,'price_override_reason','total agregado QA'),
   jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_products WHERE kind='base'),'quantity','1','unit_price','1','price_override',true,'price_override_reason','total agregado QA')
 ),'40000000-0000-0000-0000-000000000100'::uuid) r;
SELECT pg_temp.assert_true((SELECT status FROM public.vm_orders_read WHERE id=(SELECT order_id FROM qa_orders WHERE kind='core'))='Pendente','core order starts pending');
SELECT pg_temp.assert_true((SELECT subtotal FROM public.vm_orders_read WHERE id=(SELECT order_id FROM qa_orders WHERE kind='core'))='2.00','two item lines aggregate to total two');
SELECT pg_temp.assert_true((SELECT count(*) FROM public.vm_order_items WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='core'))=2,'multi-item order stores both positions');
SELECT pg_temp.assert_true((SELECT sum(total_composition_cost) FROM public.vm_order_items WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='core'))=16.0000000000000000::numeric,'multi-item composition cost is exact sixteen');
SELECT pg_temp.assert_true((SELECT count(*) FROM public.vm_order_consumption_runs WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='core'))=0,'pending creation has no consumption run');
SELECT pg_temp.pass_test('pending multi-item aggregate total and exact composition cost');

-- Product resolution: base tier, variant price/MOQ, inherit/own recipe, m2
-- dimensions, explicit override, and manual service with no recipe.
CREATE TEMP TABLE qa_resolution(order_id uuid,kind text) ON COMMIT DROP;
GRANT SELECT,INSERT ON qa_resolution TO authenticated,anon;
INSERT INTO qa_resolution
SELECT r.order_id,'tier'
FROM public.vm_create_order(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='active'),'title','QA tier','order_date','2026-10-29','discount_type','none','discount_value','0','shipping_amount','0'),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_products WHERE kind='base'),'quantity','5')),
 '40000000-0000-0000-0000-000000000101'::uuid) r;
INSERT INTO qa_resolution
SELECT r.order_id,'inherit'
FROM public.vm_create_order(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='active'),'title','QA inherit','order_date','2026-10-29','discount_type','none','discount_value','0','shipping_amount','0'),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_products WHERE kind='variant'),'variant_id',(SELECT variant_id FROM qa_variants WHERE kind='inherit'),'quantity','2')),
 '40000000-0000-0000-0000-000000000102'::uuid) r;
INSERT INTO qa_resolution
SELECT r.order_id,'own'
FROM public.vm_create_order(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='active'),'title','QA own','order_date','2026-10-29','discount_type','none','discount_value','0','shipping_amount','0'),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_products WHERE kind='variant'),'variant_id',(SELECT variant_id FROM qa_variants WHERE kind='own'),'quantity','1')),
 '40000000-0000-0000-0000-000000000103'::uuid) r;
INSERT INTO qa_resolution
SELECT r.order_id,'m2'
FROM public.vm_create_order(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='active'),'title','QA m2','order_date','2026-10-29','discount_type','none','discount_value','0','shipping_amount','0'),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_products WHERE kind='m2'),'quantity','2','dimensions',jsonb_build_object('width_cm','100','height_cm','25'))),
 '40000000-0000-0000-0000-000000000104'::uuid) r;
INSERT INTO qa_resolution
SELECT r.order_id,'override'
FROM public.vm_create_order(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='active'),'title','QA override','order_date','2026-10-29','discount_type','fixed','discount_value','0.50','shipping_amount','1.00'),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_products WHERE kind='base'),'quantity','1','unit_price','2.00','price_override',true,'price_override_reason','teste manual local')),
 '40000000-0000-0000-0000-000000000105'::uuid) r;
INSERT INTO qa_resolution
SELECT r.order_id,'manual'
FROM public.vm_create_order(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='active'),'title','QA manual','order_date','2026-10-29','discount_type','none','discount_value','0','shipping_amount','0'),
 jsonb_build_array(jsonb_build_object('kind','manual_service','title','Serviço manual','quantity','2','unit_price','3.00','price_override',true,'price_override_reason','serviço sem receita')),
 '40000000-0000-0000-0000-000000000106'::uuid) r;
SELECT pg_temp.assert_true((SELECT unit_price FROM vm_order_items WHERE order_id=(SELECT order_id FROM qa_resolution WHERE kind='tier'))='0.75000000','base tier price is selected at its MOQ');
SELECT pg_temp.assert_true((SELECT price_source FROM vm_order_items WHERE order_id=(SELECT order_id FROM qa_resolution WHERE kind='tier'))='catalog','tier remains catalog source');
SELECT pg_temp.assert_true((SELECT unit_price FROM vm_order_items WHERE order_id=(SELECT order_id FROM qa_resolution WHERE kind='inherit'))='3.50000000' AND (SELECT recipe_mode FROM vm_order_items WHERE order_id=(SELECT order_id FROM qa_resolution WHERE kind='inherit'))='inherit_base','inherit variant uses promo price and base recipe');
SELECT pg_temp.assert_true((SELECT unit_price FROM vm_order_items WHERE order_id=(SELECT order_id FROM qa_resolution WHERE kind='own'))='5.00000000' AND (SELECT recipe_mode FROM vm_order_items WHERE order_id=(SELECT order_id FROM qa_resolution WHERE kind='own'))='own' AND (SELECT quantity_snapshot FROM vm_order_item_materials WHERE order_id=(SELECT order_id FROM qa_resolution WHERE kind='own'))=3.00000000::numeric,'own variant freezes its own recipe');
SELECT pg_temp.assert_true((SELECT dimensions_factor FROM vm_order_items WHERE order_id=(SELECT order_id FROM qa_resolution WHERE kind='m2'))='0.25000000' AND (SELECT billed_quantity FROM vm_order_items WHERE order_id=(SELECT order_id FROM qa_resolution WHERE kind='m2'))='0.50000000','m2 factor and billed quantity preserve exact decimal precision');
SELECT pg_temp.assert_true((SELECT price_source FROM vm_order_items WHERE order_id=(SELECT order_id FROM qa_resolution WHERE kind='override'))='override' AND (SELECT unit_price FROM vm_order_items WHERE order_id=(SELECT order_id FROM qa_resolution WHERE kind='override'))='2.00000000' AND (SELECT price_override_reason FROM vm_order_items WHERE order_id=(SELECT order_id FROM qa_resolution WHERE kind='override'))='teste manual local','product override freezes explicit price and reason');
SELECT pg_temp.assert_true((SELECT recipe_mode FROM vm_order_items WHERE order_id=(SELECT order_id FROM qa_resolution WHERE kind='manual'))='none' AND (SELECT count(*) FROM vm_order_item_materials WHERE order_id=(SELECT order_id FROM qa_resolution WHERE kind='manual'))=0 AND (SELECT total_amount FROM vm_orders_read WHERE id=(SELECT order_id FROM qa_resolution WHERE kind='manual'))='6.00','manual service is unit-priced and has empty recipe');
SELECT pg_temp.pass_test('tier MOQ prices variant inherit own m2 factor override and manual recipe');

-- Input validation and identity barriers happen before a commercial row exists.
SELECT pg_temp.assert_raises('archived client rejected','23503',format($sql$SELECT * FROM public.vm_create_order('%s','{"client_id":"%s","title":"archived","order_date":"2026-10-29"}'::jsonb,'[{"kind":"manual_service","title":"x","quantity":"1","unit_price":"1","price_override":true,"price_override_reason":"r"}]'::jsonb,'40000000-0000-0000-0000-000000000107'::uuid)$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT client_id FROM qa_clients WHERE kind='archived')));
SELECT pg_temp.assert_raises('cross tenant client rejected','23503',format($sql$SELECT * FROM public.vm_create_order('%s','{"client_id":"%s","title":"cross","order_date":"2026-10-29"}'::jsonb,'[{"kind":"manual_service","title":"x","quantity":"1","unit_price":"1","price_override":true,"price_override_reason":"r"}]'::jsonb,'40000000-0000-0000-0000-000000000108'::uuid)$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT client_id FROM qa_clients WHERE kind='cross_tenant')));
SELECT pg_temp.assert_raises('manual service without override rejected','22023',format($sql$SELECT * FROM public.vm_create_order('%s','{"client_id":"%s","title":"bad manual","order_date":"2026-10-29"}'::jsonb,'[{"kind":"manual_service","title":"x","quantity":"1"}]'::jsonb,'40000000-0000-0000-0000-000000000109'::uuid)$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT client_id FROM qa_clients WHERE kind='active')));
SELECT pg_temp.assert_raises('m2 without dimensions rejected','22023',format($sql$SELECT * FROM public.vm_create_order('%s','{"client_id":"%s","title":"bad m2","order_date":"2026-10-29"}'::jsonb,'[{"kind":"product","product_id":"%s","quantity":"1"}]'::jsonb,'40000000-0000-0000-0000-000000000110'::uuid)$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT client_id FROM qa_clients WHERE kind='active'),(SELECT product_id FROM qa_products WHERE kind='m2')));
SELECT pg_temp.assert_true((SELECT count(*) FROM public.vm_orders WHERE code IS NOT NULL AND title IN ('archived','cross','bad manual','bad m2'))=0,'invalid order inputs create no rows');
SELECT pg_temp.pass_test('active archived cross-tenant and input validation barriers');

-- Create order replay is historical: update catalog and client, archive client,
-- replay same canonical intent, and verify no new order or changed frozen values.
INSERT INTO qa_orders
SELECT 'replay',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),r.order_id,'40000000-0000-0000-0000-000000000111'::uuid
FROM public.vm_create_order(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='active'),'title','QA replay frozen','order_date','2026-10-29','discount_type','none','discount_value','0','shipping_amount','0'),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_products WHERE kind='base'),'quantity','1')),
 '40000000-0000-0000-0000-000000000111'::uuid) r;
CREATE TEMP TABLE qa_replay_result ON COMMIT DROP AS
SELECT * FROM public.vm_create_order(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='active'),'title','QA replay frozen','order_date','2026-10-29','discount_type','none','discount_value','0','shipping_amount','0'),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_products WHERE kind='base'),'quantity','1')),
 '40000000-0000-0000-0000-000000000111'::uuid);
SELECT pg_temp.assert_true((SELECT order_id FROM qa_replay_result)=(SELECT order_id FROM qa_orders WHERE kind='replay'),'same create key returns original order');
RESET ROLE;
UPDATE public.vm_products SET name='Catálogo Orders Editado' WHERE id=(SELECT product_id FROM qa_products WHERE kind='base');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','owner')::text,true);
SELECT pg_temp.assert_true((SELECT contact_id FROM public.vm_upsert_contact(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),'client',
 '{"name":"Cliente Orders Renomeado","person_type":"individual"}'::jsonb,
 (SELECT client_id FROM qa_clients WHERE kind='active'),'40000000-0000-0000-0000-000000000112'::uuid))=(SELECT client_id FROM qa_clients WHERE kind='active'),'client edit keeps identity');
SELECT pg_temp.assert_true((SELECT event_id FROM public.vm_archive_contact(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),'client',
 (SELECT client_id FROM qa_clients WHERE kind='active'),true,'archive after order')) IS NOT NULL,'active client can be archived after historical order');
CREATE TEMP TABLE qa_replay_after_archive ON COMMIT DROP AS
SELECT * FROM public.vm_create_order(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='active'),'title','QA replay frozen','order_date','2026-10-29','discount_type','none','discount_value','0','shipping_amount','0'),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_products WHERE kind='base'),'quantity','1')),
 '40000000-0000-0000-0000-000000000111'::uuid);
SELECT pg_temp.assert_true((SELECT order_id FROM qa_replay_after_archive)=(SELECT order_id FROM qa_orders WHERE kind='replay') AND (SELECT unit_price FROM vm_order_items WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='replay'))='0.90000000','replay ignores archived client and catalog edits and keeps price snapshot');
SELECT pg_temp.assert_true((SELECT client_name_snapshot FROM vm_orders_read WHERE id=(SELECT order_id FROM qa_orders WHERE kind='replay'))='Cliente Orders Ativo' AND (SELECT client_name FROM vm_orders_read WHERE id=(SELECT order_id FROM qa_orders WHERE kind='replay'))='Cliente Orders Renomeado','order has historical client snapshot and current read name');
SELECT pg_temp.pass_test('create replay remains frozen after catalog edit and client archive');

-- Same key with a different canonical payload is a collision and never mutates.
SELECT pg_temp.assert_raises('create key different payload rejected','23505',format($sql$SELECT * FROM public.vm_create_order('%s','{"client_id":"%s","title":"different","order_date":"2026-10-29"}'::jsonb,'[{"kind":"manual_service","title":"x","quantity":"1","unit_price":"1","price_override":true,"price_override_reason":"r"}]'::jsonb,'40000000-0000-0000-0000-000000000111'::uuid)$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT client_id FROM qa_clients WHERE kind='active')));
SELECT pg_temp.pass_test('create idempotency collision preserves frozen history');

-- Exact consumption: pending -> Em Produção -> Concluído -> Entregue has one
-- deduction, one run, one event per real transition, notifications and outbox.
-- Use the base product current version after the edit; this is a fresh order.
-- Restore an active client only through a new client fixture because archived rows
-- remain historical and must not be reused for new orders.
SELECT set_config('request.jwt.claim.role','authenticated',true);
INSERT INTO qa_clients
SELECT 'active2',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),c.contact_id
FROM public.vm_upsert_contact(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 'client','{"name":"Cliente Orders Operacional","person_type":"individual"}'::jsonb,
 NULL,'40000000-0000-0000-0000-000000000113'::uuid) c;
INSERT INTO qa_orders
SELECT 'lifecycle',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),r.order_id,'40000000-0000-0000-0000-000000000114'::uuid
FROM public.vm_create_order(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='active2'),'title','QA lifecycle','order_date','2026-10-29','discount_type','none','discount_value','0','shipping_amount','0'),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_products WHERE kind='base'),'quantity','1')),
 '40000000-0000-0000-0000-000000000114'::uuid) r;
SELECT pg_temp.assert_true((SELECT status FROM vm_set_order_status(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT order_id FROM qa_orders WHERE kind='lifecycle'),'Em Produção',NULL,'40000000-0000-0000-0000-000000000115'::uuid))='Em Produção','production transition succeeds');
SELECT pg_temp.assert_true((SELECT status FROM vm_set_order_status(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT order_id FROM qa_orders WHERE kind='lifecycle'),'Concluído',NULL,'40000000-0000-0000-0000-000000000116'::uuid))='Concluído','completed transition succeeds');
SELECT pg_temp.assert_true((SELECT status FROM vm_set_order_status(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT order_id FROM qa_orders WHERE kind='lifecycle'),'Entregue',NULL,'40000000-0000-0000-0000-000000000117'::uuid))='Entregue','delivered transition succeeds');
SELECT pg_temp.assert_true((SELECT count(*) FROM vm_order_consumption_runs WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='lifecycle'))=1 AND (SELECT count(*) FROM vm_order_consumptions WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='lifecycle'))=1,'lifecycle has exactly one durable consumption run and material consumption');
SELECT pg_temp.assert_true((SELECT quantity FROM vm_order_consumptions WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='lifecycle'))=4.00000000::numeric AND (SELECT quantity_delta FROM vm_stock_movements WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='lifecycle'))=-4.00000000::numeric,'deduction is exact and linked to one order movement');
RESET ROLE;
SELECT pg_temp.assert_true((SELECT count(*) FROM vm_order_events WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='lifecycle'))=4 AND (SELECT count(*) FROM vm_notification_outbox WHERE event_id IN (SELECT id FROM vm_order_events WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='lifecycle')))=4,'created plus three transitions each have one event and outbox');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','owner')::text,true);
SELECT pg_temp.assert_true((SELECT count(*) FROM vm_notifications WHERE event_id IN (SELECT id FROM vm_order_events WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='lifecycle')))=4,'notification RLS exposes only owner A rows');
RESET ROLE;
SELECT pg_temp.assert_true((SELECT count(*) FROM vm_notifications WHERE event_id IN (SELECT id FROM vm_order_events WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='lifecycle')))=8,'each lifecycle event notifies both tenant memberships');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','owner')::text,true);
SELECT pg_temp.assert_true((SELECT changed FROM vm_set_order_status(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT order_id FROM qa_orders WHERE kind='lifecycle'),'Entregue',NULL,'40000000-0000-0000-0000-000000000118'::uuid))=false AND (SELECT count(*) FROM vm_order_consumptions WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='lifecycle'))=1,'same status is a no-op and never consumes twice');
SELECT pg_temp.pass_test('lifecycle consumes once with exact movement events notifications and outbox');

-- Direct Concluído consumes immediately; manual service also creates a durable
-- empty-recipe run while leaving material stock and consumption rows untouched.
INSERT INTO qa_orders
SELECT 'direct_completed',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),r.order_id,'40000000-0000-0000-0000-000000000119'::uuid
FROM public.vm_create_order(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='active2'),'title','QA direct completed','order_date','2026-10-29','initial_status','Concluído','discount_type','none','discount_value','0','shipping_amount','0'),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_products WHERE kind='m2'),'quantity','2','dimensions',jsonb_build_object('width_cm','100','height_cm','25'))),
 '40000000-0000-0000-0000-000000000119'::uuid) r;
SELECT pg_temp.assert_true((SELECT status FROM vm_orders_read WHERE id=(SELECT order_id FROM qa_orders WHERE kind='direct_completed'))='Concluído' AND (SELECT inventory_deducted FROM vm_orders_read WHERE id=(SELECT order_id FROM qa_orders WHERE kind='direct_completed')),'direct Concluído creates and consumes atomically');
INSERT INTO qa_orders
SELECT 'empty_recipe',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),r.order_id,'40000000-0000-0000-0000-000000000120'::uuid
FROM public.vm_create_order(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='active2'),'title','QA empty recipe','order_date','2026-10-29','initial_status','Concluído','discount_type','none','discount_value','0','shipping_amount','0'),
 jsonb_build_array(jsonb_build_object('kind','manual_service','title','Serviço sem receita','quantity','1','unit_price','2','price_override',true,'price_override_reason','sem consumo')),
 '40000000-0000-0000-0000-000000000120'::uuid) r;
SELECT pg_temp.assert_true((SELECT count(*) FROM vm_order_consumption_runs WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='empty_recipe'))=1 AND (SELECT count(*) FROM vm_order_consumptions WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='empty_recipe'))=0,'empty recipe still records one durable run without deduction rows');
SELECT pg_temp.pass_test('direct completed and empty recipe consumption ledger');

-- Insufficient one-material creation aborts the entire operation. No order,
-- event, outbox, request, run, movement, or balance change remains.
CREATE TEMP TABLE qa_short_before ON COMMIT DROP AS
SELECT (SELECT stock_quantity FROM vm_materials WHERE id=(SELECT material_id FROM qa_materials WHERE kind='short')) AS stock,
       (SELECT stock_quantity FROM vm_materials WHERE id=(SELECT material_id FROM qa_materials WHERE kind='main')) AS main_stock,
       (SELECT count(*) FROM vm_stock_movements WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))) AS movements,
       (SELECT count(*) FROM vm_order_events WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))) AS events;
SELECT pg_temp.assert_raises('insufficient material rolls back consuming create','23514',format($sql$SELECT * FROM public.vm_create_order('%s','{"client_id":"%s","title":"QA insufficient rollback","order_date":"2026-10-29","initial_status":"Em Produção"}'::jsonb,'[{"kind":"product","product_id":"%s","quantity":"1"}]'::jsonb,'40000000-0000-0000-0000-000000000121'::uuid)$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT client_id FROM qa_clients WHERE kind='active2'),(SELECT product_id FROM qa_products WHERE kind='short')));
SELECT pg_temp.assert_raises('one insufficient material aborts two-material production','23514',format($sql$SELECT * FROM public.vm_create_order('%s','{"client_id":"%s","title":"QA two-material rollback","order_date":"2026-10-29","initial_status":"Em Produção"}'::jsonb,'[{"kind":"product","product_id":"%s","quantity":"1"},{"kind":"product","product_id":"%s","quantity":"1"}]'::jsonb,'40000000-0000-0000-0000-000000000150'::uuid)$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT client_id FROM qa_clients WHERE kind='active2'),(SELECT product_id FROM qa_products WHERE kind='base'),(SELECT product_id FROM qa_products WHERE kind='short')));
SELECT pg_temp.assert_true((SELECT main_stock FROM qa_short_before)=(SELECT stock_quantity FROM vm_materials WHERE id=(SELECT material_id FROM qa_materials WHERE kind='main')),'valid material is not deducted when another material is insufficient');
RESET ROLE;
SELECT pg_temp.assert_true((SELECT count(*) FROM vm_orders WHERE title='QA insufficient rollback')=0 AND (SELECT count(*) FROM vm_order_events WHERE order_id IN (SELECT id FROM vm_orders WHERE title='QA insufficient rollback'))=0 AND (SELECT count(*) FROM vm_notification_outbox WHERE event_id IN (SELECT id FROM vm_order_events WHERE order_id IN (SELECT id FROM vm_orders WHERE title='QA insufficient rollback')))=0,'insufficient creation leaves no order event or outbox');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','owner')::text,true);
SELECT pg_temp.assert_true((SELECT stock FROM qa_short_before)=(SELECT stock_quantity FROM vm_materials WHERE id=(SELECT material_id FROM qa_materials WHERE kind='short')) AND (SELECT movements FROM qa_short_before)=(SELECT count(*) FROM vm_stock_movements WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))) AND (SELECT events FROM qa_short_before)=(SELECT count(*) FROM vm_order_events WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))),'insufficient creation leaves every balance and history count unchanged');
RESET ROLE;
SELECT pg_temp.assert_true((SELECT count(*) FROM vm_private.vm_order_requests WHERE idempotency_key='40000000-0000-0000-0000-000000000121'::uuid)=0,'failed consuming creation leaves no idempotency request');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','owner')::text,true);
SELECT pg_temp.pass_test('insufficient material atomic rollback across order event movement request and balance');

-- Status idempotency and collision use distinct payloads/keys. A second key for
-- the same current status is a no-op; a reused key with another status collides.
CREATE TEMP TABLE qa_status_replay ON COMMIT DROP AS
SELECT * FROM public.vm_set_order_status(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT order_id FROM qa_orders WHERE kind='core'),'Em Produção',NULL,'40000000-0000-0000-0000-000000000122'::uuid);
SELECT pg_temp.assert_true((SELECT changed FROM qa_status_replay)=true,'core production transition records a real first result');
SELECT pg_temp.assert_true((SELECT changed FROM public.vm_set_order_status(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT order_id FROM qa_orders WHERE kind='core'),'Em Produção',NULL,'40000000-0000-0000-0000-000000000122'::uuid))=true,'same status key replay returns original changed result');
SELECT pg_temp.assert_true((SELECT changed FROM public.vm_set_order_status(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT order_id FROM qa_orders WHERE kind='core'),'Em Produção',NULL,'40000000-0000-0000-0000-000000000123'::uuid))=false,'new key on current status is no-op');
SELECT pg_temp.assert_raises('status key different payload rejected','23505',format($sql$SELECT * FROM public.vm_set_order_status('%s','%s','Concluído',NULL,'40000000-0000-0000-0000-000000000122'::uuid)$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT order_id FROM qa_orders WHERE kind='core')));
SELECT pg_temp.assert_true((SELECT count(*) FROM vm_order_consumptions WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='core'))=1,'status retries never add a second deduction');
SELECT pg_temp.pass_test('status replay no-op and payload collision');

SELECT * FROM public.vm_set_order_status(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 (SELECT order_id FROM qa_orders WHERE kind='core'),'Concluído',NULL,'40000000-0000-0000-0000-000000000149'::uuid);
SELECT pg_temp.assert_true(
 (SELECT count(*) FROM vm_order_consumptions WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='core'))=1
 AND (SELECT quantity FROM vm_order_consumptions WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='core'))=
     (SELECT sum(consumption_quantity) FROM vm_order_item_materials WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='core'))
 AND (SELECT count(*) FROM vm_stock_movements WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='core'))=1,
 'two item snapshots sharing one material create one exact aggregate movement');
SELECT pg_temp.pass_test('multi-item shared material aggregate consumed exactly once');

-- Cancellation before consumption has no stock return; cancellation after
-- consumption preserves the deduction and the durable run.
INSERT INTO qa_orders
SELECT 'cancel_before',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),r.order_id,'40000000-0000-0000-0000-000000000124'::uuid
FROM public.vm_create_order(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='active2'),'title','QA cancel before','order_date','2026-10-29'),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_products WHERE kind='base'),'quantity','1')),
 '40000000-0000-0000-0000-000000000124'::uuid) r;
CREATE TEMP TABLE qa_cancel_stock_before ON COMMIT DROP AS
SELECT stock_quantity AS stock FROM vm_materials WHERE id=(SELECT material_id FROM qa_materials WHERE kind='main');
SELECT pg_temp.assert_true((SELECT status FROM public.vm_set_order_status(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT order_id FROM qa_orders WHERE kind='cancel_before'),'Cancelado','cliente cancelou','40000000-0000-0000-0000-000000000125'::uuid))='Cancelado','cancel before deduction succeeds');
SELECT pg_temp.assert_true((SELECT stock FROM qa_cancel_stock_before)=(SELECT stock_quantity FROM vm_materials WHERE id=(SELECT material_id FROM qa_materials WHERE kind='main')) AND (SELECT count(*) FROM vm_order_consumption_runs WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='cancel_before'))=0,'cancel before deduction does not return or consume material');
SELECT pg_temp.assert_true((SELECT reason FROM vm_order_events WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='cancel_before') AND status='Cancelado')='cliente cancelou','cancel reason is retained only in internal event history');
RESET ROLE;
SELECT pg_temp.assert_true((SELECT count(*) FROM vm_notification_outbox WHERE event_id IN (SELECT id FROM vm_order_events WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='cancel_before')))=2,'cancel event is pending in outbox with no external send');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','owner')::text,true);
INSERT INTO qa_orders
SELECT 'cancel_after',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),r.order_id,'40000000-0000-0000-0000-000000000145'::uuid
FROM public.vm_create_order(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='active2'),'title','QA cancel after production','order_date','2026-10-29','initial_status','Em Produção'),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_products WHERE kind='base'),'quantity','1')),
 '40000000-0000-0000-0000-000000000145'::uuid) r;
SELECT pg_temp.assert_true((SELECT status FROM public.vm_set_order_status(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT order_id FROM qa_orders WHERE kind='cancel_after'),'Cancelado','cancelado após produção','40000000-0000-0000-0000-000000000126'::uuid))='Cancelado','owner can cancel after deduction');
SELECT pg_temp.assert_true((SELECT count(*) FROM vm_order_consumptions WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='cancel_after'))=1 AND (SELECT inventory_deducted FROM vm_orders_read WHERE id=(SELECT order_id FROM qa_orders WHERE kind='cancel_after')),'cancel after deduction never auto-returns stock');
SELECT pg_temp.pass_test('cancel before and after deduction without automatic return');

-- Catalog validation rejects MOQ, missing variant, bad dimensions and precision
-- before inserting order rows; numeric input remains text-oriented at API edge.
SELECT pg_temp.assert_raises('variant MOQ rejects under-minimum quantity','22023',format($sql$SELECT * FROM public.vm_create_order('%s','{"client_id":"%s","title":"bad moq","order_date":"2026-10-29"}'::jsonb,'[{"kind":"product","product_id":"%s","variant_id":"%s","quantity":"1"}]'::jsonb,'40000000-0000-0000-0000-000000000127'::uuid)$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT client_id FROM qa_clients WHERE kind='active2'),(SELECT product_id FROM qa_products WHERE kind='variant'),(SELECT variant_id FROM qa_variants WHERE kind='inherit')));
SELECT pg_temp.assert_raises('variation product requires variant','22023',format($sql$SELECT * FROM public.vm_create_order('%s','{"client_id":"%s","title":"missing variant","order_date":"2026-10-29"}'::jsonb,'[{"kind":"product","product_id":"%s","quantity":"2"}]'::jsonb,'40000000-0000-0000-0000-000000000128'::uuid)$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT client_id FROM qa_clients WHERE kind='active2'),(SELECT product_id FROM qa_products WHERE kind='variant')));
SELECT pg_temp.assert_raises('decimal excess scale rejected before storage','22003',format($sql$SELECT * FROM public.vm_create_order('%s','{"client_id":"%s","title":"bad scale","order_date":"2026-10-29"}'::jsonb,'[{"kind":"product","product_id":"%s","quantity":"1.123456789"}]'::jsonb,'40000000-0000-0000-0000-000000000129'::uuid)$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT client_id FROM qa_clients WHERE kind='active2'),(SELECT product_id FROM qa_products WHERE kind='base')));
SELECT pg_temp.assert_true((SELECT count(*) FROM vm_orders WHERE title IN ('bad moq','missing variant','bad scale'))=0,'catalog numeric and MOQ errors create no order');
SELECT pg_temp.pass_test('MOQ variant requirement and pre-cast decimal validation');

-- Real payments: finance membership is used for the same tenant, cash linkage
-- copies amount/date/method/author/stamp, overpayment and nonce collisions fail.
RESET ROLE;
UPDATE public.vm_memberships SET role='finance'
WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))
  AND user_id=(SELECT user_b FROM qa_identity);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_b::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','finance')::text,true);
INSERT INTO qa_orders
SELECT 'payment_order',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),r.order_id,'40000000-0000-0000-0000-000000000130'::uuid
FROM public.vm_create_order(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='active2'),'title','QA payment order','order_date','2026-10-29'),
 jsonb_build_array(jsonb_build_object('kind','manual_service','title','Serviço faturável','quantity','10','unit_price','10','price_override',true,'price_override_reason','serviço financeiro')),
 '40000000-0000-0000-0000-000000000130'::uuid) r;
INSERT INTO qa_orders
SELECT 'free_order',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),r.order_id,'40000000-0000-0000-0000-000000000147'::uuid
FROM public.vm_create_order(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='active2'),'title','QA free order','order_date','2026-10-29'),
 jsonb_build_array(jsonb_build_object('kind','manual_service','title','Serviço gratuito','quantity','1','unit_price','0','price_override',true,'price_override_reason','serviço gratuito identificado')),
 '40000000-0000-0000-0000-000000000147'::uuid) r;
INSERT INTO qa_payments
SELECT 'first',r.payment_id,r.cash_entry_id
FROM public.vm_record_order_payment(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT order_id FROM qa_orders WHERE kind='payment_order'),40.00::numeric,DATE '2026-10-29','pix','40000000-0000-0000-0000-000000000131'::uuid) r;
SELECT pg_temp.assert_true((SELECT amount FROM vm_order_payments_read WHERE id=(SELECT payment_id FROM qa_payments WHERE kind='first'))='40.00','real payment stores exact positive amount');
SELECT pg_temp.assert_true((SELECT count(*) FROM vm_cash_entries WHERE order_payment_id=(SELECT payment_id FROM qa_payments WHERE kind='first') AND entry_type='income' AND payment_status='paid' AND amount=40.00::numeric AND entry_date=DATE '2026-10-29' AND paid_at=DATE '2026-10-29' AND payment_method='pix' AND created_by=(SELECT user_b FROM qa_identity))=1,'payment creates one linked income with copied stamps');
SELECT pg_temp.assert_true((SELECT paid_amount FROM vm_orders_read WHERE id=(SELECT order_id FROM qa_orders WHERE kind='payment_order'))='40.00' AND (SELECT balance_amount FROM vm_orders_read WHERE id=(SELECT order_id FROM qa_orders WHERE kind='payment_order'))='60.00','order view calculates real paid and balance');
SELECT pg_temp.assert_true((SELECT paid_amount FROM public.vm_record_order_payment(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT order_id FROM qa_orders WHERE kind='payment_order'),40.00::numeric,DATE '2026-10-29','pix','40000000-0000-0000-0000-000000000131'::uuid))='40.00','same payment nonce replays original result');
SELECT pg_temp.assert_true((SELECT count(*) FROM vm_order_payments WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='payment_order'))=1,'payment replay does not create duplicate real payment');
SELECT pg_temp.assert_raises('payment overpay rejected','23514',format($sql$SELECT * FROM public.vm_record_order_payment('%s','%s',60.01::numeric,DATE '2026-10-29','cash','40000000-0000-0000-0000-000000000132'::uuid)$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT order_id FROM qa_orders WHERE kind='payment_order')));
SELECT pg_temp.assert_raises('payment nonce different payload rejected','23505',format($sql$SELECT * FROM public.vm_record_order_payment('%s','%s',41.00::numeric,DATE '2026-10-29','pix','40000000-0000-0000-0000-000000000131'::uuid)$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT order_id FROM qa_orders WHERE kind='payment_order')));
SELECT pg_temp.assert_raises('payment on free balance rejected','23514',format($sql$SELECT * FROM public.vm_record_order_payment('%s','%s',0.01::numeric,DATE '2026-10-29','cash','40000000-0000-0000-0000-000000000133'::uuid)$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT order_id FROM qa_orders WHERE kind='free_order')));
SELECT pg_temp.pass_test('positive real payment cash linkage overpay and nonce collision');

-- Complete a second payment under finance and verify paid amount is still a real
-- ledger sum, not a synthetic paid-on-complete value. The order remains unrelated
-- to production consumption and no fake payment is generated by status changes.
INSERT INTO qa_payments
SELECT 'second',r.payment_id,r.cash_entry_id
FROM public.vm_record_order_payment(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT order_id FROM qa_orders WHERE kind='payment_order'),60.00::numeric,DATE '2026-10-29','cash','40000000-0000-0000-0000-000000000134'::uuid) r;
SELECT pg_temp.assert_true((SELECT count(*) FROM vm_order_payments WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='payment_order'))=2 AND (SELECT paid_amount FROM vm_orders_read WHERE id=(SELECT order_id FROM qa_orders WHERE kind='payment_order'))='100.00' AND (SELECT balance_amount FROM vm_orders_read WHERE id=(SELECT order_id FROM qa_orders WHERE kind='payment_order'))='0.00','two positive payments settle only through two real ledger rows');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','owner')::text,true);
INSERT INTO qa_orders
SELECT 'direct_not_paid',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),r.order_id,'40000000-0000-0000-0000-000000000135'::uuid
FROM public.vm_create_order(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='active2'),'title','QA direct completed unpaid','order_date','2026-10-29','initial_status','Concluído'),
 jsonb_build_array(jsonb_build_object('kind','manual_service','title','Sem recebimento','quantity','1','unit_price','2','price_override',true,'price_override_reason','sem pagamento')),
 '40000000-0000-0000-0000-000000000135'::uuid) r;
SELECT pg_temp.assert_true((SELECT paid_amount FROM vm_orders_read WHERE id=(SELECT order_id FROM qa_orders WHERE kind='direct_not_paid'))='0.00' AND (SELECT count(*) FROM vm_order_payments WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='direct_not_paid'))=0,'completion never fabricates a paid payment');
SELECT pg_temp.pass_test('payment ledger remains real and completion never marks paid');

-- Notification ownership and monotonic read: owner A cannot mark B's row;
-- viewer B can read only own notifications, not private outbox/snapshot/requests.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','owner')::text,true);
CREATE TEMP TABLE qa_owner_notification ON COMMIT DROP AS
SELECT id FROM vm_notifications WHERE recipient_user_id=(SELECT user_a FROM qa_identity) ORDER BY created_at LIMIT 1;
SELECT pg_temp.assert_true((SELECT read_at FROM public.vm_mark_notification_read(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT id FROM qa_owner_notification))) IS NOT NULL,'owner marks own notification through RPC');
SELECT pg_temp.assert_true((SELECT read_at FROM public.vm_mark_notification_read(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT id FROM qa_owner_notification)))=(SELECT read_at FROM vm_notifications WHERE id=(SELECT id FROM qa_owner_notification)),'notification read is monotonic on replay');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_b::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','finance')::text,true);
SELECT pg_temp.assert_raises('member cannot mark another user notification','42501',format($sql$SELECT * FROM public.vm_mark_notification_read('%s','%s')$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT id FROM qa_owner_notification)));
SELECT pg_temp.assert_true((SELECT count(*) FROM vm_notifications)= (SELECT count(*) FROM vm_notifications WHERE recipient_user_id=(SELECT user_b FROM qa_identity)),'notification RLS exposes only recipient rows');
SELECT pg_temp.assert_raises('authenticated cannot read private outbox','42501','SELECT count(*) FROM vm_notification_outbox');
SELECT pg_temp.assert_raises('authenticated cannot read private client snapshot','42501','SELECT count(*) FROM vm_private.vm_order_client_snapshots');
SELECT pg_temp.assert_raises('authenticated cannot read private request ledger','42501','SELECT count(*) FROM vm_private.vm_order_requests');
SELECT pg_temp.pass_test('notification own-read monotonic mark and private table denial');

-- Viewer and finance role barriers use the actual membership role, then reset to
-- owner for final protected-DML and direct catalog checks.
RESET ROLE;
UPDATE public.vm_memberships SET role='viewer'
WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))
  AND user_id=(SELECT user_b FROM qa_identity);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_b::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','viewer')::text,true);
SELECT pg_temp.assert_true((SELECT count(*) FROM vm_orders_read)>0,'viewer can read tenant order view');
SELECT pg_temp.assert_raises('viewer cannot create order','42501',format($sql$SELECT * FROM public.vm_create_order('%s','{"client_id":"%s","title":"viewer blocked","order_date":"2026-10-29"}'::jsonb,'[{"kind":"manual_service","title":"x","quantity":"1","unit_price":"1","price_override":true,"price_override_reason":"r"}]'::jsonb,'40000000-0000-0000-0000-000000000136'::uuid)$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT client_id FROM qa_clients WHERE kind='active2')));
SELECT pg_temp.assert_raises('viewer cannot set status','42501',format($sql$SELECT * FROM public.vm_set_order_status('%s','%s','Concluído',NULL,'40000000-0000-0000-0000-000000000137'::uuid)$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT order_id FROM qa_orders WHERE kind='cancel_before')));
SELECT pg_temp.assert_raises('viewer cannot record payment','42501',format($sql$SELECT * FROM public.vm_record_order_payment('%s','%s',1.00::numeric,DATE '2026-10-29','cash','40000000-0000-0000-0000-000000000138'::uuid)$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT order_id FROM qa_orders WHERE kind='payment_order')));
SELECT pg_temp.assert_true((SELECT count(*) FROM vm_orders_read WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_b FROM qa_identity)))=0,'viewer tenant read has no foreign organization rows');
SELECT pg_temp.pass_test('viewer read-only role and mutation barriers');

-- Cross-tenant token and anonymous no-read/no-write checks.
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','authenticated')::text,true);
SELECT pg_temp.assert_true((SELECT count(*) FROM vm_orders_read WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_b FROM qa_identity)))=0,'owner A cannot read tenant B orders');
SELECT pg_temp.assert_raises('wrong tenant cannot call status','42501',format($sql$SELECT * FROM public.vm_set_order_status('%s','%s','Pendente',NULL,'40000000-0000-0000-0000-000000000139'::uuid)$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_b FROM qa_identity)),(SELECT order_id FROM qa_orders WHERE kind='core')));
SELECT pg_temp.assert_raises('wrong tenant cannot call payment','42501',format($sql$SELECT * FROM public.vm_record_order_payment('%s','%s',1.00::numeric,DATE '2026-10-29','cash','40000000-0000-0000-0000-000000000140'::uuid)$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_b FROM qa_identity)),(SELECT order_id FROM qa_orders WHERE kind='payment_order')));
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','anon',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','anon')::text,true);
SELECT pg_temp.assert_raises('anon cannot read orders','42501','SELECT count(*) FROM public.vm_orders_read');
SELECT pg_temp.assert_raises('anon cannot execute create order','42501',format($sql$SELECT * FROM public.vm_create_order('%s','{"client_id":"%s","title":"anon blocked","order_date":"2026-10-29"}'::jsonb,'[{"kind":"manual_service","title":"x","quantity":"1","unit_price":"1","price_override":true,"price_override_reason":"r"}]'::jsonb,'40000000-0000-0000-0000-000000000141'::uuid)$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT client_id FROM qa_clients WHERE kind='active2')));
RESET ROLE;
SELECT pg_temp.pass_test('wrong tenant token and anonymous no-read no-write barriers');

-- Direct DML is denied to API roles and immutable guards reject privileged
-- commercial/history mutations. This exercises guard paths, not a fake API.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','owner')::text,true);
SELECT pg_temp.assert_raises('authenticated cannot update order directly','42501',format($sql$UPDATE public.vm_orders SET title='tamper' WHERE id='%s'$sql$,(SELECT order_id FROM qa_orders WHERE kind='core')));
SELECT pg_temp.assert_raises('authenticated cannot update frozen item directly','42501',format($sql$UPDATE public.vm_order_items SET unit_price=99 WHERE order_id='%s'$sql$,(SELECT order_id FROM qa_orders WHERE kind='core')));
SELECT pg_temp.assert_raises('authenticated cannot delete order event directly','42501',format($sql$DELETE FROM public.vm_order_events WHERE order_id='%s'$sql$,(SELECT order_id FROM qa_orders WHERE kind='core')));
RESET ROLE;
SELECT pg_temp.assert_raises('privileged commercial order mutation hits guard','55000',format($sql$UPDATE public.vm_orders SET title='tamper' WHERE id='%s'$sql$,(SELECT order_id FROM qa_orders WHERE kind='core')));
SELECT pg_temp.assert_raises('privileged immutable item mutation hits append-only guard','55000',format($sql$DELETE FROM public.vm_order_items WHERE order_id='%s'$sql$,(SELECT order_id FROM qa_orders WHERE kind='core')));
SELECT pg_temp.assert_raises('privileged event mutation hits append-only guard','55000',format($sql$DELETE FROM public.vm_order_events WHERE order_id='%s'$sql$,(SELECT order_id FROM qa_orders WHERE kind='core')));
SELECT pg_temp.pass_test('API DML denial and privileged immutable history guards');

-- Deferred integrity is checked explicitly after a harmless read-only command;
-- all normal RPC writes leave both sides valid at COMMIT and at SET CONSTRAINTS.
SET CONSTRAINTS ALL IMMEDIATE;
SELECT pg_temp.assert_true((SELECT count(*) FROM vm_order_payments p JOIN vm_cash_entries c ON c.organization_id=p.organization_id AND c.order_payment_id=p.id)=
                          (SELECT count(*) FROM vm_order_payments),'all payment rows have deferred cash links at immediate validation');
SELECT pg_temp.assert_true((SELECT count(*) FROM vm_order_consumption_runs r JOIN vm_orders o ON o.organization_id=r.organization_id AND o.id=r.order_id AND o.consumed_at=r.consumed_at)=
                          (SELECT count(*) FROM vm_order_consumption_runs),'all consumption runs have deferred order marks at immediate validation');
SELECT pg_temp.pass_test('deferred payment and consumption constraints validate explicitly');

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','authenticated')::text,true);
SELECT * FROM public.vm_create_order(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='active2'),'title','QA concurrency order','order_date','2026-10-29'),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_products WHERE kind='base'),'quantity','1')),
 '40000000-0000-0000-0000-000000000146'::uuid);
RESET ROLE;
SELECT pg_temp.assert_true(current_user='ubuntu','orders suite returns to local admin after role checks');
