#!/usr/bin/env python3
"""Link one fixed native HTTP trace to the unchanged Android strict comparator."""
import base64
import binascii
import hashlib
import importlib.util
from pathlib import Path
from urllib.parse import urlsplit


REPO = Path(__file__).resolve().parents[2]
GOLDEN_SHA256 = "f7513d0be00ad44664660a8ff8835ebf158dcd3acbf59e9c9dfd2113ea6851b0"
MAIN_JS_SHA256 = "731f1f1f743b9bc393ea221a7118ff4a115ffa35947aa40c88ff088bb758a894"
CANONICAL_ORIGIN = "https://fixture.invalid"
spec = importlib.util.spec_from_file_location("http_wire_strict_comparator", REPO / "scripts/legado-reference/compare-reference.py")
comparison = importlib.util.module_from_spec(spec)
spec.loader.exec_module(comparison)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def decoded(value):
    require(isinstance(value, str), "Wire body/head must contain explicit base64 bytes")
    try:
        return base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error) as error:
        raise ValueError("Wire body/head contains invalid base64") from error


def head_fields(raw):
    require(raw.endswith(b"\r\n\r\n") and len(raw) <= 65536, "Fixed fixture requires one complete bounded HTTP/1.1 head")
    lines = raw[:-4].decode("iso-8859-1").split("\r\n")
    entries = []
    for line in lines[1:]:
        name, separator, value = line.partition(":")
        require(separator == ":" and name and name.strip() == name, "Malformed captured HTTP header")
        entries.append({"name": name, "value": value.strip(" \t")})
    return lines[0], entries


def verified_android():
    path = REPO / "tools/legado-reference/golden/android-golden.json"
    raw = path.read_bytes()
    require(hashlib.sha256(raw).hexdigest() == GOLDEN_SHA256, "Original collected Android golden bytes changed")
    return comparison.parse_json(raw.decode("utf-8-sig"))


def verify(native, execution_platform):
    require(isinstance(native, dict) and native.get("suite") == "OkHttpWireCapabilityProbe"
            and native.get("passed") is True and native.get("loopbackOnly") is True,
            "Native HTTP wire probe must identify its suite and actual success")
    require(native.get("httpClient") == "okhttp-jvm:5.4.0" and native.get("okio") == "okio-jvm:3.17.0"
            and native.get("mainJsSHA256") == MAIN_JS_SHA256,
            "Native HTTP client or original mainJs identity differs")
    require(native.get("exceptions") == [] and native.get("g4ValidationPassed") is False,
            "Fixed HTTP probe must have no exceptions and must not promote G4")
    parent, child = native.get("parentDeadlineEpochMs"), native.get("childDeadlineEpochMs")
    require(type(parent) is int and parent > 0 and type(child) is int and parent == child,
            "The isolated HTTP task must retain its parent's absolute deadline")
    cleanup = native.get("cleanup", {})
    require(isinstance(cleanup, dict), "Native HTTP cleanup record is missing")
    transport = cleanup.get("transport", {})
    server = cleanup.get("server", {})
    require(isinstance(transport, dict) and isinstance(server, dict), "Native HTTP cleanup components are missing")
    require(cleanup.get("isolatedSessionClosed") is True and cleanup.get("errors") == []
            and transport.get("passed") is True and transport.get("dispatcherStopped") is True
            and type(transport.get("activeCalls")) is int and transport["activeCalls"] == 0
            and type(transport.get("pooledConnections")) is int and transport["pooledConnections"] == 0
            and all(server.get(name) is True for name in ("listenerClosed", "activeSocketClosed", "workerStopped")),
            "Native HTTP cleanup must close its isolated session, calls, pool, dispatcher and server")
    wire = native.get("wireSnapshot", {})
    require(isinstance(wire, dict), "Native HTTP wire snapshot is missing")
    origin = wire.get("origin")
    require(isinstance(origin, str), "Native wire trace lacks its actual origin")
    parsed = urlsplit(origin)
    require(parsed.scheme == "http" and parsed.hostname == "127.0.0.1" and parsed.port is not None
            and 0 < parsed.port <= 65535 and not parsed.path and not parsed.query
            and not parsed.fragment and parsed.username is None and parsed.password is None,
            "Native wire trace must use only its owned IPv4 loopback origin")
    captures, responses = wire.get("requests"), native.get("transportResponses")
    require(isinstance(captures, list) and len(captures) == 7
            and isinstance(responses, list) and len(responses) == 7,
            "Exactly seven captured requests and consumed responses are required")
    canonical_requests = []
    for capture, response in zip(captures, responses):
        require(isinstance(capture, dict) and isinstance(response, dict), "Invalid HTTP evidence entry")
        body, raw = decoded(capture.get("bodyBase64")), decoded(capture.get("rawHeadBase64"))
        request_line, entries = head_fields(raw)
        parts = request_line.split(" ")
        require(len(parts) == 3 and parts[2] == "HTTP/1.1", "Unexpected captured request line")
        method, target, version = parts
        require(target.startswith("/") and not target.startswith("//")
                and capture.get("method") == method and capture.get("requestTarget") == target
                and capture.get("httpVersion") == version and capture.get("url") == origin + target
                and capture.get("headers") == entries,
                "Parsed wire request differs from its retained raw HTTP head")
        require(capture.get("rawRequestSHA256") == hashlib.sha256(raw + body).hexdigest(),
                "Captured raw request hash differs from actual head/body bytes")
        require(capture.get("responseWritten") is True, "The fixture did not finish writing its response")
        response_body = decoded(capture.get("responseBodyBase64"))
        status_line, response_entries = head_fields(decoded(capture.get("rawResponseHeadBase64")))
        require(status_line == "HTTP/1.1 200 OK" and response.get("status") == 200
                and response.get("url") == origin + target and response.get("protocol") == "http/1.1"
                and response.get("headerEntries") == response_entries,
                "Consumed response status/headers differ from the fixture's captured response")
        response_hash = hashlib.sha256(response_body).hexdigest()
        require(capture.get("responseBodySHA256") == response_hash
                and response.get("bodySHA256") == response_hash
                and decoded(response.get("bodyBase64")) == response_body,
                "The client did not retain the exact response body written by its fixture")
        values = {}
        for entry in response_entries:
            values.setdefault(entry["name"].lower(), []).append(entry["value"])
        require(values.get("content-length") == [str(len(response_body))], "Captured response length differs from retained body bytes")
        supplied = response.get("headers")
        require(isinstance(supplied, dict), "Consumed response must retain all header values")
        supplied_values = {}
        for name, items in supplied.items():
            require(isinstance(name, str) and isinstance(items, list) and all(isinstance(x, str) for x in items),
                    "Response headers must preserve value lists")
            supplied_values.setdefault(name.lower(), []).extend(items)
        require(values == supplied_values, "Consumed response header values were dropped or merged")
        canonical_entries = [{"name": item["name"], "value":
            CANONICAL_ORIGIN.removeprefix("https://") if item["value"] == parsed.netloc else item["value"].replace(origin, CANONICAL_ORIGIN)}
            for item in entries]
        canonical_requests.append({"method": method, "url": CANONICAL_ORIGIN + target,
                                   "requestTarget": target, "httpVersion": version,
                                   "headers": canonical_entries, "bodyBase64": capture["bodyBase64"]})
    chain = native.get("readingChain")
    require(isinstance(chain, dict) and isinstance(chain.get("snapshot"), dict)
            and chain["snapshot"].get("requests") == canonical_requests,
            "Comparable reading requests must come from captured wire bytes, not prepared dispatch intent")
    verdict = comparison.compare_reports(verified_android(), {
        "passed": True, "executionPlatform": execution_platform, "readingChain": chain})
    return {"passed": verdict["passed"], "goldenSHA256": GOLDEN_SHA256,
            "rawRequestsLinkedToSnapshot": True, "consumedResponsesMatched": 7,
            "strictComparison": verdict, "g4ValidationPassed": False}
