#!/usr/bin/env python3
"""Reject incomplete/reused selections and keep later test arguments build-identical."""
from copy import deepcopy
import importlib.util
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("recovery_gate_tested", HERE/"reader-recovery-regression.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class RecoveryGateTests(unittest.TestCase):
    def tree(self):
        return {"testNodes": [{"nodeType": "Test Suite", "result": "Passed", "children": [
            {"nodeType": "Test Case", "nodeIdentifier": "A/one()", "result": "Passed"},
            {"nodeType": "Test Case", "nodeIdentifier": "B/two()", "result": "Passed"}]}]}

    def test_exact_method_set_required_not_only_green_counts(self):
        expected = {"A/one()": 1, "B/two()": 1}
        self.assertEqual(gate.verify_tree(self.tree(), expected)["passedExecutionsByMethod"], expected)
        missing, duplicate, unrelated, skipped = (deepcopy(self.tree()) for _ in range(4))
        missing["testNodes"][0]["children"].pop()
        duplicate["testNodes"][0]["children"][1]["nodeIdentifier"] = "A/one()"
        unrelated["testNodes"][0]["children"][1]["nodeIdentifier"] = "Other/passed()"
        skipped["testNodes"][0]["children"][1]["result"] = "Skipped"
        for tree in (missing, duplicate, unrelated, skipped):
            with self.subTest(tree=tree), self.assertRaises(ValueError):
                gate.verify_tree(tree, expected)

    def test_warning_may_not_hide_an_extra_execution(self):
        tree = self.tree()
        case = tree["testNodes"][0]["children"][0]
        case["children"] = [{"nodeType": "Runtime Warning", "name": "Synthetic QoS warning"}]
        self.assertEqual(gate.verify_tree(tree, {"A/one()": 1, "B/two()": 1})["runtimeWarnings"], ["Synthetic QoS warning"])
        case["children"][0]["children"] = [{"nodeType": "Test Case", "result": "Passed"}]
        with self.assertRaises(ValueError):
            gate.verify_tree(tree, {"A/one()": 1, "B/two()": 1})

    def test_prior_source_native_results_cannot_satisfy_new_required_gates(self):
        prior = {"sourceCommit": "a"*40, "passed": True, "passedTests": 3, "failedTests": 0, "skippedTests": 0}
        with patch.object(gate.native, "source", return_value="b"*40), \
                patch.object(gate.native.smoke, "git", return_value=""), \
                patch.object(gate.native.smoke, "read_json", side_effect=[prior, {}]):
            with self.assertRaisesRegex(ValueError, "freshly in this run"):
                gate.prepare(Path("unused-owned-work"))

    def test_committed_source_inventory_covers_every_selected_annotation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for relative in gate.INPUTS:
                path = root/relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("synthetic source", encoding="utf-8")
            native = root/"Tests/iOS/LegadoNativeOriginalReaderTests.swift"
            native.write_text("func " + gate.NATIVE_METHOD.split("/")[1] + " {}")
            ui = root/"Tests/iOS-UI/ReaderBookSourceSmokeUITests.swift"
            ui.write_text("func " + gate.UI_METHOD.split("/")[1] + " {}")
            for suite in gate.SUITES:
                path = root/"Tests/iOS/yuedu appTests"/(suite+".swift")
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('struct '+suite+' {\n@Test("one", .timeLimit(.minutes(1)))\n@MainActor func one() async {}\n@Test\nfunc two() {}\n}')
            selected = gate.inventory(root)
            self.assertEqual(len(selected["groups"]["unit"]), len(gate.SUITES) * 2)
            self.assertEqual(selected["groups"]["native-download"], {gate.NATIVE_METHOD: 1})
            for relative in ("Modules/Services/Online/ChangeSourceCache.swift",
                             "Modules/Features/Reader/ReaderViewModel.swift",
                             "Modules/Core/BookSource/BookSourceFetcher+OriginalPreview.swift",
                             "Targets/Yuedu/SharedApp/AppDependencies.swift",
                             "Modules/Services/Online/LegadoPersistentStateHost.swift"):
                self.assertIn(relative, {item["path"] for item in selected["sourceInputs"]})
            path.write_text('struct '+suite+' {\n@Test(arguments: [1,2])\nfunc one(value: Int) {}\n}')
            with self.assertRaisesRegex(ValueError, "Unsupported selected"):
                gate.inventory(root)

    def test_new_runs_reuse_identical_compiler_arguments_and_expand_only_build_selection(self):
        original = (HERE/"jimage-native-check.sh").read_text()
        later = (HERE/"reader-recovery-regression.sh").read_text()
        args = lambda text: re.search(r"(?ms)^ARGS=\(\n(.*?)^\)", text)[1]
        self.assertEqual(args(original), args(later))
        self.assertIn('"${BUILD_SELECTION[@]}" build-for-testing', original)
        self.assertIn('for index in 0 1 2', original)
        self.assertIn('YUEDU_TEST_ACTION=test-without-building', later)
        self.assertNotIn('build-for-testing', later)
        for suite in gate.SUITES:
            self.assertIn("yuedu appTests/"+suite, original)
            self.assertIn("yuedu appTests/"+suite, later)
        self.assertIn(gate.UI_METHOD.split('/')[1].removesuffix('()'), original)


if __name__ == "__main__":
    unittest.main()
