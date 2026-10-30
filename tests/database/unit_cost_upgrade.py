#!/usr/bin/env python3
"""Verify fractional-cost upgrade on pre-existing snapshots in a marked local DB.

The harness owns a private Unix socket and resets only its marked vm_test DB.
No connection to the Supabase project or real tenant data is made.
"""
from __future__ import annotations

import json
import sys
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from scripts import run_database_tests as h

VIEWS = [
    'vm_materials_read', 'vm_material_purchases_read', 'vm_suppliers_read', 'vm_products_read',
    'vm_product_components_read', 'vm_product_versions_read', 'vm_order_items_read',
]


def assert_true(value: bool, label: str) -> None:
    if not value:
        raise AssertionError(label)


def acl_snapshot(conn):
    return conn.execute("""
      SELECT c.relname,r.role,p.privilege,has_table_privilege(r.role,c.oid,p.privilege)
      FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      CROSS JOIN (VALUES('anon'),('authenticated'),('service_role')) r(role)
      CROSS JOIN LATERAL unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'] ||
        CASE WHEN current_setting('server_version_num')::int >= 170000 THEN ARRAY['MAINTAIN']::text[] ELSE ARRAY[]::text[] END) p(privilege)
      WHERE n.nspname='public' AND c.relname=ANY(%s) ORDER BY 1,2,3
    """, (VIEWS,)).fetchall()


def acting_as_owner(conn):
    conn.execute('SET ROLE authenticated')
    conn.execute("SELECT set_config('request.jwt.claim.sub',%s,false)", (h.AUTH_USER_A,))
    conn.execute("SELECT set_config('request.jwt.claim.role','authenticated',false)")
    conn.execute("SELECT set_config('request.jwt.claims',%s,false)", (json.dumps({'sub':h.AUTH_USER_A,'role':'authenticated'}),))


def upsert(conn, org, material, product_id, nonce):
    return conn.execute("""
      SELECT * FROM public.vm_upsert_product_v2(
        %s::uuid,'Histórico QA','orders','[]'::jsonb,NULL,NULL,NULL,NULL,0,'unit',
        1::numeric,NULL,1::numeric,'unit',false,false,'[]'::jsonb,
        NULL,NULL,NULL,NULL,'COST-HISTORY-QA',NULL,'[]'::jsonb,
        jsonb_build_array(jsonb_build_object('material_id',%s::uuid,'quantity','0.00000001','unit','g')),
        '[]'::jsonb,%s::uuid,%s::uuid)
    """, (org, material, product_id, nonce)).fetchone()


def main():
    h.require_paths()
    h.init_cluster_if_needed()
    h.start_cluster()
    try:
        h.drop_and_create_marked_database()
        h.bootstrap_roles_auth_and_users()
        h.bootstrap_storage_contract()
        h.preflight_local_database()
        h.bootstrap_realtime_contract()
        upgrade = h.MIGRATION_DIR / '20261030011000_fractional_unit_cost.sql'
        h.apply_migrations([p for p in sorted(h.MIGRATION_DIR.glob('*.sql')) if p.name < upgrade.name])
        h.run_sql_suite(h.ORDERS_TEST)
        with h.connect() as conn:
            conn.autocommit = True
            if not conn.execute("SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='service_role')").fetchone()[0]:
                conn.execute('CREATE ROLE service_role NOLOGIN')
            for view in VIEWS:
                conn.execute('GRANT ALL ON public.' + view + ' TO service_role')
            acl_before = acl_snapshot(conn)
            conn.execute('ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon,authenticated,service_role')
            org = conn.execute("SELECT organization_id FROM public.vm_memberships WHERE user_id=%s AND role='owner'", (h.AUTH_USER_A,)).fetchone()[0]
            acting_as_owner(conn)
            material = conn.execute("""
              SELECT material_id FROM public.vm_create_material(%s::uuid,'Histórico custo QA','g',1::numeric,3::numeric,
                10::numeric,0::numeric,'orders',NULL::uuid,'40000000-0000-0000-0000-000000000501'::uuid)
            """, (org,)).fetchone()[0]
            old_product = upsert(conn,org,material,None,'40000000-0000-0000-0000-000000000502')[0]
            conn.execute('RESET ROLE')
            before = conn.execute("""
              SELECT c.unit_cost_snapshot,c.line_cost,v.composition_cost,v.composition_snapshot
              FROM public.vm_product_components c JOIN public.vm_product_versions v
               ON v.organization_id=c.organization_id AND v.product_id=c.product_id AND v.product_version=c.product_version
              WHERE c.product_id=%s
            """, (old_product,)).fetchone()
            assert_true(before[0] == Decimal('0.33333333') and before[1] == 0 and before[2] == 0, 'fixture should use old rounded cost')
        h.apply_migrations([upgrade])
        with h.connect() as conn:
            conn.autocommit = True
            after = conn.execute("""
              SELECT c.unit_cost_snapshot,c.line_cost,v.composition_cost,v.composition_snapshot,
                     c.cost_precision_version,c.line_cost_precise,
                     (SELECT line_cost::numeric FROM public.vm_product_components_read r WHERE r.product_id=c.product_id AND r.product_version='1')
              FROM public.vm_product_components c JOIN public.vm_product_versions v
               ON v.organization_id=c.organization_id AND v.product_id=c.product_id AND v.product_version=c.product_version
              WHERE c.product_id=%s AND c.product_version=1
            """, (old_product,)).fetchone()
            assert_true(before == after[:4] and after[4:] == (0,Decimal(0),Decimal(0)), 'historical snapshots and old line costs must not change')
            assert_true(acl_before == acl_snapshot(conn), 'view ACLs changed despite default privilege guard')
            acting_as_owner(conn)
            result = upsert(conn,org,material,old_product,'40000000-0000-0000-0000-000000000503')
            assert_true(result[1]=='2' and Decimal(result[-1])==Decimal('0.00000000333333333333333333333333'), 'new version must use the precise material unit cost')
            conn.execute('RESET ROLE')
            versions = conn.execute("""
              SELECT product_version,composition_cost,composition_snapshot FROM public.vm_product_versions
              WHERE product_id=%s ORDER BY product_version
            """, (old_product,)).fetchall()
            assert_true(versions[0][1:] == before[2:] and versions[1][1] == Decimal('0.00000000333333333333333333333333'), 'old version changed after new product version')
        print(json.dumps({'status':'passed','suite':'unit_cost_upgrade','tests':[
            'historic rounded recipe and frozen JSON remain unchanged',
            'permissive default ACLs do not widen view access',
            'new product version uses precise current unit cost without rewriting old version',
        ]}))
    finally:
        h.stop_cluster()


if __name__ == '__main__':
    main()
