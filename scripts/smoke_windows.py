"""Smoke the packaged runtime, real CLI, original import and isolated engine venv."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.request

def port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]

def run(bundle, report):
    python = bundle / "runtime/python.exe"
    env = dict(os.environ)
    env.pop("PYTHONPATH", None)
    env.pop("PYTHONHOME", None)
    env["PATH"] = str(bundle / "tools") + os.pathsep + os.environ.get("SystemRoot", r"C:\Windows") + r"\System32"
    env["PYTHONNOUSERSITE"] = "1"
    with tempfile.TemporaryDirectory(prefix="bookpocket-package-smoke-") as directory:
        temp = Path(directory)
        api_port = port()
        log = (temp / "server.log").open("wb")
        process = subprocess.Popen([str(python), "-I", "-m", "bookpocket_companion.cli", "serve", "--dev", "--no-browser", "--port", str(api_port), "--studio-dir", str(bundle / "studio"), "--data-dir", str(temp / "data")], env=env, stdout=log, stderr=subprocess.STDOUT, creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            url = f"http://127.0.0.1:{api_port}"
            for _ in range(100):
                if process.poll() is not None: raise RuntimeError("Packaged server exited: " + (temp / "server.log").read_text(errors="replace"))
                try:
                    with urllib.request.urlopen(url + "/v1/health", timeout=1) as response:
                        health = json.load(response)
                    break
                except OSError: time.sleep(.2)
            else: raise RuntimeError("Packaged server did not become ready")
            assert health["api_version"] == "1"
            with urllib.request.urlopen(url, timeout=5) as response:
                page = response.read().decode()
            assert 'id="root"' in page and "/assets/" in page
            try:
                urllib.request.urlopen(url + "/v1/books", timeout=5)
                raise AssertionError("Private library exposed")
            except urllib.error.HTTPError as error:
                assert error.code == 401
            # Venv must still work after the official runtime is relocated into our bundle.
            subprocess.run([str(python), "-I", "-m", "venv", str(temp / "engine-probe")], check=True, env=env, capture_output=True)
            child = temp / "engine-probe/Scripts/python.exe"
            version = subprocess.check_output([str(child), "-I", "-c", "import sys;print(sys.version.split()[0])"], text=True, env=env).strip()
            ffmpeg = subprocess.check_output([str(bundle / "tools/ffmpeg.exe"), "-version"], text=True, env=env).splitlines()[0]
            # Exercise the actual windowless tray entry point and its production listeners.
            gui_env = dict(env)
            gui_env["LOCALAPPDATA"] = str(temp / "profile")
            gui_port, gui_studio = port(), port()
            gui = subprocess.Popen([str(bundle / "runtime/pythonw.exe"), "-I", str(bundle / "launcher.py"), "--no-browser", "--port", str(gui_port), "--studio-port", str(gui_studio), "--data-dir", str(temp / "gui-data")], env=gui_env, creationflags=subprocess.CREATE_NO_WINDOW)
            try:
                for _ in range(100):
                    if gui.poll() is not None: raise RuntimeError("Windowless tray launcher exited")
                    try:
                        with urllib.request.urlopen(f"http://127.0.0.1:{gui_studio}/v1/health", timeout=1) as response:
                            assert json.load(response)["api_version"] == "1"
                        break
                    except OSError: time.sleep(.2)
                else: raise RuntimeError("Windowless tray launcher did not serve the studio")
            finally:
                gui.terminate()
                gui.wait(timeout=15)
            result = {"runtime_version": version, "health": health, "studio_served": True, "windowless_tray_launcher": True, "library_requires_auth": True, "engine_venv_created": True, "ffmpeg": ffmpeg, "code_signed": False, "real_model_generation": "NOT TESTED", "physical_device": "NOT TESTED"}
            report.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
            print(json.dumps(result, indent=2))
        finally:
            process.terminate()
            process.wait(timeout=15)
            log.close()

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    run(args.bundle.resolve(), args.report)

