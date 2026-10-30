-- One-time, history-only repair for the verified 20261030005000 baseline.
-- Run only after comparing the application schema with this exact Git baseline.
-- This script never executes any application migration or touches business rows.
BEGIN;
SET LOCAL lock_timeout = '5s';
SELECT pg_advisory_xact_lock(hashtext('vm_schema_migrations'));

DO $guard$
DECLARE
  expected_custom constant text[] := ARRAY[
    '20261029203500_foundation',
    '20261029221500_inventory',
    '20261029233000_products',
    '20261029235500_contacts',
    '20261030002000_orders',
    '20261030002200_order_returns',
    '20261030003000_public_sales',
    '20261030003500_quote_admin_list',
    '20261030004000_tracking_minimal_acl',
    '20261030005000_finance_summary'
  ];
  expected_official constant text[] := ARRAY[
    '20261029203500', '20261029221500', '20261029233000', '20261029235500',
    '20261030002000', '20261030002200', '20261030003000', '20261030003500',
    '20261030004000', '20261030005000'
  ];
  actual_custom text[];
  actual_official text[];
BEGIN
  IF to_regclass('public.vm_schema_migrations') IS NULL THEN
    RAISE EXCEPTION 'Custom migration history is absent; refusing repair';
  END IF;
  SELECT array_agg(version ORDER BY version) INTO actual_custom FROM public.vm_schema_migrations;
  IF actual_custom IS DISTINCT FROM expected_custom THEN
    RAISE EXCEPTION 'Custom migration history differs from the reviewed baseline; refusing repair';
  END IF;
  IF to_regclass('supabase_migrations.schema_migrations') IS NOT NULL THEN
    EXECUTE 'SELECT array_agg(version ORDER BY version) FROM supabase_migrations.schema_migrations'
      INTO actual_official;
    IF actual_official IS NOT NULL AND actual_official IS DISTINCT FROM expected_official THEN
      RAISE EXCEPTION 'Official migration history is not empty or already reconciled; refusing repair';
    END IF;
  END IF;
END
$guard$;

-- Same schema and columns as Supabase CLI's migration-history table.
CREATE SCHEMA IF NOT EXISTS supabase_migrations;
REVOKE ALL ON SCHEMA supabase_migrations FROM PUBLIC, anon, authenticated;
CREATE TABLE IF NOT EXISTS supabase_migrations.schema_migrations (
  version text NOT NULL PRIMARY KEY
);
ALTER TABLE supabase_migrations.schema_migrations ADD COLUMN IF NOT EXISTS statements text[];
ALTER TABLE supabase_migrations.schema_migrations ADD COLUMN IF NOT EXISTS name text;
REVOKE ALL ON TABLE supabase_migrations.schema_migrations FROM PUBLIC, anon, authenticated;

DO $guard$
BEGIN
  IF EXISTS (
    SELECT 1 FROM supabase_migrations.schema_migrations s
    JOIN public.vm_schema_migrations v ON split_part(v.version, '_', 1) = s.version
    WHERE s.name IS NOT NULL AND s.name <> substr(v.version, 16)
  ) THEN
    RAISE EXCEPTION 'Official migration names conflict with reviewed history; refusing repair';
  END IF;
END
$guard$;

-- The original SQL remains in Git; NULL does not pretend that statements were
-- uploaded to the official ledger. See docs/migration-reconciliation.md.
INSERT INTO supabase_migrations.schema_migrations(version, name, statements)
SELECT split_part(version, '_', 1), substr(version, 16), NULL::text[]
FROM public.vm_schema_migrations
ON CONFLICT (version) DO NOTHING;
COMMIT;
