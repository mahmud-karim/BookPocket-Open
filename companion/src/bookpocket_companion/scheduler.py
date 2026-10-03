"""One FIFO lease for actual model work, independent of visible job status."""
from collections import deque
from contextlib import contextmanager
import threading
import time


class WorkCancelled(RuntimeError):
    pass


class WorkOwnershipUncertain(RuntimeError):
    pass


class WorkScheduler:
    def __init__(self, prepare=None):
        self.stopped = threading.Event()
        self.stop_reason = "The companion is shutting down; restart it before submitting new work"
        self.condition = threading.Condition()
        self.waiting = deque()
        self.owner = None
        self.threads = set()
        self.prepare = prepare

    @contextmanager
    def lease(self, kind, cancelled=lambda: False):
        ticket = object()
        acquired = False
        with self.condition:
            self.waiting.append(ticket)
            try:
                while True:
                    if self.stopped.is_set(): raise WorkCancelled(self.stop_reason)
                    if cancelled(): raise WorkCancelled("Work stopped before model admission")
                    if self.owner is None and self.waiting[0] is ticket:
                        self.waiting.popleft()
                        self.owner = ticket
                        acquired = True
                        break
                    self.condition.wait(.1)
            finally:
                if not acquired:
                    self.waiting.remove(ticket)
                    self.condition.notify_all()
        try:
            if self.prepare: self.prepare(kind)
            yield
        except WorkOwnershipUncertain:
            self.close("Model shutdown could not be confirmed. Check that the setup or model process has stopped, then restart the companion")
            raise
        finally:
            with self.condition:
                self.owner = None
                self.condition.notify_all()

    def start_thread(self, target, name):
        def run():
            try: target()
            finally:
                with self.condition:
                    self.threads.discard(threading.current_thread())
                    self.condition.notify_all()
        thread = threading.Thread(target=run, daemon=True, name=name)
        with self.condition:
            if self.stopped.is_set(): raise WorkCancelled(self.stop_reason)
            self.threads.add(thread)
        try: thread.start()
        except BaseException:
            with self.condition: self.threads.discard(thread)
            raise
        return thread

    def close(self, reason=None):
        with self.condition:
            if reason and not self.stopped.is_set(): self.stop_reason = reason
            self.stopped.set()
            self.condition.notify_all()

    def join(self, timeout=5):
        deadline = time.monotonic() + timeout
        with self.condition: threads = list(self.threads)
        for thread in threads:
            if thread.ident is not None:
                thread.join(max(0, deadline - time.monotonic()))
