import hashlib
import io
import zipfile
import pytest
from bookpocket_companion.archiveio import CHUNK, copy_member, file_digest, require_disk


def test_stream_hash_restores_position_without_unbounded_reads():
    class Bounded(io.BytesIO):
        def read(self, size=-1):
            assert 0 < size <= CHUNK
            return super().read(size)
    content = b"book audio" * 400000
    stream = Bounded(content)
    stream.seek(17)
    assert file_digest(stream) == hashlib.sha256(content).hexdigest()
    assert stream.tell() == 17


def test_member_limits_checked_before_writing_and_disk_reserve(tmp_path, monkeypatch):
    source = io.BytesIO()
    with zipfile.ZipFile(source, "w") as archive: archive.writestr("audio.wav", b"12345")
    with zipfile.ZipFile(source) as archive:
        with pytest.raises(ValueError, match="per-file"):
            copy_member(archive, "audio.wav", tmp_path / "out", 4)
        assert not (tmp_path / "out").exists()
        size, checksum = copy_member(archive, "audio.wav", tmp_path / "out", 5)
        assert size == 5 and checksum == hashlib.sha256(b"12345").hexdigest()
    from collections import namedtuple
    usage = namedtuple("usage", "total used free")
    monkeypatch.setattr("bookpocket_companion.archiveio.shutil.disk_usage", lambda _: usage(1000, 900, 100))
    with pytest.raises(ValueError, match="free disk"):
        require_disk(tmp_path, 50)
