#!/usr/bin/env python3
"""Synthetic schema tests only; none of these objects is collected Android evidence."""
import base64
from copy import deepcopy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("compare_reference_test", HERE / "compare-reference.py")
comparison = importlib.util.module_from_spec(spec)
spec.loader.exec_module(comparison)


def fixture_reports():
    """Build declared synthetic inputs, not an Android golden or an iPhone result."""
    base = "https://fixture.invalid"
    first, second = base + "/chapter/1", base + "/chapter/2"
    source = {"bookSourceName": "Synthetic fixture", "bookSourceUrl": base,
              "mainJsSHA256": "b" * 64, "enabledCookieJar": True,
              "header": json.dumps({"User-Agent": "Legado-Reference-Fixture/1", "Accept": "*/*",
                                    "Accept-Encoding": "identity", "Connection": "close"})}
    common = {"User-Agent": "Legado-Reference-Fixture/1", "Accept": "*/*",
              "Accept-Encoding": "identity", "Connection": "close"}
    paths = ["/login", "/search?key=%E4%B9%A6&page=1", "/book/1", "/toc/1", "/chapter/1", "/chapter/1", "/chapter/2"]
    original_requests, bridge_requests = [], []
    for index, path in enumerate(paths):
        head = dict(common)
        body = b"name=reader&password=%E4%B9%A6" if index == 0 else b""
        if index == 0:
            head["Content-Type"] = "application/x-www-form-urlencoded; charset=utf-8"
        else:
            head.update({"Cookie": "sid=fixture", "Authorization": "Bearer fixture"})
        method = "POST" if index == 0 else "GET"
        body64 = base64.b64encode(body).decode("ascii")
        original_headers = dict(head, Host="fixture.invalid")
        if body:
            original_headers["Content-Length"] = str(len(body))
        original_requests.append({"method": method, "url": base + path, "requestTarget": path,
                                  "httpVersion": "HTTP/1.1",
                                  "headers": [{"name": key, "value": value} for key, value in original_headers.items()],
                                  "bodyBase64": body64})
        bridge_requests.append({"method": method, "url": base + path, "headers": head,
                                "bodyBase64": body64 if body else None, "timeoutMs": 30_000})
    chapters = [{"index": index, "title": title, "url": url,
                 "bookUrl": base + "/book/1", "baseUrl": base + "/toc/1"}
                for index, (title, url) in enumerate((("One", first), ("Two", second)))]
    state = {"loginInfo": '{"name":"reader"}', "loginHeader": '{"Authorization":"Bearer fixture"}',
             "variable": "logged-in", "cookie": "sid=fixture", "lastKey": "书", "calls": 1}
    search = [{"name": "Fixture", "bookUrl": base + "/book/1"}]
    details = {"name": "Fixture", "bookUrl": base + "/book/1", "intro": "Introduction", "tocUrl": base + "/toc/1"}
    contents = {first: "第一章\ncontent one", second: "第二章\ncontent two"}
    android = {"passed": True, "referenceKind": "original-archive-android-instrumentation",
               "fixtureSHA256": "b" * 64, "originalArchiveSHA256": comparison.EXPECTED_ARCHIVE_SHA256,
               "canonicalTrace": {"sourceInput": source, "exceptions": [], "requests": original_requests,
                                  "outputs": {"login": {key: state[key] for key in ("loginInfo", "loginHeader", "variable", "cookie")},
                                              "search": search, "details": details, "toc": chapters,
                                              "content": contents[first], "state": state,
                                              "batch": {"missingIndexes": [], "cacheBefore": {first: None, second: None}, "cacheAfter": contents}}}}
    ios = {"passed": True, "executionPlatform": "ios-device",
           "readingChain": {"sourceInput": deepcopy(source), "login": True,
                            "search": [dict(search[0], origin=base, type=8)],
                            "details": dict(details, author="", type=8),
                            "toc": [dict(chapter, isVolume=False) for chapter in chapters],
                            "content": contents[first], "batch": {"exists": True, "saved": [first, second], "missing": []},
                            "cacheBeforeContent": {}, "sharedCalls": 1, "exceptions": [],
                            "snapshot": {"variables": {"@loginInfo": state["loginInfo"], "@loginHeader": state["loginHeader"], "@variable": state["variable"]},
                                         "cookies": ["sid=fixture"], "cache": {"lastKey": "书"}, "contents": deepcopy(contents),
                                         "requests": bridge_requests}},
           # Cancellation evidence is explicitly outside the reading-chain snapshot.
           "requests": bridge_requests + [{"url": base + "/cancel-ready", "method": "GET"}]}
    return android, ios


class CompareReferenceTests(unittest.TestCase):
    def compare(self, android=None, ios=None):
        default_android, default_ios = fixture_reports()
        return comparison.compare_reports(android if android is not None else default_android,
                                          ios if ios is not None else default_ios)

    def test_declared_fixture_matches_but_never_completes_g4(self):
        result = self.compare()
        self.assertTrue(result["passed"], result)
        self.assertFalse(result["g4ValidationPassed"])
        self.assertEqual(result["comparedReadingRequestCounts"], {"android": 7, "ios": 7})

    def test_one_changed_request_body_byte_is_a_difference(self):
        android, ios = fixture_reports()
        request = ios["readingChain"]["snapshot"]["requests"][0]
        body = bytearray(base64.b64decode(request["bodyBase64"]))
        body[0] ^= 1
        request["bodyBase64"] = base64.b64encode(body).decode("ascii")
        result = self.compare(android, ios)
        self.assertFalse(result["passed"])
        self.assertTrue(any(item["path"] == "/snapshot/requests/0/bodyBytes/base64" for item in result["differences"]))

    def test_missing_cookie_header_is_not_an_empty_cookie(self):
        android, ios = fixture_reports()
        del ios["readingChain"]["snapshot"]["requests"][1]["headers"]["Cookie"]
        result = self.compare(android, ios)
        difference = next(item for item in result["differences"] if item["path"].endswith("/headers/cookie"))
        self.assertEqual(difference["kind"], "missing_field")
        self.assertEqual(difference["ios"], {"present": False})

    def test_cookie_value_and_extra_headers_are_compared(self):
        for kind in ("cookie", "extra_header", "changed_authorization"):
            with self.subTest(kind=kind):
                android, ios = fixture_reports()
                snapshot = ios["readingChain"]["snapshot"]
                if kind == "cookie": snapshot["cookies"][0] = "sid=other"
                elif kind == "extra_header": snapshot["requests"][1]["headers"]["X-New"] = "unexplained"
                else: snapshot["requests"][1]["headers"]["Authorization"] = "Bearer changed"
                self.assertFalse(self.compare(android, ios)["passed"])

    def test_missing_output_and_original_chapter_enrichment_are_differences(self):
        for target, key in (("details", "tocUrl"), ("toc", "bookUrl"), ("toc", "baseUrl")):
            with self.subTest(target=target, key=key):
                android, ios = fixture_reports()
                output = ios["readingChain"][target]
                del (output[0] if isinstance(output, list) else output)[key]
                result = self.compare(android, ios)
                self.assertFalse(result["passed"])
                self.assertTrue(any(item["kind"] == "missing_field" and item["path"].endswith("/" + key) for item in result["differences"]))

    def test_script_sha256_must_match(self):
        android, ios = fixture_reports()
        ios["readingChain"]["sourceInput"]["mainJsSHA256"] = "c" * 64
        result = self.compare(android, ios)
        self.assertFalse(result["passed"])
        self.assertTrue(any(item["path"] == "/sourceInput/mainJsSHA256" for item in result["differences"]))

    def test_failure_reports_and_nonempty_exception_lists_are_rejected(self):
        for side in ("android", "ios"):
            for mode in ("passed_false", "failure", "exceptions"):
                with self.subTest(side=side, mode=mode):
                    android, ios = fixture_reports()
                    report = android if side == "android" else ios
                    if mode == "passed_false": report["passed"] = False
                    elif mode == "failure": report["failure"] = "Runtime failed"
                    else: report["canonicalTrace" if side == "android" else "readingChain"]["exceptions"] = [{"message": "caught failure"}]
                    result = self.compare(android, ios)
                    self.assertFalse(result["passed"])
                    self.assertEqual(result["differences"][0]["kind"], "input_rejected")

    def test_required_null_and_absent_fields_remain_distinct(self):
        for mode in ("missing_body", "missing_cache", "missing_original_readback", "missing_exceptions"):
            with self.subTest(mode=mode):
                android, ios = fixture_reports()
                if mode == "missing_body": del ios["readingChain"]["snapshot"]["requests"][1]["bodyBase64"]
                elif mode == "missing_cache": del ios["readingChain"]["cacheBeforeContent"]
                elif mode == "missing_exceptions": del ios["readingChain"]["exceptions"]
                else: android["canonicalTrace"]["outputs"]["batch"]["cacheBefore"].pop("https://fixture.invalid/chapter/1")
                self.assertFalse(self.compare(android, ios)["passed"])

    def test_header_case_and_source_json_layout_are_semantic(self):
        android, ios = fixture_reports()
        source_headers = json.loads(ios["readingChain"]["sourceInput"]["header"])
        ios["readingChain"]["sourceInput"]["header"] = json.dumps(source_headers, indent=2, sort_keys=True)
        for request in ios["readingChain"]["snapshot"]["requests"]:
            request["headers"] = {key.lower(): value for key, value in request["headers"].items()}
        self.assertTrue(self.compare(android, ios)["passed"])

    def test_unexplained_duplicate_header_values_are_not_dropped(self):
        android, ios = fixture_reports()
        android["canonicalTrace"]["requests"][1]["headers"].append({"name": "Authorization", "value": "Bearer second"})
        self.assertFalse(self.compare(android, ios)["passed"])

    def test_derived_transport_headers_are_validated_before_exclusion(self):
        for name, value in (("Host", "other.invalid"), ("Content-Length", "999")):
            with self.subTest(name=name):
                android, ios = fixture_reports()
                ios["readingChain"]["snapshot"]["requests"][0]["headers"][name] = value
                result = self.compare(android, ios)
                self.assertFalse(result["passed"])
                self.assertEqual(result["differences"][0]["kind"], "input_rejected")

    def test_duplicate_json_keys_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            comparison.parse_json('{"passed":false,"passed":true}')

    def test_inconsistent_original_cache_and_incomplete_requests_are_rejected(self):
        for mode in ("cache", "requests"):
            with self.subTest(mode=mode):
                android, ios = fixture_reports()
                if mode == "cache": android["canonicalTrace"]["outputs"]["batch"]["cacheAfter"]["https://fixture.invalid/chapter/1"] = None
                else: android["canonicalTrace"]["requests"].pop()
                result = self.compare(android, ios)
                self.assertFalse(result["passed"])
                self.assertEqual(result["differences"][0]["kind"], "input_rejected")

    def test_cli_always_writes_json_on_invalid_input(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            android, ios = fixture_reports()
            android_file, ios_file, output = folder / "android.json", folder / "ios.json", folder / "difference.json"
            android_file.write_text(json.dumps(android), encoding="utf-8")
            ios_file.write_text('{"passed":false,"passed":true}', encoding="utf-8")
            run = subprocess.run([sys.executable, "-B", str(HERE / "compare-reference.py"), "--android", str(android_file),
                                  "--ios", str(ios_file), "--output", str(output)], capture_output=True, timeout=30)
            self.assertEqual(run.returncode, 1)
            result = json.loads(output.read_text(encoding="utf-8"))
            self.assertFalse(result["passed"])
            self.assertEqual(result["differenceCount"], 1)
            self.assertIn("Duplicate", result["differences"][0]["message"])


if __name__ == "__main__":
    unittest.main()
