-- Appended to public_sales.sql, only in the marked isolated Unix-socket DB.
-- The explicit trigger disable below advances local fixture deadlines without
-- sleeping for days; production tables and application guards are not touched.
RESET ROLE;
CREATE TEMP TABLE qa_quote_clock AS
SELECT vm_private.vm_quote_business_date(pg_catalog.clock_timestamp()) AS today,
       CASE WHEN pg_catalog.timezone('Pacific/Kiritimati',pg_catalog.clock_timestamp())::date
                      <> vm_private.vm_quote_business_date(pg_catalog.clock_timestamp())
            THEN 'Pacific/Kiritimati' ELSE 'Etc/GMT+12' END AS other_timezone;
GRANT SELECT ON qa_quote_clock TO authenticated,anon;
SELECT pg_temp.assert_true(
  vm_private.vm_quote_business_date('2026-10-31 02:59:59.999999+00'::timestamptz)='2026-10-30'::date
  AND vm_private.vm_quote_business_date('2026-10-31 03:00:00+00'::timestamptz)='2026-10-31'::date
  AND vm_private.vm_quote_business_date('2018-02-18 02:30:00+00'::timestamptz)='2018-02-17'::date
  AND vm_private.vm_quote_business_date('2018-02-18 03:00:00+00'::timestamptz)='2018-02-18'::date,
  'São Paulo midnight, microsecond and historical DST boundaries');
SELECT pg_temp.assert_true(
  NOT has_function_privilege('anon','vm_private.vm_quote_business_date(timestamptz)','EXECUTE')
  AND NOT has_function_privilege('authenticated','vm_private.vm_quote_business_date(timestamptz)','EXECUTE')
  AND has_function_privilege('anon','public.vm_get_quote(uuid)','EXECUTE')
  AND has_function_privilege('anon','public.vm_approve_quote(uuid)','EXECUTE')
  AND NOT has_function_privilege('anon','public.vm_list_quotes(uuid,timestamptz,uuid,integer)','EXECUTE'),
  'business-date helper private; existing public and admin ACLs preserved');
SELECT pg_temp.pass_test('São Paulo civil-day boundaries, historical DST and function ACLs');

-- One session is deliberately on a different civil date from São Paulo.
SELECT pg_catalog.set_config('TimeZone',(SELECT other_timezone FROM qa_quote_clock),true);
SELECT pg_temp.assert_true(CURRENT_DATE<>(SELECT today FROM qa_quote_clock),'fixture timezone differs from business date');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','authenticated')::text,true);
INSERT INTO qa_quote(kind,quote_id,token)
SELECT f.kind,q.quote_id,q.public_token
FROM (VALUES ('today',0),('expired_sent',2),('expired_approved',2),('tracking_expired',2),('tracking_revoked',2),
             ('race_revoke',2),('race_read',2),('race_track',2),('race_track_reverse',2),('race_expiry',2)) AS f(kind,days)
CROSS JOIN LATERAL public.vm_create_quote(
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
  jsonb_build_object('client_id',(SELECT client_id FROM qa_client),'title','QA capability '||f.kind,'order_date',(SELECT today FROM qa_quote_clock),
                     'discount_type','none','discount_value','0','shipping_amount','0'),
  '[{"kind":"manual_service","title":"Serviço de teste local","quantity":"1","unit_price":"10.00","price_override":true,"price_override_reason":"Contrato local"}]'::jsonb,
  (SELECT today FROM qa_quote_clock)+f.days,NULL,pg_catalog.gen_random_uuid(),NULL) AS q;
SELECT pg_temp.assert_raises('before business date is rejected regardless of session timezone','22023',
  format($sql$SELECT * FROM public.vm_create_quote('%s',jsonb_build_object('client_id','%s','title','Antes do prazo','order_date','%s','discount_type','none','discount_value','0','shipping_amount','0'),
  '[{"kind":"manual_service","title":"serviço","quantity":"1","unit_price":"10","price_override":true,"price_override_reason":"local"}]'::jsonb,'%s',NULL,gen_random_uuid(),NULL)$sql$,
    (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT client_id FROM qa_client),
    (SELECT today FROM qa_quote_clock),(SELECT today-1 FROM qa_quote_clock)));
SELECT pg_temp.assert_true((SELECT status='Sent' FROM public.vm_list_quotes((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),NULL,NULL,100) WHERE quote_id=(SELECT quote_id FROM qa_quote WHERE kind='today')),'valid through today in the admin list despite foreign session timezone');
RESET ROLE;
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.role','anon',true);
SELECT pg_temp.assert_true((public.vm_get_quote((SELECT token FROM qa_quote WHERE kind='today'))->>'status')='Sent','valid through current business day');
CREATE TEMP TABLE qa_cap_results(kind text PRIMARY KEY,order_id uuid,tracking_token uuid) ON COMMIT DROP;
GRANT SELECT,INSERT ON qa_cap_results TO anon,authenticated;
INSERT INTO qa_cap_results
SELECT q.kind,a.order_id,a.tracking_token FROM qa_quote q
CROSS JOIN LATERAL public.vm_approve_quote(q.token) a
WHERE q.kind IN ('today','expired_approved','tracking_expired','tracking_revoked','race_track','race_track_reverse','race_expiry');
SELECT pg_temp.assert_true((SELECT count(*)=7 FROM qa_cap_results),'all intended local quote approvals succeeded');
SELECT pg_temp.assert_true((public.vm_get_quote((SELECT token FROM qa_quote WHERE kind='today'))->>'tracking_available')::boolean,
  'approved quote says whether its original tracking link is available');
SELECT pg_temp.pass_test('creation, list, reading and approval ignore the session timezone');

-- Advance only local fixture deadlines while retaining all historical rows.
RESET ROLE;
ALTER TABLE public.vm_quotes DISABLE TRIGGER vm_quotes_guard;
UPDATE public.vm_quotes SET valid_until=(SELECT today-1 FROM qa_quote_clock)
WHERE id IN (SELECT quote_id FROM qa_quote WHERE kind IN ('expired_sent','expired_approved'));
ALTER TABLE public.vm_quotes ENABLE TRIGGER vm_quotes_guard;
ALTER TABLE public.vm_tracking_capabilities DISABLE TRIGGER vm_tracking_guard;
UPDATE public.vm_tracking_capabilities SET created_at=pg_catalog.clock_timestamp()-interval '2 days', expires_at=pg_catalog.clock_timestamp()-interval '1 day'
WHERE token=(SELECT tracking_token FROM qa_cap_results WHERE kind='tracking_expired');
ALTER TABLE public.vm_tracking_capabilities ENABLE TRIGGER vm_tracking_guard;
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.role','anon',true);
SELECT pg_temp.assert_true(public.vm_get_quote((SELECT token FROM qa_quote WHERE kind='revoked')) IS NULL
  AND public.vm_get_quote((SELECT token FROM qa_quote WHERE kind='revision_base')) IS NULL
  AND public.vm_get_quote((SELECT token FROM qa_quote WHERE kind='expired_sent')) IS NULL
  AND public.vm_get_quote((SELECT token FROM qa_quote WHERE kind='expired_approved')) IS NULL
  AND public.vm_get_quote('ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid) IS NULL,
  'revoked expired and unknown quote links return NULL without snapshot data');
SELECT pg_temp.assert_raises('expired sent approval denied','22023',format('SELECT * FROM public.vm_approve_quote(''%s'')',(SELECT token FROM qa_quote WHERE kind='expired_sent')));
SELECT pg_temp.assert_raises('expired approved replay denied','22023',format('SELECT * FROM public.vm_approve_quote(''%s'')',(SELECT token FROM qa_quote WHERE kind='expired_approved')));
SELECT pg_temp.assert_true(public.vm_get_tracking((SELECT tracking_token FROM qa_cap_results WHERE kind='expired_approved')) IS NOT NULL,
  'independent tracking remains valid when only the quote expires');
SELECT pg_temp.assert_true(public.vm_get_tracking((SELECT tracking_token FROM qa_cap_results WHERE kind='tracking_expired')) IS NULL
  AND NOT (public.vm_get_quote((SELECT token FROM qa_quote WHERE kind='tracking_expired'))->>'tracking_available')::boolean,
  'expired original tracking is not exposed as available');
SELECT pg_temp.assert_raises('expired original tracking cannot be replayed','22023',format('SELECT * FROM public.vm_approve_quote(''%s'')',(SELECT token FROM qa_quote WHERE kind='tracking_expired')));
RESET ROLE;
SELECT pg_temp.assert_true((SELECT count(*)=0 FROM public.vm_orders WHERE title='QA capability expired_sent')
  AND (SELECT count(*)=1 FROM vm_private.vm_quote_acceptances WHERE quote_id=(SELECT quote_id FROM qa_quote WHERE kind='expired_approved'))
  AND (SELECT count(*)=1 FROM public.vm_tracking_capabilities WHERE order_id=(SELECT order_id FROM qa_cap_results WHERE kind='tracking_expired')),
  'expired attempts have no new order acceptance or replacement capability');
SELECT pg_temp.pass_test('expired and revoked reads and acceptance fail closed; independent tracking lifetime');

-- Actual admin revocation and reissue cannot make the original replay return
-- either the revoked token or the administrator's replacement.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','authenticated')::text,true);
SELECT * FROM public.vm_revoke_tracking((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
  (SELECT tracking_token FROM qa_cap_results WHERE kind='tracking_revoked'),pg_catalog.gen_random_uuid());
CREATE TEMP TABLE qa_replacement ON COMMIT DROP AS
SELECT * FROM public.vm_issue_tracking((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
  (SELECT order_id FROM qa_cap_results WHERE kind='tracking_revoked'),pg_catalog.clock_timestamp()+interval '7 days',pg_catalog.gen_random_uuid());
GRANT SELECT ON qa_replacement TO anon;
RESET ROLE;
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.role','anon',true);
SELECT pg_temp.assert_true(public.vm_get_tracking((SELECT tracking_token FROM qa_cap_results WHERE kind='tracking_revoked')) IS NULL
  AND public.vm_get_tracking((SELECT tracking_token FROM qa_replacement)) IS NOT NULL
  AND NOT (public.vm_get_quote((SELECT token FROM qa_quote WHERE kind='tracking_revoked'))->>'tracking_available')::boolean,
  'original revoked; manually issued replacement works only through its own token');
SELECT pg_temp.assert_raises('revoked original capability cannot be replayed or reactivated','22023',format('SELECT * FROM public.vm_approve_quote(''%s'')',(SELECT token FROM qa_quote WHERE kind='tracking_revoked')));
RESET ROLE;
SELECT pg_temp.assert_true((SELECT count(*)=2 AND count(*) FILTER (WHERE revoked_at IS NULL)=1 FROM public.vm_tracking_capabilities WHERE order_id=(SELECT order_id FROM qa_cap_results WHERE kind='tracking_revoked')),
  'replay issued no third tracking link');
SELECT pg_temp.pass_test('tracking revocation and manual replacement do not disclose or reactivate old tokens');

-- Expiration is a derived admin label; historic Sent remains revisable.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','authenticated')::text,true);
SELECT pg_temp.assert_true((SELECT status='Expired' FROM public.vm_list_quotes((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),NULL,NULL,100) WHERE quote_id=(SELECT quote_id FROM qa_quote WHERE kind='expired_sent'))
  AND (public.vm_get_quote_admin((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT quote_id FROM qa_quote WHERE kind='expired_sent'))->>'status')='Sent',
  'expired Sent is labeled Expired but historical admin state is Sent');
INSERT INTO qa_quote
SELECT 'revised_expired',q.quote_id,q.public_token FROM public.vm_revise_quote(
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT quote_id FROM qa_quote WHERE kind='expired_sent'),
  jsonb_build_object('client_id',(SELECT client_id FROM qa_client),'title','Revisão do vencido','order_date',(SELECT today FROM qa_quote_clock),
    'discount_type','none','discount_value','0','shipping_amount','0'),
  '[{"kind":"manual_service","title":"Serviço de teste local","quantity":"1","unit_price":"10.00","price_override":true,"price_override_reason":"Contrato local"}]'::jsonb,
  (SELECT today+1 FROM qa_quote_clock),NULL,pg_catalog.gen_random_uuid()) q;
RESET ROLE;
SELECT pg_temp.assert_true((SELECT status='Revoked' FROM public.vm_quotes WHERE id=(SELECT quote_id FROM qa_quote WHERE kind='expired_sent')),
  'revision revokes the former expired parent');
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.role','anon',true);
SELECT pg_temp.assert_true(public.vm_get_quote((SELECT token FROM qa_quote WHERE kind='revised_expired')) IS NOT NULL,
  'revision creates a new available capability');
SELECT pg_temp.pass_test('expired Sent is still revisable by admin with a new validity date');
