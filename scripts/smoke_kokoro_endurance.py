"""Opt-in real CPU rendering of an original, deterministic stress corpus.

Default: a small calibration. Use --words 50000 for a novel-sized render only
after inspecting the calibration. This is not a literary voice-quality test,
Kyon benchmark, restart/power-cycle test, or physical iPhone result. All mutable
state is isolated; existing public model files and the interpreter are read.
"""
import argparse
from collections import defaultdict
import ctypes
from ctypes import wintypes
import hashlib
import html
import io
import json
import math
import os
from pathlib import Path
import re
import secrets
import shutil
import stat
import subprocess
import tempfile
import time
import uuid
import zipfile

from fastapi.testclient import TestClient
from bookpocket_companion.app import create_app
from bookpocket_companion.engines import ManagedEngine, python_in
from bookpocket_companion.models import Config
from bookpocket_companion.render_workspace import PREFIX


def original_source(words, chapters):
    """Generate complete original paragraphs; never use a downloaded book."""
    places = ["observatory", "harbor", "garden", "workshop", "library", "bridge"]
    paragraphs, total = [], 0
    while total < words:
        number = len(paragraphs) + 1
        place = places[(number - 1) % len(places)]
        text = (
            f"At survey station {number}, Mira wrote a careful report about the {place} beyond the river. "
            "She compared the brass instrument with her paper map and marked the road that remained open. "
            "A patient companion carried the supplies while a small blue lamp lit their path through the evening. "
            "They checked each measurement together, recorded the changing weather, and returned every borrowed tool to its shelf. "
            "Before leaving, they read the complete report aloud and planned the next stage of their journey."
        )
        paragraphs.append(text)
        total += len(text.split())
    per_chapter = math.ceil(len(paragraphs) / chapters)
    groups = [paragraphs[index:index + per_chapter] for index in range(0, len(paragraphs), per_chapter)]
    titles = [f"Survey chapter {index + 1}" for index in range(len(groups))]
    manifest = "".join(f'<item id="c{i}" href="c{i}.xhtml" media-type="application/xhtml+xml"/>' for i in range(len(groups)))
    spine = "".join(f'<itemref idref="c{i}"/>' for i in range(len(groups)))
    navigation = "".join(f'<li><a href="c{i}.xhtml">{title}</a></li>' for i, title in enumerate(titles))
    result = io.BytesIO()
    with zipfile.ZipFile(result, "w") as archive:
        archive.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        archive.writestr("META-INF/container.xml", '<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
        archive.writestr("OEBPS/content.opf", f'<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="book">original-cpu-stress-corpus</dc:identifier><dc:title>Original CPU stress corpus</dc:title><dc:creator>Book Pocket Open contributors</dc:creator><dc:language>en</dc:language><meta property="dcterms:modified">2026-10-03T00:00:00Z</meta></metadata><manifest>{manifest}<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest><spine>{spine}</spine></package>')
        archive.writestr("OEBPS/nav.xhtml", f'<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol>{navigation}</ol></nav></body></html>')
        for index, (title, paragraphs) in enumerate(zip(titles, groups)):
            body = "".join(f"<p>{html.escape(text)}</p>" for text in paragraphs)
            archive.writestr(f"OEBPS/c{index}.xhtml", f'<html xmlns="http://www.w3.org/1999/xhtml"><head><title>{title}</title></head><body><h1>{title}</h1>{body}</body></html>')
    return result.getvalue(), titles


def plain(path):
    metadata = path.lstat()
    return not stat.S_ISLNK(metadata.st_mode) and not getattr(metadata, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT


class ObservedKokoro(ManagedEngine):
    def __init__(self, root, installed):
        super().__init__(root, "kokoro")
        self.python = python_in(installed / "venv")
        self.inputs = defaultdict(list)
        self.store = None

    def environment(self):
        return {**super().environment(), "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
                "PYTHONDONTWRITEBYTECODE": "1", "OMP_NUM_THREADS": "2", "MKL_NUM_THREADS": "2", "OPENBLAS_NUM_THREADS": "2"}

    def synthesize(self, text, voice, output, language="en"):
        if not output.parent.name.startswith(PREFIX):
            raise RuntimeError("Synthesis must use a registered render workspace")
        # The marker's first byte is held under an exclusive Windows file lease.
        # Read the registered identity from SQLite without opening that marker.
        with self.store.db() as database:
            identity = output.parent.name.removeprefix(PREFIX)
            row = database.execute("SELECT segment_id FROM render_workspaces WHERE id=?", (identity,)).fetchone()
            if not row:
                raise RuntimeError("Render workspace is not registered")
        self.inputs[row["segment_id"]].append(text)
        return super().synthesize(text, voice, output, language)


def checked(response, expected=200):
    if response.status_code != expected:
        raise RuntimeError(f"Unexpected benchmark API status {response.status_code}")
    return response.json()


def working_set(process):
    if os.name != "nt" or not process or process.poll() is not None:
        return None
    class Entry(ctypes.Structure):
        _fields_ = [("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD), ("th32ProcessID", wintypes.DWORD),
                   ("th32DefaultHeapID", ctypes.c_size_t), ("th32ModuleID", wintypes.DWORD), ("cntThreads", wintypes.DWORD),
                   ("th32ParentProcessID", wintypes.DWORD), ("pcPriClassBase", wintypes.LONG),
                   ("dwFlags", wintypes.DWORD), ("szExeFile", wintypes.WCHAR * 260)]
    class Counters(ctypes.Structure):
        _fields_ = [("cb", ctypes.c_ulong), ("PageFaultCount", ctypes.c_ulong),
                   *[(name, ctypes.c_size_t) for name in ["PeakWorkingSetSize", "WorkingSetSize", "QuotaPeakPagedPoolUsage", "QuotaPagedPoolUsage", "QuotaPeakNonPagedPoolUsage", "QuotaNonPagedPoolUsage", "PagefileUsage", "PeakPagefileUsage"]]]
    kernel = ctypes.windll.kernel32
    kernel.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
    kernel.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
    kernel.Process32FirstW.argtypes = kernel.Process32NextW.argtypes = [wintypes.HANDLE, ctypes.POINTER(Entry)]
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    snapshot = kernel.CreateToolhelp32Snapshot(2, 0)
    if snapshot in (None, ctypes.c_void_p(-1).value):
        raise RuntimeError("Cannot observe the owned model process tree")
    parents = {}
    try:
        entry = Entry()
        entry.dwSize = ctypes.sizeof(entry)
        more = kernel.Process32FirstW(snapshot, ctypes.byref(entry))
        while more:
            parents[entry.th32ProcessID] = entry.th32ParentProcessID
            more = kernel.Process32NextW(snapshot, ctypes.byref(entry))
    finally:
        kernel.CloseHandle(snapshot)
    owned = {process.pid}
    while True:
        expanded = owned | {pid for pid, parent in parents.items() if parent in owned}
        if expanded == owned:
            break
        owned = expanded
    total, observed = 0, 0
    for pid in owned:
        handle = kernel.OpenProcess(0x0400 | 0x0010, False, pid)
        if not handle:  # A short-lived child may exit between snapshot and read.
            continue
        try:
            counters = Counters()
            counters.cb = ctypes.sizeof(counters)
            if ctypes.windll.psapi.GetProcessMemoryInfo(ctypes.c_void_p(handle), ctypes.byref(counters), counters.cb):
                total += counters.WorkingSetSize
                observed += 1
        finally:
            kernel.CloseHandle(handle)
    if not observed:
        raise RuntimeError("No owned model process working set could be observed")
    # Current working sets summed across the owned launcher and its descendants.
    # This is sampled aggregate memory, not deduplicated/private process memory.
    return total, observed


def run(args):
    installed = args.engine_root.resolve(strict=True)
    version_file = installed / "venv/Lib/site-packages/torch/version.py"
    if not version_file.exists() or not re.search(r"cuda\s*(?::[^=]+)?=\s*None", version_file.read_text()):
        raise RuntimeError("This benchmark requires the existing CPU-only Torch runtime")
    cache = installed / "models/hub/models--hexgrad--Kokoro-82M"
    for path in [installed, cache, *cache.rglob("*")]:
        if not plain(path):
            raise RuntimeError("Public model cache must not contain symbolic links or junctions")
    args.report.parent.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(args.report.resolve().parent).free < 8 * 1024**3:
        raise RuntimeError("The isolated benchmark requires at least 8 GiB free space")
    started = time.monotonic()
    result = {"status": "incomplete", "requested_words": args.words, "corpus": "deterministic original stress prose", "physical_iphone_flow": "NOT RUN", "literary_voice_quality": "NOT EVALUATED", "restart_or_power_cycle": "NOT RUN"}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="bookpocket-cpu-endurance-", dir=args.report.resolve().parent) as temporary:
        root = Path(temporary)
        assert root.resolve(strict=True).parent == args.report.resolve().parent
        assert root.name.startswith("bookpocket-cpu-endurance-") and plain(root)
        engine_root = root / "engines/kokoro"
        (engine_root / "models/hub").mkdir(parents=True)
        shutil.copyfile(installed / "ready.json", engine_root / "ready.json")
        shutil.copytree(cache, engine_root / "models/hub" / cache.name)
        engine = ObservedKokoro(root / "engines", installed)
        config = Config(data_dir=root, dev=True, admin_token=secrets.token_urlsafe(32), ffmpeg=str(args.ffmpeg))
        app = create_app(config, engines={engine.id: engine})
        engine.store = app.state.store
        peak_memory, model_processes, next_report = None, 0, 0
        try:
            with TestClient(app, client=("127.0.0.1", 1234)) as api:
                version = checked(api.get("/v1/health"))["version"]
                admin = {"Authorization": "Bearer " + config.admin_token}
                ticket = checked(api.post("/v1/admin/pairing-tickets", headers=admin))
                pending = checked(api.post("/v1/pairings", json={"code": ticket["code"], "device_name": "Isolated CPU endurance benchmark"}))
                checked(api.post(f'/v1/admin/pairings/{pending["id"]}/approve', headers=admin))
                approval = checked(api.get(f'/v1/pairings/{pending["id"]}', headers={"Authorization": "Bearer " + pending["poll_token"]}))
                device = {"Authorization": "Bearer " + approval["device_token"]}
                source, titles = original_source(args.words, args.chapters)
                book = checked(api.post("/v1/books", headers=device, files={"file": ("original-stress.epub", source, "application/epub+zip")}))
                segments = [segment for chapter in book["chapters"] for segment in chapter["segments"]]
                actual_words = sum(len(segment["text"].split()) for segment in segments)
                assert actual_words >= args.words and [chapter["title"] for chapter in book["chapters"]] == titles
                request = {"request_id": str(uuid.uuid4()), "book_id": book["id"], "segment_ids": [s["id"] for s in segments], "engine": "kokoro", "voice_id": "kokoro:af_heart", "announce_chapters": False}
                job_id = checked(api.post("/v1/jobs", headers=device, json=request), 202)["id"]
                deadline = time.monotonic() + args.minutes * 60
                while True:
                    job = checked(api.get("/v1/jobs/" + job_id, headers=device))
                    observed = working_set(engine.process)
                    if observed is not None:
                        peak_memory = max(peak_memory or 0, observed[0])
                        model_processes = max(model_processes, observed[1])
                        if observed[0] > args.model_memory_mib * 1024**2:
                            raise RuntimeError("Owned model working sets exceeded the explicit memory bound")
                    if time.monotonic() >= next_report:
                        stored_bytes = sum(path.stat().st_size for path in root.rglob("*") if path.is_file())
                        if stored_bytes > args.storage_gib * 1024**3:
                            raise RuntimeError("Isolated benchmark storage exceeded its explicit bound")
                        print(json.dumps({"completed_segments": job["completed_segments"], "total_segments": len(segments), "wall_seconds": round(time.monotonic() - started, 1)}), flush=True)
                        next_report = time.monotonic() + 30
                    if job["status"] == "completed":
                        break
                    if job["status"] in {"failed", "cancelled"}:
                        result["job_error"] = job.get("error")
                        raise RuntimeError("Real CPU render did not complete; inspect the isolated failure report")
                    if time.monotonic() > deadline:
                        raise RuntimeError("Real CPU render exceeded the bounded deadline")
                    time.sleep(.5)
                assert job["completed_segments"] == len(segments) and len(job["assets"]) == len(segments)
                assert [asset["segment_id"] for asset in job["assets"]] == request["segment_ids"]
                assert len({asset["id"] for asset in job["assets"]}) == len(segments)
                assert api.get(f'/v1/books/{book["id"]}/source', headers=device).content == source
                assert checked(api.post("/v1/jobs", headers=device, json=request), 202)["assets"] == job["assets"]
                for segment, asset in zip(segments, job["assets"]):
                    # Independent coverage check: no production sentence splitter is used.
                    assert re.sub(r"\s", "", "".join(engine.inputs[segment["id"]])) == re.sub(r"\s", "", segment["text"])
                    assert (asset["source_start"], asset["source_end"]) == (0, len(segment["text"]))
                    assert asset["timings"] and all(0 <= t["start_offset"] < t["end_offset"] <= len(segment["text"]) for t in asset["timings"])
                    response = api.get(asset["url"], headers=device)
                    assert response.status_code == 200 and api.get(asset["url"]).status_code == 401
                    assert len(response.content) == asset["bytes"] and hashlib.sha256(response.content).hexdigest() == asset["sha256"]
                    checked_wav = root / "checked.wav"
                    checked_wav.write_bytes(response.content)
                    subprocess.run([str(args.ffmpeg), "-v", "error", "-i", str(checked_wav), "-f", "null", "-"], capture_output=True, check=True, timeout=120)
                    checked_wav.unlink()
                export = checked(api.post(f"/v1/jobs/{job_id}/export", headers=device, json={"format": "m4b"}))
                response = api.get(export["url"], headers=device)
                assert response.status_code == 200 and api.get(export["url"]).status_code == 401
                assert len(response.content) == export["bytes"] and hashlib.sha256(response.content).hexdigest() == export["sha256"]
                output = root / "complete.m4b"
                output.write_bytes(response.content)
                probe = json.loads(subprocess.check_output([str(args.ffprobe), "-v", "error", "-show_streams", "-show_format", "-show_chapters", "-of", "json", str(output)], timeout=120))
                audio_seconds = sum(a["duration"] for a in job["assets"])
                assert probe["streams"][0]["codec_name"] == "aac"
                assert [c["tags"]["title"] for c in probe["chapters"]] == titles
                assert abs(float(probe["format"]["duration"]) - audio_seconds) < .15
                cursor = 0.0
                for actual, chapter in zip(probe["chapters"], book["chapters"]):
                    assert abs(float(actual["start_time"]) - cursor) < .15
                    ids = {s["id"] for s in chapter["segments"]}
                    cursor += sum(a["duration"] for a in job["assets"] if a["segment_id"] in ids)
                    assert abs(float(actual["end_time"]) - cursor) < .15
                subprocess.run([str(args.ffmpeg), "-v", "error", "-i", str(output), "-f", "null", "-"], capture_output=True, check=True, timeout=max(120, int(audio_seconds)))
                assert not any(p.is_dir() for p in (root / "assets").iterdir())
                result.update(status="pass", companion_version=version, engine="real managed Kokoro CPU", actual_words=actual_words, chapters=len(titles), assets=len(segments), synthesis_calls=sum(map(len, engine.inputs.values())), exact_original_input_coverage="pass", source_and_pairing_preserved="pass", authenticated_assets_and_full_decode="pass", m4b_contiguous_chapters="pass", scratch_cleanup="pass", audio_seconds=audio_seconds, m4b_bytes=export["bytes"], m4b_sha256=export["sha256"], peak_observed_model_tree_working_set_bytes=peak_memory, max_model_processes_observed=model_processes)
        except BaseException as error:
            result["error_type"] = type(error).__name__
            raise
        finally:
            app.state.worker.close()
            engine.close()
            result["wall_seconds"] = round(time.monotonic() - started, 3)
            args.report.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
            print(json.dumps(result, indent=2), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--engine-root", type=Path, required=True, help="Existing validated CPU-only Kokoro directory")
    parser.add_argument("--ffmpeg", type=Path, required=True)
    parser.add_argument("--ffprobe", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--words", type=int, default=500)
    parser.add_argument("--chapters", type=int, default=2)
    parser.add_argument("--minutes", type=int, default=10)
    parser.add_argument("--model-memory-mib", type=int, default=2048)
    parser.add_argument("--storage-gib", type=int, default=8)
    args = parser.parse_args()
    if not 500 <= args.words <= 60000 or not 1 <= args.chapters <= 32 or not 1 <= args.minutes <= 240:
        parser.error("Use 500–60000 words, 1–32 chapters and a 1–240 minute deadline")
    if not 1024 <= args.model_memory_mib <= 4096 or not 2 <= args.storage_gib <= 16:
        parser.error("Use a 1024–4096 MiB model working-set bound and 2–16 GiB storage bound")
    run(args)
