#!/usr/bin/env python3
"""Audit the isolated, source-only Simulator self-renewal transport probe tests.

Passing this protocol proves the bounded diagnostic and its UI, not iPhone
service reachability, installation, signing, or unattended self-renewal.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import sys


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("renewal_probe_smoke", HERE / "smoke-tools.py")
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)
TAG_PREFIX = "reader-renewal-"
UNIT_SUITE = "SelfRenewalTransportProbeTests"
UI_SUITE = "SelfRenewalProbeUITests"
EXPECTED_CASES = {
    "unit": {UNIT_SUITE + "/" + name for name in (
        "confirmsQueryTypeWithoutExportingPrivateFields",
        "acceptsBinaryPropertyListResponse",
        "tcpConnectionAloneIsNotServiceSuccess",
        "normalizesErrorsAndRejectsWrongService",
        "rejectsInvalidFrameLengths",
        "rejectsMalformedAndTruncatedResponses",
        "cancellationAndPreCancellationFinishOnce",
        "recordsNetworkFailureWithoutCredentialClaims",
    )},
    "ui": {UI_SUITE + "/testReadOnlyConnectionProbeCanExportWithoutClaimingRenewal"},
}
SOURCE_INPUTS = (
    "Modules/Services/Diagnostics/SelfRenewalTransportProbe.swift",
    "Modules/Features/Settings/SelfRenewalProbeView.swift",
    "Modules/Features/Settings/ProfileView.swift",
    "Targets/Yuedu/SharedApp/AppDependencies.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalTransportProbeTests.swift",
    "Tests/iOS-UI/SelfRenewalProbeUITests.swift",
    "scripts/reader-experience/renewal-probe-tools.py",
    "scripts/reader-experience/renewal-probe-tests.sh",
    "scripts/reader-experience/smoke-tools.py",
    "scripts/reader-experience/stage-config.py",
    "scripts/xctest.sh",
    "scripts/sim.sh",
    ".github/workflows/reader-renewal-probe.yml",
)


def validate_tag():
    return smoke.validate_tag(TAG_PREFIX)


def require_source_only():
    if os.environ.get("LEGADO_RUNTIME_SOURCE_ONLY") != "1":
        raise ValueError("Renewal diagnostics must use LEGADO_RUNTIME_SOURCE_ONLY=1")


def source_inputs():
    records = []
    for path in SOURCE_INPUTS:
        original = smoke.git("show", "HEAD:" + path, binary=True)
        actual = (smoke.REPO / path).read_bytes()
        if actual != original:
            raise ValueError("Probe source input differs from checked-out HEAD: " + path)
        records.append({"path": path, "sha256": hashlib.sha256(actual).hexdigest(), "bytes": len(actual)})
    return records


def prepare(work):
    require_source_only()
    records = source_inputs()
    audit = smoke.prepare(work, tag_prefix=TAG_PREFIX)
    record = {"schemaVersion": 1, "sourceCommit": audit["sourceCommit"],
              "sourceTag": TAG_PREFIX + audit["sourceCommit"][:7],
              "sourceInputs": records, "runtimeSourceOnly": True,
              "intendedTests": {key: sorted(value) for key, value in EXPECTED_CASES.items()}}
    smoke.config.write_new_json(work / "source-inputs.json", record)
    return record


def verify_cases(tree, group):
    if group not in EXPECTED_CASES:
        raise ValueError("Unknown renewal test group")
    if not isinstance(tree, dict) or not isinstance(tree.get("testNodes"), list):
        raise ValueError("Expected xcresulttool test-results tests JSON with testNodes")
    cases = []

    def visit(node, suites):
        if not isinstance(node, dict):
            raise ValueError("Malformed xcresult test node")
        if node.get("nodeType") == "Test Suite":
            suites = suites + [node.get("name", "")]
        if node.get("nodeType") == "Test Case":
            identifier = node.get("nodeIdentifier")
            if not isinstance(identifier, str) or not identifier:
                raise ValueError("Every executed test case must have a nodeIdentifier")
            # Xcode may qualify an identifier with its test target. Preserve
            # exactly the final suite/method; never count only display labels.
            components = identifier.removesuffix("()").split("/")
            case = "/".join(components[-2:])
            if case not in EXPECTED_CASES[group] or node.get("result") != "Passed":
                raise ValueError("Unexpected, skipped or failed renewal test case: " + identifier)
            cases.append(case)
        children = node.get("children", [])
        if not isinstance(children, list):
            raise ValueError("Malformed xcresult child nodes")
        for child in children:
            visit(child, suites)

    for node in tree["testNodes"]:
        visit(node, [])
    if len(cases) != len(EXPECTED_CASES[group]) or set(cases) != EXPECTED_CASES[group]:
        raise ValueError("The actual xcresult test identities differ from the fixed renewal selection")
    return {"expectedTests": len(EXPECTED_CASES[group]), "passedCaseIdentifiers": sorted(cases)}


def result(work):
    require_source_only()
    source = validate_tag()
    audit = smoke.read_json(work / "overlays.json")
    smoke.review_overlays(audit)
    if audit.get("infoOverlay", {}).get("sourceCommitStamped") != source:
        raise ValueError("Renewal preparation must stamp its exact source in Info.plist")
    inputs = smoke.read_json(work / "source-inputs.json")
    if (inputs.get("sourceCommit") != source or inputs.get("runtimeSourceOnly") is not True
            or inputs.get("sourceTag") != TAG_PREFIX + source[:7]
            or inputs.get("sourceInputs") != source_inputs()
            or inputs.get("intendedTests") != {key: sorted(value) for key, value in EXPECTED_CASES.items()}):
        raise ValueError("Renewal source-input audit changed or differs from this source")
    settings = smoke.read_json(work / "build-settings.json")
    matches = [entry["buildSettings"] for entry in settings if entry.get("target") == smoke.config.MAIN_TARGET]
    if len(matches) != 1:
        raise ValueError("Expected exactly one main reader diagnostic test host")
    actual = matches[0]
    for name, expected in {"CONFIGURATION": "Debug", "SWIFT_VERSION": "5.0",
                           "PLATFORM_NAME": "iphonesimulator",
                           "PRODUCT_BUNDLE_IDENTIFIER": smoke.config.MAIN_BUNDLE}.items():
        if actual.get(name) != expected:
            raise ValueError("Unexpected renewal test-host build setting: " + name)
    app = smoke.config.checked_path(Path(actual["TARGET_BUILD_DIR"]) / actual["FULL_PRODUCT_NAME"])
    info = smoke.config.read_info(app)
    smoke.require_local_info(info)
    smoke.require_source_stamp(info, source)
    if (info.get("CFBundleSupportedPlatforms") != ["iPhoneSimulator"]
            or info.get("CFBundleIdentifier") != smoke.config.MAIN_BUNDLE):
        raise ValueError("Renewal test host must be the isolated Simulator reader")
    if plistlib.loads((app / "GoogleService-Info.plist").read_bytes()) != smoke.config.synthetic_config():
        raise ValueError("The diagnostic test host must include only synthetic Firebase configuration")
    smoke.config.no_jvm_payload(app)
    groups = {}
    for group in ("unit", "ui"):
        groups[group] = {
            **smoke.verify_summary(smoke.read_json(work / (group + "-summary.json")), len(EXPECTED_CASES[group])),
            **verify_cases(smoke.read_json(work / (group + "-tests.json")), group),
        }
    evidence = {}
    for name in ("build-settings.json", "source-inputs.json", "overlays.json", "project-overlay.json",
                 "info-overlay.json", "unit-summary.json", "unit-tests.json", "ui-summary.json", "ui-tests.json"):
        evidence[name] = smoke.config.digest(work / name)
    return {"schemaVersion": 1, "sourceCommit": source, "sourceTag": TAG_PREFIX + source[:7],
            "status": "passed", "configuration": "Debug", "executionPlatform": "ios-simulator",
            "simulatorDestination": os.environ.get("YUEDU_DEST"),
            "developerDirectory": os.environ.get("DEVELOPER_DIR"), "targetedTests": groups,
            "testedInfoSHA256": smoke.config.digest(app / "Info.plist"),
            "sourceOverlays": audit, "sourceInputs": inputs["sourceInputs"], "evidenceSHA256": evidence,
            "runtimeSourceOnly": True, "ipaGenerated": False, "ipaUploaded": False,
            "appleAccountUsed": False, "pairingRecordUsed": False,
            "iphoneTransportVerified": False, "physicalDeviceValidationPassed": False,
            "selfRenewalVerified": False, "unattendedRenewalVerified": False,
            "computerPoweredOff": "notMeasured", "companionAppsAbsent": "notMeasured",
            "limitations": ["Simulator tests of a read-only diagnostic, not a delivered IPA or iPhone test.",
                            "Unit network responses come from owned temporary loopback fixture listeners.",
                            "The UI may observe only the Simulator's own default lockdown endpoints.",
                            "No Apple login, pairing, signing, installation or renewal operation is performed.",
                            "Loopback-only endpoint results cannot exclude all direct same-device transports."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="phase", required=True)
    commands.add_parser("validate-tag")
    for phase in ("prepare", "result"):
        item = commands.add_parser(phase)
        item.add_argument("--work", type=Path, required=True)
    verify = commands.add_parser("verify-tests")
    verify.add_argument("--tests", type=Path, required=True)
    verify.add_argument("--summary", type=Path, required=True)
    verify.add_argument("--group", choices=("unit", "ui"), required=True)
    args = parser.parse_args()
    try:
        if args.phase == "validate-tag":
            record = {"sourceCommit": validate_tag()}
        elif args.phase == "prepare":
            record = prepare(smoke.config.checked_path(args.work))
        elif args.phase == "verify-tests":
            record = {**smoke.verify_summary(smoke.read_json(args.summary), len(EXPECTED_CASES[args.group])),
                      **verify_cases(smoke.read_json(args.tests), args.group)}
        else:
            work = smoke.config.checked_path(args.work)
            record = result(work)
            smoke.config.write_new_json(work / "result.json", record)
        print(json.dumps(record, indent=2))
        return 0
    except Exception as error:
        print(f"{type(error).__name__}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
