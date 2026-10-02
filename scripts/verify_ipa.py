"""Check downloaded IPA bytes, device architecture, platform and archive integrity."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import struct
import zipfile


def macho_device(data: bytes, expected_kind: int) -> dict:
    if len(data) < 32:
        raise ValueError("Truncated Mach-O executable")
    magic, cpu, _, kind, count, size, _, _ = struct.unpack_from("<8I", data)
    if (magic, cpu, kind) != (0xFEEDFACF, 0x0100000C, expected_kind):
        raise ValueError("Expected thin ARM64 Mach-O of correct executable type")
    cursor, platform = 32, None
    for _ in range(count):
        if cursor + 8 > len(data):
            raise ValueError("Truncated load command")
        command, length = struct.unpack_from("<2I", data, cursor)
        if length < 8 or cursor + length > len(data):
            raise ValueError("Invalid load command length")
        if command == 0x32:
            if length < 24:
                raise ValueError("Truncated LC_BUILD_VERSION")
            platform = struct.unpack_from("<I", data, cursor + 8)[0]
        cursor += length
    if cursor != 32 + size or platform != 2:
        raise ValueError("Expected iPhoneOS device platform, not simulator")
    return {"architecture": "arm64", "platform": "iphoneos"}


def verify_ipa(path: Path, checksum: Path, bundle_id: str = "org.bookpocket.open", version: str | None = None) -> dict:
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != checksum.read_text().split()[0]:
        raise ValueError("Downloaded IPA checksum mismatch")
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if archive.testzip() is not None:
            raise ValueError("ZIP integrity failure")
        if len(names) != len(set(names)) or any(n.startswith("/") or ".." in PurePosixPath(n).parts for n in names):
            raise ValueError("Unsafe or duplicated ZIP member")
        apps = {n.split("/")[1] for n in names if n.startswith("Payload/") and len(n.split("/")) > 2 and n.split("/")[1].endswith(".app")}
        if len(apps) != 1:
            raise ValueError("Expected one Payload application")
        prefix = f"Payload/{apps.pop()}/"
        plist = plistlib.loads(archive.read(prefix + "Info.plist"))
        if plist.get("CFBundleIdentifier") != bundle_id or plist.get("DTPlatformName") != "iphoneos":
            raise ValueError("Unexpected bundle ID or platform")
        if version and plist.get("CFBundleShortVersionString") != version.removeprefix("v"):
            raise ValueError("Release tag does not match app version")
        if not {1, 2}.issubset(set(plist.get("UIDeviceFamily", []))):
            raise ValueError("App must support both iPhone and iPad")
        if any(n.endswith("embedded.mobileprovision") for n in names):
            raise ValueError("Unexpected provisioning profile in unsigned release")
        executable = plist["CFBundleExecutable"]
        if "/" in executable or "\\" in executable:
            raise ValueError("Invalid executable name")
        application = macho_device(archive.read(prefix + executable), 2)
        frameworks = {}
        for name in names:
            if name.startswith(prefix + "Frameworks/") and name.endswith(".framework/Info.plist"):
                metadata = plistlib.loads(archive.read(name))
                binary = name.removesuffix("Info.plist") + metadata["CFBundleExecutable"]
                frameworks[binary] = macho_device(archive.read(binary), 6)
    return {"file": path.name, "bytes": path.stat().st_size, "sha256": digest, "zip_integrity": "pass", "bundle_id": bundle_id, "version": plist["CFBundleShortVersionString"], "build": plist["CFBundleVersion"], "minimum_ios": plist.get("MinimumOSVersion"), "application": application, "frameworks": frameworks, "physical_device_validation": "NOT RUN"}

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--checksum", type=Path)
    parser.add_argument("--version")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    report = verify_ipa(args.ipa, args.checksum or args.ipa.with_suffix(".ipa.sha256"), version=args.version)
    if args.report:
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
