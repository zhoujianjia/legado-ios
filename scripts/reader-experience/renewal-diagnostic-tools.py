#!/usr/bin/env python3
"""Complete, unoptimized device diagnostics; never Release or S3 acceptance."""
import argparse
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
INPUTS = (".github/workflows/yuedu-renewal-diagnostic.yml", "scripts/reader-experience/renewal-diagnostic-tools.py",
          "scripts/reader-experience/build.sh", "scripts/reader-experience/stage-config.py", *package.INPUTS)


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
        full.command(WORK, "diagnostic-device-build", ["bash", HERE / "build.sh"], 3600, environment)
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
            or manifest.get("build") != "18" or manifest.get("signed") is not False
            or manifest.get("deviceCompilationPassed") is not True or manifest.get("jvmIntegratedIntoReading") is not True
            or manifest.get("deviceValidationPassed") is not False):
        raise ValueError("Expected this source's complete, unsigned build18 diagnostic manifest")
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
        if info.get("YueduExperienceSourceCommit") != receipt["sourceCommit"] or info.get("CFBundleVersion") != "18":
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("validate-tag", "restore", "prepare-device", "export-unsigned"))
    phase = parser.parse_args().phase
    if phase == "validate-tag":
        print(json.dumps({"sourceCommit": source(), "diagnosticOnly": True, "releaseAcceptance": False, "S3Acceptance": "not_run"}))
    elif phase == "restore":
        restore()
    elif phase == "prepare-device":
        prepare()
    else:
        export_unsigned()


if __name__ == "__main__":
    main()
