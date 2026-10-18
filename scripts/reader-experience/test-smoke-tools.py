#!/usr/bin/env python3
"""Offline guard tests; these do not execute or claim the Simulator UI smoke."""
import copy
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("reader_smoke_tests", HERE / "smoke-tools.py")
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)
SOURCE = "a" * 40


class SmokeEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def write(self, path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def source_info(self):
        return {"CFBundleURLTypes": [{"CFBundleURLSchemes": ["com.googleusercontent.apps.old", "yuedu", "legado"]}],
                "GatewayBaseURL": "https://upstream.invalid", "GIDClientID": "upstream"}

    def test_source_info_overlay_is_boolean_and_replaces_only_cloud_configuration(self):
        path = self.root / "Info.plist"
        original = plistlib.dumps(self.source_info())
        self.write(path, original)
        report = smoke.overlay_info(path, self.root / "info-overlay.json")
        info = plistlib.loads(path.read_bytes())
        smoke.require_local_info(info)
        self.assertEqual(info["CFBundleURLTypes"][0]["CFBundleURLSchemes"], [smoke.config.GOOGLE_REVERSED, "yuedu", "legado"])
        self.assertEqual(report["originalSHA256"], smoke.hashlib.sha256(original).hexdigest())
        self.assertEqual(report["overlaySHA256"], smoke.config.digest(path))

    def test_source_overlay_refuses_overwriting_audit_before_mutation(self):
        path = self.root / "Info.plist"
        self.write(path, plistlib.dumps(self.source_info()))
        audit = self.root / "info-overlay.json"
        self.write(audit, b"previous evidence")
        original = path.read_bytes()
        with self.assertRaisesRegex(ValueError, "prior Info"):
            smoke.overlay_info(path, audit)
        self.assertEqual(path.read_bytes(), original)

    def test_local_info_rejects_string_flag_or_configured_gateway(self):
        info = {**smoke.config.LOCAL_FLAGS, "GatewayBaseURL": "", "GIDClientID": smoke.config.GOOGLE_CLIENT}
        smoke.require_local_info(info)
        for key, value in (("YueduLocalExperience", "YES"), ("GatewayBaseURL", "https://upstream.invalid")):
            with self.subTest(key=key), self.assertRaises(ValueError):
                smoke.require_local_info({**info, key: value})

    def test_exact_nonzero_test_counts_and_zero_skips_are_required(self):
        good = {"totalTestCount": 6, "passedTests": 6, "failedTests": 0, "skippedTests": 0}
        self.assertEqual(smoke.verify_summary(good, 6)["passedTests"], 6)
        for key, value in (("totalTestCount", 0), ("passedTests", 5), ("failedTests", 1), ("skippedTests", 1),
                           ("passedTests", True), ("skippedTests", None), ("totalTestCount", 7)):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                smoke.verify_summary({**good, key: value}, 6)

    def test_smoke_tag_must_match_current_sha7(self):
        with patch.object(smoke, "source_sha", return_value=SOURCE), \
                patch.dict(smoke.os.environ, {"GITHUB_SHA": SOURCE, "GITHUB_REF_NAME": "reader-smoke-aaaaaaa"}):
            self.assertEqual(smoke.validate_tag(), SOURCE)
            with patch.dict(smoke.os.environ, {"GITHUB_REF_NAME": "reader-experience-aaaaaaa"}), self.assertRaises(ValueError):
                smoke.validate_tag()

    def audit_fixture(self):
        originals = {smoke.INFO: plistlib.dumps(self.source_info()), smoke.config.PROJECT: b"original project"}
        self.write(self.root / smoke.INFO, originals[smoke.INFO])
        info = smoke.overlay_info(self.root / smoke.INFO, self.root / "info-overlay.json")
        self.write(self.root / smoke.config.PROJECT, b"project overlay")
        project = {"path": smoke.config.PROJECT,
                   "originalSHA256": smoke.hashlib.sha256(originals[smoke.config.PROJECT]).hexdigest(),
                   "overlaySHA256": smoke.config.digest(self.root / smoke.config.PROJECT)}
        self.write(self.root / "GoogleService-Info.plist", plistlib.dumps(smoke.config.synthetic_config()))
        audit = {"sourceCommit": SOURCE, "projectOverlay": project, "infoOverlay": info}
        def git(*args, binary=False):
            if args[0] == "diff":
                return "\n".join(sorted(smoke.OVERLAYS))
            if args[0] == "show":
                return originals[args[1].removeprefix("HEAD:")]
            raise AssertionError(args)
        return audit, git

    def test_overlay_review_rejects_tampered_source_or_additional_changes(self):
        audit, git = self.audit_fixture()
        with patch.object(smoke, "REPO", self.root), patch.object(smoke, "source_sha", return_value=SOURCE), \
                patch.object(smoke, "git", side_effect=git):
            smoke.review_overlays(audit)
            with patch.object(smoke, "git", return_value="Info.plist\nOther.swift"), self.assertRaisesRegex(ValueError, "Only the declared"):
                smoke.review_overlays(audit)
            self.write(self.root / smoke.config.PROJECT, b"tampered project")
            with self.assertRaisesRegex(ValueError, "differs from its audit"):
                smoke.review_overlays(audit)

    def test_result_requires_built_simulator_local_mode_and_keeps_device_pending(self):
        audit, git = self.audit_fixture()
        app = self.root / "products/YueduReader.app"
        info = {**smoke.config.LOCAL_FLAGS, "GatewayBaseURL": "", "GIDClientID": smoke.config.GOOGLE_CLIENT,
                "CFBundleIdentifier": smoke.config.MAIN_BUNDLE, "CFBundleExecutable": "YueduReader",
                "CFBundleSupportedPlatforms": ["iPhoneSimulator"]}
        self.write(app / "Info.plist", plistlib.dumps(info))
        self.write(app / "YueduReader", b"executable fixture")
        self.write(app / "GoogleService-Info.plist", plistlib.dumps(smoke.config.synthetic_config()))
        settings = [{"target": smoke.config.MAIN_TARGET, "buildSettings": {
            "CONFIGURATION": "Debug", "SWIFT_VERSION": "5.0", "PLATFORM_NAME": "iphonesimulator",
            "PRODUCT_BUNDLE_IDENTIFIER": smoke.config.MAIN_BUNDLE, "TARGET_BUILD_DIR": str(app.parent),
            "FULL_PRODUCT_NAME": app.name}}]
        unit = {"totalTestCount": 7, "passedTests": 7, "failedTests": 0, "skippedTests": 0}
        ui = {**unit, "totalTestCount": 1, "passedTests": 1}
        with patch.object(smoke, "REPO", self.root), patch.object(smoke, "source_sha", return_value=SOURCE), \
                patch.object(smoke, "git", side_effect=git):
            result = smoke.result(audit, settings, unit, ui)
            self.assertEqual(result["status"], "passed")
            self.assertFalse(result["deviceValidationPassed"])
            self.assertFalse(result["deliveredIPAExecuted"])
            self.assertFalse(result["paidFeatureOverrides"])
            self.assertEqual(result["configuration"], "Debug")
            info["YueduLocalExperience"] = False
            self.write(app / "Info.plist", plistlib.dumps(info))
            with self.assertRaisesRegex(ValueError, "local-mode Info"):
                smoke.result(audit, settings, unit, ui)


if __name__ == "__main__":
    unittest.main()
