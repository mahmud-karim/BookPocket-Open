"""Hosted-runner-only upgrade/uninstall test, preserving real fixture library data."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


def execute(executable, *args):
    result = subprocess.run([str(executable), *map(str, args)], creationflags=subprocess.CREATE_NO_WINDOW, timeout=600)
    if result.returncode: raise RuntimeError(f"Installer/test process failed with exit code {result.returncode}")


def snapshot(directory):
    return {p.relative_to(directory).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in directory.rglob("*") if p.is_file() and not p.name.endswith(("-wal", "-shm"))}


def run(baseline, installer, fixtures, report):
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError("Lifecycle smoke is restricted to disposable GitHub runners; it changes installer registration")
    data = Path(os.environ["LOCALAPPDATA"]) / "BookPocketOpen"
    if data.exists():
        raise RuntimeError("Refusing to use an existing personal-data directory")
    with tempfile.TemporaryDirectory(prefix="bookpocket-lifecycle-") as temporary:
        temporary = Path(temporary)
        installed = temporary / "Application"
        flags = ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", f"/DIR={installed}"]
        execute(baseline, *flags)
        runtime = installed / "runtime/python.exe"
        helper = Path(__file__).with_name("seed_windows_data.py")
        record = temporary / "record.json"
        parameters = ["--data-dir", data, "--fixtures", fixtures, "--ffmpeg", installed / "tools/ffmpeg.exe", "--record", record]
        execute(runtime, "-I", helper, "seed", *parameters)
        before = snapshot(data)
        assert any(name.endswith(".epub") for name in before)
        assert any(name.startswith("voices/") and name.endswith(".wav") for name in before)
        assert "tls/companion.key" in before and "library.sqlite3" in before
        execute(installer, *flags)
        if snapshot(data) != before: raise AssertionError("Upgrade modified personal data before startup")
        execute(runtime, "-I", helper, "verify", *parameters)
        before_uninstall = snapshot(data)
        execute(installed / "unins000.exe", "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART")
        if (installed / "launcher.py").exists() or runtime.exists():
            raise AssertionError("Uninstaller left application entry points installed")
        if snapshot(data) != before_uninstall:
            raise AssertionError("Uninstall modified personal books, voices, identity, or settings")
        result = {"baseline_installer_version": "0.0.0", "upgrade_installed": True, "library_reopened_after_upgrade": True, "source_book_and_voice_reference_preserved": True, "identity_and_settings_preserved": True, "uninstall_removed_application": True, "uninstall_preserved_data": True, "preserved_files": len(before_uninstall), "baseline_payload": "same current source with older installer version; not historic app migration", "speech_generation": "NOT TESTED"}
        report.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(result, indent=2))

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--installer", type=Path, required=True)
    parser.add_argument("--fixtures", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    run(args.baseline.resolve(), args.installer.resolve(), args.fixtures.resolve(), args.report)
