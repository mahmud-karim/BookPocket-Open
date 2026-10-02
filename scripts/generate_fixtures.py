"""Create original deterministic test media; never a narration engine."""
from __future__ import annotations
import hashlib
import io
import json
import math
from pathlib import Path
import struct
import wave
import zipfile

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests" / "fixtures"
CHAPTERS = [
    ("chapter1.xhtml", "The Lantern", ["Mira opened the brass lantern. A small blue light filled the room.", "“Can you hear me?” she asked. The answer arrived with a chime: “Yes, Mira.”", "A compass 🧭 pointed north; café bells sounded beyond the window."]),
    ("chapter2.xhtml", "Across the Bridge", ["At dawn, Mira crossed the bridge. Below her, the river carried leaves toward the sea.", "“We have time,” said Rowan. “Then let us walk,” Mira replied.", "The lantern dimmed, but its light never disappeared."]),
]

def build_epub() -> bytes:
    items = {
        "mimetype": "application/epub+zip",
        "META-INF/container.xml": '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
        "EPUB/package.opf": '''<?xml version="1.0" encoding="UTF-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="book-id">urn:bookpocket:original-lantern-fixture-v1</dc:identifier><dc:title>The Lantern — Test Edition</dc:title><dc:creator>Book Pocket Contributors</dc:creator><dc:language>en</dc:language><dc:rights>Original test text, Apache-2.0</dc:rights><meta property="dcterms:modified">2026-01-01T00:00:00Z</meta></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/><item id="c2" href="chapter2.xhtml" media-type="application/xhtml+xml"/><item id="style" href="style.css" media-type="text/css"/></manifest><spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>''',
        "EPUB/nav.xhtml": '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><h1>Contents</h1><ol><li><a href="chapter1.xhtml">The Lantern</a></li><li><a href="chapter2.xhtml">Across the Bridge</a></li></ol></nav></body></html>',
        "EPUB/style.css": "body { font-family: serif; line-height: 1.6; } h1 { margin-block: 2em; }",
    }
    for href, title, paragraphs in CHAPTERS:
        body = "".join(f'<p id="p{i}">{text}</p>' for i, text in enumerate(paragraphs))
        items[f"EPUB/{href}"] = f'<html xmlns="http://www.w3.org/1999/xhtml" lang="en"><head><title>{title}</title><link rel="stylesheet" href="style.css" type="text/css"/></head><body><section><h1>{title}</h1>{body}</section></body></html>'
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as archive:
        for name, text in items.items():
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_STORED if name == "mimetype" else zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, text.encode("utf-8"))
    return output.getvalue()

def build_wav() -> bytes:
    output = io.BytesIO()
    with wave.open(output, "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(24000)
        audio.writeframes(b"".join(struct.pack("<h", int(1600 * math.sin(2 * math.pi * 440 * n / 24000))) for n in range(6000)))
    return output.getvalue()

def main() -> None:
    FIXTURES.mkdir(parents=True, exist_ok=True)
    media = {"lantern.epub": build_epub(), "test-tone.wav": build_wav()}
    for name, data in media.items():
        (FIXTURES / name).write_bytes(data)
    (FIXTURES / "original.txt").write_text("The Lantern\n\n" + "\n\n".join(p for _, _, ps in CHAPTERS for p in ps) + "\n", encoding="utf-8", newline="\n")
    hashes = {name: hashlib.sha256(data).hexdigest() for name, data in media.items()}
    (FIXTURES / "media-provenance.json").write_text(json.dumps({"license": "Apache-2.0", "purpose": "Original test fixtures; tone is not speech", "sha256": hashes}, indent=2) + "\n", encoding="utf-8")

if __name__ == "__main__":
    main()
