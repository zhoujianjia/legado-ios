#!/usr/bin/env python3
"""Complete, unoptimized device diagnostics; never Release or S3 acceptance."""
import argparse
from contextlib import contextmanager
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
spec = importlib.util.spec_from_file_location("diagnostic_existing_package", HERE / "renewal-package-tools.py")
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)
full, native = package.full, package.native
config = full.load("diagnostic_existing_config", HERE / "stage-config.py")
runtime = full.load("diagnostic_existing_runtime", HERE / "runtime-packaging.py")
WORK = REPO / ".build/renewal-diagnostic"
BUILD = REPO / ".build/renewal-diagnostic-private/device-build"
PUBLIC = REPO / ".build/renewal-diagnostic-public"
SIMULATOR = REPO / ".build/renewal-diagnostic-private/simulator"
SIMULATOR_TESTS = REPO / config.DIAGNOSTIC_AUTH_TEST_ROOT
PRODUCED = REPO / ".build/renewal-diagnostic-private/sdk-produced"
LOGS = REPO / ".build/ci-logs"
ENROLLMENT_CASE = "SelfRenewalDeveloperAuthenticationTests/connectsOnlyThroughActualMaterialAccountValidation"
ENROLLMENT_SOURCES = tuple("Tests/iOS/yuedu appTests/" + name for name in (
    "SelfRenewalDeveloperAuthenticationTests.swift", "SelfRenewalSigningOwnedPKIFixture.swift",
    "SelfRenewalCMSFixture.swift", "SelfRenewalApplicationMaterialFixture.swift"))
SDK_RESOURCE = "Tests/iOS/yuedu appTests/owned-sdk-package.json"
SDK_TOOLS = ("generate-sdk-owned-package.py", "ImportOwnedIdentity.swift", "OwnedIdentitySearch.h",
             "OwnedIdentitySearch.c", "main.c", "extension.c", "framework.c")
INPUTS = (".github/workflows/yuedu-renewal-diagnostic.yml", "scripts/reader-experience/renewal-diagnostic-tools.py",
          "scripts/reader-experience/build.sh", "scripts/reader-experience/stage-config.py",
          "scripts/reader-experience/renewal-probe-tools.py", "scripts/xctest.sh", "scripts/sim.sh",
          "Modules/Services/SelfRenewal/SelfRenewalSigningMaterialVault.swift",
          "Tests/iOS/yuedu appTests/SelfRenewalSigningMaterialVaultTests.swift",
          "Modules/Services/SelfRenewal/SelfRenewalDeveloperAuthentication.swift",
          "Modules/Services/SelfRenewal/SelfRenewalAnisetteV3Provider.swift",
          "Modules/Services/SelfRenewal/SelfRenewalDeveloperAccountTransport.swift",
          "Modules/Services/SelfRenewal/SelfRenewalGSASRP.swift",
          *ENROLLMENT_SOURCES,
          "docs/legado-ios/evidence/renewal-opaque-adsid-step/generate-owned-vectors.py",
          "docs/legado-ios/evidence/renewal-opaque-adsid-step/owned-vectors.json",
          *("scripts/reader-experience/owned-package-fixture/" + name for name in SDK_TOOLS), *package.INPUTS)


def source():
    value = native.smoke.source_sha()
    tag = "yuedu-renewal-diagnostic-" + value[:7]
    if (sys.platform != "darwin" or re.fullmatch(r"[0-9a-f]{40}", value) is None
            or os.environ.get("GITHUB_SHA") != value or not os.environ.get("GITHUB_RUN_ID", "").isdigit()
            or os.environ.get("GITHUB_REF_NAME") != tag or os.environ.get("GITHUB_REF") != "refs/tags/" + tag):
        raise ValueError("Expected this source's isolated macOS renewal-diagnostic tag")
    return value


def binding():
    return {"schemaVersion": 1, "sourceCommit": source(), "workflowRunID": os.environ["GITHUB_RUN_ID"],
        "workflowRunAttempt": os.environ.get("GITHUB_RUN_ATTEMPT"), "sourceTag": os.environ["GITHUB_REF_NAME"],
        "diagnosticInputs": [{"path": path, **full.fact(full.checked(REPO / path))} for path in sorted(set(INPUTS))],
        "diagnosticOnly": True, "releaseAcceptance": False, "S3Acceptance": "not_run",
        "fullNativeAcceptance": False, "fullSDKAcceptance": False, "nativeRuntimeRecompiled": False,
        "deviceValidationPassed": False, "completeAutomaticRenewalVerified": False}


def check_binding():
    receipt = json.loads((WORK / "scope-binding.json").read_bytes())
    if receipt != binding():
        raise ValueError("Diagnostic source/run/input binding changed")
    return receipt


def restore():
    receipt = binding()
    if WORK.exists():
        raise ValueError("Diagnostic restoration requires a fresh work directory")
    original = runtime.validate_tag
    try:
        runtime.validate_tag = source
        proof = runtime.restore()
    finally:
        runtime.validate_tag = original
    proof["admission"] = "renewal-diagnostic"
    WORK.mkdir(parents=True)
    full.write_new(WORK / "native-restore.json", proof)
    full.write_new(WORK / "scope-binding.json", receipt)


def prepare():
    receipt = check_binding()
    if BUILD.parent.exists() or (REPO / "GoogleService-Info.plist").exists():
        raise ValueError("Diagnostic build requires fresh owned output and no existing configuration")
    if subprocess.check_output(["git", "-C", str(REPO), "status", "--porcelain", "--untracked-files=no"]):
        raise ValueError("Diagnostic preparation requires a clean tracked checkout")
    proof = json.loads((WORK / "native-restore.json").read_bytes())
    audited = runtime.audit_native(REPO, runtime.JAR)
    full.validate_reuse(proof, receipt["sourceCommit"], receipt["workflowRunID"], audited, runtime.native)
    BUILD.mkdir(parents=True, mode=0o700)
    full.write_new(BUILD / "native-reuse.json", proof)
    original = (REPO / config.PROJECT).read_bytes()
    try:
        full.command(WORK, "device-runtime-stage", [sys.executable, HERE.parent / "legado-ios/stage-runtime.py",
            "--java-home", REPO / runtime.native.HOMES["device"], "--jar", runtime.JAR,
            "--destination", REPO / "Resources/LegadoRuntime", "--replace"], 300)
        environment = dict(os.environ, LEGADO_READER_WITH_JVM="1", YUEDU_READER_DIAGNOSTIC="1",
                           YUEDU_READER_BUILD_DIR=str(BUILD))
        try:
            full.command(WORK, "diagnostic-device-build", ["bash", HERE / "build.sh"], 3600, environment)
        except Exception:
            # This build has no account inputs or signing secrets. Expose its
            # bounded compiler/gate tail so a failure needs no artifact roundtrip.
            log = WORK / "diagnostic-device-build.log"
            if log.is_file():
                with log.open("rb") as stream:
                    stream.seek(max(0, log.stat().st_size - 32768))
                    tail = stream.read().decode("utf-8", errors="replace")
                print("\n".join(tail.splitlines()[-100:]), file=sys.stderr, flush=True)
            raise
    finally:
        full.restore_build_overlays(config, original, BUILD)
    validated = validate_build(receipt)
    full.write_new(WORK / "prepared.json", dict(receipt, completeApplicationBuilt=True,
        buildManifest=full.fact(BUILD / "output/build-manifest.json"), packageBudget=validated["packageBudget"],
        controlledSigningExecuted=False, productionPackageSignerExecuted=False))


def validate_build(receipt):
    manifest_path = full.checked(BUILD / "output/build-manifest.json")
    manifest = json.loads(manifest_path.read_bytes())
    if (manifest.get("artifactKind") != config.DIAGNOSTIC_KIND or manifest.get("sourceCommit") != receipt["sourceCommit"]
            or manifest.get("diagnosticOnly") is not True or manifest.get("releaseAcceptance") is not False
            or manifest.get("S3Acceptance") != "not_run" or manifest.get("configuration") != "Release"
            or manifest.get("platform") != "iPhoneOS" or manifest.get("architecture") != "arm64"
            or manifest.get("build") != "21" or manifest.get("signed") is not False
            or manifest.get("deviceCompilationPassed") is not True or manifest.get("jvmIntegratedIntoReading") is not True
            or manifest.get("deviceValidationPassed") is not False):
        raise ValueError("Expected this source's complete, unsigned build21 diagnostic manifest")
    settings = config.inspect_settings(json.loads((BUILD / "build-settings.json").read_bytes()), with_jvm=True, diagnostic=True)
    if settings != manifest.get("actualBuildSettings"):
        raise ValueError("Diagnostic settings changed after compilation")
    app = full.checked(BUILD / "output/Payload/YueduReader.app")
    ipa = full.checked(BUILD / "output/YueduReader-experience-unsigned.ipa")
    if full.fact(ipa) != {"bytes": manifest.get("ipaBytes"), "sha256": manifest.get("ipaSHA256")}:
        raise ValueError("Diagnostic IPA bytes differ from the build manifest")
    config.require_no_bundled_sources([REPO / "Resources", app])
    if config.bundle_summary(app, with_jvm=True) != manifest.get("bundleValidation"):
        raise ValueError("Complete diagnostic runtime/bundle material changed")
    for bundle in [app, *config.extension_bundles(app).values()]:
        info = plistlib.loads((bundle / "Info.plist").read_bytes())
        if info.get("YueduExperienceSourceCommit") != receipt["sourceCommit"] or info.get("CFBundleVersion") != "21":
            raise ValueError("Diagnostic embedded bundle source/build differs")
    proof = json.loads((BUILD / "native-reuse.json").read_bytes())
    if (proof != json.loads((WORK / "native-restore.json").read_bytes())
            or proof.get("sourceCommit") != receipt["sourceCommit"] or proof.get("workflowRunID") != receipt["workflowRunID"]
            or proof.get("nativeRuntimeRecompiled") is not False or proof.get("status") != "restored"):
        raise ValueError("Diagnostic native restoration proof changed")
    budget = config.diagnostic_package_budget(app, ipa)
    if budget != manifest.get("packageBudget"):
        raise ValueError("Diagnostic package budget changed")
    return {"manifest": manifest, "packageBudget": budget}


def export_unsigned():
    receipt = check_binding()
    authorization = package.upload_authorization()
    prepared = json.loads((WORK / "prepared.json").read_bytes())
    if (any(prepared.get(key) != value for key, value in receipt.items())
            or prepared.get("completeApplicationBuilt") is not True
            or prepared.get("controlledSigningExecuted") is not False
            or prepared.get("buildManifest") != full.fact(BUILD / "output/build-manifest.json")):
        raise ValueError("Diagnostic same-job preparation is missing or changed")
    validate_build(receipt)
    if PUBLIC.exists():
        raise ValueError("Refusing to overwrite an existing diagnostic export")
    original = full.checked(BUILD / "output")
    facts = {name: full.fact(full.checked(original / name)) for name in package.OUTPUTS}
    PUBLIC.mkdir(parents=True)
    for name in package.OUTPUTS:
        shutil.copyfile(original / name, full.checked(PUBLIC / name))
        if full.fact(PUBLIC / name) != facts[name]:
            raise ValueError("Diagnostic unsigned copy changed bytes")
    # These functions run on this private imported module, preserving the old
    # package CLI admission and gates. Only source-archive checking is reused.
    original_check = package.check_binding
    try:
        package.check_binding = check_binding
        archive = package.archive_source(PUBLIC / "source.zip", receipt, authorization)
    finally:
        package.check_binding = original_check
    facts["source.zip"] = {key: archive[key] for key in ("bytes", "sha256")}
    full.write_new(PUBLIC / "delivery-binding.json", dict(receipt,
        artifactKind="unsigned-device-renewal-diagnostic", files=facts,
        distributionPolicy=authorization, exactGitSourceSnapshot=archive,
        controlledResignedOutputExported=False, signingMaterialExported=False,
        scope="Complete device diagnostic with Release configuration, Swift -Onone/singlefile and no DEBUG. Not optimized Release/S3 acceptance, signing, installation or automatic renewal."))


@contextmanager
def enrollment_project_overlay():
    """Opt only this private Simulator adapter into the focused test group."""
    settings = native.smoke.config
    original = settings.project_overlay
    try:
        settings.project_overlay = lambda raw: original(raw, diagnostic_auth_tests=True)
        yield
    finally:
        settings.project_overlay = original


def enrollment_source_stage(*, create=False):
    """Require exact source copies, including fixtures needed to compile the suite."""
    stage = full.checked(SIMULATOR_TESTS)
    paths = (*ENROLLMENT_SOURCES, SDK_RESOURCE)
    if create:
        if stage.exists():
            raise ValueError("Enrollment source staging requires a fresh directory")
        stage.mkdir(parents=True)
    records = []
    for relative in paths:
        original = full.checked(REPO / relative)
        member = Path(relative).relative_to("Tests/iOS")
        staged = full.checked(stage / member)
        if create:
            staged.parent.mkdir(parents=True, exist_ok=True)
            with staged.open("xb") as output:
                with original.open("rb") as stream:
                    shutil.copyfileobj(stream, output)
        if full.fact(staged) != full.fact(original):
            raise ValueError("Enrollment staged source/resource differs from checkout: " + relative)
        records.append({"sourcePath": relative, "stagedPath": member.as_posix(), **full.fact(staged)})
    actual = set()
    for path in stage.rglob("*"):
        path = full.checked(path)
        if path.is_file():
            actual.add(path.relative_to(stage).as_posix())
    if actual != {row["stagedPath"] for row in records}:
        raise ValueError("Unexpected file in focused enrollment test source group")
    return {"root": config.DIAGNOSTIC_AUTH_TEST_ROOT, "files": records,
        "swiftSourceCount": len(ENROLLMENT_SOURCES), "completeAppAndExtensionsUnchanged": True}


def prepare_simulator():
    receipt = check_binding()
    target = full.checked(REPO / SDK_RESOURCE)
    if SIMULATOR.exists() or SIMULATOR_TESTS.exists() or PRODUCED.exists() or target.exists():
        raise ValueError("Enrollment regression requires fresh owned Simulator and fixture outputs")
    LOGS.mkdir(parents=True, exist_ok=True)
    full.command(LOGS, "renewal-diagnostic-sdk-producer", [sys.executable,
        HERE / "owned-package-fixture/generate-sdk-owned-package.py", "--output", PRODUCED], 600)
    probe = full.load("diagnostic_owned_fixture_validation", HERE / "renewal-probe-tools.py")
    verified = probe._verify_sdk_public(PRODUCED, receipt["diagnosticInputs"])
    raw, resource_fact = probe._bounded_fact(PRODUCED / "owned-sdk-package.json", 8_388_608)
    with target.open("xb") as stream:
        stream.write(raw)
    target.chmod(0o444)
    staged = enrollment_source_stage(create=True)
    # Verify the original native closure before applying the additional audited
    # diagnostic test-group overlay. Its project file is itself a bound input.
    native_inputs = native.source_inputs()
    original = native.validate_tag
    original_inputs = native.source_inputs
    try:
        native.validate_tag = source
        native.source_inputs = lambda: native_inputs
        with enrollment_project_overlay():
            native.prepare(SIMULATOR)
    finally:
        native.validate_tag = original
        native.source_inputs = original_inputs
    full.write_new(WORK / "enrollment-prepared.json", dict(receipt,
        requiredCase=ENROLLMENT_CASE, fixture=resource_fact, producerManifest=verified["manifest"],
        testSourceStage=staged,
        regressionScope="Independent one-case owned-fixture Simulator regression after unsigned IPA export"))


def verify_enrollment(summary, tree):
    counts = native.smoke.verify_summary(summary, 1, 1)
    if not isinstance(tree, dict) or not isinstance(tree.get("testNodes"), list):
        raise ValueError("Enrollment regression requires an actual xcresult tests tree")
    cases = []
    def visit(node, depth=0):
        if depth > 64 or not isinstance(node, dict) or not isinstance(node.get("children", []), list):
            raise ValueError("Invalid enrollment regression test node")
        if node.get("nodeType") == "Test Case":
            identifier = "/".join(node.get("nodeIdentifier", "").removesuffix("()").split("/")[-2:])
            if identifier != ENROLLMENT_CASE or node.get("result") != "Passed":
                raise ValueError("Unexpected or failing enrollment regression case")
            cases.append(identifier)
        for child in node.get("children", []):
            visit(child, depth + 1)
    for node in tree["testNodes"]:
        visit(node)
    if cases != [ENROLLMENT_CASE]:
        raise ValueError("Enrollment regression must execute its exact case once")
    return {"summary": counts, "cases": cases}


def run_enrollment():
    receipt = check_binding()
    prepared = json.loads((WORK / "enrollment-prepared.json").read_bytes())
    if (any(prepared.get(key) != value for key, value in receipt.items())
            or prepared.get("requiredCase") != ENROLLMENT_CASE
            or prepared.get("testSourceStage") != enrollment_source_stage()
            or prepared.get("fixture") != full.fact(full.checked(REPO / SDK_RESOURCE))
            or prepared.get("producerManifest") != full.fact(PRODUCED / "sdk-produced-fixture-manifest.json")):
        raise ValueError("Enrollment fixture preparation changed")
    with enrollment_project_overlay():
        native.smoke.review_overlays(json.loads((SIMULATOR / "overlays.json").read_bytes()))
    result_bundle = REPO / ".build/renewal-diagnostic-enrollment.xcresult"
    failure = None
    observed = None
    try:
        try:
            full.command(LOGS, "renewal-diagnostic-enrollment-test", ["bash", REPO / "scripts/xctest.sh",
                "-l", LOGS / "renewal-diagnostic-enrollment-build.log", "-t", "1800", "--",
                "-configuration", "Debug", "-onlyUsePackageVersionsFromResolvedFile",
                "CODE_SIGNING_ALLOWED=YES", "CODE_SIGNING_REQUIRED=YES", "CODE_SIGN_IDENTITY=-",
                "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=", "CODE_SIGN_ENTITLEMENTS=",
                "GATEWAY_BASE_URL=", "YUEDU_LOCAL_EXPERIENCE=YES", "IPHONEOS_DEPLOYMENT_TARGET=18.0",
                "ENABLE_DEBUG_DYLIB=NO", "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG LEGADO_REQUIRE_NATIVE_MAINJS",
                "-resultBundlePath", result_bundle, "-only-testing:yuedu appTests/" + ENROLLMENT_CASE + "()"], 1860)
        except Exception as error:
            failure = error
        for kind in ("summary", "tests"):
            full.command(LOGS, "renewal-diagnostic-enrollment-" + kind, ["xcrun", "xcresulttool", "get",
                "test-results", kind, "--path", result_bundle], 60)
        def read(kind):
            path = full.checked(LOGS / ("renewal-diagnostic-enrollment-" + kind + ".log"))
            if path.stat().st_size > 4_194_304:
                raise ValueError("Enrollment xcresult export exceeds its fixed budget")
            return json.loads(path.read_bytes())
        observed = verify_enrollment(read("summary"), read("tests"))
        if failure is not None:
            raise failure
    except Exception:
        full.write_new(LOGS / "renewal-diagnostic-enrollment-result.json", dict(receipt,
            status="failed", requiredCase=ENROLLMENT_CASE, actualDeviceRenewalValidated=False,
            regressionScope="Independent one-case Simulator regression; never S3 or actual renewal acceptance"))
        raise
    full.write_new(LOGS / "renewal-diagnostic-enrollment-result.json", dict(receipt,
        status="passed", requiredCase=ENROLLMENT_CASE, **observed, actualDeviceRenewalValidated=False,
        regressionScope="Independent one-case Simulator regression; never S3 or actual renewal acceptance"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("validate-tag", "restore", "prepare-device", "export-unsigned", "prepare-simulator", "run-enrollment"))
    phase = parser.parse_args().phase
    if phase == "validate-tag":
        print(json.dumps({"sourceCommit": source(), "diagnosticOnly": True, "releaseAcceptance": False, "S3Acceptance": "not_run"}))
    elif phase == "restore":
        restore()
    elif phase == "prepare-device":
        prepare()
    elif phase == "prepare-simulator":
        prepare_simulator()
    elif phase == "run-enrollment":
        run_enrollment()
    else:
        export_unsigned()


if __name__ == "__main__":
    main()
