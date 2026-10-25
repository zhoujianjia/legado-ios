#!/usr/bin/env python3
"""Required same-job full-device-package preparation and Simulator signing gate.

The input IPA is this job's fresh iPhoneOS build, never an old release. Device
Mach-O is input DATA to the existing production signer, not Simulator code.
Only public small evidence is retained; the complete IPA stays job-local.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
CASE = "SelfRenewalFullApplicationSignerTests/signsFullCurrentIPhoneOSJVMApplicationThroughSameProductionOwners"
RESOURCE_NAMES = ("full-sdk-owned-package.json", "full-sdk-owned-package.ipa")
RESOURCE_ROOT = Path("Tests/iOS/yuedu appTests")
WORK = Path(".build/s3-full-application-signing")
PRIVATE = Path(".build/s3-full-application-private")


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def fact(path):
    digest = hashlib.sha256()
    count = 0
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            count += len(chunk)
            digest.update(chunk)
    return {"bytes": count, "sha256": digest.hexdigest()}


def write_new(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")


def checked(path):
    path = path.absolute()
    if any(p.is_symlink() or getattr(p, "is_junction", lambda: False)() for p in (path, *path.parents)):
        raise ValueError("Symlinked full-application input/output is forbidden")
    return path


def signing_source_inputs():
    # Bind the whole existing signing/verification owner family, rather than
    # accepting a green test against an unbound Signer/Vault/CMS/ZIP dependency.
    paths = set((REPO / "Modules/Services/SelfRenewal").glob("*.swift"))
    paths.update(REPO / p for p in (
        "Tests/iOS/yuedu appTests/SelfRenewalFullApplicationSignerTests.swift",
        "Tests/iOS/yuedu appTests/SelfRenewalSigningOwnedPKIFixture.swift",
        "scripts/reader-experience/full-application-signing-tools.py",
        "scripts/reader-experience/build.sh", "scripts/reader-experience/stage-config.py",
        "scripts/reader-experience/runtime-packaging.py", "scripts/reader-experience/runtime-notices.py",
        "ShareExtension/Info.plist", "Widget/Info.plist",
        "scripts/legado-ios/stage-runtime.py", "scripts/legado-ios/verify-runtime.py",
        "scripts/legado-ios/verify-native-reuse.py", "scripts/legado-ios/runtime-lock.json",
        "scripts/xctest.sh", "scripts/reader-experience/smoke-tools.py",
        "Packages/LegadoRuntime/Package.swift",
        "Yuedu-Reader.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"))
    paths.update(HERE / "owned-package-fixture" / name for name in (
        "generate-sdk-owned-package.py", "full-application-package.py", "ImportOwnedIdentity.swift",
        "OwnedIdentitySearch.h", "OwnedIdentitySearch.c", "main.c", "extension.c", "framework.c"))
    return [{"path": str(p.relative_to(REPO).as_posix()), **fact(checked(p))}
            for p in sorted(paths) if p.is_file()]


def admission():
    source = subprocess.check_output(["git", "-C", str(REPO), "rev-parse", "HEAD"], text=True).strip()
    if (sys.platform != "darwin" or not re.fullmatch("[0-9a-f]{40}", source)
            or os.environ.get("GITHUB_SHA") != source or not os.environ.get("GITHUB_RUN_ID")
            or os.environ.get("GITHUB_REF_NAME") != "legado-native-reader-test-" + source[:7]):
        raise ValueError("Full application requires the current-source macOS Native checkpoint job")
    return source


def validate_reuse(proof, source, run_id, audited, native):
    if (not run_id or proof.get("workflowRunID") != run_id or proof.get("sourceCommit") != source
            or proof.get("status") != "restored" or proof.get("nativeRuntimeRecompiled") is not False
            or proof.get("freshOrdinaryJVMRequired") is not True
            or proof.get("nativeExecutionVerified") is not False or proof.get("deviceValidationPassed") is not False
            or proof.get("nativeZIP") != {"bytes": native.BASELINE_BYTES, "sha256": native.BASELINE_DIGEST}
            or any(proof.get(k) != audited[k] for k in ("jar", "nativeLayout"))):
        raise ValueError("Full-application native/JAR proof is missing, stale, or not from this job")


def command(work, name, argv, seconds, env=None):
    output = work / (name + ".log")
    record = {"argv": [str(v) for v in argv], "timeoutSeconds": seconds, "timedOut": False}
    with output.open("xb") as stream:
        child = subprocess.Popen(record["argv"], cwd=REPO, env=env, stdout=stream,
                                 stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = child.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            record["timedOut"] = True
            # The producer gets its existing owned-Keychain cleanup allowance.
            os.killpg(child.pid, signal.SIGTERM)
            try:
                code = child.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                code = child.wait()
    record.update(exitCode=code, output={"path": output.name, **fact(output)})
    write_new(work / (name + "-execution.json"), record)
    if code != 0 or record["timedOut"]:
        raise RuntimeError("Full-application phase failed: " + name)
    return record


def resource_binding(directory, source, producer):
    metadata_path = checked(directory / RESOURCE_NAMES[0])
    archive = checked(directory / RESOURCE_NAMES[1])
    if not metadata_path.is_file() or not archive.is_file() or not 0 < metadata_path.stat().st_size <= 1_048_576:
        raise ValueError("Required complete package resources are absent; no minimal fallback")
    if not 0 < archive.stat().st_size <= 536_870_912:
        raise ValueError("Complete input exceeds the existing production archive budget")
    meta = json.loads(metadata_path.read_bytes())
    archive_fact = fact(archive)
    if (meta.get("schema") != 1 or meta.get("kind") != "full-current-source-iphoneos-jvm-application"
            or meta.get("sourceCommit") != source or meta.get("archiveFile") != RESOURCE_NAMES[1]
            or not 0 < archive_fact["bytes"] <= 536_870_912
            or archive_fact != {"bytes": meta.get("archiveBytes"), "sha256": meta.get("archiveSHA256")}
            or meta.get("privateMaterialArtifacts") != 0 or meta.get("realAppleAccountUsed") is not False
            or meta.get("controlledOriginalSigningOnly") is not True or meta.get("realDeviceExecution") is not False
            or meta.get("allUnrelatedDeviceBuildFilesPreserved") is not True
            or producer.get("fullApplication") != meta
            or any(producer.get(k) is not True for k in ("temporaryOwnedKeychainDeleted", "temporaryUserSearchListRestoredAndOwnedAbsent"))
            or producer.get("privateMaterialArtifacts") != 0 or producer.get("privateKeyFilesOutsideKeychain") != 0
            or producer.get("userAdminSystemTrustChanged") is not False):
        raise ValueError("Complete package metadata, archive, or owned signing cleanup failed")
    outputs = {v["path"]: {"bytes": v["bytes"], "sha256": v["sha256"]} for v in producer["publicOutputs"]}
    values = {RESOURCE_NAMES[0]: fact(metadata_path), RESOURCE_NAMES[1]: archive_fact}
    if any(outputs.get(name) != value for name, value in values.items()):
        raise ValueError("Full package resources differ from actual producer outputs")
    return values


def restore_build_overlays(config, original, build):
    """Restore only this fresh build's exact source overlay and synthetic plist."""
    project = REPO / config.PROJECT
    overlaid, _ = config.project_overlay(original)
    if project.read_bytes() not in (original, overlaid):
        raise ValueError("Device build project changed beyond its permitted overlay")
    if project.read_bytes() != original:
        if not (build / "project-overlay.json").is_file():
            raise ValueError("Missing device overlay receipt")
        config.review_project_overlay(json.loads((build / "project-overlay.json").read_bytes()), original, overlaid)
        project.write_bytes(original)
    google = REPO / "GoogleService-Info.plist"
    if google.exists():
        if plistlib.loads(google.read_bytes()) != config.synthetic_config():
            raise ValueError("Refusing to remove an unowned Google configuration")
        google.unlink()


def prepare(native_record):
    source = admission()
    work, private = checked(REPO / WORK), checked(REPO / PRIVATE)
    if work.exists() or private.exists() or (REPO / "GoogleService-Info.plist").exists():
        raise ValueError("Full-application preparation requires fresh owned directories and no existing configuration")
    if subprocess.check_output(["git", "-C", str(REPO), "status", "--porcelain", "--untracked-files=no"]):
        raise ValueError("Run full-device preparation before Simulator source overlays")
    runtime = load("full_app_existing_packaging", HERE / "runtime-packaging.py")
    config = load("full_app_existing_config", HERE / "stage-config.py")
    proof_path = checked(native_record)
    proof = json.loads(proof_path.read_bytes())
    audited = runtime.audit_native(REPO, runtime.JAR)
    validate_reuse(proof, source, os.environ["GITHUB_RUN_ID"], audited, runtime.native)
    work.mkdir(parents=True)
    private.mkdir(parents=True, mode=0o700)
    build, produced = private / "device-build", private / "produced"
    original = (REPO / config.PROJECT).read_bytes()
    build.mkdir()
    write_new(build / "native-reuse.json", proof)
    write_new(work / "native-reuse-binding.json", {"sourceCommit": source, "workflowRunID": os.environ["GITHUB_RUN_ID"],
        "nativeRecord": {"path": str(proof_path.relative_to(REPO)), **fact(proof_path)}, "audited": audited})
    primary = None
    try:
        command(work, "device-runtime-stage", [sys.executable, HERE.parent / "legado-ios/stage-runtime.py",
            "--java-home", REPO / runtime.native.HOMES["device"], "--jar", runtime.JAR,
            "--destination", REPO / "Resources/LegadoRuntime", "--replace"], 300)
        environment = dict(os.environ, LEGADO_READER_WITH_JVM="1", YUEDU_READER_BUILD_DIR=str(build))
        command(work, "full-device-build", ["bash", HERE / "build.sh"], 3600, environment)
        command(work, "full-owned-producer", [sys.executable, HERE / "owned-package-fixture/generate-sdk-owned-package.py",
            "--output", produced, "--full-application-build", build], 360)
        producer = json.loads((produced / "full-sdk-produced-fixture-manifest.json").read_bytes())
        values = resource_binding(produced, source, producer)
        # Only public small JSON is copied into the always-artifact directory.
        for name in ("full-sdk-produced-fixture-manifest.json", RESOURCE_NAMES[0]):
            shutil.copy2(produced / name, work / name)
        destination = REPO / RESOURCE_ROOT
        for name in RESOURCE_NAMES:
            target = checked(destination / name)
            if target.exists():
                raise ValueError("Refusing a pre-existing complete package test resource")
        for name in RESOURCE_NAMES:
            shutil.copy2(produced / name, destination / name)
        if {name: fact(destination / name) for name in RESOURCE_NAMES} != values:
            raise ValueError("Complete test-resource staging changed bytes")
        write_new(work / "prepared.json", {"sourceCommit": source, "workflowRunID": os.environ["GITHUB_RUN_ID"],
            "requiredCase": CASE, "resources": values, "producerManifest": fact(work / "full-sdk-produced-fixture-manifest.json"),
            "signingSourceInputs": signing_source_inputs(),
            "completeApplicationBuilt": True, "controlledSigningExecuted": True,
            "productionPackageSignerExecuted": False, "deviceValidationPassed": False})
    except BaseException as error:
        primary = error
        write_new(work / "preparation-failure.json", {"errorType": type(error).__name__,
            "completeSigningAcceptance": False, "deviceValidationPassed": False})
        raise
    finally:
        try:
            restore_build_overlays(config, original, build)
            write_new(work / "device-source-overlay-restoration.json", {"restored": True, "project": fact(REPO / config.PROJECT)})
        except Exception as error:
            write_new(work / "device-source-overlay-restoration-failed.json", {"errorType": type(error).__name__, "primaryFailurePreserved": primary is not None})
            if primary is None:
                raise


def verify_cases(tree):
    cases = []
    if not isinstance(tree, dict) or not isinstance(tree.get("testNodes"), list):
        raise ValueError("Missing actual full-application xcresult case tree")
    def visit(node):
        if not isinstance(node, dict) or not isinstance(node.get("children", []), list):
            raise ValueError("Malformed full-application xcresult node")
        if node.get("nodeType") == "Test Case":
            identifier = node.get("nodeIdentifier", "")
            if (not isinstance(identifier, str) or "/".join(identifier.removesuffix("()").split("/")[-2:]) != CASE
                    or node.get("result") != "Passed"):
                raise ValueError("Unexpected, failed, or skipped complete signing case")
            cases.append(CASE)
        for child in node.get("children", []):
            visit(child)
    for node in tree["testNodes"]:
        visit(node)
    if cases != [CASE]:
        raise ValueError("Complete signing requires its one exact executed test, never a zero-test result")
    return cases


def early_summary(work, source, run_id):
    """Project fixed existing outputs only; never export arbitrary diagnostics.

    This is not an acceptance gate. Unknown/missing evidence stays unknown.
    Execution argv, arbitrary output paths and free failure text never leave.
    """
    if re.fullmatch('[0-9a-f]{40}', source) is None or re.fullmatch('[0-9]{1,20}', run_id) is None:
        raise ValueError('Invalid early diagnostic source identity')
    work = checked(work)
    def read(name, maximum=1_048_576, json_object=True):
        path = checked(work / name)
        try:
            with path.open('rb') as stream:
                raw = stream.read(maximum + 1)
        except FileNotFoundError:
            return 'missing', None, None
        except OSError:
            return 'unreadable', None, None
        if len(raw) > maximum:
            return 'oversize', None, None
        fixed_fact = {'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
        if not json_object:
            return 'available', None, fixed_fact
        try:
            value = json.loads(raw)
        except (ValueError, UnicodeError, RecursionError):
            return 'invalid', None, fixed_fact
        return ('available', value, fixed_fact) if isinstance(value, dict) else ('invalid', None, fixed_fact)
    def number(value, low=0, high=1_000_000):
        return value if type(value) is int and low <= value <= high else None
    prepared_state, prepared, _ = read('prepared.json')
    result_state, result, _ = read('result.json')
    bound = (prepared is not None and prepared.get('sourceCommit') == source
        and prepared.get('workflowRunID') == run_id
        and (result is None or result.get('sourceCommit') == source))
    output = {'schema': 1, 'kind': 'early-s3-public-diagnostic', 'sourceCommit': source,
        'workflowRunID': run_id, 'expectedCase': CASE, 'sourceBinding': 'matched' if bound else 'unknown',
        'diagnosticOnly': True, 'productionSigningAcceptance': False, 'deviceValidationPassed': False,
        'preparedState': prepared_state, 'resultState': result_state, 'sourceResultStatus': 'unknown',
        'execution': {}, 'fixedOutputFacts': {}, 'summary': None,
        'observedExecuted': None, 'observedPassed': None, 'observedFailed': None, 'observedSkipped': None,
        'exactCaseSelectionObserved': None, 'failureTags': [], 'unknownFailureOccurrencesWithheld': 0}
    if bound and result is not None and result.get('status') in ('passed', 'failed'):
        output['sourceResultStatus'] = result['status']
    for phase in ('full-application-test', 'full-application-summary', 'full-application-tests'):
        state, value, _ = read(phase + '-execution.json', 65_536)
        entry = {'state': state, 'exitCode': None, 'timeoutSeconds': None, 'timedOut': None}
        if bound and value is not None:
            entry.update(exitCode=number(value.get('exitCode'), -255, 255),
                timeoutSeconds=number(value.get('timeoutSeconds'), 1, 3660),
                timedOut=value.get('timedOut') if type(value.get('timedOut')) is bool else None)
        output['execution'][phase] = entry
        _, _, value_fact = read(phase + '.log', json_object=False)
        if value_fact is not None:
            output['fixedOutputFacts'][phase + '.log'] = value_fact
    safe_tags = {'sizeLimit', 'missingSignature', 'unsupportedHash', 'contentReadLimit', 'hashOperationLimit',
        'truncatedRead', 'changedDirectory', 'missingSpecialSlot', 'unexpectedSpecialSlot',
        'codeSlotMismatch', 'specialSlotMismatch', 'invalidInfoMetadata', 'malformedInfoPlist',
        'missingApplicationInfo', 'unsupportedComponents', 'profileBytesNotBound', 'malformedEnvelope',
        'changedCodeDirectory', 'missingResource', 'addedResource', 'digestMismatch',
        'missingComponentMaterial', 'changedInfo', 'unsignedCode', 'missingDEREntitlements',
        'signerNotInProfile', 'applicationIdentifierMismatch', 'teamMismatch', 'groupNotInProfile'}
    tags = set()
    def failure(text):
        match = re.search(r'Caught error: \.?([A-Za-z][A-Za-z0-9]*)(?=\(|$)', text) if isinstance(text, str) else None
        if match is None or match[1] not in safe_tags:
            output['unknownFailureOccurrencesWithheld'] += 1
            return
        # Only a fixed public enum tag survives. Associated strings/paths and
        # arbitrary numeric payloads are withheld, including unknown failures.
        tags.add(match[1])
    summary_state, summary, _ = read('full-application-summary.log')
    output['summaryState'] = summary_state
    if bound and summary is not None:
        output['summary'] = {key: number(summary.get(key)) for key in
            ('totalTestCount', 'passedTests', 'failedTests', 'skippedTests', 'expectedFailures')}
        for item in summary.get('testFailures', [])[:256] if isinstance(summary.get('testFailures', []), list) else []:
            if isinstance(item, dict) and item.get('testIdentifierString') == CASE + '()':
                failure(item.get('failureText'))
    tree_state, tree, _ = read('full-application-tests.log')
    output['testsState'] = tree_state
    exports_ok = all(output['execution'][phase]['exitCode'] == 0 and output['execution'][phase]['timedOut'] is False
        for phase in ('full-application-summary', 'full-application-tests'))
    execution_valid = all(entry['exitCode'] is not None and entry['timeoutSeconds'] is not None
        and entry['timedOut'] is False for entry in output['execution'].values())
    counts_available = (exports_ok and execution_valid and output['summary'] is not None
        and all(value is not None for value in output['summary'].values())
        and output['execution']['full-application-test']['timedOut'] is False)
    if bound and tree is not None and isinstance(tree.get('testNodes'), list):
        stack = [(node, 0, False) for node in tree['testNodes']]
        statuses = []; unexpected = False; valid = True; visited = 0
        while stack:
            node, depth, selected = stack.pop(); visited += 1
            if visited > 4096 or depth > 32 or not isinstance(node, dict) or not isinstance(node.get('children', []), list):
                valid = False
                break
            if node.get('nodeType') == 'Test Case':
                selected = node.get('nodeIdentifier') in (CASE, CASE + '()', 'yuedu appTests/' + CASE, 'yuedu appTests/' + CASE + '()')
                if selected: statuses.append(node.get('result'))
                else: unexpected = True
            if selected and node.get('nodeType') == 'Failure Message':
                failure(node.get('name'))
            stack.extend((child, depth + 1, selected) for child in node.get('children', []))
        if counts_available and valid and unexpected:
            output['exactCaseSelectionObserved'] = False
        reconciled = (counts_available and output['summary']['totalTestCount'] == len(statuses)
            and output['summary']['passedTests'] == statuses.count('Passed')
            and output['summary']['failedTests'] == statuses.count('Failed')
            and output['summary']['skippedTests'] == statuses.count('Skipped'))
        if reconciled and valid and not unexpected and all(status in ('Passed', 'Failed', 'Skipped') for status in statuses):
            output.update(observedExecuted=sum(status != 'Skipped' for status in statuses),
                observedPassed=statuses.count('Passed'), observedFailed=statuses.count('Failed'),
                observedSkipped=statuses.count('Skipped'), exactCaseSelectionObserved=len(statuses) == 1 and not unexpected)
    output['failureTags'] = sorted(tags)
    if not tags:
        output['failureTags'] = ['unknown']
    return output


def run():
    source = admission()
    work = REPO / WORK
    prepared = json.loads((work / "prepared.json").read_bytes())
    producer = json.loads((work / "full-sdk-produced-fixture-manifest.json").read_bytes())
    if (prepared.get("sourceCommit") != source or prepared.get("workflowRunID") != os.environ["GITHUB_RUN_ID"]
            or prepared.get("signingSourceInputs") != signing_source_inputs()
            or prepared.get("producerManifest") != fact(work / "full-sdk-produced-fixture-manifest.json")
            or prepared.get("resources") != resource_binding(REPO / RESOURCE_ROOT, source, producer)
            or not re.fullmatch(r"id=[0-9A-Fa-f-]{36}", os.environ.get("YUEDU_DEST", ""))):
        raise ValueError("Prepared same-job complete input or Simulator destination changed")
    # Existing Native preparation alone owns the Simulator source overlay.
    # Recheck it instead of treating a dirty checkout as arbitrary permission.
    smoke = load("full_app_existing_summary_gate", HERE / "smoke-tools.py")
    audit = json.loads((REPO / ".build/native-reader-test/overlays.json").read_bytes())
    smoke.review_overlays(audit)
    if audit.get("sourceCommit") != source or audit.get("infoOverlay", {}).get("sourceCommitStamped") != source:
        raise ValueError("Complete signing test requires this source's real Native host overlay")
    args = ["-configuration", "Debug", "-onlyUsePackageVersionsFromResolvedFile", "CODE_SIGNING_ALLOWED=YES",
        "CODE_SIGNING_REQUIRED=YES", "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=",
        "CODE_SIGN_ENTITLEMENTS=", "GATEWAY_BASE_URL=", "YUEDU_LOCAL_EXPERIENCE=YES", "IPHONEOS_DEPLOYMENT_TARGET=18.0",
        "ENABLE_DEBUG_DYLIB=NO", "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG LEGADO_REQUIRE_NATIVE_MAINJS"]
    bundle = work / "full-application.xcresult"
    failed = None
    try:
        command(work, "full-application-test", ["bash", REPO / "scripts/xctest.sh", "-l", work / "full-application-test-build.log",
            "-t", "3600", "--", *args, "-resultBundlePath", bundle, "-only-testing:yuedu appTests/" + CASE + "()"], 3660)
    except Exception as error:
        failed = error
    # Export actual evidence even when the App build or test failed.
    export_failures = []
    for kind in ("summary", "tests"):
        try:
            command(work, "full-application-" + kind, ["xcrun", "xcresulttool", "get", "test-results", kind, "--path", bundle], 60)
        except Exception as error:
            export_failures.append(type(error).__name__)
    if failed is not None or export_failures:
        write_new(work / "result.json", {"sourceCommit": source, "status": "failed", "testPhaseFailed": failed is not None,
            "exportFailures": export_failures, "productionSigningAcceptance": False, "deviceValidationPassed": False})
        raise RuntimeError("Full application signing has failed or missing actual test evidence")
    summary = smoke.verify_summary(json.loads((work / "full-application-summary.log").read_bytes()), 1, 1)
    cases = verify_cases(json.loads((work / "full-application-tests.log").read_bytes()))
    after = resource_binding(REPO / RESOURCE_ROOT, source, producer)
    if after != prepared["resources"]:
        raise ValueError("Complete input resources changed during the production signing test")
    smoke.review_overlays(audit)
    if prepared["signingSourceInputs"] != signing_source_inputs():
        raise ValueError("Production signing/verification inputs changed during the test")
    write_new(work / "result.json", {"sourceCommit": source, "workflowRunID": os.environ["GITHUB_RUN_ID"], "status": "passed",
        "summary": summary, "cases": cases, "resources": after, "productionControlledPackageSignerExecuted": True,
        "independentArchiveVerificationExecuted": True, "actualDeviceIPARun": False, "realAppleAccountUsed": False,
        "completeAutomaticRenewalVerified": False, "deviceValidationPassed": False})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("prepare", "run", "early-summary"))
    parser.add_argument("--native-record", type=Path, default=REPO / ".build/native-reader-test/native-restore.json")
    args = parser.parse_args()
    if args.phase == "prepare":
        prepare(args.native_record)
    elif args.phase == 'run':
        run()
    else:
        source = admission()
        write_new(REPO / WORK / 'early-public-summary.json', early_summary(REPO / WORK, source, os.environ['GITHUB_RUN_ID']))


if __name__ == "__main__":
    main()
