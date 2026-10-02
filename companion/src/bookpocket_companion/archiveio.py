"""Bounded, streaming archive I/O for portable whole-book recordings."""
import hashlib
import io
from pathlib import Path
import shutil

MAX_ARCHIVE = 16 * 1024**3
MAX_EXPANDED = 32 * 1024**3
MAX_ASSET = 512 * 1024**2
DISK_RESERVE = 256 * 1024**2
CHUNK = 1024**2


def stream_for(content):
    return io.BytesIO(content) if isinstance(content, bytes) else content


def file_digest(source):
    if isinstance(source, (str, Path)):
        with open(source, "rb") as stream: return file_digest(stream)
    position = source.tell()
    source.seek(0)
    value = hashlib.sha256()
    try:
        while chunk := source.read(CHUNK): value.update(chunk)
    finally: source.seek(position)
    return value.hexdigest()


def require_disk(directory, needed):
    if shutil.disk_usage(directory).free < needed + DISK_RESERVE:
        raise ValueError("Not enough free disk space for this archive and the 256 MiB safety reserve")


def copy_member(archive, name, destination, limit):
    info = archive.getinfo(name)
    if info.file_size > limit: raise ValueError("Archive recording exceeds the per-file size limit")
    count, checksum = 0, hashlib.sha256()
    with archive.open(name) as source, open(destination, "wb") as output:
        while chunk := source.read(CHUNK):
            count += len(chunk)
            if count > limit: raise ValueError("Archive recording exceeds the per-file size limit")
            checksum.update(chunk)
            output.write(chunk)
    return count, checksum.hexdigest()
