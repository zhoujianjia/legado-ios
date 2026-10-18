#!/usr/bin/env python3
"""Bounded offline tests of real loopback requests and their strict fixture evidence."""
import base64
from copy import deepcopy
import importlib.util
import io
import json
from pathlib import Path
import socket
import tempfile
import threading
import unittest
from unittest.mock import MagicMock, Mock, patch
from urllib.error import HTTPError
from urllib.request import Request, build_opener, ProxyHandler
import uuid


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("online_source_fixture_test", HERE / "online-source-fixture.py")
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class OnlineSourceFixtureTests(unittest.TestCase):
    def setUp(self):
        self.server = fixture.FixtureServer(0)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        self.thread.start()
        self.info = self.server.info

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.assertFalse(self.thread.is_alive())

    def get(self, path, method="GET", data=None):
        # The service is IPv4-only by contract. Avoid OS-dependent IPv6 retries
        # and proxy autodetection in these portable tests; retain the real Host.
        origin = self.info["origin"].replace("localhost", "127.0.0.1")
        request = Request(origin + path, data=data, method=method,
                          headers={"Host": self.info["origin"].removeprefix("http://")})
        try:
            response = build_opener(ProxyHandler({})).open(request, timeout=3)
        except HTTPError as failure:
            response = failure
        with response:
            return response.status, response.read()

    def trace(self):
        status, data = self.get("/trace?runId=" + self.info["runId"])
        self.assertEqual(status, 200)
        return json.loads(data)

    def complete_reading_requests(self):
        base = "/fixture/" + self.info["runId"] + "/"
        for route in fixture.ROUTES:
            query = "?q=OnlineSmoke&page=1" if route == "search" else ""
            status, body = self.get(base + route + query)
            self.assertEqual(status, 200)
            self.assertNotIn(b"JSC_ONLY_", body)
        return self.trace()

    def test_real_http_complete_chain_has_raw_bodies_and_verifiable_trace(self):
        status, health = self.get("/health")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(health), self.info)
        self.assertEqual(self.server.server_address[0], "127.0.0.1")
        self.assertEqual(str(uuid.UUID(self.info["runId"])), self.info["runId"])
        trace = self.complete_reading_requests()
        result = fixture.verify_trace(trace, expected_run_id=self.info["runId"])
        self.assertTrue(result["passed"])
        self.assertEqual(result["requestCount"], 6)
        self.assertTrue(all(value == 1 for value in result["routeCounts"].values()))
        source = json.loads(base64.b64decode(trace["requests"][0]["response"]["bodyBase64"]))[0]
        self.assertIn("String.fromCharCode", source["ruleContent"]["content"])
        for record in trace["requests"][-2:]:
            self.assertIn(b"RAW_ONLY_CHAPTER_", base64.b64decode(record["response"]["bodyBase64"]))
        self.assertFalse(result["provesJVMCompatibility"])

    def test_known_successful_prefetch_or_refresh_repeats_are_retained(self):
        self.complete_reading_requests()
        path = "/fixture/" + self.info["runId"] + "/chapter1.html"
        self.assertEqual(self.get(path)[0], 200)
        result = fixture.verify_trace(self.trace(), self.info["runId"])
        self.assertEqual(result["requestCount"], 7)
        self.assertEqual(result["routeCounts"][path], 2)

    def test_wrong_run_and_unknown_route_cannot_pass(self):
        trace = self.complete_reading_requests()
        with self.assertRaisesRegex(ValueError, "different server runId"):
            fixture.verify_trace(trace, str(uuid.uuid4()))
        status, _ = self.get("/trace?runId=" + str(uuid.uuid4()))
        self.assertEqual(status, 409)
        for path in ["/fixture/" + str(uuid.uuid4()) + "/book.html", "/fixture/" + self.info["runId"] + "/unknown"]:
            self.assertEqual(self.get(path)[0], 404)
        with self.assertRaisesRegex(ValueError, "Unknown business route"):
            fixture.verify_trace(self.trace(), self.info["runId"])

    def test_bad_query_and_non_get_body_are_real_failures_with_retained_bytes(self):
        self.complete_reading_requests()
        base = "/fixture/" + self.info["runId"]
        self.assertEqual(self.get(base + "/search?q=Other&page=1")[0], 400)
        self.assertEqual(self.get(base + "/book.html", method="POST", data=b"one-byte-body")[0], 405)
        trace = self.trace()
        self.assertEqual(base64.b64decode(trace["requests"][-1]["bodyBase64"]), b"one-byte-body")
        with self.assertRaises(ValueError):
            fixture.verify_trace(trace)

    def test_one_changed_response_byte_fails_even_with_updated_digest(self):
        original = self.complete_reading_requests()
        for recompute in [False, True]:
            with self.subTest(recompute=recompute):
                trace = deepcopy(original)
                response = trace["requests"][-1]["response"]
                data = base64.b64decode(response["bodyBase64"])
                changed = data[:-1] + bytes([data[-1] ^ 1])
                response["bodyBase64"] = base64.b64encode(changed).decode("ascii")
                if recompute:
                    response["bodySHA256"] = fixture.digest(changed)
                with self.assertRaisesRegex(ValueError, "Response bytes/hash differ"):
                    fixture.verify_trace(trace)

    def test_missing_chapter_header_body_or_write_completion_evidence_fails(self):
        original = self.complete_reading_requests()
        candidates = []
        trace = deepcopy(original)
        trace["requests"].pop()
        candidates.append(trace)
        for key in ["headers", "bodyBase64", "bodyBytes"]:
            trace = deepcopy(original)
            del trace["requests"][0][key]
            candidates.append(trace)
        trace = deepcopy(original)
        trace["requests"][0]["response"]["writeCompleted"] = False
        candidates.append(trace)
        for trace in candidates:
            with self.subTest(trace=trace), self.assertRaises(ValueError):
                fixture.verify_trace(trace)

    def test_altered_host_source_input_or_query_is_rejected(self):
        original = self.complete_reading_requests()
        candidates = []
        trace = deepcopy(original)
        trace["sourceURL"] += "?different"
        candidates.append(trace)
        trace = deepcopy(original)
        trace["requests"][0]["headers"] = [["Host", "external.example"]]
        candidates.append(trace)
        trace = deepcopy(original)
        trace["requests"][1]["target"] += "&page=2"
        candidates.append(trace)
        trace = deepcopy(original)
        trace["requests"][1]["query"] = {}
        candidates.append(trace)
        for trace in candidates:
            with self.subTest(trace=trace), self.assertRaises(ValueError):
                fixture.verify_trace(trace)

    def test_ready_is_atomic_exclusive_and_active_port_is_not_reused(self):
        with tempfile.TemporaryDirectory() as temporary:
            ready = Path(temporary) / "ready.json"
            fixture.publish_ready(ready, self.info)
            self.assertEqual(json.loads(ready.read_text()), self.info)
            original = ready.read_bytes()
            with self.assertRaises(FileExistsError):
                fixture.publish_ready(ready, dict(self.info, runId=str(uuid.uuid4())))
            self.assertEqual(ready.read_bytes(), original)
            self.assertEqual(list(Path(temporary).glob("*.tmp")), [])
        with self.assertRaises(OSError):
            with fixture.FixtureServer(self.server.server_port):
                self.fail("A running fixture port must never be silently reused")


class DNSFreeFixtureStartupTests(unittest.TestCase):
    def test_real_loopback_health_and_business_trace_never_require_reverse_dns(self):
        with patch.object(socket, "getfqdn", side_effect=AssertionError("Unexpected reverse DNS")) as fqdn, \
                patch.object(socket, "gethostbyaddr", side_effect=AssertionError("Unexpected reverse DNS")) as reverse:
            with fixture.FixtureServer(0) as server:
                self.assertEqual(server.server_address[0], "127.0.0.1")
                self.assertEqual(server.server_name, "localhost")
                self.assertEqual(server.server_port, server.socket.getsockname()[1])
                thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
                thread.start()
                try:
                    opener = build_opener(ProxyHandler({}))
                    origin = "http://127.0.0.1:" + str(server.server_port)
                    host = server.info["origin"].removeprefix("http://")
                    def get(path):
                        request = Request(origin + path, headers={"Host": host})
                        with opener.open(request, timeout=3) as response:
                            self.assertEqual(response.status, 200)
                            return response.read()
                    self.assertEqual(json.loads(get("/health")), server.info)
                    prefix = "/fixture/" + server.info["runId"] + "/"
                    for route in fixture.ROUTES:
                        query = "?q=OnlineSmoke&page=1" if route == "search" else ""
                        get(prefix + route + query)
                    trace = json.loads(get("/trace?runId=" + server.info["runId"]))
                    verified = fixture.verify_trace(trace, expected_run_id=server.info["runId"])
                    self.assertTrue(verified["passed"])
                    self.assertEqual(verified["requestCount"], 6)
                    fqdn.assert_not_called()
                    reverse.assert_not_called()
                finally:
                    server.shutdown()
                    thread.join(timeout=2)
                    self.assertFalse(thread.is_alive())


class StartupDiagnosticsTests(unittest.TestCase):
    def server_context(self):
        context = MagicMock()
        server = Mock(info={"fixture": "synthetic"})
        context.__enter__.return_value = server
        context.__exit__.return_value = False
        return context, server

    def test_success_cancels_the_single_startup_dump_before_serving(self):
        context, server = self.server_context()
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(fixture, "FixtureServer", return_value=context), \
                patch.object(fixture.faulthandler, "dump_traceback_later") as arm, \
                patch.object(fixture.faulthandler, "cancel_dump_traceback_later") as cancel, \
                patch.object(fixture.signal, "signal"), \
                patch.object(fixture.sys, "stderr", new_callable=io.StringIO) as stderr, \
                patch.object(fixture.sys, "stdout", new_callable=io.StringIO) as stdout:
            # publish_ready's atomic/exclusive behavior is tested above with a real file.
            ready = Path(temporary) / "ready.json"
            server.info = fixture.metadata("http://localhost:18769", str(uuid.uuid4()))
            def serve(**_):
                cancel.assert_called_once_with()
                self.assertTrue(ready.exists())
                raise KeyboardInterrupt()
            server.serve_forever.side_effect = serve
            self.assertEqual(fixture.main(["--port", "0", "--ready-file", str(ready), "--diagnose-startup"]), 0)
            arm.assert_called_once_with(8, repeat=False, file=stderr)
            cancel.assert_called_once_with()
            self.assertEqual(json.loads(stdout.getvalue()), server.info)
            self.assertEqual([line.rsplit("=", 1)[1] for line in stderr.getvalue().splitlines()],
                             ["main.entered", "construct.before", "construct.after",
                              "ready.publish.before", "ready.publish.after"])

    def test_constructor_and_publisher_failures_cancel_the_startup_dump(self):
        for failed_phase in ("constructor", "publisher"):
            with self.subTest(phase=failed_phase), tempfile.TemporaryDirectory() as temporary:
                context, server = self.server_context()
                with patch.object(fixture, "FixtureServer", return_value=context) as construct, \
                        patch.object(fixture, "publish_ready") as publish, \
                        patch.object(fixture.faulthandler, "dump_traceback_later") as arm, \
                        patch.object(fixture.faulthandler, "cancel_dump_traceback_later") as cancel, \
                        patch.object(fixture.sys, "stderr", new_callable=io.StringIO) as stderr:
                    (construct if failed_phase == "constructor" else publish).side_effect = OSError("synthetic startup failure")
                    with self.assertRaisesRegex(OSError, "synthetic startup failure"):
                        fixture.main(["--port", "0", "--ready-file", str(Path(temporary) / "ready.json"), "--diagnose-startup"])
                    arm.assert_called_once_with(8, repeat=False, file=stderr)
                    cancel.assert_called_once_with()
                    self.assertNotIn("stage=ready.publish.after", stderr.getvalue())
                    server.serve_forever.assert_not_called()

    def test_startup_diagnostics_are_opt_in(self):
        context, server = self.server_context()
        server.serve_forever.side_effect = KeyboardInterrupt()
        with patch.object(fixture, "FixtureServer", return_value=context), \
                patch.object(fixture.faulthandler, "dump_traceback_later") as arm, \
                patch.object(fixture.faulthandler, "cancel_dump_traceback_later") as cancel, \
                patch.object(fixture.signal, "signal"), \
                patch.object(fixture.sys, "stderr", new_callable=io.StringIO) as stderr, \
                patch.object(fixture.sys, "stdout", new_callable=io.StringIO):
            self.assertEqual(fixture.main(["--port", "0"]), 0)
            arm.assert_not_called()
            cancel.assert_not_called()
            self.assertEqual(stderr.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
