#!/usr/bin/env python3
"""Synthetic protocol guards; no Android output or port result is invented here."""
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
spec = importlib.util.spec_from_file_location("scalar_selector_reference_tested", HERE / "run-scalar-selector-reference.py")
rules = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rules)
RUN = "12345678-1234-1234-1234-123456789012"


def synthetic_report():
    corpus = json.loads(rules.FIXTURE.read_bytes())
    observations = []
    for item in corpus["cases"]:
        for api in rules.APIS:
            observations.append({**deepcopy(item), "api": api, "setupCompleted": True, "apiInvoked": True,
                "completed": True, "outcome": "return", "actual": "  synthetic\n\u4e66\U0001f642&amp;lt;  ",
                "javaClass": "java.lang.String", "exception": None, "observationFailure": None,
                "contextJavaClass": rules.CONTEXT_CLASSES[item["context"]["kind"]],
                "unescape": api == "getString-default", "defaultArgumentUsed": api == "getString-default"})
    report = {"schemaVersion": 1, "suite": rules.SUITE, "caseSetVersion": rules.VERSION,
        "referenceKind": "original-archive-android-instrumentation", "referenceRunId": RUN,
        "applicationClass": "io.legado.app.App", "applicationMinSdkVersion": 26,
        "fixtureSHA256": "b" * 64, "originalArchiveSHA256": rules.ARCHIVE,
        "sourceProvenance": deepcopy(corpus["sourceProvenance"]), "entryPoints": list(rules.APIS),
        "passed": True, "total": 28, "executed": 28, "failed": 0,
        "returnedObservations": 28, "exceptionObservations": 0, "observations": observations,
        **{key: False for key in rules.NON_ACCEPTANCE}}
    return corpus, report


class ScalarSelectorReferenceGuardTests(unittest.TestCase):
    def verify(self, report, corpus):
        return rules.verify(report, corpus, "b" * 64, RUN)

    def test_complete_28_observations_preserve_strings_context_and_do_not_claim_port_acceptance(self):
        corpus, report = synthetic_report()
        original = deepcopy(report)
        verdict = self.verify(report, corpus)
        self.assertEqual(report, original)
        self.assertTrue(verdict["observationComplete"])
        self.assertEqual(verdict["observationsVerified"], 28)
        self.assertTrue(all(verdict[key] is False for key in rules.NON_ACCEPTANCE))
        self.assertIn("\u4e66", report["observations"][0]["actual"])
        self.assertIn("\U0001f642", corpus["cases"][0]["content"])
        self.assertEqual([x["context"]["kind"] for x in corpus["cases"]].count("css-element"), 1)
        self.assertEqual([x["context"]["kind"] for x in corpus["cases"]].count("xpath-node"), 1)
        self.assertTrue(report["observations"][0]["actual"].startswith("  "))
        self.assertIn("&amp;lt;", report["observations"][0]["actual"])

    def test_ordinary_exception_is_observed_without_becoming_a_port_acceptance(self):
        corpus, report = synthetic_report()
        report["observations"][0].update(outcome="exception", actual=None, javaClass=None,
            exception={"className": "java.lang.IllegalArgumentException", "message": None,
                "classHierarchy": ["java.lang.IllegalArgumentException", "java.lang.RuntimeException",
                                   "java.lang.Exception", "java.lang.Throwable", "java.lang.Object"]})
        report.update(returnedObservations=27, exceptionObservations=1)
        self.assertEqual(self.verify(report, corpus)["exceptionObservations"], 1)

    def test_node_setup_failure_and_fatal_errors_cannot_be_completed_api_exceptions(self):
        corpus, original = synthetic_report()
        for flag in ("setupCompleted", "apiInvoked", "completed"):
            report = deepcopy(original); report["observations"][2][flag] = False
            with self.subTest(flag=flag), self.assertRaisesRegex(ValueError, "incomplete"):
                self.verify(report, corpus)
        for fatal, parent in (("java.lang.OutOfMemoryError", "java.lang.VirtualMachineError"),
                              ("java.lang.NoClassDefFoundError", "java.lang.LinkageError"),
                              ("java.lang.UnsatisfiedLinkError", "java.lang.LinkageError"),
                              ("java.lang.ThreadDeath", "java.lang.Error")):
            report = deepcopy(original)
            report["observations"][0].update(outcome="exception", actual=None, javaClass=None,
                exception={"className": fatal, "message": "synthetic fatal guard input",
                    "classHierarchy": list(dict.fromkeys([fatal, parent, "java.lang.Error", "java.lang.Throwable", "java.lang.Object"]))})
            report.update(returnedObservations=27, exceptionObservations=1)
            with self.subTest(fatal=fatal), self.assertRaisesRegex(ValueError, "never API outcomes"):
                self.verify(report, corpus)

    def test_missing_context_wrong_overload_or_default_argument_record_cannot_pass(self):
        corpus, original = synthetic_report()
        for key, value in (("contextJavaClass", "java.lang.String"), ("unescape", True),
                           ("defaultArgumentUsed", True), ("api", "getString-default"),
                           ("observationFailure", {"className": "setup failure"})):
            report = deepcopy(original)
            index = 2 if key == "contextJavaClass" else 0
            report["observations"][index][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): self.verify(report, corpus)

    def test_scalar_returns_cannot_silently_coerce_null_number_list_or_nonstring_class(self):
        corpus, original = synthetic_report()
        for actual in (None, 1, True, ["text"], {"text": "value"}):
            report = deepcopy(original); report["observations"][0]["actual"] = actual
            with self.subTest(actual=actual), self.assertRaisesRegex(ValueError, "original Strings"):
                self.verify(report, corpus)
        report = deepcopy(original); report["observations"][0]["javaClass"] = "java.lang.StringBuilder"
        with self.assertRaises(ValueError): self.verify(report, corpus)
        report = deepcopy(original); report["observations"][0].pop("exception")
        with self.assertRaises(ValueError): self.verify(report, corpus)
        report = deepcopy(original); report["observations"][0]["actual"] = ""
        self.verify(report, corpus)

    def test_stale_run_fixture_archive_source_or_acceptance_flags_are_rejected(self):
        corpus, original = synthetic_report()
        for key, value in (("referenceRunId", "stale"), ("fixtureSHA256", "c" * 64),
                           ("originalArchiveSHA256", "a" * 64), ("applicationClass", "replacement.App"),
                           ("applicationMinSdkVersion", 23), ("referenceKind", "ported-rule-kernel"),
                           ("entryPoints", list(reversed(rules.APIS))),
                           *[(key, True) for key in rules.NON_ACCEPTANCE]):
            with self.subTest(key=key), self.assertRaises(ValueError): self.verify({**original, key: value}, corpus)
        for index in range(6):
            report = deepcopy(original); report["sourceProvenance"]["files"][index]["fileSHA256"] = "0" * 64
            with self.subTest(source=index), self.assertRaises(ValueError): self.verify(report, corpus)

    def test_incomplete_duplicate_reordered_or_changed_original_inputs_cannot_pass(self):
        corpus, original = synthetic_report()
        for key, value in (("observations", []), ("executed", 27), ("executed", True),
                           ("failed", 1), ("passed", 1), ("returnedObservations", 27)):
            with self.subTest(key=key), self.assertRaises(ValueError): self.verify({**original, key: value}, corpus)
        for key, value in (("caseId", "other"), ("content", "different"), ("rule", "@CSS:p@text##x##y"),
                           ("context", {"kind": "document", "rule": "", "index": 1})):
            report = deepcopy(original); report["observations"][0][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): self.verify(report, corpus)
        report = deepcopy(original); report["observations"][1] = deepcopy(report["observations"][0])
        with self.assertRaises(ValueError): self.verify(report, corpus)

    def test_fixture_rejects_invented_outputs_dynamic_rules_or_changed_node_setup(self):
        corpus, _ = synthetic_report()
        for key in ("expected", "actual"):
            changed = deepcopy(corpus); changed["cases"][0][key] = "invented"
            with self.subTest(key=key), self.assertRaises(ValueError): rules.validate_corpus(changed)
        for context in ({"kind": "document", "rule": "", "index": True},
                        {"kind": "css-element", "rule": "tag.missing", "index": 0}):
            changed = deepcopy(corpus); changed["cases"][0]["context"] = context
            with self.subTest(context=context), self.assertRaises(ValueError): rules.validate_corpus(changed)
        for rule in ("@CSS:p@text##x##@js:result", "@CSS:p@text####replacement", "##x##y"):
            changed = deepcopy(corpus); changed["cases"][0]["rule"] = rule
            with self.subTest(rule=rule), self.assertRaises(ValueError): rules.validate_corpus(changed)
        changed = deepcopy(corpus); changed["sourceProvenance"]["files"].pop()
        with self.assertRaises(ValueError): rules.validate_corpus(changed)

    def test_private_common_adapter_does_not_modify_the_existing_three_suite_protocols(self):
        isolated = rules.common_driver()
        for filename, expected in (("run-reference.py", "android-golden.json"),
                                   ("run-rule-reference.py", "rule-replacement-golden.json"),
                                   ("run-jsonpath-reference.py", "jsonpath-rule-golden.json")):
            spec = importlib.util.spec_from_file_location("unchanged_" + filename, HERE / filename)
            original = importlib.util.module_from_spec(spec); spec.loader.exec_module(original)
            common = original if filename == "run-reference.py" else original.common_driver()
            self.assertEqual(common.GOLDEN_FILENAME, expected)
            self.assertNotEqual(common.SOURCE, isolated.SOURCE)
            self.assertNotEqual(common.OUTPUT, isolated.OUTPUT)
        self.assertEqual(isolated.TEST_CLASS, rules.CLASS)
        self.assertEqual(isolated.GOLDEN_FILENAME, "scalar-selector-golden.json")

    def test_stage_checks_all_six_source_bytes_before_writing_overlays(self):
        corpus, _ = synthetic_report()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); hashes = {}
            for index, path in enumerate(rules.ORIGINAL_SOURCES):
                source = root / path; source.parent.mkdir(parents=True, exist_ok=True)
                source.write_bytes(b"synthetic staging guard " + bytes([index]))
                hashes[path] = hashlib.sha256(source.read_bytes()).hexdigest()
            for item in corpus["sourceProvenance"]["files"]: item["fileSHA256"] = hashes[item["path"]]
            fixture = root / "fixture.json"; fixture.write_text(json.dumps(corpus), encoding="utf-8")
            staged = []
            common = SimpleNamespace(verify_original_files=lambda: {"originalArchiveSHA256": rules.ARCHIVE},
                                     stage=lambda: staged.append(True))
            with patch.object(rules, "SOURCE", root), patch.object(rules, "FIXTURE", fixture), \
                    patch.object(rules, "ORIGINAL_SOURCES", hashes), patch.object(rules, "common_driver", return_value=common):
                rules.stage(); self.assertEqual(staged, [True])
                for path in hashes:
                    source = root / path; original = source.read_bytes(); source.write_bytes(b"changed")
                    with self.subTest(path=path), self.assertRaisesRegex(ValueError, "source bytes changed"):
                        rules.stage()
                    source.write_bytes(original)
                self.assertEqual(staged, [True])

    def test_failed_original_instrumentation_retains_failed_partial_verdict(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); common = rules.common_driver()
            common.execute = lambda: (_ for _ in ()).throw(RuntimeError("original instrumentation failed"))
            with patch.object(rules, "OUTPUT", root), patch.object(rules, "common_driver", return_value=common):
                with self.assertRaisesRegex(RuntimeError, "instrumentation failed"): rules.execute()
            verdict = json.loads((root / "scalar-selector-verification.json").read_bytes())
            self.assertFalse(verdict["passed"])
            self.assertFalse(verdict["observationComplete"])
            self.assertTrue(all(verdict[key] is False for key in rules.NON_ACCEPTANCE))

    def test_execute_binds_real_common_run_to_prepared_checkout_before_accepting_report(self):
        corpus, report = synthetic_report()
        report["fixtureSHA256"] = hashlib.sha256(rules.FIXTURE.read_bytes()).hexdigest()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); common = rules.common_driver(); common.execute = lambda: None
            def write(name, value): (root / name).write_text(json.dumps(value), encoding="utf-8")
            write("scalar-selector-golden.json", report)
            write("reference-inputs.json", {"sourceCommit": "a" * 40})
            execution = {"sourceCommit": "a" * 40, "passed": True, "instrumentationExitCode": 0, "referenceRunId": RUN}
            write("execution.json", execution)
            with patch.object(rules, "OUTPUT", root), patch.object(rules, "common_driver", return_value=common):
                rules.execute()
                self.assertTrue(json.loads((root / "scalar-selector-verification.json").read_bytes())["passed"])
                for key, value in (("sourceCommit", "b" * 40), ("sourceCommit", "short"),
                                   ("passed", False), ("instrumentationExitCode", 1), ("instrumentationExitCode", False)):
                    write("execution.json", {**execution, key: value})
                    with self.subTest(key=key, value=value), self.assertRaisesRegex(ValueError, "prepared checkout"):
                        rules.execute()


if __name__ == "__main__":
    unittest.main()
