"""Read-only schema inspection; never prints credentials or raw errors."""
import json
import os
import re
import sys
from urllib.parse import urlparse

import psycopg


def main():
    raw = os.environ.get("SUPABASE_DATABASE_URL", "").strip()
    # Brackets are valid for IPv6 literals, not DNS names copied from URI examples.
    dsn = re.sub(r"(?<=@)\[([a-zA-Z0-9.-]+)\](?=[:/]|$)", r"\1", raw)
    api = os.environ.get("VITE_SUPABASE_URL", "").strip()
    print(json.dumps({"configuration_present": {key: bool(os.environ.get(key)) for key in ["SUPABASE_DATABASE_URL", "VITE_SUPABASE_URL", "VITE_SUPABASE_ANON_KEY", "SUPABASE_SERVICE_ROLE_KEY"]}}))
    try:
        parsed = urlparse(dsn)
        api_parsed = urlparse(api)
        if parsed.scheme not in {"postgres", "postgresql"}:
            print("DATABASE_URL_INVALID_FORMAT: é necessária uma URI postgres:// ou postgresql://.")
            return 2
        if api_parsed.scheme != "https":
            print("SUPABASE_URL_INVALID_FORMAT: é necessária uma URL https://.")
            return 2
        print(json.dumps({"uri_structure": {"host_brackets_normalized_in_memory": dsn != raw, "database_name_is_postgres": parsed.path == "/postgres", "database_password_present": bool(parsed.password), "database_has_placeholder": bool(re.search(r"\[[^]]+\]|YOUR[_ -]|SUA[_ -]|\{[^}]+\}", dsn, re.I)), "api_url_has_path": api_parsed.path not in ("", "/")}}))
        with psycopg.connect(dsn, connect_timeout=15, sslmode="require") as conn:
            conn.execute("SET TRANSACTION READ ONLY")
            with conn.cursor() as cur:
                cur.execute("SELECT table_schema, table_name FROM information_schema.tables WHERE table_schema IN ('public','atelier','supabase_migrations') ORDER BY 1,2")
                tables = cur.fetchall()
                cur.execute("SELECT schemaname, tablename, rowsecurity FROM pg_tables WHERE schemaname IN ('public','atelier') ORDER BY 1,2")
                policies = cur.fetchall()
                cur.execute("SELECT count(*) FROM auth.users")
                users = cur.fetchone()[0]
            print(json.dumps({"connection": "ok", "tables": tables, "rls": policies, "auth_user_count": users}, ensure_ascii=False))
        return 0
    except Exception as exc:
        message = str(exc).lower()
        categories = {
            "password authentication failed": "invalid_password",
            "network is unreachable": "network_unreachable_ipv6_possible",
            "could not translate host name": "dns_resolution_failed",
            "failed to resolve host": "dns_resolution_failed",
            "name or service not known": "dns_resolution_failed",
            "timeout": "connection_timeout",
            "connection refused": "connection_refused",
            "tenant or user not found": "invalid_pooler_user_or_project",
            "does not appear to be an ipv4 or ipv6 address": "invalid_host_bracket_format",
            "invalid dsn": "invalid_connection_uri",
            "invalid percent-encoded token": "password_url_encoding_required",
            "does not exist": "database_name_not_found",
        }
        reason = next((value for text, value in categories.items() if text in message), "unclassified_connection_failure")
        print(json.dumps({"connection": "failed", "error_type": type(exc).__name__, "sqlstate": getattr(exc, "sqlstate", None), "reason": reason, "detail": "Mensagem original omitida para proteger os dados de conexão."}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
