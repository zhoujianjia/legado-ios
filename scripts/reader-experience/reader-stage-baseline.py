#!/usr/bin/env python3
"""Retain and validate the fixed reader-stage Debug Simulator baseline.

This is an evidence collector, not a benchmark runner. It never measures cold
startup, tap-to-visible latency, prefetch, peak memory or physical-device speed.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import statistics
import sys


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("reader_stage_smoke", HERE / "smoke-tools.py")
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)
config = smoke.config
REPO = HERE.parents[1]
MARKER = b"READER_ARCH_BENCH "
STAGES = ("document.first", "document.reuse", "page.first", "page.full", "scroll.ready")
SOURCE_FILES = (
    "Tests/iOS/yuedu appTests/ReaderArchitectureBenchmarkTests.swift",
    "Tests/iOS/yuedu appTests/CoreTextPerformanceFixtures.swift",
    "Tests/iOS/yuedu appTests/EPUBTestFixtures.swift",
    "scripts/reader-experience/reader-stage-baseline.py",
)
STYLE = {"renderWidth": 390, "renderHeight": 844, "fontSize": 18,
         "lineHeightMultiple": 1.5, "paragraphSpacing": 8, "lineSpacing": 0,
         "letterSpacing": 0, "contentInsets": [0, 0, 0, 0], "writingMode": "horizontal"}
LIMITATIONS = [
    "Five samples per fixture/stage describe median and maximum; they are not p95 estimates.",
    "First use of fresh chapter objects in an already-running test process is not cold app startup.",
    "No peak process memory, tap-to-visible, real HTTP, prefetch concurrency, battery or physical-device measurement.",
    "A first Debug Simulator capture establishes no speedup without a comparable prior measurement.",
]


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def fixture_protocol():
    # Independent, deliberately small reconstruction of CoreTextPerformanceFixtures
    # document()/paragraphs(). These units contain only single-code-point BMP
    # characters, so Swift Character and Python character counts agree here.
    result = {}
    for name, title, minimum, unit in (
            ("plain-10k", "Plain 10K", 10_240, "天地玄黃，宇宙洪荒。日月盈昃，辰宿列張。"),
            ("plain-100k", "Plain 100K", 102_400, "讀書使人充實，思考使人深邃，交談使人清醒。")):
        paragraph = (unit * ((256 + len(unit) - 1) // len(unit)))[:256]
        body = ("<p>" + paragraph + "</p>\n") * ((minimum + 255) // 256)
        html = ('<!doctype html>\n<html xmlns="http://www.w3.org/1999/xhtml"\n'
                '      xmlns:epub="http://www.idpf.org/2007/ops">\n  <head>\n'
                '    <meta charset="utf-8"/>\n    <title>' + title + '</title>\n'
                '    \n  </head>\n  <body>' + body + '</body>\n</html>')
        encoded = html.encode("utf-8")
        result[name] = {"fixtureSHA256": sha256(encoded), "fixtureHTMLBytes": len(encoded),
                        "fixtureMinimumUTF16": minimum}
    return result


def object_json(path):
    # Duplicate JSON keys can disguise a changed fixture/configuration as valid.
    def unique(pairs):
        value = {}
        for name, item in pairs:
            if name in value:
                raise ValueError("Duplicate JSON key: " + name)
            value[name] = item
        return value
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique)


def source_provenance():
    result = {}
    for name in SOURCE_FILES:
        actual = config.checked_path(REPO / name).read_bytes()
        committed = smoke.git("show", "HEAD:" + name, binary=True)
        if actual != committed:
            raise ValueError("Baseline source differs from HEAD: " + name)
        result[name] = {"sha256": sha256(actual), "bytes": len(actual)}
    return result


def validate_environment(value):
    if not isinstance(value, dict) or type(value.get("schemaVersion")) is not int or value["schemaVersion"] != 1:
        raise ValueError("Invalid baseline environment schema")
    source = value.get("sourceCommit")
    if not isinstance(source, str) or re.fullmatch(r"[a-f0-9]{40}", source) is None:
        raise ValueError("Environment requires a full source commit")
    if value.get("configuration") != "Debug" or value.get("platform") != "iphonesimulator":
        raise ValueError("Baseline requires Debug iphonesimulator")
    if re.fullmatch(r"id=[A-Fa-f0-9-]{36}", value.get("destination", "")) is None:
        raise ValueError("Baseline destination must be an explicit Simulator id")
    for name in ("xcodeVersion", "xcodeBuild", "sdkVersion", "runtimeIdentifier", "runtimeVersion",
                 "runtimeBuild", "deviceName", "deviceTypeIdentifier", "developerDirectory", "capturedAt"):
        if not isinstance(value.get(name), str) or not value[name].strip():
            raise ValueError("Missing baseline environment field: " + name)
    if (json.dumps(value.get("fixtures"), sort_keys=True) != json.dumps(fixture_protocol(), sort_keys=True)
            or json.dumps(value.get("style"), sort_keys=True) != json.dumps(STYLE, sort_keys=True)):
        raise ValueError("Baseline fixture/style protocol changed")
    sources = value.get("sourceFiles")
    if not isinstance(sources, dict) or set(sources) != set(SOURCE_FILES):
        raise ValueError("Missing benchmark/fixture/helper/collector source provenance")
    for record in sources.values():
        if (not isinstance(record, dict) or re.fullmatch(r"[a-f0-9]{64}", record.get("sha256", "")) is None
                or type(record.get("bytes")) is not int or record["bytes"] <= 0):
            raise ValueError("Invalid source file provenance")
    evidence = value.get("inputEvidence")
    if not isinstance(evidence, dict) or set(evidence) != {"audit", "settings", "xcode", "sdk", "simulators"}:
        raise ValueError("Missing raw environment evidence")
    for record in evidence.values():
        if (not isinstance(record, dict) or not isinstance(record.get("path"), str)
                or re.fullmatch(r"[a-f0-9]{64}", record.get("sha256", "")) is None):
            raise ValueError("Invalid environment evidence provenance")
    return value


def capture_environment(audit, settings, xcode, sdk, simulators, destination, developer_directory):
    smoke.review_overlays(audit)
    matches = [item.get("buildSettings") for item in settings if item.get("target") == config.MAIN_TARGET]
    if len(matches) != 1 or not isinstance(matches[0], dict):
        raise ValueError("Require exactly one actual reader host build-settings entry")
    actual = matches[0]
    for name, expected in {"CONFIGURATION": "Debug", "PLATFORM_NAME": "iphonesimulator"}.items():
        if actual.get(name) != expected:
            raise ValueError("Unexpected baseline build setting: " + name)
    sdk_version = sdk.strip()
    if re.fullmatch(r"\d+(?:\.\d+){1,2}", sdk_version) is None or actual.get("SDK_VERSION") != sdk_version:
        raise ValueError("SDK version differs from actual reader host settings")
    version = re.fullmatch(r"Xcode ([^\r\n]+)\r?\nBuild version ([^\r\n]+)\s*", xcode)
    if version is None:
        raise ValueError("Require exact xcodebuild -version evidence")
    if re.fullmatch(r"id=[A-Fa-f0-9-]{36}", destination) is None:
        raise ValueError("Baseline destination must be an explicit Simulator id")
    devices = [(runtime, device) for runtime, entries in simulators.get("devices", {}).items()
               for device in entries if device.get("udid") == destination[3:]]
    if len(devices) != 1 or devices[0][1].get("isAvailable") is not True:
        raise ValueError("Selected Simulator must occur exactly once and be available")
    runtime_id, device = devices[0]
    runtimes = [item for item in simulators.get("runtimes", []) if item.get("identifier") == runtime_id]
    if len(runtimes) != 1 or runtimes[0].get("isAvailable") is not True or ".iOS-" not in runtime_id:
        raise ValueError("Selected Simulator needs one available iOS runtime")
    runtime = runtimes[0]
    return {"schemaVersion": 1, "sourceCommit": audit["sourceCommit"],
            "capturedAt": datetime.now(timezone.utc).isoformat(),
            "configuration": actual["CONFIGURATION"], "platform": actual["PLATFORM_NAME"],
            "destination": destination, "developerDirectory": developer_directory,
            "xcodeVersion": version[1], "xcodeBuild": version[2], "sdkVersion": sdk_version,
            "runtimeIdentifier": runtime_id, "runtimeVersion": runtime.get("version"),
            "runtimeBuild": runtime.get("buildversion"), "deviceName": device.get("name"),
            "deviceTypeIdentifier": device.get("deviceTypeIdentifier"), "sourceFiles": source_provenance(),
            "fixtures": fixture_protocol(), "style": STYLE}


def validate_rows(raw):
    rows, seen = [], set()
    fixtures = fixture_protocol()
    for line in raw.splitlines():
        if line.count(MARKER) != 1:
            raise ValueError("Malformed or repeated baseline marker")
        payload = line.split(MARKER, 1)[1]
        # object_json's duplicate-key rule also applies to each raw metric row.
        def unique(pairs):
            result = {}
            for name, value in pairs:
                if name in result:
                    raise ValueError("Duplicate metric JSON key: " + name)
                result[name] = value
            return result
        row = json.loads(payload, object_pairs_hook=unique)
        if not isinstance(row, dict):
            raise ValueError("Metric row must be an object")
        name, stage, iteration = row.get("fixture"), row.get("stage"), row.get("iteration")
        if name not in fixtures or stage not in STAGES or type(iteration) is not int or not 0 <= iteration < 5:
            raise ValueError("Unexpected fixture/stage/iteration")
        expected = {"schemaVersion": 1, **fixtures[name], **STYLE}
        if set(row) != set(expected) | {"fixture", "stage", "iteration", "ms", "outputCount"}:
            raise ValueError("Missing or unknown metric fields")
        for key, value in expected.items():
            actual = row[key]
            if key == "contentInsets":
                valid = isinstance(actual, list) and len(actual) == 4 and all(
                    type(number) in (int, float) and math.isfinite(number) and number == 0 for number in actual)
            elif type(value) in (int, float):
                valid = type(actual) in (int, float) and math.isfinite(actual) and actual == value
                if key in ("schemaVersion", "fixtureHTMLBytes", "fixtureMinimumUTF16"):
                    valid = valid and type(actual) is int
            else:
                valid = actual == value
            if not valid:
                raise ValueError("Metric protocol mismatch: " + key)
        if type(row["ms"]) not in (int, float) or not math.isfinite(row["ms"]) or row["ms"] < 0:
            raise ValueError("Metric ms must be finite and nonnegative")
        count = row["outputCount"]
        if type(count) is not int or count <= 0:
            raise ValueError("Metric outputCount must be a positive integer")
        if stage.startswith("document.") and count < fixtures[name]["fixtureMinimumUTF16"]:
            raise ValueError("Document output is below its fixture minimum")
        if stage == "page.first" and count != 1:
            raise ValueError("First-page output must contain exactly one page")
        key = (name, iteration, stage)
        if key in seen:
            raise ValueError("Duplicate fixture/iteration/stage record")
        seen.add(key)
        rows.append(row)
    wanted = {(name, iteration, stage) for name in fixtures for iteration in range(5) for stage in STAGES}
    if seen != wanted:
        raise ValueError(f"Require all 50 unique metric rows; received {len(seen)}")
    by_key = {(row["fixture"], row["iteration"], row["stage"]): row for row in rows}
    for name in fixtures:
        for iteration in range(5):
            def count(stage):
                return by_key[name, iteration, stage]["outputCount"]
            if count("document.reuse") != count("document.first"):
                raise ValueError("Reused document length differs from first document")
            if any(count(stage) > count("document.first") for stage in ("page.full", "scroll.ready")):
                raise ValueError("Page/chunk output exceeds document length")
    return [{"fixture": name, "stage": stage, "samples": 5,
             "medianMs": statistics.median(row["ms"] for row in rows if row["fixture"] == name and row["stage"] == stage),
             "maxMs": max(row["ms"] for row in rows if row["fixture"] == name and row["stage"] == stage)}
            for name in fixtures for stage in STAGES]


def collect(log, environment_path, raw_path, output, summary_path, audit_path, test_exit_status=0):
    # Retain original prefixed log lines and their exact bytes before validating:
    # incomplete/invalid metrics must remain available for diagnosis after failure.
    raw_path, output = config.checked_path(raw_path), config.checked_path(output)
    if raw_path.exists() or output.exists():
        raise ValueError("Refusing to overwrite prior baseline evidence")
    log_bytes = log.read_bytes()
    raw = b"".join(line for line in log_bytes.splitlines(keepends=True) if MARKER in line)
    raw_path.parent.mkdir(parents=True, exist_ok=True)
    with raw_path.open("xb") as stream:
        stream.write(raw)
    if type(test_exit_status) is not int or test_exit_status != 0:
        raise ValueError("Reader-experience test wrapper failed; raw metrics retained")
    environment = validate_environment(object_json(environment_path))
    smoke.review_overlays(object_json(audit_path))
    if environment["sourceCommit"] != smoke.source_sha() or environment["sourceFiles"] != source_provenance():
        raise ValueError("Source changed since baseline environment capture")
    for record in environment["inputEvidence"].values():
        if sha256(config.checked_path(Path(record["path"])).read_bytes()) != record["sha256"]:
            raise ValueError("Raw environment input changed after capture")
    # The stage method sits in the existing 60/62 group. A metric log alone
    # cannot accept a run whose coverage/revision/readiness assertions failed.
    gate = smoke.verify_summary(object_json(summary_path), 60, 62)
    metrics = validate_rows(raw)
    result = {"schemaVersion": 1, "status": "passed", "sourceCommit": environment["sourceCommit"],
              "environment": environment, "readerExperienceGate": gate, "expectedMetricRows": 50,
              "rawRows": {"path": str(raw_path), "sha256": sha256(raw), "bytes": len(raw)},
              "rawLog": {"path": str(log), "sha256": sha256(log_bytes)},
              "environmentSHA256": sha256(environment_path.read_bytes()),
              "summarySHA256": sha256(summary_path.read_bytes()), "metrics": metrics,
              "speedupEstablished": False, "coldStartupMeasured": False,
              "peakProcessMemoryMeasured": False, "physicalDeviceMeasured": False,
              "limitations": LIMITATIONS}
    config.write_new_json(output, result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="phase", required=True)
    capture = commands.add_parser("capture-environment")
    for name in ("audit", "settings", "xcode", "sdk", "simulators", "output"):
        capture.add_argument("--" + name, type=Path, required=True)
    capture.add_argument("--destination", required=True)
    capture.add_argument("--developer-directory", required=True)
    gather = commands.add_parser("collect")
    for name in ("log", "environment", "raw", "output", "summary", "audit"):
        gather.add_argument("--" + name, type=Path, required=True)
    gather.add_argument("--test-exit-status", type=int, required=True)
    args = parser.parse_args()
    try:
        if args.phase == "capture-environment":
            value = capture_environment(object_json(args.audit), object_json(args.settings),
                args.xcode.read_text(encoding="utf-8"), args.sdk.read_text(encoding="utf-8"),
                object_json(args.simulators), args.destination, args.developer_directory)
            value["inputEvidence"] = {name: {"path": str(getattr(args, name).absolute()),
                "sha256": sha256(getattr(args, name).read_bytes())}
                for name in ("audit", "settings", "xcode", "sdk", "simulators")}
            validate_environment(value)
            config.write_new_json(args.output, value)
        else:
            value = collect(args.log, args.environment, args.raw, args.output, args.summary, args.audit,
                            args.test_exit_status)
        print(json.dumps(value, indent=2, ensure_ascii=False))
        return 0
    except Exception as error:
        print(f"{type(error).__name__}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
