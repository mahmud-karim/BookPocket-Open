"""Fail CI when exported hash locks drift from the universal uv project lock."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
uv = [sys.executable, "-m", "uv"]
subprocess.run([*uv, "lock", "--check", "--project", str(root / "companion")], check=True)
with tempfile.TemporaryDirectory(prefix="bookpocket-lock-check-") as temporary:
    for target, extra in [(root / "companion/requirements.lock", []), (root / "tests/requirements-test.lock", ["--extra", "test"])]:
        exported = Path(temporary) / target.name
        subprocess.run([*uv, "export", "--project", str(root / "companion"), "--frozen", "--no-dev", "--no-emit-project", "--no-header", *extra, "--output-file", str(exported), "--quiet"], check=True)
        if exported.read_text(encoding="utf-8") != target.read_text(encoding="utf-8"):
            raise SystemExit(f"Dependency export is stale: {target.relative_to(root)}")
print("Universal dependency lock and hash exports agree.")
