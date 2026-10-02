"""Download verified upstream media tools; our installers do not redistribute them."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import tempfile
import urllib.request
import zipfile

def install(destination, config, archive=None):
    spec = json.loads(config.read_text(encoding="utf-8-sig"))["ffmpeg"]
    destination = destination.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="bookpocket-media-") as temporary:
        if archive is None:
            archive = Path(temporary) / "ffmpeg.zip"
            request = urllib.request.Request(spec["url"], headers={"User-Agent": "BookPocketOpen-Setup/1"})
            print("Downloading media tools directly from the upstream publisher...", flush=True)
            with urllib.request.urlopen(request, timeout=60) as response, archive.open("wb") as output:
                shutil.copyfileobj(response, output)
        with archive.open("rb") as downloaded:
            if hashlib.file_digest(downloaded, "sha256").hexdigest() != spec["sha256"]:
                raise ValueError("FFmpeg checksum mismatch; nothing was installed")
        with zipfile.ZipFile(archive) as source:
            if source.testzip() is not None: raise ValueError("Damaged archive")
            required, found = {"ffmpeg.exe", "ffprobe.exe", "LICENSE.txt"}, {}
            for info in source.infolist():
                name = PurePosixPath(info.filename)
                if name.is_absolute() or ".." in name.parts or chr(92) in info.filename:
                    raise ValueError("Unsafe upstream archive path")
                if name.name in required:
                    if name.name in found: raise ValueError("Duplicate upstream media file")
                    found[name.name] = info
            if set(found) != required: raise ValueError("Upstream archive lacks tools or license")
            for name, info in found.items():
                target = destination / ("FFmpeg-LICENSE.txt" if name == "LICENSE.txt" else name)
                with source.open(info) as input_file, target.open("wb") as output:
                    shutil.copyfileobj(input_file, output)
        (destination / "ffmpeg-provenance.json").write_text(json.dumps(spec, indent=2), encoding="utf-8")
    print("Media tools installed and verified.", flush=True)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--config", type=Path, default=Path(__file__).with_name("windows-runtime.json"))
    parser.add_argument("--archive", type=Path)
    args = parser.parse_args()
    install(args.destination, args.config, args.archive)
