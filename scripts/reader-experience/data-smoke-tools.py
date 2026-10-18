#!/usr/bin/env python3
"""Run only the book-source data regressions, with the existing local overlays."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import xml.etree.ElementTree as ET


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("source_data_smoke", HERE / "smoke-tools.py")
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


def validate_tag():
    source = smoke.source_sha()
    if os.environ.get("GITHUB_SHA") != source or os.environ.get("GITHUB_REF_NAME") != "legado-reader-data-" + source[:7]:
        raise ValueError("Expected legado-reader-data-<current SHA7> and matching checkout")
    return source


def verify_xml(path, expected):
    root = ET.parse(path).getroot()
    cases = list(root.iter("testcase"))
    if len(cases) != expected or any(list(case.iter(name)) for case in cases for name in ("failure", "error", "skipped")):
        raise ValueError("Swift package requires its exact nonzero passing test count and zero skips")
    return {"expectedTests": expected, "executed": len(cases), "failed": 0, "skipped": 0}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="phase", required=True)
    preparation = commands.add_parser("prepare")
    preparation.add_argument("--work", type=Path, required=True)
    package = commands.add_parser("verify-package")
    package.add_argument("--xml", type=Path, required=True)
    package.add_argument("--expected", type=int, required=True)
    verdict = commands.add_parser("result")
    verdict.add_argument("--work", type=Path, required=True)
    verdict.add_argument("--expected", type=int, required=True)
    args = parser.parse_args()
    if args.phase == "prepare":
        # This imported module is private to this invocation. Existing smoke
        # workflows retain their original exact tag validation.
        smoke.validate_tag = validate_tag
        result = smoke.prepare(args.work)
    elif args.phase == "verify-package":
        if args.expected < 1:
            raise ValueError("A nonzero test count is required")
        result = verify_xml(args.xml, args.expected)
    else:
        if args.expected < 1:
            raise ValueError("A nonzero test count is required")
        work = smoke.config.checked_path(args.work)
        audit = smoke.read_json(work / "overlays.json")
        smoke.review_overlays(audit)
        summary = smoke.read_json(work / "source-data-summary.json")
        result = {"schemaVersion": 1, "sourceCommit": validate_tag(),
                  "executionPlatform": "ios-simulator", "configuration": "Debug",
                  "status": "passed", "tests": smoke.verify_summary(summary, args.expected),
                  "sourceOverlays": audit,
                  "scope": "Book-source mainJs preservation, one-time bundled installation and product routing with injected fake execution.",
                  "jvmIntegratedIntoReading": False, "realBookSourcesValidated": False,
                  "deliveredIPAExecuted": False, "deviceValidationPassed": False}
        smoke.config.write_new_json(work / "source-data-result.json", result)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
