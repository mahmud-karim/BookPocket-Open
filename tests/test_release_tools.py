"""Regression checks for media provenance and release artifact rejection boundaries."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import struct
import wave
import zipfile
import pytest

ROOT = Path(__file__).resolve().parents[1]

def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def test_original_media_reproducibility_and_integrity():
    generator = module("generate_fixtures")
    provenance = json.loads((ROOT / "tests/fixtures/media-provenance.json").read_text())["sha256"]
    for name, data in [("lantern.epub", generator.build_epub()), ("test-tone.wav", generator.build_wav())]:
        assert (ROOT / "tests/fixtures" / name).read_bytes() == data
        assert hashlib.sha256(data).hexdigest() == provenance[name]
    with zipfile.ZipFile(io.BytesIO(generator.build_epub())) as archive:
        assert archive.namelist()[0] == "mimetype"
        assert archive.getinfo("mimetype").compress_type == zipfile.ZIP_STORED
        assert archive.testzip() is None
    with wave.open(io.BytesIO(generator.build_wav())) as audio:
        assert (audio.getframerate(), audio.getnframes(), audio.getnchannels()) == (24000, 6000, 1)


def mach_o(platform=2, cpu=0x0100000C):
    return struct.pack("<8I", 0xFEEDFACF, cpu, 0, 2, 1, 24, 0, 0) + struct.pack("<6I", 0x32, 24, platform, 0, 0, 0)


def ipa_fixture(tmp_path, platform=2, metadata_platform="iphoneos", cpu=0x0100000C):
    path = tmp_path / "BookPocketOpen.ipa"
    metadata = {"CFBundleIdentifier": "org.bookpocket.open", "CFBundleExecutable": "BookPocketOpen", "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1", "DTPlatformName": metadata_platform, "UIDeviceFamily": [1, 2], "MinimumOSVersion": "18.0"}
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("Payload/BookPocketOpen.app/Info.plist", plistlib.dumps(metadata))
        archive.writestr("Payload/BookPocketOpen.app/BookPocketOpen", mach_o(platform, cpu))
    checksum = tmp_path / "BookPocketOpen.ipa.sha256"
    checksum.write_text(hashlib.sha256(path.read_bytes()).hexdigest() + "  BookPocketOpen.ipa\n")
    return path, checksum


def test_device_verifier_reads_architecture_and_version(tmp_path):
    path, checksum = ipa_fixture(tmp_path)
    report = module("verify_ipa").verify_ipa(path, checksum, version="v0.1.0")
    assert report["application"]["platform"] == "iphoneos"
    assert report["physical_device_validation"] == "NOT RUN"


@pytest.mark.parametrize("kwargs", [{"platform": 7}, {"cpu": 0x01000007}, {"metadata_platform": "iphonesimulator"}])
def test_verifier_rejects_simulator_and_wrong_architecture(tmp_path, kwargs):
    path, checksum = ipa_fixture(tmp_path, **kwargs)
    with pytest.raises(ValueError):
        module("verify_ipa").verify_ipa(path, checksum)


def test_verifier_rejects_corruption_and_wrong_version(tmp_path):
    path, checksum = ipa_fixture(tmp_path)
    verifier = module("verify_ipa")
    with pytest.raises(ValueError, match="version"):
        verifier.verify_ipa(path, checksum, version="v9.9.9")
    path.write_bytes(path.read_bytes() + b"changed")
    with pytest.raises(ValueError, match="checksum"):
        verifier.verify_ipa(path, checksum)


def test_verifier_rejects_truncated_load_command():
    with pytest.raises(ValueError, match="length"):
        module("verify_ipa").macho_device(mach_o()[:-1], 2)


def test_privacy_preflight_detects_unapproved_recording(tmp_path, monkeypatch):
    directory = tmp_path / "tests/fixtures"
    directory.mkdir(parents=True)
    (directory / "media-provenance.json").write_text('{"sha256":{}}')
    (tmp_path / "private.wav").write_bytes(b"private voice")
    auditor = module("public_preflight")
    monkeypatch.setattr(auditor.subprocess, "check_output", lambda *a, **k: b"private.wav\0")
    assert "non-fixture" in auditor.audit(tmp_path)[0]


def test_media_setup_verifies_checksum_before_installing(tmp_path):
    setup = module("setup_media")
    archive = tmp_path / "media.zip"
    with zipfile.ZipFile(archive, "w") as output:
        output.writestr("upstream/bin/ffmpeg.exe", b"test binary fixture only")
        output.writestr("upstream/bin/ffprobe.exe", b"test binary fixture only")
        output.writestr("upstream/LICENSE.txt", "Test license fixture")
    config = tmp_path / "runtime.json"
    spec = {"sha256": "0" * 64, "url": "https://unreachable.invalid/test.zip"}
    config.write_text(json.dumps({"ffmpeg": spec}))
    destination = tmp_path / "tools"
    with pytest.raises(ValueError, match="checksum"):
        setup.install(destination, config, archive)
    assert not list(destination.iterdir())
    spec["sha256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
    config.write_text(json.dumps({"ffmpeg": spec}))
    setup.install(destination, config, archive)
    assert (destination / "FFmpeg-LICENSE.txt").read_text() == "Test license fixture"
    assert (destination / "ffmpeg.exe").read_bytes() == b"test binary fixture only"
    assert json.loads((destination / "ffmpeg-provenance.json").read_text())["sha256"] == spec["sha256"]
