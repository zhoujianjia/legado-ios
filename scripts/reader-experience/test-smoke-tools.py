#!/usr/bin/env python3
"""Offline guard tests; these do not execute or claim the Simulator UI smoke."""
import copy
from contextlib import redirect_stderr
import io
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
        self.assertNotIn("sourceCommitStamped", report)
        self.assertNotIn("YueduExperienceSourceCommit", info)

    def test_explicit_source_stamp_binds_full_and_short_sha_in_info_and_record(self):
        path = self.root / "Info.plist"
        self.write(path, plistlib.dumps(self.source_info()))
        report = smoke.overlay_info(path, self.root / "info-overlay.json", source_commit=SOURCE)
        info = plistlib.loads(path.read_bytes())
        smoke.require_source_stamp(info, SOURCE)
        self.assertEqual(report["sourceCommitStamped"], SOURCE)
        self.assertEqual(info["GitCommitSHA"], SOURCE[:7])
        self.assertEqual(report["overlaySHA256"], smoke.config.digest(path))

    def test_invalid_source_stamp_is_rejected_before_info_or_record_mutation(self):
        path = self.root / "Info.plist"
        original = plistlib.dumps(self.source_info())
        self.write(path, original)
        record = self.root / "info-overlay.json"
        for value in ("", "A" * 40, "a" * 39, "a" * 41, SOURCE + "\n", True):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "full lowercase"):
                smoke.overlay_info(path, record, source_commit=value)
            self.assertEqual(path.read_bytes(), original)
            self.assertFalse(record.exists())

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

    def audit_fixture(self, source_commit=None, already_independent=False):
        family = smoke.config.MAIN_BUNDLE if already_independent else smoke.config.UPSTREAM_BUNDLE
        original_project = "\n".join("PRODUCT_BUNDLE_IDENTIFIER = " + family + suffix + ";"
                                     for suffix in ("", ".widget", ".shareextension", ".tests", ".uitests")
                                     for _ in range(2)).encode()
        originals = {smoke.INFO: plistlib.dumps(self.source_info()), smoke.config.PROJECT: original_project}
        self.write(self.root / smoke.INFO, originals[smoke.INFO])
        info = smoke.overlay_info(self.root / smoke.INFO, self.root / "info-overlay.json", source_commit=source_commit)
        self.write(self.root / smoke.config.PROJECT, original_project)
        project = smoke.config.overlay_project(self.root / smoke.config.PROJECT, self.root / "project-overlay.json")
        self.write(self.root / "GoogleService-Info.plist", plistlib.dumps(smoke.config.synthetic_config()))
        audit = {"sourceCommit": SOURCE, "projectOverlay": project, "infoOverlay": info}
        def git(*args, binary=False):
            if args[0] == "diff":
                return "\n".join(sorted({smoke.INFO} | ({smoke.config.PROJECT} if project["expectedTrackedOverlay"] else set())))
            if args[0] == "show":
                return originals[args[1].removeprefix("HEAD:")]
            raise AssertionError(args)
        return audit, git

    def test_independent_source_ids_require_no_project_mutation_and_no_fake_overlay(self):
        audit, git = self.audit_fixture(already_independent=True)
        project = audit["projectOverlay"]
        self.assertEqual(project["replacementCount"], 0)
        self.assertEqual(project["originalSHA256"], project["overlaySHA256"])
        with patch.object(smoke, "REPO", self.root), patch.object(smoke, "source_sha", return_value=SOURCE), \
                patch.object(smoke, "git", side_effect=git):
            smoke.review_overlays(audit)
            altered = copy.deepcopy(audit)
            altered["projectOverlay"]["replacementCount"] = 10
            with self.assertRaisesRegex(ValueError, "source identity"):
                smoke.review_overlays(altered)

    def test_stamped_review_rejects_record_and_info_source_mismatches(self):
        audit, git = self.audit_fixture(source_commit=SOURCE)
        with patch.object(smoke, "REPO", self.root), patch.object(smoke, "source_sha", return_value=SOURCE), \
                patch.object(smoke, "git", side_effect=git):
            smoke.review_overlays(audit)
            altered = copy.deepcopy(audit)
            altered["infoOverlay"]["sourceCommitStamped"] = "b" * 40
            with self.assertRaisesRegex(ValueError, "stamp differs"):
                smoke.review_overlays(altered)
            path = self.root / smoke.INFO
            original = path.read_bytes()
            for key, value in (("YueduExperienceSourceCommit", "b" * 40), ("GitCommitSHA", "b" * 7)):
                with self.subTest(key=key):
                    info = plistlib.loads(original)
                    info[key] = value
                    self.write(path, plistlib.dumps(info))
                    altered = copy.deepcopy(audit)
                    # Still reject a stamp mismatch when the audit's byte digest
                    # has been rewritten to match those incorrect Info bytes.
                    altered["infoOverlay"]["overlaySHA256"] = smoke.config.digest(path)
                    with self.assertRaisesRegex(ValueError, "full and short"):
                        smoke.review_overlays(altered)

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
        unit = {"totalTestCount": 9, "passedTests": 9, "failedTests": 0, "skippedTests": 0}
        ui = {**unit, "totalTestCount": 1, "passedTests": 1}
        paging = {**unit, "totalTestCount": 12, "passedTests": 12}
        product = {**unit, "totalTestCount": 41, "passedTests": 41}
        with patch.object(smoke, "REPO", self.root), patch.object(smoke, "source_sha", return_value=SOURCE), \
                patch.object(smoke, "git", side_effect=git):
            result = smoke.result(audit, settings, unit, ui, paging, product)
            self.assertEqual(result["status"], "passed")
            self.assertFalse(result["deviceValidationPassed"])
            self.assertFalse(result["deliveredIPAExecuted"])
            self.assertFalse(result["paidFeatureOverrides"])
            self.assertEqual(result["configuration"], "Debug")
            self.assertEqual(result["targetedTests"]["cloudKitAndLocalServicesConfiguration"]["totalTestCount"], 9)
            self.assertEqual(result["targetedTests"]["localProductFeatures"]["totalTestCount"], 41)
            self.assertEqual(result["targetedTests"]["searchAutoPaging"]["totalTestCount"], 12)
            self.assertEqual(result["targetedTests"]["TXTReaderUI"]["totalTestCount"], 1)
            for key, value in (("totalTestCount", 0), ("totalTestCount", 11), ("totalTestCount", 19),
                               ("passedTests", 11), ("passedTests", True), ("failedTests", 1),
                               ("skippedTests", 1), ("skippedTests", None)):
                with self.subTest(paging=(key, value)), self.assertRaises(ValueError):
                    smoke.result(audit, settings, unit, ui, {**paging, key: value}, product)
            for missing in paging:
                with self.subTest(missingPagingField=missing), self.assertRaises(ValueError):
                    smoke.result(audit, settings, unit, ui, {key: value for key, value in paging.items() if key != missing}, product)
            with self.assertRaises(ValueError):
                smoke.result(audit, settings, unit, ui, None, product)
            for change in ({"totalTestCount": 0}, {"passedTests": 26}, {"skippedTests": 1}, {"failedTests": 1}):
                with self.subTest(product=change), self.assertRaises(ValueError):
                    smoke.result(audit, settings, unit, ui, paging, {**product, **change})
            info["YueduLocalExperience"] = False
            self.write(app / "Info.plist", plistlib.dumps(info))
            with self.assertRaisesRegex(ValueError, "local-mode Info"):
                smoke.result(audit, settings, unit, ui, paging, product)

    def test_result_cli_requires_the_independent_paging_summary(self):
        args = ["smoke-tools.py", "result", "--audit", "audit.json", "--settings", "settings.json",
                "--unit", "configuration.json", "--ui", "txt.json", "--output", "result.json"]
        with patch.object(smoke.sys, "argv", args), redirect_stderr(io.StringIO()) as errors, \
                self.assertRaises(SystemExit) as failure:
            smoke.main()
        self.assertEqual(failure.exception.code, 2)
        self.assertIn("--paging", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
