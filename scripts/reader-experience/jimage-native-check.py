#!/usr/bin/env python3
"""Bind the clean-reader jimage checks to their actual source, host and test leaves."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import sys


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
CASES = {
    "mainjs": "LegadoNativeMainJSReaderTests/testNativeMainJSProductReadingChain()",
    "original-public": "LegadoNativeOriginalReaderTests/testNativeOriginalPublicConsumersUseOwnedReaderAndOfflineReopen()",
    "original-preview": "LegadoNativeOriginalReaderTests/testNativeOriginalWebBookPreviewTransferAndReopen()",
}
PACKAGE_CASES = {
    "testModuleImageValidHeader", "testModuleImageRejectsUnsupportedVersion",
    "testModuleImageRejectsTruncatedIndex",
}


def require(value, message):
    if not value:
        raise ValueError(message)


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


config = load("jimage_reader_config", "stage-config.py")
smoke = load("jimage_reader_smoke_helpers", "smoke-tools.py")


def sha(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write(path, value):
    config.write_new_json(Path(path), value)


def source():
    value = smoke.source_sha()
    require(os.environ.get("GITHUB_SHA") == value
            and os.environ.get("GITHUB_REF_NAME") == "reader-legado-" + value[:7],
            "Expected this exact clean-reader source tag")
    return value


def image(path):
    path = config.checked_path(Path(path))
    require(path.is_file(), "The module image must be a regular file")
    with path.open("rb") as stream:
        header = stream.read(28)
    require(len(header) == 28, "Truncated jimage header")
    endian = "<" if struct.unpack_from("<I", header)[0] == 0xCAFEDADA else ">"
    magic, version, flags, resources, table, locations, strings = struct.unpack(endian + "7I", header)
    require(magic == 0xCAFEDADA and version == 0x00010001,
            "Expected the standard jimage format version 1.1")
    index_bytes = 28 + table * 8 + locations + strings
    require(resources > 0 and table > 0 and index_bytes <= path.stat().st_size,
            "Invalid or truncated jimage index")
    return {"bytes": path.stat().st_size, "sha256": sha(path), "majorVersion": 1,
            "minorVersion": 1, "resourceCount": resources, "tableLength": table,
            "indexBytes": index_bytes, "flags": flags, "byteOrder": endian}


def prepare(work):
    revision = source()
    require(not smoke.git("status", "--porcelain", "--untracked-files=no"),
            "Native reader checks require a clean tracked checkout")
    work = config.checked_path(work)
    work.mkdir(parents=True, exist_ok=True)
    require(not (work / "overlays.json").exists(), "Preserve prior native-check evidence")
    originals = {"Info.plist": (REPO / "Info.plist").read_bytes(),
                 config.PROJECT: (REPO / config.PROJECT).read_bytes()}
    for name, raw in originals.items():
        require(raw == smoke.git("show", "HEAD:" + name, binary=True), "Changed source before overlay")
    require(not (REPO / "GoogleService-Info.plist").exists(), "Do not overwrite existing Firebase configuration")
    synthetic = None
    project = None
    info = None
    try:
        synthetic = config.stage(REPO / "GoogleService-Info.plist")
        project = config.overlay_project(REPO / config.PROJECT, work / "project-overlay.json")
        info = smoke.overlay_info(REPO / "Info.plist", work / "info-overlay.json", revision)
        audit = {"schemaVersion": 1, "sourceCommit": revision, "projectOverlay": project,
                 "infoOverlay": info, "syntheticConfiguration": synthetic,
                 "scope": "Required native Simulator checks only; all fixtures are owned loopback data."}
        smoke.review_overlays(audit)
        write(work / "overlays.json", audit)
    except BaseException:
        # Restore only bytes this invocation installed, never a later/unrelated edit.
        for name, record in (("Info.plist", info), (config.PROJECT, project)):
            if record is not None and sha(REPO / name) == record["overlaySHA256"]:
                (REPO / name).write_bytes(originals[name])
        if synthetic is not None and sha(REPO / "GoogleService-Info.plist") == synthetic["sha256"]:
            (REPO / "GoogleService-Info.plist").unlink()
        raise


def restore(work):
    audit_path = work / "overlays.json"
    if not audit_path.exists():
        return
    audit = json.loads(audit_path.read_bytes())
    require(audit["sourceCommit"] == source(), "Source changed during native validation")
    records = (audit["infoOverlay"], audit["projectOverlay"])
    for record in records:
        require(sha(REPO / record["path"]) == record["overlaySHA256"],
                "Refusing to overwrite changed validation overlay")
        raw = smoke.git("show", "HEAD:" + record["path"], binary=True)
        require(hashlib.sha256(raw).hexdigest() == record["originalSHA256"],
                "Original source differs from validation audit")
    synthetic = REPO / "GoogleService-Info.plist"
    require(sha(synthetic) == audit["syntheticConfiguration"]["sha256"],
            "Refusing to delete changed synthetic configuration")
    for record in records:
        (REPO / record["path"]).write_bytes(smoke.git("show", "HEAD:" + record["path"], binary=True))
    synthetic.unlink()
    require(not smoke.git("status", "--porcelain", "--untracked-files=no"),
            "Tracked source was not restored after native checks")
    write(work / "source-restored.json", {"sourceCommit": source(), "trackedSourceRestored": True,
                                         "ownedSyntheticConfigurationRemoved": True})


def verify_package(log_path, output):
    text = log_path.read_text(encoding="utf-8", errors="replace")
    cases = re.findall(r"^Test Case .*?\b(testModuleImage\w+)\b.*? (passed|failed|skipped) \(", text, re.MULTILINE)
    require(len(cases) == 3 and {name for name, _ in cases} == PACKAGE_CASES
            and all(status == "passed" for _, status in cases),
            "Expected exactly the three passing module-image diagnostic methods")
    require(re.search(r"Executed 3 tests?, with 0 failures? \(0 unexpected\)", text)
            and not re.search(r"\b[1-9][0-9]* tests? skipped\b|^Test Case .* (failed|skipped) ", text, re.MULTILINE),
            "Package diagnostics were incomplete, skipped or failed")
    write(output, {"sourceCommit": source(), "passedMethods": sorted(PACKAGE_CASES),
                   "passedTests": 3, "skippedTests": 0, "failedTests": 0,
                   "logSHA256": sha(log_path), "sourceOnly": True})


def merge_settings(work):
    selected = []
    for filename, target in (("app-build-settings.json", "yuedu app"),
                             ("test-build-settings.json", "yuedu appTests")):
        items = json.loads((work / filename).read_bytes())
        require(isinstance(items, list), "Build settings must be a target list")
        matches = [item for item in items if isinstance(item, dict) and item.get("target") == target]
        require(len(matches) == 1 and isinstance(matches[0].get("buildSettings"), dict),
                "Expected exactly one actual build-settings record for " + target)
        selected.append(matches[0])
    write(work / "build-settings.json", selected)


def host(work):
    revision = source()
    smoke.review_overlays(json.loads((work / "overlays.json").read_bytes()))
    settings = json.loads((work / "build-settings.json").read_bytes())
    require(isinstance(settings, list) and len(settings) == 2, "Expected exactly two merged target settings")
    selected = {item["target"]: item["buildSettings"] for item in settings
                if item.get("target") in ("yuedu app", "yuedu appTests")}
    require(set(selected) == {"yuedu app", "yuedu appTests"}, "Missing actual app/test-host build settings")
    for name, values in selected.items():
        require(values.get("CONFIGURATION") == "Debug" and values.get("PLATFORM_NAME") == "iphonesimulator"
                and values.get("YUEDU_LOCAL_EXPERIENCE") == "YES"
                and values.get("ENABLE_DEBUG_DYLIB") == "NO"
                and all(flag in values.get("OTHER_SWIFT_FLAGS", "")
                        for flag in ("LEGADO_REQUIRE_NATIVE_MAINJS", "LEGADO_REQUIRE_MODULE_IMAGE"))
                and values.get("CODE_SIGN_ENTITLEMENTS", "") == "",
                "Actual Simulator native-required/local-mode settings differ for " + name)
    values = selected["yuedu app"]
    require(values.get("PRODUCT_BUNDLE_IDENTIFIER") == config.MAIN_BUNDLE, "Unexpected native host identity")
    app = config.checked_path(Path(values["TARGET_BUILD_DIR"]) / values["FULL_PRODUCT_NAME"])
    info = plistlib.loads((app / "Info.plist").read_bytes())
    smoke.require_local_info(info)
    smoke.require_source_stamp(info, revision)
    staged = image(REPO / "Resources/LegadoRuntime/java-home/lib/modules")
    actual = image(app / "lib/lib/modules")
    require(actual == staged and not list(app.rglob("*.class")), "Actual host differs from the staged jimage or has loose classes")
    staged_jar = REPO / "Resources/LegadoRuntime/legado-runtime.jar"
    actual_jar = app / "LegadoRuntime/legado-runtime.jar"
    require(sha(actual_jar) == sha(staged_jar), "Native host ordinary JAR differs from staging")
    actual_manifest = app / "LegadoRuntime/runtime-manifest.json"
    require(sha(actual_manifest) == sha(REPO / "Resources/LegadoRuntime/runtime-manifest.json"),
            "Native host runtime manifest differs from staging")
    destination = (work / "destination.txt").read_text().strip()
    require(re.fullmatch(r"id=[0-9a-fA-F-]{36}", destination), "Expected a resolved Simulator UDID")
    simulator_id = destination[3:]
    inventory = json.loads((work / "simulators.json").read_bytes())
    devices = [(runtime, device) for runtime, devices in inventory["devices"].items()
               for device in devices if device.get("udid") == simulator_id and device.get("isAvailable") is True]
    require(len(devices) == 1, "Selected Simulator is absent or unavailable")
    runtime_id, device = devices[0]
    runtimes = [runtime for runtime in inventory["runtimes"] if runtime.get("identifier") == runtime_id]
    require(len(runtimes) == 1 and runtimes[0].get("isAvailable") is True, "Selected Simulator runtime is unavailable")
    executable = app / info["CFBundleExecutable"]
    export_verifier = REPO / "scripts/legado-ios/verify-native-exports.py"
    export_report = work / "native-exports.json"
    subprocess.run([sys.executable, "-B", str(export_verifier), "--executable", str(executable),
                    "--report", str(export_report), "--module-image"], check=True)
    record = {"schemaVersion": 1, "sourceCommit": revision, "appPath": str(app),
              "executableSHA256": sha(executable), "infoSHA256": sha(app / "Info.plist"),
              "nativeExportsSHA256": sha(export_report), "nativeExportVerifierSHA256": sha(export_verifier),
              "ordinaryJarSHA256": sha(actual_jar), "jimage": actual,
              "runtimeManifestSHA256": sha(actual_manifest), "settingsSHA256": sha(work / "build-settings.json"),
              "destination": destination, "device": device, "runtime": runtimes[0],
              "developerDirectory": os.environ["DEVELOPER_DIR"], "nativeRequired": True,
              "localMode": True, "configuration": "Debug", "physicalDeviceAcceptance": False}
    write(work / "host.json", record)


def verify_case(summary, tests, expected):
    counts = smoke.verify_summary(summary, 1, 1)
    found = []
    runtime_warnings = []
    def visit(node):
        require(isinstance(node, dict), "Malformed test tree node")
        children = node.get("children") or []
        require(isinstance(children, list), "Malformed test tree children")
        require(node.get("result") in (None, "Passed"), "Failed or skipped test tree container")
        if node.get("nodeType") == "Test Case":
            require(node.get("result") == "Passed", "Failed or skipped test case")
            for child in children:
                # xcresult attaches diagnostic annotations to an executed case.
                # Only the observed leaf shape is metadata; execution identities,
                # results or descendants must never hide another execution here.
                require(isinstance(child, dict) and set(child) == {"nodeType", "name"}
                        and child.get("nodeType") == "Runtime Warning"
                        and isinstance(child.get("name"), str) and child["name"].strip(),
                        "Unexpected parameterized execution or malformed runtime warning")
                runtime_warnings.append(child["name"])
            found.append(node.get("nodeIdentifier"))
            return
        require(node.get("nodeType") != "Runtime Warning", "Runtime warning is not attached to a test case")
        for child in children:
            visit(child)
    require(isinstance(tests, dict) and isinstance(tests.get("testNodes"), list), "Missing actual test tree")
    for node in tests["testNodes"]:
        visit(node)
    require(found == [expected], "Actual test method differs from the fixed native selection")
    return {**counts, "passedMethod": expected, "runtimeWarnings": runtime_warnings}


def verify_test_verdict(text):
    require(re.search(r"^\*\* TEST(?: EXECUTE)? SUCCEEDED \*\*[ \t]*$", text, re.MULTILINE)
            and not re.search(r"^\*\* (?:TEST(?: EXECUTE)? FAILED|BUILD FAILED) \*\*[ \t]*$", text, re.MULTILINE),
            "Missing actual native test success verdict or an explicit failure was recorded")


def case(work, name):
    summary_path, tests_path = work / (name + "-summary.json"), work / (name + "-tests.json")
    result = verify_case(json.loads(summary_path.read_bytes()), json.loads(tests_path.read_bytes()), CASES[name])
    log_path = work / (name + ".log")
    text = log_path.read_text(encoding="utf-8", errors="replace")
    verify_test_verdict(text)
    write(work / (name + "-result.json"), {"sourceCommit": source(), **result,
          "summarySHA256": sha(summary_path), "testsSHA256": sha(tests_path), "logSHA256": sha(log_path),
          "hostSHA256": sha(work / "host.json"), "lifecycleLogSHA256": sha(work / (name + "-lifecycle.log")),
          "freshHost": "selected Simulator shutdown and boot before this method"})


def finish(work):
    results = [json.loads((work / (name + "-result.json")).read_bytes()) for name in CASES]
    revision = source()
    require(all(result["sourceCommit"] == revision for result in results), "Native results differ from source")
    require(json.loads((work / "source-restored.json").read_bytes())["trackedSourceRestored"] is True,
            "Source restoration did not pass")
    write(work / "result.json", {"schemaVersion": 1, "sourceCommit": revision, "passed": True,
          "passedMethods": [CASES[name] for name in CASES], "passedTests": 3, "failedTests": 0, "skippedTests": 0,
          "hostSHA256": sha(work / "host.json"), "cases": results,
          "scope": "Actual jimage-backed ordinary JNI product routes in three fresh Simulator hosts; no device-install acceptance."})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("prepare", "restore", "merge-settings", "host", "case", "finish", "package", "image"))
    parser.add_argument("--work", type=Path, default=REPO / ".build/jimage-native-check")
    parser.add_argument("--case", choices=CASES)
    parser.add_argument("--log", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--image", type=Path)
    args = parser.parse_args()
    if args.phase == "prepare": prepare(args.work)
    elif args.phase == "restore": restore(args.work)
    elif args.phase == "merge-settings": merge_settings(args.work)
    elif args.phase == "host": host(args.work)
    elif args.phase == "case":
        require(args.case is not None, "case requires --case")
        case(args.work, args.case)
    elif args.phase == "finish": finish(args.work)
    elif args.phase == "package":
        require(args.log is not None and args.output is not None, "package requires log/output")
        verify_package(args.log, args.output)
    else:
        require(args.image is not None and args.output is not None, "image requires image/output")
        write(args.output, image(args.image))


if __name__ == "__main__":
    main()
