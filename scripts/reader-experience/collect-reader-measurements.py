#!/usr/bin/env python3
"""Bind separate source-only measurement/UMD selections to real XCTest evidence.

The imported reader-launch-memory.py remains shape-only. This gate additionally
requires the exact passing XCTest identities, committed source, audited local
overlays, actual Debug Simulator environment and retained original artifacts.
No result accepts product UMD import, device-cold, GPU paint or an improvement.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import sys

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


stage = module("measurements_stage_environment", "reader-stage-baseline.py")
shape = module("measurements_shape_only", "reader-launch-memory.py")
smoke, config = stage.smoke, stage.config
UMD_METHODS = tuple("UMDTextDecoderTests/" + name + "()" for name in (
    "matchesOriginalJavaFixtures", "rejectsEveryTruncatedPrefix", "rejectsImagesKeysAndUnknownSections",
    "rejectsInvalidLengthsAndEndMarker", "rejectsInvalidChapterOffsets", "rejectsInvalidUTF16AndSurrogateBoundary",
    "rejectsCorruptedZlibAndUnconsumedTail", "rejectsMismatchedRecordIdentity", "enforcesAllBudgets",
    "observesCancellation", "fileParserRetainsSnapshotAndEnforcesInputBudget"))
GROUPS = {
    "memory": {"target": "yuedu appTests", "bundle": "Unit test bundle",
               "methods": ("ReaderProcessMemoryMeasurementsTests/sampleOwnedCoreTextChapters()",)},
    "launch": {"target": "yuedu appUITests", "bundle": "UI test bundle",
               "methods": ("ReaderProcessLaunchMeasurementsUITests/testFiveProcessLaunchesToSubmittedReadableTXTAnchor()",)},
    "umd": {"target": "yuedu appTests", "bundle": "Unit test bundle", "methods": UMD_METHODS},
}
PERF_SOURCES = (
    "Modules/Core/ReaderCore/CoreText/CoreTextPageView.swift", "Tests/iOS-UI/ReaderLocalSmokeUITests.swift",
    "Tests/iOS-UI/ReaderLocalTXTScenarioTestCase.swift", "Tests/iOS-UI/ReaderProcessLaunchMeasurementsUITests.swift",
    "Tests/iOS/yuedu appTests/CoreTextPerformanceFixtures.swift",
    "Tests/iOS/yuedu appTests/ReaderArchitectureBenchmarkTests.swift",
    "Tests/iOS/yuedu appTests/ReaderProcessMemoryMeasurementsTests.swift",
    "scripts/reader-experience/reader-launch-memory.py", "scripts/reader-experience/test-reader-launch-memory.py")
UMD_FIXTURES = "Tests/iOS/yuedu appTests/Fixtures/UMD/"
UMD_IDS = ("chinese-two-chapters", "cross-compression-blocks", "multi-chapter-optional-metadata", "non-bmp-utf16", "paragraph-separators")
UMD_SOURCES = ("Modules/Core/UMD/UMDBookParser.swift", "Modules/Core/UMD/UMDTextDecoder.swift",
    "Tests/iOS/yuedu appTests/UMDTextDecoderTests.swift", UMD_FIXTURES + "provenance.json",
    "scripts/reader-experience/inspect-umd-fixtures.py", "scripts/reader-experience/test-umd-fixtures.py") + tuple(
        UMD_FIXTURES + identity + "/" + name for identity in UMD_IDS for name in ("fixture.umd", "reader-output.json"))
UI_FIXTURES = {
    "docs/legado-ios/fixtures/reader-measurements-ui-tests-39146602853.json": "5868bc2b0c9cb43ae465e4ea5a03292c13fb47bc125bc43fc0d3a65042c7cbde",
    "docs/legado-ios/fixtures/reader-measurements-ui-summary-39146602853.json": "422b43e5e6f671d84b115864216ba33cb3b47c8df25b7d78ffd4cfd623dc34ec",
}
SOURCE_FILES = (*PERF_SOURCES, *UMD_SOURCES, *UI_FIXTURES,
    "scripts/reader-experience/reader-measurements.sh", ".github/workflows/reader-measurements.yml",
    "scripts/reader-experience/collect-reader-measurements.py", "scripts/reader-experience/test-collect-reader-measurements.py",
    "scripts/reader-experience/smoke-tools.py", "scripts/reader-experience/test-smoke-tools.py",
    "scripts/reader-experience/stage-config.py", "scripts/reader-experience/reader-stage-baseline.py",
    "scripts/sim.sh", "scripts/xctest.sh", "Tests/iOS/yuedu appTests/EPUBTestFixtures.swift")


def require(value, message):
    if not value:
        raise ValueError(message)


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def object_json(path):
    return shape.strict_json(config.checked_path(path).read_text(encoding="utf-8"))


def evidence(path):
    path = config.checked_path(path)
    require(path.is_file(), "Missing regular evidence file: " + str(path))
    require(path.stat().st_size <= 512 * 1024**2, "Evidence file exceeds 512MiB")
    with path.open("rb") as stream:
        value = hashlib.file_digest(stream, "sha256").hexdigest()
    return {"path": str(path), "bytes": path.stat().st_size, "sha256": value}


def source_inventory(read_source):
    """Review simple declared signatures; source inventory is never execution."""
    memory = read_source(PERF_SOURCES[6]).decode("utf-8")
    launch = read_source(PERF_SOURCES[3]).decode("utf-8")
    umd = read_source("Tests/iOS/yuedu appTests/UMDTextDecoderTests.swift").decode("utf-8")
    require(re.findall(r"^\s*func (\w+)\(\) async throws \{", memory, re.MULTILINE) == ["sampleOwnedCoreTextChapters"]
            and len(re.findall(r"^\s*@Test\b", memory, re.MULTILINE)) == 1, "Memory source selection changed")
    require(re.findall(r"^\s*func (test\w+)\(\) async throws \{", launch, re.MULTILINE)
            == ["testFiveProcessLaunchesToSubmittedReadableTXTAnchor"]
            and re.findall(r"\bfunc (test\w+)\(", launch) == ["testFiveProcessLaunchesToSubmittedReadableTXTAnchor"],
            "Launch source selection changed")
    require("ReaderProcessLaunchMeasurementsUITests: ReaderLocalTXTScenarioTestCase" in launch,
            "Launch must not inherit the old smoke test")
    base = read_source(PERF_SOURCES[2]).decode("utf-8")
    old = read_source(PERF_SOURCES[1]).decode("utf-8")
    require(not re.findall(r"\bfunc test\w+\(", base)
            and re.findall(r"\bfunc (test\w+)\(", old) == ["testTXTImportTOCAndProgressSurviveRelaunch"],
            "Old TXT identity or no-test helper changed")
    names = re.findall(r"^\s*func (\w+)\(\)(?: async)? throws \{", umd, re.MULTILINE)
    require(set("UMDTextDecoderTests/" + name + "()" for name in names) == set(UMD_METHODS)
            and len(names) == len(UMD_METHODS) == len(re.findall(r"^\s*@Test\b", umd, re.MULTILINE)),
            "UMD source selection changed or became parameterized")


def source_provenance():
    result = {}
    require(len(SOURCE_FILES) == len(set(SOURCE_FILES)), "Duplicate source binding")
    def read_source(name):
        raw = config.checked_path(REPO / name).read_bytes()
        require(raw == smoke.git("show", "HEAD:" + name, binary=True), "Source differs from committed HEAD: " + name)
        result[name] = {"bytes": len(raw), "sha256": digest(raw)}
        return raw
    for name in SOURCE_FILES:
        read_source(name)
    source_inventory(read_source)
    for path, expected in UI_FIXTURES.items():
        require(result[path]["sha256"] == expected, "Historical UI structure fixture changed")
    provenance_raw = read_source(UMD_FIXTURES + "provenance.json")
    require(digest(provenance_raw) == "e77c071c9f821ae63dfd14d233a627b9cc6c9061e9ab2de864699f513194a2c4", "Frozen UMD golden provenance changed")
    provenance = shape.strict_json(provenance_raw.decode("utf-8"))
    require(provenance["referenceRecordSHA256"] == "fde4be8b82780807741a2f19d3bc6bfbcedabfa6b74a41a74eeb6fdfc60c345a"
            and provenance["bundleManifestSHA256"] == "aa9b128ba7ff51e524af0ef1d905860d6599e9f71426bc484544ed1344110719",
            "UMD original reference identity changed")
    expected = {identity + "/" + name for identity in UMD_IDS for name in ("fixture.umd", "reader-output.json")}
    require(len(provenance["files"]) == 10 and {entry["path"] for entry in provenance["files"]} == expected,
            "UMD fixture inventory changed")
    for entry in provenance["files"]:
        require(result[UMD_FIXTURES + entry["path"]] == {"bytes": entry["bytes"], "sha256": entry["sha256"]}, "UMD fixture digest differs")
    return result


def context():
    source = smoke.validate_tag("reader-measurements-")
    result = {"sourceCommit": source}
    for key in ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT"):
        value = os.environ.get(key)
        require(type(value) is str and re.fullmatch(r"[1-9][0-9]*", value), "Missing same-run CI context: " + key)
        result[key] = value
    return result


def validate_binding(audit_path, environment_path):
    audit = object_json(audit_path)
    smoke.review_overlays(audit)  # prepare() has already created these audited overlays.
    smoke.require_source_stamp(plistlib.loads((REPO / smoke.INFO).read_bytes()), audit["sourceCommit"])
    environment = stage.validate_environment(object_json(environment_path))
    require(environment["sourceCommit"] == audit["sourceCommit"] == context()["sourceCommit"], "Environment/source differs")
    require(environment["sourceFiles"] == stage.source_provenance(), "Shared environment source changed")
    for entry in environment["inputEvidence"].values():
        require(evidence(Path(entry["path"]))["sha256"] == entry["sha256"], "Environment raw input changed")
    require(environment["inputEvidence"]["audit"]["sha256"] == evidence(audit_path)["sha256"], "Overlay audit differs")
    return environment


def prepare(audit, environment, output):
    require(not output.exists(), "Refusing prior preparation")
    env = validate_binding(audit, environment)
    value = {"schemaVersion": 1, "kind": "reader-measurements-preparation", "context": context(),
             "preparedAtUTC": datetime.now(timezone.utc).isoformat(), "sourceInputs": source_provenance(),
             "environment": evidence(environment), "audit": evidence(audit),
             "expectedGroups": GROUPS, "measurementFixtures": shape.fixture_protocol(),
             "launchFixture": shape.launch_fixture_protocol(),
             "historicalUITreeReference": {"runID": 39146602853, "sourceCommit": "97d9f0f208369cd32766cf7d0391a6b2936d03b2",
                 "purpose": "Original modern UI container structure only; not execution of new launch method.", "files": UI_FIXTURES},
             "environmentScope": "Shared stage capture validates actual environment only; no old fifty-row stage execution is claimed.",
             "preparedDestination": env["destination"], "actualSelectedXCTestExecutionValidated": False}
    config.write_new_json(output, value)
    return value


def verify_tree(tree, target, bundle_kind, methods):
    require(type(tree) is dict and type(tree.get("testNodes")) is list and len(tree["testNodes"]) == 1,
            "Missing single actual test plan")
    require(tree["testNodes"][0].get("nodeType") == "Test Plan", "Unknown test-plan root")
    found, bundles = set(), []
    def visit(node, inside_bundle=False, is_root=False):
        require(type(node) is dict, "Malformed test node")
        kind = node.get("nodeType")
        require(kind in ("Test Plan", bundle_kind, "Test Suite", "Test Case"), "Unknown/wrong-group node type: " + str(kind))
        children = node.get("children", [])
        require(type(children) is list, "Malformed test children")
        if kind == "Test Case":
            require(inside_bundle, "Test method is outside its selected target bundle")
            name = node.get("nodeIdentifier")
            require(type(name) is str, "Missing actual method identity")
            identity = name.removeprefix(target + "/")
            require(identity in methods and identity not in found and node.get("result") == "Passed" and not children,
                    "Unexpected/duplicate/failed/skipped method: " + name)
            found.add(identity)
        else:
            require(children and ("result" not in node or node["result"] == "Passed"), "Empty or nonpassing test container")
            if kind == "Test Plan":
                require(is_root, "Nested test plan is not a selected target tree")
            if kind == bundle_kind:
                require(not inside_bundle, "Nested target bundles are not permitted")
                require(node.get("name") == target, "Wrong actual test target")
                bundles.append(node)
        for child in children:
            visit(child, inside_bundle or kind == bundle_kind)
    visit(tree["testNodes"][0], is_root=True)
    require(found == set(methods) and len(bundles) == 1, "Missing exact source methods or unique target bundle")
    return sorted(found)


def verify_execution(summary, tree, group, test_status, artifact_status, environment):
    require(type(test_status) is int and test_status == 0 and type(artifact_status) is int and artifact_status == 0,
            "XCTest wrapper or original artifact export failed")
    selection = GROUPS[group]
    counts = smoke.verify_summary(summary, len(selection["methods"]), len(selection["methods"]))
    require(summary.get("result") == "Passed" and summary.get("testFailures") == [], "Original summary not clean Passed")
    methods = verify_tree(tree, selection["target"], selection["bundle"], selection["methods"])
    devices = tree.get("devices")
    require(type(devices) is list and len(devices) == 1 and type(devices[0]) is dict, "Missing single original test device")
    actual = summary["devicesAndConfigurations"][0]
    require(actual.get("device") == devices[0], "Summary/tree devices differ")
    device = devices[0]
    require(device.get("deviceId") == environment["destination"][3:] and device.get("platform") == "iOS Simulator"
            and device.get("osVersion") == environment["runtimeVersion"] and device.get("osBuildNumber") == environment["runtimeBuild"],
            "Actual XCTest device/runtime differs from captured destination")
    require(tree.get("testPlanConfigurations") == [actual.get("testPlanConfiguration")]
            and type(actual.get("testPlanConfiguration")) is dict, "Actual test configuration differs")
    return {"counts": counts, "passedMethodIdentities": methods, "device": device}


def retain_raw(log, output, group):
    require(not output.exists(), "Refusing prior raw rows")
    markers = {"launch": (shape.LAUNCH.encode(),), "memory": (shape.MEMORY.encode(), shape.PHASE.encode()), "umd": ()}[group]
    raw = bytearray()
    original = evidence(log)
    with config.checked_path(log).open("rb") as stream:
        for line in stream:
            if any(marker in line for marker in markers):
                require(len(line) <= 8 * 1024**2 and len(raw) + len(line) <= 64 * 1024**2, "Raw observation budget exceeded")
                raw.extend(line)
    output.parent.mkdir(parents=True, exist_ok=True)
    with config.checked_path(output).open("xb") as stream:
        stream.write(raw)
    require(evidence(log) == original, "Dedicated XCTest log changed while retaining rows")
    return bytes(raw), original


def tested_host(environment):
    settings = object_json(Path(environment["inputEvidence"]["settings"]["path"]))
    matches = [item.get("buildSettings") for item in settings if item.get("target") == config.MAIN_TARGET]
    require(len(matches) == 1 and type(matches[0]) is dict, "Missing unique actual host settings")
    actual = matches[0]
    for name, expected in {"CONFIGURATION": "Debug", "PLATFORM_NAME": "iphonesimulator", "SWIFT_VERSION": "5.0",
                           "PRODUCT_BUNDLE_IDENTIFIER": config.MAIN_BUNDLE}.items():
        require(actual.get(name) == expected, "Unexpected host setting: " + name)
    app = config.checked_path(Path(actual["TARGET_BUILD_DIR"]) / actual["FULL_PRODUCT_NAME"])
    info = config.read_info(app)
    smoke.require_local_info(info)
    smoke.require_source_stamp(info, environment["sourceCommit"])
    require(info.get("CFBundleIdentifier") == config.MAIN_BUNDLE and info.get("CFBundleSupportedPlatforms") == ["iPhoneSimulator"], "Wrong tested app")
    require(plistlib.loads((app / "GoogleService-Info.plist").read_bytes()) == config.synthetic_config(), "Tested host is not exactly synthetic")
    config.no_jvm_payload(app)
    executable = info.get("CFBundleExecutable")
    require(type(executable) is str and executable not in ("", ".", "..") and Path(executable).name == executable
            and "/" not in executable and "\\" not in executable, "Invalid executable basename")
    debug_flag = actual.get("ENABLE_DEBUG_DYLIB")
    require(type(debug_flag) is str and debug_flag in ("YES", "NO"), "Missing explicit actual ENABLE_DEBUG_DYLIB setting")
    executable_evidence = evidence(app / executable)
    require(executable_evidence["bytes"] > 0, "Empty tested executable")
    debug_payload = None
    declared_path = actual.get("EXECUTABLE_DEBUG_DYLIB_PATH")
    path_origin = "disabled-by-actual-setting"
    if debug_flag == "YES":
        # Actual A Debug link/settings retain YueduReader.app/YueduReader.debug.dylib.
        # In this mode the CFBundleExecutable is the launch stub, not all main code.
        # The historical actual -showBuildSettings JSON contains ENABLE_DEBUG_DYLIB
        # but not always this derived path field; preserve that absence as null.
        require(declared_path is None or declared_path == app.name + "/" + executable + ".debug.dylib",
                "Actual debug payload path differs from executable/settings")
        path_origin = "actual-build-setting-validated" if declared_path is not None else "actual-executable-basename-and-observed-debug-dylib-suffix"
        debug_payload = evidence(app / (executable + ".debug.dylib"))
        require(debug_payload["bytes"] > 0, "Empty tested debug payload")
    return {"app": str(app), "info": evidence(app / "Info.plist"), "executable": executable_evidence,
            "ENABLE_DEBUG_DYLIB": debug_flag, "EXECUTABLE_DEBUG_DYLIB_PATH": declared_path,
            "mainDebugPayload": debug_payload, "debugPayloadPathOrigin": path_origin,
            "payloadIdentityScope": "Built file identities only; hashes do not attest which instructions executed.",
            "syntheticConfiguration": evidence(app / "GoogleService-Info.plist")}


def collect(args):
    require(not args.output.exists() and not args.raw.exists(), "Refusing previous group evidence")
    require(len({path.resolve() for path in (args.output, args.raw, args.log, args.summary, args.tests, args.preparation, args.audit, args.environment)}) == 8,
            "Evidence input/output paths overlap")
    report = {"schemaVersion": 1, "kind": "reader-measurements-bound-group", "group": args.group,
              "selectedXCTestExecutionValidated": False, "measurementSamplesValidated": False,
              "physicalDeviceMeasured": False, "deviceColdMeasured": False, "GPUPresentationMeasured": False,
              "performanceImprovementEstablished": False, "UMDProductImportSupported": False,
              "testExitStatus": args.test_exit_status, "artifactExitStatus": args.artifact_exit_status,
              "limitations": ["Committed runner/CI result and original artifact/source/environment hashes remain required for audit.",
                  "Launch is CPU submission plus AX text under automation, not GPU/device-cold; memory is a sampled XCTest-host interval including overhead.",
                  "The fixed memory child viewport need not fit entirely inside a small scene. Five observations are not p95 or an improvement.",
                  "UMD is a pure parser/owned-fixture selection, not product import, MOBI, cover, DRM or device acceptance."]}
    try:
        # Raw original marker lines survive a failed wrapper, missing summary or later validation.
        raw, log_evidence = retain_raw(args.log, args.raw, args.group)
        report["dedicatedXcodebuildLog"] = log_evidence
        report["rawRows"] = evidence(args.raw)
        environment = validate_binding(args.audit, args.environment)
        prepared = object_json(args.preparation)
        source = source_provenance()
        require(prepared.get("kind") == "reader-measurements-preparation" and type(prepared.get("schemaVersion")) is int and prepared["schemaVersion"] == 1
                and prepared.get("context") == context() and prepared.get("sourceInputs") == source
                and prepared.get("audit") == evidence(args.audit) and prepared.get("environment") == evidence(args.environment)
                and prepared.get("measurementFixtures") == shape.fixture_protocol() and prepared.get("launchFixture") == shape.launch_fixture_protocol()
                and json.dumps(prepared.get("expectedGroups"), sort_keys=True) == json.dumps(GROUPS, sort_keys=True),
                "Preparation/source/run/environment binding differs")
        report["execution"] = verify_execution(object_json(args.summary), object_json(args.tests), args.group,
                                               args.test_exit_status, args.artifact_exit_status, environment)
        require(args.result_bundle.is_dir() and args.result_bundle.name == args.group + ".xcresult", "Wrong original result bundle")
        report["originalInputs"] = {name: evidence(path) for name, path in (
            ("summary", args.summary), ("tests", args.tests), ("preparation", args.preparation),
            ("audit", args.audit), ("environment", args.environment), ("resultBundleInfo", args.result_bundle / "Info.plist"))}
        report["testedHost"] = tested_host(environment)
        if args.group == "launch":
            report["observations"] = shape.validate_launch(shape.rows(raw, shape.LAUNCH))
        elif args.group == "memory":
            report["observations"] = shape.validate_memory(shape.rows(raw, shape.MEMORY), shape.rows(raw, shape.PHASE))
        report.update(context=context(), environment=environment, sourceInputs=source)
        require(source_provenance() == source and validate_binding(args.audit, args.environment) == environment
                and evidence(args.log) == log_evidence, "Source/environment/raw log changed during collection")
        for entry in report["originalInputs"].values():
            require(evidence(Path(entry["path"])) == entry, "Original test artifact changed during collection")
        require(tested_host(environment) == report["testedHost"], "Tested host payload changed during collection")
        report["selectedXCTestExecutionValidated"] = True
        report["measurementSamplesValidated"] = args.group in ("launch", "memory")
    except Exception as error:
        report["error"] = type(error).__name__ + ": " + str(error)
    config.write_new_json(args.output, report)
    print(json.dumps({"group": args.group, "output": str(args.output),
                      "selectedXCTestExecutionValidated": report["selectedXCTestExecutionValidated"]}))
    return 0 if report["selectedXCTestExecutionValidated"] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="phase", required=True)
    prepare_command = commands.add_parser("prepare")
    for name in ("audit", "environment", "output"):
        prepare_command.add_argument("--" + name, type=Path, required=True)
    collect_command = commands.add_parser("collect")
    collect_command.add_argument("--group", choices=tuple(GROUPS), required=True)
    for name in ("audit", "environment", "preparation", "log", "summary", "tests", "result-bundle", "raw", "output"):
        collect_command.add_argument("--" + name, type=Path, required=True)
    collect_command.add_argument("--test-exit-status", type=int, required=True)
    collect_command.add_argument("--artifact-exit-status", type=int, required=True)
    args = parser.parse_args()
    try:
        if args.phase == "prepare":
            print(json.dumps(prepare(args.audit, args.environment, args.output), ensure_ascii=False, indent=2))
            return 0
        return collect(args)
    except Exception as error:
        print(type(error).__name__ + ": " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
