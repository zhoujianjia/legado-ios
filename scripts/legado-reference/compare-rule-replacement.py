#!/usr/bin/env python3
"""Compare a fixed ported scalar corpus with its actual original-Android report."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess


REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("rule_reference_contract", Path(__file__).with_name("run-rule-reference.py"))
reference = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reference)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def compare(android, port, corpus, inputs, execution, fixture_sha, harness_sha, source_sha, jar_sha):
    require(re.fullmatch(r"[0-9a-f]{40}", source_sha) is not None, "Invalid current source commit")
    require(inputs.get("sourceCommit") == execution.get("sourceCommit") == source_sha
            and inputs.get("fixtureSHA256") == fixture_sha and inputs.get("harnessSHA256") == harness_sha
            and inputs.get("originalArchiveSHA256") == corpus.get("sourceProvenance", {}).get("archiveSHA256")
            and execution.get("passed") is True, "Original reference inputs/execution do not match this checkout")
    reference.verify(android, corpus, fixture_sha, execution.get("referenceRunId"))
    require(isinstance(port, dict) and type(port.get("schemaVersion")) is int and port["schemaVersion"] == 1
            and port.get("referenceKind") == "ported-rule-kernel" and port.get("executionPlatform") == "jvm-desktop"
            and port.get("sourceCommitKind") == "caller-checkout-label" and port.get("sourceCommit") == source_sha,
            "Port trace does not identify its actual desktop execution and current checkout label")
    require(port.get("suite") == corpus["suite"] and port.get("caseSetVersion") == corpus["caseSetVersion"]
            and port.get("fixtureSHA256") == fixture_sha and port.get("sourceProvenance") == corpus["sourceProvenance"]
            and re.fullmatch(r"[0-9a-f]{64}", jar_sha) is not None and port.get("jarSHA256") == jar_sha,
            "Port fixture/source provenance or actually loaded JAR bytes differ")
    expected, actual = corpus["cases"], port.get("cases")
    require(isinstance(actual, list) and len(actual) == len(expected)
            and port.get("passed") is True and port.get("failure") is None
            and port.get("iosValidationPassed") is False and port.get("g4ValidationPassed") is False
            and all(type(port.get(key)) is int and port[key] == value
                    for key, value in (("total", len(expected)), ("executed", len(expected)), ("failed", 0))),
            "Port must execute the complete nonzero corpus without exceptions or promoted iOS gates")
    differences = []
    for fixture, observed, original in zip(expected, actual, android["cases"]):
        require(isinstance(observed, dict) and all(observed.get(key) == fixture[key] for key in ("caseId", "text", "rule"))
                and observed.get("passed") is True and observed.get("exception") is None
                and isinstance(observed.get("actual"), str), "Port case input/order/result is incomplete or changed")
        # Deliberately no trimming, Unicode normalization, newline rewriting or
        # replacement of troublesome expected values.
        if observed["actual"] != original["actual"]:
            differences.append({"caseId": fixture["caseId"], "android": original["actual"], "ported": observed["actual"]})
    return {"schemaVersion": 1, "passed": not differences, "sourceCommit": source_sha,
            "caseSetVersion": corpus["caseSetVersion"], "casesCompared": len(expected),
            "differenceCount": len(differences), "differences": differences,
            "fixtureSHA256": fixture_sha, "portedJarSHA256": jar_sha,
            "iosValidationPassed": False, "g4ValidationPassed": False,
            "declarativeSourceIntegrated": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("android", "port", "corpus", "inputs", "execution", "jar", "output"):
        parser.add_argument("--" + name, required=True, type=Path)
    args = parser.parse_args()
    verdict = {"passed": False, "iosValidationPassed": False, "g4ValidationPassed": False}
    try:
        source = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip()
        fixture_sha = hashlib.sha256(args.corpus.read_bytes()).hexdigest()
        harness_sha = hashlib.sha256(reference.HARNESS.read_bytes()).hexdigest()
        jar_sha = hashlib.sha256(args.jar.read_bytes()).hexdigest()
        objects = [json.loads(path.read_bytes()) for path in (args.android, args.port, args.corpus, args.inputs, args.execution)]
        verdict = compare(*objects, fixture_sha, harness_sha, source, jar_sha)
    except Exception as error:
        verdict["failure"] = type(error).__name__ + ": " + str(error)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x", encoding="utf-8", newline="\n") as output:
        json.dump(verdict, output, ensure_ascii=False, indent=2)
        output.write("\n")
    print(json.dumps(verdict, ensure_ascii=True))
    if not verdict["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
