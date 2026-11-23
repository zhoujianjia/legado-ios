#!/usr/bin/env python3
"""Require this attempt's exact-source fresh position job before Release work."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import time
import urllib.error
import urllib.request

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
WORKFLOW = ".github/workflows/legado-reader.yml"
FRESH_STEP = "Require the source-only reader position regressions before packaging"
ARTIFACT_STEP = "Preserve selected source, raw results and failure logs"
MAX_WAIT = 5400


class BarrierError(ValueError):
    pass


def require(value, code):
    if not value:
        raise BarrierError(code)


def context(environment, source):
    require(environment.get("GITHUB_REPOSITORY") == "zhoujianjia/legado-ios", "wrong-repository")
    require(re.fullmatch(r"[0-9a-f]{40}", source or "") and environment.get("GITHUB_SHA") == source,
            "wrong-checkout-source")
    require(environment.get("GITHUB_REF_NAME") == "reader-legado-" + source[:7], "wrong-source-tag")
    require(environment.get("GITHUB_EVENT_NAME") == "push", "wrong-event")
    run, attempt = environment.get("GITHUB_RUN_ID", ""), environment.get("GITHUB_RUN_ATTEMPT", "")
    require(re.fullmatch(r"[1-9][0-9]*", run) and re.fullmatch(r"[1-9][0-9]*", attempt), "invalid-run-attempt")
    return {"repository": environment["GITHUB_REPOSITORY"], "sourceCommit": source,
            "runID": int(run), "runAttempt": int(attempt), "tag": environment["GITHUB_REF_NAME"], "workflow": WORKFLOW}


def validate_run(run, expected):
    require(isinstance(run, dict) and run.get("id") == expected["runID"]
            and type(run.get("id")) is int and run.get("run_attempt") == expected["runAttempt"]
            and type(run.get("run_attempt")) is int and run.get("head_sha") == expected["sourceCommit"]
            and run.get("head_branch") == expected["tag"] and run.get("path") == expected["workflow"]
            and run.get("event") == "push" and run.get("repository", {}).get("full_name") == expected["repository"],
            "run-identity-mismatch")
    require(run.get("status") in ("queued", "in_progress", "completed"), "invalid-run-status")
    require(run.get("status") != "completed" or run.get("conclusion") == "success", "run-already-unsuccessful")
    # Never require overall completion: this very reader job is still running.


def position_job(jobs, expected):
    require(isinstance(jobs, list) and len(jobs) <= 1000, "invalid-job-list")
    identifiers = set()
    for job in jobs:
        require(isinstance(job, dict) and type(job.get("id")) is int and job["id"] > 0
                and job["id"] not in identifiers, "invalid-or-duplicate-job")
        identifiers.add(job["id"])
        require(job.get("run_id") == expected["runID"] and job.get("run_attempt") == expected["runAttempt"]
                and type(job.get("run_id")) is int and type(job.get("run_attempt")) is int
                and job.get("head_sha") == expected["sourceCommit"] and job.get("head_branch") == expected["tag"],
                "job-identity-mismatch")
    matches = [job for job in jobs if job.get("name") == "position-regression"]
    require(len(matches) <= 1, "ambiguous-position-job")
    return matches[0] if matches else None


def require_position_success(job):
    require(job.get("status") == "completed" and job.get("conclusion") == "success", "position-job-unsuccessful")
    require(isinstance(job.get("started_at"), str) and isinstance(job.get("completed_at"), str)
            and job["started_at"] and job["completed_at"], "missing-position-job-times")
    steps = job.get("steps")
    require(isinstance(steps, list), "missing-position-steps")
    for name in (FRESH_STEP, ARTIFACT_STEP):
        matches = [step for step in steps if isinstance(step, dict) and step.get("name") == name]
        require(len(matches) == 1 and matches[0].get("status") == "completed"
                and matches[0].get("conclusion") == "success", "position-step-not-fresh-or-passed")


def fetch_jobs(fetch, expected):
    prefix = "/repos/" + expected["repository"] + "/actions/runs/" + str(expected["runID"])
    jobs, total = [], None
    for page in range(1, 11):
        response = fetch(prefix + "/attempts/" + str(expected["runAttempt"]) + "/jobs?per_page=100&page=" + str(page))
        require(isinstance(response, dict) and type(response.get("total_count")) is int
                and 0 <= response["total_count"] <= 1000 and isinstance(response.get("jobs"), list), "invalid-jobs-response")
        require(total is None or total == response["total_count"], "jobs-pagination-changed")
        total = response["total_count"]
        require(len(response["jobs"]) <= 100, "oversized-jobs-page")
        jobs.extend(response["jobs"])
        if len(jobs) >= total:
            require(len(jobs) == total, "jobs-count-mismatch")
            return jobs
        require(response["jobs"], "truncated-jobs-response")
    raise BarrierError("too-many-jobs-pages")


def wait_for_position(fetch, expected, *, timeout=MAX_WAIT, interval=20,
                      clock=time.monotonic, sleep=time.sleep, observe=None):
    require(type(timeout) is int and 0 < timeout <= MAX_WAIT and type(interval) is int and 0 < interval <= 60,
            "invalid-poll-bounds")
    deadline = clock() + timeout
    prefix = "/repos/" + expected["repository"] + "/actions/runs/" + str(expected["runID"])
    for poll in range(1, math.ceil(timeout / interval) + 2):
        run = fetch(prefix + "/attempts/" + str(expected["runAttempt"]))
        jobs = fetch_jobs(fetch, expected)
        if observe:
            observe(poll, run, jobs)
        validate_run(run, expected)
        job = position_job(jobs, expected)
        if job is not None and job.get("status") == "completed":
            require_position_success(job)
            return {"run": run, "jobs": jobs, "job": job, "pollCount": poll}
        require(job is None or job.get("status") in ("queued", "in_progress", "waiting"), "invalid-position-job-status")
        remaining = deadline - clock()
        require(remaining > 0, "position-wait-deadline")
        # Polling the external job has an explicit finite deadline and rate limit.
        sleep(min(interval, remaining))
    raise BarrierError("position-wait-poll-limit")


def write_new(path, value):
    with path.open("x", encoding="utf-8") as output:
        output.write(json.dumps(value, indent=2, sort_keys=True) + "\n")


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def make_receipt(expected, result, hashes, helper_sha, timeout, interval):
    validate_run(result["run"], expected)
    require(position_job(result["jobs"], expected) == result["job"], "selected-position-job-differs")
    require_position_success(result["job"])
    require(type(timeout) is int and 0 < timeout <= MAX_WAIT and type(interval) is int and 0 < interval <= 60,
            "invalid-poll-bounds")
    require(type(result.get("pollCount")) is int and 1 <= result["pollCount"] <= math.ceil(timeout / interval) + 1,
            "invalid-poll-count")
    require(set(hashes) == {"run.json", "jobs.json", "job.json"}
            and all(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) for value in (*hashes.values(), helper_sha)),
            "invalid-barrier-hash-bindings")
    return {"schemaVersion": 1, "passed": True, "context": expected,
            "sourceCommit": expected["sourceCommit"], "runID": expected["runID"], "runAttempt": expected["runAttempt"],
            "positionJobID": result["job"]["id"], "freshPositionStepPassed": True,
            "rawSHA256": hashes, "helperSHA256": helper_sha, "pollCount": result["pollCount"],
            "timeoutSeconds": timeout, "pollIntervalSeconds": interval,
            "observedOverallRunStatus": result["run"]["status"], "wholeRunCompletionRequired": False,
            "rawPositionMethodCountsIndependentlyParsed": False, "expectedPositionMethods": 86,
            "expectedPositionExecutions": 89, "physicalDeviceAcceptance": False}


def api_reader(token):
    require(isinstance(token, str) and bool(token), "missing-actions-read-token")
    def fetch(path):
        require(path.startswith("/repos/zhoujianjia/legado-ios/actions/runs/"), "invalid-api-path")
        request = urllib.request.Request("https://api.github.com" + path, headers={
            "Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "YueduReaderPositionBarrier"})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                require(response.status == 200, "github-api-status")
                raw = response.read(8 * 1024**2 + 1)
            require(len(raw) <= 8 * 1024**2, "github-api-response-too-large")
            return json.loads(raw)
        except urllib.error.HTTPError as error:
            raise BarrierError("github-api-http-" + str(error.code)) from None
        except (OSError, ValueError) as error:
            if isinstance(error, BarrierError):
                raise
            raise BarrierError("github-api-read-failed") from None
    return fetch


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--timeout-seconds", type=int, default=MAX_WAIT)
    parser.add_argument("--poll-seconds", type=int, default=20)
    args = parser.parse_args()
    require(not args.work.exists(), "preserve-prior-position-barrier")
    args.work.mkdir(parents=True)
    try:
        source = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip()
        expected = context(os.environ, source)
        fetch = api_reader(os.environ.get("GITHUB_TOKEN"))
        def observe(poll, run, jobs):
            write_new(args.work / ("poll-" + str(poll) + "-run.json"), run)
            write_new(args.work / ("poll-" + str(poll) + "-jobs.json"), jobs)
        result = wait_for_position(fetch, expected, timeout=args.timeout_seconds, interval=args.poll_seconds, observe=observe)
        for name in ("run", "jobs", "job"):
            write_new(args.work / (name + ".json"), result[name])
        receipt = make_receipt(expected, result,
            {name + ".json": sha(args.work / (name + ".json")) for name in ("run", "jobs", "job")},
            sha(Path(__file__)), args.timeout_seconds, args.poll_seconds)
        write_new(args.work / "result.json", receipt)
        print(json.dumps({"passed": True, "sourceCommit": source, "runID": expected["runID"],
                          "runAttempt": expected["runAttempt"], "positionJobID": result["job"]["id"]}))
    except (BarrierError, OSError, subprocess.SubprocessError) as error:
        code = str(error) if isinstance(error, BarrierError) else type(error).__name__
        write_new(args.work / "failure.json", {"passed": False, "errorCode": code})
        print(json.dumps({"passed": False, "errorCode": code}))
        raise SystemExit(2)


if __name__ == "__main__":
    main()
