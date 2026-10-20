#!/usr/bin/env python3
"""Require source-bound, real macOS SwiftPM XCTest evidence for the ten API cases.

This is an independent package result, not an App Simulator test group or a JVM
run. The shell wrapper uses the already selected DEVELOPER_DIR and source-only
mode. XML and verbose per-case XCTest output are both required: SwiftPM's
parallel xUnit writer alone cannot reliably distinguish skipped XCTest methods.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
import xml.etree.ElementTree as ET


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
spec = importlib.util.spec_from_file_location("original_api_smoke_binding", HERE / "smoke-tools.py")
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)
PACKAGE = "Packages/LegadoRuntime"
MODE = "original-api-package"
SUITES = {
    "LegadoOriginalAPITests": (
        "testConfiguredTypedFourStageChainKeepsBusinessIdentitiesAndExplicitNoSave",
        "testTypedBusinessApiDoesNotSelectTheExistingRoute",
        "testOriginalTypedErrorsAndIncompatibleDtosStayErrors",
        "testNullPageAndUtf8RequestBudgetAreExplicit",
        "testBusinessCodingPreservesOriginalNamesWithoutEnvironmentOrAppUuid",
    ),
    "LegadoRuntimeTests": (
        "testSessionAndUnicodeRequestRoundTrip",
        "testConfiguredSessionKeepsTransportOptionsOutsideSourceData",
        "testConfiguredSessionCannotSilentlyUseLegacyTransport",
        "testRuntimeOperationsRunOnSignalableBackgroundThreads",
        "testCancelReachesRuntimeWhileExecuteWorkerIsBlocked",
    ),
}
EXPECTED = {"LegadoRuntimeTests." + suite + "/" + method for suite, methods in SUITES.items() for method in methods}
FILTER = "^(" + "|".join(re.escape(case) for case in sorted(EXPECTED)) + ")$"
CURRENTCORE_SUITES = {'LegadoCookieTextAPITests': ['testTextCookieAccessRequiresExplicitEmbeddingOptionsAndPreservesDefaultEncoding', 'testPartialSequentialEffectMetadataSurvivesPublicExecutionAndOldErrorsDecode'], 'LegadoHostEffectsTests': ['testRequestCopiesShareBoundedIssuedFactsAndHostErrorCodecKeepsThem', 'testMalformedHostResponseRetainsIssuedFactsAndEmptyEffectsPreserveOldResponses'], 'LegadoExploreAPITests': ['testExploreUsesOriginalPublicActionAndPreservesExplicitNullPage', 'testExplicitContextLifecycleUsesTypedBusinessDtoAndDoesNotExposeScopeAuthority']}
CURRENTCORE_EXPECTED = EXPECTED | {"LegadoRuntimeTests."+suite+"/"+method for suite,methods in CURRENTCORE_SUITES.items() for method in methods}
assert len(EXPECTED) == 10 and len(CURRENTCORE_EXPECTED) == 16
PUBLICBATCH_EXTRA = {"LegadoRuntimeTests.LegadoOriginalAPITests/testTypedBatchReturnsMissingChapterIdentitiesAndDoesNotGrantSaves"}
PUBLICBATCH_EXPECTED = CURRENTCORE_EXPECTED | PUBLICBATCH_EXTRA
assert len(PUBLICBATCH_EXPECTED) == 17 and not (PUBLICBATCH_EXTRA & CURRENTCORE_EXPECTED)

def publicbatch_selected():
    value = os.environ.get("YUEDU_RENEWAL_PACKAGE_SELECTION", "")
    if value not in ("", "publicbatch"):
        raise ValueError("Unknown independent Package selection")
    if value == "publicbatch" and os.environ.get("YUEDU_RENEWAL_SELECTION") != "currentcore":
        raise ValueError("Package publicbatch requires the currentcore native boundary")
    return value == "publicbatch"

def expected_cases():
    if publicbatch_selected(): return PUBLICBATCH_EXPECTED
    return CURRENTCORE_EXPECTED if os.environ.get("YUEDU_RENEWAL_SELECTION") == "currentcore" else EXPECTED

def selected_filter():
    return "^(" + "|".join(re.escape(case) for case in sorted(expected_cases())) + ")$"

def selected_mode():
    if publicbatch_selected(): return "original-api-package-currentcore-publicbatch"
    return "original-api-package-currentcore" if os.environ.get("YUEDU_RENEWAL_SELECTION") == "currentcore" else MODE

PACKAGE_INPUTS = (
    PACKAGE + "/Package.swift",
    PACKAGE + "/Sources/CLegadoJNI/include/LegadoJNI.h",
    PACKAGE + "/Sources/CLegadoJNI/LegadoJNI.m",
    PACKAGE + "/Sources/LegadoRuntime/LegadoHTTPHeaders.swift",
    PACKAGE + "/Sources/LegadoRuntime/LegadoOriginalModels.swift",
    PACKAGE + "/Sources/LegadoRuntime/LegadoPlatformHost.swift",
    PACKAGE + "/Sources/LegadoRuntime/LegadoRuntime.swift",
    PACKAGE + "/Sources/LegadoRuntime/LegadoSavedDiagnostics.swift",
    PACKAGE + "/Sources/LegadoRuntime/NativeLegadoTransport.swift",
    PACKAGE + "/Tests/LegadoRuntimeTests/LegadoHTTPHeadersTests.swift",
    PACKAGE + "/Tests/LegadoRuntimeTests/LegadoOriginalAPITests.swift",
    PACKAGE + "/Tests/LegadoRuntimeTests/LegadoRuntimeTests.swift",
)
PACKAGE_INPUTS += ('Packages/LegadoRuntime/Tests/LegadoRuntimeTests/LegadoCookieTextAPITests.swift', 'Packages/LegadoRuntime/Tests/LegadoRuntimeTests/LegadoHostEffectsTests.swift', 'Packages/LegadoRuntime/Tests/LegadoRuntimeTests/LegadoExploreAPITests.swift')
CONTROL_INPUTS = (
    "scripts/reader-experience/original-api-package-tools.py",
    "scripts/reader-experience/original-api-package-tests.sh",
    "scripts/reader-experience/test-original-api-package-tools.py",
    "scripts/reader-experience/smoke-tools.py",
    "scripts/reader-experience/stage-config.py",
    "scripts/sim.sh",
    ".github/workflows/reader-renewal-probe.yml",
)
SOURCE_INPUTS = PACKAGE_INPUTS + CONTROL_INPUTS
EVIDENCE = ("swift-executable.log", "swift-version.log", "swift-test-help.log", "tests.log", "xunit.xml", "execution.json")
REQUIRED_FLAGS = ("--parallel", "--num-workers", "--xunit-output", "--filter", "--verbose", "--disable-swift-testing")
TEST_TIMEOUT = 1200


def require_environment():
    if os.environ.get("LEGADO_RUNTIME_SOURCE_ONLY") != "1":
        raise ValueError("SwiftPM evidence requires LEGADO_RUNTIME_SOURCE_ONLY=1")
    developer = os.environ.get("DEVELOPER_DIR", "")
    if not developer or not Path(developer).is_absolute() or not Path(developer).is_dir():
        raise ValueError("Use the workflow's existing installed DEVELOPER_DIR")
    if os.environ.get("_SWIFTPM_SKIP_TESTS_LIST"):
        raise ValueError("SwiftPM skip overrides are not permitted")
    return str(Path(developer).resolve())


def source_inputs():
    # Bind every compiled non-SDK source, including unselected tests that still
    # compile. New files require a reviewed closure update instead of silently
    # entering this test executable outside its fingerprint.
    actual = {PACKAGE + "/Package.swift"}
    for directory in ("Sources", "Tests"):
        parent = REPO / PACKAGE / directory
        if parent.is_symlink():
            raise ValueError("Package source directories cannot be links")
        for path in parent.rglob("*"):
            if path.is_symlink():
                raise ValueError("Package source inputs cannot be links")
            if path.is_file():
                actual.add(path.relative_to(REPO).as_posix())
    if actual != set(PACKAGE_INPUTS):
        raise ValueError("Package source closure differs from the reviewed fifteen inputs")
    records = []
    for path in SOURCE_INPUTS:
        target = REPO / path
        if target.is_symlink():
            raise ValueError("Source-bound inputs cannot be links")
        expected = smoke.git("show", "HEAD:" + path, binary=True)
        raw = target.read_bytes()
        if raw != expected:
            raise ValueError("Package source input differs from checked-out HEAD: " + path)
        records.append({"path": path, "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()})
    return records


def snapshot():
    developer = require_environment()
    source = smoke.validate_tag("reader-renewal-")
    return {"schemaVersion": 1, "selectionMode": selected_mode(), "sourceCommit": source,
            "sourceTag": "reader-renewal-" + source[:7], "runtimeSourceOnly": True,
            "packagePath": PACKAGE, "developerDirectory": developer,
            "qualifiedXCTestMethods": sorted(expected_cases()), "filter": selected_filter(),
            "parallelWorkers": 1, "testTimeoutSeconds": TEST_TIMEOUT,
            "packageSourceInputCount": len(PACKAGE_INPUTS), "sourceInputs": source_inputs()}


def write_new_json(path, value):
    with path.open("x", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2)
        handle.write("\n")


def read_json(raw):
    def unique_keys(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("Duplicate JSON evidence key: " + key)
            result[key] = value
        return result
    return json.loads(raw, object_pairs_hook=unique_keys)


def prepare(work):
    value = snapshot()
    work = Path(work).resolve()
    build = (REPO / ".build").resolve()
    if not work.is_relative_to(build) or work == build:
        raise ValueError("Package evidence must use its own directory below .build")
    if work.exists() and any(work.iterdir()):
        raise ValueError("Refusing to replace prior package execution evidence")
    work.mkdir(parents=True, exist_ok=True)
    write_new_json(work / "source-inputs.json", value)
    return value


def checked_bytes(path, maximum):
    if path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= maximum:
        raise ValueError("Missing or invalid bounded evidence: " + path.name)
    raw = path.read_bytes()
    if len(raw) > maximum:
        raise ValueError("Evidence grew beyond its byte limit")
    return raw


def qualified(classname, method):
    if method.endswith("()"):
        method = method[:-2]
    value = classname + "/" + method
    if value not in expected_cases():
        raise ValueError("Unexpected qualified XCTest method: " + value)
    return value


def verify_xml(raw):
    raw.decode("utf-8")
    if b"<!DOCTYPE" in raw.upper() or b"<!ENTITY" in raw.upper():
        raise ValueError("Unsupported XML declarations")
    try:
        root = ET.fromstring(raw)
    except ET.ParseError as error:
        raise ValueError("Malformed XCTest XML") from error
    if root.tag != "testsuites":
        raise ValueError("Expected SwiftPM XCTest testsuites XML")
    suites = list(root.iter("testsuite"))
    if not suites or len(suites) > 16:
        raise ValueError("Missing or excessive XCTest suites")
    if any(node.tag in ("failure", "error", "skipped", "disabled") for node in root.iter()):
        raise ValueError("XCTest XML contains a failure, error or skip")
    for suite in suites:
        for key in ("errors", "failures"):
            if suite.get(key) != "0":
                raise ValueError("XCTest XML must declare zero " + key)
        if suite.get("skipped", "0") != "0" or suite.get("disabled", "0") != "0":
            raise ValueError("Skipped/disabled XCTest XML is not accepted")
        if suite.get("tests") != str(len(list(suite.iter("testcase")))):
            raise ValueError("XCTest XML summary disagrees with its leaves")
    cases = []
    for case in root.iter("testcase"):
        if case.get("status", "run") not in ("run", "passed"):
            raise ValueError("XCTest XML case was not executed")
        cases.append(qualified(case.get("classname", ""), case.get("name", "")))
    if len(cases) != len(expected_cases()) or len(set(cases)) != len(expected_cases()) or set(cases) != expected_cases():
        raise ValueError("Expected the exact selected qualified XCTest XML leaves")
    return sorted(cases)


def verify_verbose_log(text):
    # --verbose makes SwiftPM print every successful child process's actual
    # XCTest output. This complements, and never replaces, the XML requirement.
    patterns = (
        re.compile(r"^Test Case '-\[([A-Za-z0-9_.]+) (test\w+)\]' (passed|failed|skipped)\b", re.M),
        re.compile(r"^Test Case '([A-Za-z0-9_.]+)\.(test\w+)' (passed|failed|skipped)\b", re.M),
    )
    outcomes = [match.groups() for pattern in patterns for match in pattern.finditer(text)]
    cases = []
    for classname, method, outcome in outcomes:
        value = qualified(classname, method)
        if outcome != "passed":
            raise ValueError("XCTest verbose output contains " + outcome)
        cases.append(value)
    if len(cases) != len(expected_cases()) or len(set(cases)) != len(expected_cases()) or set(cases) != expected_cases():
        raise ValueError("Expected the exact selected actual qualified XCTest passed leaves in verbose output")
    return sorted(cases)


def test_command(swift, work):
    return [swift, "test", "--package-path", str((REPO / PACKAGE).resolve()),
            "--parallel", "--num-workers", "1", "--xunit-output", str((work / "xunit.xml").resolve()),
            "--filter", selected_filter(), "--verbose", "--disable-swift-testing"]


def result(work):
    work = Path(work).resolve()
    inputs = read_json(checked_bytes(work / "source-inputs.json", 1_048_576))
    if json.dumps(inputs, sort_keys=True) != json.dumps(snapshot(), sort_keys=True):
        raise ValueError("Package prepare/result source-input audit differs")
    raw = {name: checked_bytes(work / name, 16_777_216 if name == "tests.log" else 1_048_576) for name in EVIDENCE}
    executable = raw["swift-executable.log"].decode("utf-8").strip()
    path = Path(executable)
    developer = Path(inputs["developerDirectory"])
    if not path.is_absolute() or not path.is_file() or not path.resolve().is_relative_to(developer):
        raise ValueError("Swift executable does not belong to the selected installed toolchain")
    version = raw["swift-version.log"].decode("utf-8")
    match = re.search(r"\bSwift version (\d+)\.", version)
    if not match or int(match.group(1)) < 6 or "apple-macos" not in version.lower():
        raise ValueError("Expected an actual Swift 6+ macOS toolchain version")
    help_text = raw["swift-test-help.log"].decode("utf-8")
    if not all(flag in help_text for flag in REQUIRED_FLAGS):
        raise ValueError("Selected SwiftPM does not advertise the required XCTest flags")
    execution = read_json(raw["execution.json"])
    expected_execution = {"arguments": test_command(executable, work), "developerDirectory": inputs["developerDirectory"],
                          "runtimeSourceOnly": True, "exitCode": 0, "timedOut": False, "completed": True}
    if json.dumps(execution, sort_keys=True) != json.dumps(expected_execution, sort_keys=True):
        raise ValueError("SwiftPM execution command, completion or status was not the prepared selection")
    xml_cases = verify_xml(raw["xunit.xml"])
    log_cases = verify_verbose_log(raw["tests.log"].decode("utf-8"))
    return {"schemaVersion": 1, "recordedAtUTC": datetime.now(timezone.utc).isoformat(),
            **inputs, "status": "passed", "totalTestCount": len(expected_cases()), "failedTests": 0, "skippedTests": 0,
            "passedCaseIdentifiers": xml_cases, "verbosePassedCaseIdentifiers": log_cases,
            "swiftVersion": version.strip(), "swiftExecutable": executable,
            "evidenceSHA256": {name: hashlib.sha256(value).hexdigest() for name, value in raw.items()},
            "appSimulatorCaseCount": 0, "jvmExecuted": False, "physicalDeviceValidationPassed": False,
            "selfRenewalVerified": False, "unattendedRenewalVerified": False,
            "limitations": ["Exactly the selected10 historical-mode,16 unflagged currentcore or17 explicit publicbatch macOS package XCTest cases; current source closure15+7 is independently bound and App Simulator results remain independent.",
                            "Injected transport and owned DTO cases do not execute the original Kotlin WebBook or JVM/JNI runtime.",
                            "No Apple account, private pairing material, device, App install, package signing or renewal is used.",
                            "XML and actual verbose XCTest case outcomes are required together; process/log summaries alone never establish passing tests."]}


def run_tool(command, path, timeout):
    completed = subprocess.run(command, cwd=REPO, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    path.write_bytes(completed.stdout)
    if completed.returncode:
        raise ValueError("Tool failed: " + command[0])
    return completed.stdout


def run(work):
    if sys.platform != "darwin":
        raise ValueError("Actual package SDK execution requires macOS; portable guards do not execute Swift")
    inputs = prepare(work)
    work = Path(work).resolve()
    executable = run_tool(["xcrun", "--find", "swift"], work / "swift-executable.log", 60).decode("utf-8").strip()
    if not Path(executable).resolve().is_relative_to(Path(inputs["developerDirectory"])):
        raise ValueError("xcrun selected a different toolchain")
    run_tool([executable, "--version"], work / "swift-version.log", 60)
    help_text = run_tool([executable, "test", "--help"], work / "swift-test-help.log", 60).decode("utf-8")
    if not all(flag in help_text for flag in REQUIRED_FLAGS):
        raise ValueError("Installed SwiftPM cannot provide the required package test evidence")
    command = test_command(executable, work)
    print("Executing ten fixed source-only XCTest methods with one SwiftPM worker", flush=True)
    timed_out = False
    log_errors = []
    with (work / "tests.log").open("wb") as log:
        process = subprocess.Popen(command, cwd=REPO, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        def copy_output():
            copied = 0
            try:
                for line in iter(process.stdout.readline, b""):
                    if len(line) > 16_777_216 - copied:
                        raise ValueError("SwiftPM output exceeds the 16 MiB evidence limit")
                    log.write(line)
                    log.flush()
                    sys.stdout.buffer.write(line)
                    sys.stdout.buffer.flush()
                    copied += len(line)
            except Exception as error:
                log_errors.append(str(error))
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        reader = threading.Thread(target=copy_output, name="original-api-swiftpm-log", daemon=True)
        reader.start()
        try:
            exit_code = process.wait(timeout=TEST_TIMEOUT)
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                exit_code = process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                exit_code = process.wait(timeout=10)
        reader.join(timeout=10)
        if reader.is_alive():
            raise ValueError("SwiftPM child output did not close after execution")
    write_new_json(work / "execution.json", {"arguments": command,
        "developerDirectory": inputs["developerDirectory"], "runtimeSourceOnly": True,
        "exitCode": exit_code, "timedOut": timed_out, "completed": not timed_out})
    if log_errors:
        raise ValueError("SwiftPM evidence output could not be preserved: " + log_errors[0])
    if timed_out or exit_code != 0:
        raise ValueError("SwiftPM timed out or returned a failing status")
    value = result(work)
    write_new_json(work / "result.json", value)
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("prepare", "result", "run", "filter"))
    parser.add_argument("--work", type=Path, default=REPO / ".build/reader-renewal-original-api")
    args = parser.parse_args()
    try:
        if args.phase == "filter":
            print(selected_filter())
            return 0
        value = {"prepare": prepare, "result": result, "run": run}[args.phase](args.work)
        print(json.dumps(value, indent=2, ensure_ascii=False))
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
