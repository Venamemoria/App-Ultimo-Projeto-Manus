-- Appended to order_returns.sql in the isolated test cluster.
RESET ROLE;
UPDATE public.vm_memberships SET role='production' WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)) AND user_id=(SELECT user_b FROM qa_identity);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_b::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','authenticated')::text,true);
SELECT pg_temp.assert_true((SELECT count(*)=1 AND min(current_stock_quantity)::numeric>0 FROM public.vm_order_returns_read WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='partial'))
 AND (SELECT count(*)=0 FROM public.vm_stock_movements WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))),
 'production retains return quantities and balance without raw cost-bearing movements');
RESET ROLE;
SELECT pg_temp.pass_test('operational return view remains usable with financial inventory RLS');
