#!/usr/bin/env python3
"""Actual loopback failures and independent failure-exit evidence admission."""
from copy import deepcopy
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import json
from pathlib import Path
import threading
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, ProxyHandler, build_opener

HERE = Path(__file__).resolve().parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


fixture = load("failure_fixture_tests", "online-source-fixture.py")
gate = load("failure_gate_tests", "run-reader-failure-smoke.py")


class FailureFixtureTests(unittest.TestCase):
    def setUp(self):
        self.server = fixture.FixtureServer(0, scenario=fixture.FAILURE_SCENARIO)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        self.thread.start()
        self.addCleanup(self.finish)

    def finish(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.assertFalse(self.thread.is_alive())

    def get(self, path):
        info = self.server.info
        request = Request(info["origin"].replace("localhost", "127.0.0.1") + path,
                          headers={"Host": info["origin"].removeprefix("http://")})
        try:
            response = build_opener(ProxyHandler({})).open(request, timeout=3)
        except HTTPError as error:
            response = error
        with response:
            return response.status, response.read()

    def complete(self):
        base = self.server.info["baseURL"].removeprefix(self.server.info["origin"])
        for route in fixture.ROUTES:
            query = "?q=OnlineSmoke&page=1" if route == "search" else ""
            if route == "chapter1.html":
                with ThreadPoolExecutor(max_workers=1) as pool:
                    response = pool.submit(self.get, base + "/" + route)
                    self.assertEqual(self.get("/failure-held?runId=" + self.server.info["runId"])[0], 200)
                    self.assertEqual(self.get("/release-failure?runId=" + self.server.info["runId"])[0], 200)
                    status, _ = response.result(timeout=3)
            else:
                status, _ = self.get(base + "/" + route + query)
            self.assertEqual(status, 500 if route == "chapter1.html" else 200)
        self.get(base + "/chapter1.html")
        # Await the actual completed write before taking a trace snapshot.
        status, body = self.get("/failure-observed?runId=" + self.server.info["runId"] + "&count=2")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["completedFailures"], 2)
        return self.server.trace()

    def test_actual_failure_is_separate_and_requires_one_manual_retry(self):
        trace = self.complete()
        result = fixture.verify_trace(trace, self.server.info["runId"], scenario=fixture.FAILURE_SCENARIO)
        self.assertEqual(result["fixture"], fixture.FAILURE_FIXTURE)
        self.assertEqual(result["requestCount"], 7)
        self.assertIn("/failure-fixture/", result["baseURL"])
        with self.assertRaises(ValueError):
            fixture.verify_trace(trace, self.server.info["runId"])

    def test_missing_retry_extra_retry_or_forged_success_cannot_pass(self):
        trace = self.complete()
        missing = deepcopy(trace)
        missing["requests"].pop()
        extra = deepcopy(trace)
        row = deepcopy(extra["requests"][-1])
        row["sequence"] += 1
        extra["requests"].append(row)
        altered = deepcopy(trace)
        altered["requests"][-1]["response"]["status"] = 200
        for bad in (missing, extra, altered):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                fixture.verify_trace(bad, self.server.info["runId"], scenario=fixture.FAILURE_SCENARIO)

    def test_failure_observer_is_bound_to_this_run_and_bounded_count(self):
        for suffix in ("runId=other&count=1", "runId=" + self.server.info["runId"] + "&count=3"):
            self.assertEqual(self.get("/failure-observed?" + suffix)[0], 400)


class FailureVerdictTests(unittest.TestCase):
    def summary(self):
        return {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0,
                "expectedFailures": 0, "testPassRate": 100,
                "devicesAndConfigurations": [{"passedTests": 1, "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}]}

    def tree(self, method):
        return {"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": method, "result": "Passed"}]}

    def test_only_the_actual_failure_exit_method_can_satisfy_the_ui_gate(self):
        with patch.object(gate.runner, "result", return_value={"status": "passed"}) as observed:
            result = gate.result(Path("owned-work"), self.summary(), self.tree(gate.METHOD))
            self.assertEqual(result["passedMethod"], gate.METHOD)
            observed.assert_called_with(Path("owned-work"), self.summary(), scenario="chapter-failure")
            with self.assertRaises(ValueError):
                gate.result(Path("owned-work"), self.summary(), self.tree("ReaderBookSourceSmokeUITests/other()"))
            for key in ("failedTests", "skippedTests", "expectedFailures"):
                with self.subTest(key=key), self.assertRaises(ValueError):
                    gate.result(Path("owned-work"), self.summary() | {key: 1}, self.tree(gate.METHOD))


if __name__ == "__main__":
    unittest.main()
