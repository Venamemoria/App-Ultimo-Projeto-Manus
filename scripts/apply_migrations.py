"""Apply reviewed versioned migrations to the authorized Supabase, never seed data."""
import argparse
import hashlib
import json
import sys
from pathlib import Path

import psycopg
from supabase_connection import api_base, database_parameters

ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = ROOT / "supabase/migrations"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", help="Exact reviewed migration filename, including .sql")
    args = parser.parse_args()
    stage = "connection"
    try:
        config = json.loads((ROOT / "supabase/project.json").read_text())
        if api_base().split("//", 1)[1].split(".", 1)[0] != config["projectRef"]:
            raise ValueError("PROJECT_MISMATCH")
        files = sorted(MIGRATIONS.glob("*.sql"))
        if args.only:
            files = [p for p in files if p.name == args.only]
            if len(files) != 1:
                raise ValueError("REVIEWED_MIGRATION_NOT_FOUND")
        parameters = database_parameters(strip_password_delimiters=True)
        parameters.update(host=config["poolerHost"], port=config["poolerPort"], user="postgres." + config["projectRef"], prepare_threshold=None)
        reports = []
        with psycopg.connect(**parameters, autocommit=True) as connection:
            connection.execute("SELECT pg_advisory_lock(hashtext('vm_schema_migrations'))")
            for path in files:
                version = path.stem
                stage = "preflight"
                registry = connection.execute("SELECT to_regclass('public.vm_schema_migrations') IS NOT NULL").fetchone()[0]
                applied = registry and connection.execute("SELECT EXISTS(SELECT 1 FROM public.vm_schema_migrations WHERE version=%s)", (version,)).fetchone()[0]
                digest = hashlib.sha256(path.read_bytes()).hexdigest()
                if applied:
                    reports.append({"version": version, "status": "already_applied", "source_sha256": digest})
                    continue
                if not registry:
                    raise ValueError("FOUNDATION_MUST_BE_APPLIED_FIRST")
                sql = path.read_text()
                if not sql.lstrip().startswith("BEGIN;") or not sql.strip().endswith("COMMIT;"):
                    raise ValueError("TRANSACTION_REQUIRED")
                stage = "migration"
                connection.execute(sql, prepare=False)
                stage = "verification"
                if not connection.execute("SELECT EXISTS(SELECT 1 FROM public.vm_schema_migrations WHERE version=%s)", (version,)).fetchone()[0]:
                    raise ValueError("MIGRATION_REGISTRY_MISSING")
                reports.append({"version": version, "status": "applied", "source_sha256": digest})
            tables = connection.execute("SELECT n.nspname||'.'||c.relname,c.relrowsecurity FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('public','vm_private') AND c.relkind IN ('r','p') AND c.relname LIKE 'vm_%' ORDER BY 1").fetchall()
            if not all(enabled for _, enabled in tables):
                raise ValueError("TABLE_WITHOUT_RLS")
            result = {"migrations": reports, "verification": "passed", "tables_rls": tables}
            (ROOT / "docs/migrations-verification.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
            print(json.dumps(result, ensure_ascii=False))
            connection.execute("SELECT pg_advisory_unlock(hashtext('vm_schema_migrations'))")
        return 0
    except Exception as error:
        reason = str(error) if isinstance(error, ValueError) else "database_error_redacted"
        print(json.dumps({"status": "failed", "stage": stage, "type": type(error).__name__, "sqlstate": getattr(error, "sqlstate", None), "reason": reason}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
