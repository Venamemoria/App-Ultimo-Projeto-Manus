-- This extension runs only against the isolated local PostgreSQL cluster.
SET CONSTRAINTS ALL DEFERRED;
-- Establish actual roles in two organizations; the same user is production in
-- A and owner in B. All operational fixtures use existing public RPCs.
RESET ROLE;
UPDATE public.vm_memberships SET role='production'
WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))
  AND user_id=(SELECT user_b FROM qa_identity);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_b::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','authenticated')::text,true);
INSERT INTO qa_orders
SELECT 'tenant_b', (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_b FROM qa_identity)), o.order_id, '40000000-0000-0000-0000-000000000900'::uuid
FROM public.vm_create_order(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_b FROM qa_identity)),
 jsonb_build_object('client_id',(SELECT client_id FROM qa_clients WHERE kind='cross_tenant'),'title','Tenant B local order','order_date','2026-10-29'),
 '[{"kind":"manual_service","title":"Local service B","quantity":"1","unit_price":"37","price_override":true,"price_override_reason":"local"}]'::jsonb,
 '40000000-0000-0000-0000-000000000900') o;
SELECT pg_temp.assert_true((SELECT count(*)=0 FROM public.vm_orders WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)))
 AND (SELECT count(*)=0 FROM public.vm_order_items WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)))
 AND (SELECT count(*)=0 FROM public.vm_order_item_materials WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))),
 'production cannot access financial base orders items or recipe rows, even with SELECT *');
SELECT pg_temp.assert_true((SELECT count(*)=1 AND max(total_amount)=37 FROM public.vm_orders WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_b FROM qa_identity)))
 AND (SELECT unit_price::numeric=37 FROM public.vm_order_items_read WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='tenant_b')),
 'same user retains exact financial values in their owner tenant');
SELECT pg_temp.assert_true((SELECT subtotal IS NULL AND discount_type IS NULL AND discount_value IS NULL AND discount_amount IS NULL
 AND shipping_amount IS NULL AND total_amount IS NULL AND paid_amount IS NULL AND balance_amount IS NULL AND item_count='2'
 FROM public.vm_orders_read WHERE id=(SELECT order_id FROM qa_orders WHERE kind='core')),
 'production still sees core order and item count, with all values NULL');
SELECT pg_temp.assert_true((SELECT count(*)=2 FROM public.vm_order_items_read WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='core')
 AND unit_price IS NULL AND price_source IS NULL AND price_override_reason IS NULL AND line_amount_raw IS NULL AND line_amount IS NULL
 AND unit_composition_cost IS NULL AND total_composition_cost IS NULL AND price_snapshot IS NULL
 AND product_snapshot->>'name'='Produto Orders Base' AND NOT product_snapshot ? 'snapshot_metadata'
 AND jsonb_array_length(recipe_snapshot)=1 AND NOT (recipe_snapshot->0 ? 'unit_cost_snapshot')
 AND NOT (recipe_snapshot->0 ? 'consumption_cost') AND recipe_snapshot->0->>'material_name'='Material Orders A'),
 'production receives only safe operational fields and recipe quantities; JSON costs and metadata are absent');
SELECT pg_temp.assert_true((SELECT count(*)=0 FROM public.vm_order_items_read WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='core') AND unit_price IS NOT NULL)
 AND (SELECT count(*)=0 FROM public.vm_orders_read WHERE id=(SELECT order_id FROM qa_orders WHERE kind='core') AND total_amount IS NOT NULL),
 'predicate filters cannot observe hidden amounts');
SELECT pg_temp.assert_true((SELECT order_count::integer>0 AND open_order_count::integer>=0 FROM public.vm_clients_read WHERE id=(SELECT client_id FROM qa_clients WHERE kind='active')),
 'client order counts remain available despite base order restriction');
SELECT pg_temp.assert_true((SELECT status='Em Produção' FROM public.vm_set_order_status(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 (SELECT order_id FROM qa_orders WHERE kind='replay'),'Em Produção',NULL,gen_random_uuid())),
 'production retains status and stock workflow');
SELECT pg_temp.pass_test('production uses safe operational order views while financial base rows are denied per tenant');

-- Change the same membership role without changing the session identity.
RESET ROLE;
UPDATE public.vm_memberships SET role='finance' WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)) AND user_id=(SELECT user_b FROM qa_identity);
SET LOCAL ROLE authenticated;
SELECT pg_temp.assert_true((SELECT total_amount=2 FROM public.vm_orders WHERE id=(SELECT order_id FROM qa_orders WHERE kind='core'))
 AND (SELECT count(*)=2 FROM public.vm_order_items WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='core'))
 AND (SELECT count(*)=2 FROM public.vm_order_item_materials WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='core')),
 'finance retains direct raw order and recipe data');
SELECT pg_temp.assert_true((SELECT count(*)=2 FROM public.vm_order_items_read WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='core')
 AND unit_price IS NOT NULL AND line_amount IS NOT NULL AND unit_composition_cost IS NOT NULL AND price_snapshot IS NOT NULL
 AND recipe_snapshot->0 ? 'unit_cost_snapshot' AND recipe_snapshot->0 ? 'consumption_cost'),
 'finance retains complete financial snapshots in order item view');
RESET ROLE;
UPDATE public.vm_memberships SET role='admin' WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)) AND user_id=(SELECT user_b FROM qa_identity);
SET LOCAL ROLE authenticated;
SELECT pg_temp.assert_true((SELECT total_amount::numeric=2 FROM public.vm_orders_read WHERE id=(SELECT order_id FROM qa_orders WHERE kind='core')),
 'admin retains financial values');
SELECT pg_temp.pass_test('finance and admin retain exact direct and view amounts in their organization');

RESET ROLE;
UPDATE public.vm_memberships SET role='viewer' WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)) AND user_id=(SELECT user_b FROM qa_identity);
SET LOCAL ROLE authenticated;
SELECT pg_temp.assert_true((SELECT count(*)=0 FROM public.vm_orders WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)))
 AND (SELECT count(*)=2 FROM public.vm_order_items_read WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='core') AND unit_price IS NULL),
 'viewer gets only sanitized views');
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','authenticated')::text,true);
SELECT pg_temp.assert_true((SELECT count(*)=0 FROM public.vm_orders_read WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_b FROM qa_identity)))
 AND (SELECT count(*)=0 FROM public.vm_order_items_read WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_b FROM qa_identity))),
 'owner A cannot read tenant B even through definer views');
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.role','anon',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','anon')::text,true);
SELECT pg_temp.assert_raises('anon cannot read order view','42501','SELECT * FROM public.vm_orders_read');
SELECT pg_temp.assert_raises('anon cannot read item view','42501','SELECT * FROM public.vm_order_items_read');
RESET ROLE;
SELECT pg_temp.assert_true((SELECT bool_and(reloptions @> ARRAY['security_invoker=false','security_barrier=true']) FROM pg_class WHERE oid IN ('public.vm_orders_read'::regclass,'public.vm_order_items_read'::regclass))
 AND has_table_privilege('authenticated','public.vm_orders_read','SELECT') AND NOT has_table_privilege('anon','public.vm_orders_read','SELECT'),
 'restricted projections are security-barrier definer views with original role grants');
SELECT pg_temp.pass_test('viewer, cross-tenant and anonymous boundaries hold on security-barrier projections');

-- service_role is a separate privileged database role, not a JWT string that
-- an authenticated caller may use to bypass membership. Its legacy API access
-- must continue to work for machine-to-machine clients.
DO $test$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN; END IF;
END $test$;
GRANT SELECT ON public.vm_orders_read,public.vm_order_items_read,pg_temp.qa_orders TO service_role;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','service_role',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','service_role')::text,true);
SELECT pg_temp.assert_true((SELECT count(*)=0 FROM public.vm_orders_read),
 'an authenticated database role cannot activate service access by spoofing a claim');
SET LOCAL ROLE service_role;
SELECT pg_temp.assert_true((SELECT total_amount::numeric=2 FROM public.vm_orders_read WHERE id=(SELECT order_id FROM qa_orders WHERE kind='core'))
 AND (SELECT count(*)=2 FROM public.vm_order_items_read WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='core') AND unit_price IS NOT NULL),
 'the actual privileged service role retains machine-to-machine access');
RESET ROLE;
SELECT pg_temp.pass_test('privileged service-role compatibility cannot be triggered by an authenticated role claim');
