-- Foundation contract suite. The runner wraps this file in one transaction.
-- All business rows below are created through the local database/RPCs; the
-- only pre-seeded rows are two local auth.users IDs created by the runner.

CREATE TEMP TABLE qa_test_results (
  ordinal integer GENERATED ALWAYS AS IDENTITY,
  label text NOT NULL
) ON COMMIT PRESERVE ROWS;

CREATE OR REPLACE FUNCTION pg_temp.assert_true(p_condition boolean, p_label text)
RETURNS void LANGUAGE plpgsql AS $function$
BEGIN
  IF NOT COALESCE(p_condition, false) THEN
    RAISE EXCEPTION 'assertion failed: %', p_label USING ERRCODE = 'P0001';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION pg_temp.assert_raises(
  p_label text,
  p_sqlstate text,
  p_statement text
) RETURNS void LANGUAGE plpgsql AS $function$
DECLARE
  v_sqlstate text;
BEGIN
  BEGIN
    EXECUTE p_statement;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    IF p_sqlstate IS NULL OR v_sqlstate = p_sqlstate THEN
      RETURN;
    END IF;
    RAISE EXCEPTION 'assertion failed: % (unexpected SQLSTATE)', p_label USING ERRCODE = 'P0001';
  END;
  RAISE EXCEPTION 'assertion failed: % (expected error)', p_label USING ERRCODE = 'P0001';
END;
$function$;

CREATE OR REPLACE FUNCTION pg_temp.pass_test(p_label text)
RETURNS void LANGUAGE sql AS $function$
  INSERT INTO pg_temp.qa_test_results(label) VALUES (p_label)
$function$;
GRANT INSERT ON qa_test_results TO authenticated, anon;

CREATE TEMP TABLE qa_identity (
  user_a uuid NOT NULL,
  user_b uuid NOT NULL
) ON COMMIT DROP;
INSERT INTO qa_identity VALUES
  ('00000000-0000-0000-0000-0000000000a1'::uuid,
   '00000000-0000-0000-0000-0000000000b2'::uuid);

CREATE TEMP TABLE qa_orgs (
  user_id uuid NOT NULL,
  organization_id uuid PRIMARY KEY,
  membership_id uuid NOT NULL
) ON COMMIT DROP;
CREATE TEMP TABLE qa_material_a (
  material_id uuid NOT NULL,
  opening_movement_id uuid,
  unit_cost numeric,
  stock_quantity numeric
) ON COMMIT DROP;
CREATE TEMP TABLE qa_material_b (
  material_id uuid NOT NULL,
  opening_movement_id uuid,
  unit_cost numeric,
  stock_quantity numeric
) ON COMMIT DROP;
CREATE TEMP TABLE qa_supplier_b (supplier_id uuid NOT NULL) ON COMMIT DROP;
CREATE TEMP TABLE qa_receipt (movement_id uuid NOT NULL, stock_quantity numeric) ON COMMIT DROP;
CREATE TEMP TABLE qa_product_v1 (product_id uuid NOT NULL, version integer, price numeric, component_count integer) ON COMMIT DROP;
CREATE TEMP TABLE qa_product_v2 (product_id uuid NOT NULL, version integer, price numeric, component_count integer) ON COMMIT DROP;

-- These are session-local assertion fixtures owned by the local admin. Grant
-- only the operations needed after SET ROLE; public operational tables keep
-- their migration-defined grants and RLS policies.
GRANT SELECT ON qa_identity, qa_orgs, qa_material_a, qa_material_b,
  qa_supplier_b, qa_receipt, qa_product_v1, qa_product_v2
  TO authenticated, anon;
GRANT INSERT ON qa_orgs, qa_material_a, qa_material_b, qa_supplier_b,
  qa_receipt, qa_product_v1, qa_product_v2 TO authenticated;

-- Real Auth helper contract: the copied implementation reads only the request
-- GUCs, exactly like a Supabase session, not a fake current-user parameter.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', (SELECT user_a::text FROM qa_identity), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config(
  'request.jwt.claims',
  json_build_object('sub', (SELECT user_a::text FROM qa_identity), 'role', 'authenticated')::text,
  true
);
SELECT pg_temp.assert_true(current_user = 'authenticated', 'test session uses authenticated role');
SELECT pg_temp.assert_true(auth.uid() = (SELECT user_a FROM qa_identity), 'auth.uid uses local JWT GUC');
SELECT pg_temp.assert_true(auth.role() = 'authenticated', 'auth.role uses local JWT GUC');
SELECT pg_temp.assert_true(auth.jwt() ->> 'sub' = (SELECT user_a::text FROM qa_identity), 'auth.jwt uses local JWT GUC');
SELECT pg_temp.assert_true(
  vm_private.vm_is_member('00000000-0000-0000-0000-0000000000a1'::uuid) = false,
  'membership helper denies before organization creation'
);
SELECT pg_temp.pass_test('real Auth helper contract');

-- Two tenants are created through the public RPC, not by an admin fixture.
INSERT INTO qa_orgs(user_id, organization_id, membership_id)
SELECT i.user_a, c.organization_id, c.membership_id
FROM qa_identity AS i
CROSS JOIN LATERAL public.vm_create_organization('QA tenant A') AS c;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', (SELECT user_b::text FROM qa_identity), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config(
  'request.jwt.claims',
  json_build_object('sub', (SELECT user_b::text FROM qa_identity), 'role', 'authenticated')::text,
  true
);
INSERT INTO qa_orgs(user_id, organization_id, membership_id)
SELECT i.user_b, c.organization_id, c.membership_id
FROM qa_identity AS i
CROSS JOIN LATERAL public.vm_create_organization('QA tenant B') AS c;

SELECT pg_temp.assert_true((SELECT count(*) FROM qa_orgs) = 2, 'two local tenants created by RPC');
SELECT pg_temp.assert_true((SELECT count(*) FROM vm_organizations) = 1, 'tenant creation is isolated for user B');
SELECT pg_temp.pass_test('two tenants and two local users');

-- Tenant B creates one material and one supplier while authenticated.
INSERT INTO qa_material_b
SELECT *
FROM public.vm_create_material(
  (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_b FROM qa_identity)),
  'QA material B', 'g', 2.00000000::numeric, 1.00000000::numeric,
  4.00000000::numeric, 0.50000000::numeric,
  'QA', NULL::uuid, NULL::uuid
);
WITH inserted AS (
  INSERT INTO public.vm_suppliers(organization_id, name)
  VALUES (
    (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_b FROM qa_identity)),
    'QA supplier B'
  )
  RETURNING id
)
INSERT INTO qa_supplier_b SELECT id FROM inserted;

SELECT pg_temp.assert_true((SELECT count(*) FROM vm_materials) = 1, 'user B sees only tenant B material');
SELECT pg_temp.assert_true((SELECT count(*) FROM vm_suppliers) = 1, 'user B sees only tenant B supplier');
SELECT pg_temp.assert_true(
  (SELECT count(*) FROM vm_materials WHERE organization_id = (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity))) = 0,
  'user B cannot read tenant A material'
);
SELECT pg_temp.pass_test('RLS denies cross-tenant reads for user B');

-- User A creates a fractional material through the RPC. Expected cost is
-- computed by PostgreSQL at column precision, never hard-coded mentally.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', (SELECT user_a::text FROM qa_identity), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config(
  'request.jwt.claims',
  json_build_object('sub', (SELECT user_a::text FROM qa_identity), 'role', 'authenticated')::text,
  true
);
INSERT INTO qa_material_a
SELECT *
FROM public.vm_create_material(
  (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
  'QA material A', 'g', 10.00000001::numeric, 3.00000000::numeric,
  10.25000000::numeric, 1.00000000::numeric,
  'QA', NULL::uuid, NULL::uuid
);
SELECT pg_temp.assert_true(
  (SELECT unit_cost FROM qa_material_a) =
  ((10.00000001::numeric / 3.00000000::numeric)::numeric(20,8)),
  'unit cost is quantized by the database at eight fractional digits'
);
SELECT pg_temp.assert_true(
  (SELECT stock_quantity FROM qa_material_a) = 10.25000000::numeric,
  'fractional opening stock is preserved'
);
SELECT pg_temp.assert_raises(
  'scale beyond eight decimals is rejected before insert', '22003',
  $$SELECT * FROM public.vm_create_material(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      'invalid scale', 'g', 1.123456789::numeric, 1::numeric, 0::numeric, 0::numeric,
      NULL::text, NULL::uuid, NULL::uuid)$$
);
SELECT pg_temp.pass_test('RPC creation, unit cost, and fractional precision');

-- Cross-tenant authorization and composite-FK protection.
SELECT pg_temp.assert_raises(
  'RPC cannot create material in another tenant', '42501',
  $$SELECT * FROM public.vm_create_material(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_b FROM qa_identity)),
      'cross tenant', 'g', 1::numeric, 1::numeric, 0::numeric, 0::numeric,
      NULL::text, NULL::uuid, NULL::uuid)$$
);
SELECT pg_temp.assert_raises(
  'supplier from another tenant is rejected by RPC/FK contract', '23503',
  $$SELECT * FROM public.vm_create_material(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      'wrong supplier', 'g', 1::numeric, 1::numeric, 0::numeric, 0::numeric,
      NULL::text, (SELECT supplier_id FROM qa_supplier_b), NULL::uuid)$$
);
SELECT pg_temp.assert_raises(
  'material from another tenant is rejected by receiving RPC', '23503',
  $$SELECT * FROM public.vm_receive_material(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_b), 1::numeric, 1::numeric, 1::numeric,
      NULL::text, '00000000-0000-0000-0000-0000000000c1'::uuid)$$
);
SELECT pg_temp.pass_test('cross-tenant RPC and composite-FK barriers');

-- User A sees only its tenant, while all relevant rows remain present in the
-- database for the other authenticated identity.
SELECT pg_temp.assert_true((SELECT count(*) FROM vm_organizations) = 1, 'user A sees one organization');
SELECT pg_temp.assert_true((SELECT count(*) FROM vm_memberships) = 1, 'user A sees one membership');
SELECT pg_temp.assert_true((SELECT count(*) FROM vm_materials) = 1, 'user A sees one material');
SELECT pg_temp.assert_true((SELECT count(*) FROM vm_suppliers) = 0, 'user A sees no supplier from tenant B');
SELECT pg_temp.assert_true(
  (SELECT count(*) FROM vm_materials WHERE organization_id = (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_b FROM qa_identity))) = 0,
  'RLS returns zero rows for the other organization'
);
SELECT pg_temp.pass_test('RLS zero-leakage view for user A');

-- Receiving is idempotent for the same payload, and a reused key with a
-- different payload is rejected without changing stock/history.
INSERT INTO qa_receipt
SELECT movement_id, stock_quantity
FROM public.vm_receive_material(
  (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
  (SELECT material_id FROM qa_material_a), 2.12500000::numeric,
  7.50000000::numeric, 2.00000000::numeric, 'first receipt',
  '00000000-0000-0000-0000-0000000000d1'::uuid
);
SELECT pg_temp.assert_true(
  (SELECT stock_quantity FROM qa_receipt) = (10.25000000::numeric + 2.12500000::numeric),
  'receipt adds fractional quantity once'
);
SELECT pg_temp.assert_true(
  (SELECT unit_cost FROM vm_materials WHERE id = (SELECT material_id FROM qa_material_a)) =
  ((7.50000000::numeric / 2.00000000::numeric)::numeric(20,8)),
  'receipt stores recalculated unit cost with database precision'
);
SELECT pg_temp.assert_true(
  (SELECT count(*) FROM vm_stock_movements WHERE idempotency_key = '00000000-0000-0000-0000-0000000000d1'::uuid) = 1,
  'first receipt has one historical row'
);
CREATE TEMP TABLE qa_receipt_replay ON COMMIT DROP AS
SELECT *
FROM public.vm_receive_material(
  (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
  (SELECT material_id FROM qa_material_a), 2.12500000::numeric,
  7.50000000::numeric, 2.00000000::numeric, 'first receipt',
  '00000000-0000-0000-0000-0000000000d1'::uuid
);
SELECT pg_temp.assert_true(
  (SELECT movement_id FROM qa_receipt_replay) = (SELECT movement_id FROM qa_receipt),
  'replayed receipt returns original movement'
);
SELECT pg_temp.assert_true(
  (SELECT stock_quantity FROM qa_receipt_replay) = (10.25000000::numeric + 2.12500000::numeric),
  'replayed receipt does not add stock again'
);
SELECT pg_temp.assert_raises(
  'receipt key with different payload is rejected', '23505',
  $$SELECT * FROM public.vm_receive_material(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_a), 2.12500000::numeric,
      8.50000000::numeric, 2.00000000::numeric, 'different payload',
      '00000000-0000-0000-0000-0000000000d1'::uuid)$$
);
SELECT pg_temp.pass_test('idempotent receiving and payload collision rejection');

-- The foundation adjustment is intentionally tested only for atomic negative
-- rollback. Idempotency of this legacy signature belongs to inventory.sql.
SELECT pg_temp.assert_raises(
  'negative adjustment that would underflow rolls back', '23514',
  $$SELECT * FROM public.vm_adjust_material_stock(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_a), -999.00000000::numeric, 'underflow')$$
);
SELECT pg_temp.assert_true(
  (SELECT stock_quantity FROM vm_materials WHERE id = (SELECT material_id FROM qa_material_a)) =
  (10.25000000::numeric + 2.12500000::numeric),
  'failed negative adjustment leaves stock unchanged'
);
SELECT pg_temp.assert_true(
  (SELECT count(*) FROM vm_stock_movements WHERE material_id = (SELECT material_id FROM qa_material_a)) = 2,
  'failed negative adjustment creates no history row'
);
SELECT pg_temp.pass_test('negative adjustment rollback');

-- Anonymous sessions cannot read operational tables or execute RPCs.
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub', (SELECT user_a::text FROM qa_identity), true);
SELECT set_config('request.jwt.claim.role', 'anon', true);
SELECT set_config(
  'request.jwt.claims',
  json_build_object('sub', (SELECT user_a::text FROM qa_identity), 'role', 'anon')::text,
  true
);
SELECT pg_temp.assert_true(current_user = 'anon', 'test session uses anon role');
SELECT pg_temp.assert_true(
  NOT has_function_privilege('anon', 'public.vm_create_organization(text)', 'EXECUTE'),
  'anon has no execute privilege for organization RPC'
);
SELECT pg_temp.assert_raises('anon cannot read operational materials', '42501', 'SELECT count(*) FROM public.vm_materials');
SELECT pg_temp.assert_raises('anon cannot execute organization RPC', '42501', 'SELECT * FROM public.vm_create_organization(''anon attempt'')');
SELECT pg_temp.pass_test('anonymous read and RPC denial');

-- Return to a real authenticated identity before direct-DML checks.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', (SELECT user_a::text FROM qa_identity), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config(
  'request.jwt.claims',
  json_build_object('sub', (SELECT user_a::text FROM qa_identity), 'role', 'authenticated')::text,
  true
);
SELECT pg_temp.assert_raises(
  'authenticated cannot update balance directly', '42501',
  $$UPDATE public.vm_materials SET stock_quantity = stock_quantity WHERE id = (SELECT material_id FROM qa_material_a)$$
);
SELECT pg_temp.assert_raises(
  'authenticated cannot insert stock history directly', '42501',
  $$INSERT INTO public.vm_stock_movements(
      organization_id, material_id, movement_type, quantity_delta, stock_after, created_by
    ) VALUES (
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_a), 'adjustment', 1::numeric, 13.375::numeric,
      (SELECT user_a FROM qa_identity))$$
);
SELECT pg_temp.assert_raises(
  'authenticated cannot update stock history directly', '42501',
  $$UPDATE public.vm_stock_movements SET note = 'tamper' WHERE id = (SELECT movement_id FROM qa_receipt)$$
);
SELECT pg_temp.assert_raises(
  'authenticated cannot delete stock history directly', '42501',
  $$DELETE FROM public.vm_stock_movements WHERE id = (SELECT movement_id FROM qa_receipt)$$
);
SELECT pg_temp.pass_test('direct balance and history DML denial');

-- Product compositions are immutable by version: updating the product creates
-- version 2 and leaves version 1 intact.
INSERT INTO qa_product_v1
SELECT *
FROM public.vm_upsert_product(
  (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
  'QA product', 25.00000000::numeric, 'QA',
  jsonb_build_array(jsonb_build_object(
    'material_id', (SELECT material_id FROM qa_material_a),
    'quantity', 0.33333333::numeric
  )), NULL::uuid
);
INSERT INTO qa_product_v2
SELECT *
FROM public.vm_upsert_product(
  (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
  'QA product v2', 30.00000000::numeric, 'QA',
  jsonb_build_array(jsonb_build_object(
    'material_id', (SELECT material_id FROM qa_material_a),
    'quantity', 0.50000000::numeric
  )),
  (SELECT product_id FROM qa_product_v1)
);
SELECT pg_temp.assert_true((SELECT version FROM qa_product_v1) = 1, 'first composition is version 1');
SELECT pg_temp.assert_true((SELECT version FROM qa_product_v2) = 2, 'updated composition is version 2');
SELECT pg_temp.assert_true(
  (SELECT quantity FROM vm_product_components WHERE product_id = (SELECT product_id FROM qa_product_v1) AND product_version = 1) =
  0.33333333::numeric,
  'version 1 composition remains frozen'
);
SELECT pg_temp.assert_true(
  (SELECT quantity FROM vm_product_components WHERE product_id = (SELECT product_id FROM qa_product_v1) AND product_version = 2) =
  0.50000000::numeric,
  'version 2 composition stores the new fraction'
);
SELECT pg_temp.pass_test('versioned compositions');

RESET ROLE;
SELECT pg_temp.assert_true(current_user = 'ubuntu', 'suite returns to local admin after role checks');
