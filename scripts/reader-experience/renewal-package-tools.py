#!/usr/bin/env python3
"""Isolated package-only orchestration; original full Native/SDK gates stay separate."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import sys

import importlib.util

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
spec = importlib.util.spec_from_file_location("renewal_package_full", HERE / "full-application-signing-tools.py")
full = importlib.util.module_from_spec(spec)
spec.loader.exec_module(full)
native = full.load("renewal_package_native", HERE / "native-smoke-tools.py")
WORK = REPO / ".build/renewal-package"
PUBLIC = REPO / ".build/renewal-package-public"
NATIVE_WORK = REPO / ".build/native-reader-test"
INPUTS = (".github/workflows/yuedu-renewal-package.yml", "scripts/reader-experience/renewal-package-tools.py",
          "scripts/reader-experience/full-application-signing-tools.py", "scripts/reader-experience/native-smoke-tools.py")
OUTPUTS = ("YueduReader-experience-unsigned.ipa", "build-manifest.json", "README.txt")


def source():
    value = native.smoke.source_sha()
    tag = "yuedu-renewal-package-" + value[:7]
    if (sys.platform != "darwin" or not re.fullmatch("[0-9a-f]{40}", value)
            or os.environ.get("GITHUB_SHA") != value or not os.environ.get("GITHUB_RUN_ID", "").isdigit()
            or os.environ.get("GITHUB_REF_NAME") != tag or os.environ.get("GITHUB_REF") != "refs/tags/" + tag):
        raise ValueError("Expected exact source-bound macOS yuedu-renewal-package tag job")
    return value


def scope_inputs():
    return [{"path": path, **full.fact(full.checked(REPO / path))} for path in INPUTS]


def binding():
    value = source()
    return {"schemaVersion": 1, "sourceCommit": value, "workflowRunID": os.environ["GITHUB_RUN_ID"],
        "sourceTag": os.environ["GITHUB_REF_NAME"], "workflowRunAttempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
        "isolatedPackageInputs": scope_inputs(), "fullNativeAcceptance": False, "fullSDKAcceptance": False,
        "deviceValidationPassed": False, "completeAutomaticRenewalVerified": False}


def restore():
    receipt = binding()
    original = native.packaging.validate_tag
    try:
        native.packaging.validate_tag = source
        proof = native.packaging.restore()
    finally:
        native.packaging.validate_tag = original
    proof["admission"] = "renewal-package"
    native.smoke.config.write_new_json(NATIVE_WORK / "native-restore.json", proof)
    full.write_new(WORK / "scope-binding.json", receipt)


def check_binding():
    receipt = json.loads((WORK / "scope-binding.json").read_bytes())
    if receipt != binding():
        raise ValueError("Isolated package source/run/workflow inputs changed")
    return receipt


def export_unsigned():
    if os.environ.get("YUEDU_PACKAGE_REPOSITORY_PRIVATE") != "true":
        raise ValueError("Unsigned package export is restricted to a private repository")
    receipt = check_binding()
    prepared = json.loads((REPO / full.WORK / "prepared.json").read_bytes())
    if (prepared.get("sourceCommit") != receipt["sourceCommit"]
            or prepared.get("workflowRunID") != receipt["workflowRunID"]
            or prepared.get("completeApplicationBuilt") is not True):
        raise ValueError("Same-job complete device preparation is required before export")
    # Reuse the original producer's full input validator: exact source stamp,
    # ordinary JAR/resources, manifest, unsigned IPA hash and native proof.
    base = full.load("renewal_package_owned_base", HERE / "owned-package-fixture/generate-sdk-owned-package.py")
    package = full.load("renewal_package_owned_full", HERE / "owned-package-fixture/full-application-package.py")
    build = full.checked(REPO / full.PRIVATE / "device-build")
    package.validate_input(base, build)
    original = full.checked(build / "output")
    if PUBLIC.exists():
        raise ValueError("Refusing to overwrite an earlier exported package")
    facts = {name: full.fact(full.checked(original / name)) for name in OUTPUTS}
    PUBLIC.mkdir(parents=True)
    for name in OUTPUTS:
        shutil.copyfile(original / name, full.checked(PUBLIC / name))
        if full.fact(PUBLIC / name) != facts[name]:
            raise ValueError("Unsigned package copy changed bytes")
    full.write_new(PUBLIC / "delivery-binding.json", dict(receipt,
        artifactKind="unsigned-device-compilation-before-S3", files=facts,
        S3Acceptance="pending-separate-result", controlledResignedOutputExported=False,
        signingMaterialExported=False,
        scope="Fresh Release iPhoneOS unsigned input build. Sign with the original installation tool before installing. This is not a re-signed/renewed output and does not establish S3 success, installation or automatic renewal."))


def prepare_simulator():
    check_binding()
    # Imported private instances only, as in the original Native preparation.
    # The old command-line full/cold validators and gates are never modified.
    original = native.validate_tag
    try:
        native.validate_tag = source
        return native.prepare(NATIVE_WORK)
    finally:
        native.validate_tag = original


def full_phase(phase):
    check_binding()
    original = full.admission
    try:
        full.admission = source
        if phase == "prepare-device":
            full.prepare(NATIVE_WORK / "native-restore.json")
        else:
            full.run()
    finally:
        full.admission = original


def collect():
    receipt = check_binding()
    evidence = REPO / full.WORK
    result_path = evidence / "result.json"
    status = "unknown"
    if result_path.exists():
        result = json.loads(result_path.read_bytes())
        if result.get("sourceCommit") == receipt["sourceCommit"] and result.get("status") in ("passed", "failed"):
            if result["status"] == "passed" and result.get("workflowRunID") != receipt["workflowRunID"]:
                raise ValueError("S3 result belongs to another job")
            status = result["status"]
    full.write_new(WORK / "package-only-result.json", dict(receipt, S3Status=status,
        scope="Only the original one-case controlled full-package signing/independent verification; no full Native/SDK, actual Apple account, physical installation or automatic-renewal acceptance."))
    full.write_new(WORK / "early-public-summary.json", full.early_summary(evidence, receipt["sourceCommit"], receipt["workflowRunID"]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("validate-tag", "restore", "prepare-device", "export-unsigned", "prepare-simulator", "run", "collect"))
    args = parser.parse_args()
    if args.phase == "validate-tag":
        print(json.dumps({"sourceCommit": source(), "scope": "renewal-package-only"}))
    elif args.phase == "restore":
        restore()
    elif args.phase == "export-unsigned":
        export_unsigned()
    elif args.phase == "prepare-simulator":
        prepare_simulator()
    elif args.phase in ("prepare-device", "run"):
        full_phase(args.phase)
    else:
        collect()


if __name__ == "__main__":
    main()
