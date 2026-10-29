-- Physical order-return contract suite.  The runner applies the cumulative
-- local migration chain through 20261030002200 and executes this in one
-- rollback-safe vm_test transaction.  No Supabase/application data is used.

CREATE TEMP TABLE qa_test_results (
  ordinal integer GENERATED ALWAYS AS IDENTITY,
  label text NOT NULL
) ON COMMIT PRESERVE ROWS;

CREATE OR REPLACE FUNCTION pg_temp.assert_true(p_condition boolean,p_label text)
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
CREATE TEMP TABLE qa_orgs(user_id uuid NOT NULL,organization_id uuid PRIMARY KEY,membership_id uuid NOT NULL) ON COMMIT DROP;
CREATE TEMP TABLE qa_clients(kind text PRIMARY KEY,organization_id uuid NOT NULL,client_id uuid NOT NULL) ON COMMIT DROP;
CREATE TEMP TABLE qa_materials(kind text PRIMARY KEY,organization_id uuid NOT NULL,material_id uuid NOT NULL) ON COMMIT DROP;
CREATE TEMP TABLE qa_products(kind text PRIMARY KEY,organization_id uuid NOT NULL,product_id uuid NOT NULL) ON COMMIT DROP;
CREATE TEMP TABLE qa_orders(kind text PRIMARY KEY,organization_id uuid NOT NULL,order_id uuid NOT NULL) ON COMMIT DROP;
GRANT SELECT ON qa_identity,qa_orgs,qa_clients,qa_materials,qa_products,qa_orders TO authenticated,anon;
GRANT INSERT ON qa_orgs,qa_clients,qa_materials,qa_products,qa_orders TO authenticated;

-- The two tenants are real local organizations created through the public RPC.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','authenticated')::text,true);
INSERT INTO qa_orgs
SELECT i.user_a,c.organization_id,c.membership_id
FROM qa_identity i CROSS JOIN LATERAL public.vm_create_organization('Returns tenant A') c;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_b::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','authenticated')::text,true);
INSERT INTO qa_orgs
SELECT i.user_b,c.organization_id,c.membership_id
FROM qa_identity i CROSS JOIN LATERAL public.vm_create_organization('Returns tenant B') c;
SELECT pg_temp.assert_true((SELECT count(*) FROM qa_orgs)=2,'local tenants created through organization RPC');

-- A real viewer membership in tenant A exercises the role barrier without
-- spoofing auth.uid; this direct fixture setup is the same local QA pattern as
-- the existing database suites.
RESET ROLE;
INSERT INTO public.vm_memberships(organization_id,user_id,role)
VALUES((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
       (SELECT user_b FROM qa_identity),'viewer');

-- Owner A creates the active client and two materials through public RPCs.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','owner')::text,true);
INSERT INTO qa_clients
SELECT 'main',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),c.contact_id
FROM public.vm_upsert_contact(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 'client','{"name":"Cliente de devolução","person_type":"individual"}'::jsonb,
 NULL,'60000000-0000-0000-0000-000000000001'::uuid) c;
INSERT INTO qa_materials
SELECT 'consumed',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),m.material_id
FROM public.vm_create_material(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 'Material devolvido','g',4.00000000::numeric,1.00000000::numeric,10.00000000::numeric,0::numeric,
 'returns',NULL::uuid,'60000000-0000-0000-0000-000000000010'::uuid) m;
INSERT INTO qa_materials
SELECT 'not_consumed',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),m.material_id
FROM public.vm_create_material(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 'Material não consumido','g',2.00000000::numeric,1.00000000::numeric,3.00000000::numeric,0::numeric,
 'returns',NULL::uuid,'60000000-0000-0000-0000-000000000011'::uuid) m;
SELECT pg_temp.assert_true((SELECT count(*) FROM qa_materials)=2,'own materials created through inventory RPC');

-- Product recipe consumes exactly two units of the first material per order.
INSERT INTO qa_products
SELECT 'single_material',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),p.product_id
FROM public.vm_upsert_product_v2(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 'Produto devolução','returns','[]'::jsonb,NULL,NULL,NULL,NULL,0,'unit',20.00000000::numeric,NULL,1.00000000::numeric,'unit',false,false,
 '[]'::jsonb,NULL,NULL,NULL,NULL,'RET-001',NULL,'[]'::jsonb,
 jsonb_build_array(jsonb_build_object('material_id',(SELECT material_id FROM qa_materials WHERE kind='consumed'),'quantity','2.00000000','unit','g')),
 '[]'::jsonb,NULL,'60000000-0000-0000-0000-000000000020'::uuid) p;
SELECT pg_temp.assert_true((SELECT count(*) FROM qa_products)=1,'own product recipe created through product RPC');

-- A pending order is canceled before consumption and must never become
-- returnable.  It is also the explicit no-automatic-return fixture.
INSERT INTO qa_orders
SELECT 'cancel_before',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),r.order_id
FROM public.vm_create_order(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='main'),'title','Return cancel before','order_date','2026-10-29'),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_products WHERE kind='single_material'),'quantity','1')),
 '60000000-0000-0000-0000-000000000100'::uuid) r;
SELECT * FROM public.vm_set_order_status(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 (SELECT order_id FROM qa_orders WHERE kind='cancel_before'),'Cancelado','cancelado antes da baixa',
 '60000000-0000-0000-0000-000000000101'::uuid);

-- Main fixture: create, consume through the real status RPC, then cancel.
INSERT INTO qa_orders
SELECT 'partial',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),r.order_id
FROM public.vm_create_order(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='main'),'title','Return partial physical','order_date','2026-10-29'),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_products WHERE kind='single_material'),'quantity','1')),
 '60000000-0000-0000-0000-000000000102'::uuid) r;
SELECT pg_temp.assert_true((SELECT status FROM public.vm_set_order_status(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 (SELECT order_id FROM qa_orders WHERE kind='partial'),'Em Produção',NULL,
 '60000000-0000-0000-0000-000000000103'::uuid))='Em Produção','real order consumption succeeds');
SELECT pg_temp.assert_true((SELECT status FROM public.vm_set_order_status(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 (SELECT order_id FROM qa_orders WHERE kind='partial'),'Cancelado','cancelado após baixa',
 '60000000-0000-0000-0000-000000000104'::uuid))='Cancelado','real consumed order cancellation succeeds');
SELECT pg_temp.assert_true(
 (SELECT stock_quantity FROM public.vm_materials WHERE id=(SELECT material_id FROM qa_materials WHERE kind='consumed'))=8.00000000::numeric
 AND (SELECT count(*) FROM public.vm_order_consumption_runs WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='partial'))=1
 AND (SELECT count(*) FROM public.vm_stock_movements WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='partial') AND movement_type='order_return')=0,
 'cancellation keeps consumed stock and creates no automatic return');
SELECT pg_temp.pass_test('real fixture is created through public RPCs and cancel has no automatic return');

SELECT pg_temp.assert_raises('cancel-before-consumption cannot return','23514',format($sql$
 SELECT * FROM public.vm_record_order_return('%s','%s','too early',
   '[{"material_id":"%s","quantity":"0.5"}]'::jsonb,'60000000-0000-0000-0000-000000000105'::uuid)
$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 (SELECT order_id FROM qa_orders WHERE kind='cancel_before'),
 (SELECT material_id FROM qa_materials WHERE kind='consumed')));
SELECT pg_temp.pass_test('cancellation before consumption is rejected by return RPC');

-- Operator chooses the actual physical quantity, not an automatic full return.
CREATE TEMP TABLE qa_first_return ON COMMIT DROP AS
SELECT * FROM public.vm_record_order_return(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 (SELECT order_id FROM qa_orders WHERE kind='partial'),
 'devolução física parcial conferida',
 jsonb_build_array(jsonb_build_object('material_id',(SELECT material_id FROM qa_materials WHERE kind='consumed'),'quantity','0.50000000')),
 '60000000-0000-0000-0000-000000000106'::uuid);
SELECT pg_temp.assert_true(
 (SELECT line_count FROM qa_first_return)='1'
 AND (SELECT returned_quantity FROM qa_first_return)='0.50000000'
 AND (SELECT remaining_quantity FROM qa_first_return)='1.50000000'
 AND (SELECT stock_quantity FROM public.vm_materials WHERE id=(SELECT material_id FROM qa_materials WHERE kind='consumed'))=8.50000000::numeric,
 'partial physical quantity restores exact stock and preserves remaining consumption');
SELECT pg_temp.assert_true(
 (SELECT count(*) FROM public.vm_order_return_events WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='partial'))=1
 AND (SELECT count(*) FROM public.vm_order_return_lines WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='partial'))=1
 AND (SELECT count(*) FROM public.vm_stock_movements WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='partial') AND movement_type='order_return')=1
 AND (SELECT quantity_delta FROM public.vm_stock_movements WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='partial') AND movement_type='order_return')=0.50000000::numeric,
 'return event line and positive order_return movement are atomic');
SELECT pg_temp.assert_true(
 (SELECT original_consumed_quantity FROM public.vm_order_returns_read WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='partial'))='2.00000000'
 AND (SELECT returned_quantity_total FROM public.vm_order_returns_read WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='partial'))='0.50000000'
 AND (SELECT remaining_quantity FROM public.vm_order_returns_read WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='partial'))='1.50000000'
 AND (SELECT stock_after FROM public.vm_order_returns_read WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='partial'))='8.50000000',
 'member read view exposes textual original restored and remaining quantities');
SELECT pg_temp.pass_test('partial actual return and textual read view');

-- A second physical request on the same material cannot exceed remaining
-- consumption; duplicate JSON entries are rejected before any write.
SELECT pg_temp.assert_raises('return overflow is rejected','23514',format($sql$
 SELECT * FROM public.vm_record_order_return('%s','%s','excesso',
   '[{"material_id":"%s","quantity":"1.50000001"}]'::jsonb,'60000000-0000-0000-0000-000000000107'::uuid)
$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 (SELECT order_id FROM qa_orders WHERE kind='partial'),
 (SELECT material_id FROM qa_materials WHERE kind='consumed')));
SELECT pg_temp.assert_raises('duplicate material entries are rejected','22023',format($sql$
 SELECT * FROM public.vm_record_order_return('%s','%s','duplicado',
   '[{"material_id":"%s","quantity":"0.1"},{"material_id":"%s","quantity":"0.1"}]'::jsonb,'60000000-0000-0000-0000-000000000108'::uuid)
$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 (SELECT order_id FROM qa_orders WHERE kind='partial'),
 (SELECT material_id FROM qa_materials WHERE kind='consumed'),
 (SELECT material_id FROM qa_materials WHERE kind='consumed')));
SELECT pg_temp.pass_test('overflow and duplicate material guards preserve ledger');

-- Every line is validated before any increase: the valid first material is
-- mixed with an existing but unconsumed material and must roll back entirely.
RESET ROLE;
CREATE TEMP TABLE qa_mixed_before ON COMMIT DROP AS
SELECT
 (SELECT stock_quantity FROM public.vm_materials WHERE id=(SELECT material_id FROM qa_materials WHERE kind='consumed')) AS stock,
 (SELECT count(*) FROM public.vm_order_return_events WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='partial')) AS events,
 (SELECT count(*) FROM public.vm_order_return_lines WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='partial')) AS lines,
 (SELECT count(*) FROM public.vm_stock_movements WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='partial') AND movement_type='order_return') AS movements,
 (SELECT count(*) FROM vm_private.vm_order_requests WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='partial') AND operation='order_return') AS requests;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','owner')::text,true);
SELECT pg_temp.assert_raises('mixed valid and unconsumed materials roll back stock','23503',format($sql$
 SELECT * FROM public.vm_record_order_return('%s','%s','mistura inválida',
   '[{"material_id":"%s","quantity":"0.25"},{"material_id":"%s","quantity":"0.25"}]'::jsonb,'60000000-0000-0000-0000-000000000109'::uuid)
$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 (SELECT order_id FROM qa_orders WHERE kind='partial'),
 (SELECT material_id FROM qa_materials WHERE kind='consumed'),
 (SELECT material_id FROM qa_materials WHERE kind='not_consumed')));
RESET ROLE;
SELECT pg_temp.assert_true(
 (SELECT stock FROM qa_mixed_before)=(SELECT stock_quantity FROM public.vm_materials WHERE id=(SELECT material_id FROM qa_materials WHERE kind='consumed'))
 AND (SELECT events FROM qa_mixed_before)=(SELECT count(*) FROM public.vm_order_return_events WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='partial'))
 AND (SELECT lines FROM qa_mixed_before)=(SELECT count(*) FROM public.vm_order_return_lines WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='partial'))
 AND (SELECT movements FROM qa_mixed_before)=(SELECT count(*) FROM public.vm_stock_movements WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='partial') AND movement_type='order_return')
 AND (SELECT requests FROM qa_mixed_before)=(SELECT count(*) FROM vm_private.vm_order_requests WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='partial') AND operation='order_return'),
 'mixed request has no partial event movement request or stock increase');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','owner')::text,true);
SELECT pg_temp.pass_test('mixed request validates all lines before stock mutation');

-- Exact replay is durable: a current stock change does not change the
-- original result and does not add a second event/line/movement.
SELECT * FROM public.vm_adjust_material_stock_safe(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 (SELECT material_id FROM qa_materials WHERE kind='consumed'),1.00000000::numeric,'cycle count after return',
 '60000000-0000-0000-0000-000000000110'::uuid);
CREATE TEMP TABLE qa_replay ON COMMIT DROP AS
SELECT * FROM public.vm_record_order_return(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 (SELECT order_id FROM qa_orders WHERE kind='partial'),
 'devolução física parcial conferida',
 jsonb_build_array(jsonb_build_object('material_id',(SELECT material_id FROM qa_materials WHERE kind='consumed'),'quantity','0.50000000')),
 '60000000-0000-0000-0000-000000000106'::uuid);
SELECT pg_temp.assert_true(
 (SELECT return_id FROM qa_replay)=(SELECT return_id FROM qa_first_return)
 AND (SELECT line_count FROM qa_replay)=(SELECT line_count FROM qa_first_return)
 AND (SELECT returned_quantity FROM qa_replay)=(SELECT returned_quantity FROM qa_first_return)
 AND (SELECT remaining_quantity FROM qa_replay)=(SELECT remaining_quantity FROM qa_first_return)
 AND (SELECT count(*) FROM public.vm_order_return_events WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='partial'))=1
 AND (SELECT count(*) FROM public.vm_stock_movements WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='partial') AND movement_type='order_return')=1,
 'same idempotency key replays original counts without extra event or movement');
SELECT pg_temp.assert_raises('same return key with different payload is rejected','23505',format($sql$
 SELECT * FROM public.vm_record_order_return('%s','%s','motivo diferente',
   '[{"material_id":"%s","quantity":"0.40000000"}]'::jsonb,'60000000-0000-0000-0000-000000000106'::uuid)
$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 (SELECT order_id FROM qa_orders WHERE kind='partial'),
 (SELECT material_id FROM qa_materials WHERE kind='consumed')));
SELECT pg_temp.pass_test('durable idempotency replay and exact payload collision');

-- A delivered order cannot be canceled first, so it is not returnable.
INSERT INTO qa_orders
SELECT 'delivered',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),r.order_id
FROM public.vm_create_order(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='main'),'title','Return delivered','order_date','2026-10-29','initial_status','Concluído'),
 jsonb_build_array(jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_products WHERE kind='single_material'),'quantity','1')),
 '60000000-0000-0000-0000-000000000111'::uuid) r;
SELECT pg_temp.assert_true((SELECT status FROM public.vm_set_order_status(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 (SELECT order_id FROM qa_orders WHERE kind='delivered'),'Entregue',NULL,
 '60000000-0000-0000-0000-000000000112'::uuid))='Entregue','delivered order reaches terminal delivery state');
SELECT pg_temp.assert_raises('delivered order cannot be returned','22023',format($sql$
 SELECT * FROM public.vm_record_order_return('%s','%s','não entregue fisicamente',
   '[{"material_id":"%s","quantity":"0.5"}]'::jsonb,'60000000-0000-0000-0000-000000000113'::uuid)
$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 (SELECT order_id FROM qa_orders WHERE kind='delivered'),
 (SELECT material_id FROM qa_materials WHERE kind='consumed')));
SELECT pg_temp.pass_test('delivered order is not returnable without a prior cancellation');

-- Viewer and wrong-tenant owner cannot mutate; members can read only their own
-- tenant's return view. Anonymous has neither read nor RPC execution.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_b::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','viewer')::text,true);
SELECT pg_temp.assert_true((SELECT count(*) FROM public.vm_order_returns_read)>0,'readonly member can read return view');
SELECT pg_temp.assert_raises('viewer cannot record physical return', '42501', format($sql$
 SELECT * FROM public.vm_record_order_return('%s','%s','viewer',
   '[{"material_id":"%s","quantity":"0.1"}]'::jsonb,'60000000-0000-0000-0000-000000000114'::uuid)
$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 (SELECT order_id FROM qa_orders WHERE kind='partial'),
 (SELECT material_id FROM qa_materials WHERE kind='consumed')));
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','owner')::text,true);
SELECT pg_temp.assert_raises('owner cannot use another tenant return RPC','42501',format($sql$
 SELECT * FROM public.vm_record_order_return('%s','%s','cross tenant',
   '[{"material_id":"%s","quantity":"0.1"}]'::jsonb,'60000000-0000-0000-0000-000000000115'::uuid)
$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_b FROM qa_identity)),
 (SELECT order_id FROM qa_orders WHERE kind='partial'),
 (SELECT material_id FROM qa_materials WHERE kind='consumed')));
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','anon',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','anon')::text,true);
SELECT pg_temp.assert_raises('anon cannot read return view','42501','SELECT count(*) FROM public.vm_order_returns_read');
SELECT pg_temp.assert_raises('anon cannot execute return RPC','42501',format($sql$
 SELECT * FROM public.vm_record_order_return('%s','%s','anon',
   '[{"material_id":"%s","quantity":"0.1"}]'::jsonb,'60000000-0000-0000-0000-000000000116'::uuid)
$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 (SELECT order_id FROM qa_orders WHERE kind='partial'),
 (SELECT material_id FROM qa_materials WHERE kind='consumed')));
RESET ROLE;
SELECT pg_temp.pass_test('viewer read-only wrong-tenant and anonymous barriers');

-- Direct DML remains denied to API roles; owner/admin mutation is through the
-- RPC only, and append-only ledgers reject privileged edits/deletes.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','owner')::text,true);
SELECT pg_temp.assert_raises('authenticated cannot update return event directly','42501',format($sql$
 UPDATE public.vm_order_return_events SET reason='tamper' WHERE id='%s'
$sql$,(SELECT return_id FROM qa_first_return)));
RESET ROLE;
SELECT pg_temp.assert_raises('privileged return event update hits immutable guard','55000',format($sql$
 UPDATE public.vm_order_return_events SET reason='tamper' WHERE id='%s'
$sql$,(SELECT return_id FROM qa_first_return)));
SELECT pg_temp.assert_raises('privileged return line delete hits immutable guard','55000',format($sql$
 DELETE FROM public.vm_order_return_lines WHERE return_event_id='%s'
$sql$,(SELECT return_id FROM qa_first_return)));
SELECT pg_temp.assert_true(
 NOT has_function_privilege('authenticated','vm_private.vm_order_return_canonical(jsonb)','EXECUTE')
 AND NOT has_function_privilege('authenticated','vm_private.vm_order_return_complete()','EXECUTE'),
 'private helper functions have no API execution grant');
SELECT pg_temp.assert_true(has_function_privilege('authenticated','public.vm_record_order_return(uuid,uuid,text,jsonb,uuid)','EXECUTE'),'authenticated has only public return RPC execution');
SELECT pg_temp.pass_test('RLS direct DML denial append-only guards and private helper grants');

SET CONSTRAINTS ALL IMMEDIATE;
SELECT pg_temp.assert_true(
 (SELECT count(*) FROM public.vm_order_return_events e JOIN public.vm_order_return_lines l ON l.organization_id=e.organization_id AND l.return_event_id=e.id)
 = (SELECT count(*) FROM public.vm_order_return_lines),
 'deferred return event and line integrity validates at commit');
RESET ROLE;
SELECT pg_temp.assert_true(current_user='ubuntu','returns suite returns to local admin after role checks');
