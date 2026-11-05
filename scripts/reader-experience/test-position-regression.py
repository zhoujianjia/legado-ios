#!/usr/bin/env python3
"""Portable negative checks for the focused reader-position CI gate."""
import copy
import importlib.util
import re
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("position_regression", Path(__file__).with_name("position-regression.py"))
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)


class PositionRegressionGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.selection = check.inventory()
        cls.expected = cls.selection["expectedExecutionsByMethod"]

    def tree(self):
        cases = []
        for method, executions in self.expected.items():
            node = {"nodeType": "Test Case", "nodeIdentifier": method, "result": "Passed"}
            if executions > 1:
                node["children"] = [{"nodeType": "Arguments", "name": str(value), "result": "Passed"}
                                    for value in check.ARGUMENTS[method]]
            cases.append(node)
        return {"testNodes": [{"nodeType": "Test Suite", "result": "Passed", "children": cases}]}

    def summary(self):
        return {"totalTestCount": 86, "passedTests": 86, "failedTests": 0, "skippedTests": 0,
                "expectedFailures": 0, "devicesAndConfigurations": [
                    {"passedTests": 89, "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}]}

    def test_selection_binds_all_new_regressions_and_shell_selectors(self):
        self.assertEqual((len(self.expected), sum(self.expected.values())), (86, 89))
        self.assertEqual(sum(check.NEW_CASES.values()), 10)
        shell = (check.HERE / "position-regression.sh").read_text(encoding="utf-8")
        selected = re.findall(r"-only-testing:'yuedu appTests/([^']+)'", shell)
        self.assertEqual(selected, list(check.SUITES))
        self.assertIn("LEGADO_RUNTIME_SOURCE_ONLY=1", shell)
        workflow = (check.REPO / ".github/workflows/legado-reader.yml").read_text(encoding="utf-8")
        self.assertRegex(workflow, r"reader:\s+needs: position-regression")
        self.assertIn("run: bash scripts/reader-experience/position-regression.sh", workflow)

    def test_exact_methods_and_parameter_leaves_pass(self):
        result = check.verify_tree(self.tree(), self.expected)
        self.assertEqual(result["newRegressionExecutions"], 10)
        self.assertEqual(result["passedExecutionsByMethod"], self.expected)
        check.smoke.verify_summary(self.summary(), 86, 89)

    def test_empty_unrelated_duplicate_failed_or_skipped_methods_fail(self):
        mutations = [{"testNodes": []}]
        for field, value in (("nodeIdentifier", "Unrelated/test()"), ("result", "Failed"), ("result", "Skipped")):
            tree = self.tree()
            tree["testNodes"][0]["children"][0][field] = value
            mutations.append(tree)
        tree = self.tree()
        tree["testNodes"][0]["children"].append(copy.deepcopy(tree["testNodes"][0]["children"][0]))
        mutations.append(tree)
        for tree in mutations:
            with self.subTest(tree=tree), self.assertRaises(ValueError):
                check.verify_tree(tree, self.expected)

    def test_missing_duplicate_failed_or_skipped_parameter_execution_fails(self):
        for mutation in ("missing", "duplicate", "failed", "skipped"):
            tree = self.tree()
            case = next(node for node in tree["testNodes"][0]["children"] if node.get("children"))
            if mutation == "missing":
                case["children"].pop()
            elif mutation == "duplicate":
                case["children"][1] = copy.deepcopy(case["children"][0])
            else:
                case["children"][0]["result"] = mutation.capitalize()
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                check.verify_tree(tree, self.expected)

    def test_runtime_warning_metadata_cannot_hide_an_execution(self):
        tree = self.tree()
        leaf = next(node for node in tree["testNodes"][0]["children"] if not node.get("children"))
        leaf["children"] = [{"nodeType": "Runtime Warning", "name": "QoS annotation"}]
        check.verify_tree(tree, self.expected)
        for field, value in (("result", "Passed"), ("children", [{"nodeType": "Test Case"}]),
                             ("nodeIdentifier", "Unrelated/test()")):
            changed = copy.deepcopy(tree)
            changed_leaf = next(node for node in changed["testNodes"][0]["children"]
                                if node["nodeIdentifier"] == leaf["nodeIdentifier"])
            changed_leaf["children"][0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                check.verify_tree(changed, self.expected)

    def test_method_and_execution_counts_require_zero_skips_and_failures(self):
        for path in ((), ("devicesAndConfigurations", 0)):
            for field, value in (("passedTests", 0), ("failedTests", 1), ("skippedTests", 1), ("expectedFailures", 1)):
                summary = self.summary()
                target = summary if not path else summary[path[0]][path[1]]
                target[field] = value
                with self.subTest(path=path, field=field), self.assertRaises(ValueError):
                    check.smoke.verify_summary(summary, 86, 89)

    def test_source_method_or_parameter_drift_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for record in self.selection["sourceInputs"]:
                destination = root / record["path"]
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes((check.REPO / record["path"]).read_bytes())
            relative = "Tests/iOS/yuedu appTests/ReaderCoverPositionTests.swift"
            source = (root / relative).read_text(encoding="utf-8")
            for before, after in (("arguments: [-1, 1]", "arguments: [1]"),
                                  ("func coverTurnSurvivesPageReindex", "func unrelated")):
                (root / relative).write_text(source.replace(before, after), encoding="utf-8")
                with self.subTest(after=after), self.assertRaises(ValueError):
                    check.inventory(root)


if __name__ == "__main__":
    unittest.main()
