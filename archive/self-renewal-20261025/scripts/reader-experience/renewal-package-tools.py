#!/usr/bin/env python3
"""Isolated package-only orchestration; original full Native/SDK gates stay separate."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import zipfile

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
          "scripts/reader-experience/full-application-signing-tools.py", "scripts/reader-experience/native-smoke-tools.py",
          "docs/legado-ios/distribution-policy.json")
OUTPUTS = ("YueduReader-experience-unsigned.ipa", "build-manifest.json", "README.txt")
POLICY = "docs/legado-ios/distribution-policy.json"
PUBLIC_SCOPE = "Temporary main-reader diagnostic downloads during the current development work; clean up when validation is complete."


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


def upload_authorization():
    repository_private = os.environ.get("YUEDU_PACKAGE_REPOSITORY_PRIVATE")
    if repository_private not in ("true", "false"):
        raise ValueError("The actual repository visibility is required")
    policy_path = full.checked(REPO / POLICY)
    with policy_path.open("rb") as stream:
        raw = stream.read(65_537)
    if len(raw) > 65_536:
        raise ValueError("Distribution policy exceeds its bounded size")
    policy = json.loads(raw)
    authorization = policy.get("temporaryPublicUploadAuthorization", {})
    if (type(policy.get("schemaVersion")) is not int or policy["schemaVersion"] != 1
            or policy.get("privateSourcePackIncludedInSharedBuilds") is not False
            or policy.get("automaticLocalSourceInsertionEnabled") is not False
            or not isinstance(authorization, dict) or authorization.get("scope") != PUBLIC_SCOPE
            or type(authorization.get("artifactRetentionDays")) is not int
            or authorization["artifactRetentionDays"] != 1
            or authorization.get("exactGitSourceSnapshotIncluded") is not True
            or authorization.get("privateBookSourceUploadAuthorized") is not False
            or authorization.get("licenseClearanceEstablished") is not False):
        raise ValueError("Missing the bounded main-reader diagnostic upload policy")
    if repository_private == "false" and (policy.get("publicRepositoryIPAUploadsEnabled") is not True
            or policy.get("currentBinarySharingRequested") is not True):
        raise ValueError("Public diagnostic upload is not currently authorized")
    return {"path": POLICY, **full.fact(policy_path), "repositoryPrivate": repository_private == "true",
        "scope": PUBLIC_SCOPE, "artifactRetentionDays": 1, "exactGitSourceSnapshotIncluded": True,
        "privateBookSourceUploadAuthorized": False, "licenseClearanceEstablished": False,
        "publicBinaryDistributionCleared": policy.get("publicBinaryDistributionCleared") is True}


def verify_source_archive(path, source_commit, authorization):
    path = full.checked(path)
    if not path.is_file() or not 0 < path.stat().st_size <= 536_870_912:
        raise ValueError("Missing or oversized exact Git source snapshot")
    with zipfile.ZipFile(path) as archive:
        if archive.comment != source_commit.encode("ascii"):
            raise ValueError("Source snapshot does not identify this exact Git commit")
        names = archive.namelist()
        if len(names) != len(set(names)) or any(
                name.startswith(("/", ".build/", ".git/")) or "\\" in name
                or ".." in Path(name).parts
                or Path(name).name in ("BuiltInBookSources.json", "BuiltInBookSources.manifest.json")
                for name in names):
            raise ValueError("Source snapshot contains an unowned or private source-pack path")
        try:
            if archive.getinfo(POLICY).file_size != authorization["bytes"]:
                raise ValueError("Source snapshot policy has unexpected bytes")
            policy_bytes = archive.read(POLICY)
        except KeyError as error:
            raise ValueError("Source snapshot is missing its distribution policy") from error
        if (len(policy_bytes) != authorization["bytes"]
                or hashlib.sha256(policy_bytes).hexdigest() != authorization["sha256"]):
            raise ValueError("Source snapshot distribution policy differs from this upload")
    return {"file": "source.zip", **full.fact(path), "format": "git-archive-HEAD",
        "sourceCommit": source_commit, "distributionPolicySHA256": authorization["sha256"]}


def archive_source(path, receipt, authorization):
    path = full.checked(path)
    if path.exists():
        raise ValueError("Refusing to overwrite a source snapshot")
    subprocess.run(["git", "-C", str(REPO), "archive", "--format=zip", "--output", str(path), "HEAD"],
        check=True, timeout=60, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    check_binding()
    return verify_source_archive(path, receipt["sourceCommit"], authorization)


def export_unsigned():
    authorization = upload_authorization()
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
    source_archive = archive_source(PUBLIC / "source.zip", receipt, authorization)
    facts["source.zip"] = {key: source_archive[key] for key in ("bytes", "sha256")}
    full.write_new(PUBLIC / "delivery-binding.json", dict(receipt,
        artifactKind="unsigned-device-compilation-before-S3", files=facts,
        distributionPolicy=authorization, exactGitSourceSnapshot=source_archive,
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
