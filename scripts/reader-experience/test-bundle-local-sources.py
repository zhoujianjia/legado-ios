import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
import zipfile


spec = importlib.util.spec_from_file_location("local_sources_packaging", Path(__file__).with_name("bundle-local-sources.py"))
packaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packaging)


class LocalSourcePackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.ipa, self.manifest, self.sources = [self.root / name for name in ("cloud.ipa", "cloud.json", "sources.json")]
        self.app_info = {"CFBundleIdentifier": "local.zhoujianjia.legado-reader", "YueduLocalExperience": True,
                         "YueduExperienceSourceCommit": "a" * 40, "GitCommitSHA": "a" * 7}
        self.write_ipa()
        self.refresh_manifest()
        self.sources.write_bytes(b'[{"bookSourceUrl":"https://fixture.invalid","header":"private-test-cookie"}]')

    def write_ipa(self):
        with zipfile.ZipFile(self.ipa, "w") as archive:
            archive.writestr("Payload/YueduReader.app/Info.plist", plistlib.dumps(self.app_info))
            entry = zipfile.ZipInfo("Payload/YueduReader.app/YueduReader")
            entry.create_system = 3
            entry.external_attr = 0o100755 << 16
            archive.writestr(entry, b"unchanged executable fixture")

    def refresh_manifest(self):
        self.manifest.write_text(json.dumps({"ipaSHA256": packaging.digest(self.ipa), "ipaBytes": self.ipa.stat().st_size,
                                            "signed": False, "sourceCommit": "a" * 40}), encoding="utf-8")

    def run_bundle(self):
        return packaging.bundle(self.ipa, self.manifest, self.sources, self.root / "local.ipa", self.root / "local.json")

    def test_exact_source_bytes_and_original_executable_permissions_are_preserved(self):
        original = self.ipa.read_bytes()
        report = self.run_bundle()
        self.assertEqual(self.ipa.read_bytes(), original)
        self.assertFalse(report["bookSourcesUploaded"])
        self.assertEqual(report["originalNonSourceEntriesVerified"], 2)
        with zipfile.ZipFile(self.root / "local.ipa") as archive:
            self.assertEqual(archive.read("Payload/YueduReader.app/BuiltInBookSources.json"), self.sources.read_bytes())
            self.assertEqual(archive.getinfo("Payload/YueduReader.app/YueduReader").external_attr, 0o100755 << 16)
        self.assertNotIn("private-test-cookie", json.dumps(report))

    def test_wrong_cloud_hash_is_rejected_before_creating_output(self):
        value = json.loads(self.manifest.read_bytes()); value["ipaSHA256"] = "0" * 64
        self.manifest.write_text(json.dumps(value), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "does not match"):
            self.run_bundle()
        self.assertFalse((self.root / "local.ipa").exists())

    def test_cloud_manifest_requires_a_full_lowercase_source_commit(self):
        original = json.loads(self.manifest.read_bytes())
        for value in ("missing", None, "", "a" * 7, "a" * 39, "a" * 41, "A" * 40, "g" * 40, "a" * 40 + "\n"):
            with self.subTest(commit=value):
                manifest = dict(original)
                if value == "missing":
                    manifest.pop("sourceCommit")
                else:
                    manifest["sourceCommit"] = value
                self.manifest.write_text(json.dumps(manifest), encoding="utf-8")
                with self.assertRaisesRegex(ValueError, "source commit"):
                    self.run_bundle()
                self.assertFalse((self.root / "local.ipa").exists())
                self.assertFalse((self.root / "local.json").exists())

    def test_embedded_full_commit_must_match_the_hash_bound_cloud_manifest(self):
        for value in ("missing", "b" * 40, "a" * 7):
            with self.subTest(commit=value):
                if value == "missing":
                    self.app_info.pop("YueduExperienceSourceCommit", None)
                else:
                    self.app_info["YueduExperienceSourceCommit"] = value
                self.write_ipa()
                self.refresh_manifest()  # Hash and bytes match; only the stamp is wrong.
                with self.assertRaisesRegex(ValueError, "source stamps"):
                    self.run_bundle()
                self.assertFalse((self.root / "local.ipa").exists())
                self.assertFalse((self.root / "local.json").exists())

    def test_embedded_short_commit_cannot_be_missing_or_conflict_with_the_full_commit(self):
        for value in ("missing", "b" * 7, "a" * 8, "a" * 40, 7):
            with self.subTest(commit=value):
                if value == "missing":
                    self.app_info.pop("GitCommitSHA", None)
                else:
                    self.app_info["GitCommitSHA"] = value
                self.write_ipa()
                self.refresh_manifest()
                with self.assertRaisesRegex(ValueError, "source stamps"):
                    self.run_bundle()
                self.assertFalse((self.root / "local.ipa").exists())
                self.assertFalse((self.root / "local.json").exists())

    def test_signed_application_is_rejected(self):
        with zipfile.ZipFile(self.ipa, "a") as archive:
            archive.writestr("Payload/YueduReader.app/_CodeSignature/CodeResources", b"signature fixture")
        self.refresh_manifest()
        with self.assertRaisesRegex(ValueError, "unsigned main"):
            self.run_bundle()

    def test_original_inputs_and_previous_outputs_are_never_overwritten(self):
        self.run_bundle()
        before = (self.root / "local.ipa").read_bytes()
        with self.assertRaisesRegex(ValueError, "absent output"):
            self.run_bundle()
        self.assertEqual((self.root / "local.ipa").read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
