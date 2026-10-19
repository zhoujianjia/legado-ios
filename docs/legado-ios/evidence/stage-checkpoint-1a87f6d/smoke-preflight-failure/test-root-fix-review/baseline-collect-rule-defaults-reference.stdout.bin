#!/usr/bin/env python3
"""Require actual XCTest/source evidence for the independent observation group.

The frozen comparison CLI also supports fixture-only validation. This collector
has no such fallback: collect requires a real group log, summary, test tree and
result bundle. Complete representation differences remain diagnostic evidence,
never a passing compatibility claim. Portable tests supply synthetic evidence.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


reference = module("rule_collection_reference", "rule-defaults-reference.py")
stage = module("rule_collection_stage", "reader-stage-baseline.py")
smoke = stage.smoke
config = smoke.config
METHODS = tuple("BookSourceRuleDefaultsReferenceTests/" + name + "()" for name in (
    "originalReferenceContracts", "observeCurrentSwiftRepresentation", "observeUnknownFieldRoutes"))
CONTAINER_TYPES = ("Test Plan", "Unit test bundle", "Test Suite")
SOURCE_FILES = (
    "Tests/iOS/yuedu appTests/BookSourceRuleDefaultsReferenceTests.swift", reference.UNKNOWN,
    "scripts/reader-experience/rule-defaults-reference.py",
    "scripts/reader-experience/test-rule-defaults-reference.py",
    "scripts/reader-experience/collect-rule-defaults-reference.py",
    "scripts/reader-experience/test-collect-rule-defaults-reference.py",
    "scripts/reader-experience/smoke.sh", ".github/workflows/reader-smoke.yml",
    "Modules/Core/BookSource/BookSource.swift",
    "Modules/Core/BookSource/BookSourceImportOptions.swift",
    "Modules/Core/BookSource/BookSourceStore.swift",
    *("docs/legado-ios/fixtures/" + name for name in reference.FROZEN),
)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def evidence(path):
    raw = path.read_bytes()
    return {"path": str(path.absolute()), "bytes": len(raw), "sha256": digest(raw)}


def object_json(path):
    return reference.strict_json(path.read_text(encoding="utf-8"))


def source_provenance():
    inputs = {}
    for name in SOURCE_FILES:
        raw = config.checked_path(REPO / name).read_bytes()
        reference.require(raw == smoke.git("show", "HEAD:" + name, binary=True),
                          "Observer source differs from committed checkpoint: " + name)
        inputs[name] = {"sha256": digest(raw), "bytes": len(raw)}
    # Pin the actual simple, unparameterized declarations as well as their bytes.
    text = (REPO / SOURCE_FILES[0]).read_text(encoding="utf-8")
    import re
    declared = re.findall(r"^\s*func (\w+)\(\) throws \{", text, re.MULTILINE)
    reference.require(tuple("BookSourceRuleDefaultsReferenceTests/" + name + "()" for name in declared) == METHODS
                      and len(re.findall(r"^\s*@Test\b", text, re.MULTILINE)) == 3,
                      "Observer source method inventory changed")
    return inputs


def validate_binding(audit_path, environment_path):
    audit = object_json(audit_path)
    smoke.review_overlays(audit)
    environment = stage.validate_environment(object_json(environment_path))
    reference.require(environment["sourceCommit"] == audit["sourceCommit"] == smoke.source_sha(),
                      "Observer environment/source checkpoint mismatch")
    reference.require(environment["sourceFiles"] == stage.source_provenance(),
                      "Shared environment source changed after capture")
    for item in environment["inputEvidence"].values():
        reference.require(digest(config.checked_path(Path(item["path"])).read_bytes()) == item["sha256"],
                          "Shared environment input changed after capture")
    reference.require(environment["inputEvidence"]["audit"]["sha256"] == digest(audit_path.read_bytes()),
                      "Observer uses a different overlay audit")
    return environment


def verify_execution(summary, tree, test_exit_status):
    reference.require(type(test_exit_status) is int and test_exit_status == 0, "Observer XCTest wrapper failed")
    counts = smoke.verify_summary(summary, 3, 3)
    reference.require(type(tree) is dict and type(tree.get("testNodes")) is list, "Missing actual xcresult tests tree")
    found = set()

    def visit(node):
        reference.require(type(node) is dict, "Malformed observer test node")
        kind = node.get("nodeType")
        reference.require(type(kind) is str and kind in (*CONTAINER_TYPES, "Test Case"),
                          "Unknown or missing observer node type")
        children = node.get("children", [])
        reference.require(type(children) is list, "Malformed observer test children")
        if kind == "Test Case":
            name = node.get("nodeIdentifier")
            reference.require(type(name) is str, "Observer test leaf lacks method identity")
            identity = name.removeprefix("yuedu appTests/")
            reference.require(identity in METHODS and identity not in found and node.get("result") == "Passed"
                              and not children, "Unexpected/duplicate/failed/skipped observer test leaf: " + name)
            found.add(identity)
        else:
            reference.require(children and ("result" not in node or node["result"] == "Passed"),
                              "Empty or nonpassing observer container")
        for child in children:
            visit(child)
    for node in tree["testNodes"]:
        visit(node)
    reference.require(found == set(METHODS), "Missing observer test methods")
    return {"counts": counts, "passedMethodIdentities": sorted(found)}


def prepare(audit_path, environment_path, output):
    reference.require(not output.exists(), "Refusing to overwrite observer preparation")
    environment = validate_binding(audit_path, environment_path)
    originals, _ = reference.load_references()
    unknown, _ = reference.load_unknown()
    value = {"schemaVersion": 1, "kind": "rule-defaults-observer-preparation",
             "sourceCommit": environment["sourceCommit"], "sourceInputs": source_provenance(),
             "environment": evidence(environment_path), "audit": evidence(audit_path),
             "expectedMethodIdentities": list(METHODS), "originalReferenceRows": len(originals),
             "forwardUnknownFixtures": len(unknown), "swiftExecutionPerformedByPreparation": False}
    config.write_new_json(output, value)
    return value


def verify_comparison(comparison, computed, original_evidence, unknown_evidence, log_path, exit_status):
    reference.require(type(comparison) is dict, "Missing comparison report")
    for name, expected in {"schemaVersion": 1, "originalReferenceRows": 40, "forwardUnknownFixtures": 13,
                           "observationRows": 319, "selectedGetterSnapshots": 760, "forwardUnknownSnapshots": 156}.items():
        reference.require(type(comparison.get(name)) is int and comparison[name] == expected,
                          "Missing or invalid collection count/schema: " + name)
    for name in ("fixtureContractsValidated", "observationLogProvided", "observationCollectionComplete"):
        reference.require(comparison.get(name) is True, "Collection cannot use fixture-only or incomplete output")
    reference.require(comparison.get("frozenOriginalEvidence") == original_evidence
                      and comparison.get("forwardUnknownEvidence") == unknown_evidence,
                      "Comparison fixture provenance changed")
    for key, expected in computed.items():
        reference.require(comparison.get(key) == expected, "Comparison differs from raw observations: " + key)
    raw = log_path.read_bytes()
    reference.require(comparison.get("observationLog") == {
        "path": str(log_path), "bytes": len(raw), "sha256": digest(raw),
        "provenance": "Supplied text log only. Bind actual XCTest/source/build evidence separately; text alone does not attest execution."},
        "Comparison raw log digest/path mismatch")
    match = comparison.get("selectedContractsMatch")
    difference_count = comparison.get("differenceCount")
    reference.require(type(match) is bool and type(difference_count) is int
                      and ((exit_status == 0 and match and difference_count == 0)
                           or (exit_status == 1 and not match and difference_count > 0)),
                      "Comparator exit status is not explained by complete observed differences")
    reference.require(comparison.get("fullSourceSchemaCompatibilityEstablished") is False,
                      "Whole schema compatibility must not be accepted")


def collect(args):
    # Preserve original marker bytes before enforcing failures, like the existing
    # reader-stage collector. These are diagnostic raw rows, never synthetic fixes.
    paths = (args.raw, args.output, args.comparison, args.comparator_stdout, args.comparator_stderr)
    inputs = (args.log, args.summary, args.tests, args.audit, args.environment, args.preparation,
              args.result_bundle / "Info.plist")
    reference.require(len({path.resolve() for path in paths}) == len(paths)
                      and not {path.resolve() for path in paths}.intersection(path.resolve() for path in inputs),
                      "Collection outputs must be distinct from each other and inputs")
    for path in paths:
        config.checked_path(path)
        reference.require(not path.exists(), "Refusing to overwrite prior observer evidence: " + str(path))
    raw = args.log.read_bytes()
    args.raw.parent.mkdir(parents=True, exist_ok=True)
    args.raw.write_bytes(b"".join(line for line in raw.splitlines(keepends=True) if reference.MARKER.encode() in line))
    execution = verify_execution(object_json(args.summary), object_json(args.tests), args.test_exit_status)
    reference.require(args.result_bundle.is_dir() and (args.result_bundle / "Info.plist").is_file(),
                      "Missing original observer xcresult bundle")
    prepared = object_json(args.preparation)
    environment = validate_binding(args.audit, args.environment)
    reference.require(type(prepared) is dict and prepared.get("schemaVersion") == 1
                      and prepared.get("kind") == "rule-defaults-observer-preparation"
                      and prepared.get("sourceCommit") == environment["sourceCommit"]
                      and prepared.get("sourceInputs") == source_provenance()
                      and prepared.get("expectedMethodIdentities") == list(METHODS)
                      and type(prepared.get("originalReferenceRows")) is int and prepared["originalReferenceRows"] == 40
                      and type(prepared.get("forwardUnknownFixtures")) is int and prepared["forwardUnknownFixtures"] == 13
                      and prepared.get("environment") == evidence(args.environment)
                      and prepared.get("audit") == evidence(args.audit),
                      "Observer source/environment changed since preparation")
    originals, original_evidence = reference.load_references()
    unknown, unknown_evidence = reference.load_unknown()
    computed = reference.compare_observations(originals, unknown, reference.parse_observations(raw.decode("utf-8")))
    input_evidence = [evidence(path) for path in inputs]
    # Keep the original CLI contract and its actual exit1 on differences. Only a
    # full independently revalidated report can classify that exit as diagnostic.
    process = subprocess.run([sys.executable, "-B", str(HERE / "rule-defaults-reference.py"),
                              "--log", str(args.log), "--output", str(args.comparison)], capture_output=True)
    args.comparator_stdout.write_bytes(process.stdout)
    args.comparator_stderr.write_bytes(process.stderr)
    reference.require(args.log.read_bytes() == raw and input_evidence == [evidence(path) for path in inputs]
                      and source_provenance() == prepared["sourceInputs"],
                      "Observer inputs changed during collection")
    comparison = object_json(args.comparison)
    verify_comparison(comparison, computed, original_evidence, unknown_evidence, args.log, process.returncode)
    result = {"schemaVersion": 1, "status": "observed-differences" if not comparison["selectedContractsMatch"]
              else "collected-selected-contracts-match", "collectionPassed": True,
              "selectedContractsMatch": comparison["selectedContractsMatch"], "compatibilityAccepted": False,
              "fullSourceSchemaCompatibilityEstablished": False, "sourceCommit": environment["sourceCommit"],
              "sourceInputs": prepared["sourceInputs"], "environment": environment,
              "testExecutionGate": execution, "testWrapperExitStatus": args.test_exit_status,
              "comparatorExitStatus": process.returncode, "observationRows": 319,
              "originalObservationRows": 280, "unknownObservationRows": 39,
              "selectedGetterSnapshots": 760, "forwardUnknownSnapshots": 156, "totalSnapshots": 916,
              "differenceCount": comparison["differenceCount"],
              "evidence": {name: evidence(path) for name, path in (
                  ("preparation", args.preparation), ("audit", args.audit), ("environment", args.environment),
                  ("summary", args.summary), ("tests", args.tests), ("log", args.log), ("rawRows", args.raw),
                  ("comparison", args.comparison), ("comparatorStdout", args.comparator_stdout),
                  ("comparatorStderr", args.comparator_stderr), ("xcresultInfo", args.result_bundle / "Info.plist"))},
              "resultBundle": str(args.result_bundle), "physicalDeviceAccepted": False,
              "scope": "Actual XCTest collection gate plus five selected getter/default-Gson fields and thirteen unknown-preservation fixtures. Representation differences remain diagnostic; full model/rule execution parity is not established."}
    config.write_new_json(args.output, result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="phase", required=True)
    preparation = sub.add_parser("prepare")
    collection = sub.add_parser("collect", help="Require actual collection; fixture-only validation cannot satisfy this mode")
    for command in (preparation, collection):
        for name in ("audit", "environment", "output"):
            command.add_argument("--" + name, type=Path, required=True)
    for name in ("preparation", "log", "summary", "tests", "result-bundle", "raw", "comparison",
                 "comparator-stdout", "comparator-stderr"):
        collection.add_argument("--" + name, type=Path, required=True)
    collection.add_argument("--test-exit-status", type=int, required=True)
    args = parser.parse_args()
    try:
        result = prepare(args.audit, args.environment, args.output) if args.phase == "prepare" else collect(args)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(f"{type(error).__name__}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
