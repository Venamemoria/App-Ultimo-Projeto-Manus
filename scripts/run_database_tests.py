#!/usr/bin/env python3
"""Run isolated PostgreSQL QA suites for Vê na Memória.

This harness is deliberately separate from Supabase and from the application:
- it owns only .local/test-db;
- it never uses SUPABASE_DATABASE_URL for test fixtures;
- the optional Supabase connection is read-only and only fetches the real
  auth.uid/auth.role/auth.jwt helper definitions used to reproduce the local
  Auth GUC contract.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Iterable

import psycopg
from psycopg import sql

ROOT = Path(__file__).resolve().parents[1]
PG_BIN = Path("/usr/lib/postgresql/16/bin")
LOCAL_ROOT = ROOT / ".local" / "test-db"
DATA_DIR = LOCAL_ROOT / "data"
SOCKET_DIR = LOCAL_ROOT / "socket"
MARKER_FILE = LOCAL_ROOT / ".vm-test-cluster-marker"
HELPERS_FILE = LOCAL_ROOT / "auth-helper-defs.sql"
DB_NAME = "vm_test"
DB_USER = "ubuntu"
PORT = 55432
# Kept as a stable, non-secret value so a marked cluster can be identified
# before destructive reset.  It is never accepted from the environment.
CLUSTER_MARKER = "venamemoria-local-test-db-v1"

FOUNDATION = ROOT / "supabase" / "migrations" / "20261029203500_foundation.sql"
MIGRATION_DIR = ROOT / "supabase" / "migrations"
FOUNDATION_TEST = ROOT / "tests" / "database" / "foundation.sql"
INVENTORY_TEST = ROOT / "tests" / "database" / "inventory.sql"
PRODUCTS_TEST = ROOT / "tests" / "database" / "products.sql"
PRODUCTS_MIGRATION = ROOT / "supabase" / "migrations" / "20261029233000_products.sql"
CONTACTS_TEST = ROOT / "tests" / "database" / "contacts.sql"
CONTACTS_MIGRATION = ROOT / "supabase" / "migrations" / "20261029235500_contacts.sql"

AUTH_USER_A = "00000000-0000-0000-0000-0000000000a1"
AUTH_USER_B = "00000000-0000-0000-0000-0000000000b2"


def fail(stage: str, exc: BaseException | None = None) -> None:
    """Emit a safe failure record; never print connection details or SQL args."""
    payload: dict[str, object] = {"status": "failed", "stage": stage}
    if exc is not None:
        payload["error_type"] = type(exc).__name__
        sqlstate = getattr(exc, "sqlstate", None)
        if sqlstate:
            payload["sqlstate"] = sqlstate
    print(json.dumps(payload, ensure_ascii=False))
    raise SystemExit(1)


def run_quiet(command: list[str], *, stage: str) -> None:
    try:
        subprocess.run(
            command,
            cwd=ROOT,
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        fail(stage, exc)


def pg_ctl(*args: str, stage: str) -> None:
    run_quiet([str(PG_BIN / "pg_ctl"), *args], stage=stage)


def require_paths() -> None:
    for path in (PG_BIN / "initdb", PG_BIN / "pg_ctl", PG_BIN / "psql"):
        if not path.exists():
            raise RuntimeError("POSTGRES16_BINARY_MISSING")
    if not FOUNDATION.exists():
        raise RuntimeError("FOUNDATION_MIGRATION_MISSING")
    if not FOUNDATION_TEST.exists():
        raise RuntimeError("FOUNDATION_TEST_MISSING")


def ensure_private_dirs() -> None:
    LOCAL_ROOT.mkdir(parents=True, exist_ok=True)
    SOCKET_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(LOCAL_ROOT, 0o700)
    os.chmod(SOCKET_DIR, 0o700)


def write_cluster_marker() -> None:
    MARKER_FILE.write_text(CLUSTER_MARKER + "\n", encoding="utf-8")
    os.chmod(MARKER_FILE, 0o600)


def cluster_exists() -> bool:
    return (DATA_DIR / "PG_VERSION").is_file()


def assert_marked_cluster_before_use() -> None:
    if not MARKER_FILE.is_file() or MARKER_FILE.read_text(encoding="utf-8").strip() != CLUSTER_MARKER:
        raise RuntimeError("LOCAL_CLUSTER_MARKER_MISSING_OR_MISMATCH")
    if not cluster_exists():
        raise RuntimeError("LOCAL_CLUSTER_DATA_MISSING")


def init_cluster_if_needed() -> None:
    ensure_private_dirs()
    if cluster_exists():
        assert_marked_cluster_before_use()
        return
    # Refuse to initialize over unrelated files under the requested private
    # location.  This avoids ever taking ownership of an unknown cluster.
    unexpected = [p for p in LOCAL_ROOT.iterdir() if p.name not in {"socket"}]
    if unexpected:
        raise RuntimeError("LOCAL_CLUSTER_PATH_NOT_EMPTY")
    initdb = str(PG_BIN / "initdb")
    run_quiet([initdb, "-D", str(DATA_DIR), "-U", DB_USER, "--auth=trust", "--no-locale", "--encoding=UTF8"], stage="initdb")
    config = DATA_DIR / "postgresql.conf"
    with config.open("a", encoding="utf-8") as stream:
        stream.write(
            "\n# Vê na Memória isolated QA harness; not an application service.\n"
            "listen_addresses = ''\n"
            f"port = {PORT}\n"
            f"unix_socket_directories = '{SOCKET_DIR}'\n"
            "unix_socket_permissions = 0700\n"
        )
    write_cluster_marker()


def server_running() -> bool:
    result = subprocess.run(
        [str(PG_BIN / "pg_ctl"), "-D", str(DATA_DIR), "status"],
        cwd=ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    return result.returncode == 0


def start_cluster() -> None:
    assert_marked_cluster_before_use()
    if not server_running():
        pg_ctl(
            "-D",
            str(DATA_DIR),
            "-l",
            str(LOCAL_ROOT / "postgres.log"),
            "-o",
            f"-c config_file={DATA_DIR / 'postgresql.conf'}",
            "-w",
            "start",
            stage="pg_ctl_start",
        )


def stop_cluster() -> None:
    if cluster_exists() and server_running():
        pg_ctl("-D", str(DATA_DIR), "-w", "stop", stage="pg_ctl_stop")


def connect(dbname: str = DB_NAME) -> psycopg.Connection:
    # A Unix-domain socket path is intentional.  No host from the environment
    # is read here, and listen_addresses is checked again before fixtures.
    return psycopg.connect(
        dbname=dbname,
        user=DB_USER,
        host=str(SOCKET_DIR),
        port=PORT,
        connect_timeout=10,
        prepare_threshold=None,
    )


def connect_admin(dbname: str = "postgres") -> psycopg.Connection:
    return connect(dbname)


def database_exists(conn: psycopg.Connection) -> bool:
    return bool(conn.execute("SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = %s)", (DB_NAME,)).fetchone()[0])


def marker_is_valid(conn: psycopg.Connection) -> bool:
    if not database_exists(conn):
        return False
    try:
        row = conn.execute(
            """
            SELECT marker, cluster_dir, socket_dir, database_name, port
            FROM public.qa_vm_test_cluster_marker
            WHERE marker = %s
            """,
            (CLUSTER_MARKER,),
        ).fetchone()
    except psycopg.Error:
        return False
    return bool(row and row[1] == str(LOCAL_ROOT) and row[2] == str(SOCKET_DIR) and row[3] == DB_NAME and row[4] == PORT)


def drop_and_create_marked_database() -> None:
    with connect_admin("postgres") as conn:
        conn.autocommit = True
        exists = database_exists(conn)
        if exists:
            with connect_admin(DB_NAME) as current:
                current.autocommit = True
                if not marker_is_valid(current):
                    raise RuntimeError("REFUSE_RESET_UNMARKED_DATABASE")
            conn.execute(sql.SQL("DROP DATABASE {} WITH (FORCE)").format(sql.Identifier(DB_NAME)))
        conn.execute(sql.SQL("CREATE DATABASE {} OWNER {}").format(sql.Identifier(DB_NAME), sql.Identifier(DB_USER)))
    with connect_admin(DB_NAME) as conn:
        conn.autocommit = True
        conn.execute(
            """
            CREATE TABLE public.qa_vm_test_cluster_marker (
              marker text PRIMARY KEY,
              cluster_dir text NOT NULL,
              socket_dir text NOT NULL,
              database_name text NOT NULL,
              port integer NOT NULL,
              created_at timestamptz NOT NULL DEFAULT clock_timestamp()
            )
            """
        )
        conn.execute(
            """
            INSERT INTO public.qa_vm_test_cluster_marker
              (marker, cluster_dir, socket_dir, database_name, port)
            VALUES (%s, %s, %s, %s, %s)
            """,
            (CLUSTER_MARKER, str(LOCAL_ROOT), str(SOCKET_DIR), DB_NAME, PORT),
        )
        conn.execute("REVOKE ALL ON TABLE public.qa_vm_test_cluster_marker FROM PUBLIC")


def read_remote_auth_helpers() -> dict[str, str]:
    """Fetch only auth helper definitions in a read-only remote transaction."""
    # Import exactly the parameter parser used by apply_foundation.py.  This
    # connection is not used for the local database and cannot seed fixtures.
    from scripts.supabase_connection import api_base, database_parameters

    config = json.loads((ROOT / "supabase" / "project.json").read_text(encoding="utf-8"))
    if api_base().split("//", 1)[1].split(".", 1)[0] != config["projectRef"]:
        raise RuntimeError("PROJECT_MISMATCH")
    parameters = database_parameters(strip_password_delimiters=True)
    parameters.update(
        host=config["poolerHost"],
        port=config["poolerPort"],
        user="postgres." + config["projectRef"],
        prepare_threshold=None,
    )
    result: dict[str, str] = {}
    with psycopg.connect(**parameters, autocommit=False) as conn:
        conn.execute("SET TRANSACTION READ ONLY")
        for name in ("uid", "role", "jwt"):
            row = conn.execute(
                """
                SELECT pg_get_functiondef(p.oid)
                FROM pg_proc AS p
                JOIN pg_namespace AS n ON n.oid = p.pronamespace
                WHERE n.nspname = 'auth'
                  AND p.proname = %s
                  AND pg_get_function_identity_arguments(p.oid) = ''
                ORDER BY p.oid
                LIMIT 1
                """,
                (name,),
            ).fetchone()
            if not row:
                raise RuntimeError("AUTH_HELPER_NOT_FOUND_" + name)
            result[name] = row[0]
        conn.rollback()
    return result


def ensure_auth_helper_cache() -> str:
    if HELPERS_FILE.is_file():
        cached = HELPERS_FILE.read_text(encoding="utf-8")
        if (
            all(f"CREATE OR REPLACE FUNCTION auth.{name}()" in cached for name in ("uid", "role", "jwt"))
            and cached.count("$function$;") == 3
        ):
            return cached
    helpers = read_remote_auth_helpers()
    rendered = "\n".join(
        ["-- Copied by a read-only helper-definition query; not a fixture or Supabase dump.", "CREATE SCHEMA auth;"]
        + [helpers[name].rstrip() + ";" for name in ("uid", "role", "jwt")]
    ) + "\n"
    HELPERS_FILE.write_text(rendered, encoding="utf-8")
    os.chmod(HELPERS_FILE, 0o600)
    return rendered


def bootstrap_roles_auth_and_users() -> None:
    helper_sql = ensure_auth_helper_cache()
    with connect(DB_NAME) as conn:
        conn.autocommit = True
        # Cluster roles are local test identities, not application users.
        for role in ("anon", "authenticated"):
            row = conn.execute("SELECT rolsuper FROM pg_roles WHERE rolname = %s", (role,)).fetchone()
            if row is not None:
                if row[0]:
                    raise RuntimeError("TEST_ROLE_MUST_NOT_BE_SUPERUSER")
                conn.execute(sql.SQL("ALTER ROLE {} NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOLOGIN").format(sql.Identifier(role)))
            else:
                conn.execute(sql.SQL("CREATE ROLE {} NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOLOGIN").format(sql.Identifier(role)))
        conn.execute("CREATE EXTENSION IF NOT EXISTS pgcrypto")
        conn.execute(helper_sql, prepare=False)
        conn.execute("CREATE TABLE auth.users (id uuid PRIMARY KEY)")
        conn.execute("REVOKE ALL ON SCHEMA auth FROM PUBLIC")
        conn.execute("GRANT USAGE ON SCHEMA auth TO anon, authenticated")
        conn.execute("REVOKE ALL ON TABLE auth.users FROM PUBLIC, anon, authenticated")
        conn.execute("GRANT EXECUTE ON FUNCTION auth.uid(), auth.role(), auth.jwt() TO anon, authenticated")
        conn.execute("INSERT INTO auth.users (id) VALUES (%s), (%s)", (AUTH_USER_A, AUTH_USER_B))
        count = conn.execute("SELECT count(*) FROM auth.users").fetchone()[0]
        if count != 2:
            raise RuntimeError("LOCAL_AUTH_FIXTURE_COUNT")


def bootstrap_storage_contract() -> None:
    """Create an isolated Storage-shaped contract for policy/RPC tests.

    This is not a success stub and is never used by the application: it is a
    local relational stand-in for the real Supabase Storage tables so Products
    can test object existence, metadata checks, private RLS and path policies
    without uploading to a production bucket.
    """
    with connect(DB_NAME) as conn:
        conn.autocommit = True
        conn.execute("CREATE SCHEMA storage")
        conn.execute(
            """
            CREATE TABLE storage.buckets (
              id text PRIMARY KEY,
              name text NOT NULL,
              owner_id uuid,
              created_at timestamptz NOT NULL DEFAULT now(),
              updated_at timestamptz NOT NULL DEFAULT now(),
              public boolean NOT NULL DEFAULT false,
              file_size_limit bigint,
              allowed_mime_types text[]
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE storage.objects (
              id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
              bucket_id text NOT NULL REFERENCES storage.buckets(id) ON DELETE CASCADE,
              name text NOT NULL,
              owner_id uuid,
              created_at timestamptz NOT NULL DEFAULT now(),
              updated_at timestamptz NOT NULL DEFAULT now(),
              last_accessed_at timestamptz,
              metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
              user_metadata jsonb,
              UNIQUE (bucket_id, name)
            )
            """
        )
        conn.execute("ALTER TABLE storage.buckets ENABLE ROW LEVEL SECURITY")
        conn.execute("ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY")
        conn.execute("REVOKE ALL ON SCHEMA storage FROM PUBLIC")
        conn.execute("GRANT USAGE ON SCHEMA storage TO anon, authenticated")
        conn.execute("REVOKE ALL ON TABLE storage.buckets, storage.objects FROM PUBLIC, anon, authenticated")
        conn.execute("GRANT SELECT ON TABLE storage.buckets TO authenticated")
        conn.execute(
            """
            CREATE POLICY qa_storage_bucket_metadata_select
            ON storage.buckets FOR SELECT TO authenticated
            USING (id = 'vm-product-media')
            """
        )


def preflight_local_database() -> None:
    with connect(DB_NAME) as conn:
        conn.autocommit = True
        row = conn.execute(
            """
            SELECT current_database(), inet_server_addr() IS NULL,
                   current_setting('port')::integer,
                   current_setting('listen_addresses'),
                   current_setting('unix_socket_directories'),
                   EXISTS (
                     SELECT 1 FROM public.qa_vm_test_cluster_marker
                     WHERE marker = %s AND cluster_dir = %s AND socket_dir = %s
                       AND database_name = %s AND port = %s
                   )
            """,
            (CLUSTER_MARKER, str(LOCAL_ROOT), str(SOCKET_DIR), DB_NAME, PORT),
        ).fetchone()
        if row != (DB_NAME, True, PORT, "", str(SOCKET_DIR), True):
            raise RuntimeError("LOCAL_DATABASE_PREFLIGHT_FAILED")
        roles = conn.execute(
            "SELECT rolname, rolsuper FROM pg_roles WHERE rolname IN ('anon','authenticated') ORDER BY rolname"
        ).fetchall()
        if roles != [("anon", False), ("authenticated", False)]:
            raise RuntimeError("TEST_ROLES_PREFLIGHT_FAILED")


def selected_migrations(suite: str) -> list[Path]:
    paths = sorted(MIGRATION_DIR.glob("*.sql"))
    if suite == "foundation":
        if FOUNDATION not in paths:
            raise RuntimeError("FOUNDATION_MIGRATION_MISSING")
        # The inventory suite is intentionally deferred until its SQL suite is
        # supplied by the parent; this avoids claiming the legacy adjustment is
        # idempotent before the inventory correction is under test.
        return [FOUNDATION]
    if suite == "inventory":
        if "20261029221500_inventory.sql" not in [p.name for p in paths]:
            raise RuntimeError("INVENTORY_MIGRATION_MISSING")
        return [path for path in paths if path.name <= "20261029221500_inventory.sql"]
    if suite == "products":
        if PRODUCTS_MIGRATION not in paths:
            raise RuntimeError("PRODUCTS_MIGRATION_MISSING")
        return [path for path in paths if path.name <= PRODUCTS_MIGRATION.name]
    if suite == "contacts":
        if CONTACTS_MIGRATION not in paths:
            raise RuntimeError("CONTACTS_MIGRATION_MISSING")
        return [path for path in paths if path.name <= CONTACTS_MIGRATION.name]
    raise RuntimeError("UNKNOWN_SUITE")


def apply_migrations(paths: Iterable[Path]) -> list[str]:
    applied: list[str] = []
    with connect(DB_NAME) as conn:
        conn.autocommit = True
        for path in paths:
            source = path.read_text(encoding="utf-8")
            if not source.lstrip().startswith("BEGIN;") or not source.strip().endswith("COMMIT;"):
                raise RuntimeError("MIGRATION_TRANSACTION_REQUIRED")
            conn.execute(source, prepare=False)
            version = path.stem
            if not conn.execute("SELECT EXISTS (SELECT 1 FROM public.vm_schema_migrations WHERE version = %s)", (version,)).fetchone()[0]:
                raise RuntimeError("MIGRATION_REGISTRY_MISSING")
            applied.append(version)
    return applied


def run_sql_suite(test_path: Path) -> list[str]:
    if not test_path.is_file():
        raise RuntimeError("SUITE_SQL_MISSING")
    source = test_path.read_text(encoding="utf-8")
    if "assert_true" not in source or "assert_raises" not in source:
        raise RuntimeError("ASSERTION_HELPERS_MISSING")
    with connect(DB_NAME) as conn:
        conn.autocommit = False
        conn.execute("BEGIN")
        try:
            conn.execute(source, prepare=False)
            labels = [row[0] for row in conn.execute("SELECT label FROM pg_temp.qa_test_results ORDER BY ordinal").fetchall()]
            if not labels:
                raise RuntimeError("NO_TEST_ASSERTIONS")
            conn.commit()
            return labels
        except Exception:
            conn.rollback()
            raise


def print_success(suite: str, migrations: list[str], labels: list[str]) -> None:
    status = {
        "status": "passed",
        "suite": suite,
        "migrations": migrations,
        "tests_passed": len(labels),
        "tests": labels,
        "database": DB_NAME,
        "socket": str(SOCKET_DIR),
        "port": PORT,
        "listen_addresses": "",
        "cluster": str(LOCAL_ROOT),
        "pg_ctl": "running",
    }
    print(json.dumps(status, ensure_ascii=False))


def main() -> int:
    parser = argparse.ArgumentParser(description="Execute isolated PostgreSQL QA suites")
    parser.add_argument("--suite", choices=("foundation", "inventory", "products", "contacts"), default="foundation")
    parser.add_argument("--stop", action="store_true", help="stop only this marked local cluster after the run")
    args = parser.parse_args()
    try:
        require_paths()
        init_cluster_if_needed()
        start_cluster()
        # Never reset before proving that an existing database belongs to this
        # marked cluster.  A default package cluster is never used as a fixture.
        drop_and_create_marked_database()
        bootstrap_roles_auth_and_users()
        if args.suite in ("products", "contacts"):
            bootstrap_storage_contract()
        preflight_local_database()
        if args.suite == "inventory" and not INVENTORY_TEST.is_file():
            raise RuntimeError("INVENTORY_SUITE_SQL_MISSING")
        if args.suite == "products" and not PRODUCTS_TEST.is_file():
            raise RuntimeError("PRODUCTS_SUITE_SQL_MISSING")
        if args.suite == "contacts" and not CONTACTS_TEST.is_file():
            raise RuntimeError("CONTACTS_SUITE_SQL_MISSING")
        migrations = apply_migrations(selected_migrations(args.suite))
        test_path = (
            FOUNDATION_TEST if args.suite == "foundation"
            else INVENTORY_TEST if args.suite == "inventory"
            else PRODUCTS_TEST if args.suite == "products"
            else CONTACTS_TEST
        )
        labels = run_sql_suite(test_path)
        print_success(args.suite, migrations, labels)
        if args.stop:
            stop_cluster()
        return 0
    except SystemExit:
        raise
    except Exception as exc:
        if args.stop:
            try:
                stop_cluster()
            except Exception:
                pass
        fail("run", exc)


if __name__ == "__main__":
    sys.exit(main())
