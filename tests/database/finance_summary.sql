-- Financial summary contract. Fixtures are created only in the marked local QA database.
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
    RAISE EXCEPTION 'assertion failed: % (unexpected SQLSTATE %)',p_label,v_sqlstate USING ERRCODE='P0001';
  END;
  RAISE EXCEPTION 'assertion failed: % (expected error)',p_label USING ERRCODE='P0001';
END;
$function$;
CREATE OR REPLACE FUNCTION pg_temp.pass_test(p_label text)
RETURNS void LANGUAGE sql SECURITY DEFINER AS $function$
  INSERT INTO pg_temp.qa_test_results(label) VALUES (p_label)
$function$;
GRANT INSERT ON qa_test_results TO authenticated,anon;

CREATE TEMP TABLE qa_identity(user_a uuid NOT NULL,user_b uuid NOT NULL) ON COMMIT DROP;
INSERT INTO qa_identity VALUES (
  '00000000-0000-0000-0000-0000000000a1',
  '00000000-0000-0000-0000-0000000000b2'
);
CREATE TEMP TABLE qa_orgs(user_id uuid NOT NULL,organization_id uuid PRIMARY KEY) ON COMMIT DROP;
CREATE TEMP TABLE qa_client(client_id uuid NOT NULL) ON COMMIT DROP;
CREATE TEMP TABLE qa_material(material_id uuid NOT NULL) ON COMMIT DROP;
CREATE TEMP TABLE qa_order(order_id uuid NOT NULL) ON COMMIT DROP;
CREATE TEMP TABLE qa_summary(value jsonb NOT NULL) ON COMMIT PRESERVE ROWS;
GRANT SELECT ON qa_identity,qa_orgs,qa_client,qa_material,qa_order TO authenticated,anon;
GRANT INSERT ON qa_orgs,qa_client,qa_material,qa_order,qa_summary TO authenticated,anon;
GRANT SELECT ON qa_summary TO authenticated,anon;
GRANT DELETE ON qa_summary TO authenticated;

-- Real local tenants and owner/finance membership through the auth contract.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','authenticated')::text,true);
INSERT INTO qa_orgs
SELECT i.user_a,o.organization_id
FROM qa_identity i CROSS JOIN LATERAL public.vm_create_organization('Finance QA A') o;
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_b::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','authenticated')::text,true);
INSERT INTO qa_orgs
SELECT i.user_b,o.organization_id
FROM qa_identity i CROSS JOIN LATERAL public.vm_create_organization('Finance QA B') o;
RESET ROLE;
INSERT INTO public.vm_memberships(organization_id,user_id,role)
VALUES ((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
        (SELECT user_b FROM qa_identity),'finance');
SELECT pg_temp.pass_test('finance QA creates two isolated organizations and finance membership');

-- Actual source fixtures are written only to the isolated local cluster.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','authenticated')::text,true);
INSERT INTO qa_client
SELECT c.contact_id
FROM public.vm_upsert_contact(
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
  'client','{"name":"Finance QA client","person_type":"individual"}'::jsonb,
  NULL,'50000000-0000-0000-0000-000000000001'::uuid
) c;
INSERT INTO qa_material
SELECT m.material_id
FROM public.vm_create_material(
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
  'Finance QA material','g',10::numeric,10::numeric,10::numeric,0::numeric,
  'finance',NULL::uuid,'50000000-0000-0000-0000-000000000002'::uuid
) m;
INSERT INTO qa_order
SELECT o.order_id
FROM public.vm_create_order(
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
  jsonb_build_object('client_id',(SELECT client_id FROM qa_client),'title','Finance QA order','order_date',CURRENT_DATE),
  jsonb_build_array(jsonb_build_object(
    'kind','manual_service','title','Service','quantity','1','unit_price','50.00',
    'price_override',true,'price_override_reason','QA fixture only'
  )),
  '50000000-0000-0000-0000-000000000003'::uuid
) o;
SELECT * FROM public.vm_record_order_payment(
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
  (SELECT order_id FROM qa_order),25::numeric,CURRENT_DATE,'pix',
  '50000000-0000-0000-0000-000000000004'::uuid
);
SELECT * FROM public.vm_create_material_purchase(
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
  (SELECT material_id FROM qa_material),1::numeric,8::numeric,CURRENT_DATE-1,'paid',CURRENT_DATE-1,
  '50000000-0000-0000-0000-000000000005'::uuid,NULL::uuid,'paid local fixture'
);
SELECT * FROM public.vm_create_material_purchase(
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
  (SELECT material_id FROM qa_material),1::numeric,3::numeric,CURRENT_DATE,'pending',NULL::date,
  '50000000-0000-0000-0000-000000000006'::uuid,NULL::uuid,'pending local fixture'
);
RESET ROLE;
SELECT pg_temp.pass_test('finance sources use actual order-payment and purchase RPCs in local QA only');

-- Owner summary: receipts and expenses are counted once; estimates are separate.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','authenticated')::text,true);
INSERT INTO qa_summary
SELECT public.vm_get_finance_summary(
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
  CURRENT_DATE-1,CURRENT_DATE,'day'
);
SELECT pg_temp.assert_true((SELECT (value->'realized'->>'received')::numeric=25 FROM qa_summary),'canonical receipt is counted once');
SELECT pg_temp.assert_true((SELECT (value->'realized'->>'paid')::numeric=8 FROM qa_summary),'paid purchase mirror is not double-counted');
SELECT pg_temp.assert_true((SELECT (value->'realized'->>'net')::numeric=17 FROM qa_summary),'realized net is exact received less paid');
SELECT pg_temp.assert_true((SELECT (value->'estimate'->>'receivable')::numeric=25 FROM qa_summary),'open order balance appears only as estimated receivable');
SELECT pg_temp.assert_true((SELECT (value->'estimate'->>'payable')::numeric=3 FROM qa_summary),'pending purchase appears only as estimated payable');
SELECT pg_temp.assert_true((SELECT (value->'estimate'->>'projectedNet')::numeric=39 FROM qa_summary),'projected net explicitly combines actual and estimates');
SELECT pg_temp.assert_true((SELECT value->'estimate'->>'isEstimate'='true' FROM qa_summary),'forecast is explicitly marked as estimate');
SELECT pg_temp.assert_true((SELECT value->>'dueDatesAvailable'='false' FROM qa_summary),'no due date is invented');
SELECT pg_temp.assert_true((SELECT jsonb_array_length(value->'series')=2 FROM qa_summary),'expense-only date remains visible in day series');
SELECT pg_temp.assert_true((SELECT (value->'series'->0->>'paid')::numeric=8 AND (value->'series'->0->>'received')::numeric=0 FROM qa_summary),'expense-only day has paid amount and zero received');
SELECT pg_temp.assert_true((SELECT value->'realized'->'paymentMethods' @> '[{"method":"pix","amount":"25.00"}]'::jsonb FROM qa_summary),'payment-method breakdown uses the real payment method');
SELECT pg_temp.assert_true((SELECT NOT (value::text ~* '(client|email|phone|address|tax_id|order_id|material_id)') FROM qa_summary),'aggregate response excludes PII and operational IDs');
SELECT pg_temp.pass_test('owner receives exact cash totals estimates method breakdown and minimal aggregate');

-- Month grouping aggregates the same data; period boundaries remain explicit.
DELETE FROM qa_summary;
INSERT INTO qa_summary
SELECT public.vm_get_finance_summary(
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
  CURRENT_DATE-1,CURRENT_DATE,'month'
);
SELECT pg_temp.assert_true((SELECT jsonb_array_length(value->'series')=1 FROM qa_summary),'month grouping returns one monthly bucket');
SELECT pg_temp.assert_true((SELECT (value->'series'->0->>'received')::numeric=25 AND (value->'series'->0->>'paid')::numeric=8 FROM qa_summary),'monthly bucket preserves exact received and paid totals');
SELECT pg_temp.pass_test('daily and monthly grouping preserve actual totals');

-- Finance role is allowed; viewer, production, cross-tenant and anon are not.
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_b::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','authenticated')::text,true);
SELECT pg_temp.assert_true((public.vm_get_finance_summary(
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
  CURRENT_DATE-1,CURRENT_DATE,'day')->'realized'->>'received')::numeric=25,'finance role can consult its organization');
RESET ROLE;
UPDATE public.vm_memberships SET role='viewer'
WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))
  AND user_id=(SELECT user_b FROM qa_identity);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_b::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','authenticated')::text,true);
SELECT pg_temp.assert_raises('viewer cannot read finance summary','42501',format(
  'SELECT public.vm_get_finance_summary(%L::uuid,CURRENT_DATE-1,CURRENT_DATE,''day'')',
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
RESET ROLE;
UPDATE public.vm_memberships SET role='production'
WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))
  AND user_id=(SELECT user_b FROM qa_identity);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_b::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','authenticated')::text,true);
SELECT pg_temp.assert_raises('production cannot read finance summary','42501',format(
  'SELECT public.vm_get_finance_summary(%L::uuid,CURRENT_DATE-1,CURRENT_DATE,''day'')',
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','authenticated')::text,true);
SELECT pg_temp.assert_raises('cross-tenant summary is denied','42501',format(
  'SELECT public.vm_get_finance_summary(%L::uuid,CURRENT_DATE-1,CURRENT_DATE,''day'')',
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_b FROM qa_identity))));
RESET ROLE;
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','anon',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','anon')::text,true);
SELECT pg_temp.assert_raises('anon cannot read finance summary','42501',format(
  'SELECT public.vm_get_finance_summary(%L::uuid,CURRENT_DATE-1,CURRENT_DATE,''day'')',
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
RESET ROLE;
SELECT pg_temp.pass_test('server-side ACL denies viewer production cross-tenant and anonymous access');

-- Invalid grouping and date windows fail closed.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','authenticated')::text,true);
SELECT pg_temp.assert_raises('null grouping is rejected','22023',format(
  'SELECT public.vm_get_finance_summary(%L::uuid,CURRENT_DATE,CURRENT_DATE,NULL)',
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.assert_raises('unsupported grouping is rejected','22023',format(
  'SELECT public.vm_get_finance_summary(%L::uuid,CURRENT_DATE,CURRENT_DATE,''year'')',
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.assert_raises('infinite date is rejected','22023',format(
  'SELECT public.vm_get_finance_summary(%L::uuid,''infinity''::date,CURRENT_DATE,''day'')',
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.assert_raises('window beyond maximum is rejected','22023',format(
  'SELECT public.vm_get_finance_summary(%L::uuid,CURRENT_DATE-367,CURRENT_DATE,''day'')',
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))));
SELECT pg_temp.assert_true(has_function_privilege('authenticated','public.vm_get_finance_summary(uuid,date,date,text)','EXECUTE'),'authenticated role has RPC execute');
SELECT pg_temp.assert_true(NOT has_function_privilege('anon','public.vm_get_finance_summary(uuid,date,date,text)','EXECUTE'),'anon has no RPC execute grant');
SELECT pg_temp.assert_true((SELECT p.prosecdef AND 'search_path=""'=ANY(p.proconfig) FROM pg_proc p WHERE p.oid='public.vm_get_finance_summary(uuid,date,date,text)'::regprocedure),'RPC is security definer with empty search_path');
SELECT pg_temp.pass_test('invalid query parameters fail closed and function ACL is hardened');
RESET ROLE;
