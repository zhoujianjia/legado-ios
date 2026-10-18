#!/usr/bin/env python3
"""Stage an isolated, additional original-Android rule-replacement reference."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import uuid


REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO / ".build/legado-rule-reference/source"
OUTPUT = REPO / ".build/ci-logs/rule-reference"
FIXTURE = REPO / "Packages/LegadoRuntime/jvm/src/test/resources/fixtures/rule-replacement-cases.json"
HARNESS = REPO / "tools/legado-reference/androidTest/RuleReplacementGoldenTest.kt"
CLASS = "io.legado.app.reference.RuleReplacementGoldenTest"
ORIGINAL_RULE_PATH = "app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeRule.kt"


def common_driver():
    spec = importlib.util.spec_from_file_location("isolated_rule_reference_common", Path(__file__).with_name("run-reference.py"))
    common = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(common)
    common.SOURCE = SOURCE
    common.OUTPUT = OUTPUT
    common.FIXTURE = FIXTURE
    common.HARNESS = HARNESS
    common.STAGED_INIT_SCRIPT = SOURCE / "reference.init.gradle"
    common.TEST_CLASS = CLASS
    common.HARNESS_RELATIVE = "app/src/androidTest/java/io/legado/app/reference/RuleReplacementGoldenTest.kt"
    common.FIXTURE_RELATIVE = "app/src/androidTest/assets/legado-reference/rule-replacement-cases.json"
    common.REMOTE_REPORT = "files/legado-reference/rule-replacement-golden.json"
    common.GOLDEN_FILENAME = "rule-replacement-golden.json"
    common.OBSERVED_FILENAME = "rule-replacement-observed.json"
    common.TEST_CONFIGURATION_OVERRIDES = {
        "cronet": "not exercised; fixed original AnalyzeRule string evaluation only",
        "network": "not exercised; no HTTP fixture or platform host replacement",
        "suite": "StaticRuleReplacement; original mainJs reference harness and golden remain separate",
    }
    return common


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify(report, corpus, fixture_sha256, run_id):
    require(isinstance(report, dict) and isinstance(corpus, dict), "Reference report and corpus must be objects")
    require(type(report.get("schemaVersion")) is int and report["schemaVersion"] == 1
            and type(corpus.get("schemaVersion")) is int and corpus["schemaVersion"] == 1,
            "Reference report and corpus must use the fixed schema")
    require(isinstance(run_id, str) and str(uuid.UUID(run_id)) == run_id
            and report.get("referenceRunId") == run_id, "Rule reference is stale or lacks its current run identity")
    require(report.get("referenceKind") == "original-archive-android-instrumentation"
            and report.get("applicationClass") == "io.legado.app.App"
            and type(report.get("applicationMinSdkVersion")) is int and report["applicationMinSdkVersion"] == 26,
            "Reference must execute the original Android application with the declared minimum SDK")
    require(report.get("suite") == corpus.get("suite") == "StaticRuleReplacement"
            and report.get("caseSetVersion") == corpus.get("caseSetVersion") == "legado-static-rule-replacement-v1"
            and report.get("fixtureSHA256") == fixture_sha256,
            "Rule reference suite/version/fixture bytes differ from staged inputs")
    source = corpus.get("sourceProvenance")
    require(isinstance(source, dict) and report.get("originalArchiveSHA256") == source.get("archiveSHA256")
            and report.get("sourceProvenance") == source, "Rule reference original-source provenance differs")
    expected, observed = corpus.get("cases"), report.get("cases")
    require(isinstance(expected, list) and expected and isinstance(observed, list) and len(observed) == len(expected),
            "Rule reference did not execute the complete fixed corpus")
    identifiers = set()
    for fixture, actual in zip(expected, observed):
        require(isinstance(fixture, dict) and isinstance(actual, dict), "Rule reference case must be an object")
        name = fixture.get("caseId")
        require(isinstance(name, str) and name and name not in identifiers, "Rule reference corpus case names must be unique")
        identifiers.add(name)
        require(all(actual.get(key) == fixture.get(key) and isinstance(fixture.get(key), str)
                    for key in ("caseId", "text", "rule")), "Rule reference case order or original string bytes differ")
        require(actual.get("passed") is True and isinstance(actual.get("actual"), str) and actual.get("exception") is None,
                "Every original rule result must be retained, including empty strings; exceptions cannot be omitted")
    require(report.get("passed") is True and report.get("failure") is None and report.get("iosValidationPassed") is False
            and all(type(report.get(key)) is int and report[key] == value
                    for key, value in (("total", len(expected)), ("executed", len(expected)), ("failed", 0))),
            "Rule reference requires actual nonzero complete execution and no failures")
    return {"passed": True, "executionPlatform": "original-android-instrumentation",
            "casesVerified": len(expected), "fixtureSHA256": fixture_sha256,
            "iosValidationPassed": False, "g4ValidationPassed": False}


def stage():
    common = common_driver()
    manifest = common.verify_original_files()
    corpus = json.loads(FIXTURE.read_bytes())
    provenance = corpus.get("sourceProvenance", {})
    require(provenance.get("archiveSHA256") == manifest["originalArchiveSHA256"]
            and provenance.get("path") == ORIGINAL_RULE_PATH,
            "Rule corpus original archive or fixed AnalyzeRule path differs")
    actual = hashlib.sha256((SOURCE / ORIGINAL_RULE_PATH).read_bytes()).hexdigest()
    require(provenance.get("fileSHA256") == actual, "Rule corpus AnalyzeRule bytes differ from the original source")
    common.stage()


def execute():
    common = common_driver()
    verdict = {"passed": False, "iosValidationPassed": False, "g4ValidationPassed": False}
    try:
        common.execute()
        execution = json.loads((OUTPUT / "execution.json").read_bytes())
        raw = (OUTPUT / "rule-replacement-golden.json").read_bytes()
        verdict = verify(json.loads(raw), json.loads(FIXTURE.read_bytes()),
                         hashlib.sha256(FIXTURE.read_bytes()).hexdigest(), execution["referenceRunId"])
        verdict["reportSHA256"] = hashlib.sha256(raw).hexdigest()
    except Exception as error:
        verdict["failure"] = type(error).__name__ + ": " + str(error)
        raise
    finally:
        common.write_json(OUTPUT / "rule-verification.json", verdict)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("stage", "execute"))
    args = parser.parse_args()
    if args.command == "stage":
        stage()
    else:
        execute()


if __name__ == "__main__":
    main()
