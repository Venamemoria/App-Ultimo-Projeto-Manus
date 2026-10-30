"""Helpers for keeping the app and Supabase CLI migration ledgers in sync."""
from pathlib import Path
import re

from pglast import parse_sql, split

MIGRATION_NAME = re.compile(r"^(\d{14})_([a-z0-9_]+)\.sql$")


def parse_migration(path: Path) -> tuple[str, str, str, list[str]]:
    """Return timestamp, name, body and CLI-compatible statements.

    Application migrations already contain their own BEGIN/COMMIT. Remove just
    that outer pair when executing so the schema change and both ledger writes
    can be committed as a single transaction by the caller.
    """
    match = MIGRATION_NAME.fullmatch(path.name)
    if not match:
        raise ValueError("INVALID_MIGRATION_FILENAME")
    source = path.read_text(encoding="utf-8").strip()
    if not source.startswith("BEGIN;") or not source.endswith("COMMIT;"):
        raise ValueError("TRANSACTION_REQUIRED")
    parsed = parse_sql(source)
    if len(parsed) < 2 or any(type(unit.stmt).__name__ == "TransactionStmt" for unit in parsed[1:-1]):
        raise ValueError("NESTED_TRANSACTION_CONTROL")
    statements = list(split(source))
    return match.group(1), match.group(2), source[len("BEGIN;"):-len("COMMIT;")], statements


def verify_history(connection) -> None:
    """Fail closed on missing, extra, or conflicting history entries."""
    if not connection.execute("SELECT to_regclass('public.vm_schema_migrations') IS NOT NULL").fetchone()[0]:
        raise ValueError("FOUNDATION_MUST_BE_APPLIED_FIRST")
    if not connection.execute("SELECT to_regclass('supabase_migrations.schema_migrations') IS NOT NULL").fetchone()[0]:
        raise ValueError("OFFICIAL_HISTORY_MISSING_REQUIRES_RECONCILIATION")
    custom = connection.execute("SELECT version FROM public.vm_schema_migrations ORDER BY version").fetchall()
    official = connection.execute("SELECT version, name FROM supabase_migrations.schema_migrations ORDER BY version").fetchall()
    expected: dict[str, str] = {}
    for (value,) in custom:
        version, separator, name = value.partition("_")
        if not separator or not re.fullmatch(r"\d{14}", version) or version in expected:
            raise ValueError("INVALID_CUSTOM_MIGRATION_HISTORY")
        expected[version] = name
    actual = {version: name for version, name in official}
    if set(actual) != set(expected) or any(name is not None and name != expected[version] for version, name in actual.items()):
        raise ValueError("MIGRATION_HISTORIES_DIVERGE")


def apply_initial_migration(connection, path: Path) -> None:
    """Bootstrap a genuinely empty application and both ledgers atomically."""
    version, name, body, statements = parse_migration(path)
    if connection.execute("SELECT to_regclass('public.vm_schema_migrations') IS NOT NULL").fetchone()[0]:
        raise ValueError("FOUNDATION_ALREADY_EXISTS")
    with connection.transaction():
        connection.execute("SET LOCAL lock_timeout = '5s'")
        connection.execute("CREATE SCHEMA IF NOT EXISTS supabase_migrations")
        connection.execute("REVOKE ALL ON SCHEMA supabase_migrations FROM PUBLIC, anon, authenticated")
        connection.execute("CREATE TABLE IF NOT EXISTS supabase_migrations.schema_migrations (version text NOT NULL PRIMARY KEY)")
        connection.execute("ALTER TABLE supabase_migrations.schema_migrations ADD COLUMN IF NOT EXISTS statements text[]")
        connection.execute("ALTER TABLE supabase_migrations.schema_migrations ADD COLUMN IF NOT EXISTS name text")
        connection.execute("REVOKE ALL ON TABLE supabase_migrations.schema_migrations FROM PUBLIC, anon, authenticated")
        if connection.execute("SELECT EXISTS(SELECT 1 FROM supabase_migrations.schema_migrations)").fetchone()[0]:
            raise ValueError("OFFICIAL_HISTORY_NOT_EMPTY")
        connection.execute(body, prepare=False)
        connection.execute(
            "INSERT INTO supabase_migrations.schema_migrations(version, name, statements) VALUES (%s, %s, %s)",
            (version, name, statements),
        )
        verify_history(connection)


def apply_migration(connection, path: Path) -> bool:
    """Apply a reviewed file and both history entries atomically; return changed."""
    version, name, body, statements = parse_migration(path)
    verify_history(connection)
    if connection.execute(
        "SELECT EXISTS(SELECT 1 FROM public.vm_schema_migrations WHERE version=%s)",
        (path.stem,),
    ).fetchone()[0]:
        return False
    with connection.transaction():
        connection.execute("SET LOCAL lock_timeout = '5s'")
        connection.execute(body, prepare=False)
        present = connection.execute(
            "SELECT EXISTS(SELECT 1 FROM public.vm_schema_migrations WHERE version=%s)",
            (path.stem,),
        ).fetchone()[0]
        if not present:
            raise ValueError("MIGRATION_REGISTRY_MISSING")
        connection.execute(
            "INSERT INTO supabase_migrations.schema_migrations(version, name, statements) VALUES (%s, %s, %s)",
            (version, name, statements),
        )
        verify_history(connection)
    return True
