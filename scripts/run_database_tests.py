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
from concurrent.futures import ThreadPoolExecutor
import json
import os
from queue import Queue
import subprocess
import sys
from threading import Barrier
from time import monotonic, sleep
from pathlib import Path
from typing import Iterable

import psycopg
from psycopg import sql

ROOT = Path(__file__).resolve().parents[1]
# The harness uses initdb/pg_ctl directly; psql is not required. Allow an
# explicit local installation without changing the isolated socket/cluster.
PG_BIN = Path(os.environ.get("VM_TEST_POSTGRES_BIN", "/usr/lib/postgresql/16/bin"))
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
ORDERS_TEST = ROOT / "tests" / "database" / "orders.sql"
ORDERS_MIGRATION = ROOT / "supabase" / "migrations" / "20261030002000_orders.sql"
ORDER_RETURNS_TEST = ROOT / "tests" / "database" / "order_returns.sql"
ORDER_RETURNS_MIGRATION = ROOT / "supabase" / "migrations" / "20261030002200_order_returns.sql"
PUBLIC_SALES_TEST = ROOT / "tests" / "database" / "public_sales.sql"
PUBLIC_SALES_MIGRATION = ROOT / "supabase" / "migrations" / "20261030003000_public_sales.sql"
QUOTE_ADMIN_LIST_MIGRATION = ROOT / "supabase" / "migrations" / "20261030004000_tracking_minimal_acl.sql"
FINANCE_TEST = ROOT / "tests" / "database" / "finance_summary.sql"
FINANCE_MIGRATION = ROOT / "supabase" / "migrations" / "20261030005000_finance_summary.sql"
REALTIME_CONTRACT = ROOT / "tests" / "database" / "realtime_contract.sql"

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
    for path in (PG_BIN / "initdb", PG_BIN / "pg_ctl"):
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
        for role in ("anon", "authenticated", "service_role"):
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
        conn.execute("GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role")
        conn.execute("REVOKE ALL ON TABLE auth.users FROM PUBLIC, anon, authenticated")
        conn.execute("GRANT EXECUTE ON FUNCTION auth.uid(), auth.role(), auth.jwt() TO anon, authenticated, service_role")
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


def bootstrap_realtime_contract() -> None:
    """Install only the verified local Realtime message contract for public_sales.

    This is a local relational contract: it records native ``realtime.send``
    calls as rows and never represents WebSocket delivery or production state.
    The call is guarded by the marked isolated cluster preflight in ``main``.
    """
    if not REALTIME_CONTRACT.is_file():
        raise RuntimeError("REALTIME_CONTRACT_MISSING")
    source = REALTIME_CONTRACT.read_text(encoding="utf-8")
    if "CREATE OR REPLACE FUNCTION realtime.send" not in source or "CREATE TABLE realtime.messages" not in source:
        raise RuntimeError("REALTIME_CONTRACT_UNVERIFIED")
    with connect(DB_NAME) as conn:
        conn.autocommit = True
        conn.execute(source, prepare=False)


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
    if suite == "orders":
        if ORDERS_MIGRATION not in paths:
            raise RuntimeError("ORDERS_MIGRATION_MISSING")
        return [path for path in paths if path.name <= ORDERS_MIGRATION.name]
    if suite == "order_returns":
        if ORDER_RETURNS_MIGRATION not in paths:
            raise RuntimeError("ORDER_RETURNS_MIGRATION_MISSING")
        return [path for path in paths if path.name <= ORDER_RETURNS_MIGRATION.name]
    if suite == "public_sales":
        if PUBLIC_SALES_MIGRATION not in paths:
            raise RuntimeError("PUBLIC_SALES_MIGRATION_MISSING")
        if QUOTE_ADMIN_LIST_MIGRATION not in paths:
            raise RuntimeError("QUOTE_ADMIN_LIST_MIGRATION_MISSING")
        return [path for path in paths if path.name <= QUOTE_ADMIN_LIST_MIGRATION.name]
    if suite in ("finance_summary", "migration_history"):
        if FINANCE_MIGRATION not in paths:
            raise RuntimeError("FINANCE_MIGRATION_MISSING")
        return [path for path in paths if path.name <= FINANCE_MIGRATION.name]
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


def run_foundation_history_probe() -> list[str]:
    """Bootstrap the real foundation against an empty marked local database."""
    from migration_history import apply_initial_migration, verify_history

    with connect(DB_NAME) as conn:
        conn.autocommit = True
        conn.execute("CREATE SCHEMA supabase_migrations")
        conn.execute("CREATE TABLE supabase_migrations.schema_migrations(version text PRIMARY KEY)")
        conn.execute("INSERT INTO supabase_migrations.schema_migrations VALUES('20260101000000')")
        try:
            apply_initial_migration(conn, FOUNDATION)
        except ValueError as exc:
            if str(exc) != "OFFICIAL_HISTORY_NOT_EMPTY":
                raise
        else:
            raise RuntimeError("NONEMPTY_OFFICIAL_HISTORY_NOT_REJECTED")
        if conn.execute("SELECT to_regclass('public.vm_schema_migrations') IS NOT NULL").fetchone()[0]:
            raise RuntimeError("INITIAL_MIGRATION_DID_NOT_ROLL_BACK")
        conn.execute("DELETE FROM supabase_migrations.schema_migrations")
        apply_initial_migration(conn, FOUNDATION)
        verify_history(conn)
        row = conn.execute("SELECT version, name, statements IS NOT NULL FROM supabase_migrations.schema_migrations").fetchone()
        if row != ("20261029203500", "foundation", True):
            raise RuntimeError("FOUNDATION_HISTORY_INCORRECT")
    return ["foundation refuses unrelated official history and rolls back", "foundation commits schema and both migration ledgers atomically"]


def run_migration_history_probe() -> list[str]:
    """Exercise history repair and atomic dual-ledger writes only locally."""
    from migration_history import apply_migration, verify_history

    source = (ROOT / "scripts" / "reconcile_migration_history.sql").read_text(encoding="utf-8")
    labels: list[str] = []
    with connect(DB_NAME) as conn:
        conn.autocommit = True
        conn.execute(source, prepare=False)
        verify_history(conn)
        rows = conn.execute("SELECT version, name, statements FROM supabase_migrations.schema_migrations ORDER BY version").fetchall()
        if len(rows) != 10 or any(not name or statements is not None for _, name, statements in rows):
            raise RuntimeError("HISTORY_REPAIR_CONTENT_INCORRECT")
        if conn.execute("SELECT has_schema_privilege('anon','supabase_migrations','USAGE') OR has_schema_privilege('authenticated','supabase_migrations','USAGE')").fetchone()[0]:
            raise RuntimeError("HISTORY_SCHEMA_PUBLICLY_EXPOSED")
        labels.append("history-only repair records ten reviewed versions without exposing the ledger")
        conn.execute(source, prepare=False)
        if conn.execute("SELECT count(*) FROM supabase_migrations.schema_migrations").fetchone()[0] != 10:
            raise RuntimeError("HISTORY_REPAIR_NOT_IDEMPOTENT")
        labels.append("history repair is idempotent")

        # Prove that a divergent history cannot be silently accepted.
        conn.execute("DELETE FROM supabase_migrations.schema_migrations WHERE version='20261029203500'")
        try:
            verify_history(conn)
        except ValueError as exc:
            if str(exc) != "MIGRATION_HISTORIES_DIVERGE":
                raise
        else:
            raise RuntimeError("DIVERGENT_HISTORY_NOT_REJECTED")
        try:
            conn.execute(source, prepare=False)
        except psycopg.Error:
            conn.execute("ROLLBACK")
        else:
            raise RuntimeError("PARTIAL_HISTORY_REPAIR_NOT_REJECTED")
        conn.execute("INSERT INTO supabase_migrations.schema_migrations(version,name) VALUES('20261029203500','foundation')")
        verify_history(conn)
        labels.append("partial or conflicting histories fail closed")

        success = LOCAL_ROOT / "20261030005900_qa_history.sql"
        success.write_text("BEGIN;\nCREATE TABLE public.qa_history_write(id integer);\nINSERT INTO public.vm_schema_migrations(version,description) VALUES('20261030005900_qa_history','isolated QA');\nCOMMIT;\n", encoding="utf-8")
        if not apply_migration(conn, success) or apply_migration(conn, success):
            raise RuntimeError("DUAL_HISTORY_APPLY_NOT_IDEMPOTENT")
        statements = conn.execute("SELECT statements FROM supabase_migrations.schema_migrations WHERE version='20261030005900'").fetchone()[0]
        if not statements or not any("CREATE TABLE public.qa_history_write" in part for part in statements):
            raise RuntimeError("DUAL_HISTORY_SOURCE_MISSING")
        verify_history(conn)
        labels.append("new migration commits its SQL and both ledger entries together")

        failure = LOCAL_ROOT / "20261030006000_qa_rollback.sql"
        failure.write_text("BEGIN;\nCREATE TABLE public.qa_history_rollback(id integer);\nCOMMIT;\n", encoding="utf-8")
        try:
            apply_migration(conn, failure)
        except ValueError as exc:
            if str(exc) != "MIGRATION_REGISTRY_MISSING":
                raise
        else:
            raise RuntimeError("MISSING_CUSTOM_HISTORY_NOT_REJECTED")
        if conn.execute("SELECT to_regclass('public.qa_history_rollback') IS NOT NULL").fetchone()[0]:
            raise RuntimeError("MIGRATION_DDL_NOT_ROLLED_BACK")
        verify_history(conn)
        labels.append("failure rolls back schema and both histories atomically")
    return labels


def run_sql_suite(test_path: Path, extra_path: Path | None = None) -> list[str]:
    if not test_path.is_file() or (extra_path is not None and not extra_path.is_file()):
        raise RuntimeError("SUITE_SQL_MISSING")
    source = test_path.read_text(encoding="utf-8")
    if extra_path is not None:
        source += "\n" + extra_path.read_text(encoding="utf-8")
    if "assert_true" not in source or "assert_raises" not in source:
        raise RuntimeError("ASSERTION_HELPERS_MISSING")
    with connect(DB_NAME) as conn:
        conn.autocommit = False
        conn.execute("BEGIN")
        try:
            conn.execute(source, prepare=False)
            # Suites may deliberately finish while simulating an authenticated
            # or anonymous request. Restore the local harness identity before
            # reading its private assertion ledger.
            conn.execute("RESET ROLE")
            labels = [row[0] for row in conn.execute("SELECT label FROM pg_temp.qa_test_results ORDER BY ordinal").fetchall()]
            if not labels:
                raise RuntimeError("NO_TEST_ASSERTIONS")
            conn.commit()
            return labels
        except Exception:
            conn.rollback()
            raise


def run_orders_concurrency_probe() -> list[str]:
    """Exercise one status transition through two real local psycopg sessions.

    The SQL suite creates the named pending order and commits it before this
    probe. Both sessions use the local Unix socket, the real authenticated role,
    and the same Auth GUC contract; this is deliberately not an app mock.
    """
    with connect(DB_NAME) as conn:
        conn.autocommit = False
        conn.execute("SET ROLE authenticated")
        conn.execute("SELECT set_config('request.jwt.claim.sub', %s, false)", (AUTH_USER_A,))
        conn.execute("SELECT set_config('request.jwt.claim.role', 'authenticated', false)")
        conn.execute(
            "SELECT set_config('request.jwt.claims', %s, false)",
            (json.dumps({"sub": AUTH_USER_A, "role": "authenticated"}),),
        )
        target = conn.execute(
            """
            SELECT organization_id, id
            FROM public.vm_orders_read
            WHERE title = 'QA concurrency order'
            ORDER BY id
            LIMIT 1
            """
        ).fetchone()
        conn.rollback()
    if target is None:
        raise RuntimeError("ORDERS_CONCURRENCY_FIXTURE_MISSING")

    organization_id, order_id = target
    barrier = Barrier(2)
    keys = (
        "40000000-0000-0000-0000-000000000201",
        "40000000-0000-0000-0000-000000000202",
    )

    def attempt(key: str):
        with connect(DB_NAME) as conn:
            try:
                conn.execute("SET ROLE authenticated")
                conn.execute("SELECT set_config('request.jwt.claim.sub', %s, false)", (AUTH_USER_A,))
                conn.execute("SELECT set_config('request.jwt.claim.role', 'authenticated', false)")
                conn.execute(
                    "SELECT set_config('request.jwt.claims', %s, false)",
                    (json.dumps({"sub": AUTH_USER_A, "role": "authenticated"}),),
                )
                barrier.wait(timeout=10)
                result = conn.execute(
                    """
                    SELECT status, status_version, changed
                    FROM public.vm_set_order_status(%s, %s, 'Em Produção', NULL, %s)
                    """,
                    (organization_id, order_id, key),
                ).fetchone()
                conn.commit()
                return result
            except BaseException:
                conn.rollback()
                raise

    with ThreadPoolExecutor(max_workers=2, thread_name_prefix="orders-qa") as pool:
        results = list(pool.map(attempt, keys))
    if sorted(bool(result[2]) for result in results) != [False, True]:
        raise RuntimeError("ORDERS_CONCURRENCY_EXPECTED_ONE_CHANGE_ONE_NOOP")
    if any(result[0] != "Em Produção" or result[1] != "2" for result in results):
        raise RuntimeError("ORDERS_CONCURRENCY_STATUS_VERSION_MISMATCH")

    with connect(DB_NAME) as conn:
        counts = conn.execute(
            """
            SELECT
              (SELECT count(*) FROM public.vm_order_events WHERE organization_id = %s AND order_id = %s),
              (SELECT count(*) FROM public.vm_order_consumptions WHERE organization_id = %s AND order_id = %s)
            """,
            (organization_id, order_id, organization_id, order_id),
        ).fetchone()
    if counts != (2, 1):
        raise RuntimeError("ORDERS_CONCURRENCY_DUPLICATE_EVENT_OR_DEDUCTION")
    return ["real two-connection status serialization"]


def run_public_sales_concurrency_probe() -> list[str]:
    """Race two anonymous local sessions against the committed QA quote."""
    # Refuse to use a similarly named quote unless the exact marked local DB,
    # private Unix socket, and non-network server preflight all still match.
    with connect(DB_NAME) as conn:
        conn.autocommit = False
        try:
            if not marker_is_valid(conn):
                raise RuntimeError("PUBLIC_SALES_RACE_DATABASE_NOT_MARKED")
            environment = conn.execute(
                "SELECT current_database(), inet_server_addr() IS NULL, "
                "current_setting('port')::integer, current_setting('listen_addresses'), "
                "current_setting('unix_socket_directories')"
            ).fetchone()
            if environment != (DB_NAME, True, PORT, "", str(SOCKET_DIR)):
                raise RuntimeError("PUBLIC_SALES_RACE_LOCAL_SOCKET_PREFLIGHT_FAILED")
            target = conn.execute(
                """
                SELECT q.id, q.public_token
                FROM public.vm_quotes q
                WHERE q.title = 'QA race quote' AND q.status = 'Sent'
                ORDER BY q.created_at DESC, q.id
                LIMIT 2
                """
            ).fetchall()
            if len(target) != 1:
                raise RuntimeError("PUBLIC_SALES_RACE_FIXTURE_MISSING_OR_AMBIGUOUS")
            quote_id, token = target[0]
            conn.rollback()
        except BaseException:
            conn.rollback()
            raise

    barrier = Barrier(2)

    def approve(_: int):
        with connect(DB_NAME) as conn:
            try:
                conn.execute("SET ROLE anon")
                conn.execute("SELECT set_config('request.jwt.claim.role', 'anon', false)")
                barrier.wait(timeout=10)
                result = conn.execute(
                    "SELECT order_id, tracking_token FROM public.vm_approve_quote(%s)",
                    (token,),
                ).fetchone()
                if result is None:
                    raise RuntimeError("PUBLIC_SALES_RACE_EMPTY_RESULT")
                conn.commit()
                return result
            except BaseException:
                conn.rollback()
                raise

    with ThreadPoolExecutor(max_workers=2, thread_name_prefix="public-sales-qa") as pool:
        results = list(pool.map(approve, (1, 2)))
    if results[0] != results[1] or results[0][0] is None or results[0][1] is None:
        raise RuntimeError("PUBLIC_SALES_RACE_RESULT_MISMATCH")
    order_id, tracking_token = results[0]

    with connect(DB_NAME) as conn:
        state = conn.execute(
            """
            SELECT
              (SELECT count(*) FROM vm_private.vm_quote_acceptances WHERE quote_id = %s),
              (SELECT count(*) FROM vm_private.vm_quote_acceptances WHERE quote_id = %s AND order_id = %s),
              (SELECT count(*) FROM public.vm_quotes WHERE id = %s AND status = 'Approved' AND accepted_order_id = %s),
              (SELECT count(*) FROM public.vm_tracking_capabilities WHERE token = %s AND order_id = %s AND revoked_at IS NULL),
              (SELECT count(*) FROM public.vm_order_events WHERE order_id = %s),
              (SELECT count(*) FROM public.vm_orders WHERE id = %s AND status = 'Pendente' AND consumed_at IS NULL),
              (SELECT count(*) FROM public.vm_order_consumptions WHERE order_id = %s),
              (SELECT count(*) FROM public.vm_notifications n JOIN public.vm_order_events e ON e.id = n.event_id WHERE e.order_id = %s),
              (SELECT count(*) FROM public.vm_memberships m JOIN public.vm_quotes q ON q.organization_id = m.organization_id WHERE q.id = %s)
            """,
            (quote_id, quote_id, order_id, quote_id, order_id,
             tracking_token, order_id, order_id, order_id, order_id, order_id, quote_id),
        ).fetchone()
    acceptance_count, linked_count, approved_count, tracking_count, event_count, pending_count, consumption_count, notification_count, membership_count = state
    if (acceptance_count, linked_count, approved_count, tracking_count, event_count,
        pending_count, consumption_count) != (1, 1, 1, 1, 1, 1, 0):
        raise RuntimeError("PUBLIC_SALES_RACE_DUPLICATE_OR_UNEXPECTED_SIDE_EFFECT")
    if notification_count != membership_count:
        raise RuntimeError("PUBLIC_SALES_RACE_NOTIFICATION_COUNT_MISMATCH")
    return ["real two-connection anonymous quote-approval race; one order, acceptance, initial event and notification set; no material deduction"]


def run_capability_revocation_races() -> list[str]:
    """Verify real lock serialization, exclusively in the marked local DB."""
    preflight_local_database()
    with connect(DB_NAME) as conn:
        if not marker_is_valid(conn):
            raise RuntimeError("CAPABILITY_RACE_DATABASE_NOT_MARKED")
        rows = conn.execute(
            """SELECT q.title,q.organization_id,q.id,q.public_token,a.order_id,t.token,t.id
               FROM public.vm_quotes q
               LEFT JOIN vm_private.vm_quote_acceptances a ON a.organization_id=q.organization_id AND a.quote_id=q.id
               LEFT JOIN public.vm_tracking_capabilities t ON t.organization_id=a.organization_id AND t.id=a.tracking_id
               WHERE q.title IN ('QA capability race_revoke','QA capability race_read','QA capability race_track',
                                 'QA capability race_track_reverse','QA capability race_expiry')"""
        ).fetchall()
        targets = {row[0]: row[1:] for row in rows}
        if len(targets) != 5:
            raise RuntimeError("CAPABILITY_RACE_FIXTURES_MISSING")

    def admin(conn):
        conn.execute("SET ROLE authenticated")
        conn.execute("SELECT set_config('request.jwt.claim.sub', %s, false)", (AUTH_USER_A,))
        conn.execute("SELECT set_config('request.jwt.claim.role', 'authenticated', false)")
        conn.execute("SELECT set_config('request.jwt.claims', %s, false)",
                     (json.dumps({"sub": AUTH_USER_A, "role": "authenticated"}),))

    def anon(conn):
        conn.execute("SET ROLE anon")
        conn.execute("SELECT set_config('request.jwt.claim.role', 'anon', false)")

    def wait_blocked(pid: int):
        deadline = monotonic() + 8
        with connect(DB_NAME) as monitor:
            monitor.autocommit = True
            while monotonic() < deadline:
                blocked = monitor.execute(
                    "SELECT wait_event_type='Lock' AND cardinality(pg_blocking_pids(pid))>0 "
                    "FROM pg_stat_activity WHERE pid=%s", (pid,),
                ).fetchone()
                if blocked and blocked[0]:
                    return
                sleep(0.025)
        raise RuntimeError("CAPABILITY_RACE_EXPECTED_ROW_LOCK_WAIT")

    def approve_after_lock(token, pids: Queue):
        with connect(DB_NAME) as conn:
            anon(conn)
            pids.put(conn.execute("SELECT pg_backend_pid()").fetchone()[0])
            try:
                result = conn.execute("SELECT order_id,tracking_token FROM public.vm_approve_quote(%s)", (token,)).fetchone()
                conn.commit()
                return result
            except psycopg.Error as exc:
                conn.rollback()
                return exc.sqlstate

    def read_after_lock(token, pids: Queue):
        with connect(DB_NAME) as conn:
            anon(conn)
            pids.put(conn.execute("SELECT pg_backend_pid()").fetchone()[0])
            result = conn.execute("SELECT public.vm_get_quote(%s)", (token,)).fetchone()[0]
            conn.commit()
            return result

    def revoke_after_lock(org, tracking_token, pids: Queue):
        with connect(DB_NAME) as conn:
            admin(conn)
            pids.put(conn.execute("SELECT pg_backend_pid()").fetchone()[0])
            result = conn.execute("SELECT tracking_id FROM public.vm_revoke_tracking(%s,%s,gen_random_uuid())",
                                  (org,tracking_token)).fetchone()
            conn.commit()
            return result

    labels = []
    # The transaction that owns the quote lock revokes first; an approval
    # already waiting for it must observe the committed revocation.
    org, quote_id, token, _, _, _ = targets['QA capability race_revoke']
    with connect(DB_NAME) as writer, ThreadPoolExecutor(max_workers=1) as pool:
        admin(writer)
        writer.execute("SELECT * FROM public.vm_revoke_quote(%s,%s,'teste local',gen_random_uuid())", (org,quote_id))
        pids = Queue()
        future = pool.submit(approve_after_lock, token, pids)
        wait_blocked(pids.get(timeout=5))
        writer.commit()
        if future.result(timeout=10) != '22023':
            raise RuntimeError("QUOTE_REVOKE_RACE_DISCLOSED_OR_ACCEPTED")
    with connect(DB_NAME) as conn:
        count = conn.execute("SELECT count(*) FROM vm_private.vm_quote_acceptances WHERE quote_id=%s", (quote_id,)).fetchone()[0]
        if count:
            raise RuntimeError("QUOTE_REVOKE_RACE_CREATED_ACCEPTANCE")
    labels.append("quote revocation commits before blocked anonymous approval; no order")

    # The public getter serializes against the same quote row; a reader
    # already queued behind an uncommitted revocation cannot receive snapshots.
    org, quote_id, token, _, _, _ = targets['QA capability race_read']
    with connect(DB_NAME) as writer, ThreadPoolExecutor(max_workers=1) as pool:
        admin(writer)
        writer.execute("SELECT * FROM public.vm_revoke_quote(%s,%s,'teste local',gen_random_uuid())", (org,quote_id))
        pids = Queue()
        future = pool.submit(read_after_lock, token, pids)
        wait_blocked(pids.get(timeout=5))
        writer.commit()
        if future.result(timeout=10) is not None:
            raise RuntimeError("QUOTE_REVOKE_RACE_READ_LEAKED_SNAPSHOT")
    labels.append("quote revocation commits before blocked public read; no snapshot leaked")

    # A revocation holding the original tracking row wins over a blocked replay.
    org, quote_id, token, order_id, tracking_token, _ = targets['QA capability race_track']
    with connect(DB_NAME) as writer, ThreadPoolExecutor(max_workers=1) as pool:
        admin(writer)
        writer.execute("SELECT * FROM public.vm_revoke_tracking(%s,%s,gen_random_uuid())", (org,tracking_token))
        pids = Queue()
        future = pool.submit(approve_after_lock, token, pids)
        wait_blocked(pids.get(timeout=5))
        writer.commit()
        if future.result(timeout=10) != '22023':
            raise RuntimeError("TRACKING_REVOKE_RACE_DISCLOSED_TOKEN")
    with connect(DB_NAME) as conn:
        count = conn.execute("SELECT count(*) FROM public.vm_tracking_capabilities WHERE order_id=%s", (order_id,)).fetchone()[0]
        if count != 1:
            raise RuntimeError("TRACKING_REVOKE_RACE_REISSUED")
    labels.append("tracking revocation wins over blocked replay without reissuing")

    # Conversely, replay's FOR SHARE makes the valid read linearize before a
    # concurrent revocation, which cannot commit until that read commits.
    org, quote_id, token, order_id, tracking_token, _ = targets['QA capability race_track_reverse']
    with connect(DB_NAME) as reader, ThreadPoolExecutor(max_workers=1) as pool:
        anon(reader)
        result = reader.execute("SELECT order_id,tracking_token FROM public.vm_approve_quote(%s)", (token,)).fetchone()
        if result != (order_id,tracking_token):
            raise RuntimeError("TRACKING_REPLAY_RACE_INITIAL_RESULT")
        pids = Queue()
        future = pool.submit(revoke_after_lock, org, tracking_token, pids)
        wait_blocked(pids.get(timeout=5))
        reader.commit()
        if not future.result(timeout=10):
            raise RuntimeError("TRACKING_REPLAY_RACE_REVOCATION_FAILED")
    with connect(DB_NAME) as conn:
        anon(conn)
        try:
            conn.execute("SELECT * FROM public.vm_approve_quote(%s)", (token,))
        except psycopg.Error as exc:
            if exc.sqlstate != '22023':
                raise
        else:
            raise RuntimeError("TRACKING_REPLAY_AFTER_REVOCATION_ALLOWED")
    labels.append("valid replay holds shared tracking lock until commit; later revocation blocks and takes effect")

    # Expiry may occur while a previously-valid replay waits on a row lock.
    # Shorten only a marked local fixture, retain the DB CHECK, and wait until
    # the server clock actually crosses its deadline before releasing the lock.
    _, _, token, _, tracking_token, tracking_id = targets['QA capability race_expiry']
    with connect(DB_NAME) as conn:
        conn.execute("ALTER TABLE public.vm_tracking_capabilities DISABLE TRIGGER vm_tracking_guard")
        conn.execute("UPDATE public.vm_tracking_capabilities SET created_at=clock_timestamp()-interval '1 day', expires_at=clock_timestamp()+interval '2 seconds' WHERE id=%s", (tracking_id,))
        conn.execute("ALTER TABLE public.vm_tracking_capabilities ENABLE TRIGGER vm_tracking_guard")
        conn.commit()
    with connect(DB_NAME) as locker, ThreadPoolExecutor(max_workers=1) as pool:
        locker.execute("SELECT id FROM public.vm_tracking_capabilities WHERE id=%s FOR UPDATE", (tracking_id,))
        pids = Queue()
        future = pool.submit(approve_after_lock, token, pids)
        wait_blocked(pids.get(timeout=5))
        deadline = monotonic() + 8
        while monotonic() < deadline:
            if locker.execute("SELECT clock_timestamp()>=expires_at FROM public.vm_tracking_capabilities WHERE id=%s", (tracking_id,)).fetchone()[0]:
                break
            sleep(0.025)
        else:
            raise RuntimeError("TRACKING_EXPIRY_TEST_CLOCK_DID_NOT_ADVANCE")
        locker.commit()
        if future.result(timeout=10) != '22023':
            raise RuntimeError("TRACKING_EXPIRY_WHILE_BLOCKED_DISCLOSED_TOKEN")
    labels.append("tracking expiry while blocked on a row lock is rechecked before replay")
    return labels


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
    parser.add_argument("--suite", choices=("foundation", "foundation_history", "inventory", "products", "contacts", "orders", "order_returns", "public_sales", "finance_summary", "migration_history", "fractional_precision", "public_capabilities", "financial_ledgers", "recipe_guard", "financial_orders", "financial_inventory", "inventory_return_privacy"), default="foundation")
    parser.add_argument("--latest", action="store_true", help="apply all migrations before the selected functional suite")
    parser.add_argument("--stop", action="store_true", help="stop only this marked local cluster after the run")
    args = parser.parse_args()
    if args.suite in ("fractional_precision", "public_capabilities", "financial_ledgers", "recipe_guard", "financial_orders", "financial_inventory", "inventory_return_privacy"):
        args.latest = True
    try:
        require_paths()
        init_cluster_if_needed()
        start_cluster()
        # Never reset before proving that an existing database belongs to this
        # marked cluster.  A default package cluster is never used as a fixture.
        drop_and_create_marked_database()
        bootstrap_roles_auth_and_users()
        if args.latest or args.suite in ("products", "contacts", "orders", "order_returns", "public_sales", "finance_summary", "migration_history"):
            bootstrap_storage_contract()
        preflight_local_database()
        if args.latest or args.suite in ("public_sales", "finance_summary", "migration_history"):
            bootstrap_realtime_contract()
        if args.suite == "inventory" and not INVENTORY_TEST.is_file():
            raise RuntimeError("INVENTORY_SUITE_SQL_MISSING")
        if args.suite == "products" and not PRODUCTS_TEST.is_file():
            raise RuntimeError("PRODUCTS_SUITE_SQL_MISSING")
        if args.suite == "contacts" and not CONTACTS_TEST.is_file():
            raise RuntimeError("CONTACTS_SUITE_SQL_MISSING")
        if args.suite == "orders" and not ORDERS_TEST.is_file():
            raise RuntimeError("ORDERS_SUITE_SQL_MISSING")
        if args.suite == "order_returns" and not ORDER_RETURNS_TEST.is_file():
            raise RuntimeError("ORDER_RETURNS_SUITE_SQL_MISSING")
        if args.suite == "public_sales" and not PUBLIC_SALES_TEST.is_file():
            raise RuntimeError("PUBLIC_SALES_SUITE_SQL_MISSING")
        if args.suite == "finance_summary" and not FINANCE_TEST.is_file():
            raise RuntimeError("FINANCE_SUITE_SQL_MISSING")
        if args.latest and args.suite in ("foundation_history", "migration_history"):
            raise RuntimeError("HISTORY_SUITES_REQUIRE_BASELINE")
        if args.suite == "foundation_history":
            foundation_labels = run_foundation_history_probe()
            migrations = [FOUNDATION.stem]
        else:
            foundation_labels = []
            paths = sorted(MIGRATION_DIR.glob("*.sql")) if args.latest else selected_migrations(args.suite)
            migrations = apply_migrations(paths)
        test_path = (
            FOUNDATION_TEST if args.suite in ("foundation", "foundation_history")
            else INVENTORY_TEST if args.suite == "inventory"
            else PRODUCTS_TEST if args.suite == "products"
            else CONTACTS_TEST if args.suite == "contacts"
            else ORDERS_TEST if args.suite in ("orders", "fractional_precision", "recipe_guard", "financial_orders", "financial_inventory")
            else ORDER_RETURNS_TEST if args.suite in ("order_returns", "inventory_return_privacy")
            else FINANCE_TEST if args.suite in ("finance_summary", "financial_ledgers")
            else PUBLIC_SALES_TEST
        )
        extra = (ROOT / "tests" / "database" / "fractional_precision.sql" if args.suite == "fractional_precision"
                 else ROOT / "tests" / "database" / "public_capabilities.sql" if args.suite == "public_capabilities"
                 else ROOT / "tests" / "database" / "financial_ledgers.sql" if args.suite == "financial_ledgers"
                 else ROOT / "tests" / "database" / "recipe_guard.sql" if args.suite == "recipe_guard"
                 else ROOT / "tests" / "database" / "financial_orders.sql" if args.suite == "financial_orders"
                 else ROOT / "tests" / "database" / "financial_inventory.sql" if args.suite == "financial_inventory"
                 else ROOT / "tests" / "database" / "inventory_return_privacy.sql" if args.suite == "inventory_return_privacy"
                 else None)
        labels = run_migration_history_probe() if args.suite == "migration_history" else run_sql_suite(test_path, extra)
        labels.extend(foundation_labels)
        if args.suite in ("orders", "fractional_precision"):
            labels.extend(run_orders_concurrency_probe())
        if args.suite in ("public_sales", "public_capabilities"):
            labels.extend(run_public_sales_concurrency_probe())
        if args.suite == "public_capabilities":
            labels.extend(run_capability_revocation_races())
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
