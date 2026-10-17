#!/usr/bin/env python3
"""Standard-library reference preparation tests; never execute Android sources.

Run: python scripts/legado-reference/test-prepare-reference.py -v
Optional real input: --archive /path/to/legado-master.zip
Without that pinned archive only the real-input tests are explicitly skipped;
all stage/manifest/path-attack cases use small generated ZIPs and run on CI.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import stat
import sys
import tempfile
import unittest
import warnings
import zipfile
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("prepare-reference.py")
SPEC = importlib.util.spec_from_file_location("legado_prepare_reference", SCRIPT)
reference = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(reference)
REAL_ARCHIVE = Path(os.environ.get("LEGADO_REFERENCE_ARCHIVE", "F:/legado-master.zip"))
LICENSE = b"Synthetic license fixture for extraction tests.\n"


def write_json(path: Path, value: object) -> None:
    path.write_bytes(reference._json_bytes(value))


def make_snapshot(directory: Path, additional: list[tuple[str, bytes, int]] = ()) -> dict:
    """Small reviewed-manifest fixture; extra ZIP entries are deliberately unlisted."""
    directory.mkdir()
    archive = directory / reference.SNAPSHOT_NAME
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", UserWarning)
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_STORED) as bundle:
            for path, data, mode in [("LICENSE", LICENSE, stat.S_IFREG | 0o644), *additional]:
                info = zipfile.ZipInfo(path, reference.FIXED_TIME)
                info.create_system = 3
                info.external_attr = mode << 16
                bundle.writestr(info, data)
    manifest = {
        "schemaVersion": 1, "originalArchiveSHA256": reference.ARCHIVE_SHA256,
        "originalArchiveBytes": reference.ARCHIVE_BYTES, "strippedRoot": reference.ARCHIVE_ROOT,
        "snapshotFileName": reference.SNAPSHOT_NAME, "zipCompression": "stored",
        "snapshotSHA256": reference._file_sha256(archive), "snapshotBytes": archive.stat().st_size,
        "retainedFileCount": 1, "retainedTotalBytes": len(LICENSE), "excluded": [],
        "stageOnlyAddedFile": reference.TEST_CONFIGURATION_PATH,
        "files": [{"path": "LICENSE", "bytes": len(LICENSE), "sha256": hashlib.sha256(LICENSE).hexdigest(),
                   "mode": "0644"}],
    }
    write_json(directory / reference.MANIFEST_NAME, manifest)
    return manifest


class StageTests(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory(prefix="legado-reference-test-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)

    def assert_rejected(self, source: Path, destination: Path) -> None:
        with self.assertRaises(reference.ReferenceError):
            reference.stage_reference(source, destination)
        self.assertFalse(os.path.lexists(destination))

    def test_stage_preserves_source_and_only_adds_inert_configuration(self) -> None:
        snapshot, destination = self.root / "snapshot", self.root / "stage"
        manifest = make_snapshot(snapshot)
        result = reference.stage_reference(snapshot, destination)
        self.assertEqual((destination / "LICENSE").read_bytes(), LICENSE)
        paths = {path.relative_to(destination).as_posix() for path in destination.rglob("*") if path.is_file()}
        self.assertEqual(paths, {"LICENSE", reference.TEST_CONFIGURATION_PATH})
        config_bytes = (destination / reference.TEST_CONFIGURATION_PATH).read_bytes()
        config = json.loads(config_bytes)
        self.assertEqual(config["project_info"]["project_id"], "legado-reference-inert")
        self.assertEqual({row["client_info"]["android_client_info"]["package_name"] for row in config["client"]},
                         {"com.legado.app", "com.legado.app.debug"})
        self.assertTrue(all("INERT" in row["api_key"][0]["current_key"] for row in config["client"]))
        self.assertFalse(result["buildExecuted"])
        self.assertFalse(result["originalSourceBytesChanged"])
        self.assertEqual(manifest["snapshotSHA256"], reference._file_sha256(snapshot / reference.SNAPSHOT_NAME))

    def test_tampered_snapshot_rejected_before_destination_creation(self) -> None:
        source = self.root / "snapshot"
        make_snapshot(source)
        with (source / reference.SNAPSHOT_NAME).open("ab") as output:
            output.write(b"tampered")
        self.assert_rejected(source, self.root / "destination")

    def test_tampered_per_file_hash_and_omitted_file_rejected(self) -> None:
        for field in ("sha256", "files"):
            with self.subTest(field=field):
                source = self.root / field
                manifest = make_snapshot(source)
                if field == "sha256":
                    manifest["files"][0]["sha256"] = "0" * 64
                else:
                    manifest["files"] = []
                write_json(source / reference.MANIFEST_NAME, manifest)
                self.assert_rejected(source, self.root / (field + "-destination"))

    def test_unsafe_zip_paths_rejected_even_with_updated_archive_hash(self) -> None:
        paths = ["../escape", "/escape", "C:/escape", "a\\escape", "a//escape", "a/./escape",
                 "a/../escape", "CON.txt", "trailing./file", "file:stream"]
        for index, path in enumerate(paths):
            with self.subTest(path=path):
                source = self.root / f"snapshot-{index}"
                make_snapshot(source, [(path, b"attack", stat.S_IFREG | 0o644)])
                self.assert_rejected(source, self.root / f"stage-{index}")
        self.assertFalse((self.root / "escape").exists())

    def test_duplicate_case_collision_symlink_and_file_parent_rejected(self) -> None:
        entries = [("LICENSE", b"duplicate", stat.S_IFREG | 0o644),
                   ("license", b"case alias", stat.S_IFREG | 0o644),
                   ("link", b"../outside", stat.S_IFLNK | 0o777),
                   ("LICENSE/child", b"file as directory", stat.S_IFREG | 0o644)]
        for index, entry in enumerate(entries):
            with self.subTest(entry=entry[0]):
                source = self.root / f"snapshot-{index}"
                make_snapshot(source, [entry])
                self.assert_rejected(source, self.root / f"stage-{index}")

    def test_extra_unlisted_snapshot_file_rejected(self) -> None:
        source = self.root / "snapshot"
        make_snapshot(source, [("extra.txt", b"unlisted", stat.S_IFREG | 0o644)])
        self.assert_rejected(source, self.root / "stage")

    def test_existing_file_or_directory_is_never_overwritten(self) -> None:
        source = self.root / "snapshot"
        make_snapshot(source)
        existing_file, existing_directory = self.root / "file", self.root / "directory"
        existing_file.write_bytes(b"keep file")
        existing_directory.mkdir()
        sentinel = existing_directory / "sentinel"
        sentinel.write_bytes(b"keep directory")
        for destination in (existing_file, existing_directory):
            with self.subTest(destination=destination.name), self.assertRaises(reference.ReferenceError):
                reference.stage_reference(source, destination)
        self.assertEqual(existing_file.read_bytes(), b"keep file")
        self.assertEqual(sentinel.read_bytes(), b"keep directory")

    def test_manifest_duplicates_invalid_types_and_secret_paths_rejected(self) -> None:
        for index, change in enumerate(("duplicate-json-key", "boolean-count", "secret-file")):
            with self.subTest(change=change):
                source = self.root / f"snapshot-{index}"
                manifest = make_snapshot(source)
                if change == "duplicate-json-key":
                    data = reference._json_bytes(manifest).decode("utf-8")
                    (source / reference.MANIFEST_NAME).write_text(data.replace('"schemaVersion": 1', '"schemaVersion": 2, "schemaVersion": 1'), encoding="utf-8")
                else:
                    if change == "boolean-count":
                        manifest["retainedFileCount"] = True
                    else:
                        manifest["files"][0]["path"] = ".env"
                    write_json(source / reference.MANIFEST_NAME, manifest)
                self.assert_rejected(source, self.root / f"stage-{index}")

    def test_size_limit_rejected_before_destination_creation(self) -> None:
        source = self.root / "snapshot"
        make_snapshot(source)
        with mock.patch.object(reference, "MAX_TOTAL_BYTES", len(LICENSE) - 1):
            self.assert_rejected(source, self.root / "stage")


class PackagePolicyTests(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory(prefix="legado-reference-policy-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)

    def original_fixture(self, entries: dict[str, bytes]) -> Path:
        archive = self.root / "original.zip"
        with zipfile.ZipFile(archive, "w") as bundle:
            for path, data in entries.items():
                bundle.writestr(reference.ARCHIVE_ROOT + path, data)
        return archive

    def test_original_identity_is_mandatory(self) -> None:
        archive = self.original_fixture({"LICENSE": LICENSE})
        with self.assertRaisesRegex(reference.ReferenceError, "byte size"):
            reference.package_archive(archive, self.root / "output")
        with mock.patch.object(reference, "ARCHIVE_BYTES", archive.stat().st_size):
            with self.assertRaisesRegex(reference.ReferenceError, "SHA-256"):
                reference.package_archive(archive, self.root / "output")
        self.assertFalse((self.root / "output").exists())

    def test_excluded_members_are_never_opened(self) -> None:
        archive = self.original_fixture({"LICENSE": LICENSE, ".github/workflows/legado.jks": b"do not read",
                                         "app/google-services.json": b"do not read"})
        original_reader = reference._read_member
        def guarded_reader(source, info):
            self.assertNotIn(".github/", info.filename)
            self.assertFalse(info.filename.endswith("google-services.json"))
            return original_reader(source, info)
        with mock.patch.object(reference, "ARCHIVE_BYTES", archive.stat().st_size), \
                mock.patch.object(reference, "ARCHIVE_SHA256", reference._file_sha256(archive)), \
                mock.patch.object(reference, "_read_member", side_effect=guarded_reader):
            manifest = reference.package_archive(archive, self.root / "output")
        self.assertEqual(len(manifest["excluded"]), 2)
        with zipfile.ZipFile(self.root / "output" / reference.SNAPSHOT_NAME) as bundle:
            self.assertEqual(bundle.namelist(), ["LICENSE"])

    def test_unexpected_secret_candidate_fails_package(self) -> None:
        for index, path in enumerate(("unexpected.pem", "keys/client.p12", ".env", "config/.env.production")):
            with self.subTest(path=path):
                archive = self.original_fixture({"LICENSE": LICENSE, path: b"unexpected secret candidate"})
                with mock.patch.object(reference, "ARCHIVE_BYTES", archive.stat().st_size), \
                        mock.patch.object(reference, "ARCHIVE_SHA256", reference._file_sha256(archive)):
                    with self.assertRaisesRegex(reference.ReferenceError, "sensitive-file candidate"):
                        reference.package_archive(archive, self.root / f"output-{index}")
                self.assertFalse((self.root / f"output-{index}").exists())


class PinnedArchiveTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not REAL_ARCHIVE.is_file():
            raise unittest.SkipTest("Pinned original archive unavailable; pass --archive to run real-input checks")
        temp = tempfile.TemporaryDirectory(prefix="legado-reference-pinned-")
        cls.addClassCleanup(temp.cleanup)
        cls.root, cls.archive = Path(temp.name), REAL_ARCHIVE
        cls.snapshot = cls.root / "snapshot"
        cls.manifest = reference.package_archive(cls.archive, cls.snapshot)

    def test_real_snapshot_is_byte_deterministic(self) -> None:
        second = self.root / "second"
        reference.package_archive(self.archive, second)
        for filename in (reference.SNAPSHOT_NAME, reference.MANIFEST_NAME):
            self.assertEqual((self.snapshot / filename).read_bytes(), (second / filename).read_bytes())

    def test_every_retained_original_file_is_unchanged_and_all_exclusions_recorded(self) -> None:
        expected_exclusions = []
        with zipfile.ZipFile(self.archive) as original, zipfile.ZipFile(self.snapshot / reference.SNAPSHOT_NAME) as bundle:
            for info in original.infolist():
                path = info.filename[len(reference.ARCHIVE_ROOT):]
                if not path:
                    continue
                reason = reference._exclusion(path.rstrip("/"), info.is_dir())
                if reason:
                    expected_exclusions.append(path)
                elif not info.is_dir():
                    self.assertEqual(original.read(info), bundle.read(path), path)
            names = bundle.namelist()
            self.assertFalse(any(name == ".github" or name.startswith(".github/") for name in names))
            self.assertNotIn(reference.TEST_CONFIGURATION_PATH, names)
            self.assertTrue(bundle.read("LICENSE"))
        self.assertEqual(sorted(expected_exclusions), [row["path"] for row in self.manifest["excluded"]])
        self.assertEqual(set(names), {row["path"] for row in self.manifest["files"]})

    def test_real_stage_preserves_all_file_hashes_and_adds_only_test_configuration(self) -> None:
        destination = self.root / "stage"
        reference.stage_reference(self.snapshot, destination)
        expected = {row["path"] for row in self.manifest["files"]}
        actual = {path.relative_to(destination).as_posix() for path in destination.rglob("*") if path.is_file()}
        self.assertEqual(actual, expected | {reference.TEST_CONFIGURATION_PATH})
        for row in self.manifest["files"]:
            self.assertEqual(reference._file_sha256(destination / row["path"]), row["sha256"], row["path"])
        self.assertEqual((destination / reference.TEST_CONFIGURATION_PATH).read_bytes(), reference.inert_google_services())


if __name__ == "__main__":
    arguments = argparse.ArgumentParser(add_help=False)
    arguments.add_argument("--archive", type=Path)
    selected, remaining = arguments.parse_known_args()
    if selected.archive is not None:
        REAL_ARCHIVE = selected.archive
    unittest.main(argv=[sys.argv[0], *remaining])
