#!/usr/bin/env python3
"""Observe unchanged original Android JSONPath APIs, independently of port parity."""
import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import uuid


REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO / ".build/legado-jsonpath-reference/source"
OUTPUT = REPO / ".build/ci-logs/jsonpath-reference"
FIXTURE = REPO / "Packages/LegadoRuntime/jvm/src/test/resources/fixtures/jsonpath-rule-cases.json"
HARNESS = REPO / "tools/legado-reference/androidTest/JsonPathRuleGoldenTest.kt"
CLASS = "io.legado.app.reference.JsonPathRuleGoldenTest"
SUITE = "JsonPathRuleObservation"
VERSION = "legado-jsonpath-public-v1"
ARCHIVE = "724dedcac2427cd1f02ca00af1eab7156146e6d9d3141ca4c92042d04ed7bcdd"
APIS = ("getString", "getStringList", "getElements")
CASE_IDS = ("scalar-unicode-newline", "missing-path", "invalid-balanced-path", "explicit-null", "mixed-list",
            "empty-list", "object-result", "or-missing-fallback", "or-invalid-fallback", "and-lists",
            "interleave-unequal-lists", "balanced-filter-inner-and")
ORIGINAL_SOURCES = {
    "app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeRule.kt":
        "5441d6d00064059519add3e5a81d85b1776f575bd0e5d30f3b5763d90af9e8a9",
    "app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeByJSonPath.kt":
        "ee5ee9ebc95b4f5d6e2d459d6f727fccd10a6bd6a36ce872547f6cee5684109d",
    "app/src/main/java/io/legado/app/model/analyzeRule/RuleAnalyzer.kt":
        "74ab0152bce9d5e014cc69d9c6974cbb093d8353200f1452066f7d05102265a7",
}
NON_ACCEPTANCE = ("iosValidationPassed", "deviceValidationPassed", "compatibilityValidationPassed",
                  "g4ValidationPassed", "fullFeatureParityEstablished")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def common_driver():
    spec = importlib.util.spec_from_file_location("isolated_jsonpath_reference_common", Path(__file__).with_name("run-reference.py"))
    common = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(common)
    common.SOURCE, common.OUTPUT = SOURCE, OUTPUT
    common.FIXTURE, common.HARNESS = FIXTURE, HARNESS
    common.STAGED_INIT_SCRIPT = SOURCE / "reference.init.gradle"
    common.TEST_CLASS = CLASS
    common.HARNESS_RELATIVE = "app/src/androidTest/java/io/legado/app/reference/JsonPathRuleGoldenTest.kt"
    common.FIXTURE_RELATIVE = "app/src/androidTest/assets/legado-reference/jsonpath-rule-cases.json"
    common.REMOTE_REPORT = "files/legado-reference/jsonpath-rule-golden.json"
    common.GOLDEN_FILENAME = "jsonpath-rule-golden.json"
    common.OBSERVED_FILENAME = "jsonpath-rule-observed.json"
    common.TEST_CONFIGURATION_OVERRIDES = {
        "cronet": "not exercised; fixed original AnalyzeRule public JSONPath methods only",
        "network": "not exercised; no HTTP fixture or replacement host",
        "suite": SUITE + "; original mainJs and static-replacement suites remain separate",
        "passedMeaning": "All observations completed, including recorded original API exceptions; no compatibility assertion",
    }
    return common


def validate_corpus(corpus):
    require(isinstance(corpus, dict) and type(corpus.get("schemaVersion")) is int and corpus["schemaVersion"] == 1,
            "JSONPath corpus must use schemaVersion 1")
    require(corpus.get("suite") == SUITE and corpus.get("caseSetVersion") == VERSION
            and corpus.get("apis") == list(APIS), "JSONPath corpus suite/version/public API order differs")
    provenance = corpus.get("sourceProvenance")
    require(isinstance(provenance, dict) and provenance.get("archiveSHA256") == ARCHIVE,
            "JSONPath corpus original archive differs")
    sources = provenance.get("files")
    require(isinstance(sources, list) and len(sources) == len(ORIGINAL_SOURCES)
            and all(isinstance(item, dict) for item in sources)
            and [item.get("path") for item in sources] == list(ORIGINAL_SOURCES)
            and all(item.get("fileSHA256") == ORIGINAL_SOURCES[item["path"]] for item in sources),
            "JSONPath corpus must pin the three original business source files")
    cases = corpus.get("cases")
    require(isinstance(cases, list) and len(cases) == len(CASE_IDS)
            and all(isinstance(item, dict) for item in cases)
            and [item.get("caseId") for item in cases] == list(CASE_IDS), "JSONPath corpus requires the exact twelve input cases")
    for item in cases:
        require(set(item) == {"caseId", "jsonText", "rule"}
                and all(isinstance(item[key], str) for key in item) and item["rule"],
                "JSONPath fixture must contain input strings only, without expected/actual outputs")
        require(isinstance(json.loads(item["jsonText"]), dict), "JSONPath input must be a JSON object string")
    return cases


def json_value(value):
    if value is None or type(value) in (str, bool, int):
        return True
    if type(value) is float:
        return math.isfinite(value)
    if isinstance(value, list):
        return all(json_value(item) for item in value)
    return isinstance(value, dict) and all(isinstance(key, str) and json_value(item) for key, item in value.items())


def verify(report, corpus, fixture_sha256, run_id):
    cases = validate_corpus(corpus)
    require(isinstance(report, dict) and type(report.get("schemaVersion")) is int and report["schemaVersion"] == 1,
            "JSONPath report must use schemaVersion 1")
    require(isinstance(run_id, str) and str(uuid.UUID(run_id)) == run_id
            and report.get("referenceRunId") == run_id, "JSONPath report is stale or lacks the current run identity")
    require(report.get("referenceKind") == "original-archive-android-instrumentation"
            and report.get("applicationClass") == "io.legado.app.App"
            and type(report.get("applicationMinSdkVersion")) is int and report["applicationMinSdkVersion"] == 26,
            "JSONPath reference must execute the original Android application")
    require(report.get("suite") == SUITE and report.get("caseSetVersion") == VERSION
            and report.get("entryPoints") == list(APIS) and report.get("fixtureSHA256") == fixture_sha256
            and report.get("originalArchiveSHA256") == ARCHIVE
            and report.get("sourceProvenance") == corpus["sourceProvenance"],
            "JSONPath report suite/input/source provenance differs")
    expected = [(item, api) for item in cases for api in APIS]
    rows = report.get("observations")
    require(isinstance(rows, list) and len(rows) == len(expected), "JSONPath report must retain all 36 observations")
    returns, exceptions = 0, 0
    for (item, api), row in zip(expected, rows):
        require(isinstance(row, dict) and row.get("api") == api
                and all(row.get(key) == item[key] for key in ("caseId", "jsonText", "rule")),
                "JSONPath observation order/API/original input text differs")
        require(row.get("apiInvoked") is True and row.get("completed") is True and row.get("observationFailure") is None
                and all(key in row for key in ("actual", "javaClass", "elementJavaClasses", "exception")),
                "JSONPath observation is incomplete or omits explicit null/type/error fields")
        if row.get("outcome") == "exception":
            failure = row["exception"]
            require(row["actual"] is None and row["javaClass"] is None and row["elementJavaClasses"] is None
                    and isinstance(failure, dict) and isinstance(failure.get("className"), str) and failure["className"]
                    and "message" in failure and (failure["message"] is None or isinstance(failure["message"], str)),
                    "JSONPath API exception must preserve its class and nullable message")
            hierarchy = failure.get("classHierarchy")
            require(isinstance(hierarchy, list) and len(hierarchy) >= 3
                    and all(isinstance(name, str) and name for name in hierarchy)
                    and len(set(hierarchy)) == len(hierarchy) and hierarchy[0] == failure["className"]
                    and hierarchy[-2:] == ["java.lang.Throwable", "java.lang.Object"]
                    and "java.lang.Exception" in hierarchy
                    and not set(hierarchy).intersection({"java.lang.Error", "java.lang.VirtualMachineError",
                                                       "java.lang.LinkageError", "java.lang.ThreadDeath"})
                    and not (failure["className"].startswith("java.") and failure["className"].endswith("Error"))
                    and failure["className"] != "java.lang.ThreadDeath",
                    "VM, linkage, thread death and other Errors are observation failures, never ordinary API outcomes")
            exceptions += 1
        else:
            value, classes = row["actual"], row["elementJavaClasses"]
            require(row.get("outcome") == "return" and row["exception"] is None and json_value(value),
                    "JSONPath returned observation must preserve its JSON value without an exception")
            require((value is None and row["javaClass"] is None)
                    or (value is not None and isinstance(row["javaClass"], str) and row["javaClass"]),
                    "JSONPath return class must match its null/non-null value")
            if isinstance(value, list):
                require(isinstance(classes, list) and len(classes) == len(value)
                        and all((item is None and name is None)
                                or (item is not None and isinstance(name, str) and name) for item, name in zip(value, classes)),
                        "JSONPath list observations must retain each nullable Java element class")
            else:
                require(classes is None, "Scalar/object observation must not invent element classes")
            returns += 1
    require(report.get("passed") is True and report.get("failure") is None
            and all(type(report.get(key)) is int and report[key] == value for key, value in (
                ("total", len(expected)), ("executed", len(expected)), ("failed", 0),
                ("returnedObservations", returns), ("exceptionObservations", exceptions)))
            and all(report.get(key) is False for key in NON_ACCEPTANCE),
            "Only complete observation may pass; it cannot establish iOS, compatibility or full parity")
    return {"passed": True, "observationComplete": True, "observationsVerified": len(expected),
            "returnedObservations": returns, "exceptionObservations": exceptions,
            "executionPlatform": "original-android-instrumentation", "fixtureSHA256": fixture_sha256,
            **{key: False for key in NON_ACCEPTANCE}}


def stage():
    common = common_driver()
    manifest = common.verify_original_files()
    corpus = json.loads(FIXTURE.read_bytes())
    validate_corpus(corpus)
    require(manifest["originalArchiveSHA256"] == ARCHIVE, "Original snapshot archive identity differs")
    for path, expected in ORIGINAL_SOURCES.items():
        require(hashlib.sha256((SOURCE / path).read_bytes()).hexdigest() == expected,
                "Original JSONPath source bytes changed: " + path)
    common.stage()


def execute():
    common = common_driver()
    verdict = {"passed": False, "observationComplete": False, **{key: False for key in NON_ACCEPTANCE}}
    try:
        common.execute()
        execution = json.loads((OUTPUT / "execution.json").read_bytes())
        raw = (OUTPUT / "jsonpath-rule-golden.json").read_bytes()
        verdict = verify(json.loads(raw), json.loads(FIXTURE.read_bytes()),
                         hashlib.sha256(FIXTURE.read_bytes()).hexdigest(), execution["referenceRunId"])
        verdict["reportSHA256"] = hashlib.sha256(raw).hexdigest()
    except Exception as error:
        verdict["failure"] = type(error).__name__ + ": " + str(error)
        raise
    finally:
        common.write_json(OUTPUT / "jsonpath-verification.json", verdict)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("stage", "execute"))
    if parser.parse_args().command == "stage":
        stage()
    else:
        execute()


if __name__ == "__main__":
    main()
