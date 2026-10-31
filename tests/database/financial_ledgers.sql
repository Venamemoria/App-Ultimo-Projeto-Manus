-- Appended to finance_summary.sql and run only in the isolated local cluster.
-- The source rows are real payments/purchases created by those RPC fixtures.
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_b::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','authenticated')::text,true);
CREATE TEMP TABLE qa_other_material ON COMMIT DROP AS
SELECT material_id FROM public.vm_create_material(
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_b FROM qa_identity)),
  'Other tenant material','g',9,3,1,0,'local',NULL,gen_random_uuid());
SELECT * FROM public.vm_create_material_purchase(
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_b FROM qa_identity)),
  (SELECT material_id FROM qa_other_material),1,6,CURRENT_DATE,'paid',CURRENT_DATE,gen_random_uuid(),NULL,'other local tenant');
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','authenticated')::text,true);
SELECT pg_temp.assert_true((SELECT count(*)=3 FROM public.vm_cash_entries WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)))
  AND (SELECT count(*)=1 FROM public.vm_order_payments WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)))
  AND (SELECT count(*)=2 FROM public.vm_material_purchases WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)))
  AND (SELECT subtotal::numeric=50 AND total_amount::numeric=50 AND paid_amount::numeric=25 AND balance_amount::numeric=25 FROM public.vm_orders_read WHERE id=(SELECT order_id FROM qa_order)),
  'owner reads real ledger rows and exact order totals');
SELECT pg_temp.assert_true((SELECT count(*)=0 FROM public.vm_cash_entries WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_b FROM qa_identity)))
  AND (SELECT count(*)=0 FROM public.vm_material_purchases_read WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_b FROM qa_identity))),
  'owner cannot read another tenant even when it has ledger records');
SELECT pg_temp.pass_test('owner retains exact ledger and order values; tenant isolation');

RESET ROLE;
UPDATE public.vm_memberships SET role='admin' WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)) AND user_id=(SELECT user_b FROM qa_identity);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_b::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','authenticated')::text,true);
SELECT pg_temp.assert_true((SELECT count(*)=3 FROM public.vm_cash_entries_read WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)))
  AND (SELECT count(*)=1 FROM public.vm_order_payments_read WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)))
  AND (SELECT count(*)=2 FROM public.vm_material_purchases_read WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)))
  AND (SELECT paid_amount::numeric=25 AND balance_amount::numeric=25 FROM public.vm_orders_read WHERE id=(SELECT order_id FROM qa_order)),
  'admin reads its own organization ledger and real aggregates');
RESET ROLE;
UPDATE public.vm_memberships SET role='finance' WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)) AND user_id=(SELECT user_b FROM qa_identity);
SET LOCAL ROLE authenticated;
SELECT pg_temp.assert_true((SELECT count(*)=3 FROM public.vm_cash_entries WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)))
  AND (SELECT count(*)=1 FROM public.vm_order_payments_read WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)))
  AND (SELECT count(*)=2 FROM public.vm_material_purchases_read WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)))
  AND (SELECT paid_amount::numeric=25 AND balance_amount::numeric=25 FROM public.vm_orders_read WHERE id=(SELECT order_id FROM qa_order)),
  'finance reads its own organization ledger and real aggregates');
SELECT pg_temp.pass_test('admin and finance retain direct tables, views and exact order amounts');

RESET ROLE;
UPDATE public.vm_memberships SET role='production' WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)) AND user_id=(SELECT user_b FROM qa_identity);
SET LOCAL ROLE authenticated;
SELECT pg_temp.assert_true((SELECT count(*)=0 FROM public.vm_cash_entries WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)))
  AND (SELECT count(*)=0 FROM public.vm_cash_entries_read WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)))
  AND (SELECT count(*)=0 FROM public.vm_order_payments WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)))
  AND (SELECT count(*)=0 FROM public.vm_order_payments_read WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)))
  AND (SELECT count(*)=0 FROM public.vm_material_purchases WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)))
  AND (SELECT count(*)=0 FROM public.vm_material_purchases_read WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))),
  'production cannot read any cash purchase or payment rows through base tables or views');
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM public.vm_cash_entries_read)
  AND (SELECT count(*)=1 FROM public.vm_material_purchases_read),
  'same authenticated user sees their owner tenant but not their production tenant in an unfiltered query');
SELECT pg_temp.assert_true((SELECT subtotal IS NULL AND discount_type IS NULL AND discount_value IS NULL AND discount_amount IS NULL AND shipping_amount IS NULL AND total_amount IS NULL AND paid_amount IS NULL AND balance_amount IS NULL AND item_count='1'
  FROM public.vm_orders_read WHERE id=(SELECT order_id FROM qa_order)),
  'production retains operational order row but no order-view amounts or fake zero paid');
SELECT pg_temp.assert_raises('production cannot record a payment','42501',format(
  'SELECT * FROM public.vm_record_order_payment(%L::uuid,%L::uuid,1,CURRENT_DATE,''pix'',gen_random_uuid())',
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT order_id FROM qa_order)));
SELECT pg_temp.assert_true((SELECT status='Em Produção' FROM public.vm_set_order_status(
  (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT order_id FROM qa_order),'Em Produção',NULL,gen_random_uuid())),
  'production can still move an actual order through its operational RPC');
SELECT pg_temp.pass_test('production sees no ledger rows or order-view values, yet can operate status');

RESET ROLE;
UPDATE public.vm_memberships SET role='viewer' WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)) AND user_id=(SELECT user_b FROM qa_identity);
SET LOCAL ROLE authenticated;
SELECT pg_temp.assert_true((SELECT count(*)=0 FROM public.vm_cash_entries_read WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)))
  AND (SELECT count(*)=0 FROM public.vm_order_payments_read WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)))
  AND (SELECT count(*)=0 FROM public.vm_material_purchases_read WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)))
  AND (SELECT total_amount IS NULL AND paid_amount IS NULL AND balance_amount IS NULL FROM public.vm_orders_read WHERE id=(SELECT order_id FROM qa_order)),
  'viewer cannot see ledger values or aggregates');
RESET ROLE;
SELECT pg_temp.assert_true(NOT has_table_privilege('anon','public.vm_cash_entries','SELECT') AND NOT has_table_privilege('anon','public.vm_order_payments','SELECT')
  AND NOT has_table_privilege('anon','public.vm_material_purchases','SELECT'),'anonymous has no direct ledger grants');
SELECT pg_temp.assert_true((SELECT reloptions @> ARRAY['security_invoker=true'] FROM pg_class WHERE oid='public.vm_orders_read'::regclass)
  AND has_table_privilege('authenticated','public.vm_orders_read','SELECT') AND NOT has_table_privilege('anon','public.vm_orders_read','SELECT'),
  'order view retains invoker mode and original API grants');
SELECT pg_temp.pass_test('viewer and anonymous denied financial ledgers; invoker ACL preserved');
