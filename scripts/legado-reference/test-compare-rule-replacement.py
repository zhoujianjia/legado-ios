#!/usr/bin/env python3
"""Synthetic comparison guards only; these tests do not execute either rule engine."""
from copy import deepcopy
import importlib.util
from pathlib import Path
import unittest


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("rule_compare_checked", HERE / "compare-rule-replacement.py")
checked = importlib.util.module_from_spec(spec); spec.loader.exec_module(checked)
fixture_spec = importlib.util.spec_from_file_location("rule_compare_synthetic_fixture", HERE / "test-rule-reference.py")
fixtures = importlib.util.module_from_spec(fixture_spec); fixture_spec.loader.exec_module(fixtures)
SHA = "c" * 40


def evidence():
    corpus, android = fixtures.synthetic_reference()
    port = {**deepcopy(android), "referenceKind": "ported-rule-kernel", "executionPlatform": "jvm-desktop",
            "sourceCommitKind": "caller-checkout-label", "sourceCommit": SHA, "jarSHA256": "d" * 64,
            "g4ValidationPassed": False}
    inputs = {"sourceCommit": SHA, "fixtureSHA256": "b" * 64, "harnessSHA256": "e" * 64,
              "originalArchiveSHA256": "a" * 64}
    execution = {"sourceCommit": SHA, "referenceRunId": fixtures.RUN, "passed": True}
    return android, port, corpus, inputs, execution


class RuleComparisonGuards(unittest.TestCase):
    def compare(self, objects):
        return checked.compare(*objects, "b" * 64, "e" * 64, SHA, "d" * 64)

    def test_complete_equal_evidence_matches_without_enabling_ios_or_integration(self):
        verdict = self.compare(evidence())
        self.assertTrue(verdict["passed"])
        self.assertEqual(verdict["casesCompared"], 2)
        self.assertFalse(verdict["iosValidationPassed"])
        self.assertFalse(verdict["declarativeSourceIntegrated"])

    def test_whitespace_newline_and_empty_string_differences_are_retained(self):
        for replacement in ("first", "first\r\n", "first\n "):
            objects = evidence(); objects[1]["cases"][0]["actual"] = replacement
            verdict = self.compare(objects)
            self.assertFalse(verdict["passed"])
            self.assertEqual(verdict["differenceCount"], 1)
            self.assertEqual(verdict["differences"][0]["ported"], replacement)

    def test_missing_changed_or_exception_case_never_becomes_a_success(self):
        for mutation in (lambda p: p["cases"].pop(), lambda p: p["cases"][0].update(exception={"className": "Error"}),
                         lambda p: p["cases"].reverse(), lambda p: p.update(executed=0),
                         lambda p: p.update(passed=1)):
            objects = evidence(); mutation(objects[1])
            with self.assertRaises(ValueError):
                self.compare(objects)

    def test_other_source_jar_platform_or_stale_android_result_is_rejected(self):
        for field, value in (("sourceCommit", "f" * 40), ("jarSHA256", "0" * 64),
                             ("executionPlatform", "ios-device"), ("fixtureSHA256", "wrong")):
            objects = evidence(); objects[1][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.compare(objects)
        objects = evidence(); objects[0]["referenceRunId"] = "stale"
        with self.assertRaises(ValueError):
            self.compare(objects)


if __name__ == "__main__":
    unittest.main()
