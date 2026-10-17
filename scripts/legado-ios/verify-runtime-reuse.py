#!/usr/bin/env python3
"""Reuse a same-repository Zero build only when its build inputs are identical.

The prepare phase waits for immutable Actions artifacts and checks Git objects.
The restore phase validates downloaded files in isolation before copying only
the framework, Java homes and payload. Current app code must still be compiled.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
NATIVE_INPUTS = (
    "scripts/legado-ios/build-zero.sh",
    "scripts/legado-ios/prepare-zero-wx.py",
    "scripts/legado-ios/prepare-symbol-keeper.py",
    "scripts/legado-ios/fetch-sources.py",
    "scripts/legado-ios/runtime-lock.json",
)
JVM_TREE = "Packages/LegadoRuntime/jvm"
ARTIFACT_NAMES = ("legado-jvm-payload", "legado-zero-source-build")
SHA_PATTERN = re.compile(r"[0-9a-f]{40}")


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def git(*arguments):
    result = subprocess.run(["git", *arguments], cwd=REPO, capture_output=True,
                            text=True, encoding="utf-8", errors="replace", timeout=180)
    if result.returncode:
        # Do not print transport diagnostics that could contain an authenticated
        # remote URL. The hosted checkout uses an anonymous public origin.
        raise RuntimeError(f"git {arguments[0]} failed with exit status {result.returncode}")
    return result.stdout.strip()


def valid_sha(value):
    if not isinstance(value, str) or SHA_PATTERN.fullmatch(value) is None:
        raise ValueError("Expected an exact 40-character Git SHA")
    return value


class GitHub:
    def __init__(self, repository, token):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
            raise ValueError("GITHUB_REPOSITORY must identify the current owner/repository")
        if not token:
            raise ValueError("GITHUB_TOKEN with read-only Actions access is required")
        self.repository = repository
        self.token = token

    def get(self, suffix):
        request = urllib.request.Request(
            "https://api.github.com/repos/" + self.repository + suffix,
            headers={"Accept": "application/vnd.github+json", "Authorization": "Bearer " + self.token,
                     "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "legado-runtime-reuse"})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"GitHub Actions API returned HTTP {error.code} for {suffix}") from None

    def run(self, run_id):
        result = self.get(f"/actions/runs/{run_id}")
        if result.get("repository", {}).get("full_name", "").lower() != self.repository.lower():
            raise ValueError("Source workflow run does not belong to the current repository")
        if str(result.get("id")) != str(run_id):
            raise ValueError("GitHub returned a different source workflow run")
        valid_sha(result.get("head_sha"))
        return result

    def artifacts(self, run_id):
        artifacts = []
        for page in range(1, 101):
            value = self.get(f"/actions/runs/{run_id}/artifacts?per_page=100&page={page}")
            batch = value["artifacts"]
            artifacts.extend(batch)
            if len(batch) < 100:
                return artifacts
        raise ValueError("Source run has an unexpectedly large artifact inventory")


def compare_inputs(source_sha, current_sha):
    valid_sha(source_sha)
    valid_sha(current_sha)
    if git("status", "--porcelain", "--untracked-files=no", "--", *NATIVE_INPUTS, JVM_TREE):
        raise ValueError("Native/JVM build inputs have uncommitted changes")
    checks = []
    for path in (*NATIVE_INPUTS, JVM_TREE):
        source = git("rev-parse", f"{source_sha}:{path}")
        current = git("rev-parse", f"{current_sha}:{path}")
        checks.append({"path": path, "objectType": "tree" if path == JVM_TREE else "blob",
                       "sourceObject": source, "currentObject": current, "matches": source == current})
    return checks


def wait_for_artifacts(api, run_id, source_sha, timeout_seconds):
    deadline = time.monotonic() + timeout_seconds
    while True:
        inventory = api.artifacts(run_id)
        found = {}
        for name in ARTIFACT_NAMES:
            candidates = [item for item in inventory if item.get("name") == name and not item.get("expired", True)]
            if len(candidates) > 1:
                raise ValueError("Source run has duplicate non-expired artifacts named " + name)
            if candidates:
                artifact = candidates[0]
                if not isinstance(artifact.get("id"), int) or artifact["id"] <= 0 or artifact.get("size_in_bytes", 0) <= 0:
                    raise ValueError("Source artifact has invalid metadata: " + name)
                declared_sha = artifact.get("workflow_run", {}).get("head_sha")
                if declared_sha is not None and declared_sha != source_sha:
                    raise ValueError("Source artifact belongs to a different Git SHA")
                found[name] = {key: artifact.get(key) for key in ("id", "name", "size_in_bytes", "digest", "expires_at")}
        if len(found) == len(ARTIFACT_NAMES):
            return found
        state = api.run(run_id)
        if state["head_sha"] != source_sha:
            raise ValueError("Source workflow run changed its Git SHA")
        missing = [name for name in ARTIFACT_NAMES if name not in found]
        if state.get("status") == "completed":
            raise RuntimeError("Source workflow completed without reusable artifacts: " + ", ".join(missing))
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Timed out waiting for source artifacts: " + ", ".join(missing))
        print(json.dumps({"waitingForArtifacts": missing, "sourceRunID": run_id,
                          "remainingSeconds": round(remaining)}), flush=True)
        # The source job owns this external state; no delay substitutes for an
        # app synchronization event. Poll until the artifacts actually exist.
        time.sleep(min(15, remaining))


def source_run_from_tag(tag, current_sha):
    match = re.fullmatch(r"legado-replay-([1-9][0-9]*)-([0-9a-f]{7,40})", tag)
    if match is None or not current_sha.startswith(match.group(2)):
        raise ValueError("Expected legado-replay-<sourceRunID>-<currentSHA prefix> tag")
    return int(match.group(1))


def prepare(record, timeout_seconds):
    current_sha = valid_sha(git("rev-parse", "HEAD"))
    run_id = source_run_from_tag(os.environ.get("GITHUB_REF_NAME", ""), current_sha)
    api = GitHub(os.environ.get("GITHUB_REPOSITORY", ""), os.environ.get("GITHUB_TOKEN", ""))
    state = api.run(run_id)
    source_sha = valid_sha(state["head_sha"])
    record.update({"repository": api.repository, "sourceRunID": run_id, "sourceSHA": source_sha,
                   "currentSHA": current_sha, "sourceRunURL": state.get("html_url")})
    git("fetch", "--depth=1", "origin", source_sha)
    checks = compare_inputs(source_sha, current_sha)
    record["inputChecks"] = checks
    if not all(check["matches"] for check in checks):
        raise ValueError("Source runtime build inputs differ; a fresh source build is required")
    record["artifacts"] = wait_for_artifacts(api, run_id, source_sha, timeout_seconds)
    record["status"] = "prepared"
    outputs = os.environ.get("GITHUB_OUTPUT")
    if outputs:
        with Path(outputs).open("a", encoding="utf-8") as stream:
            stream.write(f"source_run_id={run_id}\nsource_sha={source_sha}\n")
            stream.write(f"jvm_artifact_id={record['artifacts']['legado-jvm-payload']['id']}\n")
            stream.write(f"native_artifact_id={record['artifacts']['legado-zero-source-build']['id']}\n")


def safe_path(path):
    path = path.absolute()
    if path == REPO or not path.is_relative_to(REPO):
        raise ValueError("Reuse path must be a child of the current repository")
    candidate = REPO
    for part in path.relative_to(REPO).parts:
        candidate = candidate / part
        if candidate.is_symlink() or getattr(candidate, "is_junction", lambda: False)():
            raise ValueError("Refusing a symlinked runtime reuse path")
        resolved = candidate.resolve()
        if resolved == REPO or not resolved.is_relative_to(REPO):
            raise ValueError("Runtime reuse path escapes the current repository")
    return path


def safe_tree(root):
    pending = [safe_path(root)]
    while pending:
        path = safe_path(pending.pop())
        if path.is_dir():
            pending.extend(path.iterdir())
        elif not path.is_file():
            raise ValueError("Runtime artifact contains a non-regular entry")


def restore(record):
    if record.get("status") != "prepared" or git("rev-parse", "HEAD") != record.get("currentSHA"):
        raise ValueError("A successful reuse preparation for the current checkout is required")
    checks = compare_inputs(record["sourceSHA"], record["currentSHA"])
    if checks != record.get("inputChecks") or not all(check["matches"] for check in checks):
        raise ValueError("Runtime inputs changed after reuse preparation")
    downloads = safe_path(REPO / ".build/reused-runtime")
    native = safe_path(downloads / "native")
    artifact_lock = safe_path(native / "scripts/legado-ios/runtime-lock.json")
    current_lock = safe_path(REPO / "scripts/legado-ios/runtime-lock.json")
    if artifact_lock.read_bytes() != current_lock.read_bytes():
        raise ValueError("Downloaded native artifact runtime-lock.json differs from the checkout")
    framework = safe_path(native / "Packages/LegadoRuntime/Artifacts/OpenJDK.xcframework")
    jar = safe_path(downloads / "jvm/legado-runtime.jar")
    homes = {platform: safe_path(native / f".build/legado-ios/{platform}-static/java-home")
             for platform in ("device", "simulator")}
    for path in (framework, jar, *homes.values()):
        safe_tree(path)
    spec = importlib.util.spec_from_file_location("verify_reused_runtime", HERE / "verify-runtime.py")
    verifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verifier)
    validation = {platform: verifier.validate(home, jar, framework) for platform, home in homes.items()}
    copies = [(framework, REPO / "Packages/LegadoRuntime/Artifacts/OpenJDK.xcframework"),
              (jar, REPO / "Packages/LegadoRuntime/jvm/build/libs/legado-runtime.jar")]
    copies.extend((home, REPO / f".build/legado-ios/{platform}-static/java-home") for platform, home in homes.items())
    for _, destination in copies:
        if safe_path(destination).exists():
            raise ValueError("Refusing to overwrite an existing runtime product: " + str(destination.relative_to(REPO)))
    for source, destination in copies:
        safe_path(destination).parent.mkdir(parents=True, exist_ok=True)
        if source.is_dir():
            shutil.copytree(source, safe_path(destination))
        else:
            shutil.copy2(source, safe_path(destination))
    with jar.open("rb") as stream:
        jar_hash = hashlib.file_digest(stream, "sha256").hexdigest()
    record.update({"status": "restored", "restoredAt": utc_now(), "validation": validation,
                   "jarSHA256": jar_hash, "nativeRuntimeRecompiled": False, "jvmPayloadRecompiled": False,
                   "currentAppCompilationRequired": True})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("prepare", "restore"))
    parser.add_argument("--timeout-seconds", type=float, default=1800)
    args = parser.parse_args()
    if not 0 < args.timeout_seconds <= 1800:
        parser.error("--timeout-seconds must be greater than zero and at most 1800")
    report = REPO / ".build/ci-logs/runtime-reuse.json"
    report.parent.mkdir(parents=True, exist_ok=True)
    record = {"schemaVersion": 1, "startedAt": utc_now(), "status": "failed", "deviceValidationPassed": False}
    try:
        if args.phase == "prepare":
            prepare(record, args.timeout_seconds)
        else:
            record = json.loads(report.read_text(encoding="utf-8-sig"))
            restore(record)
    except (Exception, KeyboardInterrupt) as error:
        record.update({"status": "failed", "failure": f"{type(error).__name__}: {error}"})
        print(record["failure"], file=sys.stderr, flush=True)
    finally:
        record["recordedAt"] = utc_now()
        report.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(record, indent=2), flush=True)
    return 0 if record["status"] in {"prepared", "restored"} else 1


if __name__ == "__main__":
    sys.exit(main())
