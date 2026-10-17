#!/usr/bin/env python3
"""Compare one original Android fixture trace with the iOS reading-chain report.

This is a bounded, explicit projection. A matching result is not completion of G4
and does not establish that either input was actually collected on a device.
"""
from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit


EXPECTED_ARCHIVE_SHA256 = "724dedcac2427cd1f02ca00af1eab7156146e6d9d3141ca4c92042d04ed7bcdd"
TRANSPORT_HEADERS = frozenset({"host", "content-length"})
SEARCH_FIELDS = ("name", "bookUrl")
DETAIL_FIELDS = ("name", "bookUrl", "intro", "tocUrl")
CHAPTER_FIELDS = ("index", "title", "url", "bookUrl", "baseUrl")
MISSING = object()


class InputError(ValueError):
    def __init__(self, side, path, message, value=MISSING):
        super().__init__(message)
        self.side, self.path, self.value = side, path, value


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON object key: " + key)
        result[key] = value
    return result


def parse_json(text):
    def reject_constant(value):
        raise ValueError("Non-finite JSON number: " + value)
    return json.loads(text, object_pairs_hook=unique_object, parse_constant=reject_constant)


def need(value, expected_type, side, path):
    if value is MISSING:
        raise InputError(side, path, "Required field is absent")
    if type(value) is not expected_type:
        raise InputError(side, path, "Expected " + expected_type.__name__, value)
    return value


def field(value, key, expected_type, side, path):
    need(value, dict, side, path)
    return need(value[key] if key in value else MISSING, expected_type, side, path + "/" + key)


def required(value, key, side, path):
    need(value, dict, side, path)
    if key not in value:
        raise InputError(side, path + "/" + key, "Required field is absent")
    return value[key]


def digest_field(value, key, side, path):
    digest = field(value, key, str, side, path)
    if re.fullmatch(r"[0-9a-f]{64}", digest) is None:
        raise InputError(side, path + "/" + key, "Expected an exact lowercase SHA-256", digest)
    return digest


def entry(value):
    return {"present": False} if value is MISSING else {"present": True, "value": value}


def compare_values(expected, actual, path, differences):
    if expected is MISSING or actual is MISSING:
        differences.append({"path": path, "kind": "missing_field", "android": entry(expected), "ios": entry(actual)})
    elif type(expected) is not type(actual):
        differences.append({"path": path, "kind": "type_mismatch", "android": entry(expected), "ios": entry(actual)})
    elif isinstance(expected, dict):
        for key in sorted(expected.keys() | actual.keys()):
            escaped = key.replace("~", "~0").replace("/", "~1")
            compare_values(expected[key] if key in expected else MISSING,
                           actual[key] if key in actual else MISSING, path + "/" + escaped, differences)
    elif isinstance(expected, list):
        for index in range(max(len(expected), len(actual))):
            compare_values(expected[index] if index < len(expected) else MISSING,
                           actual[index] if index < len(actual) else MISSING,
                           path + "/" + str(index), differences)
    elif expected != actual:
        differences.append({"path": path, "kind": "value_mismatch", "android": entry(expected), "ios": entry(actual)})


def headers(value, side, path, excluded=frozenset(), url=None, body=None):
    """Header names are case-insensitive; repeated values remain ordered and complete."""
    pairs = []
    if type(value) is dict:
        pairs = list(value.items())
    elif type(value) is list:
        for index, item in enumerate(value):
            name = field(item, "name", str, side, path + "/" + str(index))
            text = field(item, "value", str, side, path + "/" + str(index))
            pairs.append((name, text))
    else:
        raise InputError(side, path, "Expected a complete header object or name/value list", value)
    result = {}
    for name, text in pairs:
        need(name, str, side, path)
        need(text, str, side, path + "/" + name)
        if re.fullmatch(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+", name) is None or "\r" in text or "\n" in text:
            raise InputError(side, path + "/" + name, "Invalid HTTP header", text)
        key = name.lower()
        if key in excluded:
            # Absence is permitted: the iOS host bridge has not emitted wire
            # framing. A supplied framing header must still match its derivation.
            if key == "host" and text.lower() != urlsplit(url).netloc.lower():
                raise InputError(side, path + "/" + name, "Host does not match the captured URL", text)
            if key == "content-length" and (not text.isdigit() or int(text) != len(body)):
                raise InputError(side, path + "/" + name, "Content-Length does not match captured body bytes", text)
            continue
        result.setdefault(key, []).append(text)
    return result


def source_input(value, side, path):
    need(value, dict, side, path)
    result = dict(value)
    for name in ("bookSourceUrl", "bookSourceName"):
        field(value, name, str, side, path)
    field(value, "enabledCookieJar", bool, side, path)
    digest_field(value, "mainJsSHA256", side, path)
    encoded = field(value, "header", str, side, path)
    try:
        parsed = parse_json(encoded)
    except ValueError as error:
        raise InputError(side, path + "/header", "Invalid source header JSON: " + str(error), encoded) from error
    result["header"] = headers(need(parsed, dict, side, path + "/header"), side, path + "/header")
    return result


def decode_body(value, side, path):
    # Explicit JSON null means the bridge requested no body. A missing field is
    # never converted to null or to an empty body.
    if value is None:
        return b""
    need(value, str, side, path)
    try:
        return base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error) as error:
        raise InputError(side, path, "Invalid bodyBase64", value) from error


def requests(value, side, path):
    need(value, list, side, path)
    result = []
    for index, request in enumerate(value):
        current = path + "/" + str(index)
        method = field(request, "method", str, side, current)
        url = field(request, "url", str, side, current)
        parsed = urlsplit(url)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc or parsed.fragment:
            raise InputError(side, current + "/url", "Expected an absolute HTTP URL without fragment", url)
        body = decode_body(required(request, "bodyBase64", side, current), side, current + "/bodyBase64")
        header_values = required(request, "headers", side, current)
        normalized = headers(header_values, side, current + "/headers", TRANSPORT_HEADERS, url, body)
        if side == "android":
            target = field(request, "requestTarget", str, side, current)
            expected_target = (parsed.path or "/") + ("?" + parsed.query if parsed.query else "")
            if target != expected_target:
                raise InputError(side, current + "/requestTarget", "Request target differs from URL", target)
            field(request, "httpVersion", str, side, current)
        result.append({"method": method, "url": url, "headers": normalized,
                       "bodyBytes": {"base64": base64.b64encode(body).decode("ascii"), "length": len(body)}})
    return result


def projection(expected, actual, required_fields, side_path):
    """Use every Android-declared semantic field, including future extra fields."""
    for key in required_fields:
        required(expected, key, "android", side_path)
    need(actual, dict, "ios", side_path)
    # Missing iOS members remain absent so recursive diff reports missing_field.
    return {key: actual[key] for key in expected if key in actual}


def list_projection(expected, actual, required_fields, path):
    need(expected, list, "android", path)
    need(actual, list, "ios", path)
    result = []
    for index, item in enumerate(actual):
        if index < len(expected):
            result.append(projection(expected[index], item, required_fields, path + "/" + str(index)))
        else:
            result.append(item)  # Extra rows must remain visible as differences.
    for index, item in enumerate(expected):
        for key in required_fields:
            required(item, key, "android", path + "/" + str(index))
    return result


def sparse_cache(value, urls, side, path, android_readback=False):
    need(value, dict, side, path)
    if android_readback and set(value) != set(urls):
        raise InputError(side, path, "Original cache readback must explicitly include every fixture chapter URL", value)
    result = {}
    for key, content in value.items():
        if android_readback and content is None:
            # BookHelp.getContent's explicit null means no cached file. Convert
            # this declared readback representation to the bridge's sparse map.
            continue
        result[key] = need(content, str, side, path + "/" + key)
    return result


def original_projection(report):
    trace = field(report, "canonicalTrace", dict, "android", "")
    source = source_input(field(trace, "sourceInput", dict, "android", "/canonicalTrace"), "android", "/sourceInput")
    fixture_digest = digest_field(report, "fixtureSHA256", "android", "")
    if source["mainJsSHA256"] != fixture_digest:
        raise InputError("android", "/fixtureSHA256", "Fixture digest differs from canonical source input", fixture_digest)
    outputs = field(trace, "outputs", dict, "android", "/canonicalTrace")
    login = field(outputs, "login", dict, "android", "/canonicalTrace/outputs")
    state = field(outputs, "state", dict, "android", "/canonicalTrace/outputs")
    for key in ("loginInfo", "loginHeader", "variable", "cookie"):
        initial = field(login, key, str, "android", "/canonicalTrace/outputs/login")
        final = field(state, key, str, "android", "/canonicalTrace/outputs/state")
        if initial != final:
            raise InputError("android", "/canonicalTrace/outputs/state/" + key,
                             "Fixture mutated login state; iOS has no intermediate login-state snapshot", final)
    calls = field(state, "calls", int, "android", "/canonicalTrace/outputs/state")
    last_key = field(state, "lastKey", str, "android", "/canonicalTrace/outputs/state")
    search = field(outputs, "search", list, "android", "/canonicalTrace/outputs")
    details = field(outputs, "details", dict, "android", "/canonicalTrace/outputs")
    chapters = field(outputs, "toc", list, "android", "/canonicalTrace/outputs")
    for index, chapter in enumerate(chapters):
        for key in CHAPTER_FIELDS:
            required(chapter, key, "android", "/toc/" + str(index))
        field(chapter, "index", int, "android", "/toc/" + str(index))
        field(chapter, "url", str, "android", "/toc/" + str(index))
    urls = [chapter["url"] for chapter in chapters]
    if len(set(urls)) != len(urls):
        raise InputError("android", "/toc", "This fixture comparison requires distinct chapter URLs", urls)
    batch = field(outputs, "batch", dict, "android", "/canonicalTrace/outputs")
    before = sparse_cache(field(batch, "cacheBefore", dict, "android", "/canonicalTrace/outputs/batch"), urls,
                          "android", "/cacheBeforeContent", android_readback=True)
    after = sparse_cache(field(batch, "cacheAfter", dict, "android", "/canonicalTrace/outputs/batch"), urls,
                         "android", "/snapshot/contents", android_readback=True)
    missing_indexes = field(batch, "missingIndexes", list, "android", "/canonicalTrace/outputs/batch")
    for index in missing_indexes:
        need(index, int, "android", "/canonicalTrace/outputs/batch/missingIndexes")
    known_indexes = [chapter["index"] for chapter in chapters]
    if len(set(missing_indexes)) != len(missing_indexes) or any(index not in known_indexes for index in missing_indexes):
        raise InputError("android", "/canonicalTrace/outputs/batch/missingIndexes", "Invalid missing chapter indexes", missing_indexes)
    expected_missing = [chapter for chapter in chapters if chapter["index"] in missing_indexes]
    missing_by_cache = [chapter["index"] for chapter in chapters if chapter["url"] not in after]
    if missing_indexes != missing_by_cache:
        raise InputError("android", "/canonicalTrace/outputs/batch/missingIndexes",
                         "Missing chapter indexes contradict the explicit cache readback", missing_indexes)
    cookies = [part.strip() for part in state["cookie"].split(";") if part.strip()]
    if any("=" not in part for part in cookies):
        raise InputError("android", "/canonicalTrace/outputs/state/cookie", "Invalid cookie-state representation", state["cookie"])
    captured = requests(field(trace, "requests", list, "android", "/canonicalTrace"), "android", "/snapshot/requests")
    if len(captured) != 7:
        raise InputError("android", "/canonicalTrace/requests", "This fixture requires exactly seven original reading requests", len(captured))
    return {"sourceInput": source, "login": True, "search": search, "details": details, "toc": chapters,
            "content": field(outputs, "content", str, "android", "/canonicalTrace/outputs"),
            "batch": {"exists": True, "saved": [url for url in urls if url in after], "missing": expected_missing},
            "cacheBeforeContent": before,
            "snapshot": {"variables": {"@loginInfo": state["loginInfo"], "@loginHeader": state["loginHeader"], "@variable": state["variable"]},
                         "cache": {"lastKey": last_key}, "cookies": sorted(cookies), "contents": after,
                         "requests": captured},
            "sharedCalls": calls, "exceptions": field(trace, "exceptions", list, "android", "/canonicalTrace")}


def ios_projection(report, expected):
    chain = field(report, "readingChain", dict, "ios", "")
    snapshot = field(chain, "snapshot", dict, "ios", "/readingChain")
    batch = field(chain, "batch", dict, "ios", "/readingChain")
    field(batch, "exists", bool, "ios", "/readingChain/batch")
    field(batch, "saved", list, "ios", "/readingChain/batch")
    field(batch, "missing", list, "ios", "/readingChain/batch")
    cookies = field(snapshot, "cookies", list, "ios", "/readingChain/snapshot")
    for index, cookie in enumerate(cookies):
        need(cookie, str, "ios", "/readingChain/snapshot/cookies/" + str(index))
    return {"sourceInput": source_input(field(chain, "sourceInput", dict, "ios", "/readingChain"), "ios", "/sourceInput"),
            "login": field(chain, "login", bool, "ios", "/readingChain"),
            "search": list_projection(expected["search"], field(chain, "search", list, "ios", "/readingChain"), SEARCH_FIELDS, "/search"),
            "details": projection(expected["details"], field(chain, "details", dict, "ios", "/readingChain"), DETAIL_FIELDS, "/details"),
            "toc": list_projection(expected["toc"], field(chain, "toc", list, "ios", "/readingChain"), CHAPTER_FIELDS, "/toc"),
            "content": field(chain, "content", str, "ios", "/readingChain"), "batch": batch,
            "cacheBeforeContent": sparse_cache(field(chain, "cacheBeforeContent", dict, "ios", "/readingChain"), [], "ios", "/cacheBeforeContent"),
            "snapshot": {"variables": field(snapshot, "variables", dict, "ios", "/readingChain/snapshot"),
                         "cache": field(snapshot, "cache", dict, "ios", "/readingChain/snapshot"),
                         "cookies": sorted(cookies),
                         "contents": sparse_cache(field(snapshot, "contents", dict, "ios", "/readingChain/snapshot"), [], "ios", "/snapshot/contents"),
                         "requests": requests(field(snapshot, "requests", list, "ios", "/readingChain/snapshot"), "ios", "/snapshot/requests")},
            "sharedCalls": field(chain, "sharedCalls", int, "ios", "/readingChain"),
            "exceptions": field(chain, "exceptions", list, "ios", "/readingChain")}


def result_template():
    return {"schemaVersion": 1, "passed": False, "g4ValidationPassed": False,
            "scope": "One synthetic mainJs reading chain; this comparison alone never completes G4.",
            "rules": {"sourceHeaders": "Parse JSON; lowercase names; preserve every value.",
                      "requestHeaders": "Lowercase names; compare all values, including duplicate values in order.",
                      "excludedTransportHeaders": sorted(TRANSPORT_HEADERS),
                      "transportHeaderValidation": "If supplied, Host and Content-Length must match URL and decoded body length.",
                      "excludedWireField": "httpVersion; iOS host requests have not traversed a wire transport.",
                      "requestFields": ["method", "url", "headers", "decoded bodyBase64 bytes"],
                      "requestMetadata": "Bridge deadlines, timeoutMs and redundant body text are outside the captured HTTP projection; no headers are excluded by this rule.",
                      "sourceResultProjection": {"search": list(SEARCH_FIELDS), "details": list(DETAIL_FIELDS), "toc": list(CHAPTER_FIELDS)},
                      "projectionExtension": "Every extra Android-declared semantic field is also required on iOS. Extra iOS model defaults remain available in its original report.",
                      "cacheAbsence": "An explicitly recorded null Android BookHelp readback means no cached file; compare as a sparse map. Absent readback fields are rejected.",
                      "cookieState": "Compare sorted cookie entries without dropping duplicates; request Cookie headers retain exact values.",
                      "loginReturn": "Original BaseSource.login returns Unit; a successful original trace maps to true, with login and final state checked separately."},
            "remainingEvidence": ["A verified successful original Android execution", "A newly collected iPhone readingChain report", "The remaining G4 cases and broader validation gates"],
            "differences": []}


def compare_reports(android, ios, expected_archive_sha256=EXPECTED_ARCHIVE_SHA256):
    result = result_template()
    differences = result["differences"]
    try:
        for side, report in (("android", android), ("ios", ios)):
            need(report, dict, side, "")
            if required(report, "passed", side, "") is not True:
                raise InputError(side, "/passed", "A successful execution report is required", report["passed"])
            for key in ("failure", "error"):
                if key in report and report[key] is not None:
                    raise InputError(side, "/" + key, "A report containing an error cannot establish parity", report[key])
        if field(android, "referenceKind", str, "android", "") != "original-archive-android-instrumentation":
            raise InputError("android", "/referenceKind", "Expected original-archive Android execution", android["referenceKind"])
        archive = digest_field(android, "originalArchiveSHA256", "android", "")
        if archive != expected_archive_sha256:
            raise InputError("android", "/originalArchiveSHA256", "Android reference archive differs from the locked functional baseline", archive)
        platform = field(ios, "executionPlatform", str, "ios", "")
        if platform not in {"ios-device", "ios-simulator"}:
            raise InputError("ios", "/executionPlatform", "Expected an iOS device or Simulator report", platform)
        result["physicalDeviceReport"] = platform == "ios-device"
        expected = original_projection(android)
        actual = ios_projection(ios, expected)
        if expected["exceptions"] or actual["exceptions"]:
            raise InputError("android" if expected["exceptions"] else "ios", "/exceptions", "Successful fixture reports must explicitly contain no exceptions",
                             expected["exceptions"] or actual["exceptions"])
        compare_values(expected, actual, "", differences)
        result["comparedReadingRequestCounts"] = {"android": len(expected["snapshot"]["requests"]), "ios": len(actual["snapshot"]["requests"])}
        result["sourceIdentity"] = {"originalArchiveSHA256": archive,
                                    "androidFixtureSHA256": expected["sourceInput"]["mainJsSHA256"],
                                    "iosFixtureSHA256": actual["sourceInput"]["mainJsSHA256"]}
        result["passed"] = not differences
    except InputError as error:
        differences.append({"path": error.path, "kind": "input_rejected", "side": error.side,
                            "message": str(error), "observed": entry(error.value)})
    result["differenceCount"] = len(differences)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--android", required=True, type=Path)
    parser.add_argument("--ios", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--expected-archive-sha256", default=EXPECTED_ARCHIVE_SHA256)
    args = parser.parse_args()
    try:
        android_data, ios_data = args.android.read_bytes(), args.ios.read_bytes()
        result = compare_reports(parse_json(android_data.decode("utf-8-sig")), parse_json(ios_data.decode("utf-8-sig")), args.expected_archive_sha256)
        result["inputFiles"] = {"android": {"path": str(args.android), "sha256": hashlib.sha256(android_data).hexdigest()},
                                "ios": {"path": str(args.ios), "sha256": hashlib.sha256(ios_data).hexdigest()}}
    except Exception as error:
        result = result_template()
        result["differences"].append({"path": "", "kind": "input_rejected", "message": f"{type(error).__name__}: {error}"})
        result["differenceCount"] = 1
    serialized = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(serialized, encoding="utf-8")
    print(serialized, end="")
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
