#!/usr/bin/env python3
"""Negative regressions for the exact native-execution and jimage evidence gates."""
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("jimage_native_check", Path(__file__).with_name("jimage-native-check.py"))
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)


class NativeJimageEvidenceTests(unittest.TestCase):
    def summary(self):
        return {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0,
                "expectedFailures": 0, "devicesAndConfigurations": [
                    {"passedTests": 1, "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}]}

    def tree(self, identifier=None):
        return {"testNodes": [{"nodeType": "Test Suite", "result": "Passed", "children": [
            {"nodeType": "Test Case", "nodeIdentifier": identifier or check.CASES["mainjs"],
             "result": "Passed"}]}]}

    def test_exact_case_passes(self):
        result = check.verify_case(self.summary(), self.tree(), check.CASES["mainjs"])
        self.assertEqual(result["passedMethod"], check.CASES["mainjs"])
        self.assertEqual(result["runtimeWarnings"], [])

    def test_actual_runtime_warning_leaf_is_recorded(self):
        tree = self.tree(check.CASES["original-public"])
        warning = {"nodeType": "Runtime Warning", "name":
                   "[Internal] Thread running at User-initiated quality-of-service class waiting on a thread "
                   "without a QoS class specified (base priority 33). Investigate ways to avoid priority inversions"}
        tree["testNodes"][0]["children"][0]["children"] = [warning]
        result = check.verify_case(self.summary(), tree, check.CASES["original-public"])
        self.assertEqual(result["passedMethod"], check.CASES["original-public"])
        self.assertEqual(result["runtimeWarnings"], [warning["name"]])

    def test_runtime_warning_cannot_hide_results_identities_or_executions(self):
        warning = {"nodeType": "Runtime Warning", "name": "QoS diagnostic"}
        execution = {"nodeType": "Test Case", "nodeIdentifier": check.CASES["mainjs"], "result": "Passed"}
        for invalid in (warning | {"children": [execution]},
                        warning | {"children": [{"nodeType": "Arguments", "children": [execution]}]},
                        warning | {"result": "Failed"},
                        warning | {"result": "Passed"},
                        warning | {"nodeIdentifier": check.CASES["mainjs"]},
                        warning | {"nodeIdentifierURL": "test://hidden-execution"},
                        warning | {"name": ""}, execution):
            tree = self.tree()
            tree["testNodes"][0]["children"][0]["children"] = [invalid]
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                check.verify_case(self.summary(), tree, check.CASES["mainjs"])

    def test_runtime_warning_outside_test_case_is_rejected(self):
        tree = self.tree()
        tree["testNodes"].append({"nodeType": "Runtime Warning", "name": "Unbound annotation"})
        with self.assertRaises(ValueError):
            check.verify_case(self.summary(), tree, check.CASES["mainjs"])

    def test_wrong_or_duplicated_case_fails(self):
        for tree in (self.tree(check.CASES["original-public"]),
                     {"testNodes": self.tree()["testNodes"] * 2}):
            with self.subTest(tree=tree), self.assertRaises(ValueError):
                check.verify_case(self.summary(), tree, check.CASES["mainjs"])

    def test_skip_failure_expected_failure_and_missing_counts_fail(self):
        for field, value in (("skippedTests", 1), ("failedTests", 1),
                             ("expectedFailures", 1), ("passedTests", None)):
            with self.subTest(field=field), self.assertRaises(ValueError):
                check.verify_case(self.summary() | {field: value}, self.tree(), check.CASES["mainjs"])
        tree = self.tree()
        tree["testNodes"][0]["children"][0]["result"] = "Skipped"
        with self.assertRaises(ValueError):
            check.verify_case(self.summary(), tree, check.CASES["mainjs"])

    def test_nested_execution_cannot_fake_one_method(self):
        tree = self.tree()
        tree["testNodes"][0]["children"][0]["children"] = [{"nodeType": "Arguments", "result": "Passed"}]
        with self.assertRaises(ValueError):
            check.verify_case(self.summary(), tree, check.CASES["mainjs"])

    def test_normal_and_execute_success_verdicts_pass(self):
        for verdict in ("** TEST SUCCEEDED **", "** TEST EXECUTE SUCCEEDED **"):
            with self.subTest(verdict=verdict):
                check.verify_test_verdict("Executed 1 test, with 0 failures\n" + verdict + "\n")

    def test_either_failure_verdict_overrides_either_success(self):
        for success in ("** TEST SUCCEEDED **", "** TEST EXECUTE SUCCEEDED **"):
            for failure in ("** TEST FAILED **", "** TEST EXECUTE FAILED **", "** BUILD FAILED **"):
                with self.subTest(success=success, failure=failure), self.assertRaises(ValueError):
                    check.verify_test_verdict(success + "\n" + failure + "\n")
        with self.assertRaises(ValueError):
            check.verify_test_verdict("Test Suite 'All tests' passed\nExecuted 1 test, with 0 failures\n")

    def test_standard_image_header_is_recorded(self):
        with tempfile.TemporaryDirectory() as directory:
            # macOS exposes its temporary root through /var -> /private/var.
            # Resolve owned fixtures; production still rejects symlinked paths.
            path = Path(directory).resolve() / "modules"
            path.write_bytes(struct.pack("<7I", 0xCAFEDADA, 0x00010001, 0, 1, 1, 1, 1) + b"\0" * 10)
            result = check.image(path)
            self.assertEqual((result["majorVersion"], result["minorVersion"], result["indexBytes"]), (1, 1, 38))

    def test_nonstandard_and_truncated_images_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve() / "modules"
            for raw in (b"", b"\xca\xfe\xba\xbe" * 10,
                        struct.pack("<7I", 0xCAFEDADA, 0x00010000, 0, 1, 1, 1, 1) + b"\0" * 10,
                        struct.pack("<7I", 0xCAFEDADA, 0x00010001, 0, 1, 200, 1, 1)):
                path.write_bytes(raw)
                with self.subTest(raw=raw[:12]), self.assertRaises(ValueError):
                    check.image(path)

    def test_exact_source_only_diagnostic_methods_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            log, output = root / "test.log", root / "result.json"
            log.write_text("\n".join("Test Case 'LegadoRuntimeTests." + name + "' passed (0.001 seconds)."
                                     for name in sorted(check.PACKAGE_CASES))
                           + "\nExecuted 3 tests, with 0 failures (0 unexpected)\n", encoding="utf-8")
            with patch.object(check, "source", return_value="a" * 40):
                check.verify_package(log, output)
            self.assertTrue(output.is_file())

    def test_missing_or_skipped_source_only_diagnostics_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            log, output = root / "test.log", root / "result.json"
            text = "\n".join("Test Case 'LegadoRuntimeTests." + name + "' passed (0.001 seconds)."
                              for name in sorted(check.PACKAGE_CASES))
            for invalid in (text.replace("RejectsTruncatedIndex", "Unrelated"), text.replace("passed", "skipped", 1)):
                log.write_text(invalid + "\nExecuted 3 tests, with 0 failures (0 unexpected)\n", encoding="utf-8")
                with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                    check.verify_package(log, output)

    def test_explicit_test_target_settings_are_merged(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            app = {"target": "yuedu app", "buildSettings": {"ENABLE_DEBUG_DYLIB": "NO"}}
            test = {"target": "yuedu appTests", "buildSettings": {"ENABLE_DEBUG_DYLIB": "NO"}}
            (root / "app-build-settings.json").write_text(json.dumps([app]), encoding="utf-8")
            (root / "test-build-settings.json").write_text(json.dumps([test]), encoding="utf-8")
            check.merge_settings(root)
            self.assertEqual(json.loads((root / "build-settings.json").read_bytes()), [app, test])

    def test_missing_or_duplicate_test_settings_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            app = {"target": "yuedu app", "buildSettings": {}}
            test = {"target": "yuedu appTests", "buildSettings": {}}
            (root / "app-build-settings.json").write_text(json.dumps([app]), encoding="utf-8")
            for items in ([], [test, test], [app]):
                (root / "test-build-settings.json").write_text(json.dumps(items), encoding="utf-8")
                with self.subTest(items=items), self.assertRaises(ValueError):
                    check.merge_settings(root)


if __name__ == "__main__":
    unittest.main(verbosity=2)
