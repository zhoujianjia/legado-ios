#!/usr/bin/env python3
"""Fail closed on stale, unrelated or incomplete parallel position admission."""
from copy import deepcopy
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import MagicMock, patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("position_barrier_tested", HERE / "reader-position-barrier.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class FakeClock:
    def __init__(self):
        self.now = 0
        self.sleeps = []

    def clock(self):
        return self.now

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds


class PositionBarrierTests(unittest.TestCase):
    def setUp(self):
        self.expected = {"repository": "zhoujianjia/legado-ios", "sourceCommit": "a" * 40,
                         "runID": 21, "runAttempt": 2, "tag": "reader-legado-aaaaaaa", "workflow": gate.WORKFLOW}
        self.run = {"id": 21, "run_attempt": 2, "head_sha": "a" * 40,
                    "head_branch": self.expected["tag"], "path": gate.WORKFLOW, "event": "push",
                    "repository": {"full_name": self.expected["repository"]}, "status": "in_progress", "conclusion": None}
        self.job = {"id": 31, "run_id": 21, "run_attempt": 2, "head_sha": "a" * 40,
                    "head_branch": self.expected["tag"], "name": "position-regression",
                    "status": "completed", "conclusion": "success", "started_at": "2026-11-23T00:00:00Z",
                    "completed_at": "2026-11-23T00:10:00Z", "steps": [
                        {"name": name, "status": "completed", "conclusion": "success"}
                        for name in (gate.FRESH_STEP, gate.ARTIFACT_STEP)]}

    def fetcher(self, snapshots):
        polls = [0]
        def fetch(path):
            if "/jobs?" in path:
                self.assertIn("/attempts/2/jobs?per_page=100&page=1", path)
                jobs = snapshots[min(polls[0] - 1, len(snapshots) - 1)]
                return {"total_count": len(jobs), "jobs": deepcopy(jobs)}
            self.assertTrue(path.endswith("/attempts/2"))
            polls[0] += 1
            return deepcopy(self.run)
        return fetch, polls

    def test_overall_run_can_still_be_running_without_deadlock(self):
        fetch, polls = self.fetcher([[self.job]])
        result = gate.wait_for_position(fetch, self.expected, timeout=5, interval=2)
        self.assertEqual(result["job"], self.job)
        self.assertEqual(result["run"]["status"], "in_progress")
        self.assertEqual((polls[0], result["pollCount"]), (1, 1))

    def test_pending_position_is_polled_until_its_own_success(self):
        pending = self.job | {"status": "in_progress", "conclusion": None}
        fetch, _ = self.fetcher([[pending], [self.job]])
        clock = FakeClock()
        result = gate.wait_for_position(fetch, self.expected, timeout=5, interval=2,
                                        clock=clock.clock, sleep=clock.sleep)
        self.assertEqual(result["pollCount"], 2)
        self.assertEqual(clock.sleeps, [2])

    def test_wrong_run_source_attempt_tag_repository_or_workflow_fail(self):
        for field, value in (("id", 22), ("run_attempt", 1), ("head_sha", "b" * 40),
                             ("head_branch", "reader-legado-bbbbbbb"), ("path", ".github/workflows/other.yml"),
                             ("repository", {"full_name": "other/repository"}), ("event", "workflow_dispatch")):
            with self.subTest(field=field), self.assertRaises(gate.BarrierError):
                gate.validate_run(self.run | {field: value}, self.expected)

    def test_old_attempt_or_wrong_job_source_cannot_be_reused(self):
        for field, value in (("run_id", 22), ("run_attempt", 1), ("head_sha", "b" * 40),
                             ("head_branch", "other-tag")):
            with self.subTest(field=field), self.assertRaises(gate.BarrierError):
                gate.position_job([self.job | {field: value}], self.expected)

    def test_failed_skipped_or_cancelled_position_job_never_passes(self):
        for conclusion in ("failure", "skipped", "cancelled", "timed_out", None):
            fetch, _ = self.fetcher([[self.job | {"conclusion": conclusion}]])
            with self.subTest(conclusion=conclusion), self.assertRaisesRegex(gate.BarrierError, "position-job-unsuccessful"):
                gate.wait_for_position(fetch, self.expected, timeout=5, interval=2)

    def test_nonfresh_missing_duplicate_or_skipped_step_fails(self):
        for variant in ("missing", "duplicate", "skipped", "failed", "in_progress"):
            job = deepcopy(self.job)
            if variant == "missing":
                job["steps"].pop(0)
            elif variant == "duplicate":
                job["steps"].append(deepcopy(job["steps"][0]))
            elif variant == "in_progress":
                job["steps"][0]["status"] = "in_progress"
            else:
                job["steps"][0]["conclusion"] = variant
            with self.subTest(variant=variant), self.assertRaises(gate.BarrierError):
                gate.require_position_success(job)

    def test_missing_job_has_finite_deadline_and_poll_limit(self):
        for jobs in ([], [self.job | {"name": "other-job"}]):
            fetch, polls = self.fetcher([jobs])
            clock = FakeClock()
            with self.subTest(jobs=jobs), self.assertRaisesRegex(gate.BarrierError, "position-wait-deadline"):
                gate.wait_for_position(fetch, self.expected, timeout=5, interval=2,
                                        clock=clock.clock, sleep=clock.sleep)
            self.assertEqual(polls[0], 4)
            self.assertEqual(clock.sleeps, [2, 2, 1])
        fetch, polls = self.fetcher([[]])
        with self.assertRaisesRegex(gate.BarrierError, "position-wait-poll-limit"):
            gate.wait_for_position(fetch, self.expected, timeout=2, interval=1, clock=lambda: 0, sleep=lambda _: None)
        self.assertEqual(polls[0], 3)

    def test_ambiguous_position_or_duplicate_job_ids_fail(self):
        with self.assertRaisesRegex(gate.BarrierError, "ambiguous-position-job"):
            gate.position_job([self.job, self.job | {"id": 32}], self.expected)
        with self.assertRaisesRegex(gate.BarrierError, "duplicate-job"):
            gate.position_job([self.job, self.job], self.expected)

    def test_paginated_jobs_are_complete_and_consistent(self):
        reader = self.job | {"id": 32, "name": "reader", "status": "in_progress", "conclusion": None}
        pages = iter([{"total_count": 2, "jobs": [reader]}, {"total_count": 2, "jobs": [self.job]}])
        self.assertEqual(gate.fetch_jobs(lambda _: next(pages), self.expected), [reader, self.job])
        for second in ({"total_count": 3, "jobs": [self.job]}, {"total_count": 2, "jobs": []}):
            pages = iter([{"total_count": 2, "jobs": [reader]}, second])
            with self.subTest(second=second), self.assertRaises(gate.BarrierError):
                gate.fetch_jobs(lambda _: next(pages), self.expected)

    def test_invalid_bounds_and_unexpected_job_status_fail(self):
        fetch, _ = self.fetcher([[self.job | {"status": "unknown"}]])
        with self.assertRaisesRegex(gate.BarrierError, "invalid-position-job-status"):
            gate.wait_for_position(fetch, self.expected, timeout=5, interval=2)
        for timeout, interval in ((0, 2), (5401, 2), (5, 0), (5, 61)):
            with self.subTest(timeout=timeout, interval=interval), self.assertRaises(gate.BarrierError):
                gate.wait_for_position(fetch, self.expected, timeout=timeout, interval=interval)

    def test_context_requires_exact_local_source_and_authenticated_reader(self):
        environment = {"GITHUB_REPOSITORY": "zhoujianjia/legado-ios", "GITHUB_SHA": "a" * 40,
                       "GITHUB_REF_NAME": "reader-legado-aaaaaaa", "GITHUB_RUN_ID": "21",
                       "GITHUB_RUN_ATTEMPT": "2", "GITHUB_EVENT_NAME": "push"}
        self.assertEqual(gate.context(environment, "a" * 40), self.expected)
        with self.assertRaises(gate.BarrierError):
            gate.context(environment, "b" * 40)
        with self.assertRaisesRegex(gate.BarrierError, "missing-actions-read-token"):
            gate.api_reader("")

    def test_offline_receipt_replay_requires_selected_job_and_hashes(self):
        observed = {"run": self.run, "jobs": [self.job], "job": self.job, "pollCount": 1}
        hashes = {name: "c" * 64 for name in ("run.json", "jobs.json", "job.json")}
        receipt = gate.make_receipt(self.expected, observed, hashes, "d" * 64, 5, 2)
        self.assertTrue(receipt["passed"])
        self.assertFalse(receipt["wholeRunCompletionRequired"])
        for changed in (observed | {"job": self.job | {"id": 99}}, observed | {"pollCount": 0}):
            with self.subTest(changed=changed), self.assertRaises(gate.BarrierError):
                gate.make_receipt(self.expected, changed, hashes, "d" * 64, 5, 2)
        with self.assertRaises(gate.BarrierError):
            gate.make_receipt(self.expected, observed, hashes | {"run.json": "tampered"}, "d" * 64, 5, 2)

    def test_api_reader_authenticates_only_fixed_api_and_withholds_errors(self):
        response = MagicMock()
        response.__enter__.return_value = response
        response.status = 200
        response.read.return_value = b'{"ok": true}'
        fetch = gate.api_reader("owned-fixture-token")
        with patch.object(gate.urllib.request, "urlopen", return_value=response) as opened:
            self.assertEqual(fetch("/repos/zhoujianjia/legado-ios/actions/runs/21/attempts/2"), {"ok": True})
            request = opened.call_args.args[0]
            self.assertEqual(request.full_url, "https://api.github.com/repos/zhoujianjia/legado-ios/actions/runs/21/attempts/2")
            self.assertEqual(request.get_header("Authorization"), "Bearer owned-fixture-token")
            self.assertEqual(opened.call_args.kwargs["timeout"], 30)
        with self.assertRaisesRegex(gate.BarrierError, "invalid-api-path"):
            fetch("https://different.example/secret")
        with patch.object(gate.urllib.request, "urlopen", side_effect=OSError("owned-fixture-token")):
            with self.assertRaisesRegex(gate.BarrierError, "^github-api-read-failed$"):
                fetch("/repos/zhoujianjia/legado-ios/actions/runs/21/attempts/2")

    def test_workflow_requires_fresh_parallel_jobs_and_barrier_before_release(self):
        workflow = (gate.REPO / gate.WORKFLOW).read_text(encoding="utf-8")
        reader = workflow.split("\n  reader:\n", 1)[1]
        self.assertNotIn("needs:", reader.split("    steps:", 1)[0])
        self.assertNotIn("needs.position-regression", reader)
        self.assertIn("steps.reader-mode.outputs.reuse == 'true'", reader)
        self.assertIn("GITHUB_TOKEN: ${{ github.token }}", reader)
        self.assertLess(reader.index("run: bash scripts/reader-experience/reader-recovery-regression.sh"),
                        reader.index("reader-position-barrier.py --work"))
        self.assertLess(reader.index("reader-position-barrier.py --work"),
                        reader.index("--destination Resources/LegadoRuntime --replace"))
        self.assertLess(reader.index("reader-position-barrier.py --work"), reader.index("bash scripts/reader-experience/build.sh"))
        self.assertIn("hashFiles('.build/reader-position-barrier/result.json') != ''", reader)
        self.assertIn(".build/reader-position-barrier/", reader)
        self.assertIn("run: bash scripts/reader-experience/jimage-native-check.sh", reader)


if __name__ == "__main__":
    unittest.main()
