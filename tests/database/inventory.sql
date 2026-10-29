-- Inventory contract suite. The runner wraps this file in one transaction.
-- It uses only the marked local vm_test database. Fixture identities and all
-- business rows are local and are created through the public RPCs where the
-- foundation suite does so; no Supabase data is touched.

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

-- These are the same local fixture identities/tenant capture tables used by
-- foundation.sql. The runner's local auth.users contains only these two IDs.
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
CREATE TEMP TABLE qa_receipt_replay (movement_id uuid NOT NULL, stock_quantity numeric) ON COMMIT DROP;
CREATE TEMP TABLE qa_creation_replay (
  material_id uuid,
  opening_movement_id uuid,
  unit_cost numeric,
  stock_quantity numeric
) ON COMMIT DROP;
CREATE TEMP TABLE qa_adjust (
  movement_id uuid,
  material_id uuid,
  stock_quantity text
) ON COMMIT DROP;
CREATE TEMP TABLE qa_adjust_replay (
  movement_id uuid,
  material_id uuid,
  stock_quantity text
) ON COMMIT DROP;
CREATE TEMP TABLE qa_purchase (
  purchase_id uuid,
  movement_id uuid,
  cash_entry_id uuid,
  material_id uuid,
  quantity_acquired text,
  total_amount text,
  unit_cost text,
  stock_quantity text,
  payment_status text,
  paid_at date
) ON COMMIT DROP;
CREATE TEMP TABLE qa_purchase_replay (
  purchase_id uuid,
  movement_id uuid,
  cash_entry_id uuid,
  material_id uuid,
  quantity_acquired text,
  total_amount text,
  unit_cost text,
  stock_quantity text,
  payment_status text,
  paid_at date
) ON COMMIT DROP;

GRANT SELECT ON qa_identity, qa_orgs, qa_material_a, qa_material_b,
  qa_supplier_b, qa_receipt, qa_receipt_replay, qa_creation_replay,
  qa_adjust, qa_adjust_replay, qa_purchase, qa_purchase_replay
  TO authenticated, anon;
GRANT INSERT ON qa_orgs, qa_material_a, qa_material_b, qa_supplier_b,
  qa_receipt, qa_receipt_replay, qa_creation_replay, qa_adjust,
  qa_adjust_replay, qa_purchase, qa_purchase_replay TO authenticated;

-- Two organizations and one material/supplier per tenant are created through
-- the same public RPC/DML path as the foundation fixtures.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', (SELECT user_a::text FROM qa_identity), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config(
  'request.jwt.claims',
  json_build_object('sub', (SELECT user_a::text FROM qa_identity), 'role', 'authenticated')::text,
  true
);
INSERT INTO qa_orgs(user_id, organization_id, membership_id)
SELECT i.user_a, c.organization_id, c.membership_id
FROM qa_identity AS i
CROSS JOIN LATERAL public.vm_create_organization('Inventory tenant A') AS c;

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
CROSS JOIN LATERAL public.vm_create_organization('Inventory tenant B') AS c;

INSERT INTO qa_material_b
SELECT *
FROM public.vm_create_material(
  (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_b FROM qa_identity)),
  'Inventory material B', 'g', 2.00000000::numeric, 1.00000000::numeric,
  1.00000000::numeric, 0.50000000::numeric,
  'QA', NULL::uuid, NULL::uuid
);
WITH inserted AS (
  INSERT INTO public.vm_suppliers(organization_id, name)
  VALUES (
    (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_b FROM qa_identity)),
    'Inventory supplier B'
  )
  RETURNING id
)
INSERT INTO qa_supplier_b SELECT id FROM inserted;

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
  'Inventory material A', 'g', 10.00000001::numeric, 3.00000000::numeric,
  10.25000000::numeric, 1.00000000::numeric,
  'QA', NULL::uuid, '10000000-0000-0000-0000-000000000001'::uuid
);

SELECT pg_temp.assert_true((SELECT count(*) FROM qa_orgs) = 2, 'inventory fixtures create two local tenants');
SELECT pg_temp.assert_true((SELECT count(*) FROM qa_material_a) = 1, 'inventory fixture creates tenant A material');
SELECT pg_temp.assert_true((SELECT count(*) FROM qa_material_b) = 1, 'inventory fixture creates tenant B material');
SELECT pg_temp.pass_test('inventory local fixtures through foundation contract');

-- Textual DTOs, security_invoker, grants and tenant isolation.
SELECT pg_temp.assert_true(
  (SELECT count(*) FROM pg_catalog.pg_class AS c
   JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public'
     AND c.relname IN ('vm_materials_read','vm_stock_movements_read','vm_material_purchases_read','vm_cash_entries_read')
     AND c.relkind = 'v'
     AND 'security_invoker=true' = ANY(c.reloptions)) = 4,
  'all inventory read views use security_invoker'
);
SELECT pg_temp.assert_true(
  (SELECT count(*) FROM information_schema.columns
   WHERE table_schema = 'public'
     AND table_name IN ('vm_materials_read','vm_stock_movements_read','vm_material_purchases_read','vm_cash_entries_read')
     AND column_name IN (
       'package_cost','package_quantity','unit_cost','stock_quantity','reorder_level',
       'quantity_delta','stock_after','quantity_acquired','total_amount','amount'
     )
     AND data_type = 'text') = 13,
  'inventory numeric DTO columns are text'
);
SELECT pg_temp.assert_true(has_table_privilege('authenticated', 'public.vm_materials_read', 'SELECT'), 'authenticated can read materials view');
SELECT pg_temp.assert_true(has_table_privilege('authenticated', 'public.vm_stock_movements_read', 'SELECT'), 'authenticated can read movements view');
SELECT pg_temp.assert_true(has_table_privilege('authenticated', 'public.vm_material_purchases_read', 'SELECT'), 'authenticated can read purchases view');
SELECT pg_temp.assert_true(has_table_privilege('authenticated', 'public.vm_cash_entries_read', 'SELECT'), 'authenticated can read cash view');
SELECT pg_temp.assert_true(NOT has_table_privilege('anon', 'public.vm_materials_read', 'SELECT'), 'anon has no materials view grant');
SELECT pg_temp.assert_true(NOT has_table_privilege('anon', 'public.vm_material_purchases_read', 'SELECT'), 'anon has no purchases view grant');
SELECT pg_temp.pass_test('textual security_invoker views and explicit grants');

-- User A can read its own rows only; user B can read B but not A.
SELECT pg_temp.assert_true((SELECT count(*) FROM public.vm_materials_read) = 1, 'tenant A sees its material view row');
SELECT pg_temp.assert_true(
  (SELECT count(*) FROM public.vm_materials_read
   WHERE organization_id = (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_b FROM qa_identity))) = 0,
  'tenant A sees no tenant B material view row'
);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', (SELECT user_b::text FROM qa_identity), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config(
  'request.jwt.claims',
  json_build_object('sub', (SELECT user_b::text FROM qa_identity), 'role', 'authenticated')::text,
  true
);
SELECT pg_temp.assert_true((SELECT count(*) FROM public.vm_materials_read) = 1, 'tenant B sees its material view row');
SELECT pg_temp.assert_true(
  (SELECT count(*) FROM public.vm_materials_read
   WHERE organization_id = (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity))) = 0,
  'tenant B sees no tenant A material view row'
);
SELECT pg_temp.assert_true(
  (SELECT count(*) FROM public.vm_stock_movements_read
   WHERE organization_id = (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity))) = 0,
  'tenant B sees no tenant A movement view row'
);
SELECT pg_temp.assert_true(
  (SELECT count(*) FROM public.vm_material_purchases_read
   WHERE organization_id = (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity))) = 0,
  'tenant B sees no tenant A purchase view row'
);
SELECT pg_temp.assert_true(
  (SELECT count(*) FROM public.vm_cash_entries_read
   WHERE organization_id = (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity))) = 0,
  'tenant B sees no tenant A cash view row'
);
SELECT pg_temp.pass_test('inventory views have no cross-tenant exposure');

-- Numeric guards run before casts: special numeric values and excess scale are
-- rejected by every inventory write family exercised here.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', (SELECT user_a::text FROM qa_identity), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config(
  'request.jwt.claims',
  json_build_object('sub', (SELECT user_a::text FROM qa_identity), 'role', 'authenticated')::text,
  true
);
SELECT pg_temp.assert_raises(
  'create rejects NaN', '22023',
  $$SELECT * FROM public.vm_create_material(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      'NaN create', 'g', 'NaN'::numeric, 1::numeric, 0::numeric, 0::numeric,
      NULL::text, NULL::uuid, '10000000-0000-0000-0000-000000000011'::uuid)$$
);
SELECT pg_temp.assert_raises(
  'create rejects Infinity', '22023',
  $$SELECT * FROM public.vm_create_material(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      'Infinity create', 'g', 'Infinity'::numeric, 1::numeric, 0::numeric, 0::numeric,
      NULL::text, NULL::uuid, '10000000-0000-0000-0000-000000000012'::uuid)$$
);
SELECT pg_temp.assert_raises(
  'create rejects negative Infinity', '22023',
  $$SELECT * FROM public.vm_create_material(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      'negative Infinity create', 'g', '-Infinity'::numeric, 1::numeric, 0::numeric, 0::numeric,
      NULL::text, NULL::uuid, '10000000-0000-0000-0000-000000000013'::uuid)$$
);
SELECT pg_temp.assert_raises(
  'create rejects scale beyond eight decimals', '22023',
  $$SELECT * FROM public.vm_create_material(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      'scale create', 'g', 1.123456789::numeric, 1::numeric, 0::numeric, 0::numeric,
      NULL::text, NULL::uuid, '10000000-0000-0000-0000-000000000014'::uuid)$$
);
SELECT pg_temp.assert_raises(
  'receive rejects NaN', '22023',
  $$SELECT * FROM public.vm_receive_material(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_a), 'NaN'::numeric, 1::numeric, 1::numeric,
      'special', '10000000-0000-0000-0000-000000000015'::uuid)$$
);
SELECT pg_temp.assert_raises(
  'receive rejects Infinity', '22023',
  $$SELECT * FROM public.vm_receive_material(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_a), 1::numeric, 'Infinity'::numeric, 1::numeric,
      'special', '10000000-0000-0000-0000-000000000016'::uuid)$$
);
SELECT pg_temp.assert_raises(
  'receive rejects scale beyond eight decimals', '22023',
  $$SELECT * FROM public.vm_receive_material(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_a), 1.123456789::numeric, 1::numeric, 1::numeric,
      'scale', '10000000-0000-0000-0000-000000000017'::uuid)$$
);
SELECT pg_temp.assert_raises(
  'safe adjustment rejects NaN', '22023',
  $$SELECT * FROM public.vm_adjust_material_stock_safe(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_a), 'NaN'::numeric, 'special',
      '10000000-0000-0000-0000-000000000018'::uuid)$$
);
SELECT pg_temp.assert_raises(
  'safe adjustment rejects Infinity', '22023',
  $$SELECT * FROM public.vm_adjust_material_stock_safe(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_a), 'Infinity'::numeric, 'special',
      '10000000-0000-0000-0000-000000000019'::uuid)$$
);
SELECT pg_temp.assert_raises(
  'safe adjustment rejects scale beyond eight decimals', '22023',
  $$SELECT * FROM public.vm_adjust_material_stock_safe(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_a), 1.123456789::numeric, 'scale',
      '10000000-0000-0000-0000-000000000020'::uuid)$$
);
SELECT pg_temp.pass_test('NaN Infinity and excess scale rejected by material receipt and adjustment RPCs');

-- An avulsa receipt requires a key and non-empty reason/note, changes only
-- stock/history, and has no purchase or cash side effect.
SELECT pg_temp.assert_raises(
  'receive requires idempotency key', '22023',
  $$SELECT * FROM public.vm_receive_material(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_a), 1::numeric, 1::numeric, 1::numeric,
      'missing key', NULL::uuid)$$
);
SELECT pg_temp.assert_raises(
  'receive requires non-empty note', '22023',
  $$SELECT * FROM public.vm_receive_material(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_a), 1::numeric, 1::numeric, 1::numeric,
      '   ', '10000000-0000-0000-0000-000000000021'::uuid)$$
);
INSERT INTO qa_receipt
SELECT movement_id, stock_quantity
FROM public.vm_receive_material(
  (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
  (SELECT material_id FROM qa_material_a), 2.12500000::numeric,
  7.50000000::numeric, 2.00000000::numeric, 'first inventory receipt',
  '10000000-0000-0000-0000-000000000022'::uuid
);
SELECT pg_temp.assert_true(
  (SELECT stock_quantity FROM qa_receipt) = (10.25000000::numeric + 2.12500000::numeric),
  'avulsa receipt adds exact decimal quantity once'
);
SELECT pg_temp.assert_true(
  (SELECT count(*) FROM public.vm_stock_movements
   WHERE organization_id = (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity))
     AND idempotency_key = '10000000-0000-0000-0000-000000000022'::uuid) = 1,
  'avulsa receipt creates one movement'
);
SELECT pg_temp.assert_true(
  (SELECT count(*) FROM public.vm_material_purchases
   WHERE organization_id = (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity))) = 0
  AND
  (SELECT count(*) FROM public.vm_cash_entries
   WHERE organization_id = (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity))) = 0,
  'avulsa receipt creates no purchase or expense'
);
SELECT pg_temp.pass_test('receipt key and note requirements with no expense');

-- Creation replay compares its canonical request, not the current stock.
INSERT INTO qa_creation_replay
SELECT *
FROM public.vm_create_material(
  (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
  ' Inventory material A ', 'g', 10.00000001::numeric, 3.00000000::numeric,
  10.25000000::numeric, 1.00000000::numeric,
  ' QA ', NULL::uuid, '10000000-0000-0000-0000-000000000001'::uuid
);
SELECT pg_temp.assert_true(
  (SELECT material_id FROM qa_creation_replay) = (SELECT material_id FROM qa_material_a)
  AND (SELECT opening_movement_id FROM qa_creation_replay) = (SELECT opening_movement_id FROM qa_material_a)
  AND (SELECT stock_quantity FROM qa_creation_replay) = (10.25000000::numeric + 2.12500000::numeric),
  'material creation replay returns same IDs and current exact stock after receipt'
);
SELECT pg_temp.assert_raises(
  'material creation key payload mismatch is rejected', '23505',
  $$SELECT * FROM public.vm_create_material(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      'Inventory material A changed', 'g', 10.00000001::numeric, 3.00000000::numeric,
      10.25000000::numeric, 1.00000000::numeric,
      'QA', NULL::uuid, '10000000-0000-0000-0000-000000000001'::uuid)$$
);
SELECT pg_temp.assert_true(
  (SELECT count(*) FROM public.vm_materials
   WHERE organization_id = (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity))) = 1,
  'material creation replay or mismatch never duplicates the material'
);
SELECT pg_temp.pass_test('canonical material creation idempotency after stock change');

-- Safe adjustment: mandatory key/reason, idempotent replay, and atomic
-- underflow rollback. The old no-key symbol remains non-executable.
SELECT pg_temp.assert_true(
  NOT has_function_privilege('authenticated', 'public.vm_adjust_material_stock(uuid,uuid,numeric,text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.vm_adjust_material_stock(uuid,uuid,numeric,text)', 'EXECUTE'),
  'legacy adjustment has no execution privilege'
);
SELECT pg_temp.assert_raises(
  'safe adjustment requires key', '22023',
  $$SELECT * FROM public.vm_adjust_material_stock_safe(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_a), 0.50000000::numeric, 'missing key', NULL::uuid)$$
);
SELECT pg_temp.assert_raises(
  'safe adjustment requires reason', '22023',
  $$SELECT * FROM public.vm_adjust_material_stock_safe(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_a), 0.50000000::numeric, '   ',
      '10000000-0000-0000-0000-000000000023'::uuid)$$
);
SELECT pg_temp.assert_raises(
  'safe adjustment rejects zero delta', '22023',
  $$SELECT * FROM public.vm_adjust_material_stock_safe(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_a), 0::numeric, 'zero',
      '10000000-0000-0000-0000-000000000024'::uuid)$$
);
INSERT INTO qa_adjust
SELECT *
FROM public.vm_adjust_material_stock_safe(
  (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
  (SELECT material_id FROM qa_material_a), 0.50000000::numeric, 'cycle count',
  '10000000-0000-0000-0000-000000000025'::uuid
);
INSERT INTO qa_receipt_replay
SELECT movement_id, stock_quantity
FROM public.vm_receive_material(
  (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
  (SELECT material_id FROM qa_material_a), 0.25000000::numeric,
  8.00000000::numeric, 2.00000000::numeric, 'stock after adjustment',
  '10000000-0000-0000-0000-000000000026'::uuid
);
INSERT INTO qa_adjust_replay
SELECT *
FROM public.vm_adjust_material_stock_safe(
  (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
  (SELECT material_id FROM qa_material_a), 0.50000000::numeric, ' cycle count ',
  '10000000-0000-0000-0000-000000000025'::uuid
);
SELECT pg_temp.assert_true(
  (SELECT movement_id FROM qa_adjust_replay) = (SELECT movement_id FROM qa_adjust)
  AND (SELECT stock_quantity FROM qa_adjust_replay)::numeric =
      (10.25000000::numeric + 2.12500000::numeric + 0.50000000::numeric + 0.25000000::numeric),
  'safe adjustment replay returns current stock without repeating delta'
);
SELECT pg_temp.assert_true(
  (SELECT count(*) FROM public.vm_stock_movements
   WHERE organization_id = (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity))
     AND movement_type = 'adjustment') = 1,
  'safe adjustment replay creates no duplicate history'
);
SELECT pg_temp.assert_raises(
  'safe adjustment key payload mismatch is rejected', '23505',
  $$SELECT * FROM public.vm_adjust_material_stock_safe(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_a), 0.75000000::numeric, 'cycle count',
      '10000000-0000-0000-0000-000000000025'::uuid)$$
);
SELECT pg_temp.assert_raises(
  'negative safe adjustment rolls back at zero boundary', '23514',
  $$SELECT * FROM public.vm_adjust_material_stock_safe(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_a), -999.00000000::numeric, 'underflow',
      '10000000-0000-0000-0000-000000000027'::uuid)$$
);
SELECT pg_temp.assert_true(
  (SELECT stock_quantity FROM public.vm_materials
   WHERE organization_id = (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity))
     AND id = (SELECT material_id FROM qa_material_a)) =
  (10.25000000::numeric + 2.12500000::numeric + 0.50000000::numeric + 0.25000000::numeric)
  AND
  (SELECT count(*) FROM public.vm_stock_movements
   WHERE organization_id = (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity))
     AND movement_type = 'adjustment') = 1,
  'failed negative adjustment leaves balance and history unchanged'
);
SELECT pg_temp.pass_test('safe adjustment replay and atomic negative rollback');

-- Finance is a real membership, not a spoofed UID. The purchase RPC records
-- auth.uid as created_by and atomically creates all four linked effects.
RESET ROLE;
INSERT INTO public.vm_memberships(organization_id, user_id, role)
VALUES (
  (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
  (SELECT user_b FROM qa_identity),
  'finance'
);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', (SELECT user_b::text FROM qa_identity), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config(
  'request.jwt.claims',
  json_build_object('sub', (SELECT user_b::text FROM qa_identity), 'role', 'finance')::text,
  true
);

SELECT pg_temp.assert_raises(
  'purchase rejects NaN quantity', '22023',
  $$SELECT * FROM public.vm_create_material_purchase(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_a), 'NaN'::numeric, 1.00::numeric, DATE '2026-10-29',
      'pending', NULL::date, '10000000-0000-0000-0000-000000000028'::uuid, NULL::uuid, NULL::text)$$
);
SELECT pg_temp.assert_raises(
  'purchase rejects Infinity amount', '22023',
  $$SELECT * FROM public.vm_create_material_purchase(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_a), 1.00000000::numeric, 'Infinity'::numeric, DATE '2026-10-29',
      'pending', NULL::date, '10000000-0000-0000-0000-000000000029'::uuid, NULL::uuid, NULL::text)$$
);
SELECT pg_temp.assert_raises(
  'purchase rejects negative Infinity amount', '22023',
  $$SELECT * FROM public.vm_create_material_purchase(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_a), 1.00000000::numeric, '-Infinity'::numeric, DATE '2026-10-29',
      'pending', NULL::date, '10000000-0000-0000-0000-000000000030'::uuid, NULL::uuid, NULL::text)$$
);
SELECT pg_temp.assert_raises(
  'purchase rejects quantity scale beyond eight decimals', '22023',
  $$SELECT * FROM public.vm_create_material_purchase(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_a), 1.123456789::numeric, 1.00::numeric, DATE '2026-10-29',
      'pending', NULL::date, '10000000-0000-0000-0000-000000000031'::uuid, NULL::uuid, NULL::text)$$
);
SELECT pg_temp.assert_raises(
  'purchase rejects amount scale beyond two decimals', '22023',
  $$SELECT * FROM public.vm_create_material_purchase(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_a), 1.00000000::numeric, 1.001::numeric, DATE '2026-10-29',
      'pending', NULL::date, '10000000-0000-0000-0000-000000000032'::uuid, NULL::uuid, NULL::text)$$
);
SELECT pg_temp.assert_raises(
  'pending purchase rejects paid date', '22023',
  $$SELECT * FROM public.vm_create_material_purchase(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_a), 1.00000000::numeric, 1.00::numeric, DATE '2026-10-29',
      'pending', DATE '2026-10-30', '10000000-0000-0000-0000-000000000033'::uuid, NULL::uuid, NULL::text)$$
);
SELECT pg_temp.assert_raises(
  'paid purchase requires paid date', '22023',
  $$SELECT * FROM public.vm_create_material_purchase(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_a), 1.00000000::numeric, 1.00::numeric, DATE '2026-10-29',
      'paid', NULL::date, '10000000-0000-0000-0000-000000000034'::uuid, NULL::uuid, NULL::text)$$
);
SELECT pg_temp.assert_raises(
  'purchase rejects infinite purchase date', '22023',
  $$SELECT * FROM public.vm_create_material_purchase(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_a), 1.00000000::numeric, 1.00::numeric, 'infinity'::date,
      'pending', NULL::date, '10000000-0000-0000-0000-000000000035'::uuid, NULL::uuid, NULL::text)$$
);
SELECT pg_temp.pass_test('purchase numeric and payment-state guards');

INSERT INTO qa_purchase
SELECT *
FROM public.vm_create_material_purchase(
  (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
  (SELECT material_id FROM qa_material_a), 1.25000000::numeric, 12.34::numeric,
  DATE '2026-10-29', 'pending', NULL::date,
  '10000000-0000-0000-0000-000000000004'::uuid, NULL::uuid, ' DOC-001 '
);
SELECT pg_temp.assert_true(
  (SELECT quantity_acquired::numeric FROM qa_purchase) = 1.25000000::numeric
  AND (SELECT total_amount::numeric FROM qa_purchase) = 12.34::numeric
  AND (SELECT unit_cost::numeric FROM qa_purchase) = (12.34::numeric / 1.25000000::numeric)::numeric(20,8)
  AND (SELECT stock_quantity::numeric FROM qa_purchase) =
      (10.25000000::numeric + 2.12500000::numeric + 0.50000000::numeric + 0.25000000::numeric + 1.25000000::numeric)
  AND (SELECT payment_status FROM qa_purchase) = 'pending'
  AND (SELECT paid_at FROM qa_purchase) IS NULL,
  'purchase RPC returns exact Decimal values and pending state'
);
SELECT pg_temp.assert_true(
  (SELECT count(*) FROM public.vm_material_purchases AS p
   WHERE p.id = (SELECT purchase_id FROM qa_purchase)
     AND p.organization_id = (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity))
     AND p.created_by = (SELECT user_b FROM qa_identity)
     AND p.quantity_acquired = 1.25000000::numeric
     AND p.total_amount = 12.34::numeric
     AND p.unit_cost = (12.34::numeric / 1.25000000::numeric)::numeric(20,8)
     AND p.payment_status = 'pending' AND p.paid_at IS NULL) = 1,
  'purchase row is created by finance auth.uid with exact amounts'
);
SELECT pg_temp.assert_true(
  (SELECT count(*) FROM public.vm_stock_movements AS sm
   WHERE sm.id = (SELECT movement_id FROM qa_purchase)
     AND sm.purchase_id = (SELECT purchase_id FROM qa_purchase)
     AND sm.organization_id = (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity))
     AND sm.movement_type = 'receipt'
     AND sm.quantity_delta = 1.25000000::numeric
     AND sm.package_cost = 12.34::numeric
     AND sm.package_quantity = 1.25000000::numeric
     AND sm.stock_after = (10.25000000::numeric + 2.12500000::numeric + 0.50000000::numeric + 0.25000000::numeric + 1.25000000::numeric)
     AND sm.created_by = (SELECT user_b FROM qa_identity)) = 1,
  'purchase creates linked receipt movement atomically'
);
SELECT pg_temp.assert_true(
  (SELECT count(*) FROM public.vm_cash_entries AS ce
   WHERE ce.id = (SELECT cash_entry_id FROM qa_purchase)
     AND ce.material_purchase_id = (SELECT purchase_id FROM qa_purchase)
     AND ce.organization_id = (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity))
     AND ce.entry_type = 'expense'
     AND ce.amount = 12.34::numeric
     AND ce.entry_date = DATE '2026-10-29'
     AND ce.payment_status = 'pending' AND ce.paid_at IS NULL
     AND ce.created_by = (SELECT user_b FROM qa_identity)) = 1,
  'purchase creates linked pending expense atomically'
);
SELECT pg_temp.assert_true(
  (SELECT count(*) FROM public.vm_material_purchases_read
   WHERE id = (SELECT purchase_id FROM qa_purchase)
     AND receipt_movement_id = (SELECT movement_id FROM qa_purchase)
     AND cash_entry_id = (SELECT cash_entry_id FROM qa_purchase)
     AND total_amount = '12.34'
     AND unit_cost = ((12.34::numeric / 1.25000000::numeric)::numeric(20,8))::text) = 1
  AND
  (SELECT count(*) FROM public.vm_cash_entries_read
   WHERE id = (SELECT cash_entry_id FROM qa_purchase)
     AND material_purchase_id = (SELECT purchase_id FROM qa_purchase)
     AND amount = '12.34') = 1,
  'purchase and cash views expose exact linked text DTOs'
);
SELECT pg_temp.pass_test('atomic pending purchase stock movement purchase and cash links');

-- Same purchase payload replays the same three IDs without another row or
-- balance change. A mismatch and a cross-flow key collision are errors.
INSERT INTO qa_purchase_replay
SELECT *
FROM public.vm_create_material_purchase(
  (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
  (SELECT material_id FROM qa_material_a), 1.25000000::numeric, 12.34::numeric,
  DATE '2026-10-29', 'pending', NULL::date,
  '10000000-0000-0000-0000-000000000004'::uuid, NULL::uuid, 'DOC-001'
);
SELECT pg_temp.assert_true(
  (SELECT purchase_id FROM qa_purchase_replay) = (SELECT purchase_id FROM qa_purchase)
  AND (SELECT movement_id FROM qa_purchase_replay) = (SELECT movement_id FROM qa_purchase)
  AND (SELECT cash_entry_id FROM qa_purchase_replay) = (SELECT cash_entry_id FROM qa_purchase)
  AND (SELECT stock_quantity::numeric FROM qa_purchase_replay) = (SELECT stock_quantity::numeric FROM qa_purchase)
  AND (SELECT count(*) FROM public.vm_material_purchases
       WHERE organization_id = (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity))) = 1
  AND (SELECT count(*) FROM public.vm_cash_entries
       WHERE organization_id = (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity))) = 1,
  'purchase replay returns original links without duplicate rows or stock'
);
SELECT pg_temp.assert_raises(
  'purchase key payload mismatch is rejected', '23505',
  $$SELECT * FROM public.vm_create_material_purchase(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_a), 1.25000000::numeric, 12.35::numeric,
      DATE '2026-10-29', 'pending', NULL::date,
      '10000000-0000-0000-0000-000000000004'::uuid, NULL::uuid, 'DOC-001')$$
);
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', (SELECT user_a::text FROM qa_identity), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config(
  'request.jwt.claims',
  json_build_object('sub', (SELECT user_a::text FROM qa_identity), 'role', 'owner')::text,
  true
);
SELECT pg_temp.assert_raises(
  'purchase key cannot be reused by avulsa receipt', '23505',
  $$SELECT * FROM public.vm_receive_material(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_a), 1.00000000::numeric, 1.00::numeric, 1.00000000::numeric,
      'cross flow', '10000000-0000-0000-0000-000000000004'::uuid)$$
);
SELECT pg_temp.assert_raises(
  'creation key cannot be reused by purchase', '23505',
  $$SELECT * FROM public.vm_create_material_purchase(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_a), 1.00000000::numeric, 1.00::numeric,
      DATE '2026-10-29', 'pending', NULL::date,
      '10000000-0000-0000-0000-000000000001'::uuid, NULL::uuid, NULL::text)$$
);
SELECT pg_temp.pass_test('purchase replay mismatch and cross-flow key barriers');

-- A successful paid purchase proves the paid date is preserved as declared.
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', (SELECT user_b::text FROM qa_identity), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config(
  'request.jwt.claims',
  json_build_object('sub', (SELECT user_b::text FROM qa_identity), 'role', 'finance')::text,
  true
);
SELECT pg_temp.assert_true(
  (SELECT payment_status FROM public.vm_create_material_purchase(
    (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
    (SELECT material_id FROM qa_material_a), 0.50000000::numeric, 1.23::numeric,
    DATE '2026-10-30', 'paid', DATE '2026-10-31',
    '10000000-0000-0000-0000-000000000006'::uuid, NULL::uuid, 'paid document')) = 'paid',
  'finance can create a paid purchase with required paid date'
);
SELECT pg_temp.assert_true(
  (SELECT paid_at FROM public.vm_material_purchases
   WHERE idempotency_key = '10000000-0000-0000-0000-000000000006'::uuid) = DATE '2026-10-31'
  AND
  (SELECT paid_at FROM public.vm_cash_entries
   WHERE material_purchase_id = (SELECT id FROM public.vm_material_purchases
                                 WHERE idempotency_key = '10000000-0000-0000-0000-000000000006'::uuid)) = DATE '2026-10-31',
  'paid purchase and expense preserve exact paid date'
);
SELECT pg_temp.pass_test('paid purchase payment state');

-- Production and viewer memberships cannot call the purchase RPC; finance's
-- successful call above used auth.uid directly and supplied no user spoof.
RESET ROLE;
UPDATE public.vm_memberships
SET role = 'production'
WHERE organization_id = (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity))
  AND user_id = (SELECT user_b FROM qa_identity);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', (SELECT user_b::text FROM qa_identity), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config(
  'request.jwt.claims',
  json_build_object('sub', (SELECT user_b::text FROM qa_identity), 'role', 'production')::text,
  true
);
SELECT pg_temp.assert_raises(
  'production cannot create purchase', '42501',
  $$SELECT * FROM public.vm_create_material_purchase(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_a), 1.00000000::numeric, 1.00::numeric,
      DATE '2026-11-01', 'pending', NULL::date,
      '10000000-0000-0000-0000-000000000036'::uuid, NULL::uuid, NULL::text)$$
);
RESET ROLE;
UPDATE public.vm_memberships
SET role = 'viewer'
WHERE organization_id = (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity))
  AND user_id = (SELECT user_b FROM qa_identity);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', (SELECT user_b::text FROM qa_identity), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config(
  'request.jwt.claims',
  json_build_object('sub', (SELECT user_b::text FROM qa_identity), 'role', 'viewer')::text,
  true
);
SELECT pg_temp.assert_raises(
  'viewer cannot create purchase', '42501',
  $$SELECT * FROM public.vm_create_material_purchase(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_a), 1.00000000::numeric, 1.00::numeric,
      DATE '2026-11-02', 'pending', NULL::date,
      '10000000-0000-0000-0000-000000000037'::uuid, NULL::uuid, NULL::text)$$
);
SELECT pg_temp.assert_true(
  (SELECT count(*) FROM public.vm_material_purchases
   WHERE organization_id = (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity))) = 2,
  'denied production and viewer purchase calls create no rows'
);
SELECT pg_temp.pass_test('finance purchase authorization without UID spoof and role denials');

-- Composite same-tenant FKs are enforced by RPC boundaries.
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', (SELECT user_a::text FROM qa_identity), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config(
  'request.jwt.claims',
  json_build_object('sub', (SELECT user_a::text FROM qa_identity), 'role', 'owner')::text,
  true
);
SELECT pg_temp.assert_raises(
  'purchase rejects supplier from another tenant', '23503',
  $$SELECT * FROM public.vm_create_material_purchase(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_a), 1.00000000::numeric, 1.00::numeric,
      DATE '2026-11-03', 'pending', NULL::date,
      '10000000-0000-0000-0000-000000000038'::uuid,
      (SELECT supplier_id FROM qa_supplier_b), NULL::text)$$
);
SELECT pg_temp.assert_raises(
  'receive rejects material from another tenant', '23503',
  $$SELECT * FROM public.vm_receive_material(
      (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_b), 1.00000000::numeric, 1.00::numeric, 1.00::numeric,
      'wrong tenant', '10000000-0000-0000-0000-000000000039'::uuid)$$
);
SELECT pg_temp.pass_test('composite tenant foreign-key barriers');

-- Anonymous sessions have neither operational view access nor write execution.
SET LOCAL ROLE anon;
SELECT set_config('request.jwt.claim.sub', (SELECT user_a::text FROM qa_identity), true);
SELECT set_config('request.jwt.claim.role', 'anon', true);
SELECT set_config(
  'request.jwt.claims',
  json_build_object('sub', (SELECT user_a::text FROM qa_identity), 'role', 'anon')::text,
  true
);
SELECT pg_temp.assert_raises('anon cannot read inventory views', '42501', 'SELECT count(*) FROM public.vm_materials_read');
SELECT pg_temp.assert_raises(
  'anon cannot execute purchase RPC', '42501',
  $$SELECT * FROM public.vm_create_material_purchase(
      '00000000-0000-0000-0000-000000000001'::uuid,
      '00000000-0000-0000-0000-000000000002'::uuid, 1::numeric, 1::numeric,
      DATE '2026-11-04', 'pending', NULL::date,
      '10000000-0000-0000-0000-000000000040'::uuid, NULL::uuid, NULL::text)$$
);
SELECT pg_temp.pass_test('anonymous inventory read and RPC denial');

-- Authenticated direct DML is denied, and privileged accidental mutations are
-- still rejected by append-only triggers for all three history tables.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', (SELECT user_a::text FROM qa_identity), true);
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config(
  'request.jwt.claims',
  json_build_object('sub', (SELECT user_a::text FROM qa_identity), 'role', 'owner')::text,
  true
);
SELECT pg_temp.assert_raises(
  'authenticated cannot insert purchase history directly', '42501',
  $$INSERT INTO public.vm_material_purchases(
      organization_id,material_id,quantity_acquired,total_amount,purchase_date,payment_status,
      paid_at,idempotency_key,created_by)
    VALUES ((SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      (SELECT material_id FROM qa_material_a),1::numeric,1::numeric,DATE '2026-11-05','pending',NULL,
      '10000000-0000-0000-0000-000000000041'::uuid,(SELECT user_a FROM qa_identity))$$
);
SELECT pg_temp.assert_raises(
  'authenticated cannot insert cash history directly', '42501',
  $$INSERT INTO public.vm_cash_entries(
      organization_id,entry_type,amount,entry_date,description,payment_status,paid_at,created_by)
    VALUES ((SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity)),
      'expense',1::numeric,DATE '2026-11-05','direct attempt','pending',NULL,(SELECT user_a FROM qa_identity))$$
);
RESET ROLE;
SELECT pg_temp.assert_raises(
  'purchase history trigger rejects update', '55000',
  $$UPDATE public.vm_material_purchases SET document_reference = 'tamper'
    WHERE id = (SELECT purchase_id FROM qa_purchase)$$
);
SELECT pg_temp.assert_raises(
  'purchase history trigger rejects delete', '55000',
  $$DELETE FROM public.vm_material_purchases WHERE id = (SELECT purchase_id FROM qa_purchase)$$
);
SELECT pg_temp.assert_raises(
  'cash history trigger rejects update', '55000',
  $$UPDATE public.vm_cash_entries SET description = 'tamper'
    WHERE id = (SELECT cash_entry_id FROM qa_purchase)$$
);
SELECT pg_temp.assert_raises(
  'cash history trigger rejects delete', '55000',
  $$DELETE FROM public.vm_cash_entries WHERE id = (SELECT cash_entry_id FROM qa_purchase)$$
);
SELECT pg_temp.assert_raises(
  'stock history trigger rejects update', '55000',
  $$UPDATE public.vm_stock_movements SET note = 'tamper'
    WHERE id = (SELECT movement_id FROM qa_purchase)$$
);
SELECT pg_temp.assert_raises(
  'stock history trigger rejects delete', '55000',
  $$DELETE FROM public.vm_stock_movements WHERE id = (SELECT movement_id FROM qa_purchase)$$
);
SELECT pg_temp.assert_true(
  (SELECT count(*) FROM public.vm_material_purchases
   WHERE organization_id = (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity))) = 2
  AND (SELECT count(*) FROM public.vm_cash_entries
       WHERE organization_id = (SELECT organization_id FROM qa_orgs WHERE user_id = (SELECT user_a FROM qa_identity))) = 2,
  'append-only mutation attempts leave purchase and cash history intact'
);
SELECT pg_temp.pass_test('history append-only privileges and triggers');

RESET ROLE;
SELECT pg_temp.assert_true(current_user = 'ubuntu', 'inventory suite returns to local admin');
SELECT pg_temp.pass_test('inventory suite completed under local vm_test admin');
