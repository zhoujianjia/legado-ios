#!/usr/bin/env python3
"""Audit temporary local-mode overlays and require real, non-skipped smoke tests.

Requires separate configuration (7), source-pagination (12) and TXT UI (1)
summaries. The loopback-source UI verdict is verified by its independent runner.
This Simulator-only Debug protocol never modifies a delivered IPA and does not
establish Release or physical-device functional acceptance.
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
import subprocess
import sys


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
spec = importlib.util.spec_from_file_location("reader_smoke_config", HERE / "stage-config.py")
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)
INFO = "Info.plist"
OVERLAYS = {INFO, config.PROJECT}

# This selection is intentionally fixed. Counts alone cannot distinguish the
# intended font transaction cases from an unrelated all-green invocation.
LOCAL_PRODUCT_CASES = {
    "ReaderLocalProductTests": ("localChineseUsesActualSimplifiedTranslations()",
        "disabledBuiltInsStayHiddenAcrossStorefrontChanges()", "disabledRemoteCatalogKeepsCacheWithoutFetchingOrStamping()"),
    "ReaderFontCatalogTests": ("bundledFontsAreRegisteredWithLicensedResources()",
        "bundledSelectionsReachGlobalAndReaderFontResolvers()"),
    "CachedBookTXTExportTests": ("partialExportUsesValidatedCacheInTOCOrder()", "completeExportPreservesChinese()",
        "plainTextExportsWithoutHTMLInterpretation()", "emptyExportDoesNotCreateEmptyBook()"),
    "UserFontSettingsTests": ("fontImportReadsRealTrueTypeMetadata()", "reimportingFontReplacesItsFile()",
        "launchCleanupRemovesSupersededCopies()", "txtBuilderUsesSelectedReaderFont()",
        "epubPipelineExposesUserSelectedFont()", "onlineBooksAndEPUBExposeUserSelectedFont()",
        "epubFontOverrideAndRestoration()", "onlineHTMLChaptersUseSelectedReaderFontAsDefault()",
        "onlineTXTFallbackUsesSelectedReaderFont()", "regularOnlyCustomFontGainsSyntheticBoldInTXT()",
        "regularOnlyCustomFontGainsSyntheticBoldForOnlineHTML()", "nativeBoldFaceDoesNotReceiveSyntheticStroke()",
        "globalFontImportDoesNotChangeReaderSelection()", "readerFontImportDoesNotChangeGlobalSelection()",
        "deletingSharedFontClearsGlobalAndReaderSelections()", "failedImportPreservesLibrary(fault:global:)",
        "failedDeletePreservesLibrary()", "successPublishesOneCommittedFont()",
        "missingOldFilesCanBeRepaired(reimport:)", "recoveryCopyMissingErrorStillAborts()",
        "defaultRegistryCanRemoveAnAlreadyMissingFont()",
        "heldImportHasOnePublicationBoundary(cancelFirst:)", "invalidNamesAreRejected(name:)",
        "rollbackFailureRetainsMaterials()"),
    "SubscriptionPublicationTests": ("repeatedFreeStatusDoesNotInvalidateSubscribers()",
        "recomputingTheSameEntitlementDoesNotRepublishIt()"),
    "PublicLibraryAvailabilityTests": ("countriesAndColdStart()", "runningUpdates()"),
    "RemoteLibraryHTTPTests": ("feedRequestCountAndErrors()", "opds2ContentTypes()", "identifyingUserAgent()",
        "authenticationScope()", "redirectScope()", "mutationRedirectScope()", "mutationDirectOrigin()",
        "rangeStreaming()", "rangeFailureClassification()", "loginPageDoesNotTriggerDownload()",
        "malformedPartialResponse()", "searchDescription()", "coverSessionCache()"),
}
LOCAL_PRODUCT_EXECUTIONS = {suite + "/" + method: 1
    for suite, methods in LOCAL_PRODUCT_CASES.items() for method in methods}
LOCAL_PRODUCT_EXECUTIONS.update({
    "UserFontSettingsTests/failedImportPreservesLibrary(fault:global:)": 12,
    "UserFontSettingsTests/heldImportHasOnePublicationBoundary(cancelFirst:)": 2,
    "UserFontSettingsTests/invalidNamesAreRejected(name:)": 6,
    "UserFontSettingsTests/missingOldFilesCanBeRepaired(reimport:)": 2,
})
LOCAL_PRODUCT_METHOD_COUNT = 50
LOCAL_PRODUCT_EXECUTION_COUNT = 68


def local_product_source_inputs(repo=None):
    """Check the selected, simple @Test declarations, not arbitrary Swift syntax.

    A declaration/argument-shape change fails closed for deliberate review. This
    is a source inventory; it is never a claim that Swift compiled or executed.
    """
    repo = REPO if repo is None else Path(repo)
    records, found = [], set()
    pattern = re.compile(r"^[ \t]*@Test(?:\(([^\r\n]*)\))?\s+(?:nonisolated\s+)?func (\w+)\(([^)]*)\)", re.MULTILINE)
    for suite, expected in LOCAL_PRODUCT_CASES.items():
        filenames = [suite + ".swift"]
        if suite == "UserFontSettingsTests":
            filenames.append("UserFontTransactionTests.swift")
        actual = set()
        for filename in filenames:
            relative = "Tests/iOS/yuedu appTests/" + filename
            path = repo / relative
            data = path.read_bytes()
            text = data.decode("utf-8-sig")
            if filename == "UserFontTransactionTests.swift":
                if "extension UserFontSettingsTests {" not in text or "@Suite(" in text:
                    raise ValueError("Font transactions must extend the same serialized UserFontSettingsTests suite")
            elif re.search(r"\b(?:struct|class)\s+" + re.escape(suite) + r"\b", text) is None:
                raise ValueError("Selected source suite declaration is missing: " + suite)
            if suite == "UserFontSettingsTests" and filename == suite + ".swift":
                if re.search(r"@Suite\([^\r\n]*\.serialized[^\r\n]*\)", text) is None:
                    raise ValueError("Font settings and transaction cases require one serialized suite")
            declarations = pattern.findall(text)
            if len(declarations) != len(re.findall(r"^[ \t]*@Test\b", text, re.MULTILINE)):
                raise ValueError("Unsupported or missing selected @Test declaration: " + relative)
            for attributes, name, parameters in declarations:
                labels = []
                for parameter in parameters.split(",") if parameters.strip() else []:
                    match = re.fullmatch(r"\s*(\w+)\s*:\s*[\w.]+\s*", parameter)
                    if match is None:
                        raise ValueError("Unsupported selected test signature: " + name)
                    labels.append(match[1] + ":")
                method = name + "(" + "".join(labels) + ")"
                identity = suite + "/" + method
                parameter_types = {"failedImportPreservesLibrary": "fault:FontFault,global:Bool",
                    "heldImportHasOnePublicationBoundary": "cancelFirst:Bool", "invalidNamesAreRejected": "name:String",
                    "missingOldFilesCanBeRepaired": "reimport:Bool"}
                if name in parameter_types and re.sub(r"\s+", "", parameters) != parameter_types[name]:
                    raise ValueError("Font transaction parameter types differ from the fixed source selection")
                if identity in found:
                    raise ValueError("Duplicate selected source method: " + identity)
                found.add(identity)
                actual.add(method)
                if "arguments:" in attributes:
                    arguments = attributes.split("arguments:", 1)[1].strip()
                    if name == "failedImportPreservesLibrary":
                        cases = re.search(r"\benum FontFault\b[^\{]*\{\s*case ([^\r\n}]+)", text)
                        faults = [] if cases is None else [part.strip() for part in cases[1].split(",")]
                        if (re.sub(r"\s+", "", arguments) != "FontFault.allCases,[false,true]"
                                or faults != ["copyCandidate", "metadata", "copyOriginal", "unregister", "register", "removeAfterMutation"]):
                            raise ValueError("Font import fault matrix differs from the fixed 6 x 2 selection")
                    elif name in ("heldImportHasOnePublicationBoundary", "missingOldFilesCanBeRepaired"):
                        values = json.loads(arguments)
                        if (not isinstance(values, list) or any(type(value) is not bool for value in values)
                                or values != [False, True]):
                            raise ValueError("Font cancellation arguments differ from the fixed selection")
                    elif name == "invalidNamesAreRejected":
                        if json.loads(arguments) != ["../outside.ttf", "/outside.ttf", "folder/font.ttf", "folder\\font.ttf", ".", ".."]:
                            raise ValueError("Unsafe font filename arguments differ from the fixed selection")
                    else:
                        raise ValueError("Unexpected parameterized local-product method: " + identity)
                elif LOCAL_PRODUCT_EXECUTIONS.get(identity, 1) != 1:
                    raise ValueError("Parameterized font method lost its arguments: " + identity)
            records.append({"path": relative, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)})
        if actual != set(expected):
            raise ValueError("Selected source method identities differ for " + suite)
    if (set(LOCAL_PRODUCT_EXECUTIONS) != found or len(found) != LOCAL_PRODUCT_METHOD_COUNT
            or sum(LOCAL_PRODUCT_EXECUTIONS.values()) != LOCAL_PRODUCT_EXECUTION_COUNT):
        raise ValueError("Local-product source method/execution inventory differs from 50/68")
    return {"methodCount": LOCAL_PRODUCT_METHOD_COUNT, "plannedExecutionCount": LOCAL_PRODUCT_EXECUTION_COUNT,
            "expectedExecutionsByMethod": dict(sorted(LOCAL_PRODUCT_EXECUTIONS.items())), "sourceInputs": records}


def verify_local_product_cases(tree):
    # Parameter nodes use the actual xcresult schema frozen in
    # ios-cache-tests-f73f0ae.json: Test Case -> individual Arguments leaves.
    if not isinstance(tree, dict) or not isinstance(tree.get("testNodes"), list):
        raise ValueError("Local-product case gate requires xcresult testNodes")
    found = {}

    def visit(node):
        if not isinstance(node, dict):
            raise ValueError("Malformed local-product test node")
        children = node.get("children", [])
        if not isinstance(children, list):
            raise ValueError("Malformed local-product child nodes")
        kind = node.get("nodeType")
        if kind == "Test Case":
            identifier = node.get("nodeIdentifier")
            if not isinstance(identifier, str):
                raise ValueError("Local-product test case lacks its source method identifier")
            parts = identifier.split("/")
            if len(parts) == 3 and parts[0] == "yuedu appTests":
                parts = parts[1:]
            identity = "/".join(parts)
            expected = LOCAL_PRODUCT_EXECUTIONS.get(identity)
            if expected is None or identity in found or node.get("result") != "Passed":
                raise ValueError("Unexpected, duplicate, skipped or failed local-product method: " + identifier)
            if expected == 1:
                if children:
                    raise ValueError("Unexpected execution children for nonparameterized method: " + identity)
            else:
                argument_names = []
                for child in children:
                    if (not isinstance(child, dict) or child.get("nodeType") != "Arguments"
                            or child.get("result") != "Passed" or child.get("children", []) != []
                            or not isinstance(child.get("name"), str) or not child["name"]):
                        raise ValueError("Malformed, skipped or failed local-product argument execution: " + identity)
                    argument_names.append(child["name"])
                if len(argument_names) != expected or len(set(argument_names)) != expected:
                    raise ValueError("Missing, duplicate or extra local-product argument executions: " + identity)
            found[identity] = expected
            return
        if kind not in ("Test Plan", "Unit test bundle", "Test Suite"):
            raise ValueError("Unexpected local-product test node type: " + str(kind))
        if node.get("result", "Passed") != "Passed":
            raise ValueError("Skipped or failed local-product test container")
        for child in children:
            visit(child)

    for node in tree["testNodes"]:
        visit(node)
    if found != LOCAL_PRODUCT_EXECUTIONS:
        raise ValueError("Actual local-product source method identities differ from the fixed selection")
    return {"passedCaseIdentifiers": sorted(found), "passedExecutionsByMethod": dict(sorted(found.items()))}


def verify_local_product(summary, tests, repo=None):
    counts = verify_summary(summary, LOCAL_PRODUCT_METHOD_COUNT, LOCAL_PRODUCT_EXECUTION_COUNT)
    sources = local_product_source_inputs(repo)
    return {**counts, **verify_local_product_cases(tests), "sourceMethodInventory": sources}


def git(*args, binary=False):
    value = subprocess.check_output(["git", "-C", str(REPO), *args], text=not binary)
    return value if binary else value.strip()


def source_sha():
    source = git("rev-parse", "HEAD")
    if re.fullmatch(r"[0-9a-f]{40}", source) is None:
        raise ValueError("Expected a full source Git SHA")
    return source


def validate_tag(tag_prefix="reader-smoke-"):
    if tag_prefix not in ("reader-smoke-", "reader-renewal-"):
        raise ValueError("Unsupported isolated Simulator test tag prefix")
    source = source_sha()
    if os.environ.get("GITHUB_SHA") != source or os.environ.get("GITHUB_REF_NAME") != tag_prefix + source[:7]:
        raise ValueError("Expected " + tag_prefix + "<current SHA7> and matching checkout")
    return source


def overlay_info(path, record_path, source_commit=None):
    if source_commit is not None and (not isinstance(source_commit, str)
                                      or re.fullmatch(r"[0-9a-f]{40}", source_commit) is None):
        raise ValueError("Info source stamp requires a full lowercase source Git SHA")
    path, record_path = config.checked_path(path), config.checked_path(record_path)
    if record_path.exists():
        raise ValueError("Refusing to replace prior Info overlay evidence")
    original = path.read_bytes()
    info = plistlib.loads(original)
    info.update(config.LOCAL_FLAGS)
    info["GatewayBaseURL"] = ""
    info["GIDClientID"] = config.GOOGLE_CLIENT
    if source_commit is not None:
        info["YueduExperienceSourceCommit"] = source_commit
        info["GitCommitSHA"] = source_commit[:7]
    for entry in info.get("CFBundleURLTypes", []):
        entry["CFBundleURLSchemes"] = [config.GOOGLE_REVERSED if item.startswith("com.googleusercontent.apps.") else item
                                       for item in entry.get("CFBundleURLSchemes", [])]
    replacement = plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=False)
    record = {"path": INFO, "originalSHA256": hashlib.sha256(original).hexdigest(),
              "overlaySHA256": hashlib.sha256(replacement).hexdigest(),
              "localFlags": config.LOCAL_FLAGS, "gatewayConfigured": False,
              "upstreamOAuthReplaced": True, "expectedTrackedOverlay": True}
    if source_commit is not None:
        record["sourceCommitStamped"] = source_commit
    config.write_new_json(record_path, record)
    path.write_bytes(replacement)
    return record


def prepare(directory, tag_prefix="reader-smoke-"):
    # Retain the zero-argument default used by the existing private smoke
    # adapters; an additional protocol must explicitly opt into its own tag.
    source = validate_tag() if tag_prefix == "reader-smoke-" else validate_tag(tag_prefix)
    if git("status", "--porcelain", "--untracked-files=no"):
        raise ValueError("Smoke preparation requires a clean tracked source checkout")
    directory = config.checked_path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    audit_path = directory / "overlays.json"
    if audit_path.exists():
        raise ValueError("Refusing to overwrite smoke overlay evidence")
    for path in OVERLAYS:
        if (REPO / path).read_bytes() != git("show", "HEAD:" + path, binary=True):
            raise ValueError("Source bytes differ from HEAD before smoke overlay: " + path)
    synthetic = config.stage(REPO / "GoogleService-Info.plist")
    project = config.overlay_project(REPO / config.PROJECT, directory / "project-overlay.json")
    if tag_prefix == "reader-renewal-":
        info = overlay_info(REPO / INFO, directory / "info-overlay.json", source_commit=source)
    else:
        info = overlay_info(REPO / INFO, directory / "info-overlay.json")
    audit = {"schemaVersion": 1, "sourceCommit": source, "preparedAt": datetime.now(timezone.utc).isoformat(),
             "expectedTrackedChanges": sorted({INFO} | ({config.PROJECT} if project["expectedTrackedOverlay"] else set())),
             "projectOverlay": project, "infoOverlay": info,
             "syntheticConfiguration": synthetic, "paidFeatureOverrides": False,
             "deliveredIPAModified": False, "configuration": "Debug"}
    review_overlays(audit)
    config.write_new_json(audit_path, audit)
    return audit


def review_overlays(audit):
    if audit.get("sourceCommit") != source_sha():
        raise ValueError("Smoke source HEAD changed after preparation")
    project = audit["projectOverlay"]
    if type(project.get("expectedTrackedOverlay")) is not bool:
        raise ValueError("Project overlay must declare its actual tracked-change state")
    expected_changes = {INFO} | ({config.PROJECT} if project["expectedTrackedOverlay"] else set())
    if set(git("diff", "--name-only", "HEAD").splitlines()) != expected_changes:
        raise ValueError("Only the declared source Info/project overlays may change tracked inputs")
    if "expectedTrackedChanges" in audit and audit["expectedTrackedChanges"] != sorted(expected_changes):
        raise ValueError("Declared tracked changes differ from the actual project overlay")
    for record in (audit["projectOverlay"], audit["infoOverlay"]):
        if record["path"] not in OVERLAYS or config.digest(REPO / record["path"]) != record["overlaySHA256"]:
            raise ValueError("Working smoke overlay differs from its audit record")
        if hashlib.sha256(git("show", "HEAD:" + record["path"], binary=True)).hexdigest() != record["originalSHA256"]:
            raise ValueError("Original smoke overlay bytes differ from source HEAD")
    config.review_project_overlay(project, git("show", "HEAD:" + config.PROJECT, binary=True),
                                  (REPO / config.PROJECT).read_bytes())
    info = plistlib.loads((REPO / INFO).read_bytes())
    require_local_info(info)
    if "sourceCommitStamped" in audit["infoOverlay"]:
        if audit["infoOverlay"]["sourceCommitStamped"] != audit["sourceCommit"]:
            raise ValueError("Info source stamp differs from its preparation source")
        require_source_stamp(info, audit["sourceCommit"])
    if plistlib.loads((REPO / "GoogleService-Info.plist").read_bytes()) != config.synthetic_config():
        raise ValueError("Smoke Firebase configuration must remain exactly synthetic")


def require_local_info(info):
    for name, expected in config.LOCAL_FLAGS.items():
        if info.get(name) is not expected:
            raise ValueError("Missing explicit local-mode Info Boolean: " + name)
    if info.get("GatewayBaseURL") != "" or info.get("GIDClientID") != config.GOOGLE_CLIENT:
        raise ValueError("Smoke host must have an empty gateway and synthetic OAuth identity")


def require_source_stamp(info, source):
    if (not isinstance(source, str) or re.fullmatch(r"[0-9a-f]{40}", source) is None
            or info.get("YueduExperienceSourceCommit") != source
            or info.get("GitCommitSHA") != source[:7]):
        raise ValueError("Info source stamp must match the full and short preparation source SHA")


def verify_summary(summary, expected, expected_executions=None):
    if not isinstance(summary, dict):
        raise ValueError("xcresult summary must be an object with explicit test counts")
    fields = {name: summary.get(name) for name in ("totalTestCount", "passedTests", "failedTests", "skippedTests")}
    if any(type(value) is not int for value in fields.values()):
        raise ValueError("xcresult summary lacks explicit integer test counts")
    if fields != {"totalTestCount": expected, "passedTests": expected, "failedTests": 0, "skippedTests": 0}:
        raise ValueError("Smoke test count/failure/skip gate failed: " + json.dumps(fields))
    result = {"expectedTests": expected, **fields}
    if expected_executions is not None:
        # xcresult's top-level count is unique test methods. Parameterized runs
        # are counted separately in the single selected device/configuration.
        devices = summary.get("devicesAndConfigurations")
        if not isinstance(devices, list) or len(devices) != 1 or not isinstance(devices[0], dict):
            raise ValueError("Execution gate requires exactly one device/configuration")
        counts = {name: devices[0].get(name) for name in ("passedTests", "failedTests", "skippedTests", "expectedFailures")}
        if any(type(value) is not int for value in counts.values()) or counts != {
            "passedTests": expected_executions, "failedTests": 0, "skippedTests": 0, "expectedFailures": 0
        } or type(summary.get("expectedFailures")) is not int or summary["expectedFailures"] != 0:
            raise ValueError("Parameterized execution/failure/skip gate failed: " + json.dumps(counts))
        result.update(expectedExecutions=expected_executions, deviceExecutionCounts=counts)
    return result


def result(audit, settings, unit, ui, paging, product, product_tests):
    review_overlays(audit)
    matches = [item["buildSettings"] for item in settings if item.get("target") == config.MAIN_TARGET]
    if len(matches) != 1:
        raise ValueError("Expected exactly one main reader test host")
    actual = matches[0]
    for name, expected in {"CONFIGURATION": "Debug", "SWIFT_VERSION": "5.0", "PLATFORM_NAME": "iphonesimulator",
                           "PRODUCT_BUNDLE_IDENTIFIER": config.MAIN_BUNDLE}.items():
        if actual.get(name) != expected:
            raise ValueError("Unexpected actual smoke host setting: " + name)
    app = config.checked_path(Path(actual["TARGET_BUILD_DIR"]) / actual["FULL_PRODUCT_NAME"])
    info = config.read_info(app)
    require_local_info(info)
    if plistlib.loads((app / "GoogleService-Info.plist").read_bytes()) != config.synthetic_config():
        raise ValueError("The tested app must include the exact synthetic Firebase configuration")
    if info.get("CFBundleSupportedPlatforms") != ["iPhoneSimulator"] or info.get("CFBundleIdentifier") != config.MAIN_BUNDLE:
        raise ValueError("The tested app must be the isolated local Simulator reader")
    config.no_jvm_payload(app)
    return {"schemaVersion": 1, "sourceCommit": audit["sourceCommit"], "configuration": "Debug",
            "executionPlatform": "ios-simulator", "simulatorDestination": os.environ.get("YUEDU_DEST"),
            "developerDirectory": os.environ.get("DEVELOPER_DIR"), "status": "passed",
            "targetedTests": {"cloudKitAndLocalServicesConfiguration": verify_summary(unit, 9),
                              "localProductFeatures": verify_local_product(product, product_tests),
                              "searchAutoPaging": verify_summary(paging, 12), "TXTReaderUI": verify_summary(ui, 1)},
            "testedApp": str(app), "testedInfoSHA256": config.digest(app / "Info.plist"),
            "sourceOverlays": audit, "readerRoute": "Existing Yuedu/CoreText local TXT reader and source search pagination",
            "covered": ["TXT auto-import through LocalBookImportService", "bookshelf entry", "visible CoreText body",
                        "chapter selection through the real TOC", "shelf progress and selected chapter restored after relaunch",
                        "source HTTP-stub pagination through real HTML parsing and hasMoreRule evaluation",
                        "first-page false stops paging; true, invalid and unknown/cache verdicts preserve bounded paging"],
            "paidFeatureOverrides": False, "jvmIntegratedIntoReading": False,
            "deliveredIPAExecuted": False, "deviceValidationPassed": False,
            "limitations": ["Debug Simulator test, not execution of the delivered Release IPA.",
                            "Auto-import uses an existing DEBUG hook, not the Files picker UI.",
                            "This does not accept network sources, EPUB/PDF, RSS, TTS or full Legado compatibility."]}


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="phase", required=True)
    validation = commands.add_parser("validate-tag")
    validation.add_argument("--tag-prefix", choices=("reader-smoke-", "reader-renewal-"), default="reader-smoke-")
    preparation = commands.add_parser("prepare")
    preparation.add_argument("--directory", type=Path, required=True)
    preparation.add_argument("--tag-prefix", choices=("reader-smoke-", "reader-renewal-"), default="reader-smoke-")
    verify = commands.add_parser("verify-summary")
    verify.add_argument("--summary", type=Path, required=True)
    verify.add_argument("--expected", type=int, required=True)
    verify.add_argument("--expected-executions", type=int)
    commands.add_parser("local-product-source", help="Inventory the fixed source selection without running Swift")
    product = commands.add_parser("verify-local-product", help="Require local-product 50 methods/68 executions and source method identities")
    product.add_argument("--summary", type=Path, required=True)
    product.add_argument("--tests", type=Path, required=True)
    summarize = commands.add_parser("result", help="Require configuration=9, product=50/68, paging=12 and TXT UI=1 summaries")
    for name in ("audit", "settings", "unit", "ui", "paging", "product", "product-tests", "output"):
        summarize.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.phase == "validate-tag":
            value = {"sourceCommit": validate_tag(args.tag_prefix)}
        elif args.phase == "prepare":
            value = prepare(args.directory, tag_prefix=args.tag_prefix)
        elif args.phase == "verify-summary":
            value = verify_summary(read_json(args.summary), args.expected, args.expected_executions)
        elif args.phase == "local-product-source":
            value = local_product_source_inputs()
        elif args.phase == "verify-local-product":
            value = verify_local_product(read_json(args.summary), read_json(args.tests))
        else:
            value = result(read_json(args.audit), read_json(args.settings), read_json(args.unit),
                           read_json(args.ui), read_json(args.paging), read_json(args.product), read_json(args.product_tests))
            config.write_new_json(args.output, value)
        print(json.dumps(value, indent=2))
        return 0
    except Exception as error:
        print(f"{type(error).__name__}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
