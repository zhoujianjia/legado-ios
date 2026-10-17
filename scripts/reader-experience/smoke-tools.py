#!/usr/bin/env python3
"""Audit temporary local-mode overlays and require real, non-skipped smoke tests.

This is a Simulator-only Debug test protocol. It never modifies a delivered IPA
and does not establish Release or physical-device functional acceptance.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
spec = importlib.util.spec_from_file_location("reader_smoke_config", HERE / "stage-config.py")
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)
INFO = "Info.plist"
OVERLAYS = {INFO, config.PROJECT}


def git(*args, binary=False):
    value = subprocess.check_output(["git", "-C", str(REPO), *args], text=not binary)
    return value if binary else value.strip()


def source_sha():
    source = git("rev-parse", "HEAD")
    if re.fullmatch(r"[0-9a-f]{40}", source) is None:
        raise ValueError("Expected a full source Git SHA")
    return source


def validate_tag():
    source = source_sha()
    if os.environ.get("GITHUB_SHA") != source or os.environ.get("GITHUB_REF_NAME") != "reader-smoke-" + source[:7]:
        raise ValueError("Expected reader-smoke-<current SHA7> and matching checkout")
    return source


def overlay_info(path, record_path):
    path, record_path = config.checked_path(path), config.checked_path(record_path)
    if record_path.exists():
        raise ValueError("Refusing to replace prior Info overlay evidence")
    original = path.read_bytes()
    info = plistlib.loads(original)
    info.update(config.LOCAL_FLAGS)
    info["GatewayBaseURL"] = ""
    info["GIDClientID"] = config.GOOGLE_CLIENT
    for entry in info.get("CFBundleURLTypes", []):
        entry["CFBundleURLSchemes"] = [config.GOOGLE_REVERSED if item.startswith("com.googleusercontent.apps.") else item
                                       for item in entry.get("CFBundleURLSchemes", [])]
    replacement = plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=False)
    record = {"path": INFO, "originalSHA256": hashlib.sha256(original).hexdigest(),
              "overlaySHA256": hashlib.sha256(replacement).hexdigest(),
              "localFlags": config.LOCAL_FLAGS, "gatewayConfigured": False,
              "upstreamOAuthReplaced": True, "expectedTrackedOverlay": True}
    config.write_new_json(record_path, record)
    path.write_bytes(replacement)
    return record


def prepare(directory):
    source = validate_tag()
    if git("status", "--porcelain", "--untracked-files=no"):
        raise ValueError("Smoke preparation requires a clean tracked source checkout")
    directory = config.checked_path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    audit_path = directory / "overlays.json"
    if audit_path.exists():
        raise ValueError("Refusing to overwrite smoke overlay evidence")
    for path in OVERLAYS:
        if (REPO / path).read_bytes() != git("show", "HEAD:" + path, binary=True):
            raise ValueError("Source bytes differ from HEAD before smoke overlay: " + path)
    synthetic = config.stage(REPO / "GoogleService-Info.plist")
    project = config.overlay_project(REPO / config.PROJECT, directory / "project-overlay.json")
    info = overlay_info(REPO / INFO, directory / "info-overlay.json")
    audit = {"schemaVersion": 1, "sourceCommit": source, "preparedAt": datetime.now(timezone.utc).isoformat(),
             "expectedTrackedChanges": sorted(OVERLAYS), "projectOverlay": project, "infoOverlay": info,
             "syntheticConfiguration": synthetic, "paidFeatureOverrides": False,
             "deliveredIPAModified": False, "configuration": "Debug"}
    review_overlays(audit)
    config.write_new_json(audit_path, audit)
    return audit


def review_overlays(audit):
    if audit.get("sourceCommit") != source_sha():
        raise ValueError("Smoke source HEAD changed after preparation")
    if set(git("diff", "--name-only", "HEAD").splitlines()) != OVERLAYS:
        raise ValueError("Only the declared source Info/project overlays may change tracked inputs")
    for record in (audit["projectOverlay"], audit["infoOverlay"]):
        if record["path"] not in OVERLAYS or config.digest(REPO / record["path"]) != record["overlaySHA256"]:
            raise ValueError("Working smoke overlay differs from its audit record")
        if hashlib.sha256(git("show", "HEAD:" + record["path"], binary=True)).hexdigest() != record["originalSHA256"]:
            raise ValueError("Original smoke overlay bytes differ from source HEAD")
    info = plistlib.loads((REPO / INFO).read_bytes())
    require_local_info(info)
    if plistlib.loads((REPO / "GoogleService-Info.plist").read_bytes()) != config.synthetic_config():
        raise ValueError("Smoke Firebase configuration must remain exactly synthetic")


def require_local_info(info):
    for name, expected in config.LOCAL_FLAGS.items():
        if info.get(name) is not expected:
            raise ValueError("Missing explicit local-mode Info Boolean: " + name)
    if info.get("GatewayBaseURL") != "" or info.get("GIDClientID") != config.GOOGLE_CLIENT:
        raise ValueError("Smoke host must have an empty gateway and synthetic OAuth identity")


def verify_summary(summary, expected):
    fields = {name: summary.get(name) for name in ("totalTestCount", "passedTests", "failedTests", "skippedTests")}
    if any(type(value) is not int for value in fields.values()):
        raise ValueError("xcresult summary lacks explicit integer test counts")
    if fields != {"totalTestCount": expected, "passedTests": expected, "failedTests": 0, "skippedTests": 0}:
        raise ValueError("Smoke test count/failure/skip gate failed: " + json.dumps(fields))
    return {"expectedTests": expected, **fields}


def result(audit, settings, unit, ui):
    review_overlays(audit)
    matches = [item["buildSettings"] for item in settings if item.get("target") == config.MAIN_TARGET]
    if len(matches) != 1:
        raise ValueError("Expected exactly one main reader test host")
    actual = matches[0]
    for name, expected in {"CONFIGURATION": "Debug", "SWIFT_VERSION": "5.0", "PLATFORM_NAME": "iphonesimulator",
                           "PRODUCT_BUNDLE_IDENTIFIER": config.MAIN_BUNDLE}.items():
        if actual.get(name) != expected:
            raise ValueError("Unexpected actual smoke host setting: " + name)
    app = config.checked_path(Path(actual["TARGET_BUILD_DIR"]) / actual["FULL_PRODUCT_NAME"])
    info = config.read_info(app)
    require_local_info(info)
    if plistlib.loads((app / "GoogleService-Info.plist").read_bytes()) != config.synthetic_config():
        raise ValueError("The tested app must include the exact synthetic Firebase configuration")
    if info.get("CFBundleSupportedPlatforms") != ["iPhoneSimulator"] or info.get("CFBundleIdentifier") != config.MAIN_BUNDLE:
        raise ValueError("The tested app must be the isolated local Simulator reader")
    config.no_jvm_payload(app)
    return {"schemaVersion": 1, "sourceCommit": audit["sourceCommit"], "configuration": "Debug",
            "executionPlatform": "ios-simulator", "simulatorDestination": os.environ.get("YUEDU_DEST"),
            "developerDirectory": os.environ.get("DEVELOPER_DIR"), "status": "passed",
            "targetedTests": {"cloudKitConfiguration": verify_summary(unit, 6), "TXTReaderUI": verify_summary(ui, 1)},
            "testedApp": str(app), "testedInfoSHA256": config.digest(app / "Info.plist"),
            "sourceOverlays": audit, "readerRoute": "Existing Yuedu/CoreText local TXT reader",
            "covered": ["TXT auto-import through LocalBookImportService", "bookshelf entry", "visible CoreText body",
                        "chapter selection through the real TOC", "shelf progress and selected chapter restored after relaunch"],
            "paidFeatureOverrides": False, "jvmIntegratedIntoReading": False,
            "deliveredIPAExecuted": False, "deviceValidationPassed": False,
            "limitations": ["Debug Simulator test, not execution of the delivered Release IPA.",
                            "Auto-import uses an existing DEBUG hook, not the Files picker UI.",
                            "This does not accept network sources, EPUB/PDF, RSS, TTS or full Legado compatibility."]}


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="phase", required=True)
    commands.add_parser("validate-tag")
    preparation = commands.add_parser("prepare")
    preparation.add_argument("--directory", type=Path, required=True)
    verify = commands.add_parser("verify-summary")
    verify.add_argument("--summary", type=Path, required=True)
    verify.add_argument("--expected", type=int, required=True)
    summarize = commands.add_parser("result")
    for name in ("audit", "settings", "unit", "ui", "output"):
        summarize.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.phase == "validate-tag":
            value = {"sourceCommit": validate_tag()}
        elif args.phase == "prepare":
            value = prepare(args.directory)
        elif args.phase == "verify-summary":
            value = verify_summary(read_json(args.summary), args.expected)
        else:
            value = result(read_json(args.audit), read_json(args.settings), read_json(args.unit), read_json(args.ui))
            config.write_new_json(args.output, value)
        print(json.dumps(value, indent=2))
        return 0
    except Exception as error:
        print(f"{type(error).__name__}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
