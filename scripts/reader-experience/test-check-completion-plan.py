#!/usr/bin/env python3
"""Negative ledger regressions; these do not execute or accept reader features."""
import copy
from contextlib import redirect_stderr
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("completion_plan_checker_tests", HERE / "check-completion-plan.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class CompletionPlanChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = checker.read_json(checker.REPO / checker.PLAN)
        cls.catalog = checker.read_json(checker.REPO / checker.CATALOG)

    def plan(self, *, execution=False):
        value = copy.deepcopy(self.original)
        if execution:
            for package in value["workpackages"]:
                package["execution"] = {
                    "summaryZh": "执行已有工作包的剩余验收", "currentState": "已有实现，尚待对应范围验收",
                    "remainingWork": ["保存固定场景原始结果"], "nextAction": "先运行可复现的最小检查",
                    "readiness": "depends-on-work", "readyPreparation": [],
                    "acceptance": ["仅使用对应源码的实际结果"],
                    "evidence": ["docs/legado-ios/feature-catalog.json"], "deferredHardware": [],
                    "verificationBoundary": "仅验证结构，不代表功能通过",
                }
            for name in ("readyQueue", "awaitingEvidenceQueue", "deferredQueue"):
                value["execution"][name] = []
        return value

    def rejects(self, value, message=None):
        with self.assertRaisesRegex(ValueError, message or ".+"):
            checker.validate(value, self.catalog)

    def test_current_ledger_and_all_execution_instructions_have_bounded_results(self):
        result = checker.validate(self.plan(), self.catalog)
        self.assertEqual((result["stageCount"], result["workpackageCount"], result["featureDomainCount"]), (8, 33, 64))
        self.assertFalse(result["appBehaviorExecuted"])
        self.assertFalse(result["featureAcceptanceEstablished"])
        with_instructions = self.plan(execution=True)
        # Planned means unaccepted, not necessarily absent code. Independent work
        # may be ready while package/stage acceptance remains open.
        planned = next(item for item in with_instructions["workpackages"] if item["status"] == "planned")
        planned["execution"]["readiness"] = "ready"
        with_instructions["execution"]["readyQueue"] = [planned["id"]]
        self.assertEqual(checker.validate(with_instructions, self.catalog, require_execution=True)
                         ["executionInstructionsChecked"], 33)

    def test_counts_unique_ids_and_single_feature_owner_cannot_drift(self):
        for section in ("stages", "workpackages", "features"):
            value = self.plan()
            value[section].pop()
            self.rejects(value, "exactly")
            value = self.plan()
            value[section][1]["id"] = value[section][0]["id"]
            self.rejects(value, "duplicate")
        value = self.plan()
        feature = value["features"][0]
        feature["ownerWorkpackage"] = "plan-and-evidence-refresh"
        self.rejects(value, "Owner mapping")
        value = self.plan()
        owner = next(item for item in value["workpackages"] if item["kind"] == "domain-owner")
        owner["ownedFeatureIds"].pop()
        self.rejects(value)

    def test_unknown_dependencies_cycles_and_stage_contradictions_fail(self):
        for section in ("stages", "workpackages"):
            value = self.plan()
            value[section][0]["dependsOn"] = ["unknown-id"]
            self.rejects(value, "unknown dependency")
            value = self.plan()
            first, second = value[section][:2]
            first["dependsOn"], second["dependsOn"] = [second["id"]], [first["id"]]
            self.rejects(value, "cycle")
        value = self.plan()
        first = next(item for item in value["workpackages"] if item["id"] == "plan-and-evidence-refresh")
        first["dependsOn"] = ["runtime-core"]
        self.rejects(value, "stage DAG")

    def test_evidence_ids_missing_files_and_escaping_paths_cannot_pass(self):
        value = self.plan()
        value["workpackages"][0]["existingEvidence"] = ["nonexistent-evidence-id"]
        self.rejects(value, "unknown evidence")
        for path in ("docs/nonexistent-evidence.json", "../outside.json", "https://example.invalid/result", "C:/outside.json"):
            value = self.plan()
            next(iter(value["existingEvidence"].values()))["path"] = path
            self.rejects(value)

    def test_false_completion_renewal_and_legal_claims_are_rejected(self):
        for name in checker.ROOT_FALSE:
            value = self.plan()
            value[name] = True
            self.rejects(value, "completion claim")
        value = self.plan()
        value["features"][0]["fullCompatibilityEstablished"] = True
        self.rejects(value, "feature acceptance claim")
        value = self.plan()
        renewal = next(item for item in value["workpackages"] if item["id"] == "automatic-renewal-feasibility")
        renewal["feasibilityEstablished"] = True
        self.rejects(value, "Read-only renewal probe")
        value = self.plan()
        value["workpackages"][0]["status"] = "complete"
        self.rejects(value, "package status")

    def test_execution_coverage_and_reviewable_instructions_are_required(self):
        value = self.plan(execution=True)
        del value["workpackages"][0]["execution"]
        with self.assertRaisesRegex(ValueError, "Missing execution"):
            checker.validate(value, self.catalog, require_execution=True)
        for field, bad in (("summaryZh", "English only"), ("currentState", ""), ("acceptance", []),
                           ("remainingWork", []), ("readiness", "done"), ("evidence", ["docs/missing.json"])):
            value = self.plan(execution=True)
            value["workpackages"][0]["execution"][field] = bad
            self.rejects(value)
        value = self.plan(execution=True)
        value["workpackages"][0]["execution"]["dependencies"] = []
        self.rejects(value, "original dependsOn")

    def test_queues_require_known_nonduplicated_ids_and_ready_instructions(self):
        for queue in ("readyQueue", "awaitingEvidenceQueue", "deferredQueue"):
            value = self.plan(execution=True)
            value["execution"][queue] = ["unknown-id"]
            self.rejects(value, "Unknown workpackage")
        value = self.plan(execution=True)
        identity = value["workpackages"][0]["id"]
        value["execution"]["readyQueue"] = [identity]
        self.rejects(value, "readiness is not ready")
        value["workpackages"][0]["execution"]["readiness"] = "ready"
        value["execution"]["deferredQueue"] = [identity]
        self.rejects(value, "multiple execution queues")

    def test_duplicate_json_keys_cannot_hide_a_completion_claim(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve() / "duplicate.json"
            path.write_bytes(b'{"allNonDeviceWorkComplete":true,"allNonDeviceWorkComplete":false}')
            with self.assertRaisesRegex(ValueError, "Duplicate JSON key"):
                checker.read_json(path)

    def test_cli_output_cannot_replace_the_plan_it_just_checked(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve() / "plan.json"
            original = json.dumps(self.plan()).encode("utf-8")
            path.write_bytes(original)
            args = ["check-completion-plan.py", "--plan", str(path), "--output", str(path)]
            with patch.object(checker.sys, "argv", args), redirect_stderr(io.StringIO()) as errors:
                self.assertEqual(checker.main(), 1)
            self.assertIn("must not overwrite", errors.getvalue())
            self.assertEqual(path.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
