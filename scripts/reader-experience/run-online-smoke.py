#!/usr/bin/env python3
"""Own one loopback fixture process and retain a separate online-reader verdict."""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import time
import urllib.parse
import urllib.request


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


smoke = load("online_reader_smoke_helpers", HERE / "smoke-tools.py")


def read_http_json(url):
    # The fixture is local. Inherited HTTP proxy configuration must not route it
    # to another host or turn an unavailable fixture into a remote response.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(url, timeout=1) as response:
        raw = response.read(4 * 1024 * 1024 + 1)
        if len(raw) > 4 * 1024 * 1024:
            raise ValueError("Loopback fixture evidence exceeded its size limit")
        return json.loads(raw)


def validate_ready(value):
    if not isinstance(value, dict) or value.get("schemaVersion") != 1:
        raise ValueError("Fixture readiness schema mismatch")
    run_id = value.get("runId")
    if (not isinstance(run_id, str) or not 8 <= len(run_id) <= 64
            or any(c not in "0123456789abcdef-" for c in run_id)):
        raise ValueError("Fixture must identify its own fresh run")
    origin = "http://localhost:18769"
    if value.get("origin") != origin or value.get("baseURL") != origin + "/fixture/" + run_id:
        raise ValueError("Only the owned localhost fixture origin is accepted")
    if value.get("sourceURL") != value["baseURL"] + "/sources.json":
        raise ValueError("Fixture import URL does not belong to this run")
    return value


def wait_ready(process, path, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("Owned fixture exited before becoming ready; inspect its log")
        if path.exists():
            ready = validate_ready(smoke.read_json(path))
            actual = read_http_json(ready["origin"] + "/health")
            if actual != ready:
                raise ValueError("Fixture health differs from this process's readiness file")
            return ready
        time.sleep(min(0.1, max(0, deadline - time.monotonic())))
    raise TimeoutError("Owned fixture did not publish readiness before its deadline")


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    return process.poll() is not None


def run(work, command):
    work = smoke.config.checked_path(work)
    work.mkdir(parents=True, exist_ok=True)
    paths = {name: work / name for name in (
        "online-fixture-ready.json", "online-fixture-trace.json",
        "online-fixture-process.json", "online-fixture-server.log")}
    if not command or any(path.exists() for path in paths.values()):
        raise ValueError("A command and unused fixture evidence paths are required")
    source = smoke.source_sha()
    started = datetime.now(timezone.utc).isoformat()
    process = None
    ready = None
    code = None
    issue = None
    stopped = False
    with paths["online-fixture-server.log"].open("xb") as log:
        try:
            process = subprocess.Popen([sys.executable, "-B", str(HERE / "online-source-fixture.py"),
                                        "--port", "18769", "--ready-file", str(paths["online-fixture-ready.json"])],
                                       cwd=REPO, stdout=log, stderr=subprocess.STDOUT)
            ready = wait_ready(process, paths["online-fixture-ready.json"])
            code = subprocess.run(command, cwd=REPO, check=False).returncode
            if process.poll() is not None:
                raise RuntimeError("Owned fixture exited while the reader test was executing")
        except Exception as error:
            issue = type(error).__name__ + ": " + str(error)
        finally:
            if process is not None:
                try:
                    if ready is not None and process.poll() is None:
                        trace = read_http_json(ready["origin"] + "/trace?" + urllib.parse.urlencode({"runId": ready["runId"]}))
                        smoke.config.write_new_json(paths["online-fixture-trace.json"], trace)
                except Exception as error:
                    issue = issue or (type(error).__name__ + ": " + str(error))
                finally:
                    stopped = stop(process)
    record = {"schemaVersion": 1, "sourceCommit": source, "startedAt": started,
              "completedAt": datetime.now(timezone.utc).isoformat(),
              "fixturePID": process.pid if process is not None else None,
              "ready": ready, "commandExitCode": code,
              "fixtureStopped": stopped, "issue": issue,
              "deviceValidationPassed": False, "deliveredIPAExecuted": False}
    smoke.config.write_new_json(paths["online-fixture-process.json"], record)
    if issue is not None:
        print(issue, file=sys.stderr)
        return 1
    return code if code is not None and 0 <= code <= 125 else 1


def result(work, summary):
    work = smoke.config.checked_path(work)
    process = smoke.read_json(work / "online-fixture-process.json")
    if (process.get("sourceCommit") != smoke.source_sha()
            or type(process.get("commandExitCode")) is not int or process["commandExitCode"] != 0
            or process.get("fixtureStopped") is not True or process.get("issue") is not None):
        raise ValueError("Online reader requires this source's successful command and stopped owned fixture")
    ready = validate_ready(process.get("ready"))
    trace = smoke.read_json(work / "online-fixture-trace.json")
    if trace.get("runId") != ready["runId"]:
        raise ValueError("Online trace does not belong to this fixture process")
    fixture = load("online_reader_fixture_evidence", HERE / "online-source-fixture.py")
    verified = fixture.verify_trace(trace, expected_run_id=ready["runId"])
    return {"schemaVersion": 1, "sourceCommit": process["sourceCommit"], "status": "passed",
            "configuration": "Debug", "executionPlatform": "ios-simulator",
            "targetedTests": smoke.verify_summary(summary, 1),
            "fixtureRunId": ready["runId"], "fixtureTrace": verified,
            "fixtureTraceSHA256": smoke.config.digest(work / "online-fixture-trace.json"),
            "readerRoute": "Existing Yuedu/JavaScriptCore book-source and CoreText reader",
            "jvmIntegratedIntoReading": False, "deviceValidationPassed": False,
            "deliveredIPAExecuted": False, "provesFullLegadoCompatibility": False,
            "limitations": ["One fixed loopback source on Debug Simulator.",
                            "No real-site, physical-device or delivered Release IPA acceptance."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="phase", required=True)
    execution = commands.add_parser("run")
    execution.add_argument("--work", type=Path, required=True)
    execution.add_argument("command", nargs=argparse.REMAINDER)
    verdict = commands.add_parser("result")
    verdict.add_argument("--work", type=Path, required=True)
    verdict.add_argument("--summary", type=Path, required=True)
    verdict.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.phase == "run":
            command = args.command[1:] if args.command[:1] == ["--"] else args.command
            return run(args.work, command)
        report = result(args.work, smoke.read_json(args.summary))
        smoke.config.write_new_json(args.output, report)
        print(json.dumps(report, indent=2))
        return 0
    except Exception as error:
        print(type(error).__name__ + ": " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
