#!/usr/bin/env python3
"""Bind one actual native main-app product-chain test to its source and payload."""
import argparse
import importlib.util
import json
import os
from pathlib import Path


HERE = Path(__file__).resolve().parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


smoke = load("native_reader_smoke", HERE / "smoke-tools.py")
packaging = load("native_reader_packaging", HERE / "runtime-packaging.py")


def validate_tag():
    source = smoke.source_sha()
    if (os.environ.get("GITHUB_SHA") != source
            or os.environ.get("GITHUB_REF_NAME") != "legado-native-reader-test-" + source[:7]):
        raise ValueError("Expected legado-native-reader-test-<current SHA7> and matching checkout")
    return source


def result(work):
    source = validate_tag()
    audit = smoke.read_json(work / "overlays.json")
    smoke.review_overlays(audit)
    settings = smoke.read_json(work / "build-settings.json")
    matches = [item["buildSettings"] for item in settings if item.get("target") == smoke.config.MAIN_TARGET]
    if len(matches) != 1:
        raise ValueError("Expected one main reader test host")
    actual = matches[0]
    for name, expected in {"CONFIGURATION": "Debug", "PLATFORM_NAME": "iphonesimulator",
                           "SWIFT_VERSION": "5.0", "PRODUCT_BUNDLE_IDENTIFIER": smoke.config.MAIN_BUNDLE}.items():
        if actual.get(name) != expected:
            raise ValueError("Unexpected native test-host setting: " + name)
    if "LEGADO_REQUIRE_NATIVE_MAINJS" not in actual.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "").split():
        raise ValueError("The native test must fail, rather than skip, when its runtime is unavailable")
    app = smoke.config.checked_path(Path(actual["TARGET_BUILD_DIR"]) / actual["FULL_PRODUCT_NAME"])
    info = smoke.config.read_info(app)
    smoke.require_local_info(info)
    if info.get("CFBundleSupportedPlatforms") != ["iPhoneSimulator"]:
        raise ValueError("Expected the actual Simulator application")
    if smoke.read_json(work / "native-exports.json").get("requiredDynamicExportsPresent") is not True:
        raise ValueError("The final test host must preserve the required native exports")
    if smoke.read_json(work / "native-restore.json").get("sourceCommit") != source:
        raise ValueError("Native restoration source differs from the tested checkout")
    return {"schemaVersion": 1, "sourceCommit": source, "status": "passed",
            "executionPlatform": "ios-simulator", "configuration": "Debug",
            "targetedTests": smoke.verify_summary(smoke.read_json(work / "summary.json"), 1),
            "testedApp": str(app), "testedInfoSHA256": smoke.config.digest(app / "Info.plist"),
            "runtime": smoke.config.verify_jvm_payload(app), "sourceOverlays": audit,
            "nativeProductChainExecuted": True,
            "scope": "One fixed mainJs text-source product chain with retained Rhino, real loopback HTTP, E4X/Java interop and cancellation/recovery.",
            "readerUIRendered": False, "realBookSourcesValidated": False,
            "deliveredIPAExecuted": False, "deviceValidationPassed": False,
            "g4ValidationPassed": False, "fullFeatureParityEstablished": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("validate-tag", "restore", "prepare", "result"))
    parser.add_argument("--work", type=Path, default=smoke.config.REPO / ".build/native-reader-test")
    args = parser.parse_args()
    work = smoke.config.checked_path(args.work)
    if args.phase == "validate-tag":
        record = {"sourceCommit": validate_tag()}
    elif args.phase == "restore":
        # Override only this private module instance; the reader packaging tag
        # contract and all historical probe gates remain unchanged.
        packaging.validate_tag = validate_tag
        record = packaging.restore()
        smoke.config.write_new_json(work / "native-restore.json", record)
    elif args.phase == "prepare":
        smoke.validate_tag = validate_tag
        record = smoke.prepare(work)
    else:
        record = result(work)
        smoke.config.write_new_json(work / "result.json", record)
    print(json.dumps(record, indent=2))


if __name__ == "__main__":
    main()
