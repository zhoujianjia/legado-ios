#!/usr/bin/env python3
"""Loopback HTTP fixture for the existing JSC/native reader, never a JVM gate."""
from __future__ import annotations

import argparse
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import signal
import sys
import threading
import time
from urllib.parse import parse_qs, urlsplit
import uuid


DEFAULT_PORT = 18769
FIXTURE = "reader-book-source-smoke-v1"
QUERY = "OnlineSmoke"
DETAIL_MARKER = "ONLINE_DETAIL_HTTP_RESPONSE"
CHAPTERS = ("Chapter 1 Opening", "Chapter 2 Crossing")
RAW_MARKERS = ("RAW_ONLY_CHAPTER_ONE", "RAW_ONLY_CHAPTER_TWO")
ROUTES = ("sources.json", "search", "book.html", "toc.html", "chapter0.html", "chapter1.html")


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("ascii")


def digest(value):
    return hashlib.sha256(value).hexdigest()


def metadata(origin, run_id):
    base = origin + "/fixture/" + run_id
    return {"schemaVersion": 1, "fixture": FIXTURE, "runId": run_id, "origin": origin,
            "baseURL": base, "sourceURL": base + "/sources.json",
            "sourceName": "Online Smoke Source " + run_id,
            "bookTitle": QUERY + " Book " + run_id, "query": QUERY}


def responses(origin, run_id):
    info = metadata(origin, run_id)
    base, title = info["baseURL"], info["bookTitle"]
    # The expected visible prefix is constructed by JSC. It never appears in a
    # source/HTML response, so serving a pre-transformed body cannot pass the UI.
    content_rule = "#content@html@js:result.replace(/RAW_ONLY_/g,String.fromCharCode(74,83,67,95,79,78,76,89,95))"
    source = {"id": str(uuid.uuid5(uuid.NAMESPACE_URL, base)), "bookSourceName": info["sourceName"],
              "bookSourceUrl": base, "bookSourceType": 0, "enabled": True, "enabledExplore": False,
              "searchUrl": base + "/search?q={{key}}&page={{page}}",
              "ruleSearch": {"bookList": ".book", "name": "h2@text", "author": ".author@text",
                             "bookUrl": "a@href", "hasMoreRule": "@js:false"},
              "ruleBookInfo": {"name": "h1@text", "author": ".author@text", "intro": ".intro@text", "tocUrl": ".toc@href"},
              "ruleToc": {"chapterList": "a.chapter", "chapterName": "text", "chapterUrl": "href"},
              "ruleContent": {"content": content_rule}}
    bodies = {
        "sources.json": ("application/json; charset=utf-8", encoded([source])),
        "search": ("text/html; charset=utf-8", (
            f'<div class="book"><h2>{title}</h2><span class="author">Fixture Author</span>'
            f'<a href="{base}/book.html">Details</a></div>').encode("ascii")),
        "book.html": ("text/html; charset=utf-8", (
            f'<h1>{title}</h1><div class="author">Fixture Author</div>'
            f'<div class="intro">{DETAIL_MARKER}. Fixed local source detail.</div>'
            f'<a class="toc" href="{base}/toc.html">Contents</a>').encode("ascii")),
        "toc.html": ("text/html; charset=utf-8", "".join(
            f'<a class="chapter" href="{base}/chapter{i}.html">{name}</a>'
            for i, name in enumerate(CHAPTERS)).encode("ascii")),
    }
    for i, marker in enumerate(RAW_MARKERS):
        paragraphs = "".join(f"<p>{marker}. Paragraph {j}. The traveller reads the local source, "
                             "crosses the quiet valley, and records the next stage of the journey.</p>"
                             for j in range(18))
        bodies[f"chapter{i}.html"] = ("text/html; charset=utf-8",
                                      f'<h1>{CHAPTERS[i]}</h1><div id="content">{paragraphs}</div>'.encode("ascii"))
    return {base.removeprefix(origin) + "/" + name: value for name, value in bodies.items()}


def response_headers(content_type, body):
    return [["Content-Type", content_type], ["Content-Length", str(len(body))],
            ["Cache-Control", "no-store"], ["Connection", "close"]]


def publish_ready(path, info):
    """Expose one complete JSON inode atomically, failing if the ready name exists."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + "." + info["runId"] + ".tmp")
    try:
        with temporary.open("xb") as stream:
            stream.write(encoded(info) + b"\n")
            stream.flush()
        os.link(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False

    def __init__(self, port=DEFAULT_PORT):
        super().__init__(("127.0.0.1", port), Handler)
        self.info = metadata(f"http://localhost:{self.server_port}", str(uuid.uuid4()))
        self.routes = responses(self.info["origin"], self.info["runId"])
        self.records = []
        self.lock = threading.Lock()
        self.started = time.monotonic_ns()

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(5)
        return connection, address

    def trace(self):
        with self.lock:
            return dict(self.info, requests=json.loads(json.dumps(self.records)))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        self.handle_request()

    def do_POST(self):
        self.handle_request()

    def do_HEAD(self):
        self.handle_request()

    do_PUT = do_POST
    do_DELETE = do_POST
    do_PATCH = do_POST

    def handle_request(self):
        server = self.server
        parsed = urlsplit(self.path)
        query = parse_qs(parsed.query, keep_blank_values=True)
        if self.command == "GET" and parsed.path == "/health" and not query:
            self.reply(200, "application/json; charset=utf-8", encoded(server.info))
            return
        if self.command == "GET" and parsed.path == "/trace":
            good = query == {"runId": [server.info["runId"]]}
            self.reply(200 if good else 409, "application/json; charset=utf-8",
                       encoded(server.trace() if good else {"error": "runId does not match this server"}))
            return
        body = b""
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 <= length <= 1_048_576:
                raise ValueError("Request body exceeds fixture limit")
            self.connection.settimeout(5)
            body = self.rfile.read(length) if length else b""
            if len(body) != length:
                raise ValueError("Incomplete request body")
            if self.command != "GET":
                status, content_type, answer = 405, "application/json; charset=utf-8", encoded({"error": "GET required"})
            elif parsed.path not in server.routes:
                status, content_type, answer = 404, "application/json; charset=utf-8", encoded({"error": "Unknown current-run route"})
            elif query != ({"q": [QUERY], "page": ["1"]} if parsed.path.endswith("/search") else {}):
                status, content_type, answer = 400, "application/json; charset=utf-8", encoded({"error": "Unexpected query"})
            elif body:
                status, content_type, answer = 400, "application/json; charset=utf-8", encoded({"error": "GET body must be empty"})
            else:
                content_type, answer = server.routes[parsed.path]
                status = 200
        except (ValueError, TimeoutError, OSError) as failure:
            status, content_type, answer = 400, "application/json; charset=utf-8", encoded({"error": str(failure)})
        if self.command == "HEAD":
            answer = b""
        headers = response_headers(content_type, answer)
        record = {"method": self.command, "target": self.path, "path": parsed.path, "query": query,
                  "headers": [list(pair) for pair in self.headers.raw_items()],
                  "bodyBase64": base64.b64encode(body).decode("ascii"), "bodySHA256": digest(body), "bodyBytes": len(body),
                  "elapsedMilliseconds": (time.monotonic_ns() - server.started) / 1_000_000,
                  "response": {"status": status, "headers": headers, "writeCompleted": False,
                               "bodyBase64": base64.b64encode(answer).decode("ascii"),
                               "bodySHA256": digest(answer), "bodyBytes": len(answer)}}
        with server.lock:
            record["sequence"] = len(server.records) + 1
            server.records.append(record)
        try:
            self.reply(status, content_type, answer)
            with server.lock:
                record["response"]["writeCompleted"] = True
        except OSError as failure:
            with server.lock:
                record["response"]["writeError"] = type(failure).__name__ + ": " + str(failure)

    def reply(self, status, content_type, body):
        self.send_response_only(status)
        for name, value in response_headers(content_type, body):
            self.send_header(name, value)
        self.end_headers()
        self.close_connection = True
        if body:
            self.wfile.write(body)
        self.wfile.flush()

    def log_message(self, format, *args):
        sys.stderr.write("online-source-fixture: " + (format % args) + "\n")


def verify_trace(trace, expected_run_id=None):
    """Reject incomplete/stale/altered HTTP evidence; known successful repeats are allowed."""
    def require(condition, message):
        if not condition:
            raise ValueError(message)

    require(isinstance(trace, dict), "Trace must be an object")
    run_id, origin = trace.get("runId"), trace.get("origin")
    require(isinstance(run_id, str) and str(uuid.UUID(run_id)) == run_id, "Invalid canonical runId")
    require(expected_run_id is None or run_id == expected_run_id, "Trace belongs to a different server runId")
    require(isinstance(origin, str), "Missing origin")
    url = urlsplit(origin)
    require(url.scheme == "http" and url.hostname == "localhost" and url.port is not None
            and 1 <= url.port <= 65535 and origin == f"http://localhost:{url.port}", "Origin must be explicit loopback localhost")
    info = metadata(origin, run_id)
    for key, value in info.items():
        require(trace.get(key) == value, "Trace metadata mismatch: " + key)
    expected = responses(origin, run_id)
    records = trace.get("requests")
    require(isinstance(records, list) and records, "No business requests captured")
    counts = {path: 0 for path in expected}
    for sequence, request in enumerate(records, 1):
        require(isinstance(request, dict) and request.get("sequence") == sequence, "Missing/invalid request sequence")
        path = request.get("path")
        require(path in expected and request.get("method") == "GET", "Unknown business route or non-GET request")
        target = request.get("target")
        require(isinstance(target, str) and target.startswith("/"), "Missing origin-form request target")
        parsed = urlsplit(target)
        query = {"q": [QUERY], "page": ["1"]} if path.endswith("/search") else {}
        require(not parsed.scheme and not parsed.netloc and not parsed.fragment and parsed.path == path
                and parse_qs(parsed.query, keep_blank_values=True) == query and request.get("query") == query,
                "Request target/query differs from fixture contract")
        headers = request.get("headers")
        require(isinstance(headers, list) and all(isinstance(pair, list) and len(pair) == 2
                and all(isinstance(part, str) for part in pair) for pair in headers), "Missing complete request headers")
        require([value for name, value in headers if name.lower() == "host"] == [url.netloc], "Request Host differs from current origin")
        require(request.get("bodyBase64") == "" and request.get("bodySHA256") == digest(b"")
                and type(request.get("bodyBytes")) is int and request["bodyBytes"] == 0, "Unexpected/missing request body evidence")
        response = request.get("response")
        require(isinstance(response, dict) and response.get("status") == 200
                and response.get("writeCompleted") is True and "writeError" not in response, "Business response did not complete successfully")
        content_type, wanted = expected[path]
        try:
            actual = base64.b64decode(response["bodyBase64"], validate=True)
        except (KeyError, TypeError, ValueError) as failure:
            raise ValueError("Invalid/missing response bytes") from failure
        require(actual == wanted and response.get("bodySHA256") == digest(wanted)
                and type(response.get("bodyBytes")) is int and response["bodyBytes"] == len(wanted), "Response bytes/hash differ from fixed fixture")
        require(response.get("headers") == response_headers(content_type, wanted), "Response headers differ from fixed fixture")
        require(b"JSC_ONLY_" not in actual, "HTTP fixture must not supply the JSC-only visible marker")
        counts[path] += 1
    require(all(counts.values()), "Missing required real HTTP requests: " + repr([path for path, count in counts.items() if not count]))
    return {"schemaVersion": 1, "fixture": FIXTURE, "passed": True, "runId": run_id,
            "origin": origin, "baseURL": info["baseURL"], "requestCount": len(records), "routeCounts": counts,
            "responseSHA256": {path: digest(body) for path, (_, body) in expected.items()},
            "provesJVMCompatibility": False, "deviceValidationPassed": False}


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] == "verify":
        parser = argparse.ArgumentParser(description="Validate captured current-run HTTP evidence")
        parser.add_argument("--trace", required=True, type=Path)
        parser.add_argument("--run-id", required=True)
        parser.add_argument("--output", required=True, type=Path)
        args = parser.parse_args(argv[1:])
        try:
            result = verify_trace(json.loads(args.trace.read_text(encoding="utf-8")), args.run_id)
        except (ValueError, TypeError, OSError) as failure:
            result = {"passed": False, "error": str(failure)}
        args.output.write_bytes(encoded(result) + b"\n")
        print(json.dumps(result, sort_keys=True))
        return 0 if result["passed"] else 1
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--ready-file", type=Path)
    args = parser.parse_args(argv[1:] if argv[:1] == ["serve"] else argv)
    if not 0 <= args.port <= 65535:
        parser.error("port must be 0..65535")
    if args.ready_file and args.ready_file.exists():
        parser.error("ready file already exists; use a fresh evidence directory")
    with FixtureServer(args.port) as server:
        if args.ready_file:
            publish_ready(args.ready_file, server.info)
        print(json.dumps(server.info, sort_keys=True), flush=True)
        def stop(*_):
            raise KeyboardInterrupt()
        signal.signal(signal.SIGTERM, stop)
        try:
            server.serve_forever(poll_interval=0.2)
        except KeyboardInterrupt:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
