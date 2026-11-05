#!/usr/bin/env python3
"""One explicit packaging retry using the pinned, already passed reader tests.

This does not manufacture tests for the new commit. Original source stamps stay
untouched, and every source/build input outside the narrow audit repair is equal.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
RUN_ID = 42028850565
ATTEMPT = 1
BASE_SHA = "429390a60d510e04d170927c100af89b088123f0"
REPOSITORY = "zhoujianjia/legado-ios"
WORKFLOW = ".github/workflows/legado-reader.yml"
MARKER = "[reuse-reader-tests:42028850565]"
ARTIFACTS = {
    "position": {"id": 13418485405, "name": "reader-position-regression", "bytes": 1441778,
                 "digest": "sha256:a56321e3d903c890a2fc8132ce9403af169f369fe85f75e32b2e9ec0b6a5061d"},
    "build": {"id": 13425307473, "name": "legado-native-reader-build-evidence", "bytes": 3933064,
              "digest": "sha256:74a2a81b1d6b2c9a359296980eeb617214fbad257a948c843216ae1e90db4189"},
}
ALLOWED_CHANGES = {
    WORKFLOW, "scripts/reader-experience/clean-package-audit.py",
    "scripts/reader-experience/test-clean-package-audit.py",
    "scripts/reader-experience/reader-test-reuse.py",
    "scripts/reader-experience/test-reader-test-reuse.py",
}


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


position = load("reuse_position_gate", HERE / "position-regression.py")
native = position.native
replay = load("reuse_github_helpers", HERE.parent / "legado-ios/verify-runtime-reuse.py")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def git(*args, binary=False):
    result = subprocess.run(["git", *args], cwd=REPO, check=True, capture_output=True)
    return result.stdout if binary else result.stdout.decode("utf-8").strip()


def read(path):
    return json.loads(Path(path).read_bytes())


def write(path, value):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def output(key, value):
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
            stream.write(f"{key}={value}\n")


def detect_reuse(message):
    markers = re.findall(r"\[reuse-reader-tests:[^\]]*\]", message)
    require("[reuse-reader-tests:" not in message or markers == [MARKER], "Unknown/ambiguous reader evidence reuse marker")
    return markers == [MARKER]


def validate_changes(paths):
    require(bool(paths) and len(paths) == len(set(paths)), "Expected unique audit-repair changes")
    require(set(paths) <= ALLOWED_CHANGES, "Tested source/build inputs changed: " + str(sorted(set(paths) - ALLOWED_CHANGES)))
    require("scripts/reader-experience/clean-package-audit.py" in paths, "Reuse is limited to the package-audit repair")


def validate_run(run):
    expected = {"id": RUN_ID, "run_attempt": ATTEMPT, "head_sha": BASE_SHA,
                "path": WORKFLOW, "status": "completed", "conclusion": "failure"}
    require(all(run.get(k) == v for k, v in expected.items())
            and run.get("repository", {}).get("full_name") == REPOSITORY,
            "Source run/attempt/SHA/workflow differs from the pinned packaging failure")


def validate_jobs(jobs):
    require(isinstance(jobs, list), "Missing source jobs")
    for name, job_id, conclusion, steps in (
        ("position-regression", 127249813487, "success", {
            "Require the source-only reader position regressions before packaging": "success",
            "Preserve selected source, raw results and failure logs": "success"}),
        ("reader", 127268089982, "failure", {
            "Require the jimage-backed JNI product routes in three fresh Simulator hosts": "success",
            "Execute the three source-only Swift module-image diagnostics": "success",
            "Compile and package the actual main application with the local JVM": "failure",
            "Preserve compilation, source and ordinary-payload evidence": "success"}),
    ):
        selected = [job for job in jobs if job.get("name") == name]
        require(len(selected) == 1, "Missing/duplicate source job: " + name)
        job = selected[0]
        require(job.get("id") == job_id and job.get("run_id") == RUN_ID
                and job.get("status") == "completed" and job.get("conclusion") == conclusion,
                "Unexpected source job status: " + name)
        for step_name, result in steps.items():
            matches = [step for step in job.get("steps", []) if step.get("name") == step_name]
            require(len(matches) == 1 and matches[0].get("status") == "completed"
                    and matches[0].get("conclusion") == result, "Source step did not reach its required verdict: " + step_name)


def validate_artifacts(artifacts):
    require(isinstance(artifacts, list) and len(artifacts) == 2, "Expected exactly the two pinned source artifacts")
    for pinned in ARTIFACTS.values():
        matches = [item for item in artifacts if item.get("name") == pinned["name"]]
        require(len(matches) == 1, "Missing/duplicate source artifact")
        item = matches[0]
        require(item.get("id") == pinned["id"] and item.get("size_in_bytes") == pinned["bytes"]
                and item.get("digest") == pinned["digest"] and item.get("expired") is False
                and item.get("workflow_run", {}).get("id") == RUN_ID
                and item.get("workflow_run", {}).get("head_sha") == BASE_SHA,
                "Source artifact identity/digest/expiry differs from the fixed evidence")


def check_hashes(root, mapping):
    root = Path(root).resolve()
    require(isinstance(mapping, dict) and mapping, "Missing evidence hash inventory")
    for name, expected in mapping.items():
        require(isinstance(name, str) and isinstance(expected, str) and re.fullmatch(r"[0-9a-f]{64}", expected), "Invalid evidence hash")
        target = (root / name).resolve()
        require(target.is_relative_to(root) and target.is_file() and not target.is_symlink(), "Unsafe/missing evidence file")
        require(hashlib.sha256(target.read_bytes()).hexdigest() == expected, "Evidence bytes changed: " + name)


def verify_position(folder, blob_reader):
    folder = Path(folder)
    selected, result = read(folder / "selection.json"), read(folder / "result.json")
    require(selected.get("sourceCommit") == BASE_SHA and result.get("sourceCommit") == BASE_SHA
            and result.get("passed") is True and result.get("sourceOnly") is True, "Position result has a different source or failed")
    current = position.inventory()
    require(selected.get("expectedExecutionsByMethod") == current["expectedExecutionsByMethod"], "Position method selection changed")
    records = selected.get("sourceInputs")
    require(isinstance(records, list) and {item["path"] for item in records} == {item["path"] for item in current["sourceInputs"]}
            and len(records) == len(current["sourceInputs"]), "Position source inventory changed")
    for item in records:
        data = blob_reader(item["path"])
        require(item.get("bytes") == len(data) and item.get("sha256") == hashlib.sha256(data).hexdigest(), "Selected source does not match the tested Git blob")
        copy = folder / "sources" / item["path"]
        require(copy.is_file() and copy.read_bytes() == data, "Archived selected source differs from Git")
    expected_files = {"selection.json", "overlays.json", "tests.log", "summary.json", "tests.json", "build-settings.json"}
    require(set(result.get("artifactSHA256", {})) == expected_files, "Incomplete position raw evidence")
    check_hashes(folder, result["artifactSHA256"])
    require((folder / "test-exit-status.txt").read_text().strip() == "0", "Position wrapper failed")
    native.verify_test_verdict((folder / "tests.log").read_text(encoding="utf-8"))
    counts = native.smoke.verify_summary(read(folder / "summary.json"), 86, 89)
    cases = position.verify_tree(read(folder / "tests.json"), selected["expectedExecutionsByMethod"])
    require(all(result.get(key) == value for key, value in (counts | cases).items()), "Position result disagrees with the raw executions")
    overlays = read(folder / "overlays.json")
    require(overlays.get("sourceCommit") == BASE_SHA, "Position overlays have a different tested source")
    for key in ("projectOverlay", "infoOverlay"):
        record = overlays[key]
        require(record["originalSHA256"] == hashlib.sha256(blob_reader(record["path"])).hexdigest(), "Archived overlay original differs from its tested Git blob")
    require(overlays["infoOverlay"].get("sourceCommitStamped") == BASE_SHA
            and overlays["syntheticConfiguration"].get("syntheticConfiguration") is True
            and overlays["syntheticConfiguration"].get("upstreamCredentialsUsed") is False,
            "Position overlays lack their original source stamp/local configuration")
    return {"methods": 86, "executions": 89, "newRegressionExecutions": cases["newRegressionExecutions"]}


def verify_native(folder):
    folder = Path(folder)
    result, host = read(folder / "result.json"), read(folder / "host.json")
    require(result.get("sourceCommit") == BASE_SHA and result.get("passed") is True
            and result.get("passedTests") == 3 and result.get("failedTests") == 0 and result.get("skippedTests") == 0
            and result.get("passedMethods") == list(native.CASES.values()), "Native aggregate is not the exact three passing methods")
    require(host.get("sourceCommit") == BASE_SHA and host.get("nativeRequired") is True
            and host.get("localMode") is True and host.get("configuration") == "Debug", "Native host was not the tested native-required reader")
    check_hashes(folder, {"host.json": result["hostSHA256"], "build-settings.json": host["settingsSHA256"],
                          "native-exports.json": host["nativeExportsSHA256"]})
    restored = read(folder / "source-restored.json")
    require(restored.get("sourceCommit") == BASE_SHA and restored.get("trackedSourceRestored") is True, "Native source restoration failed or belongs to another source")
    cases = []
    for name, method in native.CASES.items():
        record = read(folder / (name + "-result.json"))
        require(record.get("sourceCommit") == BASE_SHA and record.get("hostSHA256") == result["hostSHA256"], "Native case source/host changed")
        check_hashes(folder, {name + "-summary.json": record["summarySHA256"], name + "-tests.json": record["testsSHA256"],
                              name + ".log": record["logSHA256"], name + "-lifecycle.log": record["lifecycleLogSHA256"]})
        actual = native.verify_case(read(folder / (name + "-summary.json")), read(folder / (name + "-tests.json")), method)
        require(all(record.get(key) == value for key, value in actual.items()), "Native case disagrees with raw execution")
        native.verify_test_verdict((folder / (name + ".log")).read_text(encoding="utf-8"))
        cases.append(record)
    require(result.get("cases") == cases, "Native case aggregation differs from the raw case records")
    return {"executions": 3, "methods": list(native.CASES.values()), "testedOrdinaryJarSHA256": host["ordinaryJarSHA256"]}


def checkout():
    sha = git("rev-parse", "HEAD")
    require(sha == os.environ.get("GITHUB_SHA") and os.environ.get("GITHUB_REPOSITORY") == REPOSITORY,
            "Expected this repository's exact checked-out retry SHA")
    require(detect_reuse(git("log", "-1", "--format=%B")), "Reuse needs the explicit commit marker")
    require(not git("status", "--porcelain", "--untracked-files=no"), "Reuse requires a clean tracked checkout")
    changes = git("diff", "--name-only", "--no-renames", "-z", BASE_SHA, sha, binary=True).decode().split("\0")
    changes = [item for item in changes if item]
    validate_changes(changes)
    return sha, changes


def prepare(work):
    api = replay.GitHub(REPOSITORY, os.environ.get("GITHUB_TOKEN", ""))
    replay.fetch_source(BASE_SHA, api.token)
    sha, changes = checkout()
    run = api.run(RUN_ID)
    jobs = api.get(f"/actions/runs/{RUN_ID}/attempts/{ATTEMPT}/jobs?per_page=100")["jobs"]
    artifacts = api.artifacts(RUN_ID)
    validate_run(run)
    validate_jobs(jobs)
    validate_artifacts(artifacts)
    write(work / "metadata.json", {"currentSHA": sha, "changes": changes, "run": run, "jobs": jobs, "artifacts": artifacts})


def verify(work):
    sha, changes = checkout()
    metadata = read(work / "metadata.json")
    require(metadata["currentSHA"] == sha and metadata["changes"] == changes, "Retry checkout changed after admission")
    validate_run(metadata["run"])
    validate_jobs(metadata["jobs"])
    validate_artifacts(metadata["artifacts"])
    positions = verify_position(work / "position/reader-position-regression", lambda path: git("show", BASE_SHA + ":" + path, binary=True))
    jni = verify_native(work / "build/.build/jimage-native-check")
    receipt = {"schemaVersion": 1, "verified": True, "currentSourceCommit": sha, "testedSourceCommit": BASE_SHA,
               "sourceRunID": RUN_ID, "sourceRunAttempt": ATTEMPT, "artifacts": ARTIFACTS,
               "allowedChangedFiles": changes, "position": positions, "jni": jni,
               "positionAndJNITestsExecutedInCurrentRun": False, "freshOrdinaryJarExecutedByJNIInCurrentRun": False,
               "scope": "Prior passing source-equivalent reader/JNI evidence; current run rebuilds the ordinary JAR and Release app and audits the package. No current-run JNI execution or physical-device acceptance is claimed."}
    write(work / "receipt.json", receipt)
    output("verified", "true")
    print(json.dumps(receipt, indent=2))


def attach(work):
    receipt = check_receipt(work)
    target = REPO / ".build/reader-experience/output"
    manifest = read(target / "build-manifest.json")
    require("reusedReaderTestEvidence" not in manifest, "Manifest already has reuse evidence")
    manifest["reusedReaderTestEvidence"] = receipt
    write(target / "build-manifest.json", manifest)
    shutil.copyfile(work / "receipt.json", target / "reader-test-reuse.json")
    with (target / "README.txt").open("a", encoding="utf-8") as stream:
        stream.write("\nThis packaging retry reuses passing reader-position (86 methods / 89 executions) and JNI (3 methods) evidence from run 42028850565, commit " + BASE_SHA + ".\nOnly the permitted packaging audit/workflow repair changed; the current run freshly builds the ordinary JAR and Release application and runs package audits. The fresh JAR was not executed by JNI in this run; no physical-device acceptance is claimed. See reader-test-reuse.json.\n")


def check_receipt(work):
    receipt = read(work / "receipt.json")
    require(receipt.get("verified") is True and receipt.get("currentSourceCommit") == git("rev-parse", "HEAD")
            and receipt.get("testedSourceCommit") == BASE_SHA and receipt.get("sourceRunID") == RUN_ID
            and receipt.get("sourceRunAttempt") == ATTEMPT and receipt.get("artifacts") == ARTIFACTS
            and receipt.get("positionAndJNITestsExecutedInCurrentRun") is False
            and receipt.get("freshOrdinaryJarExecutedByJNIInCurrentRun") is False,
            "Missing verified retry receipt for this exact checkout")
    validate_changes(receipt["allowedChangedFiles"])
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("detect", "prepare", "verify", "receipt", "attach"))
    parser.add_argument("--work", type=Path, default=REPO / ".build/reused-reader-evidence")
    args = parser.parse_args()
    if args.phase == "detect":
        reuse = detect_reuse(git("log", "-1", "--format=%B"))
        output("reuse", "true" if reuse else "false")
        print("Pinned prior test evidence requested" if reuse else "Normal full test execution required")
    else:
        {"prepare": prepare, "verify": verify, "receipt": check_receipt, "attach": attach}[args.phase](args.work)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, TypeError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(2)
