#!/usr/bin/env python3
"""Portable checks for synthetic config and reader bundle/package provenance."""
import copy
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("reader_experience_config_tests", HERE / "stage-config.py")
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)
SOURCE = "a" * 40


class ReaderExperienceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def write(self, path, data=b"fixture"):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def plist(self, path, value):
        return self.write(path, plistlib.dumps(value))

    def app(self):
        app = self.root / config.MAIN_PRODUCT
        info = {"CFBundleIdentifier": config.MAIN_BUNDLE, "CFBundleExecutable": "YueduReader",
                "CFBundleSupportedPlatforms": ["iPhoneOS"], "MinimumOSVersion": "17.0",
                "CFBundleShortVersionString": "3.0.0", "CFBundleVersion": "1", "CFBundleDisplayName": "Yuedu",
                "GIDClientID": "upstream-client", "CFBundleURLTypes": [{"CFBundleURLSchemes": [
                    "com.googleusercontent.apps.upstream-client", "yuedu", "legado"]}]}
        self.plist(app / "Info.plist", info)
        self.write(app / "YueduReader")
        self.plist(app / "GoogleService-Info.plist", config.synthetic_config())
        for name, (identifier, extension_point) in config.EXTENSIONS.items():
            bundle = app / "PlugIns" / name
            executable = name.removesuffix(".appex")
            self.plist(bundle / "Info.plist", {"CFBundleIdentifier": identifier,
                "CFBundleExecutable": executable, "CFBundleShortVersionString": "3.0.0", "CFBundleVersion": "1",
                "NSExtension": {"NSExtensionPointIdentifier": extension_point}})
            self.write(bundle / executable)
            self.plist(bundle / "GoogleService-Info.plist", config.synthetic_config())
        return app

    def settings(self):
        return [{"target": "Yuedu-Reader Widget", "buildSettings": {"PRODUCT_BUNDLE_IDENTIFIER": "extension"}},
                {"target": config.MAIN_TARGET, "buildSettings": {
                    "CONFIGURATION": "Release", "SWIFT_VERSION": "5.0", "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
                    "PLATFORM_NAME": "iphoneos", "FULL_PRODUCT_NAME": config.MAIN_PRODUCT,
                    "PRODUCT_BUNDLE_IDENTIFIER": config.MAIN_BUNDLE, "ARCHS": "arm64",
                    "CODE_SIGNING_ALLOWED": "NO", "YUEDU_LOCAL_EXPERIENCE": "YES",
                    "TARGET_BUILD_DIR": str(self.root), "MARKETING_VERSION": "3.0.0", "CURRENT_PROJECT_VERSION": "1",
                    "SDK_NAME": "iphoneos27.0"}}]

    def test_bundled_sources_are_optional_but_stale_packaging_is_rejected(self):
        app, resources = self.root / "App", self.root / "Resources"
        self.assertEqual(config.bundled_sources(app, resources), {"included": False})
        self.write(app / "BuiltInBookSources.json", b"[]")
        with self.assertRaisesRegex(ValueError, "Unexpected bundled"):
            config.bundled_sources(app, resources)

    def test_bundled_source_manifest_binds_actual_resource_and_packaged_bytes(self):
        app, resources = self.root / "App", self.root / "Resources"
        raw = json.dumps([{"bookSourceUrl": "https://fixture.invalid", "mainJs": "function search(){return [];}"}]).encode()
        metadata = json.dumps({"schemaVersion": 1, "version": "test-v1", "sha256": config.hashlib.sha256(raw).hexdigest()}).encode()
        for root in (resources, app):
            self.write(root / "BuiltInBookSources.json", raw)
            self.write(root / "BuiltInBookSources.manifest.json", metadata)
        result = config.bundled_sources(app, resources)
        self.assertEqual(result["sourceCount"], 1)
        self.assertEqual(result["mainJsSourceCount"], 1)
        self.assertFalse(result["realSourceAvailabilityValidated"])
        self.write(app / "BuiltInBookSources.json", b"[]")
        with self.assertRaisesRegex(ValueError, "differ"):
            config.bundled_sources(app, resources)

    def test_missing_or_changed_source_manifest_never_passes_packaging(self):
        app, resources = self.root / "App", self.root / "Resources"
        raw = b'[{"bookSourceUrl":"https://fixture.invalid"}]'
        self.write(resources / "BuiltInBookSources.json", raw)
        self.write(app / "BuiltInBookSources.json", raw)
        with self.assertRaisesRegex(ValueError, "must be packaged"):
            config.bundled_sources(app, resources)
        for root in (resources, app):
            self.write(root / "BuiltInBookSources.manifest.json", json.dumps(
                {"schemaVersion": 1, "version": "test-v1", "sha256": "0" * 64}).encode())
        with self.assertRaisesRegex(ValueError, "differ"):
            config.bundled_sources(app, resources)

    def original_project(self):
        return ("// unrelated identifier " + config.UPSTREAM_BUNDLE + "\n" + "\n".join(
            "\tPRODUCT_BUNDLE_IDENTIFIER = " + config.UPSTREAM_BUNDLE + suffix + ";"
            for suffix in ("", ".widget", ".shareextension", ".tests", ".uitests") for _ in range(2)) + "\n").encode()

    def independent_project(self):
        return self.original_project().replace(
            ("PRODUCT_BUNDLE_IDENTIFIER = " + config.UPSTREAM_BUNDLE).encode(),
            ("PRODUCT_BUNDLE_IDENTIFIER = " + config.MAIN_BUNDLE).encode())

    def test_stage_generates_only_known_synthetic_configuration(self):
        path = self.root / "GoogleService-Info.plist"
        report = config.stage(path)
        self.assertEqual(plistlib.loads(path.read_bytes()), config.synthetic_config())
        self.assertFalse(report["upstreamCredentialsUsed"])
        self.assertEqual(report["sha256"], config.digest(path))
        self.assertTrue(config.synthetic_config()["DATABASE_URL"].endswith(".invalid"))
        self.assertFalse(config.synthetic_config()["IS_SIGNIN_ENABLED"])

    def test_stage_never_overwrites_existing_configuration(self):
        path = self.write(self.root / "GoogleService-Info.plist", b"existing private config")
        with self.assertRaisesRegex(ValueError, "overwrite"):
            config.stage(path)
        self.assertEqual(path.read_bytes(), b"existing private config")

    def test_bundle_overlay_changes_exactly_ten_settings_and_records_both_hashes(self):
        original = self.original_project()
        path = self.write(self.root / config.PROJECT, original)
        record = config.overlay_project(path, self.root / "overlay.json")
        self.assertEqual(record["replacementCount"], 10)
        self.assertEqual(record["overlaySHA256"], config.digest(path))
        self.assertEqual(record["originalSHA256"], config.hashlib.sha256(original).hexdigest())
        text = path.read_text()
        self.assertEqual(text.count("PRODUCT_BUNDLE_IDENTIFIER = " + config.MAIN_BUNDLE), 10)
        self.assertIn("// unrelated identifier " + config.UPSTREAM_BUNDLE, text)
        self.assertTrue(record["expectedTrackedOverlay"])
        self.assertFalse(record["identifiersAlreadyIndependent"])

    def test_independent_project_validates_all_ten_ids_without_rewriting(self):
        original = self.independent_project()
        path = self.write(self.root / config.PROJECT, original)
        before_mtime = path.stat().st_mtime_ns
        # The audit uses an exclusive text stream. No project write is permitted
        # when its existing source identity is already the independent family.
        with patch.object(Path, "write_bytes", side_effect=AssertionError("Unexpected project rewrite")):
            record = config.overlay_project(path, self.root / "overlay.json")
        self.assertEqual(path.read_bytes(), original)
        self.assertEqual(path.stat().st_mtime_ns, before_mtime)
        self.assertEqual(record["replacementCount"], 0)
        self.assertTrue(record["identifiersAlreadyIndependent"])
        self.assertFalse(record["expectedTrackedOverlay"])
        self.assertEqual(record["originalSHA256"], record["overlaySHA256"])
        self.assertEqual(len(record["settings"]), 5)
        self.assertTrue(all(item["before"] == item["after"] and item["count"] == 2 for item in record["settings"]))
        self.assertFalse(config.review_project_overlay(record, original, path.read_bytes()))

    def test_overlay_rejects_mixed_unknown_duplicate_and_extra_identifiers(self):
        for original, family, other in (
                (self.original_project(), config.UPSTREAM_BUNDLE, config.MAIN_BUNDLE),
                (self.independent_project(), config.MAIN_BUNDLE, config.UPSTREAM_BUNDLE)):
            marker = ("PRODUCT_BUNDLE_IDENTIFIER = " + family).encode()
            bad_projects = (
                original.replace(marker, ("PRODUCT_BUNDLE_IDENTIFIER = " + other).encode(), 1),
                original.replace(marker + b".tests;", marker + b".unknown;", 1),
                original.replace(marker + b".tests;", marker + b".widget;", 1),
                original + marker + b";\n",
                original.replace(b"PRODUCT_BUNDLE_IDENTIFIER = ", b"PRODUCT_BUNDLE_IDENTIFIER=", 1),
            )
            for malformed in bad_projects:
                with self.subTest(family=family, malformed=malformed):
                    path = self.write(self.root / config.PROJECT, malformed)
                    with self.assertRaisesRegex(ValueError, "exactly ten"):
                        config.overlay_project(path, self.root / "rejected-overlay.json")
                    self.assertEqual(path.read_bytes(), malformed)
                    self.assertFalse((self.root / "rejected-overlay.json").exists())

    def test_overlay_review_rejects_forged_profile_counts_hashes_and_actual_bytes(self):
        for original in (self.original_project(), self.independent_project()):
            overlaid, record = config.project_overlay(original)
            self.assertEqual(config.review_project_overlay(record, original, overlaid), record["expectedTrackedOverlay"])
            altered_values = (
                ("replacementCount", 0 if record["replacementCount"] else 10),
                ("replacementCount", False),
                ("identifiersAlreadyIndependent", not record["identifiersAlreadyIndependent"]),
                ("expectedTrackedOverlay", not record["expectedTrackedOverlay"]),
                ("originalSHA256", "0" * 64),
                ("overlaySHA256", "0" * 64),
                ("settings", []),
            )
            for key, value in altered_values:
                with self.subTest(key=key, independent=record["identifiersAlreadyIndependent"]), self.assertRaises(ValueError):
                    config.review_project_overlay({**record, key: value}, original, overlaid)
            # Updating a record's SHA cannot authorize unrelated project edits.
            tampered = overlaid + b"// unrelated mutation\n"
            forged = {**record, "overlaySHA256": config.hashlib.sha256(tampered).hexdigest()}
            with self.assertRaises(ValueError):
                config.review_project_overlay(forged, original, tampered)

    def test_overlay_rejects_unexpected_count_or_existing_record_without_modifying_project(self):
        original = self.original_project()
        path = self.write(self.root / config.PROJECT, original.replace(b"PRODUCT_BUNDLE_IDENTIFIER", b"DIFFERENT_SETTING", 1))
        before = path.read_bytes()
        with self.assertRaisesRegex(ValueError, "exactly ten"):
            config.overlay_project(path, self.root / "overlay.json")
        self.assertEqual(path.read_bytes(), before)
        self.write(path, original)
        config.write_new_json(self.root / "overlay.json", {"previous": True})
        with self.assertRaisesRegex(ValueError, "overwrite"):
            config.overlay_project(path, self.root / "overlay.json")
        self.assertEqual(path.read_bytes(), original)

    def test_exact_tag_and_checkout_are_required(self):
        with patch.object(config.subprocess, "check_output", return_value=SOURCE), \
                patch.dict(config.os.environ, {"GITHUB_SHA": SOURCE, "GITHUB_REF_NAME": "reader-experience-aaaaaaa"}):
            self.assertEqual(config.validate_tag()["sourceCommit"], SOURCE)
            for tag in ("reader-experience-bbbbbbb", "reader-experience-aaaaaaaa", "legado-core-aaaaaaa"):
                with patch.dict(config.os.environ, {"GITHUB_REF_NAME": tag}), self.assertRaises(ValueError):
                    config.validate_tag()

    def test_selects_main_target_without_changing_extension_identity(self):
        settings = self.settings()
        before = copy.deepcopy(settings)
        result = config.inspect_settings(settings)
        self.assertEqual(result["appPath"], str(self.root / config.MAIN_PRODUCT))
        self.assertEqual(settings, before)

    def test_build_settings_reject_wrong_mode_platform_signing_or_language(self):
        for key, value in (("CONFIGURATION", "Debug"), ("SWIFT_VERSION", "6.0"),
                ("IPHONEOS_DEPLOYMENT_TARGET", "18.0"), ("ARCHS", "arm64 x86_64"),
                ("CODE_SIGNING_ALLOWED", "YES"), ("PLATFORM_NAME", "iphonesimulator"),
                ("FULL_PRODUCT_NAME", "../Outside.app"), ("YUEDU_LOCAL_EXPERIENCE", "NO"),
                ("CODE_SIGN_ENTITLEMENTS", "upstream.entitlements"), ("GATEWAY_BASE_URL", "https://upstream.example")):
            settings = self.settings()
            settings[1]["buildSettings"][key] = value
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, key):
                config.inspect_settings(settings)

    def test_ambiguous_or_missing_main_target_is_rejected(self):
        settings = self.settings()
        for value in (settings[:1], settings + settings[1:]):
            with self.assertRaisesRegex(ValueError, "exactly one"):
                config.inspect_settings(value)

    def test_finalize_stamps_all_three_bundles_and_retains_import_urls(self):
        app = self.app()
        summary = config.finalize(app, SOURCE)
        info = plistlib.loads((app / "Info.plist").read_bytes())
        self.assertEqual(info["GIDClientID"], config.GOOGLE_CLIENT)
        self.assertEqual(info["CFBundleURLTypes"][0]["CFBundleURLSchemes"], [config.GOOGLE_REVERSED, "yuedu", "legado"])
        self.assertEqual(info["YueduExperienceSourceCommit"], SOURCE)
        self.assertEqual(info["GatewayBaseURL"], "")
        self.assertTrue(summary["extensionsPreserved"])
        self.assertEqual(len(summary["bundles"]), 3)
        for name, value in config.LOCAL_FLAGS.items():
            self.assertIs(info[name], value)
        self.assertEqual(info["CFBundleDisplayName"], "Yuedu")

    def test_rejects_real_backend_configuration_before_bundle_mutation(self):
        app = self.app()
        original_info = (app / "Info.plist").read_bytes()
        self.plist(app / "GoogleService-Info.plist", {"API_KEY": "unowned-config"})
        with self.assertRaisesRegex(ValueError, "exact synthetic"):
            config.finalize(app, SOURCE)
        self.assertEqual((app / "Info.plist").read_bytes(), original_info)

    def test_rejects_missing_or_reidentified_extensions(self):
        app = self.app()
        widget = app / "PlugIns/yuedu_app_Widget.appex"
        info = plistlib.loads((widget / "Info.plist").read_bytes())
        info["CFBundleIdentifier"] = config.MAIN_BUNDLE
        self.plist(widget / "Info.plist", info)
        with self.assertRaisesRegex(ValueError, "identity"):
            config.finalize(app, SOURCE)
        widget.rename(widget.with_name("Missing.appex"))
        with self.assertRaisesRegex(ValueError, "Both original"):
            config.finalize(app, SOURCE)

    def test_rejects_accidental_jvm_payload_and_signed_output(self):
        app = self.app()
        jar = self.write(app / "LegadoRuntime/legado-runtime.jar")
        with self.assertRaisesRegex(ValueError, "JVM payload"):
            config.finalize(app, SOURCE)
        jar.unlink()
        (app / "_CodeSignature").mkdir()
        with self.assertRaisesRegex(ValueError, "unsigned"):
            config.finalize(app, SOURCE)

    def test_rejects_version_mismatch_and_unsafe_bundle_executable(self):
        app = self.app()
        info = plistlib.loads((app / "Info.plist").read_bytes())
        info["CFBundleExecutable"] = "../outside"
        self.plist(app / "Info.plist", info)
        with self.assertRaisesRegex(ValueError, "bundle-local"):
            config.finalize(app, SOURCE)
        info["CFBundleExecutable"] = "YueduReader"
        info["CFBundleVersion"] = "2"
        self.plist(app / "Info.plist", info)
        with self.assertRaisesRegex(ValueError, "mismatched"):
            config.finalize(app, SOURCE)

    def test_manifest_hashes_exact_ipa_and_states_unverified_runtime(self):
        app = self.app()
        config.finalize(app, SOURCE)
        ipa = self.write(self.root / "experience.ipa", b"packaged IPA fixture")
        resolved = self.root / "Yuedu-Reader.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        self.write(resolved, b"locked packages")
        original = self.original_project()
        project = self.write(self.root / config.PROJECT, original)
        overlay = config.overlay_project(project, self.root / "overlay.json")
        def git_output(args, **kwargs):
            if "status" in args:
                return " M " + config.PROJECT
            if "diff" in args:
                return config.PROJECT + "\n"
            if "show" in args:
                return original
            raise AssertionError(args)
        with patch.object(config, "REPO", self.root), patch.object(config.subprocess, "check_output", side_effect=git_output):
            result = config.manifest(app, ipa, config.inspect_settings(self.settings()), SOURCE, "Xcode fixture", overlay)
        self.assertEqual(result["ipaSHA256"], config.digest(ipa))
        self.assertEqual(result["ipaBytes"], ipa.stat().st_size)
        self.assertFalse(result["signed"])
        self.assertFalse(result["deviceValidationPassed"])
        self.assertFalse(result["jvmIntegratedIntoReading"])
        self.assertEqual(result["functionalAcceptance"], "not_run")
        self.assertEqual(result["simulatorExecution"], "not_run")
        self.assertFalse(result["backendServicesConfigured"])
        self.assertTrue(result["workingTreeDirty"])
        self.assertTrue(result["expectedTrackedOverlay"])
        self.assertEqual(result["projectOverlay"]["replacementCount"], 10)

    def test_record_writing_does_not_overwrite_existing_evidence(self):
        path = self.root / "manifest.json"
        config.write_new_json(path, {"first": True})
        with self.assertRaises(FileExistsError):
            config.write_new_json(path, {"second": True})
        self.assertEqual(json.loads(path.read_text()), {"first": True})

    def test_manifest_accepts_unchanged_independent_project_and_rejects_extra_tracked_edits(self):
        app = self.app()
        config.finalize(app, SOURCE)
        ipa = self.write(self.root / "experience.ipa", b"packaged IPA fixture")
        resolved = self.root / "Yuedu-Reader.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        self.write(resolved, b"locked packages")
        original = self.independent_project()
        project = self.write(self.root / config.PROJECT, original)
        overlay = config.overlay_project(project, self.root / "overlay.json")
        extra_tracked = False
        def git_output(args, **kwargs):
            if "status" in args:
                return " M Info.plist" if extra_tracked else ""
            if "diff" in args:
                return "Info.plist\n" if extra_tracked else ""
            if "show" in args:
                return original
            raise AssertionError(args)
        with patch.object(config, "REPO", self.root), patch.object(config.subprocess, "check_output", side_effect=git_output):
            result = config.manifest(app, ipa, config.inspect_settings(self.settings()), SOURCE, "Xcode fixture", overlay)
            self.assertFalse(result["workingTreeDirty"])
            self.assertFalse(result["expectedTrackedOverlay"])
            self.assertEqual(result["trackedChanges"], [])
            self.assertEqual(result["projectOverlay"]["replacementCount"], 0)
            self.assertTrue(result["projectOverlay"]["identifiersAlreadyIndependent"])
            self.assertEqual(result["ipaSHA256"], config.digest(ipa))
            extra_tracked = True
            with self.assertRaisesRegex(ValueError, "recorded project"):
                config.manifest(app, ipa, config.inspect_settings(self.settings()), SOURCE, "Xcode fixture", overlay)


if __name__ == "__main__":
    unittest.main()
