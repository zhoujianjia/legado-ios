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
import re
import sys


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("renewal_probe_smoke", HERE / "smoke-tools.py")
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)
TAG_PREFIX = "reader-renewal-"
UNIT_SUITE = "SelfRenewalTransportProbeTests"
DISCOVERY_SUITE = "SelfRenewalDiscoveryProbeTests"
UI_SUITE = "SelfRenewalProbeUITests"
REPLACEMENT_SUITE = "SelfRenewalReplacementPolicyTests"
MATERIALS_SUITE = "SelfRenewalMaterialInventoryTests"
SIGNATURE_SUITE = "SelfRenewalMachOSignatureReaderTests"
LANGUAGES = ("zh-Hant", "zh-Hans", "en", "ja", "ko")
BONJOUR_SERVICES = ("_calibresmartdeviceapp._tcp", "_remotepairing._tcp")
USAGE_KEY = "NSLocalNetworkUsageDescription"
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
    "discovery": {DISCOVERY_SUITE + "/" + name for name in (
        "acceptsOnlyOwnedAddresses",
        "rejectsNonUnicastAndMalformedAddresses",
        "scopedIPv6NeedsExactInterface",
        "rejectsBroadcastAndExcludedInterfaces",
        "snapshotsDetectRelevantTopologyChanges",
        "connectsOnlyAfterClosedWindowAndKeepsReportRedacted",
        "removalsAndExpiredRecordsCannotConnect",
        "incompleteOrOverflowedDiscoveryNeverConnects",
        "revalidatesOwnershipAndTTLBeforeEachConnection",
        "cancellationAndGlobalDeadlineCloseAllWork",
        "enforcesBudgetsAndPreservesDistinctFailures",
        "retainsSchemaOneReportCompatibility",
        "tcpAdapterConnectsAndClosesWithoutSendingPayload",
        "selectsFourOwnedEndpointsFromReportedAddressShape",
        "selectionIsStableAcrossOrderAndUsesShorterDuplicateTTL",
        "selectionPreservesHardLimitsCancellationAndSnapshotChecks",
    )},
    "replacement": {REPLACEMENT_SUITE + "/" + name for name in (
        "rejectsAccountTeamAndBundleMappingChanges",
        "rejectsMissingDuplicateOrIncompleteBundleInventory",
        "rejectsChangedOrUnknownEntitlementGroups",
        "rejectsUnverifiedExpiredOrInvalidCandidateMaterial",
        "sameVersionAndBuildYieldOnlyMetadataPreflight",
    )},
    "materials": {MATERIALS_SUITE + "/" + name for name in (
        "parsesBoundedMetadataAndRejectsDamagedOrUnsafeValues",
        "readsThreeBundleFactsWithoutTrustAssertion",
        "retainsAdditionalPotentialSignedComponents",
        "reportsIncompleteAndConflictingRoleStructure",
        "rejectsLinkedMaterials",
        "enforcesDirectoryAndByteLimits",
    )},
    "signature": {SIGNATURE_SUITE + "/" + name for name in (
        "readsThinSignaturesWithoutReadingExecutableBodiesOrClaimingTrust",
        "readsFat32And64InBothByteOrders",
        "rejectsMalformedFatTablesAndOverlappingSlices",
        "rejectsMalformedAndUnknownRequiredLoadCommands",
        "rejectsDamagedEmbeddedSignatureStructures",
        "rejectsInvalidCodeDirectoryOffsetsAndUnsupportedLayouts",
        "readsKnownDirectoryVersionsAndEmptyCMSWithoutAssumingTrust",
        "handlesUnsignedTruncatedAndCancelledInputs",
        "readsOwnedUnpackedAppThroughInventoryAndRejectsLinkedCode",
    )},
    "ui": {UI_SUITE + "/testReadOnlyConnectionProbeCanExportWithoutClaimingRenewal"},
}
SELECTION_GROUPS = {
    # Preserve the historical all-mode contract; new implementation tests have
    # an explicit independent selection rather than silently widening it.
    "all": ("unit", "discovery", "replacement", "ui"),
    "replacement": ("replacement",),
    "implementation": ("replacement", "materials"),
    "signature": ("signature",),
}
SOURCE_INPUTS = (
    "Modules/Services/Diagnostics/SelfRenewalTransportProbe.swift",
    "Modules/Services/Diagnostics/SelfRenewalDiscoveryPolicy.swift",
    "Modules/Services/Diagnostics/SelfRenewalDiscoveryProbe.swift",
    "Modules/Services/Diagnostics/SelfRenewalDiscoveryNativeDriver.swift",
    "Modules/Features/Settings/SelfRenewalProbeView.swift",
    "Modules/Features/Settings/ProfileView.swift",
    "Targets/Yuedu/SharedApp/AppDependencies.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalTransportProbeTests.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalDiscoveryProbeTests.swift",
    "Modules/Services/SelfRenewal/SelfRenewalReplacementPolicy.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalReplacementPolicyTests.swift",
    "Modules/Services/SelfRenewal/SelfRenewalMaterialInventory.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalMaterialInventoryTests.swift",
    "Modules/Services/SelfRenewal/SelfRenewalMachOSignatureReader.swift",
    "Tests/iOS/yuedu appTests/SelfRenewalMachOSignatureReaderTests.swift",
    "Tests/iOS-UI/SelfRenewalProbeUITests.swift",
    "Info.plist",
    "Yuedu-Reader.xcodeproj/project.pbxproj",
    "scripts/reader-experience/renewal-probe-tools.py",
    "scripts/reader-experience/inspect-renewal-report.py",
    "scripts/reader-experience/renewal-report-schema1.py",
    "scripts/reader-experience/test-inspect-renewal-report.py",
    "scripts/reader-experience/renewal-probe-tests.sh",
    "scripts/reader-experience/smoke-tools.py",
    "scripts/reader-experience/stage-config.py",
    "scripts/xctest.sh",
    "scripts/sim.sh",
    ".github/workflows/reader-renewal-probe.yml",
) + tuple("Resources/" + language + ".lproj/" + table
          for language in LANGUAGES for table in ("Localizable.strings", "InfoPlist.strings"))


def validate_tag():
    selection_mode()
    return smoke.validate_tag(TAG_PREFIX)


def selection_mode():
    mode = os.environ.get("YUEDU_RENEWAL_SELECTION", "all")
    if mode not in SELECTION_GROUPS:
        raise ValueError("YUEDU_RENEWAL_SELECTION must be all, replacement, implementation or signature")
    return mode


def selected_cases():
    mode = selection_mode()
    return {group: EXPECTED_CASES[group] for group in SELECTION_GROUPS[mode]}


def require_source_only():
    if os.environ.get("LEGADO_RUNTIME_SOURCE_ONLY") != "1":
        raise ValueError("Renewal diagnostics must use LEGADO_RUNTIME_SOURCE_ONLY=1")


def source_inputs(overlays=None):
    records = []
    for path in SOURCE_INPUTS:
        original = smoke.git("show", "HEAD:" + path, binary=True)
        actual = (smoke.REPO / path).read_bytes()
        if actual != original:
            # These two inputs alone have an independently reviewed local-mode overlay.
            # Their source fingerprint must remain the original checked-out Git bytes.
            overlay = next((overlays.get(key, {}) for key in ("infoOverlay", "projectOverlay")
                            if overlays.get(key, {}).get("path") == path), None) if overlays else None
            if (path not in smoke.OVERLAYS or overlay is None
                    or overlay.get("originalSHA256") != hashlib.sha256(original).hexdigest()
                    or overlay.get("overlaySHA256") != hashlib.sha256(actual).hexdigest()):
                raise ValueError("Probe source input differs from checked-out HEAD: " + path)
        records.append({"path": path, "sha256": hashlib.sha256(original).hexdigest(), "bytes": len(original)})
    return records


def decoded_strings_value(path, key):
    """Read source OpenStep strings and Xcode's binary/XML compiled strings."""
    raw = path.read_bytes()
    if len(raw) > 64 * 1024:
        raise ValueError("Oversized privacy localization table")
    if raw.startswith(b"bplist") or raw.lstrip().startswith((b"<?xml", b"<plist")):
        table = plistlib.loads(raw)
        value = table.get(key) if isinstance(table, dict) else None
    else:
        text = raw.decode("utf-16" if raw.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig")
        matches = re.findall(r'^\s*"' + re.escape(key) + r'"\s*=\s*("(?:[^"\\\r\n]|\\.)*")\s*;\s*$',
                             text, flags=re.MULTILINE)
        if len(matches) != 1:
            raise ValueError("Privacy localization must contain exactly one usage description")
        # OpenStep supports uppercase four-digit Unicode escapes as well as JSON's escapes.
        value = json.loads(re.sub(r"(?<!\\)((?:\\\\)*)\\U([0-9a-fA-F]{4})", r"\1\\u\2", matches[0]))
    if not isinstance(value, str) or not value.strip() or len(value) > 1024:
        raise ValueError("Missing or invalid local-network usage description")
    return value


def verify_built_discovery_metadata(app, info):
    services = info.get("NSBonjourServices")
    if (not isinstance(services, list) or len(services) != len(BONJOUR_SERVICES)
            or any(not isinstance(value, str) for value in services)
            or set(services) != set(BONJOUR_SERVICES)):
        raise ValueError("Built Bonjour services must preserve Calibre and declare exactly one RemotePairing type")
    project = (smoke.REPO / smoke.config.PROJECT).read_text(encoding="utf-8")
    fallbacks = re.findall(r'^\s*INFOPLIST_KEY_NSLocalNetworkUsageDescription\s*=\s*("(?:[^"\\\r\n]|\\.)*")\s*;\s*$',
                           project, flags=re.MULTILINE)
    if len(fallbacks) != 2:
        raise ValueError("Both project configurations must declare the local-network privacy fallback")
    values = [json.loads(value) for value in fallbacks]
    if not values[0].strip() or values[0] != values[1] or info.get(USAGE_KEY) != values[0]:
        raise ValueError("Built local-network privacy fallback differs from both source project configurations")
    localized = []
    for language in LANGUAGES:
        relative = language + ".lproj/InfoPlist.strings"
        source = smoke.REPO / "Resources" / relative
        built = app / relative
        if decoded_strings_value(built, USAGE_KEY) != decoded_strings_value(source, USAGE_KEY):
            raise ValueError("Built local-network privacy localization differs from source: " + language)
        localized.append({"language": language, "sourceSHA256": smoke.config.digest(source),
                          "builtSHA256": smoke.config.digest(built), "usageDescriptionMatchesSource": True})
    return {"bonjourServices": list(BONJOUR_SERVICES), "fallbackMatchesBothSourceConfigurations": True,
            "localizedUsageDescriptions": localized}


def prepare(work):
    mode = selection_mode()
    cases = selected_cases()
    require_source_only()
    if (work / "overlays.json").exists() or (work / "source-inputs.json").exists():
        raise ValueError("Refusing to overwrite prior renewal preparation evidence")
    records = source_inputs()
    audit = smoke.prepare(work, tag_prefix=TAG_PREFIX)
    record = {"schemaVersion": 1, "sourceCommit": audit["sourceCommit"],
              "sourceTag": TAG_PREFIX + audit["sourceCommit"][:7],
              "sourceInputs": records, "runtimeSourceOnly": True,
              "selectionMode": mode,
              "intendedTests": {key: sorted(value) for key, value in cases.items()}}
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
    mode = selection_mode()
    cases = selected_cases()
    require_source_only()
    source = validate_tag()
    audit = smoke.read_json(work / "overlays.json")
    smoke.review_overlays(audit)
    if audit.get("infoOverlay", {}).get("sourceCommitStamped") != source:
        raise ValueError("Renewal preparation must stamp its exact source in Info.plist")
    inputs = smoke.read_json(work / "source-inputs.json")
    if (inputs.get("sourceCommit") != source or inputs.get("runtimeSourceOnly") is not True
            or inputs.get("sourceTag") != TAG_PREFIX + source[:7]
            or inputs.get("sourceInputs") != source_inputs(audit)
            or inputs.get("selectionMode") != mode
            or inputs.get("intendedTests") != {key: sorted(value) for key, value in cases.items()}):
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
    metadata = verify_built_discovery_metadata(app, info)
    if plistlib.loads((app / "GoogleService-Info.plist").read_bytes()) != smoke.config.synthetic_config():
        raise ValueError("The diagnostic test host must include only synthetic Firebase configuration")
    smoke.config.no_jvm_payload(app)
    groups = {}
    for group in cases:
        groups[group] = {
            **smoke.verify_summary(smoke.read_json(work / (group + "-summary.json")), len(EXPECTED_CASES[group])),
            **verify_cases(smoke.read_json(work / (group + "-tests.json")), group),
        }
    evidence = {}
    evidence_names = ["build-settings.json", "source-inputs.json", "overlays.json", "project-overlay.json", "info-overlay.json"]
    evidence_names += [group + suffix for group in cases for suffix in ("-summary.json", "-tests.json")]
    for name in evidence_names:
        evidence[name] = smoke.config.digest(work / name)
    return {"schemaVersion": 2, "sourceCommit": source, "sourceTag": TAG_PREFIX + source[:7],
            "status": "passed", "configuration": "Debug", "executionPlatform": "ios-simulator",
            "simulatorDestination": os.environ.get("YUEDU_DEST"),
            "developerDirectory": os.environ.get("DEVELOPER_DIR"), "selectionMode": mode,
            "targetedTests": groups, "unselectedTestGroups": [group for group in EXPECTED_CASES if group not in cases],
            "testedInfoSHA256": smoke.config.digest(app / "Info.plist"),
            "sourceOverlays": audit, "sourceInputs": inputs["sourceInputs"], "evidenceSHA256": evidence,
            "builtDiscoveryMetadata": metadata,
            "runtimeSourceOnly": True, "ipaGenerated": False, "ipaUploaded": False,
            "appleAccountUsed": False, "pairingRecordUsed": False,
            "iphoneTransportVerified": False, "physicalDeviceValidationPassed": False,
            "serviceIdentityVerified": False,
            "selfRenewalVerified": False, "unattendedRenewalVerified": False,
            "computerPoweredOff": "notMeasured", "companionAppsAbsent": "notMeasured",
            "limitations": ["Only the selected Simulator groups are accepted; not a delivered IPA or iPhone test.",
                            "No Apple login, pairing, signing, installation or renewal operation is performed."] + (
                           ["This selection executes exactly nine owned-fixture Mach-O signature-structure cases; unit, discovery, replacement, materials and UI groups are not executed or accepted.",
                            "Thin/fat Mach-O, load commands, SuperBlob, CodeDirectory and CMS slot observations remain untrusted; no CMS ASN.1, certificate-chain, page-hash, resource-seal or profile authenticity is established.",
                            "No QueryType fixture listener, RemotePairing browsing or diagnostic TCP probe is invoked."]
                           if mode == "signature" else [
                            "Five replacement-policy cases check caller-supplied metadata only; no real platform adapter, signature or profile authenticity is established.",
                            "This selection executes only replacement metadata cases; unit, discovery, materials, signature and UI groups are not executed or accepted."]
                           if mode == "replacement" else [
                            "Five replacement-policy cases check caller-supplied metadata only; no real platform adapter, signature or profile authenticity is established.",
                            "This selection executes exactly five replacement-policy and six owned-file material-inventory cases; unit, discovery, signature and UI groups are not executed or accepted.",
                            "Material inventory reads bounded owned directory fixtures and untrusted metadata; it does not verify Mach-O signatures, resource seals, CMS profiles or certificate authority."]
                           if mode == "implementation" else [
                            "Five replacement-policy cases check caller-supplied metadata only; no real platform adapter, signature or profile authenticity is established.",
                            "Historical all mode retains only unit, discovery, replacement and UI groups; material-inventory and signature-structure cases are not executed or accepted.",
                            "Unit network responses come from owned temporary loopback fixture listeners.",
                            "The explicit UI operation browses only RemotePairing, filters numeric local ownership, opens TCP and closes without an application payload.",
                            "The existing eight QueryType fixture cases remain separate from sixteen discovery cases and one UI case.",
                            "A bare TCP connection does not establish service identity or an authenticated usable transport.",
                            "The previous fixed-loopback experiment does not exclude alternate transports; discovery fixtures and Simulator UI do not establish iPhone reachability."])}


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
    verify.add_argument("--group", choices=tuple(EXPECTED_CASES), required=True)
    args = parser.parse_args()
    try:
        if args.phase == "validate-tag":
            record = {"sourceCommit": validate_tag()}
        elif args.phase == "prepare":
            record = prepare(smoke.config.checked_path(args.work))
        elif args.phase == "verify-tests":
            if args.group not in selected_cases():
                raise ValueError("Test group is not part of YUEDU_RENEWAL_SELECTION")
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
