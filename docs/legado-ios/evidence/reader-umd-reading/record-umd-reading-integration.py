#!/usr/bin/env python3
"""Root-only, once-only recorder draft; do not execute during preparation.

After root applies the exact reviewed five-path patch and adds the evidence
.gitattributes rule, root may run:
  python -X utf8 -B .build/renewal-discovery/record-umd-reading-integration.py

No patch apply, Git/network/CI command, test rerun, product registration or old
evidence rewrite. Existing/partial outputs refuse. Root is the sole plan writer.
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
import sys
import uuid

ROOT = Path(__file__).resolve().parents[2]
FROZEN = ROOT / ".build/reader-umd-reading-worktree/.build"
REVIEW = ROOT / ".build/renewal-discovery"
DEST = ROOT / "docs/legado-ios/evidence/reader-umd-reading"
BATCH = ROOT / "docs/legado-ios/umd-reading-preparation-batch.json"
PLAN = ROOT / "docs/legado-ios/completion-plan.json"
BASE = "1fd96156392b231580482606f394219df45141db"
SOURCE_D = "f3e0b15aae3b74e820f2ee86e5468c05a6c1d842"
REG = "umd-reading-preparation"
FLAGS = ("allNonDeviceWorkComplete", "automaticSelfRenewalImplemented",
         "fullLegadoCompatibilityEstablished", "legalRedistributionClearanceEstablished")
METHODS = ("originalGoldenDocumentsAndDirectory", "literalBodyAndLegacyControl", "chapterSeamsDoNotMerge",
           "rejectsInconsistentProjectionAndBudgets", "literalMetadataAndEmptyChapter",
           "positionsUseRenderedSpineAndTitlePrefix", "explicitTransformsPreserveOriginalDocument",
           "cancellationDoesNotReturnPreparedContent")
PINS = {
    "reader-umd-reading.patch": "3441c1517244bd4e6e7eac5f6e0cdd04726796a6fbe90e8f6c8c42075939fcef",
    "reader-umd-reading-preparation.json": "ccabf53a827271014eacdb10a1d813056bdfa5ec2167a37fcc58720507e3cd88",
    "collect-umd-reading-validation.py": "94e61b78cd8d38e7f9cc559d9b1287002974d28d700f5e97c64a47c7a0c93795",
    "freeze-umd-reading-preparation.py": "0cd778286cf79fe4d41d648afaec7cda8f3c1263ebb1f45900d1bbb9e221dca2",
}
REVIEW_PINS = {
    "umd-reading-independent-review.json": "9fdd297081f4b74ba56d04273f9356e1ec661f8e9f0f426fc7021c7c587ae0d8",
    "umd-reading-independent-review-correction.json": "4e484454362f7bf9e8a6bbc562de8962239cdd169d4c59b7c182aa8e016bcd3a",
    "review-umd-reading-offline-attempt1.py": "3caceec0100a641c0cf425c4c5f1583b959d4efecda20fe47d5216cbccc94fe1",
    "review-umd-reading-offline.py": "7af4f552b9f2bbf99e325f51a7ba1db70ff82bf4098b8c92bb9e68ba83e70419",
    "correct-umd-reading-trace-review.py": "6b6df3d5326e7050431fbe979a13092baff3c02c76382c1f4d557306b5a3424f",
}
# Each pin is SHA256(encoded(sorted [{name, bytes, sha256}])). Exact flat
# directory membership and every member's original bytes are checked before copy.
BUNDLES = (
    (FROZEN / "umd-reading-validation", "author/validation", 18, "1b9e11c011f800fdf9bbd92d55b581af525907c113e971262fc997519ec485a9"),
    (FROZEN / "umd-reading-patch-checks", "author/patch-checks", 22, "6231db0da2954182db1af1f8756e0674f92f9a6f283d9b76b34c6aa2c87e6f47"),
    (FROZEN / "umd-reading-primary", "primary", 2, "cdc51e11ede499b759a85f5d14cc89f69b6e62053f8b296aa80f5256ba98731b"),
    (REVIEW / "umd-reading-independent-validation", "independent/attempt1", 25, "a90e65ad0ee3c1212357b13e8d14783618902075cc5ef39320541cde83fb14b1"),
    (REVIEW / "umd-reading-independent-validation-final", "independent/final", 27, "83c58159e1d57db47b051963468b628343ac2895badc2bc56bbb9f96cebce8b4"),
    (REVIEW / "umd-reading-trace-correction-raw", "independent/correction", 5, "7a310421b4cb8317e1d0f4da4a6e9ad3bf2264d56dff864d7e37133809d62d04"),
    (REVIEW / "umd-reading-main-verification", "main", 9, "04467a362aabae2966eb44f6b41859adf44aa29ec77cd148176c7ceb30e77aa4"),
)
sys.dont_write_bytecode = True


def require(value, message):
    if not value: raise ValueError(message)


def sha(data): return hashlib.sha256(data).hexdigest()
def rel(path): return path.relative_to(ROOT).as_posix()
def encoded(value): return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def safe_relative(value):
    require(isinstance(value, str) and "\\" not in value and ":" not in value, "Invalid relative path")
    path = PurePosixPath(value)
    require(value == path.as_posix() and not path.is_absolute() and path.parts
            and all(part not in (".", "..") for part in path.parts), "Unsafe relative path")
    return Path(*path.parts)


def owned(path, missing=False):
    require(path.is_absolute() and path.is_relative_to(ROOT), "Path outside repository")
    for item in (path, *path.parents):
        try: value = item.lstat()
        except FileNotFoundError: require(missing, "Required path missing: " + str(item))
        else:
            require(not stat.S_ISLNK(value.st_mode) and not (getattr(value, "st_file_attributes", 0) & 0x400),
                    "Refusing symlink/junction/reparse path")
        if item == ROOT: break
    require(path.resolve(strict=not missing).is_relative_to(ROOT), "Resolved path outside repository")


def read(path):
    owned(path)
    require(path.is_file() and path.stat().st_size <= 4 * 1024 * 1024, "Invalid/oversize input")
    return path.read_bytes()


def parse(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "Duplicate JSON key")
            result[key] = value
        return result
    def nonfinite(value): raise ValueError("Nonfinite JSON: " + value)
    return json.loads(data.decode("utf-8"), object_pairs_hook=unique, parse_constant=nonfinite)


def exclusive(path, data):
    owned(path, missing=True)
    path.parent.mkdir(parents=True, exist_ok=True)
    owned(path.parent)
    with path.open("xb") as stream:
        stream.write(data); stream.flush(); os.fsync(stream.fileno())
    require(read(path) == data, "Output bytes differ")


def collect():
    items = []
    def add(path, name, digest, count=None):
        safe_relative(name)
        require(name not in {item["name"] for item in items}, "Duplicate archive destination")
        data = read(path)
        require(re.fullmatch(r"[0-9a-f]{64}", digest) and sha(data) == digest
                and (count is None or len(data) == count), "Frozen input changed: " + rel(path))
        items.append(dict(name=name, source=rel(path), path=rel(DEST / name), bytes=len(data), sha256=digest, data=data))
        return data
    frozen = {name:add(FROZEN / name, name, digest) for name, digest in PINS.items()}
    reviews = {name:add(REVIEW / name, name, digest) for name, digest in REVIEW_PINS.items()}
    prep = parse(frozen["reader-umd-reading-preparation.json"])
    original = parse(reviews["umd-reading-independent-review.json"])
    correction = parse(reviews["umd-reading-independent-review-correction.json"])
    require(prep["base"] == original["base"] == correction["base"] == BASE, "Wrong literal baseline")
    require(prep["files"] == original["files"] == correction["files"] and len(prep["files"]) == 5, "Wrong five-source inventory")
    for value in (prep, original, correction):
        require(value["patch"]["sha256"] == PINS["reader-umd-reading.patch"], "Patch binding mismatch")
    require(original["preparation"]["sha256"] == correction["preparation"]["sha256"] == PINS["reader-umd-reading-preparation.json"], "Preparation binding mismatch")
    require(correction["originalReviewPreservedUnchanged"]["sha256"] == REVIEW_PINS["umd-reading-independent-review.json"], "Original review binding mismatch")
    effective = correction["effectiveReview"]
    require(effective["status"] == "no-unresolved-static-blocking-findings" and effective["unresolvedBlockingFindings"] == []
            and effective["nonBlockingFindings"] == [], "Effective review has unresolved findings")
    withdrawn = correction["withdrawnFinding"]
    require(withdrawn["id"] == "trace-byte-field-is-entry-zero" and withdrawn["withdrawn"] is True
            and withdrawn["findingWasIncorrect"] is True, "Trace finding must be explicitly withdrawn")
    require(effective["actualSwiftMethodsExecuted"] == effective["iOSTestsExecuted"] == 0
            and effective["SwiftTypecheckPerformed"] is False and effective["AppleSDKCompilationPerformed"] is False,
            "Unsupported native acceptance")
    tests = prep["plannedSwiftTests"]
    require(tests["suite"] == "UMDReadingPreparationTests" and tests["methods"] == list(METHODS)
            and tests["count"] == tests["expectedExecutions"] == 8 and tests["actualExecutions"] == 0
            and tests["parameterized"] is False, "Wrong planned eight test identities")
    for item in prep["files"]:
        path = ROOT / safe_relative(item["path"])
        add(path, "source/" + item["path"], item["sha256"], item["bytes"])
        require(read(FROZEN.parent / item["path"]) == read(path), "Root/frozen source differs")
    for directory, prefix, count, pin in BUNDLES:
        owned(directory)
        paths = sorted(directory.iterdir())
        require(len(paths) == count, "Unexpected evidence directory membership")
        members = [{"name": path.name, "bytes": len(read(path)), "sha256": sha(read(path))} for path in paths]
        require(sha(encoded(members)) == pin, "Evidence directory catalog changed: " + rel(directory))
        for path, member in zip(paths, members): add(path, prefix + "/" + member["name"], member["sha256"], member["bytes"])
    validation = parse(read(FROZEN / "umd-reading-validation/validation-record.json"))
    require(validation["portableTests"] == dict(executed=12, passed=12, failed=0)
            and validation["getterIntegrity"]["fixtures"] == 5 and validation["getterIntegrity"]["chapters"] == 15
            and validation["grammarFiles"] == 5 and validation["grammarPassed"] is True, "Wrong author portable/grammar evidence")
    require(all(validation[key] == 0 for key in ("actualSwiftTypechecks", "actualSwiftSDKBuilds", "actualSwiftTests", "actualIOSTests")), "Author scope mismatch")
    main = parse(read(REVIEW / "umd-reading-main-verification/record.json"))
    require(main["fiveFrozenMainFilesMatch"] == prep["files"] and main["all16FrozenParserFilesUnchanged"] is True
            and len(main["commands"]) == 4 and all(item["exitCode"] == 0 for item in main["commands"])
            and main["newSDKBuilds"] == main["newSwiftTests"] == 0, "Wrong root source checks")
    callee = correction["calleeBinding"]
    require(callee["allThreeByteIdentical"] is True
            and sha(read(ROOT / safe_relative(callee["sourcePath"]))) == callee["currentMainFile"]["sha256"], "Trace callee changed")
    # Reuse existing evidence archives; do not copy the old reference132 bundle.
    reused = []
    for name, count in (("umd-parser-preparation-batch.json", 16), ("reader-launch-memory-batch.json", 9),
                        ("reader-measurements-runner-batch.json", 8)):
        path = ROOT / "docs/legado-ios" / name; data = read(path); record = parse(data)
        files = record["sourceBinding"]["files"]
        require(len(files) == count and len({item["path"] for item in files}) == count, "Wrong reused batch source count")
        for item in files:
            raw = read(ROOT / safe_relative(item["path"]))
            require((len(raw), sha(raw)) == (item["bytes"], item["sha256"]), "Unrelated prepared source changed")
        reused.append(dict(path=rel(path), bytes=len(data), sha256=sha(data), sourceFilesUnchanged=count, archivedAgain=False))
    receipt_path = ROOT / "docs/legado-ios/stage-checkpoint-f3e0b15-initial.json"
    receipt = parse(read(receipt_path))
    require(receipt["sourceCommit"] == SOURCE_D and receipt["APIRequests"] == 2 and receipt["newRuntimeOrCompatibilityAcceptance"] is False
            and "literal UMD reading5 is isolated and excluded" in receipt["scope"], "Wrong saved D submission context")
    reused.append(dict(path=rel(receipt_path), bytes=len(read(receipt_path)), sha256=sha(read(receipt_path)), archivedAgain=False))
    add(Path(__file__), "record-umd-reading-integration.py", sha(read(Path(__file__))))
    require(len(items) < 160 and sum(item["bytes"] for item in items) < 8 * 1024 * 1024, "Unexpected archive size")
    return prep, correction, items, reused


def update_plan(original):
    require((len(original["stages"]), len(original["workpackages"]), len(original["features"])) == (8, 33, 64), "Wrong plan graph")
    require(all(original[key] is False for key in FLAGS), "Global acceptance must remain false")
    updated = copy.deepcopy(original)
    package = next(item for item in updated["workpackages"] if item["id"] == "local-formats")
    old = next(item for item in original["workpackages"] if item["id"] == "local-formats")
    state = package["execution"]
    require(package["stageId"] == "s5-library-formats-backup" and state["readiness"] == "ready"
            and package["id"] in updated["execution"]["readyQueue"] and REG not in updated["existingEvidence"], "Wrong readiness or duplicate evidence")
    require(package["id"] not in updated["execution"]["awaitingEvidenceQueue"]
            and package["id"] not in updated["execution"]["deferredQueue"], "Queue mismatch")
    state["currentState"] = "TXT/EPUB/PDF 继续按既有统一导入及 CoreText/Readium/PDFKit 路径验收。UMD16 的未注册 type1 文本 parser 与原 Java 自有 5 fixture/15 章黄金观察保持不变；其 11 方法已随 D f3e0b15 的集中 source-only smoke 与 memory1/UI1/UMD11 runner 提交，沿用原首次观察，不在本批更新云端状态或接受结果。新增并独审的字面阅读 5 文件在主树匹配冻结字节：复用 UnifiedChapter、TXTBookDocument 和同一 TXT/Node/CoreText 构造器，保留原目录及字面正文，显式用户转换与替换仅影响渲染。新增 8 方法仅 planned，Swift/SDK/iOS 实际均 0；portable12、5 fixture/15 章完整性及 5 文件 grammar 通过不代表 Swift 验收。该 5 文件不在 D 源码内，也未触发新 CI；UMD/MOBI 仍未注册产品导入或阅读路由，checked lease 仍仅 design0。"
    state["remainingWork"] = [
        "保留 D 已提交的原 11 方法与集中 runner 的独立源绑定结果；新增 8 个 UMDReadingPreparationTests 方法仍需未来经批准的固定源码 Apple SDK 编译及精确 8/8 真实执行，保留原始 xcresult/log，不以 portable 或 grammar 代替。",
        "实现并独审最小 shared-writer checked import commit：复用现有 pause/drain，覆盖同文件跨 store/direct writer 与 records revision 冲突，成功前不发布，失败或 CAS rollback 不确定时保留 owned recovery；不新增 GCD 或平行书架，不宣称全局 crash/powerloss 事务。",
        "在 checked commit 完成后将原 .umd 保留、显式目录和字面正文接入同一 LocalBookImportService/BookParserRegistry 及既有 reader，覆盖目录、同步 TXT 入口、share/Calibre/iCloud 与关闭重开；不得把原 byte offset 当持久 charOffset，不经标题 regex 重猜目录，不静默转 TXT 冒充完整支持。",
        "真实导入、目录、正文、重开及失败不污染旧书架均验收后再接受 UMD 子集；MOBI 仍需合法无 DRM 子集、样本、许可调查及真实 parser/import/reader。TXT/EPUB/PDF 原有固定回归继续保持。",
    ]
    state["nextAction"] = "继续 local-formats ready 开发：先收敛并实施 checked-commit foundation，再接产品 UMD 路由；复用本次已审字面阅读准备，按阶段合并新增 8 方法的真实 SDK 验证，不为小改触发 CI，不把准备或 D 提交当成通过，也不将 ready 改为 awaiting。"
    prose = [state["currentState"], state["nextAction"], *state["remainingWork"]]
    require(all(isinstance(value, str) and value and "?" not in value and "\uFFFD" not in value for value in prose), "Damaged UTF-8 prose")
    updated["existingEvidence"][REG] = dict(path=rel(BATCH), scope="Reviewed unregistered UMD literal in-memory reading preparation: exact five sources, old initializers preserved, portable12/fixture5-chapter15/grammar5 only; eight Swift methods planned, SDK/iOS0. Original review retained with its trace finding explicitly withdrawn by correction. Not in source D; product route/checked commit remain ready.")
    require(REG not in package["existingEvidence"], "Duplicate local evidence reference")
    package["existingEvidence"].append(REG)
    for path in (rel(BATCH), rel(DEST / "reader-umd-reading-preparation.json"),
                 rel(DEST / "umd-reading-independent-review.json"), rel(DEST / "umd-reading-independent-review-correction.json"),
                 "Modules/Core/UMD/UMDReadingPreparation.swift", "Tests/iOS/yuedu appTests/UMDReadingPreparationTests.swift"):
        if path not in state["evidence"]: state["evidence"].append(path)
    # Only these exact text/reference fields are authorized; other local-formats
    # fields, all other packages, stage/feature/global state and D/cloud policy stay exact.
    proof = copy.deepcopy(updated); del proof["existingEvidence"][REG]
    target = next(item for item in proof["workpackages"] if item["id"] == "local-formats")
    target["existingEvidence"] = copy.deepcopy(old["existingEvidence"])
    for key in ("currentState", "remainingWork", "nextAction", "evidence"):
        target["execution"][key] = copy.deepcopy(old["execution"][key])
    require(proof == original and updated["execution"] == original["execution"], "Unrelated canonical field changed")
    return updated


def main():
    require(len(sys.argv) == 1, "No arguments accepted")
    owned(DEST.parent); owned(BATCH.parent)
    require(not DEST.exists() and not DEST.is_symlink() and not BATCH.exists() and not BATCH.is_symlink(), "Existing/partial outputs refuse rerun")
    require(b"docs/legado-ios/evidence/reader-umd-reading/** -text -whitespace" in read(ROOT / ".gitattributes").splitlines(), "Root must add exact-byte evidence attribute first")
    prep, correction, items, reused = collect()  # All frozen checks before writes.
    before = read(PLAN); original = parse(before); proposed = update_plan(original); after = encoded(proposed)
    catalog_path = ROOT / "docs/legado-ios/feature-catalog.json"; catalog = read(catalog_path)
    checker_path = ROOT / "scripts/reader-experience/check-completion-plan.py"; owned(checker_path)
    spec = importlib.util.spec_from_file_location("umd_reading_existing_plan_checker", checker_path)
    require(spec is not None and spec.loader is not None, "Cannot load existing checker")
    checker = importlib.util.module_from_spec(spec); spec.loader.exec_module(checker)
    checker.validate(original, parse(catalog), ROOT, require_execution=True)
    history = {entry["path"]:sha(read(ROOT / safe_relative(entry["path"]))) for entry in original["existingEvidence"].values()}
    batch = dict(schemaVersion=1, recordedOn=datetime.now(timezone.utc).date().isoformat(),
        stageId="s5-library-formats-backup", workpackageId="local-formats",
        status="reviewed-unregistered-literal-reading-preparation-product-chain-still-ready", stageComplete=False,
        **{key:False for key in FLAGS},
        sourceBinding=dict(patchBaseCommit=BASE, fiveMainFilesMatchFrozenReviewedBytes=True, files=prep["files"],
            sourceD=SOURCE_D, includedInD=False, noNewCheckpointSubmitted=True, uncommittedMainHashesNotAnAcceptanceCommit=True),
        plannedSwiftTests=dict(suite="UMDReadingPreparationTests", methodIdentities=["UMDReadingPreparationTests/" + name + "()" for name in METHODS],
            expectedMethods=8, expectedExecutions=8, parameterized=False, actualExecuted=0),
        localChecksAlreadyExecuted=dict(authorPortableUniqueChecks=12, fixtureIntegrityFixtures=5, fixtureIntegrityChapters=15,
            grammarSwiftFiles=5, grammarIsNotTypecheck=True, actualSwiftTypechecks=0, actualSDKBuilds=0, actualIOSTests=0,
            rootApplyCheckApplyReverseDiffCommands=4, rootChecksExitZero=True, testsRerunByRecorder=False),
        effectiveIndependentReview=dict(original=rel(DEST / "umd-reading-independent-review.json"),
            correction=rel(DEST / "umd-reading-independent-review-correction.json"), originalPreservedUnchanged=True,
            withdrawnIncorrectFinding="trace-byte-field-is-entry-zero", unresolvedBlockingFindings=[], nonBlockingFindings=[],
            traceBoundary=correction["effectiveReview"]["traceSemantics"]),
        productState=dict(registered=False, importSupported=False, readerTOCReopenAccepted=False, checkedLeaseImplemented=False,
            diskStorageOrPositionWrites=False, readiness="ready", checkedLeaseStatus="design0-outside-this-batch"),
        reusedEvidence=reused, originalReference132Rearchived=False,
        retainedEvidence=[{key:value for key,value in item.items() if key not in ("name", "data")} for item in items],
        historicalEvidencePreservedSHA256=history,
        canonicalPlanMutation=dict(path=rel(PLAN), beforeSHA256=sha(before), afterSHA256=sha(after), stageCount=8,
            workpackageCount=33, featureDomainCount=64, onlyLocalFormatsTextAndEvidenceChanged=True, readinessAndQueuesPreserved=True,
            otherWorkpackagesAndSourceDStatusesPreserved=True, globalFourFalsePreserved=True, cloudPolicyPreserved=True),
        limits=["Portable and grammar are not Swift SDK or iOS execution.",
                "New eight methods are absent from source-D runner selections; no new CI trigger.",
                "No product UMD/MOBI support, checked commit, storage/reopen, global transaction, memory or performance acceptance."],
        recorderActions=dict(rootOnly=True, networkRequests=0, CIQueriesOrTriggers=0, gitCommands=0, testsExecuted=0,
            oldEvidenceRewritten=False, originalFullReferenceRearchived=False))
    DEST.mkdir()
    for item in items: exclusive(DEST / safe_relative(item["name"]), item["data"])
    exclusive(DEST / "completion-plan.before.json", before)
    exclusive(DEST / "completion-plan.after.json", after)
    exclusive(BATCH, encoded(batch))
    result = checker.validate(proposed, parse(catalog), ROOT, require_execution=True)
    result["inputSHA256"] = {rel(PLAN):sha(after), rel(catalog_path):sha(catalog)}
    exclusive(DEST / "plan-check.json", encoded(result))
    require(read(PLAN) == before and read(catalog_path) == catalog, "Canonical/catalog changed during recording")
    for path, digest in history.items(): require(sha(read(ROOT / safe_relative(path))) == digest, "Historical record changed")
    for item in items: require(sha(read(ROOT / safe_relative(item["source"]))) == item["sha256"], "Frozen input changed during recording")
    for item in reused: require(sha(read(ROOT / safe_relative(item["path"]))) == item["sha256"], "Reused evidence or D receipt changed")
    temporary = PLAN.with_name(".completion-plan-umd-reading-" + uuid.uuid4().hex + ".tmp")
    exclusive(temporary, after)
    require(read(PLAN) == before, "Canonical changed immediately before replacement")
    os.replace(temporary, PLAN)
    require(read(PLAN) == after, "Canonical byte verification failed")
    print(json.dumps(dict(record=rel(BATCH), recordSHA256=sha(read(BATCH)), archivedInputs=len(items),
        planSHA256=sha(after), readiness="ready", actualSwiftOrIOSTestsExecuted=0,
        sourceDStatusesChanged=False, newCITriggered=False, originalReferenceRearchived=False)))


if __name__ == "__main__":
    try: main()
    except Exception as error:
        print(f"{type(error).__name__}: {error}; partial outputs are never overwritten; root must inspect them.", file=sys.stderr)
        sys.exit(1)
