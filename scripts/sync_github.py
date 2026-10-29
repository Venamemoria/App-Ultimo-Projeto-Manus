"""Copy committed source to the user's authorized existing GitHub repository.

Keeps separate histories and refuses to overwrite concurrent user changes.
Never copies untracked files, credentials or the source .git directory.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess

SOURCE = Path(__file__).resolve().parents[1]
TARGET = Path("/home/ubuntu/App-No-Atelie")
STATE = SOURCE / ".local/github-sync.json"


def git(*args, cwd=SOURCE):
    return subprocess.check_output(["git", *args], cwd=cwd, env={**os.environ, "GIT_TERMINAL_PROMPT": "0", "GIT_PAGER": "cat"}).decode().strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", help="Previously copied canonical source SHA")
    parser.add_argument("--message", required=True)
    args = parser.parse_args()
    saved = json.loads(STATE.read_text()) if STATE.exists() else {}
    baseline = args.baseline or saved.get("source_sha")
    if not baseline:
        raise SystemExit("Previous source SHA required; refusing an ungrounded copy.")
    remote = git("remote", "get-url", "origin", cwd=TARGET)
    if remote not in {"https://github.com/Venamemoria/App-No-Atelie.git", "git@github.com:Venamemoria/App-No-Atelie.git"}:
        raise SystemExit("Unexpected target repository; sync aborted.")
    if git("status", "--porcelain", cwd=TARGET):
        raise SystemExit("Target has local changes; preserve and review before syncing.")
    git("pull", "--ff-only", cwd=TARGET)
    source_sha = git("rev-parse", "HEAD")
    paths = git("ls-tree", "-r", "--name-only", source_sha).splitlines()
    updates = []
    for name in paths:
        if name.startswith(".git/") or name == ".env" or (name.startswith(".env.") and name != ".env.example"):
            raise SystemExit("Unexpected protected path; sync aborted.")
        current = subprocess.check_output(["git", "show", source_sha + ":" + name], cwd=SOURCE)
        target = TARGET / name
        if target.is_symlink():
            raise SystemExit("Unexpected target symlink; sync aborted.")
        if target.exists() and target.read_bytes() != current:
            old = subprocess.run(["git", "show", baseline + ":" + name], cwd=SOURCE, capture_output=True)
            if old.returncode or target.read_bytes() != old.stdout:
                raise SystemExit("Concurrent target change preserved; review required: " + name)
        updates.append((target, current))
    secrets = [os.environ.get(key, "").encode() for key in ("VITE_SUPABASE_URL", "VITE_SUPABASE_ANON_KEY", "SUPABASE_DATABASE_URL", "SUPABASE_SERVICE_ROLE_KEY")]
    if any(secret in content for secret in secrets if len(secret) > 16 for _, content in updates):
        raise SystemExit("Protected value in source; sync aborted.")
    for target, content in updates:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
    git("diff", "--check", cwd=TARGET)
    git("add", "--", *paths, cwd=TARGET)
    if git("diff", "--cached", "--name-only", cwd=TARGET):
        git("-c", "user.name=Manus", "-c", "user.email=dev-agent@manus.ai", "commit", "-m", args.message, cwd=TARGET)
    target_sha = git("rev-parse", "HEAD", cwd=TARGET)
    git("push", "origin", "main", cwd=TARGET)
    remote_sha = git("ls-remote", "origin", "refs/heads/main", cwd=TARGET).split()[0]
    if remote_sha != target_sha:
        raise SystemExit("Remote SHA mismatch; verify push before continuing.")
    STATE.parent.mkdir(exist_ok=True)
    STATE.write_text(json.dumps({"source_sha": source_sha, "target_sha": target_sha}, indent=2) + "\n")
    print(json.dumps({"github_push": "verified", "source_sha": source_sha, "github_sha": target_sha}))


if __name__ == "__main__":
    main()
