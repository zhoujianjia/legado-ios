#!/usr/bin/env python3
"""Own and verify one independent failure-exit UI selection; never the success smoke."""
import argparse
import importlib.util
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


runner = load("reader_failure_runner", "run-online-smoke.py")
native = load("reader_failure_case_gate", "jimage-native-check.py")
METHOD = "ReaderChapterFailureExitUITests/testSecondChapterFailureCanExitWithChromeHidden()"


def result(work, summary, tests):
    record = runner.result(work, summary, scenario="chapter-failure")
    exact = native.verify_case(summary, tests, METHOD)
    record.update(passedMethod=exact["passedMethod"],
                  runtimeWarnings=exact["runtimeWarnings"],
                  readerRoute="Retained original WebBook/Rhino JVM and CoreText reader",
                  jvmIntegratedIntoReading=True,
                  failureExitScope="Second chapter HTTP 500, one manual retry, hidden-chrome exit to details and library.",
                  automaticRetryObserved=False)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="phase", required=True)
    run = commands.add_parser("run")
    run.add_argument("--work", required=True, type=Path)
    run.add_argument("command", nargs=argparse.REMAINDER)
    verdict = commands.add_parser("result")
    verdict.add_argument("--work", required=True, type=Path)
    verdict.add_argument("--summary", required=True, type=Path)
    verdict.add_argument("--tests", required=True, type=Path)
    verdict.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.phase == "run":
        command = args.command[1:] if args.command[:1] == ["--"] else args.command
        return runner.run(args.work, command, scenario="chapter-failure")
    record = result(args.work, runner.smoke.read_json(args.summary), runner.smoke.read_json(args.tests))
    record.update(summarySHA256=runner.smoke.config.digest(args.summary),
                  testTreeSHA256=runner.smoke.config.digest(args.tests),
                  validatorSHA256=runner.smoke.config.digest(Path(__file__)))
    runner.smoke.config.write_new_json(args.output, record)
    return 0


if __name__ == "__main__":
    sys.exit(main())
