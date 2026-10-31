SET CONSTRAINTS ALL DEFERRED;
-- Fixtures below are created only in the isolated local cluster.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','authenticated')::text,true);
CREATE TEMP TABLE qa_inventory_supplier ON COMMIT DROP AS SELECT contact_id FROM public.vm_upsert_contact(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 'supplier','{"name":"Local supplier","person_type":"individual"}'::jsonb,NULL,gen_random_uuid());
GRANT SELECT ON qa_inventory_supplier TO authenticated,anon,service_role;
SELECT * FROM public.vm_update_material((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 (SELECT material_id FROM qa_materials WHERE kind='main'),'Material Orders A',0,'orders',(SELECT contact_id FROM qa_inventory_supplier));
CREATE TEMP TABLE qa_inventory_baseline ON COMMIT DROP AS SELECT stock_quantity FROM public.vm_materials WHERE id=(SELECT material_id FROM qa_materials WHERE kind='main');
GRANT SELECT ON qa_inventory_baseline TO authenticated,anon,service_role;
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_b::text FROM qa_identity),true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','authenticated')::text,true);
CREATE TEMP TABLE qa_inventory_other ON COMMIT DROP AS SELECT material_id FROM public.vm_create_material(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_b FROM qa_identity)),
 'Tenant B material','g',9,3,4,0,NULL,NULL,gen_random_uuid());
GRANT SELECT ON qa_inventory_other TO authenticated,anon,service_role;
RESET ROLE;
UPDATE public.vm_memberships SET role='production' WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)) AND user_id=(SELECT user_b FROM qa_identity);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_b::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','authenticated')::text,true);
SELECT pg_temp.assert_true((SELECT count(*)=0 FROM public.vm_materials WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)))
 AND (SELECT count(*)=0 FROM public.vm_stock_movements WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity))),
 'production cannot read raw cost-bearing inventory tables');
SELECT pg_temp.assert_true((SELECT count(*)=2 FROM public.vm_materials_read WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)) AND package_cost IS NULL AND unit_cost IS NULL AND stock_quantity IS NOT NULL)
 AND (SELECT count(*)>0 FROM public.vm_stock_movements_read WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)) AND package_cost IS NULL),
 'production receives balances and movements with costs masked');
SELECT pg_temp.assert_true((SELECT material_count='1' AND current_stock_cost IS NULL AND stocks_by_unit::jsonb ? 'g' FROM public.vm_suppliers_read WHERE id=(SELECT contact_id FROM qa_inventory_supplier))
 AND (SELECT current_material_cost IS NULL FROM public.vm_products_read WHERE id=(SELECT product_id FROM qa_products WHERE kind='base'))
 AND (SELECT count(*)=1 FROM public.vm_order_consumptions_read WHERE order_id=(SELECT order_id FROM qa_orders WHERE kind='core')),
 'supplier counts, product availability, and consumption quantities remain operational without fabricated cost');
SELECT pg_temp.assert_raises('production cannot receive with cost','42501',format($sql$
 SELECT * FROM public.vm_receive_material(%L::uuid,%L::uuid,1,123,50,'local',%L::uuid)$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT material_id FROM qa_materials WHERE kind='main'),'40000000-0000-0000-0000-000000000950'));
SELECT pg_temp.assert_true((SELECT stock_quantity::numeric=(SELECT stock_quantity FROM qa_inventory_baseline) FROM public.vm_materials_read WHERE id=(SELECT material_id FROM qa_materials WHERE kind='main')),
 'denied production receipt does not alter the balance');
SELECT pg_temp.assert_true((SELECT unit_cost::numeric=3 FROM public.vm_materials_read WHERE id=(SELECT material_id FROM qa_inventory_other))
 AND (SELECT count(*)=1 FROM public.vm_materials WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_b FROM qa_identity))),
 'same user retains full owner inventory access in other tenant');
SELECT pg_temp.pass_test('production reads operational stock but cannot read costs or register receipts');

RESET ROLE;
UPDATE public.vm_memberships SET role='finance' WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)) AND user_id=(SELECT user_b FROM qa_identity);
SET LOCAL ROLE authenticated;
SELECT pg_temp.assert_true((SELECT unit_cost::numeric=2 FROM public.vm_materials_read WHERE id=(SELECT material_id FROM qa_materials WHERE kind='main'))
 AND (SELECT current_stock_cost::numeric=(SELECT stock_quantity*2 FROM qa_inventory_baseline) FROM public.vm_suppliers_read WHERE id=(SELECT contact_id FROM qa_inventory_supplier)),
 'finance sees exact precise cost and supplier valuation');
SELECT pg_temp.assert_true((SELECT stock_quantity=(SELECT stock_quantity FROM qa_inventory_baseline)+1 AND package_cost=123 AND package_quantity=50
 FROM public.vm_receive_material((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 (SELECT material_id FROM qa_materials WHERE kind='main'),1,123,50,'local financial receipt','40000000-0000-0000-0000-000000000950')),
 'finance can register real priced receipt');
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM public.vm_stock_movements WHERE idempotency_key='40000000-0000-0000-0000-000000000950')
 AND (SELECT unit_cost_precise=2.46 FROM public.vm_materials WHERE id=(SELECT material_id FROM qa_materials WHERE kind='main')),
 'finance sees exact real receipt and precise updated cost');
SELECT * FROM public.vm_receive_material((SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),
 (SELECT material_id FROM qa_materials WHERE kind='main'),1,123,50,'local financial receipt','40000000-0000-0000-0000-000000000950');
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM public.vm_stock_movements WHERE idempotency_key='40000000-0000-0000-0000-000000000950'),
 'financial receipt replay is exactly once');
RESET ROLE;
UPDATE public.vm_memberships SET role='production' WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)) AND user_id=(SELECT user_b FROM qa_identity);
SET LOCAL ROLE authenticated;
SELECT pg_temp.assert_raises('downgraded production cannot replay prior financial receipt','42501',format($sql$
 SELECT * FROM public.vm_receive_material(%L::uuid,%L::uuid,1,123,50,'local financial receipt','40000000-0000-0000-0000-000000000950')$sql$,
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT material_id FROM qa_materials WHERE kind='main')));
SELECT pg_temp.pass_test('finance can receive exactly once, and a role downgrade blocks replay');

RESET ROLE;
UPDATE public.vm_memberships SET role='viewer' WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)) AND user_id=(SELECT user_b FROM qa_identity);
SET LOCAL ROLE authenticated;
SELECT pg_temp.assert_true((SELECT count(*)=2 FROM public.vm_materials_read WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)) AND unit_cost IS NULL)
 AND (SELECT current_stock_cost IS NULL FROM public.vm_suppliers_read WHERE id=(SELECT contact_id FROM qa_inventory_supplier)), 'viewer sees stock without amounts');
SELECT set_config('request.jwt.claim.sub',(SELECT user_a::text FROM qa_identity),true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_a::text FROM qa_identity),'role','authenticated')::text,true);
SELECT pg_temp.assert_true((SELECT count(*)=0 FROM public.vm_materials_read WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_b FROM qa_identity)))
 AND (SELECT count(*)=0 FROM public.vm_stock_movements_read WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_b FROM qa_identity))), 'no cross-tenant stock view rows');
SET LOCAL ROLE anon;
SELECT pg_temp.assert_raises('anon cannot read material view','42501','SELECT * FROM public.vm_materials_read');
SELECT pg_temp.assert_raises('anon cannot read movement view','42501','SELECT * FROM public.vm_stock_movements_read');
RESET ROLE;
SELECT pg_temp.assert_true((SELECT bool_and(reloptions @> ARRAY['security_invoker=false','security_barrier=true']) FROM pg_class WHERE oid IN ('public.vm_materials_read'::regclass,'public.vm_stock_movements_read'::regclass)), 'stock projections are security-barrier views');
SELECT pg_temp.pass_test('viewer, cross-tenant and anonymous stock privacy');
RESET ROLE;
UPDATE public.vm_memberships SET role='admin' WHERE organization_id=(SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)) AND user_id=(SELECT user_b FROM qa_identity);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT user_b::text FROM qa_identity),true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','authenticated')::text,true);
SELECT pg_temp.assert_true((SELECT unit_cost::numeric=2.46 FROM public.vm_materials_read WHERE id=(SELECT material_id FROM qa_materials WHERE kind='main'))
 AND (SELECT stock_quantity=(SELECT stock_quantity FROM qa_inventory_baseline)+2 FROM public.vm_receive_material(
 (SELECT organization_id FROM qa_orgs WHERE user_id=(SELECT user_a FROM qa_identity)),(SELECT material_id FROM qa_materials WHERE kind='main'),
 1,123,50,'admin local receipt','40000000-0000-0000-0000-000000000951')),
 'admin retains real cost and receipt permissions');
SELECT set_config('request.jwt.claim.role','service_role',true);
SELECT set_config('request.jwt.claims',json_build_object('sub',(SELECT user_b::text FROM qa_identity),'role','service_role')::text,true);
SELECT pg_temp.assert_true((SELECT count(*)=0 FROM public.vm_materials_read) AND (SELECT count(*)=0 FROM public.vm_stock_movements_read),
 'service claim alone cannot bypass authenticated role tenancy');
RESET ROLE;
GRANT SELECT ON public.vm_materials_read,public.vm_stock_movements_read,pg_temp.qa_materials TO service_role;
SET LOCAL ROLE service_role;
SELECT pg_temp.assert_true((SELECT unit_cost::numeric=2.46 FROM public.vm_materials_read WHERE id=(SELECT material_id FROM qa_materials WHERE kind='main'))
 AND (SELECT count(*)>0 FROM public.vm_stock_movements_read WHERE package_cost IS NOT NULL),
 'actual service_role retains integration views');
RESET ROLE;
SELECT pg_temp.pass_test('admin and privileged integration access remain; forged service claims are denied');
