#!/usr/bin/env python3
"""Portable reference-fixture integrity screen; never executes or attests Swift.
This small independent binary walk checks the frozen original Java observations
against Python's zlib/strict UTF-16. It is not a product importer or compatibility
oracle for malformed UMDs; those rejections are explicitly project policy.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import struct
import zlib

IDS = ("chinese-two-chapters", "cross-compression-blocks", "multi-chapter-optional-metadata",
       "non-bmp-utf16", "paragraph-separators")
NAMES = {2: "title", 3: "author", 4: "year", 5: "month", 6: "day", 7: "bookType", 8: "bookMan", 9: "shopKeeper"}
class FixtureError(ValueError): pass

def require(value, message):
    if not value: raise FixtureError(message)

def strict_json(data):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, "duplicate JSON key")
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=pairs,
                      parse_constant=lambda _: (_ for _ in ()).throw(FixtureError("nonfinite JSON")))

def walk(data):
    """Independent bounded walk for the five frozen writer-format fixtures."""
    require(len(data) <= 64 * 1024 * 1024 and data[:4] == bytes.fromhex("899b9ade"), "magic/input")
    cursor = 4; records = 0; section = None; key = None
    metadata = {}; offsets = []; titles = []; chunks = []; chunk_ids = []; indexed = False; finished = False; total = None
    while cursor < len(data):
        records += 1; require(records <= 65536, "record budget")
        start = cursor
        if data[cursor] == 35:
            require(cursor + 5 <= len(data), "short header")
            kind, flag, length = struct.unpack_from("<HBB", data, cursor + 1)
            require(length >= 5 and length <= len(data) - cursor, "section length")
            body = data[cursor + 5:cursor + length]; cursor += length
            if kind == 1:
                require(start == 4 and flag == 0 and len(body) == 3 and body[0] == 1, "text header")
            elif kind in NAMES:
                require(flag == 0 and kind not in metadata and total is None, "metadata")
                metadata[kind] = body.decode("utf-16-le", errors="strict")
            elif kind == 11:
                require(flag == 0 and len(body) == 4 and total is None, "total header")
                total, = struct.unpack("<I", body)
                require(0 < total <= 32 * 1024 * 1024 and total % 2 == 0, "output budget")
            elif kind in (131, 132, 129):
                require(len(body) == 4 and flag == (0 if kind == 131 else 1), "key header")
                key, = struct.unpack("<I", body)
                require(total is not None, "missing total")
            elif kind == 241:
                require(section == 132 and flag == 0 and body == bytes(16) and chunks, "nonzero license/unknown key")
            elif kind == 12:
                require(flag == 1 and len(body) == 4 and struct.unpack("<I", body)[0] == len(data)
                        and cursor == len(data) and indexed, "end marker")
                finished = True
            else: raise FixtureError("unsupported record")
            if kind != 241: section = kind
        elif data[cursor] == 36:
            require(cursor + 9 <= len(data), "short additional")
            identifier, length = struct.unpack_from("<II", data, cursor + 1)
            require(length >= 9 and length <= len(data) - cursor, "additional length")
            body = data[cursor + 9:cursor + length]; cursor += length
            if section == 131:
                require(identifier == key and not offsets and body and len(body) % 4 == 0, "offset table")
                require(len(body) // 4 <= 16384, "chapter budget")
                offsets = list(struct.unpack("<" + "I" * (len(body) // 4), body))
            elif section == 132 and identifier == key:
                require(not titles and not chunks, "duplicate titles")
                pos = 0
                for _ in offsets:
                    require(pos < len(body), "title length")
                    count = body[pos]; pos += 1
                    require(count <= len(body) - pos, "title truncation")
                    titles.append(body[pos:pos + count].decode("utf-16-le", errors="strict")); pos += count
                require(pos == len(body), "title tail")
            elif section == 132:
                require(titles and identifier not in chunk_ids and not indexed, "chunk identity")
                decoder = zlib.decompressobj()
                remaining = total - sum(map(len, chunks))
                raw = decoder.decompress(body, remaining + 1)
                require(len(raw) <= remaining and decoder.eof and not decoder.unused_data and not decoder.unconsumed_tail,
                        "zlib checksum/wrapper/size/tail")
                require(raw, "empty chunk")
                chunks.append(raw); chunk_ids.append(identifier)
            elif section == 129:
                require(identifier == key and not indexed and len(body) == len(chunks) * 4, "chunk index")
                require(list(struct.unpack("<" + "I" * len(chunks), body)) == chunk_ids[::-1], "chunk index identity")
                indexed = True
            else: raise FixtureError("unexpected additional")
        else: raise FixtureError("record marker")
    raw = b"".join(chunks)
    require(finished and len(raw) == total and offsets and offsets[0] == 0 and len(offsets) == len(titles), "incomplete content")
    chapters = []
    for index, (offset, title) in enumerate(zip(offsets, titles)):
        end = offsets[index + 1] if index + 1 < len(offsets) else total
        require(offset % 2 == 0 and end % 2 == 0 and 0 <= offset <= end <= total, "offset range")
        content = raw[offset:end]
        chapters.append(dict(title=title, offset=offset, raw=content, text=content.decode("utf-16-le", errors="strict").replace("\u2029", "\n")))
    return metadata, chapters

def inspect(root):
    manifest = strict_json((root / "provenance.json").read_bytes())
    expected_paths = {f"{identifier}/{name}" for identifier in IDS for name in ("fixture.umd", "reader-output.json")}
    files = manifest["files"]
    require(len(files) == 10 and {entry["path"] for entry in files} == expected_paths, "exact manifest file identity")
    require(len({entry["path"] for entry in files}) == len(files), "duplicate manifest path")
    for entry in files:
        data = (root / entry["path"]).read_bytes()
        require(len(data) == entry["bytes"] and hashlib.sha256(data).hexdigest() == entry["sha256"], "fixture digest")
    chapter_count = 0
    for identifier in IDS:
        folder = root / identifier
        golden = strict_json((folder / "reader-output.json").read_bytes())
        metadata, chapters = walk((folder / "fixture.umd").read_bytes())
        require(golden["id"] == identifier, "golden identity")
        require(type(golden["chapterCount"]["value"]) is int and len(chapters) == golden["chapterCount"]["value"], "chapter count")
        require(len(golden["chapters"]) == len(chapters), "golden row count")
        for key, name in NAMES.items(): require(metadata.get(key) == golden["metadata"][name]["value"], "metadata getter")
        for index, (chapter, observation) in enumerate(zip(chapters, golden["chapters"])):
            require(type(observation["index"]) is int and observation["index"] == index, "chapter identity")
            require(type(observation["offset"]["value"]) is int and chapter["offset"] == observation["offset"]["value"], "raw byte offset")
            require(chapter["title"] == observation["title"]["value"], "title getter")
            require(chapter["raw"] == base64.b64decode(observation["rawContent"]["valueBase64"], validate=True), "raw getter")
            require(chapter["text"] == observation["getContentString"]["value"], "public content getter")
        require(sum(len(chapter["raw"]) for chapter in chapters) == golden["totalContentLength"]["value"], "total getter")
        chapter_count += len(chapters)
    require(chapter_count == 15, "exact matrix")
    return dict(scope="portable fixture/reference integrity only", fixtures=5, chapters=15,
                fixtureIntegrityValidated=True, swiftExecuted=0, iOSExecuted=0,
                malformedPolicy="project strict subset, no original Java malformed outcomes asserted")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(inspect(args.root), ensure_ascii=False, indent=2))
