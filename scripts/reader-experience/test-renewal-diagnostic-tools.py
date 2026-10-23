#!/usr/bin/env python3
"""Small portable admission/settings/budget checks; no Apple build or runtime claim."""
import copy
import fnmatch
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("renewal_diagnostic_gate_tests", HERE / "renewal-diagnostic-tools.py")
diagnostic = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostic)
config = diagnostic.config
SOURCE = "a" * 40


class DiagnosticGates(unittest.TestCase):
    def settings(self, root):
        return [{"target": target, "buildSettings": {
            "CONFIGURATION": "Release", "SWIFT_VERSION": "5.0", "IPHONEOS_DEPLOYMENT_TARGET": "18.0",
            "PLATFORM_NAME": "iphoneos", "FULL_PRODUCT_NAME": product, "PRODUCT_BUNDLE_IDENTIFIER": identifier,
            "ARCHS": "arm64", "CODE_SIGNING_ALLOWED": "NO", "CODE_SIGNING_REQUIRED": "NO", "ENABLE_DEBUG_DYLIB": "NO",
            "CODE_SIGN_ENTITLEMENTS": "", "GATEWAY_BASE_URL": "", "YUEDU_LOCAL_EXPERIENCE": "YES",
            "TARGET_BUILD_DIR": str(root), "MARKETING_VERSION": "3.0", "CURRENT_PROJECT_VERSION": "21",
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone", "SWIFT_COMPILATION_MODE": "singlefile",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "", "GCC_PREPROCESSOR_DEFINITIONS": "NDEBUG=1",
            "OTHER_SWIFT_FLAGS": "-D YUEDU_LOCAL_EXPERIENCE"}}
            for target, (product, identifier) in config.DIAGNOSTIC_TARGETS.items()]

    def test_three_actual_targets_require_diagnostic_settings_without_debug_or_optimization_override(self):
        with tempfile.TemporaryDirectory() as tmp:
            valid = self.settings(Path(tmp).resolve())
            result = config.inspect_settings(valid, with_jvm=True, diagnostic=True)
            self.assertEqual(set(result["diagnosticTargets"]), set(config.DIAGNOSTIC_TARGETS))
            self.assertTrue(result["diagnosticOnly"])
            self.assertFalse(result["releaseAcceptance"])
            self.assertEqual(result["S3Acceptance"], "not_run")
            # The ordinary path retains its original output contract.
            self.assertNotIn("diagnosticOnly", config.inspect_settings(valid, with_jvm=True))
            for index in range(3):
                for key, value in [("CONFIGURATION", "Debug"), ("SWIFT_OPTIMIZATION_LEVEL", "-O"),
                    ("SWIFT_COMPILATION_MODE", "wholemodule"), ("ENABLE_DEBUG_DYLIB", "YES"), ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "DEBUG"),
                    ("GCC_PREPROCESSOR_DEFINITIONS", "DEBUG=0"), ("OTHER_SWIFT_FLAGS", "-DDEBUG=0"),
                    ("OTHER_SWIFT_FLAGS", "-D DEBUG"), ("OTHER_SWIFT_FLAGS", "-Osize"),
                    ("OTHER_SWIFT_FLAGS", "-whole-module-optimization"), ("CURRENT_PROJECT_VERSION", "17"),
                    ("PRODUCT_BUNDLE_IDENTIFIER", "changed.fixture"), ("PLATFORM_NAME", "iphonesimulator")]:
                    invalid = copy.deepcopy(valid); invalid[index]["buildSettings"][key] = value
                    with self.subTest(target=index, key=key, value=value), self.assertRaises(ValueError):
                        config.inspect_settings(invalid, with_jvm=True, diagnostic=True)
            for invalid in (valid[:-1], valid + [valid[1]]):
                with self.assertRaises(ValueError):
                    config.inspect_settings(invalid, with_jvm=True, diagnostic=True)
            with self.assertRaises(ValueError):
                config.inspect_settings(valid, with_jvm=False, diagnostic=True)

    def test_exact_diagnostic_tag_does_not_trigger_other_builds_and_rejects_wrong_source_or_refs(self):
        tag = "yuedu-renewal-diagnostic-" + SOURCE[:7]
        env = {"GITHUB_SHA": SOURCE, "GITHUB_RUN_ID": "123", "GITHUB_REF_NAME": tag, "GITHUB_REF": "refs/tags/" + tag}
        with patch.object(diagnostic.native.smoke, "source_sha", return_value=SOURCE), patch.object(diagnostic.sys, "platform", "darwin"):
            with patch.dict(os.environ, env, clear=True):
                self.assertEqual(diagnostic.source(), SOURCE)
            for key, value in [("GITHUB_SHA", "b" * 40), ("GITHUB_REF", "refs/heads/" + tag),
                               ("GITHUB_REF_NAME", "yuedu-renewal-package-" + SOURCE[:7]), ("GITHUB_RUN_ID", "")]:
                with self.subTest(key=key), patch.dict(os.environ, dict(env, **{key: value}), clear=True), self.assertRaises(ValueError):
                    diagnostic.source()
        for pattern in ("reader-renewal-*", "legado-native-reader-test-*", "reader-legado-*", "yuedu-renewal-package-*"):
            self.assertFalse(fnmatch.fnmatchcase(tag, pattern))
        self.assertEqual(diagnostic.ENROLLMENT_CASE,
            "SelfRenewalDeveloperAuthenticationTests/connectsOnlyThroughActualMaterialAccountValidation")
        summary = {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0,
            "expectedFailures": 0, "devicesAndConfigurations": [
                {"passedTests": 1, "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}]}
        case = {"nodeType": "Test Case", "nodeIdentifier": "yuedu appTests/" + diagnostic.ENROLLMENT_CASE + "()", "result": "Passed"}
        tree = {"testNodes": [{"nodeType": "Test Suite", "children": [case]}]}
        self.assertEqual(diagnostic.verify_enrollment(summary, tree)["cases"], [diagnostic.ENROLLMENT_CASE])
        for invalid in ({"testNodes": []}, {"testNodes": [case, case]},
                {"testNodes": [dict(case, result="Failed")]},
                {"testNodes": [dict(case, nodeIdentifier="OtherTests/anotherCase()")]},
                {"testNodes": [dict(case, children={})]}):
            with self.subTest(tree=invalid), self.assertRaises(ValueError):
                diagnostic.verify_enrollment(summary, invalid)
        for invalid in (dict(summary, totalTestCount=2, failedTests=1), dict(summary, expectedFailures=1),
                dict(summary, devicesAndConfigurations=[]), dict(summary, passedTests=0, skippedTests=1)):
            with self.subTest(summary=invalid), self.assertRaises(ValueError):
                diagnostic.verify_enrollment(invalid, tree)
        workflow = (HERE.parents[1] / ".github/workflows/yuedu-renewal-diagnostic.yml").read_text()
        self.assertLess(workflow.index("name: Retain the diagnostic unsigned device package"), workflow.index("prepare-simulator"))
        self.assertLess(workflow.index("prepare-simulator"), workflow.index("run-enrollment"))
        self.assertNotIn("renewal-package-tools.py run", workflow)
        self.assertNotIn("full-application-signing-tools.py", workflow)

    def test_focused_authentication_group_is_an_explicit_private_simulator_overlay(self):
        original = (diagnostic.REPO / config.PROJECT).read_bytes()
        ordinary, ordinary_record = config.project_overlay(original)
        focused, record = config.project_overlay(original, diagnostic_auth_tests=True)
        self.assertNotEqual(ordinary, focused)
        self.assertEqual(record["diagnosticAuthTestRoot"], config.DIAGNOSTIC_AUTH_TEST_ROOT)
        self.assertTrue(record["expectedTrackedOverlay"])
        self.assertIn(b'path = "' + config.DIAGNOSTIC_AUTH_TEST_ROOT.encode() + b'";', focused)
        for path in (b"path = Modules;", b"path = Targets/Yuedu;", b"path = Widget;", b"path = ShareExtension;"):
            self.assertEqual(original.count(path), focused.count(path))
        settings = diagnostic.native.smoke.config
        original_adapter = settings.project_overlay
        with diagnostic.enrollment_project_overlay():
            self.assertEqual(settings.project_overlay(original), (focused, record))
            self.assertTrue(settings.review_project_overlay(record, original, focused))
            with self.assertRaises(ValueError):
                settings.review_project_overlay(record, original, focused.replace(b"path = Modules;", b"path = Elsewhere;"))
        self.assertIs(settings.project_overlay, original_adapter)
        self.assertEqual(config.project_overlay(original), (ordinary, ordinary_record))
        with self.assertRaises(ValueError):
            config.review_project_overlay(record, original, focused)
        for changed in (original.replace(b"path = Tests/iOS;", b"path = OtherTests;"), original + original):
            with self.assertRaises(ValueError):
                config.project_overlay(changed, diagnostic_auth_tests=True)

    def test_focused_authentication_source_closure_rejects_extra_changed_or_missing_inputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            stage = root / config.DIAGNOSTIC_AUTH_TEST_ROOT
            for relative in diagnostic.ENROLLMENT_SOURCES:
                target = root / relative; target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes((diagnostic.REPO / relative).read_bytes())
            resource = root / diagnostic.SDK_RESOURCE
            resource.write_text('{"controlledFixture":true}')
            unrelated = resource.with_name("UnrelatedTests.swift")
            unrelated.write_text("import Testing\n@Test func unrelated() {}\n")
            with patch.object(diagnostic, "REPO", root), patch.object(diagnostic, "SIMULATOR_TESTS", stage):
                record = diagnostic.enrollment_source_stage(create=True)
                self.assertEqual(record["swiftSourceCount"], 4)
                self.assertEqual(record, diagnostic.enrollment_source_stage())
                self.assertEqual({row["sourcePath"] for row in record["files"]},
                    {*diagnostic.ENROLLMENT_SOURCES, diagnostic.SDK_RESOURCE})
                self.assertEqual({path.name for path in stage.rglob("*.swift")},
                    {Path(relative).name for relative in diagnostic.ENROLLMENT_SOURCES})
                self.assertTrue(unrelated.is_file())
                self.assertFalse((stage / "yuedu appTests" / unrelated.name).exists())
                with self.assertRaises(ValueError):
                    diagnostic.enrollment_source_stage(create=True)
                fixture = stage / record["files"][1]["stagedPath"]
                raw = fixture.read_bytes(); fixture.write_bytes(raw + b"\n// changed\n")
                with self.assertRaises(ValueError):
                    diagnostic.enrollment_source_stage()
                fixture.write_bytes(raw)
                extra = fixture.with_name("Unexpected.swift"); extra.write_text("// unexpected source")
                with self.assertRaises(ValueError):
                    diagnostic.enrollment_source_stage()
                extra.unlink(); fixture.unlink()
                with self.assertRaises(FileNotFoundError):
                    diagnostic.enrollment_source_stage()

    def test_real_file_and_zip_budget_gates_and_old_s3_kind_rejection(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve(); app = root / "App"; app.mkdir()
            item = app / "executable"; item.write_bytes(b"synthetic-owned" * 2)
            ipa = root / "input.ipa"
            def archive(values):
                with zipfile.ZipFile(ipa, "w", compression=zipfile.ZIP_DEFLATED) as stream:
                    for name, value in values.items(): stream.writestr(name, value)
            archive({"Payload/App/executable": item.read_bytes()})
            # Small thresholds exercise the same strict production comparisons
            # without allocating hundreds of MiB of synthetic fixture data.
            with patch.object(config, "DIAGNOSTIC_FILE_BYTES", 512), patch.object(config, "DIAGNOSTIC_PACKAGE_BYTES", 1024):
                self.assertTrue(config.diagnostic_package_budget(app, ipa)["crcVerified"])
                item.write_bytes(b"x" * 513)
                with self.assertRaisesRegex(ValueError, "file exceeds"):
                    config.diagnostic_package_budget(app, ipa)
                item.write_bytes(b"x" * 400)
                (app / "second").write_bytes(b"x" * 400); (app / "third").write_bytes(b"x" * 400)
                with self.assertRaisesRegex(ValueError, "app exceeds"):
                    config.diagnostic_package_budget(app, ipa)
                (app / "second").unlink(); (app / "third").unlink(); item.write_bytes(b"small")
                archive({"Payload/App/executable": b"x" * 513})
                with self.assertRaisesRegex(ValueError, "ZIP entry"):
                    config.diagnostic_package_budget(app, ipa)
                archive({str(i): b"x" * 400 for i in range(3)})
                with self.assertRaisesRegex(ValueError, "ZIP exceeds"):
                    config.diagnostic_package_budget(app, ipa)
            producer = diagnostic.full.load("diagnostic_old_s3_gate_test", HERE / "owned-package-fixture/full-application-package.py")
            build = root / "build"; (build / "output").mkdir(parents=True)
            (build / "output/build-manifest.json").write_text(json.dumps({
                "sourceCommit": SOURCE, "artifactKind": config.DIAGNOSTIC_KIND, "configuration": "Release",
                "platform": "iPhoneOS", "architecture": "arm64", "signed": False,
                "deviceCompilationPassed": True, "jvmIntegratedIntoReading": True, "deviceValidationPassed": False}))
            base = SimpleNamespace(HERE=HERE / "owned-package-fixture", run=lambda argv: SOURCE.encode())
            with self.assertRaisesRegex(ValueError, "fresh Release"):
                producer.validate_input(base, build)


if __name__ == "__main__":
    unittest.main()
