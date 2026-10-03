"""Bounded setup subprocess trees with cooperative application shutdown."""
import contextlib
import os
import signal
import subprocess
import tempfile
import time
from .scheduler import WorkCancelled, WorkOwnershipUncertain


def run_setup(command, *, cancel_event=None, timeout=1800, input=None, check=True, capture_output=False,
              text=False, stdout=None, stderr=None, env=None, cwd=None):
    if cancel_event is not None and cancel_event.is_set(): raise WorkCancelled("Model setup stopped")
    with contextlib.ExitStack() as stack:
        # Files avoid pipe EOF depending on a surviving build-helper descendant.
        source = stack.enter_context(tempfile.TemporaryFile())
        if input is not None: source.write(input.encode("utf-8") if isinstance(input, str) else input)
        source.seek(0)
        output = stdout if stdout is not None else stack.enter_context(tempfile.TemporaryFile())
        errors = stderr if stderr is not None else stack.enter_context(tempfile.TemporaryFile())
        if os.name == "nt":
            from .setup_windows import WindowsSetupTree
            process = WindowsSetupTree(command, source, output, errors, env=env, cwd=cwd)
        else:
            process = subprocess.Popen(command, stdin=source, stdout=output, stderr=errors, env=env, cwd=cwd, start_new_session=True)
        deadline = time.monotonic() + timeout
        try:
            while process.poll() is None:
                if cancel_event is not None and cancel_event.is_set(): raise WorkCancelled("Model setup stopped")
                if time.monotonic() >= deadline: raise subprocess.TimeoutExpired(command, timeout)
                time.sleep(.1)
            returncode = process.poll()
        finally:
            if os.name == "nt":
                process.close()  # Exact owned job includes launcher/model/build descendants.
            else:
                try: os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired as exc: raise WorkOwnershipUncertain("Owned setup process did not stop") from exc
        captured = []
        for file in (output, errors):
            if capture_output:
                file.seek(0)
                value = file.read(4 * 1024**2 + 1)
                if len(value) > 4 * 1024**2: raise ValueError("Setup diagnostic output exceeds 4 MiB")
                captured.append(value.decode("utf-8", errors="replace") if text else value)
            else: captured.append(None)
        result = subprocess.CompletedProcess(command, returncode, *captured)
        if check: result.check_returncode()
        return result
