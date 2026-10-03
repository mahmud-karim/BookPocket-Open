"""Harmless Windows process-tree checks; never install packages or launch models."""
import os
import ctypes
from ctypes import wintypes
from pathlib import Path
import sys
import time

import pytest
from test_release_tools import module


@pytest.mark.skipif(os.name != "nt", reason="Windows Job Object boundary")
@pytest.mark.parametrize("mode", ["normal", "hang", "orphan", "breakaway"])
def test_private_job_controls_children_and_grandchildren(tmp_path, mode):
    smoke = module("smoke_windows_model_setup")
    script = Path(smoke.__file__).resolve()
    result = smoke.supervise([sys.executable, "-I", str(script), "--fixture-worker", mode, "--root", str(tmp_path)],
                             tmp_path, dict(os.environ), seconds=2 if mode == "hang" else 10)
    assert result["assigned_before_start"] and result["kill_on_close"] and result["breakaway_disabled"]
    assert result["created_suspended"]
    assert result["active_processes_after"] == 0
    if mode in {"normal", "breakaway"}:
        error = tmp_path / "fixture-error.txt"
        assert result["normal_tree_exit"] and result["exit_code"] == 0 and not result["timed_out"], error.read_text() if error.exists() else result
    elif mode == "hang":
        assert result["timed_out"] and not result["normal_tree_exit"]
    else:
        assert result["orphaned_descendants"] and not result["normal_tree_exit"]
    if mode != "breakaway":
        assert result["total_owned_processes"] >= 2
        assert (tmp_path / "grandchild.pid").exists()


def test_cold_setup_refuses_local_development_host(monkeypatch, tmp_path):
    smoke = module("smoke_windows_model_setup")
    monkeypatch.delenv("GITHUB_ACTIONS", raising=False)
    with pytest.raises(RuntimeError, match="only on a GitHub-hosted"):
        smoke.hosted(tmp_path / "report.json")
    assert not (tmp_path / "report.json").exists()


@pytest.mark.skipif(os.name != "nt", reason="Windows Job Object boundary")
def test_closing_only_job_handle_kills_live_child_and_grandchild(tmp_path):
    smoke = module("smoke_windows_model_setup")
    job = smoke.WindowsJob()
    child = smoke.SuspendedProcess([sys.executable, "-I", str(Path(smoke.__file__).resolve()),
                                    "--fixture-worker", "hang", "--root", str(tmp_path)], tmp_path, dict(os.environ))
    grandchild = None
    kernel = job.kernel
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    try:
        job.assign(child)
        (tmp_path / "start.flag").write_text("assigned", encoding="ascii")
        child.resume()
        deadline = time.monotonic() + 10
        while not (tmp_path / "grandchild.pid").exists() and time.monotonic() < deadline:
            time.sleep(.05)
        grandchild = kernel.OpenProcess(0x100000 | 0x1000, False, int((tmp_path / "grandchild.pid").read_text()))
        assert grandchild
        contained = wintypes.BOOL()
        assert kernel.IsProcessInJob(grandchild, job.handle, ctypes.byref(contained)) and contained.value
        assert kernel.WaitForSingleObject(grandchild, 0) == 258  # Still sleeping.
        assert job.counts()["active"] >= 2
        assert child.poll() is None
        job.close()  # No TerminateProcess/TerminateJobObject: exercise handle loss.
        assert child.wait(timeout=10) is not None  # Windows chooses the close-job exit code.
        assert kernel.WaitForSingleObject(grandchild, 10000) == 0
    finally:
        job.close()
        child.wait(timeout=10)
        child.close()
        if grandchild:
            kernel.CloseHandle(grandchild)


@pytest.mark.parametrize("damage", ["nan", "out_of_duration", "empty", "source_reversed", "empty_interval"])
def test_runtime_timing_gate_rejects_bad_metadata(damage):
    smoke = module("smoke_windows_model_setup")
    asset = {"duration": 1.0, "timings": [{"start": 0., "end": .5, "start_offset": 0, "end_offset": 4}]}
    if damage == "nan":
        asset["timings"][0]["start"] = float("nan")
    elif damage == "out_of_duration":
        asset["timings"][0]["end"] = 2.
    elif damage == "empty":
        asset["timings"] = []
    elif damage == "empty_interval":
        asset["timings"][0]["end"] = 0.
    else:
        asset["timings"].append({"start": .5, "end": 1., "start_offset": 0, "end_offset": 4})
    with pytest.raises(RuntimeError):
        smoke.validate_timings(asset, "Mira walked.")


def test_runtime_timing_gate_accepts_bounded_original_intervals():
    smoke = module("smoke_windows_model_setup")
    smoke.validate_timings({"duration": 1., "timings": [
        {"start": 0., "end": .5, "start_offset": 0, "end_offset": 4},
        {"start": .45, "end": 1., "start_offset": 5, "end_offset": 11},
    ]}, "Mira walked.")
