"""Parse PostgreSQL and PL/pgSQL migration syntax without connecting to a database.

Install pglast in an isolated Python environment, then run this script.
This is syntax validation, not a claim that a migration has been applied.
"""
from pathlib import Path
import re
from pglast import parse_sql, parse_plpgsql

root = Path(__file__).resolve().parents[1] / "supabase" / "migrations"
for path in sorted(root.glob("*.sql")):
    source = path.read_text()
    statements = parse_sql(source)
    blocks = re.findall(r"CREATE OR REPLACE FUNCTION .*?\$function\$;", source, re.S)
    functions = [block for block in blocks if "LANGUAGE plpgsql" in block]
    for block in functions:
        parse_plpgsql(block)
    if not source.startswith("BEGIN;") or not source.strip().endswith("COMMIT;"):
        raise ValueError(f"Migration must be transactional: {path.name}")
    print(f"{path.name}: {len(statements)} statements, {len(functions)} PL/pgSQL functions parsed")
