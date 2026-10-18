#!/usr/bin/env python3
"""Synthetic evidence guards only; these tests never run an iOS app or JVM."""
import base64
from copy import deepcopy
import hashlib
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("native_http_wire_tested", HERE / "verify-http-wire.py")
wire = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wire)


def b64(raw):
    return base64.b64encode(raw).decode("ascii")


def synthetic_capability():
    android = wire.verified_android()
    chain = deepcopy(wire.comparison.original_projection(android))
    chain["traceVersion"] = "legado-main-js-v1"
    chain["sourceInput"] = deepcopy(android["canonicalTrace"]["sourceInput"])
    requests = deepcopy(android["canonicalTrace"]["requests"])
    chain["snapshot"]["requests"] = requests
    origin = "http://127.0.0.1:18766"
    captures, consumed = [], []
    for index, request in enumerate(requests):
        capture = deepcopy(request)
        capture["url"] = capture["url"].replace(wire.CANONICAL_ORIGIN, origin)
        for entry in capture["headers"]:
            if entry["name"].lower() == "host":
                entry["value"] = "127.0.0.1:18766"
        raw_head = (f'{capture["method"]} {capture["requestTarget"]} HTTP/1.1\r\n'
                    + "".join(f'{entry["name"]}: {entry["value"]}\r\n' for entry in capture["headers"])
                    + "\r\n").encode("iso-8859-1")
        body = base64.b64decode(capture["bodyBase64"])
        # Deliberately synthetic response data tests linkage, not book parsing.
        answer = ("Synthetic response " + str(index)).encode("ascii")
        response_entries = [{"name": "Content-Type", "value": "text/plain; charset=utf-8"},
                            {"name": "Content-Length", "value": str(len(answer))},
                            {"name": "Connection", "value": "close"},
                            {"name": "Set-Cookie", "value": "first=one"},
                            {"name": "Set-Cookie", "value": "second=two"}]
        response_head = ("HTTP/1.1 200 OK\r\n"
                         + "".join(f'{entry["name"]}: {entry["value"]}\r\n' for entry in response_entries)
                         + "\r\n").encode("ascii")
        capture.update({"rawHeadBase64": b64(raw_head), "rawRequestSHA256": hashlib.sha256(raw_head + body).hexdigest(),
                        "responseWritten": True, "rawResponseHeadBase64": b64(response_head),
                        "responseBodyBase64": b64(answer), "responseBodySHA256": hashlib.sha256(answer).hexdigest()})
        captures.append(capture)
        response_values = {}
        for entry in response_entries:
            response_values.setdefault(entry["name"], []).append(entry["value"])
        consumed.append({"url": capture["url"], "status": 200, "protocol": "http/1.1",
                         "headers": response_values, "headerEntries": response_entries,
                         "bodyBase64": b64(answer), "bodySHA256": hashlib.sha256(answer).hexdigest()})
    return {"suite": "OkHttpWireCapabilityProbe", "passed": True, "loopbackOnly": True,
            "g4ValidationPassed": False, "exceptions": [], "parentDeadlineEpochMs": 123456789,
            "childDeadlineEpochMs": 123456789, "httpClient": "okhttp-jvm:5.4.0", "okio": "okio-jvm:3.17.0",
            "mainJsSHA256": wire.MAIN_JS_SHA256, "readingChain": chain,
            "wireSnapshot": {"origin": origin, "requests": captures}, "transportResponses": consumed,
            "cleanup": {"isolatedSessionClosed": True, "errors": [],
                        "transport": {"passed": True, "dispatcherStopped": True, "activeCalls": 0, "pooledConnections": 0},
                        "server": {"listenerClosed": True, "activeSocketClosed": True, "workerStopped": True}}}


class HttpWireEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.native = synthetic_capability()

    def test_exact_raw_linkage_and_existing_comparator_must_both_pass(self):
        result = wire.verify(self.native, "ios-simulator")
        self.assertTrue(result["passed"])
        self.assertEqual(result["strictComparison"]["differenceCount"], 0)
        self.assertEqual(result["consumedResponsesMatched"], 7)
        self.assertFalse(result["g4ValidationPassed"])
        self.assertFalse(result["strictComparison"]["physicalDeviceReport"])

    def test_supplied_success_and_prepared_intent_cannot_replace_actual_wire(self):
        self.native["preparedRequests"] = deepcopy(self.native["readingChain"]["snapshot"]["requests"])
        self.native["wireSnapshot"]["requests"].pop()
        with self.assertRaisesRegex(ValueError, "Exactly seven captured"):
            wire.verify(self.native, "ios-simulator")
        self.native = synthetic_capability()
        self.native["readingChain"]["snapshot"]["requests"][1]["headers"][0]["value"] += "-changed"
        with self.assertRaisesRegex(ValueError, "captured wire bytes"):
            wire.verify(self.native, "ios-simulator")

    def test_raw_request_digest_and_parsed_fields_are_independently_checked(self):
        self.native["wireSnapshot"]["requests"][0]["rawRequestSHA256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "raw request hash"):
            wire.verify(self.native, "ios-simulator")
        self.native = synthetic_capability()
        self.native["wireSnapshot"]["requests"][0]["headers"].pop()
        with self.assertRaisesRegex(ValueError, "retained raw HTTP head"):
            wire.verify(self.native, "ios-simulator")

    def test_consumed_response_bytes_and_all_duplicate_header_values_are_required(self):
        self.native["transportResponses"][0]["bodyBase64"] = b64(b"different bytes")
        with self.assertRaisesRegex(ValueError, "exact response body"):
            wire.verify(self.native, "ios-simulator")
        self.native = synthetic_capability()
        self.native["transportResponses"][0]["headers"]["Set-Cookie"].pop()
        with self.assertRaisesRegex(ValueError, "dropped or merged"):
            wire.verify(self.native, "ios-simulator")

    def test_still_running_resources_changed_deadline_or_nonloopback_cannot_pass(self):
        for mutation in (
            lambda cap: cap["cleanup"]["transport"].update(activeCalls=1),
            lambda cap: cap["cleanup"]["server"].update(workerStopped=False),
            lambda cap: cap.update(childDeadlineEpochMs=123456790),
            lambda cap: cap["wireSnapshot"].update(origin="https://example.com"),
            lambda cap: cap["wireSnapshot"]["requests"][0].update(responseWritten=False),
        ):
            self.native = synthetic_capability()
            mutation(self.native)
            with self.subTest(native=self.native), self.assertRaises(ValueError):
                wire.verify(self.native, "ios-simulator")

    def test_changed_state_or_missing_exception_evidence_still_fails_strict_comparison(self):
        self.native["readingChain"]["snapshot"]["cache"]["lastKey"] = "changed"
        result = wire.verify(self.native, "ios-simulator")
        self.assertFalse(result["passed"])
        self.assertGreater(result["strictComparison"]["differenceCount"], 0)
        self.native = synthetic_capability()
        del self.native["readingChain"]["exceptions"]
        self.assertFalse(wire.verify(self.native, "ios-simulator")["passed"])

    def test_changed_collected_golden_and_desktop_platform_are_not_accepted_as_ios(self):
        with patch.object(Path, "read_bytes", return_value=b"changed original reference"):
            with self.assertRaisesRegex(ValueError, "golden bytes changed"):
                wire.verify(self.native, "ios-simulator")
        self.assertFalse(wire.verify(self.native, "windows-desktop")["passed"])


if __name__ == "__main__":
    unittest.main()
