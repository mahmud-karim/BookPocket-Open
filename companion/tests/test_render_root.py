"""Safe canonical render roots, including packaged Windows path redirection."""
import os
from pathlib import Path
import subprocess

import pytest

from bookpocket_companion.render_workspace import _assets_root, render_workspace, cleanup_abandoned_renders
from bookpocket_companion.store import Store, canonical


def emulate_redirect(monkeypatch, configured, canonical_root, *, same_identity=True):
    """Emulate OS path virtualization; never create an actual redirect in user data."""
    original_resolve, original_samefile = Path.resolve, Path.samefile
    def resolve(path, *args, **kwargs):
        if path.is_relative_to(configured): return canonical_root / path.relative_to(configured)
        return original_resolve(path, *args, **kwargs)
    def samefile(path, other):
        if path == configured and Path(other) == canonical_root: return same_identity
        return original_samefile(path, other)
    monkeypatch.setattr(Path, "resolve", resolve)
    monkeypatch.setattr(Path, "samefile", samefile)


def test_redirected_root_renders_and_cleans_only_owned_workspace(tmp_path, monkeypatch):
    store = Store(tmp_path / "configured-library")
    configured = store.root / "assets"
    physical = tmp_path / "package-local-cache" / "assets"
    physical.mkdir(parents=True)
    emulate_redirect(monkeypatch, configured, physical)
    assert configured.resolve(strict=True) != configured.absolute()  # Prior rejection.
    assert _assets_root(store) == physical
    durable = physical / "durable.wav"
    durable.write_bytes(b"original indexed recording fixture")
    unknown = physical / "user-notes.txt"
    unknown.write_bytes(b"preserve unowned content")
    with store.db() as db:
        db.execute("INSERT INTO assets VALUES(?,?,?,?)", ("durable", "fixture", canonical({"id": "durable"}), str(durable)))
    with render_workspace(store, "fixture-job", "fixture-segment") as workspace:
        assert workspace.parent == physical
        (workspace / "0-raw.wav").write_bytes(b"original scratch fixture")
        assert cleanup_abandoned_renders(store) == 0  # Live marker remains leased.
    assert not workspace.exists()
    with store.db() as db:
        assert db.execute("SELECT count(*) FROM render_workspaces").fetchone()[0] == 0
    assert durable.read_bytes() == b"original indexed recording fixture"
    assert unknown.read_bytes() == b"preserve unowned content"
    assert store.item("assets", "durable") is not None


def test_indexed_logical_alias_path_preserves_canonical_workspace(tmp_path, monkeypatch):
    store = Store(tmp_path / "configured-library")
    configured = store.root / "assets"
    physical = tmp_path / "package-local-cache" / "assets"
    physical.mkdir(parents=True)
    emulate_redirect(monkeypatch, configured, physical)
    with render_workspace(store, "fixture-job", "fixture-segment") as workspace:
        recording = workspace / "0-raw.wav"
        recording.write_bytes(b"indexed original fixture")
        logical_recording = configured / workspace.name / recording.name
        with store.db() as db:
            db.execute("INSERT INTO assets VALUES(?,?,?,?)", ("indexed", "fixture", canonical({"id": "indexed"}), str(logical_recording)))
    assert recording.read_bytes() == b"indexed original fixture"
    assert cleanup_abandoned_renders(store) == 0
    # Removing the fixture index proves it was the resolved reference which
    # protected the workspace, rather than a broken redirected cleanup path.
    with store.db() as db: db.execute("DELETE FROM assets WHERE id='indexed'")
    assert cleanup_abandoned_renders(store) == 1
    assert not workspace.exists()


def test_different_directory_identity_is_rejected(tmp_path, monkeypatch):
    store = Store(tmp_path / "library")
    other = tmp_path / "other-assets"
    other.mkdir()
    emulate_redirect(monkeypatch, store.root / "assets", other, same_identity=False)
    with pytest.raises(ValueError, match="configured directory"):
        with render_workspace(store, "job", "segment"): pytest.fail("Must not enter an unverified root")
    assert list(other.iterdir()) == []


def test_parent_traversal_is_rejected(tmp_path):
    (tmp_path / "intermediate").mkdir()
    store = Store(tmp_path / "intermediate" / ".." / "library")
    with pytest.raises(ValueError, match="parent traversal"): _assets_root(store)


def test_canonical_ancestor_link_is_rejected_even_with_matching_identity(tmp_path, monkeypatch):
    store = Store(tmp_path / "library")
    outside = tmp_path / "outside"
    (outside / "assets").mkdir(parents=True)
    sentinel = outside / "assets" / "0-raw.wav"
    sentinel.write_bytes(b"outside fixture must remain")
    link = tmp_path / "canonical-link"
    if os.name == "nt":
        result = subprocess.run(["cmd.exe", "/c", "mklink", "/J", str(link), str(outside)], capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
    else:
        link.symlink_to(outside, target_is_directory=True)
    emulate_redirect(monkeypatch, store.root / "assets", link / "assets")
    with pytest.raises(ValueError, match="symbolic links or junctions"): _assets_root(store)
    assert sentinel.read_bytes() == b"outside fixture must remain"
