"""Exact-handle Windows containment for model setup and its descendants."""
import ctypes
from ctypes import wintypes
import os
import subprocess
import shutil
import time
from .scheduler import WorkOwnershipUncertain


class WindowsSetupTree:
    def __init__(self, command, stdin, stdout, stderr, env=None, cwd=None):
        import _winapi
        import msvcrt
        self.api = _winapi
        self.process = self.thread = self.job = None
        self.kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        k = self.kernel
        k.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
        k.CreateJobObjectW.restype = wintypes.HANDLE
        k.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
        k.QueryInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD, ctypes.c_void_p]
        k.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
        k.IsProcessInJob.argtypes = [wintypes.HANDLE, wintypes.HANDLE, ctypes.POINTER(wintypes.BOOL)]
        k.TerminateJobObject.argtypes = [wintypes.HANDLE, wintypes.UINT]
        k.CloseHandle.argtypes = [wintypes.HANDLE]
        k.ResumeThread.argtypes = [wintypes.HANDLE]
        k.ResumeThread.restype = wintypes.DWORD

        class BasicLimits(ctypes.Structure):
            _fields_ = [("ProcessTime", ctypes.c_int64), ("JobTime", ctypes.c_int64), ("Flags", wintypes.DWORD),
                        ("MinWorkingSet", ctypes.c_size_t), ("MaxWorkingSet", ctypes.c_size_t), ("ActiveLimit", wintypes.DWORD),
                        ("Affinity", ctypes.c_size_t), ("Priority", wintypes.DWORD), ("Scheduling", wintypes.DWORD)]
        class Limits(ctypes.Structure):
            _fields_ = [("Basic", BasicLimits), ("IO", ctypes.c_uint64 * 6), ("Memory", ctypes.c_size_t * 4)]
        class Accounting(ctypes.Structure):
            _fields_ = [("Times", ctypes.c_int64 * 4), ("PageFaults", wintypes.DWORD), ("Total", wintypes.DWORD),
                        ("Active", wintypes.DWORD), ("Terminated", wintypes.DWORD)]
        self.accounting = Accounting
        try:
            self.job = k.CreateJobObjectW(None, None)
            self.check(self.job)
            limits = Limits()
            limits.Basic.Flags = 0x2000  # KILL_ON_JOB_CLOSE, neither breakaway mode.
            self.check(k.SetInformationJobObject(self.job, 9, ctypes.byref(limits), ctypes.sizeof(limits)))
            handles = [msvcrt.get_osfhandle(file.fileno()) for file in (stdin, stdout, stderr)]
            startup = subprocess.STARTUPINFO()
            startup.dwFlags = subprocess.STARTF_USESTDHANDLES
            startup.hStdInput, startup.hStdOutput, startup.hStdError = handles
            startup.lpAttributeList = {"handle_list": list(set(handles))}
            try:
                for handle in set(handles): os.set_handle_inheritable(handle, True)
                executable = str(command[0])
                if not os.path.dirname(executable):
                    executable = shutil.which(executable, path=(env or os.environ).get("PATH")) or executable
                self.process, self.thread, self.pid, _ = _winapi.CreateProcess(
                    executable, subprocess.list2cmdline(command), None, None, True,
                    subprocess.CREATE_NO_WINDOW | 0x00000004, env, str(cwd) if cwd else None, startup)
            finally:
                for handle in set(handles): os.set_handle_inheritable(handle, False)
            # No interpreter, pip helper or model code runs before containment.
            self.check(k.AssignProcessToJobObject(self.job, self.process))
            contained = wintypes.BOOL()
            self.check(k.IsProcessInJob(self.process, self.job, ctypes.byref(contained)))
            self.check(contained.value)
            if k.ResumeThread(self.thread) != 1: raise RuntimeError("Setup thread was not suspended")
            _winapi.CloseHandle(self.thread)
            self.thread = None
        except BaseException:
            if self.process and self.poll() is None:
                _winapi.TerminateProcess(self.process, 1)
            self.close()
            raise

    @staticmethod
    def check(result):
        if not result: raise ctypes.WinError(ctypes.get_last_error())

    def poll(self):
        if self.api.WaitForSingleObject(self.process, 0) == self.api.WAIT_OBJECT_0:
            return self.api.GetExitCodeProcess(self.process)
        return None

    def close(self):
        try:
            if self.job:
                self.check(self.kernel.TerminateJobObject(self.job, 1))
                deadline = time.monotonic() + 5
                while True:
                    counts = self.accounting()
                    self.check(self.kernel.QueryInformationJobObject(self.job, 1, ctypes.byref(counts), ctypes.sizeof(counts), None))
                    if not counts.Active: break
                    if time.monotonic() >= deadline: raise WorkOwnershipUncertain("Owned setup process tree did not stop; restart the companion after checking the setup process")
                    time.sleep(.02)
        except OSError as exc:
            raise WorkOwnershipUncertain("Unable to confirm setup process-tree shutdown") from exc
        finally:
            for name in ("thread", "process", "job"):
                handle = getattr(self, name)
                if handle:
                    self.api.CloseHandle(handle)
                    setattr(self, name, None)
