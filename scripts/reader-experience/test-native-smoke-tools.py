#!/usr/bin/env python3
"""Portable provenance guards using synthetic files, never native execution."""
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("native_smoke_tested", Path(__file__).with_name("native-smoke-tools.py"))
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
SOURCE = "a" * 40


class NativeSmokeProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def test_private_prepare_stamps_source_and_restores_module_hooks(self):
        info = self.root / "Info.plist"
        info.write_bytes(plistlib.dumps({}))
        overlay_record = self.root / "info-overlay.json"
        old_overlay, old_validate = native.smoke.overlay_info, native.smoke.validate_tag

        def prepare(work):
            self.assertEqual(work, self.root)
            self.assertEqual(native.smoke.validate_tag(), SOURCE)
            return native.smoke.overlay_info(info, overlay_record)

        with patch.object(native, "validate_tag", return_value=SOURCE), \
                patch.object(native.smoke, "prepare", side_effect=prepare):
            record = native.prepare(self.root)
            self.assertEqual(record["sourceCommitStamped"], SOURCE)
            native.smoke.require_source_stamp(plistlib.loads(info.read_bytes()), SOURCE)
            prior_info, prior_record = info.read_bytes(), overlay_record.read_bytes()
            with self.assertRaisesRegex(ValueError, "prior Info"):
                native.prepare(self.root)
            self.assertEqual(info.read_bytes(), prior_info)
            self.assertEqual(overlay_record.read_bytes(), prior_record)
        self.assertIs(native.smoke.overlay_info, old_overlay)
        self.assertIs(native.smoke.validate_tag, old_validate)

    def result_fixture(self):
        app = self.root / "products/YueduReader.app"
        app.mkdir(parents=True)
        info = {**native.smoke.config.LOCAL_FLAGS, "GatewayBaseURL": "",
                "GIDClientID": native.smoke.config.GOOGLE_CLIENT,
                "CFBundleExecutable": "YueduReader", "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
                "YueduExperienceSourceCommit": SOURCE, "GitCommitSHA": SOURCE[:7]}
        (app / "Info.plist").write_bytes(plistlib.dumps(info))
        (app / "YueduReader").write_bytes(b"synthetic executable, not a native payload")
        audit = {"sourceCommit": SOURCE, "infoOverlay": {"sourceCommitStamped": SOURCE}}
        settings = [{"target": native.smoke.config.MAIN_TARGET, "buildSettings": {
            "CONFIGURATION": "Debug", "PLATFORM_NAME": "iphonesimulator", "SWIFT_VERSION": "5.0",
            "ENABLE_DEBUG_DYLIB": "NO", "PRODUCT_BUNDLE_IDENTIFIER": native.smoke.config.MAIN_BUNDLE,
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG LEGADO_REQUIRE_NATIVE_MAINJS",
            "TARGET_BUILD_DIR": str(app.parent), "FULL_PRODUCT_NAME": app.name}}]
        records = {"overlays.json": audit, "build-settings.json": settings,
                   "native-exports.json": {"requiredDynamicExportsPresent": True},
                   "native-restore.json": {"sourceCommit": SOURCE},
                   "summary.json": {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}}
        return app, info, records

    def test_result_requires_exact_built_app_source_stamp(self):
        app, info, records = self.result_fixture()
        with patch.object(native, "validate_tag", return_value=SOURCE), \
                patch.object(native.smoke, "read_json", side_effect=lambda path: records[path.name]), \
                patch.object(native.smoke, "review_overlays"), \
                patch.object(native.smoke.config, "verify_jvm_payload", return_value={"synthetic": True}):
            result = native.result(self.root)
            self.assertEqual(result["sourceCommitStamped"], SOURCE)
            self.assertEqual(result["sourceOverlays"]["infoOverlay"]["sourceCommitStamped"], SOURCE)
            self.assertFalse(result["deviceValidationPassed"])
            for key, value in (("YueduExperienceSourceCommit", "b" * 40), ("GitCommitSHA", "b" * 7),
                               ("YueduExperienceSourceCommit", None)):
                with self.subTest(key=key, value=value):
                    changed = {**info}
                    if value is None:
                        changed.pop(key)
                    else:
                        changed[key] = value
                    (app / "Info.plist").write_bytes(plistlib.dumps(changed))
                    with self.assertRaisesRegex(ValueError, "full and short"):
                        native.result(self.root)

    def test_result_rejects_unstamped_or_other_source_preparation(self):
        _, _, records = self.result_fixture()
        with patch.object(native, "validate_tag", return_value=SOURCE), \
                patch.object(native.smoke, "read_json", side_effect=lambda path: records[path.name]):
            for value in (None, "b" * 40):
                with self.subTest(value=value):
                    records["overlays.json"]["infoOverlay"] = {} if value is None else {"sourceCommitStamped": value}
                    with self.assertRaisesRegex(ValueError, "did not stamp"):
                        native.result(self.root)


if __name__ == "__main__":
    unittest.main()
