#!/usr/bin/env python3
"""Portable reference-driver guards; no Android/iOS or rule implementation runs here."""
from copy import deepcopy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("isolated_rule_driver_tested", HERE / "run-rule-reference.py")
rules = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rules)
RUN = "12345678-1234-1234-1234-123456789012"


def synthetic_reference():
    corpus = {"schemaVersion": 1, "suite": "StaticRuleReplacement", "caseSetVersion": "legado-static-rule-replacement-v1",
              "sourceProvenance": {"archiveSHA256": "a" * 64},
              "cases": [{"caseId": "one", "text": "first\nsecond", "rule": "##second##"},
                        {"caseId": "two", "text": "none", "rule": "##missing##x###"}]}
    report = {"schemaVersion": 1, "suite": corpus["suite"], "caseSetVersion": corpus["caseSetVersion"],
              "referenceKind": "original-archive-android-instrumentation", "referenceRunId": RUN,
              "applicationClass": "io.legado.app.App", "applicationMinSdkVersion": 26,
              "fixtureSHA256": "b" * 64, "originalArchiveSHA256": "a" * 64,
              "sourceProvenance": deepcopy(corpus["sourceProvenance"]), "passed": True,
              "iosValidationPassed": False, "total": 2, "executed": 2, "failed": 0,
              "cases": [{**corpus["cases"][0], "passed": True, "actual": "first\n"},
                        {**corpus["cases"][1], "passed": True, "actual": ""}]}
    return corpus, report


class RuleReferenceGuardTests(unittest.TestCase):
    def verify(self, report, corpus):
        return rules.verify(report, corpus, "b" * 64, RUN)

    def test_complete_original_results_preserve_newlines_and_empty_strings(self):
        corpus, report = synthetic_reference()
        verdict = self.verify(report, corpus)
        self.assertEqual(verdict["casesVerified"], 2)
        self.assertFalse(verdict["iosValidationPassed"])
        self.assertFalse(verdict["g4ValidationPassed"])

    def test_missing_stale_or_mismatched_reference_identity_is_rejected(self):
        corpus, report = synthetic_reference()
        for key, replacement in (("referenceRunId", "stale"), ("fixtureSHA256", "changed"),
                                 ("originalArchiveSHA256", "wrong"), ("applicationClass", "replacement.App"),
                                 ("applicationMinSdkVersion", 23), ("caseSetVersion", "changed")):
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.verify({**report, key: replacement}, corpus)

    def test_case_order_and_original_text_or_rule_cannot_be_substituted(self):
        corpus, original = synthetic_reference()
        for key, replacement in (("caseId", "two"), ("text", "firstsecond"), ("rule", "##other##")):
            report = deepcopy(original); report["cases"][0][key] = replacement
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.verify(report, corpus)
        report = deepcopy(original); report["cases"].reverse()
        with self.assertRaises(ValueError):
            self.verify(report, corpus)

    def test_zero_partial_failed_or_exception_cases_cannot_pass(self):
        corpus, original = synthetic_reference()
        for key, replacement in (("cases", []), ("executed", 0), ("executed", True), ("failed", 1), ("passed", 1)):
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.verify({**original, key: replacement}, corpus)
        report = deepcopy(original); report["cases"][0]["exception"] = {"className": "Error", "message": "failed"}
        with self.assertRaises(ValueError):
            self.verify(report, corpus)
        report = deepcopy(original); report["cases"][0].pop("actual")
        with self.assertRaises(ValueError):
            self.verify(report, corpus)
        report = deepcopy(original); report["cases"][0]["passed"] = False
        with self.assertRaises(ValueError):
            self.verify(report, corpus)
        with self.assertRaises(ValueError):
            self.verify({**original, "failure": "contradictory failure"}, corpus)

    def test_isolated_configuration_does_not_change_mainjs_driver_defaults(self):
        isolated = rules.common_driver()
        spec = importlib.util.spec_from_file_location("original_driver_defaults_checked", HERE / "run-reference.py")
        original = importlib.util.module_from_spec(spec); spec.loader.exec_module(original)
        self.assertEqual(original.TEST_CLASS, "io.legado.app.reference.LegadoGoldenTraceTest")
        self.assertEqual(original.GOLDEN_FILENAME, "android-golden.json")
        self.assertEqual(original.FIXTURE.name, "main-source.js")
        self.assertEqual(isolated.TEST_CLASS, rules.CLASS)
        self.assertEqual(isolated.GOLDEN_FILENAME, "rule-replacement-golden.json")
        self.assertNotEqual(isolated.SOURCE, original.SOURCE)
        self.assertNotEqual(isolated.OUTPUT, original.OUTPUT)

    def test_failed_execution_retains_an_independent_failed_verdict(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            common = rules.common_driver()
            common.execute = lambda: (_ for _ in ()).throw(RuntimeError("original instrumentation failed"))
            with patch.object(rules, "OUTPUT", root), patch.object(rules, "common_driver", return_value=common):
                with self.assertRaisesRegex(RuntimeError, "instrumentation failed"):
                    rules.execute()
            verdict = json.loads((root / "rule-verification.json").read_bytes())
            self.assertFalse(verdict["passed"])
            self.assertIn("instrumentation failed", verdict["failure"])

    def test_staging_binds_corpus_to_the_actual_original_rule_source_before_writing(self):
        import hashlib
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = root / rules.ORIGINAL_RULE_PATH
            original.parent.mkdir(parents=True)
            original.write_bytes(b"synthetic original source bytes for provenance test")
            corpus = {"sourceProvenance": {"archiveSHA256": "a" * 64, "path": rules.ORIGINAL_RULE_PATH,
                      "fileSHA256": hashlib.sha256(original.read_bytes()).hexdigest()}}
            fixture = root / "fixture.json"
            staged = []
            common = SimpleNamespace(verify_original_files=lambda: {"originalArchiveSHA256": "a" * 64},
                                     stage=lambda: staged.append(True))
            with patch.object(rules, "SOURCE", root), patch.object(rules, "FIXTURE", fixture), \
                    patch.object(rules, "common_driver", return_value=common):
                fixture.write_text(json.dumps(corpus), encoding="utf-8")
                rules.stage()
                self.assertEqual(staged, [True])
                for key, wrong in (("archiveSHA256", "wrong"), ("path", "unrelated.kt"), ("fileSHA256", "changed")):
                    changed = deepcopy(corpus); changed["sourceProvenance"][key] = wrong
                    fixture.write_text(json.dumps(changed), encoding="utf-8")
                    with self.subTest(key=key), self.assertRaises(ValueError):
                        rules.stage()
                self.assertEqual(staged, [True])


if __name__ == "__main__":
    unittest.main()
