#!/usr/bin/env python3
"""Fail closed on stale, skipped, failed or unowned online-reader evidence."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("online_smoke_tested", HERE / "run-online-smoke.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
SOURCE = "b" * 40
RUN = "12345678-1234-1234-1234-123456789abc"
READY = {"schemaVersion": 1, "runId": RUN, "origin": "http://localhost:18769",
         "baseURL": "http://localhost:18769/fixture/" + RUN,
         "sourceURL": "http://localhost:18769/fixture/" + RUN + "/sources.json"}
SUMMARY = {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}


class OnlineSmokeToolsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name)
        self.process = {"sourceCommit": SOURCE, "commandExitCode": 0,
                        "fixtureStopped": True, "issue": None, "ready": READY}
        self.trace = {"runId": RUN}
        self.verify = Mock(return_value={"verified": True})

    def verdict(self, summary=None):
        for filename, value in (("online-fixture-process.json", self.process),
                                ("online-fixture-trace.json", self.trace)):
            (self.work / filename).write_bytes(json.dumps(value).encode("utf-8"))
        with patch.object(runner.smoke.config, "checked_path", side_effect=lambda value: value), \
                patch.object(runner.smoke, "source_sha", return_value=SOURCE), \
                patch.object(runner, "load", return_value=SimpleNamespace(verify_trace=self.verify)):
            return runner.result(self.work, summary or SUMMARY)

    def test_success_requires_trace_verifier_bound_to_owned_run_and_keeps_device_pending(self):
        result = self.verdict()
        self.verify.assert_called_once_with(self.trace, expected_run_id=RUN)
        self.assertEqual(result["targetedTests"]["passedTests"], 1)
        self.assertFalse(result["deviceValidationPassed"])
        self.assertFalse(result["deliveredIPAExecuted"])
        self.assertFalse(result["provesFullLegadoCompatibility"])

    def test_stale_source_command_failure_or_live_fixture_cannot_pass(self):
        for field, bad in (("sourceCommit", "a" * 40), ("commandExitCode", 1),
                           ("commandExitCode", False), ("fixtureStopped", False),
                           ("issue", "readiness failed")):
            with self.subTest(field=field, value=bad):
                original = self.process
                self.process = {**original, field: bad}
                with self.assertRaisesRegex(ValueError, "stopped owned fixture"):
                    self.verdict()
                self.process = original

    def test_stale_trace_and_fixture_verification_failure_cannot_pass(self):
        self.trace = {"runId": "old-run-id"}
        with self.assertRaisesRegex(ValueError, "does not belong"):
            self.verdict()
        self.trace = {"runId": RUN}
        self.verify.side_effect = ValueError("missing actual chapter requests")
        with self.assertRaisesRegex(ValueError, "actual chapter"):
            self.verdict()

    def test_no_executed_tests_extra_tests_or_skips_are_rejected(self):
        for field, bad in (("totalTestCount", 0), ("totalTestCount", 2), ("passedTests", 0),
                           ("failedTests", 1), ("skippedTests", 1)):
            with self.subTest(field=field, value=bad), self.assertRaises(ValueError):
                self.verdict({**SUMMARY, field: bad})

    def test_readiness_rejects_another_origin_old_source_path_or_non_run_id(self):
        runner.validate_ready(READY)
        for field, bad in (("origin", "https://example.com"), ("runId", "../other-run"),
                           ("sourceURL", READY["origin"] + "/sources.json"),
                           ("baseURL", READY["origin"] + "/fixture/old-run")):
            with self.subTest(field=field, value=bad), self.assertRaises(ValueError):
                runner.validate_ready({**READY, field: bad})

    def test_readiness_does_not_accept_an_already_exited_process_and_stop_reaps_after_timeout(self):
        exited = Mock()
        exited.poll.return_value = 1
        with self.assertRaisesRegex(RuntimeError, "exited before"):
            runner.wait_ready(exited, self.work / "no-readiness.json")
        process = Mock()
        process.poll.side_effect = [None, -9]
        process.wait.side_effect = [subprocess.TimeoutExpired("fixture", 5), -9]
        self.assertTrue(runner.stop(process))
        process.terminate.assert_called_once()
        process.kill.assert_called_once()
        self.assertEqual(process.wait.call_count, 2)

    def test_owned_fixture_requests_diagnostics_without_changing_readiness_contract(self):
        child = Mock(pid=12345)
        child.poll.return_value = None
        with patch.object(runner.smoke.config, "checked_path", side_effect=lambda value: value), \
                patch.object(runner.smoke, "source_sha", return_value=SOURCE), \
                patch.object(runner.subprocess, "Popen", return_value=child) as spawn, \
                patch.object(runner, "wait_ready", return_value=READY) as ready, \
                patch.object(runner.subprocess, "run", return_value=SimpleNamespace(returncode=0)), \
                patch.object(runner, "read_http_json", return_value=self.trace), \
                patch.object(runner, "stop", return_value=True):
            self.assertEqual(runner.run(self.work, ["synthetic-test-command"]), 0)
            arguments = spawn.call_args.args[0]
            self.assertIn("--diagnose-startup", arguments)
            self.assertEqual(arguments[arguments.index("--port") + 1], "18769")
            ready.assert_called_once_with(child, self.work / "online-fixture-ready.json")
        self.assertEqual(runner.wait_ready.__defaults__, (15,))


if __name__ == "__main__":
    unittest.main()
