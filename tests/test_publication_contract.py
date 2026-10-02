"""Cross-language source identities and hostile EPUB regression cases."""
import hashlib
import io
import json
from pathlib import Path
import zipfile
import pytest
from bookpocket_companion.publication import parse_book

FIXTURES = Path(__file__).parent / "fixtures"

def test_epub_import_preserves_source_identity_and_order():
    raw = (FIXTURES / "lantern.epub").read_bytes()
    book = parse_book(raw, "lantern.epub")
    assert book["source_sha256"] == hashlib.sha256(raw).hexdigest()
    assert book["title"] == "The Lantern — Test Edition"
    assert [c["title"] for c in book["chapters"]] == ["The Lantern", "Across the Bridge"]
    assert [c["href"] for c in book["chapters"]] == ["EPUB/chapter1.xhtml", "EPUB/chapter2.xhtml"]
    assert [len(c["segments"]) for c in book["chapters"]] == [4, 4]
    for chapter in book["chapters"]:
        for index, segment in enumerate(chapter["segments"]):
            expected = hashlib.sha256(f'{book["source_sha256"]}\n{chapter["href"]}\n{index}\n{segment["text"]}'.encode()).hexdigest()
            assert segment["id"] == expected
            assert segment["locator"]["href"] == chapter["href"]
            assert segment["locator"]["text"]["highlight"] == segment["text"]


def test_wire_fixture_matches_imported_unicode_segment():
    fixture = json.loads((FIXTURES / "contract-v1.json").read_text(encoding="utf-8"))
    book = parse_book((FIXTURES / "lantern.epub").read_bytes(), "lantern.epub")
    segment = book["chapters"][0]["segments"][3]
    expected = fixture["book"]["chapters"][0]["segments"][0]
    assert segment["id"] == expected["id"]
    case = fixture["unicode_case"]
    assert segment["text"][case["scalar_start"]:case["scalar_end"]] == case["expected_substring"]
    # Demonstrate why clients must translate Unicode scalar indices to UTF-16.
    assert len(case["expected_substring"].encode("utf-16-le")) // 2 == 2


def mutated_epub(name, content):
    output = io.BytesIO()
    with zipfile.ZipFile(FIXTURES / "lantern.epub") as original, zipfile.ZipFile(output, "w") as archive:
        for member in original.infolist():
            archive.writestr(member, original.read(member.filename))
        member = zipfile.ZipInfo('placeholder')
        member.filename = name
        member.orig_filename = name
        archive.writestr(member, content)
    return output.getvalue()


@pytest.mark.parametrize("name", ["../escape.xhtml", "/absolute.xhtml", "..\\windows.xhtml", "C:drive.xhtml"])
def test_unsafe_archive_member_rejected(name):
    with pytest.raises(ValueError, match="Unsafe"):
        parse_book(mutated_epub(name, "unsafe"), "book.epub")


def test_encrypted_book_rejected():
    encrypted = '<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><EncryptedData><EncryptionMethod Algorithm="urn:unsupported-drm"/></EncryptedData></encryption>'
    with pytest.raises(ValueError, match="DRM"):
        parse_book(mutated_epub("META-INF/encryption.xml", encrypted), "book.epub")


def test_txt_import_handles_unicode_and_blank_paragraphs():
    book = parse_book("Heading\n\n\nA compass 🧭\npoints north.\n\nCafé.".encode(), "original.txt")
    assert [s["text"] for s in book["chapters"][0]["segments"]] == ["Heading", "A compass 🧭 points north.", "Café."]
    with pytest.raises(ValueError, match="no readable text"):
        parse_book(b"\n \n", "empty.txt")


