#!/usr/bin/env python3
"""Portable corruption/path/ownership regressions for runtime notice materials."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch


HERE = Path(__file__).resolve().parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


notices = load("runtime_notice_tests", HERE / "runtime-notices.py")
config = load("runtime_notice_config_tests", HERE / "stage-config.py")
runtime_tools = load("runtime_notice_existing_fixtures", HERE.parent / "legado-ios/test-runtime-tools.py")


def snapshot(root):
    return {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob("*") if p.is_file()}


class RuntimeNoticeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def copy_materials(self):
        target = self.root / "Notices"
        shutil.copytree(notices.VENDOR, target)
        return target

    def runtime_fixture(self):
        fixture = runtime_tools.RuntimeToolsTests()
        fixture.setUp()
        self.addCleanup(fixture.tearDown)
        return fixture

    def test_originals_have_pinned_bytes_and_explicit_limited_coverage(self):
        report = notices.verify(notices.VENDOR)
        self.assertEqual(report["noticeFileCount"], 37)
        self.assertEqual(report["noticeBytes"], 370325)
        self.assertEqual(report["requiredModuleCount"], 13)
        self.assertEqual(report["staticArchiveGroupCount"], 8)
        self.assertFalse(report["coverage"]["nativeObjectAndHeaderLicenseReviewComplete"])
        self.assertFalse(report["coverage"]["correspondingDependencySourceClosureEstablished"])
        self.assertFalse(report["coverage"]["componentLicenseCombinationReviewed"])
        self.assertFalse(report["coverage"]["redistributionClearanceEstablished"])
        _, value = notices.load_manifest(notices.VENDOR)
        self.assertEqual(sum(not m["legalSourceCandidates"] for m in value["moduleCoverage"]), 10)
        self.assertEqual(sum(len(m["legalSourceCandidates"]) for m in value["moduleCoverage"]), 32)
        self.assertFalse(value["additionalNativeInputs"][0]["effectiveLicenseApplicationReviewed"])
        self.assertIn(b"GNU AFFERO GENERAL PUBLIC LICENSE", (notices.VENDOR / "ios-tools/LICENSE").read_bytes())

    def test_missing_notice_and_unlisted_file_or_empty_directory_rejected(self):
        target = self.copy_materials()
        original = target / "ios-tools/LICENSE"
        data = original.read_bytes()
        original.unlink()
        with self.assertRaisesRegex(ValueError, "missing or extra"):
            notices.verify(target)
        original.write_bytes(data)
        extra = target / "extra.txt"
        extra.write_bytes(b"unexpected")
        with self.assertRaisesRegex(ValueError, "missing or extra"):
            notices.verify(target)
        extra.unlink()
        (target / "extra-directory").mkdir()
        with self.assertRaisesRegex(ValueError, "missing or extra"):
            notices.verify(target)

    def test_same_length_corruption_is_rejected(self):
        target = self.copy_materials()
        path = target / "openjdk/src/java.base/share/legal/unicode.md"
        data = path.read_bytes()
        path.write_bytes(bytes([data[0] ^ 1]) + data[1:])
        with self.assertRaisesRegex(ValueError, "bytes differ"):
            notices.verify(target)

    def test_source_or_packaged_manifest_tampering_is_rejected(self):
        target = self.copy_materials()
        path = target / "manifest.json"
        value = json.loads(path.read_bytes())
        value["moduleCoverage"] = []
        path.write_bytes(json.dumps(value).encode())
        with self.assertRaisesRegex(ValueError, "manifest differs"):
            notices.verify(target)
        with self.assertRaisesRegex(ValueError, "reviewed fingerprint"):
            notices.verify(target, target)

    def test_native_source_pin_drift_is_rejected(self):
        with patch.object(notices, "REPO", self.root):
            path = self.root / "scripts/legado-ios/runtime-lock.json"
            path.parent.mkdir(parents=True)
            lock = {"openjdkMobile": {}, "iosTools": {}, "libffi": {}, "requiredModules": []}
            path.write_bytes(json.dumps(lock).encode())
            with self.assertRaisesRegex(ValueError, "source pins"):
                notices.verify(notices.VENDOR)

    def test_unsafe_paths_are_rejected(self):
        for value in ("../outside", "/absolute", "C:/drive", "a\\b", "a//b", "a/./b", "a/../b", "nul\0byte", "line\nbreak"):
            with self.subTest(path=value), self.assertRaisesRegex(ValueError, "Unsafe"):
                notices.relative_path(value)

    def test_symbolic_linked_notice_is_rejected_without_reading_target(self):
        target = self.copy_materials()
        outside = self.root / "outside"
        outside.write_bytes(b"outside must not be read")
        linked = target / "libffi/LICENSE"
        linked.unlink()
        try:
            linked.symlink_to(outside)
        except OSError as error:
            self.skipTest("OS does not allow unprivileged symbolic links: " + str(error))
        original_read = Path.read_bytes
        def guarded_read(path):
            if path == outside or path == linked:
                raise AssertionError("Symlink target was read")
            return original_read(path)
        with patch.object(Path, "read_bytes", guarded_read), self.assertRaisesRegex(ValueError, "symlink"):
            notices.verify(target)

    def test_link_guard_rejects_reported_link_before_reading_its_bytes(self):
        target = self.copy_materials()
        linked = (target / "libffi/LICENSE").absolute()
        original_link = Path.is_symlink
        original_read = Path.read_bytes
        def reported_link(path):
            return path.absolute() == linked or original_link(path)
        def guarded_read(path):
            if path.absolute() == linked:
                raise AssertionError("Linked notice bytes were read")
            return original_read(path)
        with patch.object(Path, "is_symlink", reported_link), patch.object(Path, "read_bytes", guarded_read):
            with self.assertRaisesRegex(ValueError, "symlink"):
                notices.verify(target)

    @unittest.skipUnless(os.name == "nt", "Windows junction regression")
    def test_windows_junction_is_rejected_and_external_files_are_preserved(self):
        target = self.copy_materials()
        external = self.root / "external-directory"
        external.mkdir()
        sentinel = external / "sentinel"
        sentinel.write_bytes(b"external directory must stay unchanged")
        junction = target / "injected-junction"
        # Paths are data in environment variables, never interpolated shell code.
        env = {**os.environ, "NOTICE_TEST_LINK": str(junction), "NOTICE_TEST_TARGET": str(external)}
        subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command",
                        "$ErrorActionPreference = 'Stop'; New-Item -ItemType Junction -Path $env:NOTICE_TEST_LINK -Target $env:NOTICE_TEST_TARGET | Out-Null"],
                       env=env, check=True, capture_output=True, timeout=15)
        try:
            self.assertTrue(junction.is_junction())
            with self.assertRaisesRegex(ValueError, "junction"):
                notices.verify(target)
            self.assertEqual(sentinel.read_bytes(), b"external directory must stay unchanged")
        finally:
            # Removing the junction itself does not recurse into its target.
            junction.rmdir()

    def test_stage_refuses_overwrite_or_source_overlap(self):
        target = self.root / "Notices"
        report = notices.stage(target)
        self.assertTrue(report["verified"])
        before = snapshot(target)
        with self.assertRaisesRegex(ValueError, "overwrite"):
            notices.stage(target)
        self.assertEqual(snapshot(target), before)
        with self.assertRaisesRegex(ValueError, "separate"):
            notices.stage(notices.VENDOR / "Notices")

    def test_central_staging_retains_jar_java_home_bytes_and_other_resources(self):
        fixture = self.runtime_fixture()
        source_home = snapshot(fixture.java_home)
        source_jar = fixture.jar.read_bytes()
        destination = self.root / "Resources/LegadoRuntime"
        destination.mkdir(parents=True)
        (destination / "README.md").write_bytes(b"retained reader documentation")
        result = runtime_tools.stager.stage(fixture.java_home, fixture.jar, destination)
        self.assertEqual(result["runtimeNotices"], notices.verify(destination / "Notices"))
        self.assertEqual(snapshot(fixture.java_home), source_home)
        self.assertEqual(fixture.jar.read_bytes(), source_jar)
        self.assertEqual(snapshot(destination / "java-home"), source_home)
        self.assertEqual((destination / "legado-runtime.jar").read_bytes(), source_jar)
        self.assertEqual((destination / "README.md").read_bytes(), b"retained reader documentation")
        runtime_tools.stager.stage(fixture.java_home, fixture.jar, destination, replace=True)
        self.assertEqual(snapshot(fixture.java_home), source_home)
        self.assertEqual(fixture.jar.read_bytes(), source_jar)
        self.assertEqual(snapshot(destination / "java-home"), source_home)
        self.assertEqual((destination / "legado-runtime.jar").read_bytes(), source_jar)

    def test_bad_notice_source_stops_central_staging_before_output_mutation(self):
        fixture = self.runtime_fixture()
        bad = self.copy_materials()
        (bad / "ios-tools/LICENSE").unlink()
        destination = self.root / "Runtime"
        with patch.object(runtime_tools.stager.notices, "VENDOR", bad), self.assertRaisesRegex(ValueError, "missing or extra"):
            runtime_tools.stager.stage(fixture.java_home, fixture.jar, destination)
        self.assertFalse(destination.exists())

    def test_legacy_marker_cannot_claim_user_notices_during_replacement(self):
        fixture = self.runtime_fixture()
        for label, declaration in (("legacy", None), ("wrong-sha", {"manifestSHA256": "0" * 64})):
            with self.subTest(marker=label):
                destination = self.root / label / "LegadoRuntime"
                destination.mkdir(parents=True)
                shutil.copytree(fixture.java_home, destination / "java-home")
                shutil.copy2(fixture.jar, destination / "legado-runtime.jar")
                marker = {"staticValidationPassed": True, "layout": "exploded-java-home/modules"}
                if declaration is not None:
                    marker["runtimeNotices"] = declaration
                (destination / "runtime-manifest.json").write_bytes(json.dumps(marker).encode())
                user_notice = destination / "Notices/user-created.txt"
                user_notice.parent.mkdir()
                user_notice.write_bytes(b"unowned notice must not be read or removed")
                before = snapshot(destination)
                original_read = Path.read_bytes
                def guarded_read(path):
                    if path == user_notice:
                        raise AssertionError("Unowned notice content was read")
                    return original_read(path)
                with patch.object(Path, "read_bytes", guarded_read), self.assertRaisesRegex(ValueError, "notice ownership"):
                    runtime_tools.stager.stage(fixture.java_home, fixture.jar, destination, replace=True)
                self.assertEqual(snapshot(destination), before)

    def test_forged_declaration_cannot_replace_an_unrecognized_notice_manifest(self):
        fixture = self.runtime_fixture()
        destination = self.root / "LegadoRuntime"
        destination.mkdir()
        marker = {"runtimeNotices": {"manifestSHA256": notices.MANIFEST_SHA256}}
        (destination / "runtime-manifest.json").write_bytes(json.dumps(marker).encode())
        shutil.copytree(notices.VENDOR, destination / "Notices")
        (destination / "Notices/manifest.json").write_bytes(b"unowned metadata")
        before = snapshot(destination)
        with self.assertRaisesRegex(ValueError, "manifest differs"):
            runtime_tools.stager.stage(fixture.java_home, fixture.jar, destination, replace=True)
        self.assertEqual(snapshot(destination), before)

    def test_final_product_requires_notices_before_native_or_plist_mutation(self):
        app = self.root / "YueduReader.app"
        app.mkdir()
        with self.assertRaisesRegex(ValueError, "Notices directory is missing"):
            config.finalize(app, "a" * 40, with_jvm=True)
        notices.stage(app / "LegadoRuntime/Notices")
        (app / "LegadoRuntime/Notices/ios-tools/LICENSE").write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "bytes differ"):
            config.verify_jvm_payload(app)


if __name__ == "__main__":
    unittest.main()
