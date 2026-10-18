#!/usr/bin/env python3
"""Observe original scalar selection/replacement/unescape, without port acceptance."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import uuid


REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO / ".build/legado-scalar-selector-reference/source"
OUTPUT = REPO / ".build/ci-logs/scalar-selector-reference"
FIXTURE = REPO / "Packages/LegadoRuntime/jvm/src/test/resources/fixtures/scalar-selector-cases.json"
HARNESS = REPO / "tools/legado-reference/androidTest/ScalarSelectorGoldenTest.kt"
CLASS = "io.legado.app.reference.ScalarSelectorGoldenTest"
SUITE = "ScalarSelectorRuleObservation"
VERSION = "legado-scalar-selector-public-v1"
ARCHIVE = "724dedcac2427cd1f02ca00af1eab7156146e6d9d3141ca4c92042d04ed7bcdd"
APIS = ("getString-unescape-false", "getString-default")
CASE_IDS = ("css-unicode-group-replace", "css-element-joined-before-replace", "css-missing-skips-empty-replace",
            "css-attribute-whitespace", "xpath-document-text", "xpath-node-relative-text", "xpath-missing-empty-replace",
            "json-string-unicode-newline", "json-missing-empty-replace", "json-invalid-empty-replace",
            "json-null-empty-replace", "static-delimiter-whitespace", "entity-in-json-result",
            "entity-introduced-by-replacement")
ORIGINAL_SOURCES = {
    "app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeRule.kt":
        "5441d6d00064059519add3e5a81d85b1776f575bd0e5d30f3b5763d90af9e8a9",
    "app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeByJSoup.kt":
        "9889421f76a8fda62b0b874e70d0535f2b781b59a9c84fa797af695a9f8cccfa",
    "app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeByXPath.kt":
        "b6ee22cc3242313f8d5e3758dc93ff06891eeec7b3ab9ee9267ebac11145d842",
    "app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeByJSonPath.kt":
        "ee5ee9ebc95b4f5d6e2d459d6f727fccd10a6bd6a36ce872547f6cee5684109d",
    "app/src/main/java/io/legado/app/model/analyzeRule/RuleAnalyzer.kt":
        "74ab0152bce9d5e014cc69d9c6974cbb093d8353200f1452066f7d05102265a7",
    "app/src/main/java/io/legado/app/model/analyzeRule/SourceHtmlParser.kt":
        "252630eef2545dc71b3c30905accc93dc834b78bfff2f207769e2aabfd3ed19a",
}
CONTEXT_CLASSES = {"document": "java.lang.String", "css-element": "org.jsoup.nodes.Element",
                   "xpath-node": "org.seimicrawler.xpath.JXNode"}
NON_ACCEPTANCE = ("iosValidationPassed", "deviceValidationPassed", "compatibilityValidationPassed",
                  "g4ValidationPassed", "fullFeatureParityEstablished")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def common_driver():
    spec = importlib.util.spec_from_file_location("isolated_scalar_selector_reference_common", Path(__file__).with_name("run-reference.py"))
    common = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(common)
    common.SOURCE, common.OUTPUT = SOURCE, OUTPUT
    common.FIXTURE, common.HARNESS = FIXTURE, HARNESS
    common.STAGED_INIT_SCRIPT = SOURCE / "reference.init.gradle"
    common.TEST_CLASS = CLASS
    common.HARNESS_RELATIVE = "app/src/androidTest/java/io/legado/app/reference/ScalarSelectorGoldenTest.kt"
    common.FIXTURE_RELATIVE = "app/src/androidTest/assets/legado-reference/scalar-selector-cases.json"
    common.REMOTE_REPORT = "files/legado-reference/scalar-selector-golden.json"
    common.GOLDEN_FILENAME = "scalar-selector-golden.json"
    common.OBSERVED_FILENAME = "scalar-selector-observed.json"
    common.TEST_CONFIGURATION_OVERRIDES = {
        "cronet": "not exercised; original scalar AnalyzeRule methods only",
        "network": "not exercised; fixed public synthetic strings and public node selection only",
        "suite": SUITE + "; original mainJs, static-replacement and JSONPath suites remain separate",
        "passedMeaning": "All observations completed, including recorded original API exceptions; no port compatibility assertion",
    }
    return common


def validate_corpus(corpus):
    require(isinstance(corpus, dict) and type(corpus.get("schemaVersion")) is int and corpus["schemaVersion"] == 1,
            "Scalar selector corpus must use schemaVersion 1")
    require(corpus.get("suite") == SUITE and corpus.get("caseSetVersion") == VERSION
            and corpus.get("apis") == list(APIS), "Scalar selector corpus suite/version/API order differs")
    provenance = corpus.get("sourceProvenance")
    require(isinstance(provenance, dict) and provenance.get("archiveSHA256") == ARCHIVE,
            "Scalar selector corpus archive differs")
    files = provenance.get("files")
    require(isinstance(files, list) and len(files) == len(ORIGINAL_SOURCES)
            and all(isinstance(item, dict) and set(item) == {"path", "fileSHA256"} for item in files)
            and [item["path"] for item in files] == list(ORIGINAL_SOURCES)
            and all(item["fileSHA256"] == ORIGINAL_SOURCES[item["path"]] for item in files),
            "Scalar selector corpus must pin all six original business files")
    cases = corpus.get("cases")
    require(isinstance(cases, list) and len(cases) == len(CASE_IDS)
            and all(isinstance(item, dict) for item in cases)
            and [item.get("caseId") for item in cases] == list(CASE_IDS), "Scalar selector corpus requires the exact fourteen inputs")
    contexts = []
    for item in cases:
        require(set(item) == {"caseId", "content", "context", "rule"}
                and all(isinstance(item[key], str) for key in ("caseId", "content", "rule")),
                "Scalar selector fixture must contain inputs only, without expected/actual values")
        context = item["context"]
        require(isinstance(context, dict) and set(context) == {"kind", "rule", "index"}
                and context.get("kind") in CONTEXT_CLASSES and isinstance(context.get("rule"), str)
                and type(context.get("index")) is int and context["index"] == 0,
                "Scalar selector context is outside the fixed document/public-node setup")
        require((context["kind"] == "document" and context["rule"] == "")
                or (context["kind"] == "css-element" and context["rule"] == "tag.article")
                or (context["kind"] == "xpath-node" and context["rule"] == "//article"),
                "Scalar selector public node-setup rule differs")
        contexts.append(context["kind"])
        parts = item["rule"].strip("\x00\t\n\v\f\r ").split("##")
        require(len(parts) > 1 and parts[0].strip() and parts[1]
                and not any(token in item["rule"].lower() for token in ("@js:", "<js>", "<webjs>", "@webjs:", "@put:", "@get:", "{{"))
                and parts[0].strip().startswith(("@CSS:", "@XPath:", "@Json:")),
                "Scalar selector fixture requires static explicit selectors and nonempty patterns")
        if parts[0].strip().startswith("@Json:"):
            require(context["kind"] == "document" and isinstance(json.loads(item["content"]), dict),
                    "JSON selector observations require a String JSON-object context")
    require(contexts.count("css-element") == 1 and contexts.count("xpath-node") == 1,
            "Scalar selector corpus must retain both public node contexts")
    return cases


def ordinary_exception(value):
    require(isinstance(value, dict) and isinstance(value.get("className"), str) and value["className"]
            and "message" in value and (value["message"] is None or isinstance(value["message"], str)),
            "API exception must retain its original class and nullable message")
    hierarchy = value.get("classHierarchy")
    require(isinstance(hierarchy, list) and len(hierarchy) >= 3
            and all(isinstance(name, str) and name for name in hierarchy)
            and len(set(hierarchy)) == len(hierarchy) and hierarchy[0] == value["className"]
            and hierarchy[-2:] == ["java.lang.Throwable", "java.lang.Object"] and "java.lang.Exception" in hierarchy
            and not set(hierarchy).intersection({"java.lang.Error", "java.lang.VirtualMachineError", "java.lang.LinkageError", "java.lang.ThreadDeath"})
            and not (value["className"].startswith("java.") and value["className"].endswith("Error")),
            "VM, linkage, thread death and other Errors are observation failures, never API outcomes")


def verify(report, corpus, fixture_sha256, run_id):
    cases = validate_corpus(corpus)
    require(isinstance(report, dict) and type(report.get("schemaVersion")) is int and report["schemaVersion"] == 1,
            "Scalar selector report must use schemaVersion 1")
    require(isinstance(run_id, str) and str(uuid.UUID(run_id)) == run_id
            and report.get("referenceRunId") == run_id, "Scalar selector report lacks the current run identity")
    require(report.get("referenceKind") == "original-archive-android-instrumentation"
            and report.get("applicationClass") == "io.legado.app.App"
            and type(report.get("applicationMinSdkVersion")) is int and report["applicationMinSdkVersion"] == 26,
            "Scalar selector reference must execute the original Android application")
    require(report.get("suite") == SUITE and report.get("caseSetVersion") == VERSION
            and report.get("entryPoints") == list(APIS) and report.get("fixtureSHA256") == fixture_sha256
            and report.get("originalArchiveSHA256") == ARCHIVE
            and report.get("sourceProvenance") == corpus["sourceProvenance"], "Scalar selector report input/source provenance differs")
    expected = [(item, api) for item in cases for api in APIS]
    rows = report.get("observations")
    require(isinstance(rows, list) and len(rows) == len(expected), "Scalar selector report must retain all 28 observations")
    returns, exceptions = 0, 0
    for (item, api), row in zip(expected, rows):
        require(isinstance(row, dict) and row.get("api") == api
                and all(row.get(key) == item[key] for key in ("caseId", "content", "context", "rule")),
                "Scalar selector observation order/API/original inputs differ")
        require(row.get("setupCompleted") is True and row.get("apiInvoked") is True and row.get("completed") is True
                and row.get("observationFailure") is None
                and row.get("contextJavaClass") == CONTEXT_CLASSES[item["context"]["kind"]]
                and row.get("unescape") is (api == "getString-default")
                and row.get("defaultArgumentUsed") is (api == "getString-default")
                and all(key in row for key in ("actual", "javaClass", "exception", "observationFailure")),
                "Scalar selector setup/API observation is incomplete or omits explicit null/type/error fields")
        if row.get("outcome") == "exception":
            require(row["actual"] is None and row["javaClass"] is None,
                    "A thrown scalar API cannot have an invented returned value")
            ordinary_exception(row["exception"])
            exceptions += 1
        else:
            require(row.get("outcome") == "return" and type(row["actual"]) is str
                    and row["javaClass"] == "java.lang.String" and row["exception"] is None,
                    "Scalar API returns must remain original Strings without trimming or coercion")
            returns += 1
    require(report.get("passed") is True and report.get("failure") is None
            and all(type(report.get(key)) is int and report[key] == value for key, value in (
                ("total", len(expected)), ("executed", len(expected)), ("failed", 0),
                ("returnedObservations", returns), ("exceptionObservations", exceptions)))
            and all(report.get(key) is False for key in NON_ACCEPTANCE),
            "Only complete observation may pass; it cannot establish port/iOS/full parity")
    return {"passed": True, "observationComplete": True, "observationsVerified": len(expected),
            "returnedObservations": returns, "exceptionObservations": exceptions,
            "executionPlatform": "original-android-instrumentation", "fixtureSHA256": fixture_sha256,
            **{key: False for key in NON_ACCEPTANCE}}


def stage():
    common = common_driver()
    manifest = common.verify_original_files()
    validate_corpus(json.loads(FIXTURE.read_bytes()))
    require(manifest["originalArchiveSHA256"] == ARCHIVE, "Original snapshot archive identity differs")
    for path, expected in ORIGINAL_SOURCES.items():
        require(hashlib.sha256((SOURCE / path).read_bytes()).hexdigest() == expected,
                "Original scalar selector source bytes changed: " + path)
    common.stage()


def execute():
    common = common_driver()
    verdict = {"passed": False, "observationComplete": False, **{key: False for key in NON_ACCEPTANCE}}
    try:
        common.execute()
        execution = json.loads((OUTPUT / "execution.json").read_bytes())
        inputs = json.loads((OUTPUT / "reference-inputs.json").read_bytes())
        require(isinstance(execution.get("sourceCommit"), str)
                and re.fullmatch(r"[0-9a-f]{40}", execution["sourceCommit"])
                and execution["sourceCommit"] == inputs.get("sourceCommit")
                and execution.get("passed") is True and type(execution.get("instrumentationExitCode")) is int
                and execution["instrumentationExitCode"] == 0,
                "Scalar selector execution must bind the prepared checkout and successful instrumentation")
        raw = (OUTPUT / "scalar-selector-golden.json").read_bytes()
        verdict = verify(json.loads(raw), json.loads(FIXTURE.read_bytes()),
                         hashlib.sha256(FIXTURE.read_bytes()).hexdigest(), execution["referenceRunId"])
        verdict.update(reportSHA256=hashlib.sha256(raw).hexdigest(), sourceCommit=execution["sourceCommit"])
    except Exception as error:
        verdict["failure"] = type(error).__name__ + ": " + str(error)
        raise
    finally:
        common.write_json(OUTPUT / "scalar-selector-verification.json", verdict)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("stage", "execute"))
    if parser.parse_args().command == "stage":
        stage()
    else:
        execute()


if __name__ == "__main__":
    main()
