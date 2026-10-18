#!/usr/bin/env python3
"""Collect bounded diagnostics from the synthetic native-reader CI Simulator.

Missing logs are evidence of absence, never a successful runtime validation.
No source databases, preferences, exports or arbitrary container files are read.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import itertools
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import time
import uuid


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
spec = importlib.util.spec_from_file_location("native_diagnostic_config", HERE / "stage-config.py")
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)
MAX_FILE_BYTES = 16 * 1024 * 1024
MAX_TOTAL_BYTES = 64 * 1024 * 1024
MAX_FILES = 64
NATIVE_NAME = re.compile(r"(?:stages\.log|vm-output\.log|hs_err_pid[0-9]+\.log)\Z")


def checked(path):
    requested = str(path)
    path = Path(path).absolute()
    for part in (path, *path.parents):
        if part.is_symlink() or getattr(part, "is_junction", lambda: False)():
            raise ValueError(f"Refusing a linked diagnostics path: rejectedPart={part}; requestedPath={requested}")
    return path.resolve(strict=False)


def command(arguments):
    result = subprocess.run(arguments, cwd=REPO, check=True, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    if len(result.stdout) > 16_384:
        raise ValueError("Unexpectedly large Simulator command output")
    return result.stdout.strip()


def read_bounded(path):
    path = checked(path)
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(descriptor, "rb") as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_size > MAX_FILE_BYTES:
            raise ValueError("Diagnostics input is not a bounded regular file")
        data = stream.read(MAX_FILE_BYTES + 1)
        after = os.fstat(stream.fileno())
    if (len(data) > MAX_FILE_BYTES or len(data) != before.st_size
            or (before.st_ino, before.st_size, before.st_mtime_ns)
            != (after.st_ino, after.st_size, after.st_mtime_ns)):
        raise ValueError("Diagnostics file changed while being collected")
    return data, before


def since_record(path, source):
    audit = json.loads(read_bounded(path)[0])
    if audit.get("sourceCommit") != source:
        raise ValueError("Diagnostics preparation record belongs to another checkout")
    if audit.get("configuration") != "Debug" or audit.get("deliveredIPAModified") is not False:
        raise ValueError("Expected this run's synthetic Simulator preparation")
    info = audit.get("infoOverlay", {})
    if info.get("localFlags") != config.LOCAL_FLAGS or info.get("gatewayConfigured") is not False:
        raise ValueError("Diagnostics preparation is not explicitly synthetic/local")
    moment = datetime.fromisoformat(audit["preparedAt"].replace("Z", "+00:00"))
    if moment.utcoffset() is None:
        raise ValueError("Preparation timestamp must include a timezone")
    since = moment.timestamp()
    if not time.time() - 6 * 3600 <= since <= time.time():
        raise ValueError("Preparation timestamp is outside this bounded CI run")
    return since


def ips_matches(data):
    text = data.decode("utf-8")
    decoder = json.JSONDecoder()
    header, index = decoder.raw_decode(text)
    if not isinstance(header, dict):
        return False
    bundle = header.get("bundleID")
    if bundle is None and text[index:].strip():
        body, _ = decoder.raw_decode(text[index:].lstrip())
        if isinstance(body, dict):
            bundle = body.get("bundleInfo", {}).get("CFBundleIdentifier")
    return header.get("app_name") == "YueduReader" and bundle == config.MAIN_BUNDLE


def collect(udid, output, preparation, source, run=command, home=None):
    udid = str(uuid.UUID(udid)).upper()
    output = checked(output)
    if not output.is_relative_to(checked(REPO / ".build")):
        raise ValueError("Diagnostics output must stay under this checkout's .build")
    output.mkdir(parents=True, exist_ok=False)
    record = {"schemaVersion": 1, "sourceCommit": source, "simulatorUDID": udid,
              "bundleIdentifier": config.MAIN_BUNDLE, "executionPlatform": "ios-simulator",
              "collectionStatus": "unavailable", "files": [], "errors": [], "skipped": [],
              "runtimeValidationEstablished": False, "deviceValidationPassed": False,
              "startedAtEpochSeconds": time.time()}
    total = 0

    def copy(path, relative, origin, since, crash=False):
        nonlocal total
        if len(record["files"]) >= MAX_FILES:
            raise ValueError("Diagnostics file-count limit exceeded")
        if checked(path).stat().st_size > MAX_TOTAL_BYTES - total:
            raise ValueError("Diagnostics aggregate limit exceeded before read")
        data, details = read_bounded(path)
        if details.st_mtime < since or details.st_mtime > time.time() + 60:
            record["skipped"].append({"origin": origin, "name": path.name, "reason": "outside-run-time-bound"})
            return
        if crash and not ips_matches(data):
            raise ValueError("Crash report identity differs from the synthetic test app")
        if len(record["files"]) >= MAX_FILES or total + len(data) > MAX_TOTAL_BYTES:
            raise ValueError("Diagnostics aggregate limit exceeded")
        destination = checked(output / relative)
        if not destination.is_relative_to(output):
            raise ValueError("Diagnostics destination escaped its new directory")
        destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.open("xb") as stream:
            stream.write(data)
        destination.chmod(0o600)
        total += len(data)
        record["files"].append({"path": relative, "origin": origin, "bytes": len(data),
                                "sha256": hashlib.sha256(data).hexdigest(), "modifiedAtEpochSeconds": details.st_mtime})

    def entries(directory, pattern=None):
        values = list(itertools.islice(directory.glob(pattern) if pattern else directory.iterdir(), MAX_FILES + 1))
        if len(values) > MAX_FILES:
            raise ValueError("Diagnostics directory entry limit exceeded")
        return sorted(values)

    try:
        since = since_record(preparation, source)
        record["sinceEpochSeconds"] = since
        app = checked(run(["xcrun", "simctl", "get_app_container", udid, config.MAIN_BUNDLE, "app"]))
        info = plistlib.loads(read_bounded(app / "Info.plist")[0])
        if (info.get("CFBundleIdentifier") != config.MAIN_BUNDLE
                or info.get("CFBundleSupportedPlatforms") != ["iPhoneSimulator"]
                or any(info.get(key) is not value for key, value in config.LOCAL_FLAGS.items())
                or info.get("GatewayBaseURL") != "" or info.get("GIDClientID") != config.GOOGLE_CLIENT):
            raise ValueError("Installed diagnostics owner is not the synthetic local Simulator app")
        record["installedSyntheticAppValidated"] = True
        container = checked(run(["xcrun", "simctl", "get_app_container", udid, config.MAIN_BUNDLE, "data"]))
        native = checked(container / "Library/Application Support/LegadoRuntimeDiagnostics")
        if native.is_dir():
            for folder in ("current", "previous"):
                directory = checked(native / folder)
                if directory.is_dir():
                    for path in entries(directory):
                        if NATIVE_NAME.fullmatch(path.name):
                            try:
                                copy(path, "runtime/" + folder + "/" + path.name, "app-native-diagnostics", since)
                            except Exception as error:
                                record["errors"].append(type(error).__name__ + ": " + str(error))
        record["nativeDiagnosticsDirectoryPresent"] = native.is_dir()
        home = Path(home or Path.home()).absolute()
        roots = [("host", home / "Library/Logs/DiagnosticReports"),
                 ("simulator", home / "Library/Developer/CoreSimulator/Devices" / udid / "data/Library/Logs/CrashReporter")]
        for label, directory in roots:
            origin = label + "-ips"
            try:
                directory = checked(directory)
                if directory.is_dir():
                    for path in entries(directory, "YueduReader*.ips"):
                        try:
                            copy(path, "crash-reports/" + label + "/" + path.name, origin, since, crash=True)
                        except Exception as error:
                            record["errors"].append("origin=" + origin + " " + type(error).__name__ + ": " + str(error))
            except Exception as error:
                record["errors"].append("origin=" + origin + " " + type(error).__name__ + ": " + str(error))
    except Exception as error:
        # The always step must retain a precise missing-container/log explanation,
        # including failures before installation, without changing the XCTest result.
        record["errors"].append(type(error).__name__ + ": " + str(error))
    record["hasNativeDiagnostics"] = any(item["origin"] == "app-native-diagnostics" for item in record["files"])
    record["hasCrashReports"] = any(item["origin"].endswith("-ips") for item in record["files"])
    record["totalBytes"] = total
    if record["files"]:
        record["collectionStatus"] = "partial" if record["errors"] else "collected"
    record["completedAtEpochSeconds"] = time.time()
    with (output / "collection.json").open("x", encoding="utf-8") as stream:
        json.dump(record, stream, indent=2)
        stream.write("\n")
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--output", type=Path, default=REPO / ".build/native-reader-test/diagnostics")
    parser.add_argument("--since-record", type=Path, default=REPO / ".build/native-reader-test/overlays.json")
    args = parser.parse_args()
    source = command(["git", "rev-parse", "HEAD"])
    if (os.environ.get("GITHUB_ACTIONS") != "true" or not re.fullmatch(r"[0-9a-f]{40}", source)
            or os.environ.get("GITHUB_SHA") != source
            or os.environ.get("GITHUB_REF_NAME") != "legado-native-reader-test-" + source[:7]):
        raise ValueError("Collection is restricted to this native-test CI source/tag")
    record = collect(args.udid, args.output, args.since_record, source)
    print(json.dumps({key: record[key] for key in ("collectionStatus", "hasNativeDiagnostics", "hasCrashReports", "totalBytes", "errors")}, indent=2))


if __name__ == "__main__":
    main()
