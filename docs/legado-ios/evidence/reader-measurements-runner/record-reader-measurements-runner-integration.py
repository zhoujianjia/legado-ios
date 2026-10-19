#!/usr/bin/env python3
"""Root-only once-only recorder draft. Merely reading this file has no effects.

Run: python -X utf8 -B .build/renewal-discovery/record-reader-measurements-runner-integration.py
No test reruns, patch application, git mutation, network, CI or package actions.
The latest canonical and two existing batches are read only when root runs this.
Existing evidence/batch outputs refuse, including a rerun after partial failure.
Root must remain the sole writer. Three document replacements are individually
atomic; this documentation recorder does not promise crash-atomic multi-file IO.
"""
from datetime import datetime, timezone
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[2]
FROZEN = ROOT / ".build/reader-measurements-runner-worktree/.build"
DEST = ROOT / "docs/legado-ios/evidence/reader-measurements-runner"
BATCH = ROOT / "docs/legado-ios/reader-measurements-runner-batch.json"
PLAN = ROOT / "docs/legado-ios/completion-plan.json"
LAUNCH_BATCH = ROOT / "docs/legado-ios/reader-launch-memory-batch.json"
UMD_BATCH = ROOT / "docs/legado-ios/umd-parser-preparation-batch.json"
WP = "reading-performance-and-prefetch"
REG = "reader-measurements-runner-integration"
BASE = "9e4656128e202a0324dda3e8ad97a3c028d37499"
C_SOURCE = "1a87f6d57b2e3f215b86930fdfa75fdd52ce2e06"
A_SOURCE = "a76d380fdc108db83be68961905ee49edd209571"
PINS = {
    "reader-measurements-runner.patch": "1da20a58629e888ab6b430c22d68e3500158dbce9379b0c0ab52e2516c3d191f",
    "reader-measurements-runner-preparation.json": "48e6d3de388ff7cfa5a760fa885c08d90a0c2a7f02a40b268b094b6909f06bd6",
    "reader-measurements-runner-v2.patch": "11e578fc44104e10b168320b0c8ebd766ab4d46294e7f40203a381df1798197f",
    "reader-measurements-runner-preparation-v2.json": "99a2fada7ec2f1bdd6dd4811655cd38e0a920c0716780208f5cc591784dcc4f6",
}
REVIEW_PIN = "a7fd3f15f060132b49cc996ca772313199674cd98534759786d3822b6f5dac87"
NEGATIVE_PIN = "6144500f71a0344982c9498b2042581b80fff20249318e7235ea634031d6f4ba"
DEBUG_PIN = "9cb38e97570f5ca112d10721b598dde93c08b6775b013d01dadfa98ccb2aede4"
PERF_PREP_PIN = "f5704e40f106c5256cedeebcac878036cf68bec1741bd4e7a2535c6efd97e961"
UMD_PREP_PIN = "f5ffb5197a5ae2e346f15bb123c53278b7bd5da4a17cc8ebd78706b8996a6040"
GLOBAL_FLAGS = ("allNonDeviceWorkComplete", "automaticSelfRenewalImplemented",
                "fullLegadoCompatibilityEstablished", "legalRedistributionClearanceEstablished")
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
            require(missing and item == path, "Missing required path: " + str(item))
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
    return json.loads(data.decode("utf-8"), object_pairs_hook=unique)


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def exclusive(path, data):
    owned(path, missing=True)
    with path.open("xb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    require(read(path) == data, "Written output differs: " + rel(path))


def validate_new_text(value):
    if isinstance(value, str):
        require(chr(0xFFFD) not in value, "Replacement character in generated text")
        if re.search("[\u3400-\u9fff]", value):
            require(chr(63) not in value, "Question mark in generated Chinese prose")
    elif isinstance(value, dict):
        for key, item in value.items():
            validate_new_text(key)
            validate_new_text(item)
    elif isinstance(value, list):
        for item in value:
            validate_new_text(item)


def manifest(files, count):
    result = {item["path"]: {key: item[key] for key in ("path", "bytes", "sha256")} for item in files}
    require(len(files) == len(result) == count, "Wrong source inventory size")
    require(all(re.fullmatch(r"[0-9a-f]{64}", item["sha256"]) for item in result.values()), "Invalid source hash")
    return result


def verify_main(files):
    for item in files.values():
        data = read(ROOT / item["path"])
        require((sha(data), len(data)) == (item["sha256"], item["bytes"]),
                "Main bytes differ from frozen source: " + item["path"])


def evidence():
    items = []
    by_source = {}

    def add(source, name, digest, kind, size=None):
        source = Path(source)
        if not source.is_absolute():
            source = ROOT / source
        require(Path(name).name == name and "/" not in name and "\\" not in name, "Invalid archive basename")
        data = read(source)
        require(sha(data) == digest and (size is None or len(data) == size), "Frozen input mismatch: " + rel(source))
        if source in by_source:
            old = by_source[source]
            require((old["sha256"], old["bytes"]) == (digest, len(data)), "Conflicting repeated input")
            return data
        require(name not in {item["name"] for item in items}, "Duplicate archive basename")
        entry = {"name": name, "source": rel(source), "path": rel(DEST / name), "bytes": len(data),
                 "sha256": digest, "kind": kind, "data": data}
        items.append(entry)
        by_source[source] = entry
        return data

    frozen = {name: add(FROZEN / name, name, digest, "frozen-original-preparation") for name, digest in PINS.items()}
    old = parse(frozen["reader-measurements-runner-preparation.json"])
    prep = parse(frozen["reader-measurements-runner-preparation-v2.json"])
    review = parse(add(ROOT / ".build/renewal-discovery/reader-measurements-runner-independent-review.json",
                       "reader-measurements-runner-independent-review.json", REVIEW_PIN, "independent-static-review", 13331))
    add(ROOT / ".build/renewal-discovery/measurement-runner-preliminary-containment-negative.json",
        "measurement-runner-preliminary-containment-negative.json", NEGATIVE_PIN, "original-synthetic-counterexample", 4176)
    require(prep["baselineSourceCommit"] == old["baselineSourceCommit"] == review["baselineSourceCommit"] == BASE,
            "Wrong runner baseline")
    require(prep["preparationRevision"] == 2 and review["reviewedPreparationRevision"] == 2,
            "Wrong preparation revision")
    require(review["status"] == "no-unresolved-static-blocking-findings" and review["unresolvedBlockingFindings"] == [],
            "Independent review has unresolved findings")
    require(prep["patch"]["sha256"] == review["patch"]["sha256"] == PINS["reader-measurements-runner-v2.patch"]
            and review["preparation"]["sha256"] == PINS["reader-measurements-runner-preparation-v2.json"], "Review binding mismatch")
    require(prep["supersedesFrozenV1"]["patch"]["sha256"] == PINS["reader-measurements-runner.patch"]
            and prep["supersedesFrozenV1"]["preparation"]["sha256"] == PINS["reader-measurements-runner-preparation.json"],
            "Frozen v1 binding mismatch")
    require(prep["files"] == review["files"] and set(prep["changedPaths"]) == {item["path"] for item in prep["files"]},
            "Eight-source review binding mismatch")
    main = manifest(prep["files"], 8)
    verify_main(main)
    require(prep["sourceInputsPlanned"] == review["evidence"]["plannedSourceBindings"] == 38,
            "Source-binding contract changed")
    for record in (old, prep, review):
        require(record["SwiftTypecheckPerformed"] is False and record["AppleSDKCompilationPerformed"] is False
                and record["iOSTestsExecuted"] == record["actualLaunchSamples"] == record["actualMemorySamples"] == 0,
                "Unsupported actual native/sample claim")
    require(prep["actualUMDSwiftExecutions"] == 0 and prep["newCIProtocol"]["submittedOrTriggered"] is False,
            "Preparation is not unsubmitted source-only work")
    require(prep["newCIProtocol"]["includeHiddenFiles"] is True and prep["newCIProtocol"]["retentionDays"] == 7,
            "Reviewed upload contract changed")

    raw_count = 0
    expected_names = {"portable-collection", "portable-shared-smoke", "portable-shared-stage", "bash-syntax",
                      "actionlint", "diff-check", "tracked-patch", "reverse-patch-check", "forward-main-check",
                      *("new-file-" + str(index) for index in range(6))}
    for revision, record, count in ((1, old, 20), (2, prep, 22)):
        checks = record["localChecks"]
        require(checks["portableCollectionMethodsPassed"] == count and checks["portableSharedSmokeMethodsPassed"] == 24
                and checks["portableSharedStageMethodsPassed"] == 20 and checks["shellcheckExecuted"] is False,
                "Wrong original portable counts")
        commands = checks["commands"]
        require(len(commands) == 15 and {item["name"] for item in commands} == expected_names,
                "Unexpected original command set")
        for command in commands:
            require(command["exitCode"] == command["expectedExitCode"], "Original author command failed")
            for channel in ("stdout", "stderr"):
                entry = command[channel]
                source = Path(entry["path"])
                folder = "reader-measurements-validation"
                if revision == 2 and not command.get("reusedUnchangedV1EvidenceNotRerun", False):
                    folder += "-v2"
                require(source == FROZEN / folder / (command["name"] + "." + channel), "Unexpected author raw path")
                before = len(items)
                raw = add(source, "author-v" + str(revision) + "-" + source.name,
                          entry["sha256"], "author-original-portable-or-static-raw", entry["bytes"])
                raw_count += len(items) - before
                if channel == "stderr" and command["name"].startswith("portable-"):
                    actual_count = {"portable-collection": count, "portable-shared-smoke": 24, "portable-shared-stage": 20}[command["name"]]
                    require(re.search(rb"Ran " + str(actual_count).encode() + rb" tests in [0-9.]+s\s+OK\s*$", raw),
                            "Original raw portable verdict mismatch")
    require(raw_count == 54, "Unexpected number of unique original v1/v2 raw logs")
    findings = review["resolvedFindings"]
    require(findings[0]["originalNegative"]["sha256"] == NEGATIVE_PIN, "Original counterexample not review-bound")
    for key, name in (("identityCheck", "independent-identity-check.json"),
                      ("reviewerScript", "review-measurements-runner-v2.py"),
                      ("reviewerBaseScript", "review-measurements-runner.py")):
        entry = review["evidence"][key]
        add(Path(entry["path"]), name, entry["sha256"], "independent-original-validation", entry["bytes"])
    replay = findings[0]["frozenReplay"]
    add(Path(replay["path"]), "independent-containment-replay.json", replay["sha256"],
        "independent-counterexample-replay", replay["bytes"])
    for entry in review["evidence"]["historicalUIReference"]:
        original = entry["original"]
        raw = add(Path(original["path"]), "historical-" + Path(original["path"]).name,
                  original["sha256"], "historical-original-ui-structure-only", original["bytes"])
        require(raw == read(ROOT / entry["fixture"]), "Historical UI fixture bytes changed")
    debug_entry = prep["debugPayloadHistoricalReference"]
    require(debug_entry["sha256"] == DEBUG_PIN, "Unexpected debug reference")
    debug = parse(add(Path(debug_entry["path"]), "debug-payload-historical-reference.json", DEBUG_PIN,
                      "historical-debug-naming-reference", debug_entry["bytes"]))
    actual_a = debug["mainAppA"]
    require(actual_a["sourceCommit"] == A_SOURCE and actual_a["runID"] == 39272841721
            and actual_a["actualTestCases"] == 0, "Wrong original A debug evidence")
    raw = add(ROOT / actual_a["log"], "historical-A-unit-tests.log", actual_a["sha256"],
              "original-A-actual-compile-link-log-not-new-tests", actual_a["bytes"])
    lines = raw.decode("utf-8").splitlines()
    require(all(lines[item["line"] - 1] == item["text"] for item in actual_a["excerpts"]), "A original excerpt mismatch")
    settings = debug["oldUIBuildSettings"]
    add(ROOT / settings["path"], "historical-ui-build-settings.json", settings["sha256"],
        "historical-original-debug-build-settings", settings["bytes"])
    require(settings["selectedActualFields"]["ENABLE_DEBUG_DYLIB"] == "YES"
            and settings["selectedActualFields"]["EXECUTABLE_DEBUG_DYLIB_PATH"] is None,
            "Historical optional Debug path contract changed")
    dependency = prep["UMDDependencyPreparation"]
    require(dependency["sha256"] == UMD_PREP_PIN, "Wrong UMD dependency preparation")
    umd = parse(add(Path(dependency["path"]), "reader-umd-parser-preparation.json", UMD_PREP_PIN,
                    "existing-reviewed-umd-source-inventory", dependency["bytes"]))
    perf = parse(add(ROOT / ".build/reader-launch-memory-worktree/.build/reader-launch-memory-preparation.json",
                     "reader-launch-memory-preparation.json", PERF_PREP_PIN, "existing-reviewed-perf-source-inventory"))
    require(perf["preparedSelections"]["oldTXTSelectionAndCount"] == 1
            and perf["preparedSelections"]["oldReaderStageRows"] == 50, "Legacy selections changed")
    perf_files = manifest(perf["files"], 9)
    umd_files = manifest(umd["files"], 16)
    verify_main(perf_files)
    verify_main(umd_files)
    for path in old["localChecks"]["unchangedProtocolFiles"]:
        require(read(ROOT / path) == read(FROZEN.parent / path), "Old smoke/stage protocol changed: " + path)
    return prep, review, items, main, perf_files, umd_files


def update_plan(original):
    proposed = copy.deepcopy(original)
    require(all(original[key] is False for key in GLOBAL_FLAGS), "Global completion flag changed")
    require(len(original["stages"]) == 8 and len(original["workpackages"]) == 33 and len(original["features"]) == 64,
            "Canonical 8/33/64 contract changed")
    package = next(item for item in proposed["workpackages"] if item["id"] == WP)
    require(package["stageId"] == "s2-reading-experience" and package["kind"] == "cross-domain"
            and package["status"] == "in_progress" and package["ownedFeatureIds"] == []
            and package["execution"]["readiness"] == "awaiting-cloud", "Wrong performance package state")
    require(REG not in proposed["existingEvidence"] and REG not in package["existingEvidence"], "Evidence already registered")
    require(WP in proposed["execution"]["awaitingEvidenceQueue"] and WP not in proposed["execution"]["readyQueue"]
            and WP not in proposed["execution"]["nextReadyBatch"], "Unexpected performance queue state")
    proposed["existingEvidence"][REG] = {
        "path": rel(BATCH),
        "scope": "Reviewed independent runner8 code is present, not submitted: exact memory1/UI1/UMD11 leaves, source38/environment/overlay/actual Debug main-payload binding. Original portable collector22/shared24/stage20 raw retained; root rerun is tool-reported-only without new raw. Swift/SDK/new XCTest and launch/memory samples0. Old TXT1/stage50, parser product readiness and all other checkpoints remain independent."
    }
    package["existingEvidence"].append(REG)
    state = package["execution"]
    state["currentState"] = "20/100 章十跳、损坏缓存与原 50 行排版阶段证据继续按各自源码验收。独立启动/内存 9 文件与未注册 UMD 纯解析器 16 文件保持原冻结字节；另已准备并审查独立 runner 8 文件，接入 memory 1/1、UI launch 1/1、UMD 11/11 三组精确实际叶集门、38 源文件及环境/overlay/Debug 主代码载荷绑定。作者实际 portable collector 22、shared 24、stage 20 有原始日志；root 主树同组检查与 bash/diff 仅 tool-reported-only，无新增 raw，不累计为更多用例。独立 workflow/选择的代码已接入，但该批尚未提交；实际 Swift/SDK、新 XCTest、启动和内存样本均 0，不在 C1a87f6d 或 A Release 中。awaiting-cloud 仅表示等待对应证据。"
    state["remainingWork"] = [
        "由 root 在同阶段相关源码与实际 C 临时根修复审查完成后统一提交独立 runner 检查点；提交前 submitted 保持 false。保留旧 smoke/TXT 1 方法/50 行阶段协议，三组分别留存 dedicated log、xcresult、summary、tests tree 与失败事实。",
        "按固定 source、实际 Xcode/SDK/runtime/UDID、overlay 和构建产物身份取得真实 memory 1/1、launch 1/1 与 UMD 11/11、零失败/跳过/额外叶；须满足 5 个启动样本、2×5 个内存样本及 300 条完整 raw phase events，不能仅凭 shape 或自报接受。",
        "继续取得原预取/损坏缓存/50 行阶段的源码对应证据；测量仅 CPU layer.contents 提交与 AX 正文、进程 sampled footprint/RSS，保留 periodic/gap 门与裁切边界。没有可比实测前值不宣称性能收益，不更改未确认错误的排队策略。"
    ]
    state["nextAction"] = "root 集中提交经审的 source-only 检查点后再执行一次独立 measurement workflow，按每组原始结果逐项验收；当前 runner 已接入代码但尚未提交，不查询或改写其他检查点状态。继续其他 ready 工作，不能将采集准备等同 native 验收或整包完成。"
    state["readyPreparation"] = [
        "逐 SHA 核对 runner 8、原测量 9 与纯解析器 16 文件；保留 v1/v2、修复前外移叶负例、独审 replay、全部作者 raw、A Debug link 与旧 UI 原始结构/环境证据。",
        "独立保留 memory、launch、UMD 的真实 leaf/source/environment/host 绑定；不把旧 UI 结构、synthetic 负例或文件 hash 当新 SDK 执行，不混入旧 TXT 与 stage 50 计数。"
    ]
    for path in (rel(BATCH), rel(DEST / "reader-measurements-runner-preparation-v2.json"),
                 rel(DEST / "reader-measurements-runner-independent-review.json"),
                 ".github/workflows/reader-measurements.yml", "scripts/reader-experience/reader-measurements.sh",
                 "scripts/reader-experience/collect-reader-measurements.py"):
        require(path not in state["evidence"], "Runner evidence already present")
        state["evidence"].append(path)
    validate_new_text({key: state[key] for key in ("currentState", "remainingWork", "nextAction", "readyPreparation")})
    # Reverse only the explicitly allowed performance fields and new reference.
    proof = copy.deepcopy(proposed)
    del proof["existingEvidence"][REG]
    prior = next(item for item in original["workpackages"] if item["id"] == WP)
    target = next(item for item in proof["workpackages"] if item["id"] == WP)
    target["existingEvidence"] = copy.deepcopy(prior["existingEvidence"])
    for key in ("currentState", "remainingWork", "nextAction", "readyPreparation", "evidence"):
        target["execution"][key] = copy.deepcopy(prior["execution"][key])
    require(proof == original, "Unrelated canonical field changed, including cloudPolicy/queues/other packages")
    return proposed


def replace_document(path, expected, data):
    require(read(path) == expected, "Document changed immediately before replacement: " + rel(path))
    temporary = path.with_name("." + path.name + ".runner-" + uuid.uuid4().hex + ".tmp")
    exclusive(temporary, data)
    require(read(path) == expected, "Document changed during replacement preparation")
    os.replace(temporary, path)
    require(read(path) == data, "Document replacement verification failed")


def main():
    require(len(sys.argv) == 1, "No arguments accepted")
    owned(DEST.parent)
    owned(BATCH.parent)
    require(not DEST.exists() and not DEST.is_symlink() and not BATCH.exists() and not BATCH.is_symlink(),
            "Refusing existing evidence/batch output, including reruns")
    prep, review, items, main_files, perf_files, umd_files = evidence()
    before = {path: read(path) for path in (PLAN, LAUNCH_BATCH, UMD_BATCH)}
    original, launch, umd = (parse(before[path]) for path in (PLAN, LAUNCH_BATCH, UMD_BATCH))
    require(manifest(launch["sourceBinding"]["files"], 9) == perf_files
            and manifest(umd["sourceBinding"]["files"], 16) == umd_files, "Existing batch source inventories changed")
    require(launch["measurementCloudSubmission"]["selectorsAddedToCI"] is False
            and launch["measurementCloudSubmission"]["submitted"] is False
            and umd["otherRunnerPreparation"]["submitted"] is False
            and umd["otherRunnerPreparation"].get("runnerCodePresent", False) is False,
            "A batch has already been integrated/submitted")
    proposed = update_plan(original)  # Deliberately use latest; do not pin an obsolete plan SHA.
    launch_after = copy.deepcopy(launch)
    launch_after["measurementCloudSubmission"]["selectorsAddedToCI"] = True
    launch_after["measurementCloudSubmission"]["submitted"] = False
    umd_after = copy.deepcopy(umd)
    umd_after["otherRunnerPreparation"]["runnerCodePresent"] = True
    umd_after["otherRunnerPreparation"]["submitted"] = False
    for old, new, key in ((launch, launch_after, "measurementCloudSubmission"), (umd, umd_after, "otherRunnerPreparation")):
        proof = copy.deepcopy(new)
        proof[key] = copy.deepcopy(old[key])
        require(proof == old, "Unrelated existing batch field changed")
    after = {PLAN: encoded(proposed), LAUNCH_BATCH: encoded(launch_after), UMD_BATCH: encoded(umd_after)}
    catalog_path = ROOT / "docs/legado-ios/feature-catalog.json"
    catalog = read(catalog_path)
    checker_path = ROOT / "scripts/reader-experience/check-completion-plan.py"
    checker_bytes = read(checker_path)
    spec = importlib.util.spec_from_file_location("measurements_runner_existing_plan_checker", checker_path)
    require(spec is not None and spec.loader is not None, "Cannot load existing checker")
    checker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(checker)
    checker.validate(original, parse(catalog), ROOT, require_execution=True)
    history_paths = [ROOT / path for path in (
        "docs/legado-ios/reading-comfort-batch.json", "docs/legado-ios/reader-supply-measurement-batch.json",
        "docs/legado-ios/previous-reader-smoke-audit.json", "docs/legado-ios/local-product-validation.json",
        "scripts/reader-experience/smoke.sh", ".github/workflows/reader-smoke.yml",
        "scripts/reader-experience/reader-stage-baseline.py", "scripts/reader-experience/test-reader-stage-baseline.py")]
    history = {rel(path): sha(read(path)) for path in history_paths}
    require(parse(read(history_paths[0]))["prefetchAndPerformanceReview"]["baselineCollection"]["expectedMetricRows"] == 50,
            "Historical fifty-row contract changed")
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT).decode("ascii").strip()
    require(re.fullmatch(r"[0-9a-f]{40}", head), "Invalid observed HEAD")
    script = read(Path(__file__).resolve())
    items.append({"name": Path(__file__).name, "source": rel(Path(__file__).resolve()),
                  "path": rel(DEST / Path(__file__).name), "bytes": len(script), "sha256": sha(script),
                  "kind": "executed-recorder-source", "data": script})
    mutations = {rel(path): {"beforeSHA256": sha(before[path]), "afterSHA256": sha(after[path]),
                            "beforeSnapshot": rel(DEST / (path.stem + ".before.json")),
                            "afterSnapshot": rel(DEST / (path.stem + ".after.json"))} for path in before}
    batch = {
        "schemaVersion": 1, "recordedOn": datetime.now(timezone.utc).date().isoformat(),
        "stageId": "s2-reading-experience", "workpackageId": WP,
        "status": "reviewed-runner-code-integrated-not-submitted-native-evidence-pending",
        "说明": "归档独立 runner 代码、原始 portable 与静态独审；已有旧 UI/A 编译资料只提供实际结构和 Debug 命名来源。本批尚未提交云测，不构成新 Swift/SDK/XCTest、UMD 产品导入、启动/内存或整阶段验收。",
        "stageComplete": False, **{key: False for key in GLOBAL_FLAGS},
        "sourceBinding": {"patchBaseCommit": BASE, "integratingHEADObserved": head,
                          "HEADNotUsedAsAcceptanceCommitForUncommittedChanges": True,
                          "eightMainFilesMatchFrozenReviewedByteHashes": True, "files": prep["files"],
                          "performanceNineMainFileHashesPreserved": list(perf_files.values()),
                          "UMDSixteenMainFileHashesPreserved": list(umd_files.values()),
                          "sourceInputsPlanned": 38, "checkpointCSource": C_SOURCE,
                          "includedInC": False, "includedInARelease12": False},
        "preparedSelections": prep["preparedGroups"], "bindingContract": prep["bindingContract"],
        "CIProtocolPrepared": prep["newCIProtocol"],
        "measurementCloudSubmission": {"runnerCodePresent": True, "selectorsAddedToCI": True, "submitted": False,
                                       "newRunID": None, "newTag": None, "awaitingEvidenceIsNotSubmission": True},
        "UMDBoundary": {"pureParserMethodsPlanned": 11, "actualSwiftExecutions": 0, "productImportSupported": False,
                        "localFormatsReadinessAndQueuesUnchanged": True},
        "localChecksAlreadyExecuted": {
            "authorV1PortableCollectorMethods": 20, "authorV2PortableCollectorMethods": 22,
            "authorSharedSmokeMethods": 24, "authorSharedStageMethods": 20,
            "uniqueOriginalAuthorRawLogs": 54, "sameChecksNotAccumulated": True,
            "v2Shared24Stage20BashReuseOriginalV1Logs": True,
            "authorBashSyntaxAndActionlintPassed": True, "shellcheckExecuted": False,
            "rootMainVerification": {"provenance": "root-tool-reported-only-no-new-raw-retained",
                                     "reportedPortableMethods": {"collector": 22, "shared": 24, "stage": 20},
                                     "reportedBashSyntaxExitCode": 0, "reportedDiffCheckExitCode": 0,
                                     "newRawEvidenceAvailable": False, "rawEvidenceFabricated": False,
                                     "reportMustNotBePromotedToHashVerifiedRaw": True},
            "testsRerunByRecorder": False, "SwiftTypecheckPerformed": False, "AppleSDKCompilationPerformed": False,
            "iOSTestsExecuted": 0, "actualLaunchSamples": 0, "actualMemorySamples": 0,
            "actualRawMemoryPhaseRows": 0, "actualUMDSwiftExecutions": 0},
        "historicalProtocol": {"oldTXTMethods": 1, "existingStagePortableMethods": 20, "existingMetricRows": 50,
                               "oldTXTOrStageSelectionsRunByNewRunner": False,
                               "newExpectedExecutions": {"memory": 1, "launch": 1, "umd": 11},
                               "innerSamplesPlanned": {"launch": 5, "memory": 10}, "rawMemoryPhaseRowsPlanned": 300},
        "resolvedFindings": review["resolvedFindings"],
        "historicalSourceContext": {"UIReference": prep["historicalUIStructureReference"],
                                    "debugReference": rel(DEST / "debug-payload-historical-reference.json"),
                                    "officialPinnedActionMetadataURL": prep["v2RootReviewFixes"][0]["officialPinnedActionMetadata"],
                                    "officialActionDefaultFalseCheckProvenance": "root-reported exact pinned action.yml read; this preparation contains URL only, no invented local download",
                                    "historicalInputsAreNotNewSelectorExecution": True},
        "retainedEvidence": [{key: value for key, value in item.items() if key not in ("data", "name")} for item in items],
        "historicalEvidencePreservedSHA256": history, "limits": prep["limits"],
        "documentMutations": mutations,
        "canonicalPlanMutation": {"path": rel(PLAN), "beforeSHA256": sha(before[PLAN]), "afterSHA256": sha(after[PLAN]),
                                  "stageCount": 8, "workpackageCount": 33, "featureDomainCount": 64,
                                  "allFourGlobalFlagsRemainFalse": True, "existingCheckerResult": rel(DEST / "plan-check.json"),
                                  "allQueuesCloudPolicyDependenciesOwnersOtherPackagesUnchanged": True,
                                  "onlyPerformanceExecutionAndNewEvidenceReferenceChanged": True},
        "recorderActions": {"gitMutation": False, "networkOrCIQueriedOrTriggered": False, "privateSourcesRead": False,
                            "testsRerun": False, "latestCanonicalReadAtExecution": True,
                            "multiDocumentCrashAtomicityClaimed": False,
                            "COrAResultReclassified": False, "AReleaseRebuilt": False}
    }
    validate_new_text(batch)
    # Everything above is validation/read-only. Only the root's explicit invocation reaches this point.
    DEST.mkdir(exist_ok=False)
    for item in items:
        exclusive(DEST / item["name"], item["data"])
    for path in before:
        exclusive(DEST / (path.stem + ".before.json"), before[path])
        exclusive(DEST / (path.stem + ".after.json"), after[path])
    exclusive(BATCH, encoded(batch))
    result = checker.validate(proposed, parse(catalog), ROOT, require_execution=True)
    require(result["status"] == "passed" and (result["stageCount"], result["workpackageCount"], result["featureDomainCount"]) == (8, 33, 64),
            "Existing canonical checker did not pass")
    result["inputSHA256"] = {rel(PLAN): sha(after[PLAN]), rel(catalog_path): sha(catalog)}
    exclusive(DEST / "plan-check.json", encoded(result))
    require(all(read(path) == data for path, data in before.items()), "Latest documents changed; refusing stale replacement")
    require(read(catalog_path) == catalog and read(checker_path) == checker_bytes, "Catalog/checker changed while recording")
    require(all(sha(read(path)) == history[rel(path)] for path in history_paths), "Historical evidence changed while recording")
    for inventory in (main_files, perf_files, umd_files):
        verify_main(inventory)
    for path in (LAUNCH_BATCH, UMD_BATCH, PLAN):
        replace_document(path, before[path], after[path])
    require(all(read(path) == after[path] for path in after), "Final document byte verification failed")
    print(json.dumps({"record": rel(BATCH), "recordSHA256": sha(read(BATCH)), "archivedInputs": len(items),
                      "originalAuthorRawLogs": 54, "planSHA256": sha(after[PLAN]), "planStructureCheck": "passed",
                      "newNativeExecutionsOrMeasurementSamples": 0, "runnerSubmitted": False,
                      "cloudPoliciesAndQueuesChanged": False}))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"{type(error).__name__}: {error}; existing evidence is never overwritten; inspect any fresh partial outputs and document snapshots.", file=sys.stderr)
        sys.exit(1)
