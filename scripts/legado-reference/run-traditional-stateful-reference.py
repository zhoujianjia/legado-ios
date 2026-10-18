#!/usr/bin/env python3
"""Observe ordered original AnalyzeRule state; a complete observation is not port acceptance."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import uuid
import xml.etree.ElementTree as ET


REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO / ".build/legado-traditional-stateful-reference/source"
OUTPUT = REPO / ".build/ci-logs/traditional-stateful-reference"
FIXTURE = REPO / "Packages/LegadoRuntime/jvm/src/test/resources/fixtures/traditional-stateful-cases.json"
HARNESS = REPO / "tools/legado-reference/androidTest/TraditionalStatefulGoldenTest.kt"
CLASS = "io.legado.app.reference.TraditionalStatefulGoldenTest"
METHOD = "observeOriginalStatefulTraditionalRules"
SUITE = "TraditionalStatefulRuleObservation"
VERSION = "legado-traditional-stateful-public-v1"
ARCHIVE = "724dedcac2427cd1f02ca00af1eab7156146e6d9d3141ca4c92042d04ed7bcdd"
FIXTURE_SHA256 = "a7e0b23bc73c1a32c6d99466aebad25eee8e3c227e12e4d98efccb53d0008ddf"
APIS = ("getString-unescape-false", "getString-default", "getString-content-default", "getElements")
SCENARIO_IDS = (
    "original-javascript-array-normalization", "issue1180-textnodes-low-level", "issue1180-base64-low-level",
    "implicit-css-replacement-js-repeated", "inline-book-expression-cached-rule", "js-library-recursive-get-string",
    "recursive-get-elements-real-nodes", "ruledata-local-empty-and-false-put", "chapter-book-source-priority",
    "put-without-state-target", "set-content-preserves-state-invalidates-selectors",
    "explicit-source-global-sharing-and-isolation", "regex-mode-persists-after-set-content", "exception-preserves-earlier-put",
)
ORIGINAL_SOURCES = {
    "app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeRule.kt": "5441d6d00064059519add3e5a81d85b1776f575bd0e5d30f3b5763d90af9e8a9",
    "app/src/main/java/io/legado/app/model/analyzeRule/RuleData.kt": "ff9a0782fb27dfa69f8e914d2738afd6a14cbe77b6fe0d646c4c091f652fd311",
    "app/src/main/java/io/legado/app/model/analyzeRule/RuleDataInterface.kt": "4cec4e15b2769f9e1daf03e933a8198d5650a6053f023d499bee3e856ad4db56",
    "app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeByJSoup.kt": "9889421f76a8fda62b0b874e70d0535f2b781b59a9c84fa797af695a9f8cccfa",
    "app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeByXPath.kt": "b6ee22cc3242313f8d5e3758dc93ff06891eeec7b3ab9ee9267ebac11145d842",
    "app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeByJSonPath.kt": "ee5ee9ebc95b4f5d6e2d459d6f727fccd10a6bd6a36ce872547f6cee5684109d",
    "app/src/main/java/io/legado/app/data/entities/Book.kt": "b737391f3eec2404314212490f0efd7e9f18c114b51aaf9f4566c8f41cfe4338",
    "app/src/main/java/io/legado/app/data/entities/BaseBook.kt": "a27896e273ec222f1bfa626067e8827632868e5182022c18d179749bb87448b2",
    "app/src/main/java/io/legado/app/data/entities/BookChapter.kt": "2725ee89235677b28e8d4cf1e9ae847212e7524a9b418f7c0a195a4114bdabbd",
    "app/src/main/java/io/legado/app/data/entities/BaseSource.kt": "080160e06a23fdfc7f4dbe5975a370473eee5d13ad0638b46aa2075276516243",
    "app/src/main/java/io/legado/app/data/entities/BookSource.kt": "6f2e9b400f2417dc17e19969c386607097bc00c2dbde3e03ba8cad23811c8a3d",
    "app/src/main/java/io/legado/app/help/source/BaseSourceExtensions.kt": "96f90ee5e8919a6763cd7fa9c9bbaa08f7c279e437828f607bff0389f56dccce",
    "app/src/main/java/io/legado/app/model/SharedJsScope.kt": "9bb5bc9d4e39bd788a68605f04287f4079b7dbb1c75510aba24b8cdacd97016e",
    "app/src/main/java/io/legado/app/help/JsExtensions.kt": "b587bd35e58898a0197abedb352a2acbe8c1a3c5c24573d77d2b7a98b6d7be6c",
    "modules/rhino/src/main/java/com/script/rhino/RhinoScriptEngine.kt": "4a5d5d95a825046ef773518ddf927c12795f97300357afe4b05b8ecf610513d4",
    "modules/rhino/src/main/java/com/script/ScriptBindings.kt": "21ef4a04db05695463af9051f7c5457f67654c5c1d354f048e626fc295926b9c",
    "app/src/test/java/io/legado/app/model/analyzeRule/AnalyzeRuleElementsNormalizationTest.kt": "355d38a19ade40c26b7560b5765d24c30d8ca249a883ac0fc48ac4c376536556",
    "app/src/androidTest/java/io/legado/app/model/webBook/SourceContentCompatibilityTest.kt": "de739d7d4ee89af57f946853b3b6f6b56939a9ead1419ea43abbd1d31361cb9c",
    "app/src/androidTest/assets/issue1180-content-rules.json": "bf290c4fb3e428c269b27004c7e57a6d079befba92f28859332e17e4e82a32fa",
}
NON_ACCEPTANCE = ("iosValidationPassed", "deviceValidationPassed", "compatibilityValidationPassed",
                  "g4ValidationPassed", "fullFeatureParityEstablished")
MODEL_CLASSES = {"rule-data": "io.legado.app.model.analyzeRule.RuleData", "book": "io.legado.app.data.entities.Book"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def common_driver():
    spec = importlib.util.spec_from_file_location("isolated_stateful_reference_common", Path(__file__).with_name("run-reference.py"))
    common = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(common)
    common.SOURCE, common.OUTPUT, common.FIXTURE, common.HARNESS = SOURCE, OUTPUT, FIXTURE, HARNESS
    common.STAGED_INIT_SCRIPT = SOURCE / "reference.init.gradle"
    common.TEST_CLASS = CLASS
    common.HARNESS_RELATIVE = "app/src/androidTest/java/io/legado/app/reference/TraditionalStatefulGoldenTest.kt"
    common.FIXTURE_RELATIVE = "app/src/androidTest/assets/legado-reference/traditional-stateful-cases.json"
    common.REMOTE_REPORT = "files/legado-reference/traditional-stateful-golden.json"
    common.GOLDEN_FILENAME = "traditional-stateful-golden.json"
    common.OBSERVED_FILENAME = "traditional-stateful-observed.json"
    common.TEST_CONFIGURATION_OVERRIDES = {
        "cronet": "not exercised; no network operation in fixed traditional-rule inputs",
        "network": "no HTTP; run-UUID-scoped .invalid origins identify original models and cache keys only",
        "suite": SUITE + "; original 18/36/28 and mainJs suites remain independent",
        "instanceLifetime": "one original object per fixture-declared ID; setup and calls execute in ordered steps without reset",
        "passedMeaning": "All declared steps observed, including ordinary API exceptions; not a port comparison",
    }
    return common


def string_map(value, message):
    require(isinstance(value, dict) and all(type(k) is str and type(v) is str for k, v in value.items()), message)


def validate_corpus(corpus):
    require(isinstance(corpus, dict) and set(corpus) == {"schemaVersion", "suite", "caseSetVersion", "apis", "originTemplate",
            "apiExceptionPolicy", "stepPolicy", "sourceProvenance", "scenarios"}, "Stateful corpus must contain only reviewed inputs")
    require(type(corpus["schemaVersion"]) is int and corpus["schemaVersion"] == 1 and corpus["suite"] == SUITE
            and corpus["caseSetVersion"] == VERSION and corpus["apis"] == list(APIS), "Stateful corpus suite/version/APIs differ")
    require(corpus["originTemplate"] == "https://traditional-stateful.invalid/{runId}/{scenarioId}/{sourceId}/",
            "Stateful origins must retain the current run UUID")
    provenance = corpus["sourceProvenance"]
    require(provenance == {"archiveSHA256": ARCHIVE, "files": [{"path": p, "fileSHA256": h} for p, h in ORIGINAL_SOURCES.items()]},
            "Stateful corpus must pin all nineteen original source/test/asset files")
    scenarios = corpus["scenarios"]
    require(isinstance(scenarios, list) and [x.get("scenarioId") for x in scenarios if isinstance(x, dict)] == list(SCENARIO_IDS),
            "Stateful corpus scenario order differs")
    for scenario in scenarios:
        require(set(scenario) == {"scenarioId", "provenance", "sources", "data", "chapters", "instances", "observedKeys", "steps"},
                "Scenario must contain only explicit graph/setup/ordered input steps")
        require(isinstance(scenario["provenance"], dict) and scenario["provenance"].get("kind") in
                ("original-test-input", "adapted-original-test-input", "synthetic-public-input"), "Scenario origin label missing")
        require(isinstance(scenario["observedKeys"], list) and len(set(scenario["observedKeys"])) == len(scenario["observedKeys"])
                and all(type(x) is str and x for x in scenario["observedKeys"]), "Observed keys must be explicit and unique")
        groups = {}
        for name, fields in (("sources", {"id", "jsLib", "variables"}), ("data", {"id", "kind", "name", "variables"}),
                ("chapters", {"id", "bookId", "title", "variables"}), ("instances", {"id", "dataId", "sourceId", "chapterId", "content"})):
            values = scenario[name]
            require(isinstance(values, list) and all(isinstance(x, dict) and set(x) == fields
                    and type(x["id"]) is str and re.fullmatch(r"[a-z][a-z0-9-]*", x["id"]) for x in values), "Declared graph fields/IDs differ")
            groups[name] = {x["id"]: x for x in values}
            require(len(groups[name]) == len(values), "Duplicate declared object ID")
            for value in values:
                if "variables" in value:
                    string_map(value["variables"], "Initial variables must retain exact Strings")
                    require(set(value["variables"]) <= set(scenario["observedKeys"]), "Initial variable not included in snapshots")
                if name == "sources": require(value["jsLib"] is None or type(value["jsLib"]) is str, "jsLib type differs")
                if name == "data": require(value["kind"] in MODEL_CLASSES and type(value["name"]) is str, "Unknown model kind/name")
                if name == "chapters": require(value["bookId"] in groups["data"] and groups["data"][value["bookId"]]["kind"] == "book"
                                               and type(value["title"]) is str, "Chapter requires an explicit original Book")
                if name == "instances":
                    require(type(value["content"]) is str and all(value[key] is None or value[key] in groups[group]
                        for key, group in (("dataId", "data"), ("sourceId", "sources"), ("chapterId", "chapters"))), "AnalyzeRule graph reference differs")
        require(groups["instances"], "Scenario needs at least one declared original AnalyzeRule")
        steps = scenario["steps"]
        require(isinstance(steps, list) and steps, "Ordered steps required")
        seen, previous_calls = set(), set()
        for step in steps:
            require(isinstance(step, dict) and type(step.get("stepId")) is str and step["stepId"] not in seen, "Unique ordered step IDs required")
            seen.add(step["stepId"])
            if step.get("kind") == "call":
                fields = {"stepId", "kind", "instanceId", "api", "rule"}
                if step.get("api") == "getString-content-default": fields.add("contentFromStep")
                require(set(step) == fields and step["instanceId"] in groups["instances"] and step["api"] in APIS
                        and type(step["rule"]) is str, "Unknown public call/input/instance")
                if "contentFromStep" in step: require(step["contentFromStep"] in previous_calls, "Content must reference a preceding explicit String call")
                previous_calls.add(step["stepId"])
            else:
                action = step.get("action")
                fields = {"stepId", "kind", "action"}
                extra = {"setContent": {"instanceId", "content"}, "setLocal": {"instanceId", "key", "value"},
                         "setBookName": {"dataId", "value"}, "putVariable": {"target", "targetId", "key", "value"}}
                require(step.get("kind") == "setup" and action in extra and set(step) == fields | extra[action], "Unreviewed setup operation")
                if "instanceId" in step: require(step["instanceId"] in groups["instances"], "Setup instance missing")
                if action == "setBookName": require(step["dataId"] in groups["data"] and groups["data"][step["dataId"]]["kind"] == "book", "Rename requires original Book")
                if action == "putVariable": require(step["target"] in ("data", "chapter") and step["targetId"] in groups["data" if step["target"] == "data" else "chapters"], "Variable target missing")
                if "key" in step: require(step["key"] in scenario["observedKeys"], "Mutation key absent from snapshots")
                for key in ("content", "value"):
                    if key in step: require(type(step[key]) is str or (action == "putVariable" and step[key] is None), "Setup String/null value differs")
    return scenarios


def origin(run_id, scenario, object_id):
    return f"https://traditional-stateful.invalid/{run_id}/{scenario['scenarioId']}/{object_id}/"


def typed(value):
    require(isinstance(value, dict) and type(value.get("kind")) is str and "javaClass" in value, "Typed original return omitted")
    kind, java_class = value["kind"], value["javaClass"]
    if kind == "null": require(value == {"kind": "null", "javaClass": None, "value": None}, "Explicit null return differs")
    elif kind in ("string", "boolean", "number"):
        require(set(value) == {"kind", "javaClass", "value"}, "Scalar typed fields differ")
        require((kind == "string" and java_class == "java.lang.String" and type(value["value"]) is str)
                or (kind == "boolean" and java_class == "java.lang.Boolean" and type(value["value"]) is bool)
                or (kind == "number" and java_class in {"java.lang.Integer", "java.lang.Double", "java.lang.Long", "java.lang.Float", "java.lang.Short", "java.lang.Byte"}
                    and type(value["value"]) is str and value["value"]), "Returned Java scalar type/value must not be coerced")
    elif kind == "element":
        require(set(value) == {"kind", "javaClass", "outerHTML", "text"} and java_class == "org.jsoup.nodes.Element"
                and type(value["outerHTML"]) is str and type(value["text"]) is str, "Real node class/outerHTML/text required")
    elif kind == "list":
        require(set(value) == {"kind", "javaClass", "items"} and type(java_class) is str and java_class
                and isinstance(value["items"], list), "Original List class/items required")
        for item in value["items"]: typed(item)
    else: raise ValueError("Unknown returned Java type must fail observation")


def ordinary_exception(value, depth=0):
    require(depth < 32 and isinstance(value, dict) and set(value) == {"className", "message", "classHierarchy", "cause"}
            and type(value["className"]) is str and (value["message"] is None or type(value["message"]) is str), "Original exception class/message/cause required")
    hierarchy = value["classHierarchy"]
    require(isinstance(hierarchy, list) and len(hierarchy) >= 4 and all(type(x) is str and x for x in hierarchy)
            and len(set(hierarchy)) == len(hierarchy) and hierarchy[0] == value["className"]
            and hierarchy[-2:] == ["java.lang.Throwable", "java.lang.Object"] and "java.lang.Exception" in hierarchy
            and "java.lang.Error" not in hierarchy, "Errors are observation failures, never ordinary API outcomes")
    if value["cause"] is not None: ordinary_exception(value["cause"], depth + 1)


def snapshot(value, scenario, run_id):
    require(isinstance(value, dict) and set(value) == {"sources", "data", "chapters", "instances"}, "Complete model/source/instance snapshot required")
    keys = scenario["observedKeys"]
    for group in ("sources", "data", "chapters", "instances"):
        require(isinstance(value[group], dict) and set(value[group]) == {x["id"] for x in scenario[group]}, "Snapshot object graph differs")
        for definition in scenario[group]:
            item = value[group][definition["id"]]
            require(isinstance(item, dict) and "objectIdentityHashCode" not in item, "Process identity metadata must remain outside semantic state")
            expected_class = {"sources": "io.legado.app.data.entities.BookSource", "chapters": "io.legado.app.data.entities.BookChapter",
                              "instances": "io.legado.app.model.analyzeRule.AnalyzeRule"}.get(group)
            if group == "data": expected_class = MODEL_CLASSES[definition["kind"]]
            require(item.get("javaClass") == expected_class, "Original Java model/host FQN must not be renamed")
            variable_field = "variables" if group == "sources" else "resolvedPublicReads" if group == "instances" else "effectiveVariables"
            string_map(item.get(variable_field), "Exact variable Strings required")
            require(set(item[variable_field]) == set(keys), "Observed variable keys are missing")
            if group == "sources": require(item.get("url") == origin(run_id, scenario, definition["id"]), "Source URL must retain this run UUID")
            if group in ("data", "chapters"):
                string_map(item.get("variableMap"), "Original variableMap required, including empty Strings")
                require("serializedVariable" in item and (item["serializedVariable"] is None or type(item["serializedVariable"]) is str)
                        and all(k in item for k in ("name", "title", "bookUrl", "url")), "Serialized original model fields omitted")
                if group == "data" and definition["kind"] == "book":
                    require(item["bookUrl"] == origin(run_id, scenario, "models") + definition["id"] and type(item["name"]) is str, "Book identity/name differs")
                if group == "chapters":
                    require(item["bookUrl"] == origin(run_id, scenario, "models") + definition["bookId"]
                            and item["url"] == origin(run_id, scenario, "chapters") + definition["id"] and type(item["title"]) is str, "Chapter identity/title differs")


def verify_runtime_identity(value, scenario):
    require(isinstance(value, dict) and set(value) == {"identityHashCodes", "referenceEqualityToSetup"}, "Per-run identity diagnostics missing")
    for field in value:
        require(isinstance(value[field], dict) and set(value[field]) == {"sources", "data", "chapters", "instances"}, "Runtime identity graph differs")
        for group, items in value[field].items():
            require(isinstance(items, dict) and set(items) == {x["id"] for x in scenario[group]}, "Runtime identity object set differs")
            require(all(type(x) is int for x in items.values()) if field == "identityHashCodes" else all(x is True for x in items.values()),
                    "Objects must remain reference-equal to setup within this run")


def verify(report, corpus, fixture_sha256, run_id):
    scenarios = validate_corpus(corpus)
    require(isinstance(report, dict) and type(report.get("schemaVersion")) is int and report["schemaVersion"] == 1,
            "Stateful report schema differs")
    require(type(run_id) is str and str(uuid.UUID(run_id)) == run_id and report.get("referenceRunId") == run_id, "Current run UUID required")
    require(report.get("referenceKind") == "original-archive-android-instrumentation" and report.get("applicationClass") == "io.legado.app.App"
            and type(report.get("applicationMinSdkVersion")) is int and report["applicationMinSdkVersion"] == 26, "Original Android Application/minSdk required")
    require(report.get("suite") == SUITE and report.get("caseSetVersion") == VERSION and report.get("entryPoints") == list(APIS)
            and fixture_sha256 == FIXTURE_SHA256 and report.get("fixtureSHA256") == fixture_sha256
            and report.get("inputFixture") == corpus and report.get("originalArchiveSHA256") == ARCHIVE
            and report.get("sourceProvenance") == corpus["sourceProvenance"], "Original stateful input/source identity differs")
    runtime = report.get("runtime")
    require(isinstance(runtime, dict) and runtime.get("engineClass") == "com.script.rhino.RhinoScriptEngine"
            and runtime.get("contextClass") == "com.script.rhino.RhinoContext" and type(runtime.get("implementationVersion")) is str
            and runtime["implementationVersion"] and type(runtime.get("languageVersion")) is int
            and all(runtime.get(k) is True for k in ("interpretedMode", "e4xEnabled", "dynamicDefaultThisEnabled", "dynamicEvalRealmEnabled")),
            "Actual original configured Rhino context evidence required")
    rows = report.get("scenarios")
    require(isinstance(rows, list) and len(rows) == len(scenarios), "All original scenarios must be retained")
    returned = exceptions = completed_steps = 0
    for scenario, row in zip(scenarios, rows):
        require(isinstance(row, dict) and row.get("scenarioId") == scenario["scenarioId"] and row.get("input") == scenario
                and row.get("setupCompleted") is True and row.get("completed") is True and "setupFailure" in row and row["setupFailure"] is None,
                "Scenario setup/input/ordered completion differs")
        resolved = row.get("resolvedSetup")
        require(isinstance(resolved, dict) and set(resolved) == {"sources", "initialPutReturns", "initialState", "runtimeIdentity"}, "Resolved original setup missing")
        snapshot(resolved["initialState"], scenario, run_id)
        require(isinstance(resolved["sources"], dict) and set(resolved["sources"]) == {x["id"] for x in scenario["sources"]}, "Resolved source graph differs")
        for source in scenario["sources"]:
            item = resolved["sources"][source["id"]]
            require(isinstance(item, dict) and set(item) == {"javaClass", "url", "jsLib"}
                    and item.get("javaClass") == "io.legado.app.data.entities.BookSource"
                    and item.get("url") == origin(run_id, scenario, source["id"]) and item.get("jsLib") == source["jsLib"], "Resolved source identity/library differs")
        expected_puts = [(target, definition["id"], key) for group, target in (("sources", "source"), ("data", "data"), ("chapters", "chapter"))
                         for definition in scenario[group] for key in definition["variables"]]
        puts = resolved["initialPutReturns"]
        require(isinstance(puts, list) and len(puts) == len(expected_puts), "Every initial public put return must be retained")
        for item, (target, target_id, key) in zip(puts, expected_puts):
            require(isinstance(item, dict) and set(item) == {"target", "targetId", "key", "returned"}
                    and (item["target"], item["targetId"], item["key"]) == (target, target_id, key), "Initial public put order/target differs")
            typed(item["returned"])
            require(item["returned"]["kind"] == ("string" if target == "source" else "boolean"), "Original initial put return type differs")
        steps = row.get("steps")
        require(isinstance(steps, list) and len(steps) == len(scenario["steps"]), "All ordered stateful steps required")
        previous = resolved["initialState"]
        initial_identities = resolved["runtimeIdentity"]
        verify_runtime_identity(initial_identities, scenario)
        for expected, actual in zip(scenario["steps"], steps):
            require(isinstance(actual, dict) and actual.get("input") == expected and actual.get("stepId") == expected["stepId"]
                    and actual.get("setupCompleted") is True and actual.get("completed") is True
                    and all(k in actual for k in ("actual", "exception", "observationFailure", "before", "after"))
                    and actual["observationFailure"] is None, "Ordered step input/setup/completion differs")
            snapshot(actual["before"], scenario, run_id)
            snapshot(actual["after"], scenario, run_id)
            require(actual["before"] == previous, "Hidden reset, mutation or fresh instance between declared steps")
            identities = actual.get("runtimeIdentity")
            require(isinstance(identities, dict) and set(identities) == {"before", "after"}, "Per-run identity metadata required")
            for identity in identities.values():
                verify_runtime_identity(identity, scenario)
                require(identity == initial_identities, "Original object identity changed within this run's scenario")
            previous = actual["after"]
            if expected["kind"] == "setup":
                require(actual.get("apiInvoked") is False and actual.get("outcome") == "setup" and actual["exception"] is None,
                        "Setup cannot masquerade as a completed API exception")
                if expected["action"] == "putVariable":
                    typed(actual["actual"])
                    require(actual["actual"]["kind"] == "boolean", "Original putVariable Boolean return required")
                else: require(actual["actual"] is None, "Do not encode setter-returned object address strings")
            else:
                require(actual.get("apiInvoked") is True, "Original public API was not invoked")
                if actual.get("outcome") == "exception":
                    require(actual["actual"] is None, "Exception cannot invent a returned value")
                    ordinary_exception(actual["exception"])
                    exceptions += 1
                else:
                    require(actual.get("outcome") == "return" and actual["exception"] is None, "Original API outcome missing")
                    typed(actual["actual"])
                    require(actual["actual"]["kind"] == ("list" if expected["api"] == "getElements" else "string"), "Original public API return type differs")
                    returned += 1
            completed_steps += 1
        cleanup = row.get("cleanup")
        require(isinstance(cleanup, dict) and cleanup.get("completed") is True and cleanup.get("errors") == []
                and cleanup.get("sourceSharedStateRemoved") is True and cleanup.get("globalCacheCleared") is False
                and cleanup.get("keys") == scenario["observedKeys"]
                and cleanup.get("sourceURLs") == [origin(run_id, scenario, x["id"]) for x in scenario["sources"]], "Per-scenario bounded cleanup incomplete")
    total_calls = sum(step["kind"] == "call" for scenario in scenarios for step in scenario["steps"])
    require(report.get("passed") is True and report.get("failure") is None
            and all(type(report.get(k)) is int and report[k] == v for k, v in (("total", total_calls), ("executed", total_calls), ("failed", 0),
                    ("totalSteps", completed_steps), ("completedSteps", completed_steps), ("returnedObservations", returned), ("exceptionObservations", exceptions)))
            and all(report.get(k) is False for k in NON_ACCEPTANCE), "Complete observation cannot establish port/iOS/G4 parity")
    return {"passed": True, "observationComplete": True, "scenariosVerified": len(scenarios), "stepsVerified": completed_steps,
            "observationsVerified": total_calls, "returnedObservations": returned, "exceptionObservations": exceptions,
            "executionPlatform": "original-android-instrumentation", "fixtureSHA256": fixture_sha256,
            **{k: False for k in NON_ACCEPTANCE}}


def verify_junit(directory):
    files = sorted(directory.rglob("*.xml"))
    require(len(files) == 1, "Actual raw JUnit XML must identify exactly one report for this test")
    root = ET.parse(files[0]).getroot()
    require(root.tag == "testsuite" and root.get("name") == CLASS and root.get("tests") == "1"
            and all(root.get(k) == "0" for k in ("failures", "errors", "skipped")), "Actual raw JUnit suite must report one test with zero failures/errors/skips")
    cases = list(root.iter("testcase"))
    require(len(cases) == 1 and cases[0].get("classname") == CLASS and cases[0].get("name") == METHOD
            and not any(cases[0].find(x) is not None for x in ("failure", "error", "skipped")), "Actual raw JUnit XML must contain exactly this one successful test")
    return [{"path": p.relative_to(SOURCE).as_posix(), "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in files]


def stage():
    common = common_driver()
    manifest = common.verify_original_files()
    require(hashlib.sha256(FIXTURE.read_bytes()).hexdigest() == FIXTURE_SHA256, "Reviewed fixture bytes changed")
    validate_corpus(json.loads(FIXTURE.read_bytes()))
    require(manifest["originalArchiveSHA256"] == ARCHIVE, "Original archive identity differs")
    for path, expected in ORIGINAL_SOURCES.items():
        require(hashlib.sha256((SOURCE / path).read_bytes()).hexdigest() == expected, "Original source bytes changed: " + path)
    common.stage()


def execute():
    common = common_driver()
    verdict = {"passed": False, "observationComplete": False, **{k: False for k in NON_ACCEPTANCE}}
    try:
        common.execute()
        execution = json.loads((OUTPUT / "execution.json").read_bytes())
        inputs = json.loads((OUTPUT / "reference-inputs.json").read_bytes())
        require(type(execution.get("sourceCommit")) is str and re.fullmatch(r"[0-9a-f]{40}", execution["sourceCommit"])
                and execution["sourceCommit"] == inputs.get("sourceCommit") and execution.get("passed") is True
                and type(execution.get("instrumentationExitCode")) is int and execution["instrumentationExitCode"] == 0,
                "Stateful execution must bind successful instrumentation to the prepared checkout")
        raw = (OUTPUT / "traditional-stateful-golden.json").read_bytes()
        verdict = verify(json.loads(raw), json.loads(FIXTURE.read_bytes()), hashlib.sha256(FIXTURE.read_bytes()).hexdigest(), execution["referenceRunId"])
        verdict.update(rawJUnitXML=verify_junit(SOURCE / "app/build/outputs/androidTest-results"), reportSHA256=hashlib.sha256(raw).hexdigest(), sourceCommit=execution["sourceCommit"])
    except Exception as error:
        verdict.update(passed=False, observationComplete=False, failure=type(error).__name__ + ": " + str(error))
        raise
    finally:
        common.write_json(OUTPUT / "traditional-stateful-verification.json", verdict)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("stage", "execute"))
    if parser.parse_args().command == "stage": stage()
    else: execute()


if __name__ == "__main__":
    main()
