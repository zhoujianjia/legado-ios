#!/usr/bin/env python3
"""Portable bounded-collector guards; synthetic files do not establish native execution."""
import importlib.util
import json
import os
import plistlib
import tempfile
import time
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
path = REPO / "scripts/reader-experience/collect-native-diagnostics.py"
spec = importlib.util.spec_from_file_location("collector_check", path)
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)


class CollectorChecks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.patch = patch.object(c, "REPO", self.root)
        self.patch.start()
        self.source = "a" * 40
        self.udid = "11111111-1111-1111-1111-111111111111"
        self.since = time.time() - 10
        self.app = self.root / "app"
        self.app.mkdir()
        self.data = self.root / "data"
        self.data.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.info = {"CFBundleIdentifier": c.config.MAIN_BUNDLE,
                     "CFBundleSupportedPlatforms": ["iPhoneSimulator"], **c.config.LOCAL_FLAGS,
                     "GatewayBaseURL": "", "GIDClientID": c.config.GOOGLE_CLIENT}
        (self.app / "Info.plist").write_bytes(plistlib.dumps(self.info))
        self.record = self.root / "overlays.json"
        self.audit = {"sourceCommit": self.source, "configuration": "Debug",
                      "deliveredIPAModified": False,
                      "infoOverlay": {"localFlags": c.config.LOCAL_FLAGS, "gatewayConfigured": False},
                      "preparedAt": datetime.fromtimestamp(self.since, timezone.utc).isoformat()}
        self.record.write_text(json.dumps(self.audit))
        self.native = self.data / "Library/Application Support/LegadoRuntimeDiagnostics/current"
        self.native.mkdir(parents=True)
        (self.native / "stages.log").write_text("JNI_CreateJavaVM.before\n")
        (self.native / "book_sources.json").write_text("DO_NOT_COPY")
        self.crashes = self.home / "Library/Logs/DiagnosticReports"
        self.crashes.mkdir(parents=True)
        self.ips = self.crashes / "YueduReader-test.ips"
        self.ips.write_text(json.dumps({"app_name": "YueduReader", "bundleID": c.config.MAIN_BUNDLE})
                           + "\n" + json.dumps({"threads": []}))

    def tearDown(self):
        self.patch.stop()
        self.tmp.cleanup()

    def run_collection(self):
        return c.collect(self.udid, self.root / ".build/out", self.record, self.source,
                         run=lambda args: str(self.app if args[-1] == "app" else self.data), home=self.home)

    def test_bounded_whitelist_and_hashes(self):
        result = self.run_collection()
        self.assertEqual(result["collectionStatus"], "collected")
        self.assertEqual(len(result["files"]), 2)
        self.assertTrue(result["hasNativeDiagnostics"])
        self.assertTrue(result["hasCrashReports"])
        self.assertFalse(result["runtimeValidationEstablished"])
        self.assertFalse(any("book_sources" in entry["path"] for entry in result["files"]))

    def test_no_overwrite(self):
        self.run_collection()
        with self.assertRaises(FileExistsError):
            self.run_collection()

    def test_only_exact_task_trace_names_are_copied(self):
        for name in c.TASK_TRACE_NAMES:
            (self.native / name).write_text('{"stage":"cancel.lookup","found":true}\n')
        for name in ("runtime-events.jsonl.extra", "private-events.jsonl", "native-task-events.json"):
            (self.native / name).write_text("DO_NOT_COPY")
        result = self.run_collection()
        copied = {entry["path"].split("/")[-1] for entry in result["files"]}
        self.assertTrue(c.TASK_TRACE_NAMES <= copied)
        self.assertFalse(any("private-events" in name or name.endswith(".extra") for name in copied))

    def test_task_trace_has_its_own_64_kib_limit(self):
        (self.native / "runtime-events.jsonl").write_bytes(b"x" * (c.MAX_TASK_TRACE_BYTES + 1))
        result = self.run_collection()
        self.assertEqual(result["collectionStatus"], "partial")
        self.assertFalse(any(entry["path"].endswith("runtime-events.jsonl") for entry in result["files"]))
        self.assertTrue(any("independent 64 KiB" in error for error in result["errors"]))

    def test_old_crash_rejected(self):
        os.utime(self.ips, (self.since - 60, self.since - 60))
        result = self.run_collection()
        self.assertFalse(result["hasCrashReports"])
        self.assertTrue(result["skipped"])

    def test_wrong_app_not_read(self):
        self.info["YueduLocalExperience"] = False
        (self.app / "Info.plist").write_bytes(plistlib.dumps(self.info))
        result = self.run_collection()
        self.assertEqual(result["collectionStatus"], "unavailable")
        self.assertEqual(result["files"], [])

    def test_source_mismatch_not_read(self):
        self.audit["sourceCommit"] = "b" * 40
        self.record.write_text(json.dumps(self.audit))
        result = self.run_collection()
        self.assertEqual(result["files"], [])
        self.assertTrue(result["errors"])

    def test_missing_container_is_unavailable(self):
        def fail(arguments):
            raise FileNotFoundError("synthetic app not installed")
        result = c.collect(self.udid, self.root / ".build/out", self.record, self.source,
                           run=fail, home=self.home)
        self.assertEqual(result["collectionStatus"], "unavailable")
        self.assertTrue(result["errors"])

    def test_oversized_native_file_is_partial(self):
        with patch.object(c, "MAX_FILE_BYTES", 10000):
            (self.native / "vm-output.log").write_bytes(b"x" * 10001)
            result = self.run_collection()
        self.assertEqual(result["collectionStatus"], "partial")
        self.assertTrue(result["errors"])
        self.assertFalse(any(entry["path"].endswith("vm-output.log") for entry in result["files"]))

    def test_parent_escape_rejected(self):
        with self.assertRaises(ValueError):
            c.collect(self.udid, self.root / ".build/../outside", self.record, self.source,
                      run=lambda args: "", home=self.home)

    def test_wrong_crash_identity_rejected(self):
        self.ips.write_text(json.dumps({"app_name": "YueduReader", "bundleID": "other.app"}))
        result = self.run_collection()
        self.assertEqual(result["collectionStatus"], "partial")
        self.assertFalse(result["hasCrashReports"])

    def test_directory_entry_limit(self):
        with patch.object(c, "MAX_FILES", 1):
            result = self.run_collection()
        self.assertEqual(result["collectionStatus"], "unavailable")
        self.assertEqual(result["files"], [])
        self.assertIn("directory entry limit", result["errors"][0])

    def test_total_read_budget(self):
        with patch.object(c, "MAX_TOTAL_BYTES", 1):
            result = self.run_collection()
        self.assertEqual(result["collectionStatus"], "unavailable")
        self.assertEqual(result["files"], [])
        self.assertTrue(any("before read" in error for error in result["errors"]))

    def test_checked_link_diagnostic_names_rejected_ancestor_and_requested_path(self):
        requested = self.root / "alias/child/stages.log"
        rejected = self.root / "alias"
        # Model an OS-reported link without requiring Windows symlink privileges.
        with patch.object(Path, "is_symlink", lambda path: path == rejected):
            with self.assertRaises(ValueError) as raised:
                c.checked(requested)
        self.assertIn("rejectedPart=" + str(rejected), str(raised.exception))
        self.assertIn("requestedPath=" + str(requested), str(raised.exception))

    def test_host_crash_root_alias_is_rejected_with_origin_and_no_crash_copy(self):
        rejected = self.home / "Library/Logs"
        with patch.object(Path, "is_symlink", lambda path: path == rejected):
            result = self.run_collection()
        self.assertEqual(result["collectionStatus"], "partial")
        self.assertFalse(result["hasCrashReports"])
        self.assertEqual(len(result["files"]), 1)
        self.assertIn("origin=host-ips", result["errors"][0])
        self.assertIn("rejectedPart=" + str(rejected), result["errors"][0])
        self.assertIn("requestedPath=" + str(self.crashes), result["errors"][0])

    def test_simulator_crash_root_alias_is_rejected_with_its_own_origin(self):
        requested = self.home / "Library/Developer/CoreSimulator/Devices" / self.udid / "data/Library/Logs/CrashReporter"
        with patch.object(Path, "is_symlink", lambda path: path == requested):
            result = self.run_collection()
        self.assertEqual(result["collectionStatus"], "partial")
        self.assertEqual(len(result["files"]), 2)
        self.assertTrue(result["hasCrashReports"])
        self.assertIn("origin=simulator-ips", result["errors"][0])
        self.assertIn("rejectedPart=" + str(requested), result["errors"][0])
        self.assertIn("requestedPath=" + str(requested), result["errors"][0])


if __name__ == "__main__":
    unittest.main(verbosity=2)
