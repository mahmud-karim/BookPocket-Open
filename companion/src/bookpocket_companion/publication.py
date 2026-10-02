"""Bounded EPUB ingestion with stable source spans and preserved originals."""
import io
import posixpath
import re
import zipfile
from pathlib import PurePosixPath
from urllib.parse import unquote
from defusedxml import ElementTree as ET
from .store import digest, now

IMPORT_VERSION = 1
MAX_EXPANDED = 250 * 1024 * 1024

def normalize(text):
    return re.sub(r"\s+", " ", text).strip()

def segment(source_hash, href, ordinal, text, kind="paragraph", title=None):
    text = normalize(text)
    return {"id": digest("\n".join([source_hash, href, str(ordinal), text])), "text": text, "kind": kind,
            "locator": {"href": href, "type": "application/xhtml+xml", "title": title,
                        "locations": {"position": ordinal + 1}, "text": {"highlight": text}}}

def parse_book(content, filename):
    source_hash = digest(content)
    title = PurePosixPath(filename).stem
    author, language, chapters = "Unknown author", "en", []
    if filename.lower().endswith(".txt"):
        text = content.decode("utf-8-sig")
        paragraphs = [normalize(p) for p in re.split(r"\n\s*\n", text) if normalize(p)]
        chapters = [{"id": digest(source_hash + "text"), "title": title, "href": "text.xhtml",
                     "segments": [segment(source_hash, "text.xhtml", i, p, title=title) for i, p in enumerate(paragraphs)]}]
    elif filename.lower().endswith(".epub"):
        with zipfile.ZipFile(io.BytesIO(content)) as archive:
            members = archive.infolist()
            if len(members) > 10000 or sum(m.file_size for m in members) > MAX_EXPANDED:
                raise ValueError("EPUB exceeds the expanded archive limit")
            seen = set()
            for member in members:
                name = member.filename
                if name in seen or name.startswith(("/", "\\")) or "\\" in name or ".." in PurePosixPath(name).parts or ":" in name:
                    raise ValueError("Unsafe or duplicate EPUB archive path")
                if member.flag_bits & 1 or ((member.external_attr >> 16) & 0o170000) == 0o120000:
                    raise ValueError("Encrypted or symbolic link archive entry is unsupported")
                seen.add(name)
            if "META-INF/encryption.xml" in seen:
                encryption = ET.fromstring(archive.read("META-INF/encryption.xml"))
                algorithms = [e.attrib.get("Algorithm", "") for e in encryption.iter() if e.tag.endswith("EncryptionMethod")]
                if any(a not in {"http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"} for a in algorithms):
                    raise ValueError("DRM-encrypted books are not supported")
            container = ET.fromstring(archive.read("META-INF/container.xml"))
            rootfile = next(e.attrib["full-path"] for e in container.iter() if e.tag.endswith("rootfile"))
            package = ET.fromstring(archive.read(rootfile))
            def metadata(key, default):
                return next((normalize(e.text or "") for e in package.iter() if e.tag == "{http://purl.org/dc/elements/1.1/}" + key and e.text), default)
            title, author, language = metadata("title", title), metadata("creator", author), metadata("language", language)
            manifest = {e.attrib["id"]: e.attrib for e in package.iter() if e.tag.endswith("}item")}
            for ref in (e for e in package.iter() if e.tag.endswith("}itemref") and e.attrib.get("linear") != "no"):
                item = manifest.get(ref.attrib["idref"], {})
                if item.get("media-type") not in {"application/xhtml+xml", "text/html"}:
                    continue
                href = unquote(item["href"].split("#")[0])
                path = posixpath.normpath(posixpath.join(posixpath.dirname(rootfile), href))
                if path.startswith("../") or path.startswith("/"):
                    raise ValueError("Invalid EPUB spine path")
                href = path
                doc = ET.fromstring(archive.read(path))
                texts = []
                block_tags = {"p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "pre"}
                def walk(element):
                    tag = element.tag.split("}")[-1]
                    if tag in {"script", "style", "head"}: return
                    if tag in block_tags and not any(c.tag.split("}")[-1] in block_tags for c in element.iter() if c is not element):
                        value = normalize("".join(element.itertext()))
                        if value: texts.append((value, "heading" if tag.startswith("h") else "paragraph"))
                        return
                    for child in element: walk(child)
                walk(doc)
                if not texts:
                    body = next((e for e in doc.iter() if e.tag.split("}")[-1] == "body"), doc)
                    value = normalize("".join(body.itertext()))
                    if value: texts = [(value, "paragraph")]
                chapter_title = next((t for t, k in texts if k == "heading"), f"Chapter {len(chapters)+1}")
                chapters.append({"id": digest(source_hash + "\n" + href), "title": chapter_title, "href": href,
                                 "segments": [segment(source_hash, href, i, text, kind, chapter_title) for i, (text, kind) in enumerate(texts)]})
    else:
        raise ValueError("Choose a DRM-free EPUB or UTF-8 TXT file")
    if not any(c["segments"] for c in chapters):
        raise ValueError("This publication contains no readable text")
    return {"id": source_hash, "title": title, "author": author, "language": language, "source_sha256": source_hash,
            "chapters": chapters, "created_at": now(), "import_version": IMPORT_VERSION}


def extract_cover(content):
    """Called only after archive validation; rasterize to a bounded safe JPEG."""
    from PIL import Image
    with zipfile.ZipFile(io.BytesIO(content)) as archive:
        container = ET.fromstring(archive.read("META-INF/container.xml"))
        rootfile = next(e.attrib["full-path"] for e in container.iter() if e.tag.endswith("rootfile"))
        package = ET.fromstring(archive.read(rootfile))
        cover_id = next((e.attrib.get("content") for e in package.iter() if e.tag.endswith("}meta") and e.attrib.get("name") == "cover"), None)
        item = next((e for e in package.iter() if e.tag.endswith("}item") and ("cover-image" in e.attrib.get("properties", "").split() or e.attrib.get("id") == cover_id)), None)
        if item is None: return None
        path = posixpath.normpath(posixpath.join(posixpath.dirname(rootfile), unquote(item.attrib["href"])))
        if archive.getinfo(path).file_size > 10 * 1024 * 1024: return None
        with Image.open(io.BytesIO(archive.read(path))) as image:
            if image.width * image.height > 20_000_000: return None
            image.thumbnail((800, 1200))
            output = io.BytesIO()
            image.convert("RGB").save(output, format="JPEG", quality=88)
            return output.getvalue()
