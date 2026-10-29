"""Parse PostgreSQL/PLpgSQL migration syntax; never connect to a database.

Install pglast in the isolated optional QA environment. Parsing does not prove
execution, permissions, data safety, or that a migration was applied.
"""
from pathlib import Path
import re
from pglast import parse_sql, parse_plpgsql

ROOT = Path(__file__).resolve().parents[1] / "supabase" / "migrations"
FUNCTION = re.compile(
    r"\bCREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\b.*?\$function\$;",
    re.IGNORECASE | re.DOTALL,
)
DO = re.compile(r"\bDO\s+\$(\w*)\$.*?\$\1\$;", re.IGNORECASE | re.DOTALL)
LANGUAGE = re.compile(r"\bLANGUAGE\s+plpgsql\b", re.IGNORECASE)

for path in sorted(ROOT.glob("*.sql")):
    source = path.read_text(encoding="utf-8")
    statements = parse_sql(source)
    functions = [match.group(0) for match in FUNCTION.finditer(source) if LANGUAGE.search(match.group(0))]
    blocks = [match.group(0) for match in DO.finditer(source)]
    for unit in [*functions, *blocks]:
        parse_plpgsql(unit)
    if not source.lstrip().startswith("BEGIN;") or not source.strip().endswith("COMMIT;"):
        raise ValueError(f"Migration must be transactional: {path.name}")
    print(f"{path.name}: {len(statements)} statements, {len(functions)} PL/pgSQL functions and {len(blocks)} DO blocks parsed")
