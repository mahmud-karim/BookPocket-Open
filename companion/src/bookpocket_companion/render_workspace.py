"""Identify and reclaim only this companion's abandoned render scratch files."""
from contextlib import contextmanager
import logging
import os
from pathlib import Path
import re
import stat
import uuid
from .store import canonical

PREFIX = "bookpocket-render-"
MARKER = ".bookpocket-render.json"
_AUDIO = re.compile(r"(?:joined|[0-9]+(?:-raw)?)\.wav\Z")
_LOG = logging.getLogger(__name__)


def _plain(path, directory=False):
    """lstat also rejects Windows junctions, not only symbolic links."""
    info = path.lstat()
    return (not stat.S_ISLNK(info.st_mode)
            and not getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT
            and (stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)))


def _assets_root(store):
    assets = (store.root / "assets").absolute()
    if ".." in assets.parts:
        raise ValueError("Render assets root must not contain parent traversal")
    for path in (assets, *assets.parents):
        if not _plain(path, directory=True):
            raise ValueError("Render assets root must not contain symbolic links or junctions")
    resolved = assets.resolve(strict=True)
    for path in (resolved, *resolved.parents):
        if not _plain(path, directory=True):
            raise ValueError("Render assets root must not contain symbolic links or junctions")
    # Windows packaged processes can transparently redirect LocalAppData without
    # a filesystem reparse point. Compare actual directory identity, not spelling;
    # use that verified canonical root for every subsequent workspace boundary.
    if not assets.samefile(resolved):
        raise ValueError("Render assets root did not resolve to its configured directory")
    return resolved


def _lock(file):
    file.seek(0)
    if os.name == "nt":
        import msvcrt
        msvcrt.locking(file.fileno(), msvcrt.LK_NBLCK, 1)
    else:
        import fcntl
        fcntl.flock(file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)


def _unlock(file):
    file.seek(0)
    if os.name == "nt":
        import msvcrt
        msvcrt.locking(file.fileno(), msvcrt.LK_UNLCK, 1)
    else:
        import fcntl
        fcntl.flock(file.fileno(), fcntl.LOCK_UN)


def _remove_registered(store, db, row):
    """No traversal or recursive deletion; unknown contents preserve the workspace."""
    assets = _assets_root(store)
    identity = row["id"]
    if str(uuid.UUID(identity)) != identity: return False
    workspace = assets / (PREFIX + identity)
    if not _plain(workspace, directory=True) or workspace.resolve(strict=True).parent != assets:
        return False
    # Hold the database write lock while checking references and deleting scratch files.
    for asset in db.execute("SELECT path FROM assets"):
        referenced = Path(asset["path"]).absolute().resolve(strict=False)
        if referenced == workspace or workspace in referenced.parents: return False
    entries = list(workspace.iterdir())
    if not entries or any(not _plain(p) or (p.name != MARKER and not _AUDIO.fullmatch(p.name)) for p in entries):
        return False
    marker = workspace / MARKER
    if marker.stat().st_size > 4096: return False
    with marker.open("r+b") as lease:
        try: _lock(lease)
        except OSError: return False  # The process that owns this workspace is still rendering.
        try:
            if lease.read(4097).decode("utf-8") != row["marker"]: return False
            for path in entries:
                if path.name == MARKER: continue
                # Recheck the complete boundary immediately before each file deletion.
                if _assets_root(store) != assets or not _plain(workspace, directory=True) or not _plain(path):
                    return False
                path.unlink()
        finally:
            _unlock(lease)
    # The marker is removed last: a failed/busy unlink leaves ownership evidence for next start.
    if _assets_root(store) != assets or not _plain(workspace, directory=True) or not _plain(marker): return False
    marker.unlink()
    workspace.rmdir()
    db.execute("DELETE FROM render_workspaces WHERE id=?", (identity,))
    return True


def cleanup_abandoned_renders(store, workspace_id=None):
    removed = 0
    with store.db() as db:
        db.execute("BEGIN IMMEDIATE")
        rows = db.execute("SELECT * FROM render_workspaces" + (" WHERE id=?" if workspace_id else ""),
                          (workspace_id,) if workspace_id else ()).fetchall()
        for row in rows:
            try: removed += int(_remove_registered(store, db, row))
            except (OSError, ValueError, TypeError):
                # Never make startup destructive or fail recovery because scratch files are unknown/busy.
                _LOG.warning("Preserved an unverified or busy render workspace")
    return removed


@contextmanager
def render_workspace(store, job_id, segment_id):
    assets = _assets_root(store)
    identity = str(uuid.uuid4())
    workspace = assets / (PREFIX + identity)
    marker = canonical({"format": "bookpocket-render-v1", "id": identity, "job_id": job_id, "segment_id": segment_id})
    lease = None
    try:
        # Keep registration, directory creation and live lease acquisition indivisible to startup cleanup.
        with store.db() as db:
            db.execute("BEGIN IMMEDIATE")
            db.execute("INSERT INTO render_workspaces VALUES(?,?,?,?)", (identity, job_id, segment_id, marker))
            workspace.mkdir()
            lease = (workspace / MARKER).open("x+b")
            lease.write(marker.encode("utf-8")); lease.flush(); os.fsync(lease.fileno())
            _lock(lease)
        yield workspace
    finally:
        if lease is not None: lease.close()  # Process death also releases this OS-held lease.
        cleanup_abandoned_renders(store, identity)
