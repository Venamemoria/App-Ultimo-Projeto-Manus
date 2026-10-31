#!/usr/bin/env python3
"""Exercise pre-upgrade empty snapshots and rollback in the marked local DB only."""
from __future__ import annotations
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from scripts import run_database_tests as h


def actor(conn, role, uid=None):
    conn.execute('RESET ROLE')
    conn.execute('SET ROLE ' + role)  # roles are fixed local harness literals
    conn.execute("SELECT set_config('request.jwt.claim.sub',%s,false)", (uid or '',))
    conn.execute("SELECT set_config('request.jwt.claim.role',%s,false)", (role,))
    conn.execute("SELECT set_config('request.jwt.claims',%s,false)", (json.dumps({'sub': uid, 'role': role}),))


def snapshot(conn, order_id, material_id):
    return conn.execute("""
      SELECT o.status,o.status_version,o.consumed_at,
        (SELECT count(*) FROM public.vm_order_items i WHERE i.order_id=o.id),
        (SELECT count(*) FROM public.vm_order_item_materials m WHERE m.order_id=o.id),
        (SELECT count(*) FROM public.vm_order_consumption_runs r WHERE r.order_id=o.id),
        (SELECT count(*) FROM public.vm_order_consumptions r WHERE r.order_id=o.id),
        (SELECT count(*) FROM public.vm_order_events e WHERE e.order_id=o.id),
        (SELECT count(*) FROM public.vm_notification_outbox n JOIN public.vm_order_events e ON e.id=n.event_id WHERE e.order_id=o.id),
        (SELECT count(*) FROM public.vm_stock_movements s WHERE s.order_id=o.id),
        (SELECT count(*) FROM vm_private.vm_order_requests r WHERE r.order_id=o.id),
        (SELECT stock_quantity FROM public.vm_materials WHERE id=%s)
      FROM public.vm_orders o WHERE o.id=%s
    """, (material_id, order_id)).fetchone()


def main():
    h.require_paths(); h.init_cluster_if_needed(); h.start_cluster()
    try:
        h.drop_and_create_marked_database(); h.bootstrap_roles_auth_and_users(); h.bootstrap_storage_contract()
        h.preflight_local_database(); h.bootstrap_realtime_contract()
        upgrade = h.MIGRATION_DIR / '20261031003000_require_product_recipe_for_consumption.sql'
        h.apply_migrations([p for p in sorted(h.MIGRATION_DIR.glob('*.sql')) if p.name < upgrade.name])
        h.run_sql_suite(h.ORDERS_TEST)
        with h.connect() as conn:
            conn.autocommit = True
            org = conn.execute("SELECT organization_id FROM public.vm_memberships WHERE user_id=%s AND role='owner'", (h.AUTH_USER_A,)).fetchone()[0]
            client = conn.execute("SELECT id FROM public.vm_clients WHERE organization_id=%s AND archived_at IS NULL ORDER BY created_at LIMIT 1", (org,)).fetchone()[0]
            material, valid_product = conn.execute("""
              SELECT c.material_id,p.id FROM public.vm_products p JOIN public.vm_product_components c
                ON c.organization_id=p.organization_id AND c.product_id=p.id AND c.product_version=p.current_version
              WHERE p.organization_id=%s AND p.pricing_mode='unit' ORDER BY p.created_at LIMIT 1
            """, (org,)).fetchone()
            acl_before = conn.execute("""
              SELECT has_function_privilege('anon','vm_private.vm_order_consume(uuid,uuid,uuid)','EXECUTE'),
                     has_function_privilege('authenticated','vm_private.vm_order_consume(uuid,uuid,uuid)','EXECUTE'),
                     has_function_privilege('authenticated','public.vm_set_order_status(uuid,uuid,text,text,uuid)','EXECUTE')
            """).fetchone()
            actor(conn, 'authenticated', h.AUTH_USER_A)
            empty_product = conn.execute("""
              SELECT product_id FROM public.vm_upsert_product_v2(%s,'Legacy local empty','qa','[]'::jsonb,NULL,NULL,NULL,NULL,0,'unit',
                1,NULL,1,'unit',false,false,'[]'::jsonb,NULL,NULL,NULL,NULL,NULL,NULL,'[]'::jsonb,'[]'::jsonb,'[]'::jsonb,NULL,gen_random_uuid())
            """, (org,)).fetchone()[0]
            nonce = '40000000-0000-0000-0000-000000000700'
            def create_legacy():
                return conn.execute("""
                  SELECT order_id FROM public.vm_create_order(%s,
                    jsonb_build_object('client_id',%s::uuid,'title','Legacy local mixed','order_date',CURRENT_DATE),
                    jsonb_build_array(jsonb_build_object('kind','product','product_id',%s::uuid,'quantity','1'),
                                      jsonb_build_object('kind','product','product_id',%s::uuid,'quantity','1')),%s::uuid)
                """, (org, client, empty_product, valid_product, nonce)).fetchone()[0]
            order_id = create_legacy()
            quote_token = conn.execute("""
              SELECT public_token FROM public.vm_create_quote(%s,jsonb_build_object('client_id',%s::uuid,'title','Legacy local quote','order_date',CURRENT_DATE),
                jsonb_build_array(jsonb_build_object('kind','product','product_id',%s::uuid,'quantity','1')),CURRENT_DATE+1,NULL,gen_random_uuid(),NULL)
            """, (org, client, empty_product)).fetchone()[0]
            conn.execute('RESET ROLE')
            before = snapshot(conn, order_id, material)
            assert before[0] == 'Pendente' and before[3:7] == (2, 1, 0, 0)
        h.apply_migrations([upgrade])
        with h.connect() as conn:
            conn.autocommit = True
            assert conn.execute("""
              SELECT has_function_privilege('anon','vm_private.vm_order_consume(uuid,uuid,uuid)','EXECUTE'),
                     has_function_privilege('authenticated','vm_private.vm_order_consume(uuid,uuid,uuid)','EXECUTE'),
                     has_function_privilege('authenticated','public.vm_set_order_status(uuid,uuid,text,text,uuid)','EXECUTE')
            """).fetchone() == acl_before
            actor(conn, 'authenticated', h.AUTH_USER_A)
            assert create_legacy() == order_id, 'idempotent create replay must keep historical result'
            for status in ('Em Produção', 'Concluído'):
                try:
                    conn.execute('SELECT * FROM public.vm_set_order_status(%s,%s,%s,NULL,gen_random_uuid())', (org, order_id, status))
                    raise AssertionError('old mixed order must not progress or deduct')
                except h.psycopg.Error as error:
                    assert error.sqlstate == 'VM001', error.sqlstate
            conn.execute('RESET ROLE')
            assert snapshot(conn, order_id, material) == before, 'failed transitions changed frozen history, events, requests, or stock'
            actor(conn, 'anon')
            approved_order, tracking = conn.execute('SELECT order_id,tracking_token FROM public.vm_approve_quote(%s)', (quote_token,)).fetchone()
            assert conn.execute('SELECT public.vm_get_tracking(%s) IS NOT NULL', (tracking,)).fetchone()[0]
            conn.execute('RESET ROLE')
            approved_before = snapshot(conn, approved_order, material)
            assert approved_before[0] == 'Pendente' and approved_before[3:7] == (1, 0, 0, 0)
            actor(conn, 'authenticated', h.AUTH_USER_A)
            try:
                conn.execute("SELECT * FROM public.vm_set_order_status(%s,%s,'Concluído',NULL,gen_random_uuid())", (org, approved_order))
                raise AssertionError('old approved quote with empty product must not consume')
            except h.psycopg.Error as error:
                assert error.sqlstate == 'VM001', error.sqlstate
            conn.execute('RESET ROLE')
            assert snapshot(conn, approved_order, material) == approved_before, 'old quote status attempt changed history or stock'
        print(json.dumps({'status':'passed','suite':'recipe_guard_upgrade','tests':[
            'old mixed pending order is blocked for production and direct completion with no side effects',
            'original create idempotency replay and function privileges are preserved',
            'old quote still approves and tracks; its empty physical recipe blocks later consumption',
        ]}))
    finally:
        h.stop_cluster()


if __name__ == '__main__':
    main()
