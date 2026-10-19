#!/usr/bin/env python3
"""Portable gate tests using owned SYNTHETIC logs/xcresult shapes, never iOS evidence."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


HERE = Path(__file__).resolve().parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


collector = load("rule_collection_guard_tests", "collect-rule-defaults-reference.py")
fixtures = load("rule_collection_synthetic_shapes", "test-rule-defaults-reference.py")
baseline_fixtures = load("rule_collection_synthetic_environment", "test-reader-stage-baseline.py")


class RuleCollectionGuards(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="synthetic-rule-collection-")
        self.addCleanup(self.temp.cleanup)
        # Canonicalize only this test-owned root (macOS may return a /var alias).
        # Production checked_path must still reject symlinked evidence paths.
        self.root = Path(self.temp.name).resolve()
        shape = fixtures.RuleReferenceGuards()
        shape.setUp()
        self.rows = shape.synthetic_observations()
        self.args = SimpleNamespace(**{name: self.root / (name + ".json") for name in (
            "audit", "environment", "preparation", "log", "summary", "tests", "raw", "comparison", "output",
            "comparator_stdout", "comparator_stderr")}, result_bundle=self.root / "synthetic.xcresult", test_exit_status=0)
        self.args.result_bundle.mkdir()
        (self.args.result_bundle / "Info.plist").write_bytes(b"Synthetic shape only; never a real xcresult")
        self.summary = {"totalTestCount": 3, "passedTests": 3, "failedTests": 0, "skippedTests": 0,
                        "expectedFailures": 0, "devicesAndConfigurations": [
                            {"passedTests": 3, "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}]}
        self.tree = {"testNodes": [{"nodeType": "Test Plan", "result": "Passed", "children": [
            {"nodeType": "Test Case", "nodeIdentifier": name, "result": "Passed"} for name in collector.METHODS]}]}
        self.environment = {"sourceCommit": "a" * 40, "syntheticFixture": True}
        self.sources = {"synthetic-owned-input": {"sha256": "b" * 64, "bytes": 1}}
        for name, value in (("audit", {"sourceCommit": "a" * 40}), ("environment", self.environment),
                            ("summary", self.summary), ("tests", self.tree)):
            self.write_json(getattr(self.args, name), value)
        self.write_rows(self.rows)
        self.binding = patch.object(collector, "validate_binding", return_value=self.environment)
        self.source = patch.object(collector, "source_provenance", return_value=self.sources)
        self.binding.start()
        self.source.start()
        self.addCleanup(self.binding.stop)
        self.addCleanup(self.source.stop)
        collector.prepare(self.args.audit, self.args.environment, self.args.preparation)

    def write_json(self, path, value):
        path.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")

    def write_rows(self, rows):
        self.args.log.write_text("Synthetic fixture only\n" + "".join(
            collector.reference.MARKER + json.dumps(row, ensure_ascii=False) + "\n" for row in rows), encoding="utf-8")

    def clear_outputs(self):
        for name in ("raw", "output", "comparison", "comparator_stdout", "comparator_stderr"):
            path = getattr(self.args, name)
            if path.exists(): path.unlink()

    def cases(self, tree):
        return tree["testNodes"][0]["children"]

    def test_complete_synthetic_collection_retains_exact_counts_and_digests(self):
        result = collector.collect(self.args)
        self.assertTrue(result["collectionPassed"])
        self.assertTrue(result["selectedContractsMatch"])
        self.assertFalse(result["compatibilityAccepted"])
        self.assertEqual(result["comparatorExitStatus"], 0)
        self.assertEqual((result["observationRows"], result["totalSnapshots"]), (319, 916))
        self.assertEqual(result["testExecutionGate"]["passedMethodIdentities"], sorted(collector.METHODS))
        self.assertEqual(result["evidence"]["log"], collector.evidence(self.args.log))
        self.assertEqual(result["evidence"]["tests"], collector.evidence(self.args.tests))

    def test_complete_differences_keep_real_cli_exit_one_and_false_match(self):
        self.rows[0]["snapshots"][0]["getterValue"] = "owned difference"
        self.write_rows(self.rows)
        result = collector.collect(self.args)
        self.assertTrue(result["collectionPassed"])
        self.assertEqual(result["status"], "observed-differences")
        self.assertFalse(result["selectedContractsMatch"])
        self.assertFalse(result["compatibilityAccepted"])
        self.assertEqual(result["comparatorExitStatus"], 1)
        self.assertGreater(result["differenceCount"], 0)
        self.assertFalse(collector.object_json(self.args.comparison)["selectedContractsMatch"])

    def test_empty_missing_duplicate_unknown_and_malformed_observations_fail(self):
        for mutate in (lambda rows: rows.clear(), lambda rows: rows.pop(),
                       lambda rows: rows.append(copy.deepcopy(rows[0])),
                       lambda rows: rows[0].update(identity="not-an-original-case"),
                       lambda rows: rows[0].update(kind="unknown-kind"),
                       lambda rows: rows[0].update(snapshots=[])):
            self.clear_outputs()
            rows = copy.deepcopy(self.rows)
            mutate(rows)
            self.write_rows(rows)
            with self.subTest(mutate=mutate), self.assertRaises(ValueError): collector.collect(self.args)
            self.assertTrue(self.args.raw.exists())
            self.assertFalse(self.args.output.exists())

    def test_missing_summary_tree_or_bundle_is_never_collection_success(self):
        for name in ("summary", "tests"):
            path = getattr(self.args, name)
            original = path.read_bytes()
            path.unlink()
            with self.subTest(name=name), self.assertRaises(OSError): collector.collect(self.args)
            self.clear_outputs()
            path.write_bytes(original)
        (self.args.result_bundle / "Info.plist").unlink()
        with self.assertRaisesRegex(ValueError, "xcresult"): collector.collect(self.args)

    def test_explicit_method_and_execution_counts_reject_missing_false_skipped_and_expected_failure(self):
        for key, value in (("totalTestCount", 0), ("passedTests", True), ("failedTests", 1),
                           ("skippedTests", 1), ("expectedFailures", 1), ("devicesAndConfigurations", [])):
            changed = copy.deepcopy(self.summary)
            changed[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): collector.verify_execution(changed, self.tree, 0)
        changed = copy.deepcopy(self.summary)
        changed["devicesAndConfigurations"][0]["passedTests"] = 2
        with self.assertRaises(ValueError): collector.verify_execution(changed, self.tree, 0)
        with self.assertRaises(ValueError): collector.verify_execution(self.summary, self.tree, 1)

    def test_exact_actual_leaf_gate_rejects_omitted_duplicate_wrong_failed_skipped_and_arguments(self):
        for mutate in (lambda cases: cases.pop(), lambda cases: cases.append(copy.deepcopy(cases[0])),
                       lambda cases: cases[0].update(nodeIdentifier="OtherSuite/sameCount()"),
                       lambda cases: cases[0].update(result="Skipped"), lambda cases: cases[0].update(result="Failed"),
                       lambda cases: cases[0].update(children=[{"nodeType": "Arguments", "result": "Passed"}])):
            tree = copy.deepcopy(self.tree)
            mutate(self.cases(tree))
            with self.subTest(mutate=mutate), self.assertRaises(ValueError): collector.verify_execution(self.summary, tree, 0)
        tree = copy.deepcopy(self.tree)
        for case in self.cases(tree): case["nodeIdentifier"] = "yuedu appTests/" + case["nodeIdentifier"]
        self.assertEqual(len(collector.verify_execution(self.summary, tree, 0)["passedMethodIdentities"]), 3)

    def test_unknown_or_missing_node_types_cannot_hide_under_passing_counts(self):
        # These include root's three actual portable counterexamples to v2.
        for kind in ("Unrecognized Container", None, "", [], 1):
            tree = copy.deepcopy(self.tree)
            root = tree["testNodes"][0]
            if kind is None: root.pop("nodeType")
            else: root["nodeType"] = kind
            with self.subTest(rootType=kind), self.assertRaises(ValueError):
                collector.verify_execution(self.summary, tree, 0)
        for extra in ({"nodeType": "Unrecognized Leaf", "result": "Passed"},
                      {"result": "Passed"}, {"nodeType": "Arguments", "result": "Passed"}):
            tree = copy.deepcopy(self.tree)
            self.cases(tree).append(extra)
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                collector.verify_execution(self.summary, tree, 0)

    def test_all_known_containers_reject_interrupted_cancelled_and_unrecognized_results(self):
        for kind in collector.CONTAINER_TYPES:
            for status in ("Interrupted", "Cancelled", "Failed", "Skipped", "Expected Failure", "Unknown", "", None, True):
                tree = copy.deepcopy(self.tree)
                tree["testNodes"][0].update(nodeType=kind, result=status)
                with self.subTest(kind=kind, status=status), self.assertRaises(ValueError):
                    collector.verify_execution(self.summary, tree, 0)
        tree = copy.deepcopy(self.tree)
        self.cases(tree).append({"nodeType": "Test Suite", "result": "Passed", "children": []})
        with self.assertRaisesRegex(ValueError, "container"):
            collector.verify_execution(self.summary, tree, 0)

    def test_known_nonempty_container_hierarchy_allows_only_passed_or_absent_container_result(self):
        tree = {"testNodes": [{"nodeType": "Test Plan", "result": "Passed", "children": [
            {"nodeType": "Unit test bundle", "children": [
                {"nodeType": "Test Suite", "result": "Passed", "children": copy.deepcopy(self.cases(self.tree))}]}]}]}
        result = collector.verify_execution(self.summary, tree, 0)
        self.assertEqual(result["passedMethodIdentities"], sorted(collector.METHODS))

    def test_source_environment_or_preparation_changes_are_rejected(self):
        for key, value in (("sourceCommit", "c" * 40), ("sourceInputs", {}), ("expectedMethodIdentities", [])):
            prepared = collector.object_json(self.args.preparation)
            original = self.args.preparation.read_bytes()
            prepared[key] = value
            self.write_json(self.args.preparation, prepared)
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "changed since preparation"):
                collector.collect(self.args)
            self.clear_outputs()
            self.args.preparation.write_bytes(original)
        self.args.environment.write_text("{}", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "changed since preparation"): collector.collect(self.args)

    def test_fixture_only_report_cannot_satisfy_required_collection(self):
        def fixture_only(*unused, **ignored):
            self.write_json(self.args.comparison, {"schemaVersion": 1, "fixtureContractsValidated": True,
                                                  "observationLogProvided": False})
            return subprocess.CompletedProcess([], 0, b"fixture-only", b"")
        with patch.object(collector.subprocess, "run", side_effect=fixture_only), self.assertRaises(ValueError):
            collector.collect(self.args)
        self.assertFalse(self.args.output.exists())

    def test_exit_one_without_complete_report_is_not_diagnostic_success(self):
        with patch.object(collector.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, b"", b"failure")), \
                self.assertRaises(OSError): collector.collect(self.args)
        self.assertEqual(self.args.comparator_stderr.read_bytes(), b"failure")
        self.assertFalse(self.args.output.exists())

    def test_exit_status_must_agree_with_actual_comparison(self):
        run = subprocess.run
        def changed_status(*args, **kwargs):
            result = run(*args, **kwargs)
            result.returncode = 1  # Actual synthetic matching report requires zero.
            return result
        with patch.object(collector.subprocess, "run", side_effect=changed_status), self.assertRaisesRegex(ValueError, "exit status"):
            collector.collect(self.args)

    def test_raw_log_digest_and_comparison_replay_cannot_be_changed(self):
        run = subprocess.run
        def changed_report(*args, **kwargs):
            result = run(*args, **kwargs)
            report = collector.object_json(self.args.comparison)
            report["observationLog"]["sha256"] = "0" * 64
            self.write_json(self.args.comparison, report)
            return result
        with patch.object(collector.subprocess, "run", side_effect=changed_report), self.assertRaisesRegex(ValueError, "digest"):
            collector.collect(self.args)

    def test_prior_evidence_is_never_overwritten(self):
        original = self.args.preparation.read_bytes()
        with self.assertRaises(ValueError): collector.prepare(self.args.audit, self.args.environment, self.args.preparation)
        self.assertEqual(self.args.preparation.read_bytes(), original)
        self.args.output.write_bytes(b"old evidence")
        with self.assertRaises(ValueError): collector.collect(self.args)
        self.assertEqual(self.args.output.read_bytes(), b"old evidence")

    def test_mid_collection_input_changes_and_output_aliases_are_rejected(self):
        run = subprocess.run
        def changed_log(*args, **kwargs):
            result = run(*args, **kwargs)
            self.args.log.write_bytes(self.args.log.read_bytes() + b"changed after comparison\n")
            return result
        with patch.object(collector.subprocess, "run", side_effect=changed_log), self.assertRaisesRegex(ValueError, "during collection"):
            collector.collect(self.args)
        self.clear_outputs()
        self.args.raw = self.args.log
        original = self.args.log.read_bytes()
        with self.assertRaisesRegex(ValueError, "distinct"): collector.collect(self.args)
        self.assertEqual(self.args.log.read_bytes(), original)

    def test_real_environment_validator_rejects_wrong_source_digest_and_configuration(self):
        self.binding.stop()
        fixture = baseline_fixtures.ReaderStageBaselineTests()
        fixture.root = self.root
        environment = fixture.environment()
        for item in environment["inputEvidence"].values(): Path(item["path"]).write_bytes(b"input bytes")
        environment["inputEvidence"]["audit"] = {"path": str(self.args.audit),
                                                   "sha256": collector.digest(self.args.audit.read_bytes())}
        self.write_json(self.args.environment, environment)
        with patch.object(collector.smoke, "review_overlays"), \
                patch.object(collector.smoke, "source_sha", return_value="a" * 40), \
                patch.object(collector.stage, "source_provenance", return_value=baseline_fixtures.SOURCES):
            self.assertEqual(collector.validate_binding(self.args.audit, self.args.environment), environment)
            for key, value in (("sourceCommit", "c" * 40), ("configuration", "Release")):
                changed = copy.deepcopy(environment)
                changed[key] = value
                self.write_json(self.args.environment, changed)
                with self.subTest(key=key), self.assertRaises(ValueError):
                    collector.validate_binding(self.args.audit, self.args.environment)
            self.write_json(self.args.environment, environment)
            Path(environment["inputEvidence"]["settings"]["path"]).write_bytes(b"modified settings")
            with self.assertRaisesRegex(ValueError, "input changed"):
                collector.validate_binding(self.args.audit, self.args.environment)
        self.binding.start()

    def test_source_bytes_must_equal_committed_checkpoint(self):
        self.source.stop()
        with patch.object(collector.smoke, "git", return_value=b"not the source"):
            with self.assertRaisesRegex(ValueError, "differs from committed"): collector.source_provenance()
        self.source.start()

    def test_collect_cli_requires_log_and_actual_execution_inputs(self):
        process = subprocess.run([sys.executable, "-B", str(HERE / "collect-rule-defaults-reference.py"),
                                  "collect", "--output", str(self.root / "no-log.json")], capture_output=True)
        self.assertNotEqual(process.returncode, 0)
        self.assertIn(b"--log", process.stderr)
        self.assertFalse((self.root / "no-log.json").exists())


if __name__ == "__main__": unittest.main()
