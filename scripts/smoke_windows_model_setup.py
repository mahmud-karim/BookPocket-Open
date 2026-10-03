"""Manual fresh-hosted-Windows gate for the published Companion 0.1.3.

The parent is stdlib-only. Every installer/model descendant belongs to a private
Windows Job Object before the bootstrap child may do work. Never run --hosted
on a development PC: cold model installation is restricted to GitHub runners.
Only explicit, sanitized measurements are exported; runtime files are deleted.
"""
import argparse
import ctypes
from ctypes import wintypes
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import wave


INSTALLER_URL = "https://github.com/mahmud-karim/BookPocket-Open/releases/download/windows-v0.1.3-preview.1/BookPocketOpen-Setup-x64.exe"
INSTALLER_SHA256 = "2288618d1de0886d1813917d7e72280d89169e818daabcff335eff303abd997b"
DEADLINE_SECONDS = 22 * 60
PARAGRAPHS = ["Mira placed the blue lantern beside the garden gate.",
              "Rowan crossed the quiet bridge and returned the borrowed map."]
SOURCE = ("\n\n".join(PARAGRAPHS) + "\n").encode("utf-8")


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


class SuspendedProcess:
    """Retain the exact process and primary-thread handles from CreateProcess."""
    def __init__(self, command, cwd, environment):
        import _winapi
        import msvcrt
        self.api = _winapi
        self.returncode = None
        startup = subprocess.STARTUPINFO()
        startup.dwFlags = subprocess.STARTF_USESTDHANDLES
        with open(os.devnull, "w+b") as null:
            handle = msvcrt.get_osfhandle(null.fileno())
            os.set_handle_inheritable(handle, True)
            startup.hStdInput = startup.hStdOutput = startup.hStdError = handle
            startup.lpAttributeList = {"handle_list": [handle]}
            self._handle, self._thread, self.pid, _ = _winapi.CreateProcess(
                str(command[0]), subprocess.list2cmdline(command), None, None, True,
                subprocess.CREATE_NO_WINDOW | 0x00000004, environment, str(cwd), startup)

    def resume(self):
        # ResumeThread receives the retained creation handle, never a reopened ID.
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.ResumeThread.argtypes = [wintypes.HANDLE]
        kernel.ResumeThread.restype = wintypes.DWORD
        require(kernel.ResumeThread(self._thread) == 1, "Primary thread was not suspended")
        self.api.CloseHandle(self._thread)
        self._thread = None

    def poll(self):
        if self.returncode is None and self.api.WaitForSingleObject(self._handle, 0) == self.api.WAIT_OBJECT_0:
            self.returncode = self.api.GetExitCodeProcess(self._handle)
        return self.returncode

    def wait(self, timeout):
        if self.api.WaitForSingleObject(self._handle, int(timeout * 1000)) != self.api.WAIT_OBJECT_0:
            raise subprocess.TimeoutExpired("owned suspended child", timeout)
        return self.poll()

    def terminate(self):
        self.api.TerminateProcess(self._handle, 1)

    def close(self):
        if self._thread is not None:
            self.api.CloseHandle(self._thread)
            self._thread = None
        if self._handle is not None:
            self.api.CloseHandle(self._handle)
            self._handle = None


class WindowsJob:
    """Private kill-on-close job; no breakaway permission and no PID-tree scans."""
    def __init__(self):
        if os.name != "nt":
            raise RuntimeError("Windows Job Objects require Windows")
        self.kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel = self.kernel
        kernel.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
        kernel.CreateJobObjectW.restype = wintypes.HANDLE
        kernel.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
        kernel.QueryInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD, ctypes.c_void_p]
        kernel.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
        kernel.IsProcessInJob.argtypes = [wintypes.HANDLE, wintypes.HANDLE, ctypes.POINTER(wintypes.BOOL)]
        kernel.TerminateJobObject.argtypes = [wintypes.HANDLE, wintypes.UINT]
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]

        class BasicLimits(ctypes.Structure):
            _fields_ = [("PerProcessUserTimeLimit", ctypes.c_int64), ("PerJobUserTimeLimit", ctypes.c_int64),
                        ("LimitFlags", wintypes.DWORD), ("MinimumWorkingSetSize", ctypes.c_size_t),
                        ("MaximumWorkingSetSize", ctypes.c_size_t), ("ActiveProcessLimit", wintypes.DWORD),
                        ("Affinity", ctypes.c_size_t), ("PriorityClass", wintypes.DWORD), ("SchedulingClass", wintypes.DWORD)]

        class IOCounters(ctypes.Structure):
            _fields_ = [(name, ctypes.c_uint64) for name in ("ReadOperationCount", "WriteOperationCount", "OtherOperationCount", "ReadTransferCount", "WriteTransferCount", "OtherTransferCount")]

        class ExtendedLimits(ctypes.Structure):
            _fields_ = [("BasicLimitInformation", BasicLimits), ("IoInfo", IOCounters),
                        ("ProcessMemoryLimit", ctypes.c_size_t), ("JobMemoryLimit", ctypes.c_size_t),
                        ("PeakProcessMemoryUsed", ctypes.c_size_t), ("PeakJobMemoryUsed", ctypes.c_size_t)]

        class Accounting(ctypes.Structure):
            _fields_ = [(name, ctypes.c_int64) for name in ("TotalUserTime", "TotalKernelTime", "ThisPeriodTotalUserTime", "ThisPeriodTotalKernelTime")]
            _fields_ += [(name, wintypes.DWORD) for name in ("TotalPageFaultCount", "TotalProcesses", "ActiveProcesses", "TotalTerminatedProcesses")]

        self.accounting_type = Accounting
        self.name = "BookPocketSetupSmoke-" + os.urandom(16).hex()
        self.handle = kernel.CreateJobObjectW(None, self.name)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            limits = ExtendedLimits()
            limits.BasicLimitInformation.LimitFlags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            self._check(kernel.SetInformationJobObject(self.handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)))
            confirmed = ExtendedLimits()
            self._check(kernel.QueryInformationJobObject(self.handle, 9, ctypes.byref(confirmed), ctypes.sizeof(confirmed), None))
            self.limit_flags = confirmed.BasicLimitInformation.LimitFlags
            require(self.limit_flags == 0x2000, "Job limits must forbid both breakaway modes")
        except BaseException:
            self.close()
            raise

    @staticmethod
    def _check(result):
        if not result:
            raise ctypes.WinError(ctypes.get_last_error())

    def assign(self, process):
        # Keep the live creation handle; never reopen a potentially reused PID.
        handle = wintypes.HANDLE(int(process._handle))
        self._check(self.kernel.AssignProcessToJobObject(self.handle, handle))
        contained = wintypes.BOOL()
        self._check(self.kernel.IsProcessInJob(handle, self.handle, ctypes.byref(contained)))
        require(contained.value, "Child was not assigned to its private job")

    def counts(self):
        value = self.accounting_type()
        self._check(self.kernel.QueryInformationJobObject(self.handle, 1, ctypes.byref(value), ctypes.sizeof(value), None))
        return {"active": value.ActiveProcesses, "total": value.TotalProcesses}

    def terminate(self):
        self._check(self.kernel.TerminateJobObject(self.handle, 124))

    def wait_empty(self, seconds=10):
        deadline = time.monotonic() + seconds
        while self.counts()["active"] and time.monotonic() < deadline:
            time.sleep(.05)
        require(self.counts()["active"] == 0, "Owned job did not become empty")

    def close(self):
        if self.handle:
            self._check(self.kernel.CloseHandle(self.handle))
            self.handle = None


def wait_for_start(root):
    # No installation/import of application code/subprocess creation before this.
    deadline = time.monotonic() + 30
    while not (root / "start.flag").exists():
        if time.monotonic() > deadline:
            raise RuntimeError("Parent never authorized the assigned child")
        time.sleep(.02)


def supervise(command, root, environment, seconds=DEADLINE_SECONDS):
    """Bound the entire tree, including an orphan left after the leader exits."""
    started = time.monotonic()
    require(not (root / "start.flag").exists(), "Start flag must be fresh")
    result = {"assigned_before_start": False, "kill_on_close": False, "breakaway_disabled": False,
              "timed_out": False, "normal_tree_exit": False, "active_processes_after": None}
    job = WindowsJob()
    child = None
    try:
        result.update(kill_on_close=True, breakaway_disabled=True)
        environment = {**environment, "BOOKPOCKET_SMOKE_JOB": job.name}
        child = SuspendedProcess(command, root, environment)
        try:
            job.assign(child)
        except BaseException:
            # The unassigned child is still waiting; it has never spawned anything.
            child.terminate()
            child.wait(timeout=10)
            raise
        result["assigned_before_start"] = True
        (root / "start.flag").write_text("assigned", encoding="ascii")
        child.resume()
        result["created_suspended"] = True
        leader_exited = None
        while True:
            now = time.monotonic()
            count = job.counts()
            code = child.poll()
            if code is not None and count["active"] == 0:
                result.update(exit_code=code, normal_tree_exit=True)
                break
            if code is not None and leader_exited is None:
                leader_exited = now
            if now - started >= seconds:
                result["timed_out"] = True
                break
            if leader_exited is not None and now - leader_exited > min(5, seconds):
                result["orphaned_descendants"] = True
                break
            time.sleep(.05)
        if not result["normal_tree_exit"]:
            job.terminate()
            child.wait(timeout=10)
            result["exit_code"] = child.returncode
        job.wait_empty()
        result["active_processes_after"] = job.counts()["active"]
        result["total_owned_processes"] = job.counts()["total"]
        return result
    finally:
        # Any exception also closes the only job handle, killing its descendants.
        job.close()
        if child is not None:
            try:
                child.wait(timeout=10)
            finally:
                child.close()


def isolated_environment(root):
    # Do not inherit registry-backed Python, personal caches, proxy credentials,
    # GitHub tokens, pip configuration, external voice URLs or a source PYTHONPATH.
    env = {key: value for key, value in os.environ.items()
           if key.upper() in {"SYSTEMROOT", "WINDIR", "COMSPEC", "NUMBER_OF_PROCESSORS", "PROCESSOR_ARCHITECTURE"}}
    for key, relative in {"TEMP": "tmp", "TMP": "tmp", "USERPROFILE": "profile", "HOME": "profile",
                          "LOCALAPPDATA": "profile/local", "APPDATA": "profile/roaming", "PIP_CACHE_DIR": "pip-cache",
                          "HF_HOME": "models", "HF_HUB_CACHE": "models/hub", "TORCH_HOME": "torch-cache",
                          "XDG_CACHE_HOME": "cache"}.items():
        path = root / relative
        path.mkdir(parents=True, exist_ok=True)
        env[key] = str(path)
    env.update(PATH=str(root / "installed/tools") + os.pathsep + str(Path(env["SYSTEMROOT"]) / "System32"),
               PYTHONNOUSERSITE="1", PYTHONUTF8="1", PIP_CONFIG_FILE=os.devnull,
               PIP_DISABLE_PIP_VERSION_CHECK="1", HF_HUB_DISABLE_TELEMETRY="1",
               OMP_NUM_THREADS="2", MKL_NUM_THREADS="2", OPENBLAS_NUM_THREADS="2",
               NUMEXPR_NUM_THREADS="2", CUDA_VISIBLE_DEVICES="-1")
    return env


def save_result(root, report):
    path = root / "result.json"
    temporary = root / "result.tmp"
    temporary.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def validate_wav(path, expected_duration=None):
    with wave.open(str(path), "rb") as audio:
        require((audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) == (1, 2, 24000), "Unexpected PCM format")
        frames = audio.getnframes()
        pcm = audio.readframes(frames)
        require(frames >= 240 and len(pcm) == frames * 2 and any(pcm), "Missing, truncated or entirely silent audio")
        seconds = frames / 24000
        if expected_duration is not None:
            require(math.isfinite(expected_duration) and abs(seconds - expected_duration) <= 1 / 24000, "Audio duration does not match its frames")
        return seconds


def full_decode(ffmpeg, path):
    subprocess.run([str(ffmpeg), "-v", "error", "-xerror", "-i", str(path), "-f", "null", "-"],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)


def validate_timings(asset, text):
    duration = asset["duration"]
    require(math.isfinite(duration) and duration > 0, "Invalid timing duration")
    require(bool(asset["timings"]), "Missing source timing intervals")
    source_end, audio_end = 0, 0.0
    for interval in asset["timings"]:
        start, end = interval["start"], interval["end"]
        first, last = interval["start_offset"], interval["end_offset"]
        require(math.isfinite(start) and math.isfinite(end) and 0 <= start < end <= duration + 1e-6, "Invalid audio timing interval")
        require(start >= audio_end - .05, "Model intervals overlap by more than 50ms")
        require(type(first) is int and type(last) is int and source_end <= first < last <= len(text), "Invalid original source interval")
        source_end, audio_end = last, end


def runtime_probe(root):
    # This function is reached only through the installed interpreter's -I mode.
    import httpx
    import uvicorn
    import bookpocket_companion.app as application
    from bookpocket_companion.models import Config
    import secrets
    import uuid

    bundle = root / "installed"
    require(sys.flags.isolated == 1, "Installed interpreter must use isolated mode")
    require(Path(sys.executable).resolve() == (bundle / "runtime/python.exe").resolve(), "Wrong application interpreter")
    require(Path(application.__file__).resolve().is_relative_to((bundle / "runtime").resolve()), "Application code was loaded outside the installer")
    report = json.loads((root / "result.json").read_text(encoding="utf-8"))
    report["phase"] = "server_start"
    save_result(root, report)
    config = Config(data_dir=root / "data", dev=True, admin_token=secrets.token_urlsafe(32), ffmpeg=str(bundle / "tools/ffmpeg.exe"))
    require(not config.data_dir.exists(), "Application data must be fresh")
    app = application.create_app(config)  # No injected engines or fake capabilities.
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(128)
    address = f"http://127.0.0.1:{listener.getsockname()[1]}"
    server = uvicorn.Server(uvicorn.Config(app, log_config=None, log_level="critical", access_log=False, lifespan="on", timeout_graceful_shutdown=20))
    thread = threading.Thread(target=server.run, kwargs={"sockets": [listener]}, name="hosted-smoke-uvicorn")
    thread.start()
    completed = False
    try:
        with httpx.Client(base_url=address, timeout=30, trust_env=False) as api:
            for _ in range(300):
                try:
                    response = api.get("/v1/health")
                    if response.status_code == 200:
                        break
                except httpx.TransportError:
                    pass
                require(thread.is_alive(), "Server exited during startup")
                time.sleep(.1)
            else:
                raise RuntimeError("Server did not become ready")
            health = response.json()
            require(health["version"] == "0.1.3", "Unexpected installed Companion version")
            admin = {"Authorization": "Bearer " + config.admin_token}

            def request(method, path, expected=200, **kwargs):
                response = api.request(method, path, **kwargs)
                require(response.status_code == expected, "Unexpected API status")
                return response.json()

            ticket = request("POST", "/v1/admin/pairing-tickets", headers=admin)
            pending = request("POST", "/v1/pairings", json={"code": ticket["code"], "device_name": "Hosted isolated setup smoke"})
            request("POST", f'/v1/admin/pairings/{pending["id"]}/approve', headers=admin)
            approved = request("GET", f'/v1/pairings/{pending["id"]}', headers={"Authorization": "Bearer " + pending["poll_token"]})
            device = {"Authorization": "Bearer " + approved["device_token"]}
            require(api.get("/v1/books").status_code == 401, "Private books must require authentication")
            require(api.post("/v1/admin/engines/kokoro/install", headers=device).status_code == 403, "Device token must not install engines")
            inventory = request("GET", "/v1/engines", headers=device)["engines"]
            require(not next(e for e in inventory if e["id"] == "kokoro")["available"], "Cold engine unexpectedly ready")
            engine_root = config.data_dir / "engines/kokoro"
            require(not (engine_root / "venv").exists() and not (engine_root / "models").exists(), "Model state must be cold")
            report.update(phase="model_install", installed_runtime_isolated=True, companion_version=health["version"], initial_engine_unavailable=True)
            save_result(root, report)
            started = time.monotonic()
            request("POST", "/v1/admin/engines/kokoro/install", headers=admin)
            while True:
                states = request("GET", "/v1/admin/engines/installations", headers=admin)["installations"]
                state = next(s for s in states if s["engine"] == "kokoro")
                if state["status"] == "completed":
                    break
                require(state["status"] == "running", "Real model installation failed")
                time.sleep(2)  # Outer Job Object watchdog bounds even pip hangs.
            require(next(e for e in request("GET", "/v1/engines", headers=device)["engines"] if e["id"] == "kokoro")["available"], "Installed model not ready")
            marker = json.loads((engine_root / "ready.json").read_text(encoding="utf-8"))
            require(marker.get("validated_synthesis") is True and marker.get("validated_model_load") is True, "Readiness lacks validated synthesis")
            provenance = marker["provenance"]
            packages = provenance["packages"]
            require(packages.get("kokoro") == "0.9.4" and packages.get("torch"), "Missing model package provenance")
            snapshots = provenance["model_snapshots"]
            require(any(re.fullmatch(r"models--hexgrad--Kokoro-82M/snapshots/[0-9a-f]{40}", s) for s in snapshots), "Missing pinned public model snapshot provenance")
            cpu = json.loads(subprocess.check_output([str(engine_root / "venv/Scripts/python.exe"), "-I", "-c",
                "import json,torch; print(json.dumps({'cuda_available':torch.cuda.is_available(),'cuda_devices':torch.cuda.device_count(),'torch_version':torch.__version__}))"], timeout=60, stderr=subprocess.DEVNULL))
            require(cpu["cuda_available"] is False and cpu["cuda_devices"] == 0, "This gate requires a CPU-only host")
            probe_seconds = validate_wav(engine_root / "probe.wav")
            full_decode(bundle / "tools/ffmpeg.exe", engine_root / "probe.wav")
            report.update(phase="render", setup_seconds=round(time.monotonic() - started, 3), readiness_probe_seconds=probe_seconds,
                          cpu_confirmed=True, model_snapshot_revisions=[s.rsplit("/", 1)[-1] for s in snapshots if s.startswith("models--hexgrad--Kokoro-82M/snapshots/")],
                          package_versions={key: packages[key] for key in ("kokoro", "torch", "numpy", "soundfile") if key in packages})
            save_result(root, report)
            book = request("POST", "/v1/books", headers=device, files={"file": ("original-setup-smoke.txt", SOURCE, "text/plain")})
            segments = [segment for chapter in book["chapters"] for segment in chapter["segments"]]
            require([s["text"] for s in segments] == PARAGRAPHS, "Original paragraph identity changed")
            require(api.get(f'/v1/books/{book["id"]}/source', headers=device).content == SOURCE, "Original source bytes changed")
            body = {"request_id": str(uuid.uuid4()), "book_id": book["id"], "segment_ids": [s["id"] for s in segments], "engine": "kokoro", "voice_id": "kokoro:af_heart", "announce_chapters": False}
            job = request("POST", "/v1/jobs", expected=202, headers=device, json=body)
            while job["status"] != "completed":
                require(job["status"] in {"queued", "running"}, "Real short render failed")
                time.sleep(.3)
                job = request("GET", "/v1/jobs/" + job["id"], headers=device)
            require(job["completed_segments"] == job["total_segments"] == 2 and len(job["assets"]) == 2, "Incomplete short book")
            require([a["segment_id"] for a in job["assets"]] == body["segment_ids"] and len({a["id"] for a in job["assets"]}) == 2, "Wrong asset source identity/order")

            def download(asset, name):
                require(api.get(asset["url"]).status_code == 401, "Audio must require authentication")
                response = api.get(asset["url"], headers=device)
                require(response.status_code == 200 and len(response.content) == asset["bytes"] and hashlib.sha256(response.content).hexdigest() == asset["sha256"], "Downloaded audio failed integrity validation")
                path = root / name
                path.write_bytes(response.content)
                full_decode(bundle / "tools/ffmpeg.exe", path)
                return path

            for index, (segment, asset) in enumerate(zip(segments, job["assets"])):
                require((asset["source_start"], asset["source_end"]) == (0, len(segment["text"])), "Asset source scope changed")
                validate_timings(asset, segment["text"])
                validate_wav(download(asset, f"checked-{index}.wav"), asset["duration"])
            report["phase"] = "export"
            save_result(root, report)
            exported = request("POST", f'/v1/jobs/{job["id"]}/export', headers=device, json={"format": "m4b"})
            output = download(exported, "checked.m4b")
            probe = json.loads(subprocess.check_output([str(bundle / "tools/ffprobe.exe"), "-v", "error", "-show_streams", "-show_format", "-show_chapters", "-of", "json", str(output)], timeout=60, stderr=subprocess.DEVNULL))
            seconds = sum(a["duration"] for a in job["assets"])
            require(any(s.get("codec_name") == "aac" and s.get("codec_type") == "audio" for s in probe["streams"]), "Export must contain AAC audio")
            require(abs(float(probe["format"]["duration"]) - seconds) < .15, "Export duration mismatch")
            require(len(probe["chapters"]) == 1 and abs(float(probe["chapters"][0]["start_time"])) <= .001 and abs(float(probe["chapters"][0]["end_time"]) - seconds) < .002, "Export chapter does not span the source")
            require(not any(p.is_dir() for p in (config.data_dir / "assets").iterdir()), "Render workspace remains after completion")
            report.update(phase="shutdown", authenticated_loopback_pairing=True, original_source_preserved=True,
                          rendered_assets=2, audio_seconds=seconds, wav_integrity_and_full_decode=True,
                          finite_bounded_source_timings=True,
                          m4b_integrity_and_full_decode=True, m4b_bytes=exported["bytes"], m4b_sha256=exported["sha256"])
            save_result(root, report)
            completed = True
    finally:
        server.should_exit = True
        thread.join(timeout=30)
        require(not thread.is_alive(), "Uvicorn lifespan did not exit normally")
        listener.close()
        require(not app.state.worker.thread.is_alive(), "Narration worker did not stop")
    if completed:
        report.update(status="pass", phase="complete", normal_lifespan_shutdown=True)
        save_result(root, report)


def bootstrap(root):
    wait_for_start(root)
    report = {"status": "incomplete", "phase": "installer_download", "installer_sha256": INSTALLER_SHA256,
              "release": "windows-v0.1.3-preview.1", "scope": "fresh GitHub-hosted Windows VM with CPU",
              "physical_device": "NOT RUN", "consumer_hardware": "NOT TESTED", "voice_quality": "NOT EVALUATED"}
    save_result(root, report)
    installer = root / "verified-installer.exe"
    request = urllib.request.Request(INSTALLER_URL, headers={"User-Agent": "BookPocketOpen-HostedSetupSmoke/1"})
    with urllib.request.urlopen(request, timeout=60) as response, installer.open("wb") as output:
        shutil.copyfileobj(response, output)
    require(hashlib.sha256(installer.read_bytes()).hexdigest() == INSTALLER_SHA256, "Published installer checksum mismatch")
    report["phase"] = "installer_run"
    save_result(root, report)
    bundle = root / "installed"
    subprocess.run([str(installer), "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/SP-", "/NOICONS",
                    "/NOCLOSEAPPLICATIONS", "/NORESTARTAPPLICATIONS", f"/DIR={bundle}"], check=True)
    require((bundle / "tools/ffmpeg-provenance.json").exists(), "Installer did not provision verified media tools")
    subprocess.run([str(bundle / "runtime/python.exe"), "-I", str(Path(__file__).resolve()), "--runtime-child", "--root", str(root)], check=True)


def harmless_fixture(root, mode):
    """Local tests only: ordinary sleeping processes, never app imports/network."""
    wait_for_start(root)
    if mode == "breakaway":
        try:
            child = subprocess.Popen([sys.executable, "-I", "-c", "import time; time.sleep(.5)"], creationflags=subprocess.CREATE_BREAKAWAY_FROM_JOB)
        except OSError:
            return
        # Nested jobs may accept the creation flag while keeping the child in
        # this job. Require actual membership, not a particular Win32 error.
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenJobObjectW.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.LPCWSTR]
        kernel.OpenJobObjectW.restype = wintypes.HANDLE
        kernel.IsProcessInJob.argtypes = [wintypes.HANDLE, wintypes.HANDLE, ctypes.POINTER(wintypes.BOOL)]
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        handle = kernel.OpenJobObjectW(0x0004, False, os.environ["BOOKPOCKET_SMOKE_JOB"])
        require(handle, "Cannot inspect exact private job")
        try:
            contained = wintypes.BOOL()
            require(kernel.IsProcessInJob(int(child._handle), handle, ctypes.byref(contained)) and contained.value, "Child escaped its exact private job")
            child.wait(timeout=5)
        finally:
            kernel.CloseHandle(handle)
        return
    child = subprocess.Popen([sys.executable, "-I", "-c", "import time; time.sleep(.05)" if mode == "normal" else "import time; time.sleep(60)"])
    (root / "grandchild.pid").write_text(str(child.pid), encoding="ascii")
    if mode != "orphan":
        child.wait()


def cleanup_owned_root(root, parent, *, attempts=5, retry_delay=.5):
    """Remove only this fresh root; repair in-root read-only files, never links.

    rmtree removes Windows junctions and symlinks themselves without traversing
    their targets. Its error callback may chmod only a verified ordinary entry.
    Retries handle short-lived scanner/file locks after the owned job is empty.
    """
    root = root.absolute()
    parent = parent.resolve(strict=True)
    require(root.parent == parent and root.name.startswith("bookpocket-fresh-model-"), "Unsafe cleanup target")
    require(1 <= attempts <= 10 and 0 <= retry_delay <= 2, "Cleanup retry bound is invalid")
    outcome = {"removed": False, "attempts": 0, "read_only_repairs": 0, "last_error": None}

    def ordinary(path):
        value = path.lstat()
        return not stat.S_ISLNK(value.st_mode) and not getattr(value, "st_file_attributes", 0) & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)

    def repair(function, name, exception_info):
        error = exception_info[1]
        if isinstance(error, FileNotFoundError):
            return
        path = Path(name).absolute()
        # Check both the lexical path and all resolved ancestors before chmod.
        # An external junction target is never made writable to aid deletion.
        if (not path.is_relative_to(root) or not ordinary(path)
                or not path.resolve(strict=True).is_relative_to(root)):
            raise error
        mode = path.stat().st_mode
        if mode & stat.S_IWRITE:
            raise error  # A real lock/other error needs a bounded outer retry.
        path.chmod(mode | stat.S_IWRITE)
        outcome["read_only_repairs"] += 1
        if function not in (os.unlink, os.remove, os.rmdir):
            raise error
        function(name)

    for attempt in range(1, attempts + 1):
        outcome["attempts"] = attempt
        if not os.path.lexists(root):
            outcome["removed"] = True
            break
        # Recheck before every recursive removal, including after partial cleanup.
        require(ordinary(root) and root.resolve(strict=True) == root, "Cleanup root must not be a link or junction")
        try:
            shutil.rmtree(root, onerror=repair)
            outcome["removed"] = not os.path.lexists(root)
            if outcome["removed"]:
                break
        except OSError as error:
            outcome["last_error"] = {"type": type(error).__name__, "errno": error.errno,
                                     "winerror": getattr(error, "winerror", None)}
        if attempt < attempts:
            time.sleep(retry_delay)
    return outcome


def hosted(report_path):
    require(os.name == "nt" and os.environ.get("GITHUB_ACTIONS") == "true" and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted", "Cold setup is allowed only on a GitHub-hosted Windows runner")
    runner = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
    root = Path(tempfile.mkdtemp(prefix="bookpocket-fresh-model-", dir=runner)).resolve(strict=True)
    require(root.parent == runner and root.name.startswith("bookpocket-fresh-model-"), "Unexpected isolated root")
    require(not report_path.resolve().is_relative_to(root), "Report must live outside the disposable root")
    result = {"status": "failed", "phase": "watchdog_start"}
    started = time.monotonic()
    try:
        ownership = supervise([sys.executable, "-I", str(Path(__file__).resolve()), "--bootstrap-child", "--root", str(root)], root, isolated_environment(root))
        if (root / "result.json").exists():
            result = json.loads((root / "result.json").read_text(encoding="utf-8"))
        result["process_tree"] = ownership
        if ownership["exit_code"] != 0 or not ownership["normal_tree_exit"] or result.get("status") != "pass":
            result["status"] = "failed"
    except BaseException as error:
        result.update(status="failed", error_type=type(error).__name__)
    finally:
        # Only the verified, fresh direct child of RUNNER_TEMP is removed.
        require(root.parent == runner and root.name.startswith("bookpocket-fresh-model-"), "Unsafe cleanup target")
        cleanup = cleanup_owned_root(root, runner)
        result["cleanup"] = cleanup
        result["isolated_files_removed"] = cleanup["removed"]
        if not cleanup["removed"]:
            result["status"] = "failed"
        result["wall_seconds"] = round(time.monotonic() - started, 3)
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(result, indent=2))
    return 0 if result["status"] == "pass" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--hosted", action="store_true")
    modes.add_argument("--bootstrap-child", action="store_true")
    modes.add_argument("--runtime-child", action="store_true")
    modes.add_argument("--fixture-worker", choices=["normal", "hang", "orphan", "breakaway"])
    parser.add_argument("--root", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    if args.hosted:
        require(args.report is not None, "A sanitized report path is required")
        return hosted(args.report)
    require(args.root is not None, "An isolated child root is required")
    try:
        if args.bootstrap_child:
            bootstrap(args.root)
        elif args.runtime_child:
            runtime_probe(args.root)
        else:
            harmless_fixture(args.root, args.fixture_worker)
        return 0
    except BaseException as error:
        if args.fixture_worker:
            (args.root / "fixture-error.txt").write_text(type(error).__name__ + ": " + str(error), encoding="utf-8")
        else:
            path = args.root / "result.json"
            result = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
            result.update(status="failed", error_type=type(error).__name__)
            save_result(args.root, result)
        return 1  # Never print exception text containing local paths or responses.


if __name__ == "__main__":
    sys.exit(main())
