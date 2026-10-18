#!/usr/bin/env python3
"""Synthetic evidence guards only; these tests do not run Android or a JSONPath port."""
from copy import deepcopy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("jsonpath_reference_tested", HERE / "run-jsonpath-reference.py")
rules = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rules)
RUN = "12345678-1234-1234-1234-123456789012"


def synthetic_report():
    corpus = json.loads(rules.FIXTURE.read_bytes())
    rows = []
    for item in corpus["cases"]:
        for api in rules.APIS:
            value = "synthetic\n\u4e66\U0001f642" if api == "getString" else ["synthetic", ""]
            rows.append({**item, "api": api, "apiInvoked": True, "completed": True, "outcome": "return", "actual": value,
                         "javaClass": "java.lang.String" if isinstance(value, str) else "java.util.ArrayList",
                         "elementJavaClasses": None if isinstance(value, str) else ["java.lang.String"] * 2,
                         "exception": None})
    report = {"schemaVersion": 1, "suite": rules.SUITE, "caseSetVersion": rules.VERSION,
              "referenceKind": "original-archive-android-instrumentation", "referenceRunId": RUN,
              "applicationClass": "io.legado.app.App", "applicationMinSdkVersion": 26,
              "fixtureSHA256": "b" * 64, "originalArchiveSHA256": rules.ARCHIVE,
              "sourceProvenance": deepcopy(corpus["sourceProvenance"]), "entryPoints": list(rules.APIS),
              "passed": True, "total": 36, "executed": 36, "failed": 0,
              "returnedObservations": 36, "exceptionObservations": 0, "observations": rows,
              **{key: False for key in rules.NON_ACCEPTANCE}}
    return corpus, report


class JsonPathReferenceGuardTests(unittest.TestCase):
    def verify(self, report, corpus):
        return rules.verify(report, corpus, "b" * 64, RUN)

    def test_complete_observations_keep_original_inputs_and_never_accept_port_parity(self):
        corpus, report = synthetic_report()
        original = deepcopy(report)
        verdict = self.verify(report, corpus)
        self.assertTrue(verdict["observationComplete"])
        self.assertEqual(verdict["observationsVerified"], 36)
        self.assertEqual(report, original)
        self.assertIn("\u4e66", corpus["cases"][0]["jsonText"])
        self.assertIn("\U0001f642", corpus["cases"][0]["jsonText"])
        self.assertIn(" && ", corpus["cases"][-1]["rule"])
        self.assertTrue(all(verdict[key] is False for key in rules.NON_ACCEPTANCE))

    def test_original_api_exception_is_an_explicit_completed_outcome_not_a_failure_to_collect(self):
        corpus, report = synthetic_report()
        report["observations"][0].update(outcome="exception", actual=None, javaClass=None, elementJavaClasses=None,
            exception={"className": "com.jayway.jsonpath.PathNotFoundException", "message": None,
                       "classHierarchy": ["com.jayway.jsonpath.PathNotFoundException", "com.jayway.jsonpath.JsonPathException",
                                          "java.lang.RuntimeException", "java.lang.Exception", "java.lang.Throwable", "java.lang.Object"]})
        report.update(returnedObservations=35, exceptionObservations=1)
        verdict = self.verify(report, corpus)
        self.assertEqual(verdict["exceptionObservations"], 1)
        self.assertFalse(verdict["compatibilityValidationPassed"])

    def test_setup_failure_and_fatal_errors_cannot_be_promoted_to_completed_api_exceptions(self):
        corpus, original = synthetic_report()
        for fatal, parent in (("java.lang.OutOfMemoryError", "java.lang.VirtualMachineError"),
                              ("java.lang.StackOverflowError", "java.lang.VirtualMachineError"),
                              ("java.lang.NoClassDefFoundError", "java.lang.LinkageError"),
                              ("java.lang.UnsatisfiedLinkError", "java.lang.LinkageError"),
                              ("java.lang.ThreadDeath", "java.lang.Error")):
            report = deepcopy(original)
            report["observations"][0].update(outcome="exception", actual=None, javaClass=None, elementJavaClasses=None,
                exception={"className": fatal, "message": "fatal synthetic guard input",
                           "classHierarchy": list(dict.fromkeys([fatal, parent, "java.lang.Error", "java.lang.Throwable", "java.lang.Object"]))})
            report.update(returnedObservations=35, exceptionObservations=1)
            with self.subTest(fatal=fatal), self.assertRaisesRegex(ValueError, "never ordinary API"):
                self.verify(report, corpus)
        report = deepcopy(original)
        report["observations"][0].update(apiInvoked=False, outcome="exception", actual=None, javaClass=None, elementJavaClasses=None,
            exception={"className": "java.lang.IllegalStateException", "message": "constructor setup failed",
                       "classHierarchy": ["java.lang.IllegalStateException", "java.lang.RuntimeException", "java.lang.Exception",
                                          "java.lang.Throwable", "java.lang.Object"]})
        report.update(returnedObservations=35, exceptionObservations=1)
        with self.assertRaisesRegex(ValueError, "observation is incomplete"):
            self.verify(report, corpus)

    def test_null_empty_and_mixed_element_types_are_preserved_without_stringification(self):
        corpus, report = synthetic_report()
        rows = report["observations"]
        rows[0].update(actual="", javaClass="java.lang.String")
        rows[3].update(actual=None, javaClass=None)
        rows[5].update(actual=["line\n", 2, True, None, {"x": 1}],
            elementJavaClasses=["java.lang.String", "java.lang.Integer", "java.lang.Boolean", None, "java.util.LinkedHashMap"])
        self.verify(report, corpus)
        self.assertIs(rows[5]["actual"][2], True)
        self.assertIsNone(rows[5]["actual"][3])
        self.assertEqual(rows[0]["actual"], "")

    def test_stale_metadata_source_hashes_or_claimed_compatibility_are_rejected(self):
        corpus, original = synthetic_report()
        for key, value in (("referenceRunId", "stale"), ("fixtureSHA256", "c" * 64),
                           ("applicationClass", "replacement.App"), ("applicationMinSdkVersion", 23),
                           ("originalArchiveSHA256", "a" * 64), ("caseSetVersion", "changed"),
                           ("referenceKind", "ported-rule-kernel"), ("entryPoints", list(reversed(rules.APIS))),
                           *[(key, True) for key in rules.NON_ACCEPTANCE]):
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.verify({**original, key: value}, corpus)
        report = deepcopy(original)
        report["sourceProvenance"]["files"][1]["fileSHA256"] = "0" * 64
        with self.assertRaises(ValueError):
            self.verify(report, corpus)

    def test_incomplete_duplicate_reordered_or_wrong_input_observations_cannot_pass(self):
        corpus, original = synthetic_report()
        for key, value in (("observations", []), ("executed", 35), ("executed", True),
                           ("total", 0), ("failed", 1), ("passed", 1), ("exceptionObservations", 1)):
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.verify({**original, key: value}, corpus)
        for key, value in (("caseId", "wrong"), ("jsonText", "{}"), ("rule", "$.other"),
                           ("api", "getObject"), ("completed", False), ("observationFailure", {"className": "Error"})):
            report = deepcopy(original); report["observations"][0][key] = value
            with self.subTest(field=key), self.assertRaises(ValueError):
                self.verify(report, corpus)
        report = deepcopy(original); report["observations"][1] = deepcopy(report["observations"][0])
        with self.assertRaises(ValueError):
            self.verify(report, corpus)

    def test_missing_null_fields_bad_element_classes_or_nonfinite_json_cannot_pass(self):
        corpus, original = synthetic_report()
        for key in ("actual", "javaClass", "elementJavaClasses", "exception"):
            report = deepcopy(original); report["observations"][0].pop(key)
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.verify(report, corpus)
        for changes in ({"elementJavaClasses": ["java.lang.String"]},
                        {"elementJavaClasses": [None, "java.lang.String"]}, {"actual": float("nan")},
                        {"javaClass": None}, {"outcome": "unknown"}):
            report = deepcopy(original); report["observations"][2].update(changes)
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.verify(report, corpus)

    def test_corpus_cannot_preload_outputs_change_api_order_or_original_source_hashes(self):
        corpus, _ = synthetic_report()
        for key, value in (("actual", "invented"), ("expected", "invented"), ("rule", ""), ("jsonText", "not-json")):
            changed = deepcopy(corpus); changed["cases"][0][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                rules.validate_corpus(changed)
        changed = deepcopy(corpus); changed["apis"].reverse()
        with self.assertRaises(ValueError): rules.validate_corpus(changed)
        changed = deepcopy(corpus); changed["cases"].pop()
        with self.assertRaises(ValueError): rules.validate_corpus(changed)
        changed = deepcopy(corpus); changed["sourceProvenance"]["files"][2]["path"] = "other.kt"
        with self.assertRaises(ValueError): rules.validate_corpus(changed)

    def test_private_driver_leaves_existing_mainjs_and_replacement_protocols_unchanged(self):
        isolated = rules.common_driver()
        spec = importlib.util.spec_from_file_location("mainjs_driver_unchanged", HERE / "run-reference.py")
        mainjs = importlib.util.module_from_spec(spec); spec.loader.exec_module(mainjs)
        spec = importlib.util.spec_from_file_location("replacement_driver_unchanged", HERE / "run-rule-reference.py")
        replacement = importlib.util.module_from_spec(spec); spec.loader.exec_module(replacement)
        self.assertEqual(mainjs.GOLDEN_FILENAME, "android-golden.json")
        self.assertEqual(replacement.common_driver().GOLDEN_FILENAME, "rule-replacement-golden.json")
        self.assertEqual(isolated.GOLDEN_FILENAME, "jsonpath-rule-golden.json")
        self.assertEqual(isolated.TEST_CLASS, rules.CLASS)
        self.assertNotIn(isolated.SOURCE, (mainjs.SOURCE, replacement.SOURCE))
        self.assertNotIn(isolated.OUTPUT, (mainjs.OUTPUT, replacement.OUTPUT))

    def test_stage_checks_all_three_source_bytes_before_writing_overlays(self):
        corpus, _ = synthetic_report()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); hashes = {}
            for index, path in enumerate(rules.ORIGINAL_SOURCES):
                source = root / path; source.parent.mkdir(parents=True, exist_ok=True)
                source.write_bytes(b"synthetic provenance unit test " + bytes([index]))
                hashes[path] = hashlib.sha256(source.read_bytes()).hexdigest()
            for item in corpus["sourceProvenance"]["files"]: item["fileSHA256"] = hashes[item["path"]]
            fixture = root / "fixture.json"; fixture.write_text(json.dumps(corpus), encoding="utf-8")
            staged = []
            common = SimpleNamespace(verify_original_files=lambda: {"originalArchiveSHA256": rules.ARCHIVE},
                                     stage=lambda: staged.append(True))
            with patch.object(rules, "SOURCE", root), patch.object(rules, "FIXTURE", fixture), \
                    patch.object(rules, "ORIGINAL_SOURCES", hashes), patch.object(rules, "common_driver", return_value=common):
                rules.stage()
                self.assertEqual(staged, [True])
                for path in hashes:
                    source = root / path; original = source.read_bytes(); source.write_bytes(b"changed")
                    with self.subTest(path=path), self.assertRaisesRegex(ValueError, "source bytes changed"):
                        rules.stage()
                    source.write_bytes(original)
                self.assertEqual(staged, [True])

    def test_failed_original_execution_keeps_a_partial_failed_verdict(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); common = rules.common_driver()
            common.execute = lambda: (_ for _ in ()).throw(RuntimeError("original observation failed"))
            with patch.object(rules, "OUTPUT", root), patch.object(rules, "common_driver", return_value=common):
                with self.assertRaisesRegex(RuntimeError, "observation failed"): rules.execute()
            verdict = json.loads((root / "jsonpath-verification.json").read_bytes())
            self.assertFalse(verdict["passed"])
            self.assertFalse(verdict["observationComplete"])
            self.assertTrue(all(verdict[key] is False for key in rules.NON_ACCEPTANCE))


if __name__ == "__main__":
    unittest.main()
