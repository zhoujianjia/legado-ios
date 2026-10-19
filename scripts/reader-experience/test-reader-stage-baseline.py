#!/usr/bin/env python3
"""Offline collector guards using synthetic timings; no iOS latency is measured."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("reader_stage_baseline_tests", HERE / "reader-stage-baseline.py")
baseline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(baseline)
SOURCE = "a" * 40
DESTINATION = "id=12345678-1234-1234-1234-123456789ABC"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
SOURCES = {name: {"sha256": "b" * 64, "bytes": 100} for name in baseline.SOURCE_FILES}


def rows():
    return [{"schemaVersion": 1, "fixture": name, "stage": stage, "iteration": iteration,
             "ms": (iteration + 1) * 2, "outputCount": fixture["fixtureMinimumUTF16"]
                 if stage.startswith("document.") else (1 if stage == "page.first" else 8),
             **fixture, **copy.deepcopy(baseline.STYLE)}
            for name, fixture in baseline.fixture_protocol().items()
            for iteration in range(5) for stage in baseline.STAGES]


def raw_rows(values):
    return b"".join(b"2026-10-19 testhost[1] READER_ARCH_BENCH " +
                    json.dumps(row, ensure_ascii=False).encode("utf-8") + b"\r\n" for row in values)


class ReaderStageBaselineTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def write_json(self, name, value):
        path = self.root / name
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def environment(self):
        return {"schemaVersion": 1, "sourceCommit": SOURCE, "capturedAt": "2026-10-19T00:00:00+00:00",
                "configuration": "Debug", "platform": "iphonesimulator", "destination": DESTINATION,
                "developerDirectory": "/Applications/Xcode.app/Contents/Developer", "xcodeVersion": "27.0",
                "xcodeBuild": "18A1", "sdkVersion": "27.0", "runtimeIdentifier": RUNTIME,
                "runtimeVersion": "27.0", "runtimeBuild": "24A1", "deviceName": "Selected phone",
                "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.selected-phone",
                "sourceFiles": copy.deepcopy(SOURCES), "fixtures": baseline.fixture_protocol(),
                "style": copy.deepcopy(baseline.STYLE), "inputEvidence": {
                    name: {"path": str(self.root / (name + ".input")), "sha256": baseline.sha256(b"input bytes")}
                    for name in ("audit", "settings", "xcode", "sdk", "simulators")}}

    def collection_files(self, values=None):
        log = self.root / "run.log"
        log.write_bytes(b"ordinary build output\r\n" + raw_rows(rows() if values is None else values) + b"** TEST SUCCEEDED **\n")
        environment = self.environment()
        for item in environment["inputEvidence"].values():
            Path(item["path"]).write_bytes(b"input bytes")
        env = self.write_json("environment.json", environment)
        summary = self.write_json("summary.json", {"totalTestCount": 60, "passedTests": 60, "failedTests": 0,
            "skippedTests": 0, "expectedFailures": 0, "devicesAndConfigurations": [
                {"passedTests": 62, "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}]})
        audit = self.write_json("audit.json", {"sourceCommit": SOURCE})
        return log, env, self.root / "raw.log", self.root / "baseline.json", summary, audit

    def collect(self, files):
        with patch.object(baseline.smoke, "review_overlays"), \
                patch.object(baseline.smoke, "source_sha", return_value=SOURCE), \
                patch.object(baseline, "source_provenance", return_value=SOURCES):
            return baseline.collect(*files)

    def test_complete_capture_reports_only_five_sample_median_and_max(self):
        # Deliberately nonmonotonic log order: samples are grouped by identity.
        result = baseline.validate_rows(raw_rows(list(reversed(rows()))))
        self.assertEqual(len(result), 10)
        for metric in result:
            self.assertEqual(metric["samples"], 5)
            self.assertEqual(metric["medianMs"], 6)
            self.assertEqual(metric["maxMs"], 10)
            self.assertNotIn("p95Ms", metric)

    def test_fixture_protocol_has_actual_generated_bytes_and_distinct_hashes(self):
        fixtures = baseline.fixture_protocol()
        self.assertEqual(set(fixtures), {"plain-10k", "plain-100k"})
        # 40/400 paragraphs, each 256 BMP characters at 3 UTF-8 bytes plus
        # eight ASCII wrapper bytes; the XHTML envelope is 212/213 bytes.
        self.assertEqual(fixtures["plain-10k"]["fixtureHTMLBytes"], 40 * (256 * 3 + 8) + 212)
        self.assertEqual(fixtures["plain-100k"]["fixtureHTMLBytes"], 400 * (256 * 3 + 8) + 213)
        self.assertNotEqual(fixtures["plain-10k"]["fixtureSHA256"], fixtures["plain-100k"]["fixtureSHA256"])

    def test_missing_extra_and_duplicate_records_cannot_meet_coverage(self):
        good = rows()
        for broken in ([], good[:-1], good + [good[0]], good[:-1] + [good[0]]):
            with self.subTest(count=len(broken)), self.assertRaises(ValueError):
                baseline.validate_rows(raw_rows(broken))

    def test_unknown_fixture_stage_and_iteration_are_rejected(self):
        for key, value in (("fixture", "private-epub"), ("stage", "source.css.first"),
                           ("iteration", -1), ("iteration", 5), ("iteration", True), ("iteration", 1.0)):
            values = rows()
            values[0][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                baseline.validate_rows(raw_rows(values))

    def test_invalid_timings_and_counts_are_rejected(self):
        for key, value in (("ms", -0.01), ("ms", float("nan")), ("ms", float("inf")),
                           ("ms", True), ("ms", "2"), ("outputCount", 0), ("outputCount", -1),
                           ("outputCount", True), ("outputCount", 1.5), ("outputCount", 10)):
            values = rows()
            values[0][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                baseline.validate_rows(raw_rows(values))

    def test_every_fixture_and_style_field_is_checked(self):
        changes = {"schemaVersion": True, "fixtureSHA256": "c" * 64, "fixtureHTMLBytes": 1,
                   "fixtureMinimumUTF16": 1, "renderWidth": 844, "renderHeight": 390,
                   "fontSize": 17, "lineHeightMultiple": 1.6, "paragraphSpacing": 0,
                   "lineSpacing": True, "letterSpacing": 1, "writingMode": "verticalRL",
                   "contentInsets": [0, 0, 0, True]}
        for name, value in changes.items():
            values = rows()
            values[0][name] = value
            with self.subTest(field=name), self.assertRaises(ValueError):
                baseline.validate_rows(raw_rows(values))

    def test_missing_unknown_and_duplicate_json_fields_fail_closed(self):
        for name in rows()[0]:
            values = rows()
            del values[0][name]
            with self.subTest(missing=name), self.assertRaises(ValueError):
                baseline.validate_rows(raw_rows(values))
        values = rows()
        values[0]["newUnreviewedField"] = 1
        with self.assertRaisesRegex(ValueError, "unknown"):
            baseline.validate_rows(raw_rows(values))
        raw = raw_rows(rows()).replace(b'"ms": 2', b'"ms": 999, "ms": 2', 1)
        with self.assertRaisesRegex(ValueError, "Duplicate metric"):
            baseline.validate_rows(raw)

    def test_document_reuse_first_page_and_coverage_counts_have_semantic_guards(self):
        for index, count in ((1, 10241), (2, 2), (3, 20000), (4, 20000)):
            values = rows()
            values[index]["outputCount"] = count
            with self.subTest(index=index), self.assertRaises(ValueError):
                baseline.validate_rows(raw_rows(values))

    def test_environment_requires_source_fixture_and_debug_simulator_provenance(self):
        baseline.validate_environment(self.environment())
        for name, value in (("sourceCommit", "short"), ("configuration", "Release"),
                            ("platform", "iphoneos"), ("destination", "name=Phone"),
                            ("runtimeBuild", ""), ("sdkVersion", None), ("fixtures", {}),
                            ("style", {}), ("sourceFiles", {}), ("inputEvidence", {})):
            with self.subTest(field=name), self.assertRaises(ValueError):
                baseline.validate_environment({**self.environment(), name: value})

    def test_capture_resolves_selected_device_runtime_and_actual_sdk(self):
        settings = [{"target": baseline.config.MAIN_TARGET, "buildSettings": {
            "CONFIGURATION": "Debug", "PLATFORM_NAME": "iphonesimulator", "SDK_VERSION": "27.0"}}]
        simulators = {"devices": {RUNTIME: [{"udid": DESTINATION[3:], "name": "Selected phone",
            "deviceTypeIdentifier": "type-id", "isAvailable": True}]}, "runtimes": [
                {"identifier": RUNTIME, "version": "27.0", "buildversion": "24A1", "isAvailable": True}]}
        args = ({"sourceCommit": SOURCE}, settings, "Xcode 27.0\nBuild version 18A1\n", "27.0\n",
                simulators, DESTINATION, "/Applications/Xcode.app/Contents/Developer")
        with patch.object(baseline.smoke, "review_overlays"), \
                patch.object(baseline, "source_provenance", return_value=SOURCES):
            result = baseline.capture_environment(*args)
            self.assertEqual(result["runtimeIdentifier"], RUNTIME)
            self.assertEqual(result["runtimeBuild"], "24A1")
            self.assertEqual(result["xcodeBuild"], "18A1")
            for index, value in ((1, settings * 2), (2, "Xcode missing build"), (3, "26.0"),
                                 (4, {**simulators, "runtimes": []}), (5, "name=Selected phone")):
                broken = list(args)
                broken[index] = value
                with self.subTest(index=index), self.assertRaises(ValueError):
                    baseline.capture_environment(*broken)
            for collection, field in (("devices", "isAvailable"), ("runtimes", "isAvailable")):
                broken = copy.deepcopy(simulators)
                selected = broken[collection][RUNTIME][0] if collection == "devices" else broken[collection][0]
                selected[field] = False
                with self.subTest(collection=collection), self.assertRaises(ValueError):
                    baseline.capture_environment(*args[:4], broken, *args[5:])

    def test_source_provenance_rejects_worktree_bytes_differing_from_head(self):
        for name in baseline.SOURCE_FILES:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"committed source")
        with patch.object(baseline, "REPO", self.root), patch.object(baseline.smoke, "git", return_value=b"committed source"):
            self.assertEqual(set(baseline.source_provenance()), set(baseline.SOURCE_FILES))
            (self.root / baseline.SOURCE_FILES[1]).write_bytes(b"modified fixture")
            with self.assertRaisesRegex(ValueError, "differs from HEAD"):
                baseline.source_provenance()

    def test_collection_preserves_exact_raw_bytes_and_claim_boundaries(self):
        files = self.collection_files()
        result = self.collect(files)
        raw = files[2].read_bytes()
        self.assertEqual(raw, raw_rows(rows()))
        self.assertEqual(result["rawRows"]["sha256"], baseline.sha256(raw))
        self.assertEqual(result["status"], "passed")
        self.assertEqual(len(result["metrics"]), 10)
        for field in ("speedupEstablished", "coldStartupMeasured", "peakProcessMemoryMeasured", "physicalDeviceMeasured"):
            self.assertIs(result[field], False)
        self.assertEqual(json.loads(files[3].read_text()), result)

    def test_incomplete_metrics_are_retained_without_a_passing_result(self):
        files = self.collection_files(rows()[:-1])
        with self.assertRaisesRegex(ValueError, "50 unique"):
            self.collect(files)
        self.assertEqual(files[2].read_bytes(), raw_rows(rows()[:-1]))
        self.assertFalse(files[3].exists())

    def test_nonzero_test_wrapper_exit_rejects_a_complete_metric_log(self):
        files = self.collection_files()
        with self.assertRaisesRegex(ValueError, "wrapper failed"):
            baseline.collect(*files, test_exit_status=1)
        self.assertEqual(files[2].read_bytes(), raw_rows(rows()))
        self.assertFalse(files[3].exists())

    def test_failed_or_skipped_assertions_prevent_accepting_valid_timings(self):
        files = self.collection_files()
        summary = json.loads(files[4].read_text())
        summary["skippedTests"] = 1
        files[4].write_text(json.dumps(summary))
        with self.assertRaisesRegex(ValueError, "gate failed"):
            self.collect(files)
        self.assertTrue(files[2].exists())
        self.assertFalse(files[3].exists())

    def test_changed_environment_input_prevents_acceptance(self):
        files = self.collection_files()
        (self.root / "sdk.input").write_bytes(b"changed SDK evidence")
        with self.assertRaisesRegex(ValueError, "input changed"):
            self.collect(files)
        self.assertFalse(files[3].exists())

    def test_source_drift_after_environment_capture_prevents_acceptance(self):
        files = self.collection_files()
        with patch.object(baseline.smoke, "review_overlays"), \
                patch.object(baseline.smoke, "source_sha", return_value="c" * 40):
            with self.assertRaisesRegex(ValueError, "Source changed"):
                baseline.collect(*files)
        self.assertTrue(files[2].exists())
        self.assertFalse(files[3].exists())

    def test_prior_raw_or_result_evidence_is_never_overwritten(self):
        files = self.collection_files()
        for path in (files[2], files[3]):
            path.write_bytes(b"prior evidence")
            with self.assertRaisesRegex(ValueError, "overwrite"):
                self.collect(files)
            self.assertEqual(path.read_bytes(), b"prior evidence")
            path.unlink()


if __name__ == "__main__":
    unittest.main()
