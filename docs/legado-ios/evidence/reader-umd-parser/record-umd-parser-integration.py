#!/usr/bin/env python3
"""Root-only once-only integration recorder draft. Do not import/run during preparation.

Run only after root review:
  python -X utf8 -B .build/renewal-discovery/record-umd-parser-integration.py
Reads the latest canonical at execution, verifies all frozen inputs before writing,
archives exact bytes, and changes only local-formats execution/evidence references.
No patch apply, test rerun, CI/network/signing/package action, git mutation or retry.
Existing/partial destinations refuse; root must remain the sole canonical writer.
"""
from datetime import datetime, timezone
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[2]
FROZEN = ROOT / ".build/reader-umd-worktree/.build"
REFERENCE = ROOT / ".build/umd-reference-preparation"
MAIN_LOG = ROOT / ".build/renewal-discovery/umd-main-verification"
DEST = ROOT / "docs/legado-ios/evidence/reader-umd-parser"
BATCH = ROOT / "docs/legado-ios/umd-parser-preparation-batch.json"
PLAN = ROOT / "docs/legado-ios/completion-plan.json"
WP = "local-formats"
REG = "umd-parser-preparation"
BASE_C = "1a87f6d57b2e3f215b86930fdfa75fdd52ce2e06"
A_RELEASE = "a76d380fdc108db83be68961905ee49edd209571"
EXCLUDED_ZIP = "run/original/legado-master.zip"
PINS = {
    "reader-umd-parser.patch": "50f5d84136eca006fdeea2cf0c151d39920673c1bc2e3e46759796fa02de1b21",
    "reader-umd-parser-preparation.json": "f5ffb5197a5ae2e346f15bb123c53278b7bd5da4a17cc8ebd78706b8996a6040",
    "umd-swift-grammar.json": "26a82a89599acfa5db6a975fd10316c35e7d2160d4d4242ecf668b4713f60995",
    "umd-checked-import-design.json": "ca28ae27078c5ca34dfc7d26bd1bb97c90e966d5d6728d635b2572b7537c2a11",
}
PARSER_REVIEW_PIN = "b0100254dcee408d9530f4ef23dee56cde2de17638a5628eac6bf2d491686898"
REFERENCE_REVIEW_PIN = "3052ffd6cea4918047cd5ddcf3c830f791ab8ccac69024ab570e155565467901"
REFERENCE_MANIFEST_PIN = "aa9b128ba7ff51e524af0ef1d905860d6599e9f71426bc484544ed1344110719"
REFERENCE_RECORD_PIN = "fde4be8b82780807741a2f19d3bc6bfbcedabfa6b74a41a74eeb6fdfc60c345a"
ZIP_PIN = "724dedcac2427cd1f02ca00af1eab7156146e6d9d3141ca4c92042d04ed7bcdd"
MAIN_PINS = {
    "portable": "d7ef727d5295c30a487e4807fb0dd85e079536ffc0eaa8a4f0a3ec3b1d035d6b",
    "getters": "69922887306ddad84471bcea7d1494f83e117e2f9e61ec714b25638dd7d64ae9",
    "reverse": "7691da7a088603c2f67f762ff2887ed4d0ab0434b9d121b20d4fd7408c980f13",
    "diff": "cae22a0b497249fc25349406a0524298daa6a46118df27ac0ba8bf7323980cf7",
}
METHODS = (
    "matchesOriginalJavaFixtures", "rejectsEveryTruncatedPrefix", "rejectsImagesKeysAndUnknownSections",
    "rejectsInvalidLengthsAndEndMarker", "rejectsInvalidChapterOffsets", "rejectsInvalidUTF16AndSurrogateBoundary",
    "rejectsCorruptedZlibAndUnconsumedTail", "rejectsMismatchedRecordIdentity", "enforcesAllBudgets",
    "observesCancellation", "fileParserRetainsSnapshotAndEnforcesInputBudget",
)
sys.dont_write_bytecode = True


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def rel(path):
    return path.relative_to(ROOT).as_posix()


def owned(path, missing=False):
    require(path.is_absolute() and path.is_relative_to(ROOT), "Path outside repository")
    for item in (path, *path.parents):
        try:
            info = item.lstat()
        except FileNotFoundError:
            require(missing, "Missing required path: " + str(item))
        else:
            require(not stat.S_ISLNK(info.st_mode) and not (getattr(info, "st_file_attributes", 0) & 0x400),
                    "Refusing symlink/junction/reparse path: " + str(item))
        if item == ROOT:
            break
    require(path.resolve(strict=not missing).is_relative_to(ROOT), "Resolved path outside repository")


def read(path):
    owned(path)
    require(path.is_file(), "Not a regular file: " + str(path))
    return path.read_bytes()


def parse(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "Duplicate JSON key: " + key)
            result[key] = value
        return result
    def nonfinite(value):
        raise ValueError("Nonfinite JSON value: " + value)
    return json.loads(data.decode("utf-8"), object_pairs_hook=unique, parse_constant=nonfinite)


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def exclusive(path, data):
    owned(path, missing=True)
    path.parent.mkdir(parents=True, exist_ok=True)
    owned(path.parent)
    with path.open("xb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    require(read(path) == data, "Written output differs: " + rel(path))


def safe_relative(value):
    require(isinstance(value, str) and "\\" not in value and ":" not in value, "Invalid relative path")
    path = PurePosixPath(value)
    require(not path.is_absolute() and bool(path.parts) and all(part not in (".", "..") for part in path.parts)
            and path.as_posix() == value, "Unsafe relative path: " + value)
    return Path(*path.parts)


def inventory(directory):
    owned(directory)
    pending, files = [directory], set()
    while pending:
        for path in pending.pop().iterdir():
            owned(path)
            if path.is_dir():
                pending.append(path)
            else:
                require(path.is_file(), "Nonregular reference member")
                files.add(path.relative_to(directory).as_posix())
    return files


def collect():
    items = []
    def add(source, name, digest, kind, expected_bytes=None):
        safe_relative(name)
        require(name not in {entry["name"] for entry in items}, "Duplicate evidence destination")
        data = read(source)
        require(re.fullmatch(r"[0-9a-f]{64}", digest) and sha(data) == digest, "Input SHA256 mismatch: " + rel(source))
        require(expected_bytes is None or len(data) == expected_bytes, "Input byte count mismatch: " + rel(source))
        items.append(dict(name=name, source=rel(source), path=rel(DEST / name), bytes=len(data), sha256=digest, kind=kind, data=data))
        return data
    frozen = {name: add(FROZEN / name, name, digest, "frozen-parser-preparation") for name, digest in PINS.items()}
    prep = parse(frozen["reader-umd-parser-preparation.json"])
    grammar = parse(frozen["umd-swift-grammar.json"])
    design = parse(frozen["umd-checked-import-design.json"])
    review = parse(add(ROOT / ".build/renewal-discovery/umd-parser-independent-review.json",
                       "umd-parser-independent-review.json", PARSER_REVIEW_PIN, "independent-static-parser-review"))
    require(prep["base"] == review["base"] == BASE_C and design["base"] == BASE_C, "Wrong parser baseline")
    require(design["status"] == "design-only-not-implemented", "Checked lease must remain design0")
    require(review["status"] == "no-unresolved-static-blocking-findings" and review["unresolvedBlockingFindings"] == [], "Parser review not clear")
    require(prep["patch"]["sha256"] == review["patch"]["sha256"] == PINS["reader-umd-parser.patch"], "Patch review binding mismatch")
    require(review["preparation"]["sha256"] == PINS["reader-umd-parser-preparation.json"], "Preparation review binding mismatch")
    fields = lambda value: {item["path"]: (item["bytes"], item["sha256"]) for item in value}
    manifest = fields(prep["files"])
    require(len(prep["files"]) == len(review["files"]) == len(manifest) == 16 and manifest == fields(review["files"]), "Wrong 16-file source inventory")
    for path, (size, digest) in manifest.items():
        safe_relative(path)
        data = read(ROOT / path)
        require((len(data), sha(data)) == (size, digest), "Root source differs from reviewed bytes: " + path)
    require(grammar["passed"] is True and len(grammar["files"]) == 3, "Wrong three-file grammar screen")
    for item in grammar["files"]:
        require(item["passed"] is True and item["errors"] == [] and manifest[item["path"]][1] == item["sha256"], "Grammar source mismatch")
    require(prep["plannedSwiftTests"] == dict(suite="UMDTextDecoderTests", methods=list(METHODS), count=11, executed=0,
        scope="real production decoder/file parser calls planned on Apple SDK; not a sourceguard substitute"), "Wrong planned Swift identities")
    require(review["SwiftTypecheckPerformed"] is False and review["AppleSDKCompilationPerformed"] is False
            and review["iOSTestsExecuted"] == 0 and review["productImportTOCReopenSupported"] is False, "Unsupported native/product claim")
    checks = prep["actualValidation"]
    require(checks["portableChecks"] == 12 and checks["swiftTypecheck"] == checks["swiftSDKBuild"] == checks["iOSExecution"] == 0,
            "Wrong original portable/native scope")
    accounting = review["evidenceAccounting"]
    author = accounting["authorEvidence"]
    require(accounting["authorPortableRawLogsHashVerified"] is True and accounting["actualSwiftMethodsExecuted"] == 0,
            "Wrong independent execution accounting")
    def bound(entry, name, kind):
        return add(Path(entry["path"]), name, entry["sha256"], kind, entry["bytes"])
    validation = parse(bound(author["validation"], "author/validation.json", "author-original-validation"))
    require(validation["patch"]["sha256"] == PINS["reader-umd-parser.patch"] and len(validation["commands"]) == 7, "Wrong original validation commands")
    require(validation["grammarPassed"] is True and validation["swiftSDKExecuted"] == validation["iOSExecuted"] == validation["deviceExecuted"] == 0,
            "Wrong original validation boundary")
    raw = {item["name"]: item for item in author["rawLogs"]}
    require(set(raw) == {item["name"] for item in validation["commands"]}, "Author command/log identity mismatch")
    for command in validation["commands"]:
        require(command["exitCode"] == 0, "Original author command failed")
        for channel in ("stdout", "stderr"):
            entry = raw[command["name"]][channel]
            require(Path(entry["path"]) == FROZEN.parent / command[channel], "Author raw path mismatch")
            bound(entry, "author/" + command["name"] + "." + channel, "author-original-raw-log")
    require(author["grammar"]["sha256"] == PINS["umd-swift-grammar.json"], "Independent grammar pin mismatch")
    bound(author["primaryIndex"], "primary/index.json", "zlib-primary-original-index")
    bound(author["primaryManual"], "primary/zlib-manual.html", "zlib-primary-original-manual")
    require(author["primaryIndex"]["sha256"] == prep["primaryAPI"]["sha256"]
            and author["primaryManual"]["sha256"] == prep["primaryAPI"]["reference"]["sha256"], "Primary/preparation mismatch")
    bound(accounting["reviewerIdentityCheck"], "independent/identity-check.json", "reviewer-original-identity-check")
    bound(accounting["reviewerChecker"], "independent/check-umd-parser-independent.py", "reviewer-checker-source")
    for item in accounting["reviewerLaunchRaw"]:
        bound(item, "independent/" + Path(item["path"]).name, "reviewer-original-launch-raw")
    for command in accounting["reviewerActualReadOnlyGitCommands"]:
        require(command["exitCode"] == 0, "Reviewer git command failed")
        for channel in ("stdout", "stderr"):
            bound(command[channel], "independent/" + command["name"] + "." + channel, "reviewer-original-git-raw")
    # Existing registry/import dispatch remain exactly the independently reviewed base bytes.
    base_commands = {item["name"]: item for item in accounting["reviewerActualReadOnlyGitCommands"]}
    for name, path in (("base-BookParsing", "Modules/Core/EPUB/BookParsing.swift"),
                       ("base-LocalBookImportService", "Modules/Services/LibraryStore/LocalBookImportService.swift")):
        require(read(ROOT / path) == read(Path(base_commands[name]["stdout"]["path"])),
                "Product registry/import dispatch changed; this unregistered-parser record needs review")
    expected_commands = {
        "portable": ["-B", "scripts/reader-experience/test-umd-fixtures.py", "-v"],
        "getters": ["-B", "scripts/reader-experience/inspect-umd-fixtures.py", "--root", "Tests/iOS/yuedu appTests/Fixtures/UMD"],
        "reverse": ["git", "apply", "--reverse", "--check", ".build/reader-umd-worktree/.build/reader-umd-parser.patch"],
        "diff": ["git", "diff", "--check"],
    }
    for name, digest in MAIN_PINS.items():
        record = parse(add(MAIN_LOG / (name + ".json"), "main/" + name + ".json", digest, "root-main-existing-verification"))
        require(record["group"] == name and record["exitCode"] == 0 and record["sourceFilesMatched"] == prep["files"]
                and record["SwiftSDKOrIOSTestsExecuted"] is False, "Wrong root verification source/result")
        expected = expected_commands[name]
        require((record["command"][1:] if name in ("portable", "getters") else record["command"]) == expected, "Wrong root command")
        require(record["portableUniqueChecks"] == (12 if name == "portable" else None)
                and record["getterIntegrityOnlyNotSwiftExecution"] is (name == "getters"), "Wrong root verification scope")
        require(len(record["logs"]) == 2 and {Path(entry["path"]).name for entry in record["logs"]}
                == {name + ".stdout", name + ".stderr"}, "Wrong root raw log pair")
        for entry in record["logs"]:
            source = ROOT / entry["path"]
            require(source.parent == MAIN_LOG and source.name in (name + ".stdout", name + ".stderr"), "Wrong root log source")
            data = add(source, "main/" + source.name, entry["sha256"], "root-main-original-raw", entry["bytes"])
            if name == "portable" and source.suffix == ".stderr":
                require(re.search(rb"Ran 12 tests in [0-9.]+s\s+OK\s*$", data), "Missing actual root portable12 verdict")
            if name == "getters" and source.suffix == ".stdout":
                result = parse(data)
                require(result["fixtures"] == 5 and result["chapters"] == 15 and result["fixtureIntegrityValidated"] is True
                        and result["swiftExecuted"] == result["iOSExecuted"] == 0, "Wrong root getter integrity")
    # The manifest excludes itself, but pins and checks all 132 original members.
    reference_review = parse(add(ROOT / ".build/renewal-discovery/umd-reference-independent-review.json",
        "umd-reference-independent-review.json", REFERENCE_REVIEW_PIN, "independent-original-java-reference-review"))
    original_manifest = parse(add(REFERENCE / "bundle-manifest.json", "reference/bundle-manifest.json",
        REFERENCE_MANIFEST_PIN, "original-reference-full-manifest"))
    require(reference_review["status"] == "no-unresolved-blocking-findings-for-reference-preparation-scope" and reference_review["unresolvedBlockingFindings"] == []
            and reference_review["manifest"]["sha256"] == REFERENCE_MANIFEST_PIN and reference_review["manifestMemberHashesVerified"] == 132,
            "Wrong original reference review")
    members = original_manifest["files"]
    paths = [item["path"] for item in members]
    require(len(members) == len(set(paths)) == 132 and original_manifest["manifestExcludesItself"] is True, "Wrong reference members")
    require(inventory(REFERENCE) == set(paths) | {"bundle-manifest.json"}, "Unexpected/missing reference bundle file")
    require(len([p for p in paths if p.endswith(".class")]) == 13 and
            len([p for p in paths if p.startswith("run/sources/original/") and p.endswith(".java")]) == 9, "Wrong original class/Java inventory")
    excluded = None
    for member in members:
        path = REFERENCE / safe_relative(member["path"])
        data = read(path)
        require((len(data), sha(data)) == (member["bytes"], member["sha256"]), "Original reference member changed: " + member["path"])
        if member["path"] == EXCLUDED_ZIP:
            require(member["bytes"] == 11178463 and member["sha256"] == ZIP_PIN, "Wrong retained local ZIP")
            excluded = dict(path=rel(path), bytes=len(data), sha256=sha(data), retainedLocal=True, archived=False,
                reason="Large original archive retained locally; exact nine original Java bytes and original manifest/reference record remain archived.")
        else:
            add(path, "reference/" + member["path"], member["sha256"], "original-reference-member-byte-copy", member["bytes"])
    require(excluded is not None and len([x for x in items if x["kind"] == "original-reference-member-byte-copy"]) == 131,
            "Wrong reference exclusion count")
    ref_record = parse(read(REFERENCE / "run/reference-record.json"))
    require(sha(read(REFERENCE / "run/reference-record.json")) == REFERENCE_RECORD_PIN
            and prep["originalReference"]["sha256"] == REFERENCE_RECORD_PIN, "Wrong original reference record")
    require(ref_record["actualExecution"]["matchedFixtureCount"] == 5 and ref_record["actualExecution"]["originalReaderFixtureProcesses"] == 5
            and ref_record["actualExecution"]["originalWriterFixtureProcesses"] == 5, "Wrong original Java fixture execution")
    for item in parse(read(ROOT / "Tests/iOS/yuedu appTests/Fixtures/UMD/provenance.json"))["files"]:
        require(read(ROOT / "Tests/iOS/yuedu appTests/Fixtures/UMD" / safe_relative(item["path"])) ==
                read(REFERENCE / "run/fixtures" / safe_relative(item["path"])), "Main golden differs from original")
    # Fixed source objects, not current HEAD, establish absence from A/C.
    source_checks = []
    for commit in (A_RELEASE, BASE_C):
        command = ["git", "ls-tree", "-r", "--name-only", commit, "--", *manifest]
        result = subprocess.run(command, cwd=ROOT, capture_output=True)
        require(result.returncode == 0 and result.stdout == b"", "A/C unexpectedly includes new UMD parser preparation")
        source_checks.append(dict(argv=command, exitCode=result.returncode,
            stdoutSHA256=sha(result.stdout), stderrSHA256=sha(result.stderr), source=commit, UMDPreparationPresent=False))
    data = read(Path(__file__))
    add(Path(__file__), "record-umd-parser-integration.py", sha(data), "root-only-recorder-source")
    return prep, review, items, excluded, source_checks


def update_plan(original):
    require(len(original["stages"]) == 8 and len(original["workpackages"]) == 33 and len(original["features"]) == 64, "Unexpected plan graph counts")
    for flag in ("allNonDeviceWorkComplete", "automaticSelfRenewalImplemented", "fullLegadoCompatibilityEstablished", "legalRedistributionClearanceEstablished"):
        require(original[flag] is False, "Global acceptance must stay false")
    updated = copy.deepcopy(original)
    package = next(item for item in updated["workpackages"] if item["id"] == WP)
    require(package["kind"] == "domain-owner" and package["stageId"] == "s5-library-formats-backup" and REG not in updated["existingEvidence"], "Wrong package or duplicate evidence")
    require(package["execution"]["readiness"] == "ready" and WP in updated["execution"]["readyQueue"]
            and WP not in updated["execution"]["awaitingEvidenceQueue"] and WP not in updated["execution"]["deferredQueue"], "local-formats must remain ready")
    updated["existingEvidence"][REG] = dict(path=rel(BATCH), scope="Unregistered bounded UMD type1 text parser preparation: frozen16 sources, original Java five fixtures/fifteen chapter getters, portable12 and three-file grammar only. Eleven Swift methods planned, SDK/iOS0; checked import commit/product reader/TOC/reopen remain ready work. No full UMD/MOBI/product support.")
    require(REG not in package["existingEvidence"], "Duplicate package evidence")
    package["existingEvidence"].append(REG)
    state = package["execution"]
    state["currentState"] = "TXT/EPUB/PDF 继续按既有统一导入及 CoreText/Readium/PDFKit 路径逐项验收。UMD 已在主树准备未注册的 bounded type1 文本 decoder/file parser 与原 Java 自有 5 fixture/15 章 golden；16 文件匹配冻结补丁及独审，原始 ZIP、9 Java 和全部 132 reference members 核验，归档除大 ZIP 外的原字节。author/root portable 12、getter integrity 与 3 文件 grammar screen 通过，但不能累加或当 Swift 验收；11 个 Swift 方法仅 planned，实际 Swift/SDK/iOS 均 0。UMD/MOBI 仍未接入产品 registry/import/reader；checked lease 只有 design0。另有 3 组集中 runner 准备，尚未提交，不在 C1a87f6d 或 ARelease12；本记录不改变它的提交状态或验收。"
    state["remainingWork"] = [
        "为已准备的 11 个无参数 UMDTextDecoderTests 方法取得固定源码的真实 Apple SDK 编译及精确 11/11 passing leaves；保留原始 xcresult/log，不把 Python fixture walker 或 grammar 当 Swift 执行。",
        "先实现经审查的最小 shared-writer checked import commit：复用现有 pause/drain，覆盖同文件跨 store/direct writer 与 records revision 冲突，成功前不发布，失败或 CAS rollback 不确定时保留 owned recovery；不新建 GCD 或平行书架，不宣称全局 crash/powerloss 事务。当前只有设计，未实现。",
        "完成原 .umd 保留、同一 LocalBookImportService/BookParserRegistry 接入及既有 TXT/CoreText 的显式 UMD TOC/relative UTF16 spine 路由，覆盖 WorkTableOfContents、同步 TXT 入口、share/Calibre/iCloud 与关闭重开；禁用 UMD 正文的 Aozora 注记解释，不经标题 regex 重猜目录，不把 raw byte offset 当持久 charOffset。",
        "UMD 完成真实导入、目录、正文、关闭重开及失败不污染旧书架的验收后再接受该子集；MOBI 仍需合法无 DRM 子集、样本、许可调查与真实 parser/import/reader。TXT/EPUB/PDF 继续合法、损坏、编码、目录、图像与重开的固定回归。"
    ]
    state["nextAction"] = "继续 local-formats ready 开发：先审定并实施最小 checked-commit foundation 与显式目录 reader 路由，再挂接 UMD 产品入口；将 11 方法 SDK 验证并入经审批的集中 checkpoint，不为小改触发 CI，不把纯 parser 准备改成已支持，也不把 ready 改为 awaiting。"
    state["readyPreparation"] = [
        "复用已冻结未注册 decoder/file parser、原 Java 5 fixture/15 getter 与 11 方法精确身份；strict malformed、预算及加密拒绝是项目策略，不伪称原 Java 坏输入异常。",
        "收敛 checked lease design0 为最小 shared writer 原语，覆盖旧 direct writers、跨 store、取消后结果收尾与失败恢复；独立实现评审后再复用同一 importer/reader。",
        "保持 MOBI 调查与 TXT/EPUB/PDF 原验收边界；不得以改扩展名、静默 TXT storageText 或第二 importer/renderer 伪装完整格式支持。"
    ]
    prose = [state["currentState"], state["nextAction"], *state["remainingWork"], *state["readyPreparation"]]
    require(all(isinstance(value, str) and value and "?" not in value and "\uFFFD" not in value for value in prose),
            "Refusing damaged Chinese execution text: question mark or Unicode replacement character")
    for path in (rel(BATCH), rel(DEST / "reader-umd-parser-preparation.json"), rel(DEST / "umd-parser-independent-review.json"),
                 rel(DEST / "reference/run/reference-record.json"), rel(DEST / "umd-reference-independent-review.json"),
                 rel(DEST / "umd-checked-import-design.json"), "Modules/Core/UMD/UMDBookParser.swift",
                 "Modules/Core/UMD/UMDTextDecoder.swift", "Tests/iOS/yuedu appTests/UMDTextDecoderTests.swift"):
        if path not in state["evidence"]: state["evidence"].append(path)
    # Evidence references and this package's execution are the only authorized edits.
    proof = copy.deepcopy(updated)
    del proof["existingEvidence"][REG]
    old = next(item for item in original["workpackages"] if item["id"] == WP)
    target = next(item for item in proof["workpackages"] if item["id"] == WP)
    target["existingEvidence"] = copy.deepcopy(old["existingEvidence"])
    target["execution"] = copy.deepcopy(old["execution"])
    require(proof == original, "Unrelated canonical semantic field changed")
    require(updated["execution"] == original["execution"], "Queue/cloud policy changed")
    require(state["readiness"] == old["execution"]["readiness"] == "ready", "Readiness changed")
    return updated


def main():
    require(len(sys.argv) == 1, "No arguments accepted")
    owned(DEST.parent); owned(BATCH.parent)
    require(not DEST.exists() and not DEST.is_symlink() and not BATCH.exists() and not BATCH.is_symlink(), "Existing/partial outputs refuse rerun")
    required_attribute = b"docs/legado-ios/evidence/reader-umd-parser/** -text -whitespace"
    require(required_attribute in read(ROOT / ".gitattributes").splitlines(), "Root must add the exact-byte evidence .gitattributes rule before recording/staging")
    prep, review, items, excluded, source_checks = collect()
    before = read(PLAN)  # No stale canonical hash pin; root is the sole writer.
    original = parse(before); proposed = update_plan(original); after = encoded(proposed)
    catalog_path = ROOT / "docs/legado-ios/feature-catalog.json"; catalog = read(catalog_path)
    checker_path = ROOT / "scripts/reader-experience/check-completion-plan.py"; owned(checker_path)
    spec = importlib.util.spec_from_file_location("umd_existing_plan_checker", checker_path)
    require(spec is not None and spec.loader is not None, "Cannot load existing plan checker")
    checker = importlib.util.module_from_spec(spec); spec.loader.exec_module(checker)
    checker.validate(original, parse(catalog), ROOT, require_execution=True)
    # Preserve every pre-existing canonical evidence record's exact bytes, not only package state.
    history = {}
    for entry in original["existingEvidence"].values():
        path = ROOT / safe_relative(entry["path"])
        history[rel(path)] = sha(read(path))
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT).decode("ascii").strip()
    require(re.fullmatch(r"[0-9a-f]{40}", head), "Invalid observed HEAD")
    batch = dict(schemaVersion=1, recordedOn=datetime.now(timezone.utc).date().isoformat(),
        stageId="s5-library-formats-backup", workpackageId=WP, status="reviewed-unregistered-parser-preparation-product-chain-still-ready",
        stageComplete=False, allNonDeviceWorkComplete=False, automaticSelfRenewalImplemented=False,
        fullLegadoCompatibilityEstablished=False, legalRedistributionClearanceEstablished=False,
        sourceBinding=dict(patchBaseCommit=BASE_C, integratingHEADObserved=head, HEADNotUsedAsAcceptanceCommitForUncommittedChanges=True,
            sixteenMainFilesMatchFrozenReviewedByteHashes=True, files=prep["files"], checkpointC=BASE_C, includedInC=False,
            AReleaseSource=A_RELEASE, includedInARelease12=False, fixedObjectAbsenceChecks=source_checks),
        productState=dict(registered=False, importSupported=False, readerTOCReopenSupported=False, checkedLeaseImplemented=False,
            checkedLeaseDesignOnly=rel(DEST / "umd-checked-import-design.json"), UMDSubset="bounded unencrypted type1 text only",
            MOBISupported=False, readiness="ready", readyQueuesPreserved=True),
        plannedSwiftTests=dict(suite="UMDTextDecoderTests", methodIdentities=["UMDTextDecoderTests/" + name + "()" for name in METHODS],
            expectedMethods=11, expectedExecutions=11, parameterized=False, expectedExecutionsPerMethod=1, actualExecuted=0),
        localChecksAlreadyExecuted=dict(authorPortableUniqueChecks=12, rootPortableUniqueChecks=12, sameChecksNotAccumulated=True,
            frozenOriginalJavaFixtures=5, originalJavaChapters=15, originalJavaRerunByRecorder=False,
            authorAndRootGetterIntegrity=True, grammarSwiftFiles=3, grammarIsNotTypecheck=True,
            SwiftTypecheckPerformed=False, AppleSDKCompilationPerformed=False, iOSTestsExecuted=0, deviceExecutionPerformed=False,
            testsRerunByRecorder=False, rootReverseAndDiffExitCode=0),
        originalReferenceArchive=dict(originalManifestMembersVerified=132, archivedManifestMembers=131,
            archivedOriginalManifest=True, archivedClassFiles=13, archivedOriginalJavaFiles=9,
            referenceRecordSHA256=REFERENCE_RECORD_PIN, bundleManifestSHA256=REFERENCE_MANIFEST_PIN,
            excludedOriginalZIP=excluded, originalBundleNotModified=True, allMemberBytesPreserved=True,
            fixtureOwnership="public owned synthetic inputs; no private books/source file read"),
        rootMainVerificationRecords=[rel(DEST / "main" / (name + ".json")) for name in MAIN_PINS],
        otherRunnerPreparation=dict(UMDMethodsPlanned=11, runnerGroupsPlanned=3, submitted=False, includedInC=False, includedInARelease12=False,
            note="Separate concentrated measurement/diagnostic runner preparation; this parser archive does not implement, submit or accept it."),
        retainedEvidence=[{k:v for k,v in item.items() if k not in ("name", "data")} for item in items],
        historicalEvidencePreservedSHA256=history,
        canonicalPlanMutation=dict(path=rel(PLAN), beforeSHA256=sha(before), afterSHA256=sha(after), stageCount=8,
            workpackageCount=33, featureDomainCount=64, localFormatsExecutionAndEvidenceReferencesOnly=True,
            allQueuesOtherPackagesAndCloudPoliciesUnchanged=True, allFourGlobalFlagsRemainFalse=True,
            existingCheckerResult=rel(DEST / "plan-check.json")),
        limits=prep["limits"] + ["Original archive omitted from checked-in evidence remains local and hash-bound; archived manifest still describes all original 132 members.",
            "No product registration/import/reader or SDK acceptance; original malformed Java behavior was not exercised.",
            "Checked import lease design0 and shared-writer/rollback recovery remain implementation work, not completed safety properties."],
        recorderActions=dict(gitMutation=False, CIQueriedOrTriggered=False, networkUsed=False, privateSourcesRead=False,
            originalZIPRemoved=False, deviceOrPackageActions=False))
    # All frozen/member/current source checks above precede the first evidence write.
    DEST.mkdir(exist_ok=False)
    for item in items: exclusive(DEST / safe_relative(item["name"]), item["data"])
    exclusive(DEST / "completion-plan.before.json", before)
    exclusive(DEST / "completion-plan.after.json", after)
    exclusive(BATCH, encoded(batch))
    result = checker.validate(proposed, parse(catalog), ROOT, require_execution=True)
    result["inputSHA256"] = {rel(PLAN):sha(after), rel(catalog_path):sha(catalog)}
    exclusive(DEST / "plan-check.json", encoded(result))
    require(read(PLAN) == before and read(catalog_path) == catalog, "Latest canonical/catalog changed; refusing stale replace")
    for path, digest in history.items(): require(sha(read(ROOT / path)) == digest, "Historical evidence changed: " + path)
    for item in prep["files"]:
        data = read(ROOT / item["path"])
        require((len(data), sha(data)) == (item["bytes"], item["sha256"]), "Main source changed during recording")
    for item in items:
        require(sha(read(ROOT / item["source"])) == item["sha256"], "Frozen input changed during recording")
    require(sha(read(ROOT / excluded["path"])) == ZIP_PIN, "Local original ZIP changed during recording")
    temporary = PLAN.with_name(".completion-plan-umd-parser-" + uuid.uuid4().hex + ".tmp")
    exclusive(temporary, after)
    require(read(PLAN) == before, "Canonical changed immediately before replacement")
    os.replace(temporary, PLAN)
    require(read(PLAN) == after, "Canonical byte verification failed")
    print(json.dumps(dict(record=rel(BATCH), recordSHA256=sha(read(BATCH)), archivedInputs=len(items),
        originalReferenceMembersVerified=132, originalReferenceMembersArchived=131, originalZIPArchived=False,
        planSHA256=sha(after), planStructureCheck="passed", readiness="ready", actualSwiftOrIOSTestsExecuted=0,
        measurementRunnerSubmitted=False, cloudPoliciesChanged=False)))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"{type(error).__name__}: {error}; existing outputs are never overwritten; inspect any partial new outputs.", file=sys.stderr)
        sys.exit(1)
