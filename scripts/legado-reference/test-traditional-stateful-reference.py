#!/usr/bin/env python3
"""Synthetic observation-protocol guards; never Android golden or port results."""
from copy import deepcopy
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("stateful_reference_tested", HERE / "run-traditional-stateful-reference.py")
rules = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rules)
RUN = "12345678-1234-1234-1234-123456789012"


def scalar(value, kind="string", java_class="java.lang.String"):
    return {"kind": kind, "javaClass": java_class, "value": value}


def identities(scenario):
    return {"identityHashCodes": {g: {d["id"]: i + 1 for i, d in enumerate(scenario[g])}
                                 for g in ("sources", "data", "chapters", "instances")},
            "referenceEqualityToSetup": {g: {d["id"]: True for d in scenario[g]}
                                        for g in ("sources", "data", "chapters", "instances")}}


def initial_state(scenario):
    keys = scenario["observedKeys"]
    value = {g: {} for g in ("sources", "data", "chapters", "instances")}
    for d in scenario["sources"]:
        value["sources"][d["id"]] = {"javaClass": "io.legado.app.data.entities.BookSource", "url": rules.origin(RUN, scenario, d["id"]),
                                     "variables": {k: d["variables"].get(k, "") for k in keys}}
    for group in ("data", "chapters"):
        for d in scenario[group]:
            book = group == "data" and d["kind"] == "book"
            chapter = group == "chapters"
            value[group][d["id"]] = {
                "javaClass": "io.legado.app.data.entities.BookChapter" if chapter else rules.MODEL_CLASSES[d["kind"]],
                "variableMap": deepcopy(d["variables"]), "effectiveVariables": {k: d["variables"].get(k, "") for k in keys},
                "serializedVariable": json.dumps(d["variables"]) if d["variables"] else None,
                "name": d["name"] if book else None, "title": d["title"] if chapter else None,
                "bookUrl": rules.origin(RUN, scenario, "models") + (d["bookId"] if chapter else d["id"]) if book or chapter else None,
                "url": rules.origin(RUN, scenario, "chapters") + d["id"] if chapter else None,
            }
    for d in scenario["instances"]:
        value["instances"][d["id"]] = {"javaClass": "io.legado.app.model.analyzeRule.AnalyzeRule",
                                        "resolvedPublicReads": {k: "synthetic-read" for k in keys}}
    return value


def synthetic_report():
    """Intentionally arbitrary semantic values: these guards assert protocol, not correctness."""
    corpus = json.loads(rules.FIXTURE.read_bytes())
    rows = []
    calls = steps = 0
    for scenario in corpus["scenarios"]:
        state, identity = initial_state(scenario), identities(scenario)
        puts = []
        for group, target in (("sources", "source"), ("data", "data"), ("chapters", "chapter")):
            for d in scenario[group]:
                for key, value in d["variables"].items():
                    puts.append({"target": target, "targetId": d["id"], "key": key,
                                 "returned": scalar(value) if target == "source" else scalar(True, "boolean", "java.lang.Boolean")})
        row = {"scenarioId": scenario["scenarioId"], "input": deepcopy(scenario), "setupCompleted": True,
               "completed": True, "setupFailure": None,
               "resolvedSetup": {"sources": {d["id"]: {"javaClass": "io.legado.app.data.entities.BookSource",
                    "url": rules.origin(RUN, scenario, d["id"]), "jsLib": d["jsLib"]} for d in scenario["sources"]},
                    "initialPutReturns": puts, "initialState": deepcopy(state), "runtimeIdentity": deepcopy(identity)},
               "steps": [], "cleanup": {"completed": True, "errors": [], "sourceSharedStateRemoved": True,
                    "globalCacheCleared": False, "keys": scenario["observedKeys"],
                    "sourceURLs": [rules.origin(RUN, scenario, d["id"]) for d in scenario["sources"]]}}
        for step in scenario["steps"]:
            is_call = step["kind"] == "call"
            actual = (scalar("  synthetic\n\u4e66\U0001f642&amp;lt;  ") if step.get("api") != "getElements"
                      else {"kind": "list", "javaClass": "java.util.ArrayList", "items": []}) if is_call else (
                          scalar(False, "boolean", "java.lang.Boolean") if step["action"] == "putVariable" else None)
            row["steps"].append({"stepId": step["stepId"], "input": deepcopy(step), "setupCompleted": True,
                "apiInvoked": is_call, "completed": True, "outcome": "return" if is_call else "setup",
                "actual": actual, "exception": None, "observationFailure": None,
                "before": deepcopy(state), "after": deepcopy(state),
                "runtimeIdentity": {"before": deepcopy(identity), "after": deepcopy(identity)}})
            calls += is_call
            steps += 1
        rows.append(row)
    return corpus, {"schemaVersion": 1, "suite": rules.SUITE, "caseSetVersion": rules.VERSION,
        "referenceKind": "original-archive-android-instrumentation", "referenceRunId": RUN,
        "applicationClass": "io.legado.app.App", "applicationMinSdkVersion": 26,
        "fixtureSHA256": rules.FIXTURE_SHA256, "originalArchiveSHA256": rules.ARCHIVE,
        "inputFixture": deepcopy(corpus), "sourceProvenance": deepcopy(corpus["sourceProvenance"]), "entryPoints": list(rules.APIS),
        "runtime": {"engineClass": "com.script.rhino.RhinoScriptEngine", "contextClass": "com.script.rhino.RhinoContext",
                    "implementationVersion": "synthetic-protocol-only", "languageVersion": 200,
                    "interpretedMode": True, "e4xEnabled": True, "dynamicDefaultThisEnabled": True, "dynamicEvalRealmEnabled": True},
        "passed": True, "total": calls, "executed": calls, "failed": 0, "totalSteps": steps, "completedSteps": steps,
        "returnedObservations": calls, "exceptionObservations": 0, "scenarios": rows, **{k: False for k in rules.NON_ACCEPTANCE}}


def exception(class_name="java.lang.IllegalArgumentException", cause=None):
    return {"className": class_name, "message": "raw\nexception message", "classHierarchy": [class_name,
        "java.lang.RuntimeException", "java.lang.Exception", "java.lang.Throwable", "java.lang.Object"], "cause": cause}


class TraditionalStatefulReferenceGuardTests(unittest.TestCase):
    def verify(self, report, corpus):
        return rules.verify(report, corpus, rules.FIXTURE_SHA256, RUN)

    def test_exact_fixture_is_input_only_14_scenarios_56_steps_47_calls_with_original_asset_bytes(self):
        corpus, report = synthetic_report()
        self.assertEqual(hashlib.sha256(rules.FIXTURE.read_bytes()).hexdigest(), rules.FIXTURE_SHA256)
        verdict = self.verify(report, corpus)
        self.assertEqual((verdict["scenariosVerified"], verdict["stepsVerified"], verdict["observationsVerified"]), (14, 56, 47))
        self.assertTrue(all(verdict[k] is False for k in rules.NON_ACCEPTANCE))
        self.assertEqual(len(rules.ORIGINAL_SOURCES), 19)
        for scenario in corpus["scenarios"]:
            self.assertNotIn("expected", scenario)
            self.assertNotIn("actual", scenario)
        self.assertEqual(corpus["scenarios"][0]["steps"][0]["rule"], "@js:[1, null, 2]")
        self.assertIn("BookContent", corpus["scenarios"][1]["provenance"]["adaptation"])
        asset_path = "app/src/androidTest/assets/issue1180-content-rules.json"
        with zipfile.ZipFile(rules.REPO / "Packages/LegadoRuntime/vendor/android-reference/source-snapshot.zip") as original:
            raw_asset = original.read(asset_path)
        self.assertEqual(hashlib.sha256(raw_asset).hexdigest(), rules.ORIGINAL_SOURCES[asset_path])
        asset = json.loads(raw_asset)
        for index in (0, 1):
            scenario = corpus["scenarios"][index + 1]
            self.assertEqual(scenario["steps"][0]["rule"], asset[index]["ruleContent"]["content"])
            self.assertEqual(scenario["steps"][1]["rule"], asset[index]["ruleContent"]["replaceRegex"])
        encoded = base64.b64encode("<p>正文第一段</p><p>正文第二段</p><p>喜欢测试书籍</p>".encode()).decode()
        self.assertEqual(corpus["scenarios"][2]["instances"][0]["content"], "<script>var content='" + encoded + "';</script>")

    def test_verifier_never_mutates_raw_strings_values_types_or_identity_metadata(self):
        corpus, report = synthetic_report()
        original = deepcopy(report)
        self.verify(report, corpus)
        self.assertEqual(report, original)
        self.assertTrue(report["scenarios"][1]["steps"][0]["actual"]["value"].startswith("  "))
        self.assertIn("&amp;lt;", report["scenarios"][1]["steps"][0]["actual"]["value"])
        self.assertNotIn("objectIdentityHashCode", report["scenarios"][0]["steps"][0]["before"]["instances"]["a"])

    def test_real_list_number_types_and_outerhtml_are_retained_without_node_tree_serialization(self):
        corpus, report = synthetic_report()
        report["scenarios"][0]["steps"][0]["actual"]["items"] = [scalar("1", "number", "java.lang.Integer"),
            scalar("2.0", "number", "java.lang.Double"), {"kind": "element", "javaClass": "org.jsoup.nodes.Element", "outerHTML": "<b>A &amp; B</b>", "text": "A & B"}]
        self.verify(report, corpus)
        for field, value in (("javaClass", "java.lang.Object"), ("outerHTML", None)):
            changed = deepcopy(report)
            changed["scenarios"][0]["steps"][0]["actual"]["items"][2][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError): self.verify(changed, corpus)
        changed = deepcopy(report); changed["scenarios"][0]["steps"][0]["actual"]["items"][0]["value"] = 1
        with self.assertRaises(ValueError): self.verify(changed, corpus)

    def test_ordinary_api_exception_and_cause_continue_as_observations(self):
        corpus, report = synthetic_report()
        row = report["scenarios"][-1]["steps"][0]
        row.update(outcome="exception", actual=None, exception=exception(cause=exception("java.lang.IllegalStateException")))
        report.update(returnedObservations=46, exceptionObservations=1)
        verdict = self.verify(report, corpus)
        self.assertEqual(verdict["exceptionObservations"], 1)
        self.assertTrue(report["scenarios"][-1]["steps"][1]["completed"])

    def test_error_setup_failure_and_missing_cause_cannot_masquerade_as_api_outcomes(self):
        corpus, report = synthetic_report()
        fatal = exception("java.lang.OutOfMemoryError")
        fatal["classHierarchy"] = ["java.lang.OutOfMemoryError", "java.lang.VirtualMachineError", "java.lang.Error", "java.lang.Throwable", "java.lang.Object"]
        for value in (fatal, exception(cause=fatal)):
            changed = deepcopy(report); changed["scenarios"][0]["steps"][0].update(outcome="exception", actual=None, exception=value)
            changed.update(returnedObservations=46, exceptionObservations=1)
            with self.subTest(cause=value.get("cause")), self.assertRaisesRegex(ValueError, "Errors"): self.verify(changed, corpus)
        changed = deepcopy(report); changed["scenarios"][0]["steps"][0]["setupCompleted"] = False
        with self.assertRaises(ValueError): self.verify(changed, corpus)
        changed = deepcopy(report); changed["scenarios"][0]["steps"][0].update(outcome="exception", actual=None, exception=exception())
        changed["scenarios"][0]["steps"][0]["exception"].pop("cause")
        with self.assertRaises(ValueError): self.verify(changed, corpus)

    def test_missing_empty_string_variable_serialized_field_or_original_model_class_fails(self):
        corpus, original = synthetic_report()
        for mutate in (
            lambda r: r["scenarios"][7]["steps"][0]["after"]["data"]["d"]["variableMap"].update(k=None),
            lambda r: r["scenarios"][7]["steps"][0]["after"]["data"]["d"].pop("serializedVariable"),
            lambda r: r["scenarios"][7]["steps"][0]["after"]["data"]["d"].update(javaClass="port.RuleData"),
            lambda r: r["scenarios"][7]["steps"][0]["after"]["instances"]["a"]["resolvedPublicReads"].pop("k"),
        ):
            changed = deepcopy(original); mutate(changed)
            with self.assertRaises(ValueError): self.verify(changed, corpus)

    def test_hidden_fresh_instance_reset_or_false_reference_equality_is_rejected_within_run(self):
        corpus, original = synthetic_report()
        for field in ("identityHashCodes", "referenceEqualityToSetup"):
            changed = deepcopy(original)
            changed["scenarios"][3]["steps"][1]["runtimeIdentity"]["after"][field]["instances"]["a"] = 99 if field == "identityHashCodes" else False
            with self.subTest(field=field), self.assertRaises(ValueError): self.verify(changed, corpus)
        changed = deepcopy(original)
        changed["scenarios"][3]["steps"][1]["before"]["data"]["d"]["variableMap"]["hidden"] = "reset"
        with self.assertRaisesRegex(ValueError, "Hidden reset"): self.verify(changed, corpus)

    def test_reordered_duplicated_or_omitted_steps_and_incorrect_overload_fail(self):
        corpus, original = synthetic_report()
        for mutate in (
            lambda r: r["scenarios"][3]["steps"].reverse(),
            lambda r: r["scenarios"][3]["steps"].pop(),
            lambda r: r["scenarios"][3]["steps"].__setitem__(1, deepcopy(r["scenarios"][3]["steps"][0])),
            lambda r: r["scenarios"][1]["steps"][1]["input"].update(api="getString-unescape-false"),
        ):
            changed = deepcopy(original); mutate(changed)
            with self.assertRaises(ValueError): self.verify(changed, corpus)

    def test_missing_uuid_source_hash_runtime_flags_or_false_acceptance_claim_fails(self):
        corpus, original = synthetic_report()
        for key, value in (("referenceRunId", "stale"), ("fixtureSHA256", "0"*64), ("originalArchiveSHA256", "0"*64),
                           ("applicationMinSdkVersion", 23), ("passed", 1), ("executed", True),
                           *[(k, True) for k in rules.NON_ACCEPTANCE]):
            with self.subTest(key=key), self.assertRaises(ValueError): self.verify({**original, key:value}, corpus)
        changed = deepcopy(original); changed["runtime"]["interpretedMode"] = False
        with self.assertRaises(ValueError): self.verify(changed, corpus)
        changed = deepcopy(original); changed["scenarios"][2]["resolvedSetup"]["sources"]["s"]["url"] = "https://fixture.invalid/"
        with self.assertRaises(ValueError): self.verify(changed, corpus)
        changed = deepcopy(original); changed["sourceProvenance"]["files"][0]["fileSHA256"] = "0"*64
        with self.assertRaises(ValueError): self.verify(changed, corpus)

    def test_setup_is_never_api_exception_or_address_string_and_cleanup_must_be_bounded(self):
        corpus, original = synthetic_report()
        for key, value in (("outcome", "exception"), ("apiInvoked", True), ("actual", "AnalyzeRule@abc")):
            changed = deepcopy(original); changed["scenarios"][4]["steps"][1][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): self.verify(changed, corpus)
        for key, value in (("completed", False), ("errors", [{"className":"synthetic"}]), ("globalCacheCleared", True), ("sourceSharedStateRemoved", False)):
            changed = deepcopy(original); changed["scenarios"][0]["cleanup"][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): self.verify(changed, corpus)

    def test_fixture_rejects_invented_outputs_undeclared_objects_forward_references_or_missing_pins(self):
        corpus, _ = synthetic_report()
        for mutate in (
            lambda c: c["scenarios"][0].update(expected="invented"),
            lambda c: c["scenarios"][0]["steps"][0].update(actual="invented"),
            lambda c: c["scenarios"][0]["instances"][0].update(sourceId="undeclared"),
            lambda c: c["scenarios"][1]["steps"][1].update(contentFromStep="future"),
            lambda c: c["sourceProvenance"]["files"].pop(),
        ):
            changed = deepcopy(corpus); mutate(changed)
            with self.assertRaises(ValueError): rules.validate_corpus(changed)

    def test_isolated_common_adapter_leaves_old_mainjs_and_18_36_28_protocols_unchanged(self):
        isolated = rules.common_driver()
        for filename, expected in (("run-reference.py","android-golden.json"), ("run-rule-reference.py","rule-replacement-golden.json"),
                                    ("run-jsonpath-reference.py","jsonpath-rule-golden.json"), ("run-scalar-selector-reference.py","scalar-selector-golden.json")):
            spec = importlib.util.spec_from_file_location("unchanged_stateful_"+filename, HERE/filename)
            old = importlib.util.module_from_spec(spec); spec.loader.exec_module(old)
            driver = old if filename == "run-reference.py" else old.common_driver()
            self.assertEqual(driver.GOLDEN_FILENAME, expected)
            self.assertNotEqual(driver.SOURCE, isolated.SOURCE)
            self.assertNotEqual(driver.OUTPUT, isolated.OUTPUT)

    def test_stage_checks_all_nineteen_original_bytes_before_adding_any_overlays(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); hashes={}
            for i,path in enumerate(rules.ORIGINAL_SOURCES):
                file=root/path; file.parent.mkdir(parents=True,exist_ok=True); file.write_bytes(b"synthetic staging "+bytes([i]))
                hashes[path]=hashlib.sha256(file.read_bytes()).hexdigest()
            corpus=json.loads(rules.FIXTURE.read_bytes())
            for item in corpus["sourceProvenance"]["files"]: item["fileSHA256"]=hashes[item["path"]]
            fixture=root/"fixture.json"; fixture.write_text(json.dumps(corpus),encoding="utf-8")
            staged=[]
            common=SimpleNamespace(verify_original_files=lambda:{"originalArchiveSHA256":rules.ARCHIVE},stage=lambda:staged.append(True))
            with patch.object(rules,"SOURCE",root), patch.object(rules,"ORIGINAL_SOURCES",hashes), patch.object(rules,"FIXTURE",fixture), \
                 patch.object(rules,"FIXTURE_SHA256",hashlib.sha256(fixture.read_bytes()).hexdigest()), patch.object(rules,"common_driver",return_value=common):
                rules.stage(); self.assertEqual(staged,[True])
                for path in hashes:
                    file=root/path; original=file.read_bytes(); file.write_bytes(b"changed")
                    with self.subTest(path=path),self.assertRaisesRegex(ValueError,"source bytes changed"): rules.stage()
                    file.write_bytes(original)
                self.assertEqual(staged,[True])

    def test_actual_junit_requires_one_exact_successful_case_not_just_report_passed(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); path=root/"TEST-result.xml"
            xml=f'<testsuite name="{rules.CLASS}" tests="1" failures="0" errors="0" skipped="0"><testcase classname="{rules.CLASS}" name="{rules.METHOD}"/></testsuite>'
            with patch.object(rules,"SOURCE",root):
                path.write_text(xml,encoding="utf-8"); self.assertEqual(len(rules.verify_junit(root)),1)
                for changed in (xml.replace(rules.METHOD,"other"),xml.replace("/>","><skipped/></testcase>"),xml.replace('errors="0"','errors="1"'),
                                xml.replace("</testsuite>",f'<testcase classname="{rules.CLASS}" name="{rules.METHOD}"/></testsuite>')):
                    path.write_text(changed,encoding="utf-8")
                    with self.assertRaises(ValueError): rules.verify_junit(root)
                path.unlink()
                with self.assertRaises(ValueError): rules.verify_junit(root)

    def test_failed_instrumentation_writes_non_accepting_partial_verdict(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); common=rules.common_driver()
            common.execute=lambda: (_ for _ in ()).throw(RuntimeError("original instrumentation failed"))
            with patch.object(rules,"OUTPUT",root),patch.object(rules,"common_driver",return_value=common):
                with self.assertRaisesRegex(RuntimeError,"instrumentation failed"): rules.execute()
            verdict=json.loads((root/"traditional-stateful-verification.json").read_bytes())
            self.assertFalse(verdict["passed"]); self.assertFalse(verdict["observationComplete"])
            self.assertTrue(all(verdict[k] is False for k in rules.NON_ACCEPTANCE))

    def test_execute_binds_current_prepared_commit_and_junit_then_rejects_stale_success(self):
        corpus, report=synthetic_report()
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); common=rules.common_driver(); common.execute=lambda:None
            def write(name,value): (root/name).write_text(json.dumps(value),encoding="utf-8")
            write("traditional-stateful-golden.json",report); write("reference-inputs.json",{"sourceCommit":"a"*40})
            execution={"sourceCommit":"a"*40,"passed":True,"instrumentationExitCode":0,"referenceRunId":RUN}
            write("execution.json",execution)
            with patch.object(rules,"OUTPUT",root),patch.object(rules,"common_driver",return_value=common),patch.object(rules,"verify_junit",return_value=[{"sha256":"synthetic"}]):
                rules.execute(); self.assertTrue(json.loads((root/"traditional-stateful-verification.json").read_bytes())["passed"])
                for key,value in (("sourceCommit","b"*40),("sourceCommit","short"),("passed",False),("instrumentationExitCode",False),("referenceRunId",str(__import__('uuid').uuid4()))):
                    write("execution.json",{**execution,key:value})
                    with self.subTest(key=key),self.assertRaises(ValueError): rules.execute()
                    self.assertFalse(json.loads((root/"traditional-stateful-verification.json").read_bytes())["passed"])
                write("execution.json",execution)
                with patch.object(rules,"verify_junit",side_effect=ValueError("missing raw XML")):
                    with self.assertRaisesRegex(ValueError,"raw XML"): rules.execute()
                self.assertFalse(json.loads((root/"traditional-stateful-verification.json").read_bytes())["observationComplete"])


if __name__ == "__main__":
    unittest.main()
