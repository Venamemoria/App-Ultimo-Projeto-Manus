"""Read protected configuration, tolerate copied example delimiters in memory only."""
import os
import re
from urllib.parse import unquote


def api_base():
    raw = os.environ.get("VITE_SUPABASE_URL", "").strip()
    # Project addresses are public; never accept an arbitrary host from malformed text.
    cleaned = raw.replace("[", "").replace("]", "")
    hosts = set(re.findall(r"[a-z0-9]{20}\.supabase\.co", cleaned, re.I))
    if len(hosts) != 1:
        raise ValueError("SUPABASE_API_URL_FORMAT")
    return "https://" + next(iter(hosts)).lower()


def database_parameters(strip_password_delimiters=False):
    raw = os.environ.get("SUPABASE_DATABASE_URL", "").strip()
    if not raw.startswith(("postgresql://", "postgres://")) or raw.count("@") != 1:
        raise ValueError("DATABASE_URI_FORMAT")
    info, tail = raw.split("://", 1)[1].rsplit("@", 1)
    if ":" not in info:
        raise ValueError("DATABASE_CREDENTIAL_FORMAT")
    username, password = info.split(":", 1)
    username = unquote(username).strip("[]")
    password = unquote(password)
    if strip_password_delimiters and password.startswith("[") and password.endswith("]"):
        password = password[1:-1]
    tail = tail.replace("[", "").replace("]", "")
    host_match = re.search(r"(?:db\.[a-z0-9]{20}\.supabase\.co|[a-z0-9.-]+\.pooler\.supabase\.com)", tail, re.I)
    if not host_match:
        raise ValueError("DATABASE_HOST_FORMAT")
    host = host_match.group(0).lower()
    after = tail[host_match.end():]
    port_match = re.match(r":(5432|6543)(?:/|$)", after)
    port = int(port_match.group(1)) if port_match else 5432
    name = after.rsplit("/", 1)[-1].split("?", 1)[0]
    if name != "postgres":
        raise ValueError("DATABASE_NAME_FORMAT")
    project = api_base().removeprefix("https://").split(".", 1)[0]
    if host.startswith("db."):
        if host != "db." + project + ".supabase.co":
            raise ValueError("PROJECT_MISMATCH")
    elif not username.endswith("." + project):
        raise ValueError("POOLER_PROJECT_MISMATCH")
    return {"host": host, "port": port, "dbname": name, "user": username, "password": password, "sslmode": "require", "connect_timeout": 12, "prepare_threshold": None}
