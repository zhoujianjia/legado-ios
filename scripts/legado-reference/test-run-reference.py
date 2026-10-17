#!/usr/bin/env python3
"""Check execution/report binding with mocked external tools; never run Gradle."""
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("run_reference_test", HERE / "run-reference.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class ReferenceExecutionBindingTests(unittest.TestCase):
    def exercise(self, mode):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            inputs = {"fixtureSHA256": "f" * 64, "harnessSHA256": "b" * 64,
                      "initScriptSHA256": "d" * 64, "buildMinSdkVersion": 26,
                      "sourceCommit": "c" * 40, "overlays": []}
            manifest = {"originalArchiveSHA256": "a" * 64}
            (output / "reference-inputs.json").write_text(json.dumps(inputs), encoding="utf-8")
            captured = {}

            def fake_gradle(command, log_path, timeout):
                prefix = "-Pandroid.testInstrumentationRunnerArguments.referenceRunId="
                matches = [argument[len(prefix):] for argument in command if argument.startswith(prefix)]
                self.assertEqual(len(matches), 1)
                captured["runId"] = matches[0]
                self.assertEqual(str(uuid.UUID(matches[0])), matches[0])
                self.assertIn("-Pandroid.testInstrumentationRunnerArguments.class=" + runner.TEST_CLASS, command)
                self.assertEqual(command.count("-I"), 1)
                self.assertEqual(command[command.index("-I") + 1], str(runner.STAGED_INIT_SCRIPT))
                return 1 if mode == "instrumentation_failed" else 0

            def fake_subprocess(command, **kwargs):
                if "exec-out" in command:
                    report = {"referenceRunId": captured["runId"], "passed": mode != "failed_report",
                              "referenceKind": "original-archive-android-instrumentation",
                              "applicationClass": "io.legado.app.App",
                              "applicationMinSdkVersion": 26,
                              "fixtureSHA256": inputs["fixtureSHA256"],
                              "originalArchiveSHA256": manifest["originalArchiveSHA256"]}
                    if mode == "stale": report["referenceRunId"] = "00000000-0000-0000-0000-000000000000"
                    if mode == "missing_id": del report["referenceRunId"]
                    if mode == "wrong_min_sdk": report["applicationMinSdkVersion"] = 23
                    if mode == "missing_min_sdk": del report["applicationMinSdkVersion"]
                    return SimpleNamespace(returncode=0, stdout=json.dumps(report).encode("utf-8"), stderr=b"")
                self.assertIn("logcat", command)
                return SimpleNamespace(returncode=0, stdout=b"synthetic logcat\n", stderr=b"")

            caught = None
            with patch.multiple(runner, OUTPUT=output), \
                    patch.object(runner, "verify_original_files", return_value=manifest), \
                    patch.object(runner, "adb_prefix", return_value=["adb", "-s", "emulator-5554"]), \
                    patch.object(runner, "digest", side_effect=lambda path: inputs["fixtureSHA256"] if path == runner.FIXTURE
                                 else inputs["initScriptSHA256"] if path in (runner.INIT_SCRIPT, runner.STAGED_INIT_SCRIPT)
                                 else inputs["harnessSHA256"]), \
                    patch.object(runner, "run_logged", side_effect=fake_gradle), \
                    patch.object(runner.subprocess, "run", side_effect=fake_subprocess):
                try:
                    runner.execute()
                except RuntimeError as error:
                    caught = error
            record = json.loads((output / "execution.json").read_text(encoding="utf-8"))
            observed = json.loads((output / "android-report-observed.json").read_text(encoding="utf-8"))
            golden = json.loads((output / "android-golden.json").read_text(encoding="utf-8")) if (output / "android-golden.json").exists() else None
            return record, observed, golden, captured, caught

    def test_current_uuid_is_passed_to_runner_and_bound_to_report(self):
        record, observed, golden, command, failure = self.exercise("current")
        self.assertIsNone(failure)
        self.assertTrue(record["passed"])
        self.assertEqual(record["referenceRunId"], command["runId"])
        self.assertEqual(golden["referenceRunId"], command["runId"])
        self.assertEqual(observed, golden)

    def test_stale_or_missing_uuid_cannot_be_promoted(self):
        for mode in ("stale", "missing_id"):
            with self.subTest(mode=mode):
                record, observed, golden, command, failure = self.exercise(mode)
                self.assertIsInstance(failure, RuntimeError)
                self.assertFalse(record["passed"])
                self.assertIsNone(golden)
                self.assertNotEqual(observed.get("referenceRunId"), command["runId"])
                self.assertIn("stale", record["failure"])

    def test_failed_current_report_retains_its_run_id_and_partial_trace(self):
        record, observed, golden, command, failure = self.exercise("failed_report")
        self.assertIsInstance(failure, RuntimeError)
        self.assertFalse(record["passed"])
        self.assertFalse(golden["passed"])
        self.assertEqual(golden["referenceRunId"], command["runId"])

    def test_nonzero_instrumentation_cannot_pass_with_a_valid_report(self):
        record, observed, golden, command, failure = self.exercise("instrumentation_failed")
        self.assertIsInstance(failure, RuntimeError)
        self.assertFalse(record["passed"])
        self.assertEqual(record["instrumentationExitCode"], 1)
        self.assertEqual(golden["referenceRunId"], command["runId"])

    def test_missing_or_wrong_installed_apk_minimum_sdk_cannot_pass(self):
        for mode in ("wrong_min_sdk", "missing_min_sdk"):
            with self.subTest(mode=mode):
                record, observed, golden, command, failure = self.exercise(mode)
                self.assertIsInstance(failure, RuntimeError)
                self.assertFalse(record["passed"])
                self.assertIn("minimum SDK", record["failure"])


class ReferenceMinimumSdkConfigurationTests(unittest.TestCase):
    def test_stage_adds_external_init_and_preserves_original_gradle_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, snapshot, output = root / "source", root / "snapshot", root / "output"
            original = source / "app/build.gradle.kts"
            original.parent.mkdir(parents=True)
            original_bytes = b'android { defaultConfig { minSdk = 23 } }\n'
            original.write_bytes(original_bytes)
            snapshot.mkdir()
            manifest = {"originalArchiveSHA256": "a" * 64, "snapshotSHA256": "c" * 64,
                        "files": [{"path": "app/build.gradle.kts", "bytes": len(original_bytes),
                                   "sha256": runner.digest(original)}]}
            (snapshot / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            staged_init = source / "reference.init.gradle"
            with patch.multiple(runner, SOURCE=source, SNAPSHOT=snapshot, OUTPUT=output,
                                STAGED_INIT_SCRIPT=staged_init), \
                    patch.object(runner.subprocess, "check_output", return_value="c" * 40), \
                    patch("builtins.print"):
                runner.stage()
                runner.verify_original_files()
            record = json.loads((output / "reference-inputs.json").read_bytes())
            self.assertEqual(original.read_bytes(), original_bytes)
            self.assertEqual(staged_init.read_bytes(), runner.INIT_SCRIPT.read_bytes())
            self.assertEqual(record["buildMinSdkVersion"], 26)
            self.assertEqual(record["initScriptSHA256"], runner.digest(staged_init))
            self.assertIn({"path": "reference.init.gradle", "sha256": runner.digest(staged_init)}, record["overlays"])
            self.assertEqual(record["originalFilesVerified"], 1)
            self.assertIn("23 -> 26", record["testConfiguration"]["minimumSdk"])

    def test_changed_staged_init_is_rejected_before_any_external_execution(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            inputs = {"fixtureSHA256": "f" * 64, "harnessSHA256": "b" * 64,
                      "initScriptSHA256": "d" * 64, "buildMinSdkVersion": 26}
            (output / "reference-inputs.json").write_text(json.dumps(inputs), encoding="utf-8")
            def observed_digest(path):
                return {runner.FIXTURE: "f" * 64, runner.HARNESS: "b" * 64,
                        runner.INIT_SCRIPT: "d" * 64, runner.STAGED_INIT_SCRIPT: "e" * 64}[path]
            with patch.object(runner, "OUTPUT", output), \
                    patch.object(runner, "verify_original_files", return_value={}), \
                    patch.object(runner, "digest", side_effect=observed_digest), \
                    patch.object(runner, "adb_prefix") as adb, \
                    patch.object(runner, "run_logged") as gradle:
                with self.assertRaisesRegex(ValueError, "init script changed"):
                    runner.execute()
                adb.assert_not_called()
                gradle.assert_not_called()


if __name__ == "__main__":
    unittest.main()
