"""Apply reviewed foundation to the explicitly configured Supabase project.

Secrets are read from the process environment, never written or printed.
No users, organizations, materials or orders are seeded by this script.
"""
import json
import sys
from pathlib import Path

import psycopg
from supabase_connection import database_parameters, api_base
from migration_history import apply_initial_migration, verify_history

ROOT = Path(__file__).resolve().parents[1]
VERSION = "20261029203500_foundation"


def main():
    stage = "connection"
    try:
        config = json.loads((ROOT / "supabase/project.json").read_text())
        if api_base().split("//", 1)[1].split(".", 1)[0] != config["projectRef"]:
            raise ValueError("PROJECT_MISMATCH")
        parameters = database_parameters(strip_password_delimiters=True)
        parameters.update(host=config["poolerHost"], port=config["poolerPort"], user="postgres." + config["projectRef"], prepare_threshold=None)
        with psycopg.connect(**parameters, autocommit=True) as connection:
            connection.execute("SELECT pg_advisory_lock(hashtext('vm_schema_migrations'))")
            stage = "preflight"
            exists = connection.execute("SELECT to_regclass('public.vm_schema_migrations') IS NOT NULL").fetchone()[0]
            if exists:
                verify_history(connection)
                applied = connection.execute("SELECT EXISTS(SELECT 1 FROM public.vm_schema_migrations WHERE version=%s)", (VERSION,)).fetchone()[0]
                if not applied:
                    raise ValueError("EXISTING_FOUNDATION_REQUIRES_REVIEW")
                print(json.dumps({"migration": VERSION, "status": "already_applied"}))
            else:
                tables = connection.execute("SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_name LIKE 'vm_%'").fetchall()
                if tables:
                    raise ValueError("EXISTING_TABLES_REQUIRES_REVIEW")
                stage = "migration"
                apply_initial_migration(connection, ROOT / "supabase/migrations" / (VERSION + ".sql"))
                print(json.dumps({"migration": VERSION, "status": "applied"}))
            verify_history(connection)
            stage = "verification"
            tables = connection.execute("SELECT tablename, rowsecurity FROM pg_tables WHERE schemaname='public' AND tablename LIKE 'vm_%' ORDER BY 1").fetchall()
            policies = connection.execute("SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename LIKE 'vm_%'").fetchone()[0]
            rpc_permissions = connection.execute("SELECT proname, has_function_privilege('anon', oid, 'EXECUTE'), has_function_privilege('authenticated', oid, 'EXECUTE') FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname LIKE 'vm_%' ORDER BY 1").fetchall()
            anon_select = connection.execute("SELECT has_table_privilege('anon','public.vm_materials','SELECT')").fetchone()[0]
            auth_direct_stock_write = connection.execute("SELECT has_table_privilege('authenticated','public.vm_materials','UPDATE')").fetchone()[0]
            history_mutations = connection.execute("SELECT has_table_privilege('authenticated','public.vm_stock_movements','INSERT,UPDATE,DELETE')").fetchone()[0]
            if len(tables) != 9 or not all(row[1] for row in tables) or anon_select or auth_direct_stock_write or history_mutations:
                raise ValueError("SECURITY_VERIFICATION_FAILED")
            report = {"migration": VERSION, "verification": "passed", "tables_rls": tables, "policy_count": policies, "rpc_permissions": rpc_permissions, "anonymous_material_read": anon_select, "direct_stock_update": auth_direct_stock_write, "direct_history_mutation": history_mutations}
            print(json.dumps(report, ensure_ascii=False))
            (ROOT / "docs/foundation-verification.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        return 0
    except Exception as error:
        reason = str(error) if isinstance(error, ValueError) else (getattr(getattr(error, "diag", None), "message_primary", None) if stage != "connection" else "connection_error_redacted")
        print(json.dumps({"stage": stage, "status": "failed", "error_type": type(error).__name__, "sqlstate": getattr(error, "sqlstate", None), "reason": reason}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
