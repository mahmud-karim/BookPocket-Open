"""Reject accidental private source inputs before public publication. No secret output."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

MEDIA = {".epub", ".pdf", ".wav", ".mp3", ".m4a", ".m4b", ".flac", ".ogg", ".safetensors", ".pt", ".pth", ".onnx", ".db", ".sqlite", ".sqlite3", ".ipa", ".p12", ".pfx", ".pem", ".key"}
PATTERNS = [
    ("private key", re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")),
    ("GitHub credential", re.compile(rb"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})")),
    ("AWS credential", re.compile(rb"AKIA[A-Z0-9]{16}")),
    ("personal absolute path", re.compile(rb"(?:[A-Za-z]:[\\/]Users[\\/](?!Public\b)[^\s\"<>]+|\x2fUsers/[^\s\"<>]+)")),
    ("Tailscale private hostname", re.compile(rb"[A-Za-z0-9-]+\.[A-Za-z0-9-]+\.ts\.net")),
]

def audit(root: Path) -> list[str]:
    provenance = json.loads((root / "tests/fixtures/media-provenance.json").read_text(encoding="utf-8-sig"))["sha256"]
    output = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root)
    paths = sorted(set(p.decode("utf-8") for p in output.split(b"\0") if p))
    failures = []
    for relative in paths:
        path = root / relative
        if path.is_symlink():
            failures.append(f"{relative}: symlink requires explicit release review")
            continue
        if not path.is_file():
            continue
        if path.name == ".env" or (path.name.startswith(".env.") and path.name not in {".env.example", ".env.sample"}):
            failures.append(f"{relative}: environment credentials file")
        data = path.read_bytes()
        if path.suffix.lower() in MEDIA:
            expected = provenance.get(path.name) if relative.startswith("tests/fixtures/") else None
            if expected != hashlib.sha256(data).hexdigest():
                failures.append(f"{relative}: non-fixture private/media/model binary")
        if len(data) > 5_000_000:
            failures.append(f"{relative}: source payload exceeds 5 MB; review binary provenance")
        # Tests intentionally exercise detectors without carrying live credentials.
        if path.suffix.lower() not in MEDIA:
            for label, pattern in PATTERNS:
                if pattern.search(data):
                    failures.append(f"{relative}: {label}")
    return failures

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    failures = audit(args.root.resolve())
    for failure in failures:
        print(failure)
    if failures:
        raise SystemExit(1)
    print("Public source preflight passed. Manual provenance review is still required.")


