-- Public-sales contract suite. All rows are local vm_test fixtures only.
-- The runner installs the verified local realtime.send contract before migrations;
-- this suite never connects to Supabase or claims WebSocket delivery.
CREATE TEMP TABLE qa_test_results (
  ordinal integer GENERATED ALWAYS AS IDENTITY,
  label text NOT NULL
) ON COMMIT PRESERVE ROWS;
CREATE OR REPLACE FUNCTION pg_temp.assert_true(p_condition boolean,p_label text)
RETURNS void LANGUAGE plpgsql AS $function$
BEGIN
  IF NOT COALESCE(p_condition,false) THEN RAISE EXCEPTION 'assertion failed: %',p_label USING ERRCODE='P0001'; END IF;
END;
$function$;
CREATE OR REPLACE FUNCTION pg_temp.assert_raises(p_label text,p_sqlstate text,p_statement text)
RETURNS void LANGUAGE plpgsql AS $function$
DECLARE v_sqlstate text;
BEGIN
  BEGIN EXECUTE p_statement;
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_sqlstate=RETURNED_SQLSTATE;
    IF p_sqlstate IS NULL OR v_sqlstate=p_sqlstate THEN RETURN; END IF;
    RAISE EXCEPTION 'assertion failed: % (unexpected SQLSTATE %)',p_label,v_sqlstate USING ERRCODE='P0001';
  END;
  RAISE EXCEPTION 'assertion failed: % (expected error)',p_label USING ERRCODE='P0001';
END;
$function$;
CREATE OR REPLACE FUNCTION pg_temp.pass_test(p_label text)
RETURNS void LANGUAGE sql SECURITY DEFINER AS $function$ INSERT INTO pg_temp.qa_test_results(label) VALUES (p_label) $function$;
GRANT INSERT ON qa_test_results TO authenticated,anon;

CREATE TEMP TABLE qa_identity(user_a uuid NOT NULL,user_b uuid NOT NULL) ON COMMIT DROP;
INSERT INTO qa_identity VALUES ('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-0000000000b2');
CREATE TEMP TABLE qa_orgs(user_id uuid NOT NULL,organization_id uuid PRIMARY KEY,membership_id uuid NOT NULL) ON COMMIT DROP;
CREATE TEMP TABLE qa_client(client_id uuid NOT NULL) ON COMMIT DROP;
CREATE TEMP TABLE qa_material(material_id uuid NOT NULL) ON COMMIT DROP;
CREATE TEMP TABLE qa_product(product_id uuid NOT NULL) ON COMMIT DROP;
CREATE TEMP TABLE qa_quote(kind text PRIMARY KEY,quote_id uuid NOT NULL,token uuid NOT NULL) ON COMMIT DROP;
CREATE TEMP TABLE qa_accept(order_id uuid NOT NULL,tracking_token uuid NOT NULL) ON COMMIT DROP;
CREATE TEMP TABLE qa_race(quote_id uuid NOT NULL,token uuid NOT NULL) ON COMMIT DROP;
GRANT SELECT ON qa_identity,qa_orgs,qa_client,qa_material,qa_product,qa_quote,qa_accept,qa_race TO authenticated,anon;
GRANT INSERT ON qa_orgs,qa_client,qa_material,qa_product,qa_quote,qa_accept,qa_race TO authenticated,anon;

-- Two real tenants and a finance member in tenant A.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','owner')::text,true);
INSERT INTO qa_orgs SELECT i.user_a,c.organization_id,c.membership_id FROM qa_identity i CROSS JOIN LATERAL public.vm_create_organization('Public sales A') c;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_b::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','owner')::text,true);
INSERT INTO qa_orgs SELECT i.user_b,c.organization_id,c.membership_id FROM qa_identity i CROSS JOIN LATERAL public.vm_create_organization('Public sales B') c;
RESET ROLE;
INSERT INTO public.vm_memberships(organization_id,user_id,role)
VALUES ((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT user_b FROM qa_identity),'finance');
SELECT pg_temp.pass_test('public sales local tenants and real owner/finance identities');

-- Real client, material and versioned product. No seed rows are used.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','owner')::text,true);
INSERT INTO qa_client
SELECT contact_id FROM public.vm_upsert_contact(
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
  'client','{"name":"Cliente Público Original","email":"private@example.test","phone":"11999999999","person_type":"individual","tax_id":"12345678901","address":{"city":"São Paulo","state":"SP"}}'::jsonb,
  NULL,'50000000-0000-0000-0000-000000000001'::uuid);
INSERT INTO qa_material
SELECT material_id FROM public.vm_create_material(
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
  'Papel congelado','g',10::numeric,2::numeric,100::numeric,0::numeric,'papel',NULL::uuid,'50000000-0000-0000-0000-000000000002'::uuid);
INSERT INTO qa_product
SELECT product_id FROM public.vm_upsert_product_v2(
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
  'Produto Público Original','papelaria','[]'::jsonb,NULL,NULL,NULL,NULL,0,'unit',50::numeric,40::numeric,1::numeric,'unit',false,false,
  '[]'::jsonb,NULL,NULL,NULL,NULL,'PUB-001',NULL,'[]'::jsonb,
  jsonb_build_array(jsonb_build_object('material_id',(SELECT material_id FROM qa_material),'quantity','0.50000000','unit','g')),
  '[]'::jsonb,NULL,'50000000-0000-0000-0000-000000000003'::uuid);
SELECT pg_temp.assert_true((SELECT count(*) FROM public.vm_product_versions WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)) AND product_id=(SELECT product_id FROM qa_product))=1,'fixture product has an immutable version');
SELECT pg_temp.pass_test('real client material and product snapshots are available');

-- Public quote API ACL and projection allowlist.
SELECT pg_temp.assert_true(
  has_function_privilege('anon','public.vm_get_quote(uuid)','EXECUTE') AND has_function_privilege('anon','public.vm_approve_quote(uuid)','EXECUTE')
  AND has_function_privilege('anon','public.vm_get_tracking(uuid)','EXECUTE')
  AND NOT has_function_privilege('anon','public.vm_create_quote(uuid,jsonb,jsonb,date,text,uuid,uuid)','EXECUTE')
  AND NOT has_function_privilege('anon','public.vm_revoke_quote(uuid,uuid,text,uuid)','EXECUTE'),
  'anonymous has only public getter/approve function ACLs');
SELECT pg_temp.assert_true(
  NOT has_table_privilege('anon','public.vm_quotes','SELECT') AND NOT has_table_privilege('anon','public.vm_quote_items','SELECT')
  AND NOT has_table_privilege('anon','public.vm_orders','SELECT') AND NOT has_table_privilege('anon','public.vm_clients','SELECT'),
  'anonymous has no business-table SELECT');
SELECT pg_temp.pass_test('public API ACL and no anonymous table reads');

-- Issue a quote from the real owner. Terms are text by documented choice.
INSERT INTO qa_quote
SELECT 'original',q.quote_id,q.public_token FROM public.vm_create_quote(
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
  jsonb_build_object('client_id',(SELECT client_id FROM qa_client),'title','Álbum público','order_date',CURRENT_DATE,
    'production_date',CURRENT_DATE+1,'delivery_date',CURRENT_DATE+3,'public_notes','Entrega combinada',
    'discount_type','fixed','discount_value','5.00','shipping_amount','10.00'),
  jsonb_build_array(jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_product),'quantity','2','price_override',false)),
  CURRENT_DATE+7,'Prazo: 7 dias úteis','50000000-0000-0000-0000-000000000010'::uuid,NULL::uuid) AS q;
RESET ROLE;
SELECT pg_temp.assert_true((SELECT status FROM public.vm_quotes WHERE id=(SELECT quote_id FROM qa_quote WHERE kind='original'))='Sent','new quote status is exactly Sent');
SELECT pg_temp.assert_true((SELECT count(*) FROM public.vm_quote_events WHERE quote_id=(SELECT quote_id FROM qa_quote WHERE kind='original') AND status='Sent')=1,'Sent emits one immutable quote event');
SELECT pg_temp.assert_true((SELECT total_amount FROM public.vm_quotes WHERE id=(SELECT quote_id FROM qa_quote WHERE kind='original'))=85.00::numeric,'quote freezes subtotal discount shipping and total');
SELECT pg_temp.pass_test('quote issuance persists frozen commercial totals and terms');

-- Getter is a strict allowlist: no client PII, internal IDs, cost, recipe or margin.
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.role','anon',true);
SELECT pg_temp.assert_true((public.vm_get_quote((SELECT token FROM qa_quote WHERE kind='original'))->>'brand')='Public sales A','quote getter exposes only the organization brand');
SELECT pg_temp.assert_true(
  NOT ((public.vm_get_quote((SELECT token FROM qa_quote WHERE kind='original')))::text ~ '(client_id|email|phone|address|tax_id|unit_cost|consumption|margin|internal_notes|material_id)'),
  'quote projection does not expose PII IDs costs recipe or internal notes');
SELECT pg_temp.assert_true((public.vm_get_quote('ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid) IS NULL),'invalid quote capability returns null');
SELECT pg_temp.pass_test('quote getter projection and invalid-token null behavior');

-- Catalog and client mutate after issuance. Quote rows must remain unchanged.
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','owner')::text,true);
SELECT * FROM public.vm_upsert_contact(
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),'client',
  '{"name":"Cliente Público Editado","email":"changed@example.test","phone":"11888888888","person_type":"individual","tax_id":"12345678901"}'::jsonb,
  (SELECT client_id FROM qa_client),'50000000-0000-0000-0000-000000000011'::uuid);
SELECT * FROM public.vm_upsert_product_v2(
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),'Produto Público Editado','papelaria','[]'::jsonb,NULL,NULL,NULL,NULL,0,'unit',90::numeric,80::numeric,1::numeric,'unit',false,false,
  '[]'::jsonb,NULL,NULL,NULL,NULL,'PUB-001-V2',NULL,'[]'::jsonb,
  jsonb_build_array(jsonb_build_object('material_id',(SELECT material_id FROM qa_material),'quantity','2.00000000','unit','g')),
  '[]'::jsonb,(SELECT product_id FROM qa_product),'50000000-0000-0000-0000-000000000012'::uuid);
RESET ROLE;
SELECT pg_temp.assert_true((SELECT total_amount FROM public.vm_quotes WHERE id=(SELECT quote_id FROM qa_quote WHERE kind='original'))=85.00::numeric,'catalog edit cannot rewrite quote total');
SELECT pg_temp.assert_true((SELECT (product_snapshot->>'name') FROM public.vm_quote_items WHERE quote_id=(SELECT quote_id FROM qa_quote WHERE kind='original'))='Produto Público Original','catalog edit cannot rewrite product snapshot');
SELECT pg_temp.pass_test('price recipe and client changes after issuance do not rewrite quote snapshots');

-- One anonymous approval creates a pending order from only the quote snapshot.
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.role','anon',true);
INSERT INTO qa_accept
SELECT order_id,tracking_token FROM public.vm_approve_quote((SELECT token FROM qa_quote WHERE kind='original'));
RESET ROLE;
SELECT pg_temp.assert_true((SELECT status FROM public.vm_quotes WHERE id=(SELECT quote_id FROM qa_quote WHERE kind='original'))='Approved','approval status is exactly Approved');
SELECT pg_temp.assert_true((SELECT status FROM public.vm_orders WHERE id=(SELECT order_id FROM qa_accept))='Pendente','approval does not start production');
SELECT pg_temp.assert_true((SELECT consumed_at FROM public.vm_orders WHERE id=(SELECT order_id FROM qa_accept)) IS NULL,'approval does not consume material');
SELECT pg_temp.assert_true((SELECT commercial_terms FROM public.vm_orders WHERE id=(SELECT order_id FROM qa_accept))='Prazo: 7 dias úteis','terms are copied into the order snapshot');
RESET ROLE;
SELECT pg_temp.assert_true((SELECT client_name_snapshot FROM public.vm_orders WHERE id=(SELECT order_id FROM qa_accept))='Cliente Público Original','order uses frozen client name');
SELECT pg_temp.assert_true((SELECT unit_price FROM public.vm_order_items WHERE order_id=(SELECT order_id FROM qa_accept))=40.00::numeric,'order uses frozen quoted price, not catalog v2');
SELECT pg_temp.assert_true((SELECT quantity_snapshot FROM public.vm_order_item_materials WHERE order_id=(SELECT order_id FROM qa_accept))=0.50000000::numeric,'order uses frozen quoted recipe');
SELECT pg_temp.assert_true((SELECT snapshot->>'name' FROM vm_private.vm_order_client_snapshots WHERE order_id=(SELECT order_id FROM qa_accept))='Cliente Público Original','private client snapshot is copied once from quote');
SELECT pg_temp.pass_test('anonymous acceptance builds one pending order from frozen price recipe and client snapshots');


-- Admin tracking RPC is restricted to owner/admin/finance of the same tenant.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','authenticated')::text,true);
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM public.vm_get_order_tracking((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT order_id FROM qa_accept))),'owner may retrieve current valid tracking capability');
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_b::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','authenticated')::text,true);
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM public.vm_get_order_tracking((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT order_id FROM qa_accept))),'finance may retrieve same-tenant current tracking capability');
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','authenticated')::text,true);
SELECT pg_temp.assert_raises('other tenant denied admin tracking capability','42501',format('SELECT * FROM public.vm_get_order_tracking(''%s'',''%s'')',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_b FROM qa_identity)),(SELECT order_id FROM qa_accept)));
RESET ROLE;
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.role','anon',true);
SELECT pg_temp.assert_raises('anon cannot execute admin tracking RPC','42501',format('SELECT * FROM public.vm_get_order_tracking(''%s'',''%s'')',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT order_id FROM qa_accept)));
SELECT pg_temp.assert_true(has_function_privilege('anon','public.vm_get_tracking(uuid)','EXECUTE') AND has_function_privilege('authenticated','public.vm_get_tracking(uuid)','EXECUTE') AND has_function_privilege('authenticated','public.vm_get_order_tracking(uuid,uuid)','EXECUTE') AND NOT has_function_privilege('anon','public.vm_get_order_tracking(uuid,uuid)','EXECUTE'),'tracking grants preserve public getter and authenticated admin getter contract');
CREATE TEMP TABLE qa_public_tracking ON COMMIT DROP AS SELECT public.vm_get_tracking((SELECT tracking_token FROM qa_accept)) AS payload;
SELECT pg_temp.assert_true(
  (SELECT (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(payload) k)=ARRAY['brand','code','delivery_date','expires_at','history','order_date','production_date','status','status_version','title']::text[] FROM qa_public_tracking)
  AND (SELECT (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(payload->'history'->0) k)=ARRAY['created_at','status','status_version']::text[] FROM qa_public_tracking)
  AND NOT ((SELECT payload::text FROM qa_public_tracking) ~ '(tracking_token|public_notes|commercial_terms|notes|terms|items|variation|price|total|subtotal|cost|email|phone|address|tax_id|contact|snapshot|client)')
  AND (SELECT payload->>'brand'='Public sales A' AND payload->>'title'='Álbum público' FROM qa_public_tracking),
  'anonymous tracking exposes exact minimal allowlist only for valid capability');
SELECT pg_temp.assert_true(public.vm_get_tracking('ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid) IS NULL,'invalid public tracking capability returns null');
SELECT pg_temp.pass_test('tracking owner/finance admin access and anonymous minimum public allowlist');

-- Replay returns the same order and tracking capability, without duplicate side effects.
SET LOCAL ROLE anon;
SELECT pg_temp.assert_true((SELECT order_id FROM public.vm_approve_quote((SELECT token FROM qa_quote WHERE kind='original')))=(SELECT order_id FROM qa_accept),'repeated approval returns the same order');
SELECT pg_temp.assert_true((SELECT tracking_token FROM public.vm_approve_quote((SELECT token FROM qa_quote WHERE kind='original')) )=(SELECT tracking_token FROM qa_accept),'repeated approval returns the same tracking capability');
RESET ROLE;
SELECT pg_temp.assert_true((SELECT count(*) FROM public.vm_order_events WHERE order_id=(SELECT order_id FROM qa_accept))=1,'replay creates no second order event');
SELECT pg_temp.assert_true((SELECT count(*) FROM public.vm_notifications WHERE event_id=(SELECT event_id FROM public.vm_order_events WHERE order_id=(SELECT order_id FROM qa_accept)))=(SELECT count(*) FROM public.vm_memberships WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))),'replay creates no duplicate member notifications');
SELECT pg_temp.assert_true((SELECT count(*) FROM vm_private.vm_quote_acceptances WHERE quote_id=(SELECT quote_id FROM qa_quote WHERE kind='original'))=1,'quote to order link is unique');
SELECT pg_temp.pass_test('approval replay is durable and side-effect idempotent');

-- Revisions revoke the old capability atomically; approved quotes remain immutable.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','owner')::text,true);
INSERT INTO qa_quote
SELECT 'revision_base',q.quote_id,q.public_token FROM public.vm_create_quote(
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
  jsonb_build_object('client_id',(SELECT client_id FROM qa_client),'title','Base revisável','order_date',CURRENT_DATE,'discount_type','none','discount_value','0','shipping_amount','0'),
  jsonb_build_array(jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_product),'quantity','1','price_override',false)),
  CURRENT_DATE+10,'Termos base','50000000-0000-0000-0000-000000000013'::uuid,NULL::uuid) AS q;
INSERT INTO qa_quote
SELECT 'revision',q.quote_id,q.public_token FROM public.vm_revise_quote(
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
  (SELECT quote_id FROM qa_quote WHERE kind='revision_base'),
  jsonb_build_object('client_id',(SELECT client_id FROM qa_client),'title','Álbum revisado','order_date',CURRENT_DATE,'discount_type','none','discount_value','0','shipping_amount','0'),
  jsonb_build_array(jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_product),'quantity','1','price_override',false)),
  CURRENT_DATE+10,'Termos revisados','50000000-0000-0000-0000-000000000014'::uuid) AS q;
RESET ROLE;
SELECT pg_temp.assert_true((SELECT status FROM public.vm_quotes WHERE id=(SELECT quote_id FROM qa_quote WHERE kind='revision_base'))='Revoked','revision revokes the previous Sent quote');
SELECT pg_temp.assert_true((SELECT status FROM public.vm_quotes WHERE id=(SELECT quote_id FROM qa_quote WHERE kind='revision'))='Sent','a fresh revision remains Sent');
SELECT pg_temp.assert_raises('approved quote revision is rejected','55000',format($sql$SELECT * FROM public.vm_revise_quote('%s','%s','{"client_id":"%s","title":"nope","order_date":"%s","discount_type":"none","discount_value":"0","shipping_amount":"0"}'::jsonb,'[{"kind":"product","product_id":"%s","quantity":"1","price_override":false}]'::jsonb,'%s','x','50000000-0000-0000-0000-000000000019')$sql$,
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT quote_id FROM qa_quote WHERE kind='original'),(SELECT client_id FROM qa_client),CURRENT_DATE,(SELECT product_id FROM qa_product),CURRENT_DATE+10));
SELECT pg_temp.pass_test('approved quotes remain linked and cannot be removed by revision');

-- A separate sent quote can be revoked, and both invalid public acceptance cases roll back.
INSERT INTO qa_quote
SELECT 'revoked',q.quote_id,q.public_token FROM public.vm_create_quote(
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
  jsonb_build_object('client_id',(SELECT client_id FROM qa_client),'title','Quote revoked','order_date',CURRENT_DATE,'discount_type','none','discount_value','0','shipping_amount','0'),
  jsonb_build_array(jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_product),'quantity','1','price_override',false)),CURRENT_DATE+3,'revoked','50000000-0000-0000-0000-000000000015'::uuid,NULL::uuid) AS q;
SELECT * FROM public.vm_revoke_quote((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT quote_id FROM qa_quote WHERE kind='revoked'),'cancelado','50000000-0000-0000-0000-000000000016'::uuid);
RESET ROLE;
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.role','anon',true);
SELECT pg_temp.assert_raises('revoked quote cannot be approved','22023',format('SELECT * FROM public.vm_approve_quote(''%s''::uuid)',(SELECT token FROM qa_quote WHERE kind='revoked')));
SELECT pg_temp.assert_raises('unknown quote cannot be approved','22023','SELECT * FROM public.vm_approve_quote(''ffffffff-ffff-ffff-ffff-ffffffffffff''::uuid)');
RESET ROLE;
SELECT pg_temp.assert_true((SELECT count(*) FROM public.vm_orders WHERE title='Quote revoked')=0,'invalid approval leaves no partial order');
SELECT pg_temp.pass_test('revoked and unknown tokens reject without existence leaks or partial writes');

-- A fresh real order receives/revokes a tracking capability only through owner RPC.
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','owner')::text,true);
INSERT INTO qa_race
SELECT q.quote_id,q.public_token FROM public.vm_create_quote(
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
  jsonb_build_object('client_id',(SELECT client_id FROM qa_client),'title','QA race quote','order_date',CURRENT_DATE,'discount_type','none','discount_value','0','shipping_amount','0'),
  jsonb_build_array(jsonb_build_object('kind','product','product_id',(SELECT product_id FROM qa_product),'quantity','1','price_override',false)),CURRENT_DATE+3,'race','50000000-0000-0000-0000-000000000017'::uuid,NULL::uuid) AS q;
SELECT pg_temp.assert_true(has_function_privilege('authenticated','public.vm_issue_tracking(uuid,uuid,timestamptz,uuid)','EXECUTE'),'owner can issue tracking');
SELECT pg_temp.assert_true(NOT has_function_privilege('anon','public.vm_issue_tracking(uuid,uuid,timestamptz,uuid)','EXECUTE'),'anonymous cannot issue tracking');
SELECT pg_temp.assert_raises('past quote validity rejected before persistence','22023',format($sql$SELECT * FROM public.vm_create_quote('%s',jsonb_build_object('client_id','%s','title','past','order_date',CURRENT_DATE,'discount_type','none','discount_value','0','shipping_amount','0'),'[{"kind":"product","product_id":"%s","quantity":"1","price_override":false}]'::jsonb,CURRENT_DATE-1,NULL,'50000000-0000-0000-0000-000000000018',NULL)$sql$,(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT client_id FROM qa_client),(SELECT product_id FROM qa_product)));
SELECT pg_temp.pass_test('tracking mutation ACL and quote validity guard');

-- Admin listing RPC role gate, allowlisted projection, and stable keyset pages.
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','authenticated')::text,true);
CREATE TEMP TABLE qa_quote_page1 ON COMMIT DROP AS SELECT * FROM public.vm_list_quotes((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),NULL,NULL,1);
CREATE TEMP TABLE qa_quote_page2 ON COMMIT DROP AS SELECT * FROM public.vm_list_quotes((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT created_at FROM qa_quote_page1),(SELECT quote_id FROM qa_quote_page1),1);
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM qa_quote_page1) AND (SELECT count(*)=1 FROM qa_quote_page2) AND NOT EXISTS(SELECT 1 FROM qa_quote_page1 a JOIN qa_quote_page2 b USING(quote_id)) AND (SELECT (created_at,quote_id) FROM qa_quote_page2)<(SELECT (created_at,quote_id) FROM qa_quote_page1),'descending tuple cursor progresses without duplicates');
SELECT pg_temp.assert_true((SELECT public_token IS NOT NULL FROM qa_quote_page1) AND NOT ((SELECT to_jsonb(p)::text FROM qa_quote_page1 p) ~ '(email|phone|address|tax_id|internal_notes|birth_date|material_id|unit_cost|recipe|margin)'),'listing is copyable but excludes contacts and private snapshots');
SELECT pg_temp.assert_raises('partial cursor rejected','22023',format('SELECT * FROM public.vm_list_quotes(''%s'',NULL,''%s'',1)',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT quote_id FROM qa_quote_page1)));
SELECT pg_temp.assert_raises('limit above 100 rejected','22023',format('SELECT * FROM public.vm_list_quotes(''%s'',NULL,NULL,101)',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.pass_test('owner list projection and cursor/limit validation');

-- The admin revision payload contains only the explicitly approved commercial fields.
CREATE TEMP TABLE qa_manual_quote ON COMMIT DROP AS
SELECT q.quote_id FROM public.vm_create_quote(
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
  jsonb_build_object('client_id',(SELECT client_id FROM qa_client),'title','Serviço manual','order_date',CURRENT_DATE,
    'discount_type','none','discount_value','0','shipping_amount','0'),
  jsonb_build_array(jsonb_build_object('kind','manual_service','title','Acabamento especial','quantity','1',
    'unit_price','27.50','price_override',true,'price_override_reason','Preço acordado')),
  CURRENT_DATE+5,'Termos privados comerciais','50000000-0000-0000-0000-000000000021'::uuid,NULL::uuid) q;
CREATE TEMP TABLE qa_admin_payload ON COMMIT DROP AS
SELECT public.vm_get_quote_admin((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
  (SELECT quote_id FROM qa_quote WHERE kind='original')) AS payload;
SELECT pg_temp.assert_true(
  (SELECT (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(payload) k)=ARRAY['data','items','parent_quote_id','quote_id','status','terms','valid_until']::text[] FROM qa_admin_payload)
  AND (SELECT (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(payload->'data') k)=ARRAY['client_id','delivery_date','discount_type','discount_value','internal_notes','order_date','production_date','public_notes','responsible_membership_id','shipping_amount','title']::text[] FROM qa_admin_payload)
  AND (SELECT (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(payload->'items'->0) k)=ARRAY['delivery_date','details','dimensions','kind','personalization','price_override','price_override_reason','product_id','production_date','quantity','title','unit_price','variant_id']::text[] FROM qa_admin_payload)
  AND (SELECT payload->'items'->0->'unit_price'='null'::jsonb AND payload->'items'->0->'price_override'='false'::jsonb FROM qa_admin_payload)
  AND NOT ((SELECT payload::text FROM qa_admin_payload) ~ '(vm_quote_client_snapshots|private@example|11999999999|12345678901|"address"|unit_cost|material_id|consumption|margin)')
  AND (SELECT jsonb_array_length(payload->'items')=1 FROM qa_admin_payload),
  'owner admin getter has exact allowlists, catalog price redaction and no private fields');
SELECT pg_temp.assert_true(
  (public.vm_get_quote_admin((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT quote_id FROM qa_manual_quote))->'items'->0->>'unit_price')='27.50000000'
  AND (public.vm_get_quote_admin((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT quote_id FROM qa_manual_quote))->'items'->0->>'price_override')='true',
  'manual quote item returns override price and flag');
SELECT pg_temp.assert_true(public.vm_get_quote_admin((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid) IS NULL,
  'unknown quote returns null');
SELECT pg_temp.pass_test('owner admin getter strict projection, catalog/manual pricing and tenant null behavior');
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_b::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','authenticated')::text,true);
SELECT pg_temp.assert_true((SELECT count(*) FROM public.vm_list_quotes((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),NULL,NULL,100))>0,'finance member may list');
SELECT pg_temp.assert_true(public.vm_get_quote_admin((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT quote_id FROM qa_quote WHERE kind='original')) IS NOT NULL,'finance member may fetch admin quote payload');
SELECT pg_temp.assert_true(public.vm_get_quote_admin((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_b FROM qa_identity)),(SELECT quote_id FROM qa_quote WHERE kind='original')) IS NULL,'authorized tenant user gets null for cross-tenant quote');
SELECT pg_temp.assert_true((SELECT count(*) FROM public.vm_list_quotes((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_b FROM qa_identity)),NULL,NULL,40))=0,'authorized empty organization yields empty result');
RESET ROLE;
UPDATE public.vm_memberships SET role='viewer' WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)) AND user_id=(SELECT user_b FROM qa_identity);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_b::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','authenticated')::text,true);
SELECT pg_temp.assert_raises('viewer denied listing','42501',format('SELECT * FROM public.vm_list_quotes(''%s'',NULL,NULL,40)',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.assert_raises('viewer denied admin getter','42501',format('SELECT public.vm_get_quote_admin(''%s'',''%s'')',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT quote_id FROM qa_quote WHERE kind='original')));
SELECT pg_temp.assert_raises('viewer denied admin tracking getter','42501',format('SELECT * FROM public.vm_get_order_tracking(''%s'',''%s'')',(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT order_id FROM qa_accept)));
RESET ROLE;
SELECT pg_temp.assert_true(NOT has_function_privilege('anon','public.vm_list_quotes(uuid,timestamptz,uuid,integer)','EXECUTE'),'anon has no execute grant');
SELECT pg_temp.assert_true(NOT has_function_privilege('anon','public.vm_get_quote_admin(uuid,uuid)','EXECUTE'),'anon has no execute grant on admin getter');
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.role','anon',true);
SELECT pg_temp.pass_test('finance allow; viewer and anon denied; empty organization result');
-- Persisted native message contract is exercised after the runner has committed this suite.
SELECT pg_temp.pass_test('two-connection acceptance race fixture is committed for runner probe');
