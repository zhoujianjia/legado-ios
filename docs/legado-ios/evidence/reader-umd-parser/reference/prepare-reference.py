#!/usr/bin/env python3
"""Compile the pinned original Java UMD library and freeze five owned reference cases.

No product integration, alternative parser, malformed compressed input, network, or retry.
Every generated output is exclusive; a second invocation refuses the existing run directory.
"""
from __future__ import annotations

import base64
import hashlib
import json
import shutil
import subprocess
import sys
import time
import zipfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent.parent
SOURCE_ZIP = Path("F:/legado-master.zip")
SOURCE_SHA = "724dedcac2427cd1f02ca00af1eab7156146e6d9d3141ca4c92042d04ed7bcdd"
ZIP_PREFIX = "legado-master/modules/book/src/main/java/"
PACKAGE = "me/ag2s/umdlib/"
ENTRIES = [PACKAGE + value for value in (
    "domain/UmdBook.java", "domain/UmdChapters.java", "domain/UmdCover.java",
    "domain/UmdEnd.java", "domain/UmdHeader.java", "tool/StreamReader.java",
    "tool/UmdUtils.java", "tool/WrapOutputStream.java", "umd/UmdReader.java",
)]
JDK = REPO / ".tools/jdk21/jdk-21.0.12.1+1"
RUN = ROOT / "run"
COMMANDS: list[dict] = []


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def new_bytes(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("xb") as stream:
        stream.write(data)


def new_json(path: Path, value: object) -> None:
    new_bytes(path, (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))


def relative(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def run_command(name: str, args: list[str], timeout: int) -> None:
    started = datetime.now(timezone.utc).isoformat()
    before = time.monotonic()
    timed_out = False
    try:
        result = subprocess.run(args, cwd=ROOT, capture_output=True, timeout=timeout, check=False)
        stdout, stderr, code = result.stdout, result.stderr, result.returncode
    except subprocess.TimeoutExpired as error:
        stdout, stderr, code = error.stdout or b"", error.stderr or b"", None
        timed_out = True
    stdout_path = RUN / "logs" / f"{name}.stdout.txt"
    stderr_path = RUN / "logs" / f"{name}.stderr.txt"
    new_bytes(stdout_path, stdout)
    new_bytes(stderr_path, stderr)
    command = {
        "name": name, "argv": args, "cwd": str(ROOT), "startedAtUTC": started,
        "durationSeconds": round(time.monotonic() - before, 6),
        "timeoutSeconds": timeout, "timedOut": timed_out, "exitCode": code,
        "stdout": relative(stdout_path), "stderr": relative(stderr_path),
    }
    COMMANDS.append(command)
    new_json(RUN / "commands" / f"{name}.json", command)
    if timed_out or code != 0:
        raise RuntimeError(f"{name} failed: timeout={timed_out}, exit={code}; raw logs retained")


def meta(title: str, author: str | None) -> dict:
    return dict(title=title, author=author, year=None, month=None, day=None,
                bookType=None, bookMan=None, shopKeeper=None)


def chapter(title: str, content: str) -> dict:
    return {"title": title, "content": content}


def expectations() -> list[dict]:
    """Independent owned inputs; no UMD parsing and no reading back writer internals."""
    optional = meta("可选元数据", "")
    optional.update(year="2026", month="10", day="19", bookType="自有文本", shopKeeper="公开样本")
    return [
        dict(id="chinese-two-chapters", metadata=meta("自有中文样本", "公开测试作者"), chapters=[
            chapter("第一章 初见", "山川与星光。\n这是第一章的自有文字。"),
            chapter("第二章 归途", "清风经过书页。\n故事在这里结束。")]),
        dict(id="paragraph-separators", metadata=meta("段落分隔符", "测试作者"), chapters=[
            chapter("段落一", "甲\u2029乙\n丙\r\n丁\u2029"),
            chapter("段落二", "\u2029开头与结尾\u2029"),
            chapter("段落三", "普通换行\n保留；回车\r保留。")]),
        dict(id="non-bmp-utf16", metadata=meta("星空😀", "作者𠀀"), chapters=[
            chapter("第一章 😀", "汉字𠀀与表情😀，音乐符号𝄞。"),
            chapter("第二章 𠀀", "组合 e\u0301；火箭🚀\u2029下一段。")]),
        dict(id="multi-chapter-optional-metadata", metadata=optional, chapters=[
            chapter(f"章节 {i}", f"第{i}章自有内容。") for i in range(1, 6)]),
        dict(id="cross-compression-blocks", metadata=meta("跨压缩块", "测试作者"), chapters=[
            chapter("块边界一", "汉" * 16383 + "😀尾"),
            chapter("块边界二", "星\u2029" * 10000 + "𠀀"),
            chapter("块边界三", "末章\n完成。")]),
    ]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def verify_case(expected: dict) -> dict:
    case = RUN / "fixtures" / expected["id"]
    actual_input = json.loads((case / "fixture-input.json").read_text(encoding="utf-8"))
    require(actual_input == expected, f"{expected['id']}: Java input differs from independent owned expectation")
    actual = json.loads((case / "reader-output.json").read_text(encoding="utf-8"))
    require(actual["id"] == expected["id"], "case identity mismatch")
    require(actual["umdType"] == {"type": "java.lang.Byte", "value": 1}, "not text-type")
    require(actual["chapterCount"] == {"type": "java.lang.Integer", "value": len(expected["chapters"])}, "chapter count mismatch")
    require(len(actual["chapters"]) == len(expected["chapters"]), "chapter list mismatch")
    expected_metadata = {key: {"type": None if not value else "java.lang.String", "value": value or None}
                         for key, value in expected["metadata"].items()}
    require(actual["metadata"] == expected_metadata, "metadata mismatch (empty/null writer omission preserved)")
    offset = 0
    chapters = []
    for index, (original, read) in enumerate(zip(expected["chapters"], actual["chapters"], strict=True)):
        raw = original["content"].encode("utf-16le")
        display = original["content"].replace("\u2029", "\n")
        expected_raw_path = case / f"chapter-{index:02d}.expected.utf16le"
        expected_string_path = case / f"chapter-{index:02d}.expected-string.utf8"
        new_bytes(expected_raw_path, raw)
        new_bytes(expected_string_path, display.encode("utf-8"))
        require(read["index"] == index, "index mismatch")
        require(read["title"] == {"type": "java.lang.String", "value": original["title"]}, "title mismatch")
        require(read["offset"] == {"type": "java.lang.Integer", "value": offset}, "UTF-16LE byte offset mismatch")
        require(read["rawContent"]["type"] == "[B", "unexpected raw public return type")
        require(base64.b64decode(read["rawContent"]["valueBase64"], validate=True) == raw, "raw public bytes mismatch")
        require((case / read["rawContent"]["file"]).read_bytes() == raw, "raw byte file mismatch")
        require(read["getContentString"] == {"type": "java.lang.String", "value": display}, "public content string mismatch")
        require((case / read["stringFile"]).read_bytes() == display.encode("utf-8"), "public string file mismatch")
        chapters.append({
            "index": index, "title": original["title"], "offsetBytes": offset,
            "rawUTF16LEBytes": len(raw), "rawSHA256": hashlib.sha256(raw).hexdigest(),
            "publicStringType": read["getContentString"]["type"], "publicStringWasNull": False,
            "publicStringUTF8Bytes": len(display.encode("utf-8")),
            "publicStringSHA256": hashlib.sha256(display.encode("utf-8")).hexdigest(),
            "paragraphSeparatorCount": original["content"].count("\u2029"),
            "expectationMatchesOriginalReader": True,
        })
        offset += len(raw)
    require(actual["totalContentLength"] == {"type": "java.lang.Integer", "value": offset}, "total byte length mismatch")
    if expected["id"] == "cross-compression-blocks":
        require(offset > 65536, "cross-block owned input unexpectedly too small")
        first = expected["chapters"][0]["content"].encode("utf-16le")
        require(first[32766:32770] == "😀".encode("utf-16le"), "surrogate pair no longer crosses original chunk boundary")
    golden = {
        "id": expected["id"], "status": "matched-owned-expectations",
        "binary": {"path": relative(case / "fixture.umd"), "bytes": (case / "fixture.umd").stat().st_size,
                   "sha256": digest(case / "fixture.umd")},
        "chapterCount": len(chapters), "totalUTF16LEBytes": offset,
        "writerChunkSizeFromUnmodifiedSource": 32768,
        "expectedChunkCountFromOwnedInputAndOriginalWriter": (offset + 32767) // 32768,
        "metadataObservedWithTypeAndNull": actual["metadata"], "chapters": chapters,
        "actualPublicOutput": relative(case / "reader-output.json"),
        "independentOwnedInput": relative(case / "fixture-input.json"),
    }
    new_json(case / "golden-comparison.json", golden)
    return golden


def main() -> None:
    require(digest(SOURCE_ZIP) == SOURCE_SHA, "source ZIP SHA256 mismatch")
    require((JDK / "bin/java.exe").is_file() and (JDK / "bin/javac.exe").is_file(), "pinned existing JDK missing")
    RUN.mkdir(exist_ok=False)
    archived_zip = RUN / "original/legado-master.zip"
    archived_zip.parent.mkdir()
    with SOURCE_ZIP.open("rb") as source, archived_zip.open("xb") as target:
        shutil.copyfileobj(source, target)
    require(digest(archived_zip) == SOURCE_SHA, "copied source ZIP SHA mismatch")
    source_entries = []
    original_sources = []
    with zipfile.ZipFile(archived_zip) as archive:
        actual_entries = [name for name in archive.namelist()
                          if name.startswith(ZIP_PREFIX + PACKAGE) and name.endswith(".java")]
        require(sorted(actual_entries) == sorted(ZIP_PREFIX + name for name in ENTRIES), "original source entry set mismatch")
        for entry in ENTRIES:
            name = ZIP_PREFIX + entry
            data = archive.read(name)
            source_path = RUN / "sources/original" / entry
            new_bytes(source_path, data)
            require(source_path.read_bytes() == data, "original source extraction changed bytes")
            source_entries.append({"entry": name, "path": relative(source_path), "bytes": len(data),
                                   "sha256": hashlib.sha256(data).hexdigest(), "modified": False})
            original_sources.append(source_path)
    java = str(JDK / "bin/java.exe")
    javac = str(JDK / "bin/javac.exe")
    run_command("java-version", [java, "-version"], 10)
    run_command("javac-version", [javac, "-version"], 10)
    classes = RUN / "classes"
    classes.mkdir()
    harness_sources = [ROOT / "harness/androidx/annotation/NonNull.java", ROOT / "harness/UmdReferenceHarness.java"]
    run_command("compile-original-and-harness", [javac, "-encoding", "UTF-8", "-d", str(classes)] +
                [str(path) for path in original_sources + harness_sources], 30)
    (RUN / "fixtures").mkdir()
    goldens = []
    for case in expectations():
        run_command(case["id"], [java, "-Dfile.encoding=UTF-8", "-Dstdout.encoding=UTF-8", "-Dstderr.encoding=UTF-8",
                                "-cp", str(classes), "UmdReferenceHarness", case["id"],
                                str(RUN / "fixtures" / case["id"])], 20)
        goldens.append(verify_case(case))
    report = {
        "schemaVersion": 1, "createdAtUTC": datetime.now(timezone.utc).isoformat(),
        "status": "original-java-reference-executed-five-owned-fixtures-matched",
        "scope": "原版 Java 桌面公开 API 参考与自有文本 fixture；不是 UMD 产品支持验收。",
        "sourceZIP": {"original": str(SOURCE_ZIP), "archived": relative(archived_zip),
                      "sha256": SOURCE_SHA, "bytes": archived_zip.stat().st_size},
        "sourceEntries": source_entries,
        "harness": {"annotationStub": "harness/androidx/annotation/NonNull.java",
                    "stubScope": "annotation-only; no parser/writer/runtime business implementation",
                    "source": "harness/UmdReferenceHarness.java", "originalSourcesModified": False,
                    "rng": "Unmodified original java.util.Random; no seed injection/reflection. Frozen binaries have recorded SHA256; regenerated binaries need not match.",
                    "fixtureOwnership": "All titles, content and metadata self-authored for this bundle; no private source or user library was read."},
        "toolchain": {"jdkRoot": str(JDK), "javaSHA256": digest(JDK / "bin/java.exe"),
                      "javacSHA256": digest(JDK / "bin/javac.exe"), "releaseSHA256": digest(JDK / "release"),
                      "javaVersionRaw": "run/logs/java-version.stderr.txt",
                      "javacVersionRaw": "run/logs/javac-version.stdout.txt"},
        "commands": COMMANDS, "fixtures": goldens,
        "actualExecution": {"originalJavaCompileCommands": 1, "originalReaderFixtureProcesses": 5,
                            "originalWriterFixtureProcesses": 5, "matchedFixtureCount": 5,
                            "swiftTypecheck": 0, "iOSExecution": 0, "deviceExecution": 0,
                            "malformedCompressedInputs": 0, "retries": 0},
        "observedContract": [
            "章节 offset 是 UTF-16LE 原始字节偏移；每章原始字节与自有输入逐字节一致。",
            "getContentString 将 U+2029 替换为 LF；原始字节保留 U+2029；原有 LF/CR/CRLF 保留。",
            "原 writer 省略 null/空 metadata；原 reader 对这些缺省字段返回 Java null，类型/null 已保留。",
            "非 BMP 的 UTF-16 surrogate pair 可跨原 writer 的 32768 字节压缩块；reader 拼接后本次结果与预期一致。",
        ],
        "limits": [
            "不是 UMD 产品支持、MOBI、封面、DRM、导入重开、真机或法律清算证据。",
            "未修改 BookParserRegistry / LocalBookImportService；后续实现复用现有唯一导入链。",
            "仅 writer 生成的有效 text-type 输入。原 Inflater 缺少停滞保护，逐进程 timeout 用于防挂起；未运行畸形压缩输入。",
            "未来 Swift 的严格拒绝策略不能倒推为原 Java parser 已拒绝。",
            "annotation-only stub 只提供编译注解；未替换原 parser/writer 的任何执行逻辑。",
        ],
    }
    new_json(RUN / "reference-record.json", report)
    new_bytes(RUN / "toolchain-release.raw.txt", (JDK / "release").read_bytes())
    inventory = []
    for path in sorted(ROOT.rglob("*")):
        if path.is_file():
            inventory.append({"path": relative(path), "bytes": path.stat().st_size, "sha256": digest(path)})
    new_json(ROOT / "bundle-manifest.json", {"schemaVersion": 1, "files": inventory,
                                            "manifestExcludesItself": True})
    print(json.dumps({"status": report["status"], "fixtures": len(goldens),
                      "record": str(RUN / "reference-record.json"),
                      "recordSHA256": digest(RUN / "reference-record.json"),
                      "manifest": str(ROOT / "bundle-manifest.json"),
                      "manifestSHA256": digest(ROOT / "bundle-manifest.json")}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
