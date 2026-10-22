#!/usr/bin/env python3
"""Stage synthetic configuration and audit an unsigned local Yuedu experience.

No upstream Firebase credentials or signing identities are accepted. This build
uses the existing Yuedu/JSC reader; it does not integrate the experimental JVM.
The build flag is also stamped into the *built* bundle, since arbitrary
INFOPLIST_KEY_* settings are not reliably emitted by every Xcode configuration.
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
import zipfile


REPO = Path(__file__).resolve().parents[2]
MAIN_TARGET = "yuedu app"
MAIN_PRODUCT = "YueduReader.app"
UPSTREAM_BUNDLE = "com.zhangruilin.yuedureader"
MAIN_BUNDLE = "local.zhoujianjia.legado-reader"
PROJECT = "Yuedu-Reader.xcodeproj/project.pbxproj"
GOOGLE_CLIENT = "000000000000-yuedu-local-experience.apps.googleusercontent.com"
GOOGLE_REVERSED = "com.googleusercontent.apps.000000000000-yuedu-local-experience"
EXTENSIONS = {
    "yuedu_app_Widget.appex": (MAIN_BUNDLE + ".widget", "com.apple.widgetkit-extension"),
    "yuedu_app_ShareExtension.appex": (MAIN_BUNDLE + ".shareextension", "com.apple.share-services"),
}
DIAGNOSTIC_KIND = "yuedu-renewal-diagnostic-device"
DIAGNOSTIC_TARGETS = {
    MAIN_TARGET: (MAIN_PRODUCT, MAIN_BUNDLE),
    "Yuedu-Reader Widget": ("yuedu_app_Widget.appex", MAIN_BUNDLE + ".widget"),
    "Yuedu-Reader ShareExtension": ("yuedu_app_ShareExtension.appex", MAIN_BUNDLE + ".shareextension"),
}
# Same file and expanded-package ceilings as the production signing inventory.
DIAGNOSTIC_FILE_BYTES = 268_435_456
DIAGNOSTIC_PACKAGE_BYTES = 536_870_912
LOCAL_FLAGS = {
    "YueduLocalExperience": True,
    "FirebaseDataCollectionDefaultEnabled": False,
    "FIREBASE_ANALYTICS_COLLECTION_ENABLED": False,
    "FirebaseCrashlyticsCollectionEnabled": False,
    "firebase_performance_collection_enabled": False,
    "firebase_performance_instrumentation_enabled": False,
}


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def checked_path(path):
    path = path.absolute()
    for entry in (path, *path.parents):
        if entry.is_symlink() or getattr(entry, "is_junction", lambda: False)():
            raise ValueError("Refusing a symlinked experience output/configuration path")
    return path


def write_new_json(path, record):
    path = checked_path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as stream:
        stream.write(json.dumps(record, indent=2, ensure_ascii=False) + "\n")


def synthetic_config():
    return {
        "API_KEY": "AIza" + "0" * 35,
        "GCM_SENDER_ID": "000000000000",
        "PLIST_VERSION": "1",
        "BUNDLE_ID": MAIN_BUNDLE,
        "PROJECT_ID": "yuedu-local-experience",
        "STORAGE_BUCKET": "yuedu-local-experience.invalid",
        "DATABASE_URL": "https://yuedu-local-experience.invalid",
        "CLIENT_ID": GOOGLE_CLIENT,
        "REVERSED_CLIENT_ID": GOOGLE_REVERSED,
        "GOOGLE_APP_ID": "1:000000000000:ios:0000000000000000000000",
        "IS_ADS_ENABLED": False,
        "IS_ANALYTICS_ENABLED": False,
        "IS_APPINVITE_ENABLED": False,
        "IS_GCM_ENABLED": False,
        "IS_SIGNIN_ENABLED": False,
        "YueduSyntheticConfiguration": True,
    }


def stage(destination):
    destination = checked_path(destination)
    if destination.exists():
        raise ValueError("Refusing to overwrite GoogleService-Info.plist; use a fresh checkout")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("xb") as stream:
        plistlib.dump(synthetic_config(), stream, fmt=plistlib.FMT_XML, sort_keys=True)
    return {"syntheticConfiguration": True, "path": str(destination),
            "sha256": digest(destination), "bytes": destination.stat().st_size,
            "upstreamCredentialsUsed": False}


def project_overlay(original):
    """Derive the exact permitted project bytes without touching the file."""
    text = original.decode("utf-8")
    pattern = re.compile(r"(?m)^(?P<prefix>[ \t]*PRODUCT_BUNDLE_IDENTIFIER = )"
                         + r"(?P<identifier>[^;\r\n]+)(?P<tail>;[ \t]*\r?)$")
    matches = list(pattern.finditer(text))
    suffixes = ("", ".widget", ".shareextension", ".tests", ".uitests")
    upstream_counts = {suffix: sum(item["identifier"] == UPSTREAM_BUNDLE + suffix for item in matches)
                       for suffix in suffixes}
    independent_counts = {suffix: sum(item["identifier"] == MAIN_BUNDLE + suffix for item in matches)
                          for suffix in suffixes}
    setting_count = len(re.findall(r"(?m)^[ \t]*PRODUCT_BUNDLE_IDENTIFIER\b", text))
    already_independent = all(count == 2 for count in independent_counts.values())
    all_upstream = all(count == 2 for count in upstream_counts.values())
    if len(matches) != 10 or setting_count != 10 or not (already_independent or all_upstream):
        raise ValueError("Expected exactly ten bundle-ID settings, two per target, all upstream or all independent")
    if already_independent:
        overlaid, counts, before_family = original, independent_counts, MAIN_BUNDLE
    else:
        overlaid = pattern.sub(lambda item: item["prefix"] + MAIN_BUNDLE
                               + item["identifier"][len(UPSTREAM_BUNDLE):] + item["tail"], text).encode("utf-8")
        counts, before_family = upstream_counts, UPSTREAM_BUNDLE
    record = {"schemaVersion": 1, "path": PROJECT, "replacementCount": 0 if already_independent else 10,
              "identifiersAlreadyIndependent": already_independent,
              "originalSHA256": hashlib.sha256(original).hexdigest(),
              "overlaySHA256": hashlib.sha256(overlaid).hexdigest(), "expectedTrackedOverlay": not already_independent,
              "settings": [{"before": before_family + suffix, "after": MAIN_BUNDLE + suffix, "count": count}
                           for suffix, count in counts.items()],
              "scope": "Only PRODUCT_BUNDLE_IDENTIFIER settings; entitlements and other identifiers are unchanged in source."}
    return overlaid, record


def review_project_overlay(record, original_bytes, project_bytes):
    """Verify source identity, record fields and actual bytes for both profiles."""
    if not isinstance(record, dict):
        raise ValueError("Project overlay record must be an object")
    expected_bytes, expected_record = project_overlay(original_bytes)
    for key, expected in expected_record.items():
        if type(record.get(key)) is not type(expected) or record[key] != expected:
            raise ValueError("Project overlay record differs from source identity: " + key)
    if project_bytes != expected_bytes:
        raise ValueError("Working project differs from its exact recorded source overlay")
    return expected_record["expectedTrackedOverlay"]


def overlay_project(project, report_path):
    """Validate ten independent IDs, or replace exactly ten upstream settings."""
    project, report_path = checked_path(project), checked_path(report_path)
    if report_path.exists():
        raise ValueError("Refusing to overwrite an existing project overlay record")
    original = project.read_bytes()
    overlaid, record = project_overlay(original)
    # Write the audit record first; failure must not leave an unrecorded overlay.
    write_new_json(report_path, record)
    if overlaid != original:
        project.write_bytes(overlaid)
    return record


def validate_tag():
    source = subprocess.check_output(["git", "-C", str(REPO), "rev-parse", "HEAD"], text=True).strip()
    if not re.fullmatch(r"[0-9a-f]{40}", source):
        raise ValueError("Git did not return a full source SHA")
    if os.environ.get("GITHUB_SHA") != source or os.environ.get("GITHUB_REF_NAME") != "reader-experience-" + source[:7]:
        raise ValueError("Expected reader-experience-<current SHA7> tag and matching checkout")
    return {"sourceCommit": source}


def inspect_settings(settings, with_jvm=False, diagnostic=False):
    matches = [item["buildSettings"] for item in settings if item.get("target") == MAIN_TARGET]
    if len(matches) != 1:
        raise ValueError("Expected exactly one main yuedu app target in build settings")
    values = matches[0]
    required = {"CONFIGURATION": "Release", "SWIFT_VERSION": "5.0",
                "IPHONEOS_DEPLOYMENT_TARGET": "18.0" if with_jvm else "17.0", "PLATFORM_NAME": "iphoneos",
                "FULL_PRODUCT_NAME": MAIN_PRODUCT, "PRODUCT_BUNDLE_IDENTIFIER": MAIN_BUNDLE,
                "ARCHS": "arm64", "CODE_SIGNING_ALLOWED": "NO", "YUEDU_LOCAL_EXPERIENCE": "YES",
                "CODE_SIGN_ENTITLEMENTS": "", "GATEWAY_BASE_URL": ""}
    for name, expected in required.items():
        # Xcode may omit an empty build setting in its JSON representation.
        if values.get(name, "" if expected == "" else None) != expected:
            raise ValueError(f"Unexpected actual build setting {name}: {values.get(name)!r}; expected {expected!r}")
    directory = Path(values.get("TARGET_BUILD_DIR", ""))
    if not directory.is_absolute():
        raise ValueError("TARGET_BUILD_DIR must be absolute")
    app = checked_path(directory / MAIN_PRODUCT)
    result = {"schemaVersion": 1, "target": MAIN_TARGET, "appPath": str(app),
            "verifiedSettings": required,
            "version": values.get("MARKETING_VERSION"), "build": values.get("CURRENT_PROJECT_VERSION"),
            "sdk": values.get("SDK_NAME"), "swiftStrictConcurrency": values.get("SWIFT_STRICT_CONCURRENCY"),
            "swiftDefaultActorIsolation": values.get("SWIFT_DEFAULT_ACTOR_ISOLATION"),
            "localExperience": True, "signed": False}
    if diagnostic:
        if not with_jvm:
            raise ValueError("Diagnostic packages require the complete JVM")
        targets = {}
        for target, (product, identifier) in DIAGNOSTIC_TARGETS.items():
            actual = [item["buildSettings"] for item in settings if item.get("target") == target]
            if len(actual) != 1:
                raise ValueError("Expected exactly one diagnostic target: " + target)
            actual = actual[0]
            expected = dict(required, FULL_PRODUCT_NAME=product, PRODUCT_BUNDLE_IDENTIFIER=identifier,
                            SWIFT_OPTIMIZATION_LEVEL="-Onone", SWIFT_COMPILATION_MODE="singlefile",
                            CODE_SIGNING_REQUIRED="NO", ENABLE_DEBUG_DYLIB="NO", CURRENT_PROJECT_VERSION="18")
            for key, value in expected.items():
                if actual.get(key, "" if value == "" else None) != value:
                    raise ValueError("Unexpected diagnostic setting " + target + " " + key)
            conditions = actual.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "").split()
            defines = actual.get("GCC_PREPROCESSOR_DEFINITIONS", "").split()
            flags = actual.get("OTHER_SWIFT_FLAGS", "").split()
            if (any(token == "DEBUG" or token.startswith("DEBUG=") for token in conditions + defines)
                    or any(token.startswith("-DDEBUG") for token in flags)
                    or any(flags[i] == "-D" and flags[i + 1].startswith("DEBUG") for i in range(len(flags) - 1))
                    or any(token in ("-O", "-Osize", "-Ounchecked", "-wmo", "-whole-module-optimization") for token in flags)):
                raise ValueError("Diagnostic targets must retain non-DEBUG production branches")
            targets[target] = dict(expected, SWIFT_ACTIVE_COMPILATION_CONDITIONS=conditions,
                                   GCC_PREPROCESSOR_DEFINITIONS=defines, OTHER_SWIFT_FLAGS=flags)
        result.update(diagnosticOnly=True, releaseAcceptance=False, S3Acceptance="not_run", diagnosticTargets=targets)
    return result


def diagnostic_package_budget(app, ipa):
    app, ipa = checked_path(app), checked_path(ipa)
    total = 0
    for path in app.rglob("*"):
        checked_path(path)
        if path.is_file():
            size = path.stat().st_size
            if size > DIAGNOSTIC_FILE_BYTES:
                raise ValueError("Diagnostic file exceeds the production signing budget")
            total += size
            if total > DIAGNOSTIC_PACKAGE_BYTES:
                raise ValueError("Diagnostic app exceeds the production expanded-package budget")
    if not 0 < ipa.stat().st_size <= DIAGNOSTIC_PACKAGE_BYTES:
        raise ValueError("Diagnostic IPA exceeds the production archive budget")
    with zipfile.ZipFile(ipa) as archive:
        expanded = 0
        for item in archive.infolist():
            if item.file_size > DIAGNOSTIC_FILE_BYTES or item.compress_size > DIAGNOSTIC_FILE_BYTES:
                raise ValueError("Diagnostic ZIP entry exceeds the production signing budget")
            expanded += item.file_size
            if expanded > DIAGNOSTIC_PACKAGE_BYTES:
                raise ValueError("Diagnostic ZIP exceeds the production expanded-package budget")
        if archive.testzip() is not None:
            raise ValueError("Diagnostic IPA failed CRC validation")
    return {"fileBytesLimit": DIAGNOSTIC_FILE_BYTES, "expandedBytesLimit": DIAGNOSTIC_PACKAGE_BYTES,
            "appFileBytes": total, "archiveExpandedBytes": expanded, "crcVerified": True}


def read_info(bundle):
    with checked_path(bundle / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable or executable != Path(executable).name or "/" in executable or "\\" in executable:
        raise ValueError("Bundle executable must be a bundle-local filename")
    if not checked_path(bundle / executable).is_file():
        raise ValueError("Bundle executable is absent")
    return info


def extension_bundles(app):
    plugins = checked_path(app / "PlugIns")
    bundles = {path.name: checked_path(path) for path in plugins.glob("*.appex")}
    if set(bundles) != set(EXTENSIONS):
        raise ValueError("Both original Widget and ShareExtension must be embedded")
    for name, bundle in bundles.items():
        info = read_info(bundle)
        bundle_id, extension_point = EXTENSIONS[name]
        if info.get("CFBundleIdentifier") != bundle_id or info.get("NSExtension", {}).get("NSExtensionPointIdentifier") != extension_point:
            raise ValueError("Embedded extension identity or extension point changed: " + name)
    return bundles


def no_jvm_payload(app):
    runtime = checked_path(app / "LegadoRuntime")
    if runtime.exists():
        if any(runtime.rglob("*.jar")) or (runtime / "java-home").exists() or (runtime / "runtime-manifest.json").exists():
            raise ValueError("The JSC experience must not accidentally include a staged JVM payload")
    if (app / "lib/modules/java.base").exists():
        raise ValueError("Unexpected JVM bootstrap modules in the reader experience")


def verify_jvm_payload(app):
    # Notices are separately owned App resources; native Java-home/JAR identity
    # and the seven fixed producer inputs remain independent of this inventory.
    notice_spec = importlib.util.spec_from_file_location("reader_packaged_notices", Path(__file__).with_name("runtime-notices.py"))
    notices = importlib.util.module_from_spec(notice_spec)
    notice_spec.loader.exec_module(notices)
    notice_validation = notices.verify(checked_path(app / "LegadoRuntime/Notices"))
    script = REPO / "scripts/legado-ios/verify-runtime.py"
    spec = importlib.util.spec_from_file_location("reader_packaged_runtime", script)
    validator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(validator)
    jar = checked_path(app / "LegadoRuntime/legado-runtime.jar")
    home = checked_path(app / "lib")
    validation = validator.validate(home, jar)
    if (app / "LegadoRuntime/java-home").exists():
        raise ValueError("The reader JVM must boot from App.app/lib")
    staging = json.loads((app / "LegadoRuntime/runtime-manifest.json").read_bytes())
    if staging.get("jarSHA256") != digest(jar):
        raise ValueError("Packaged JVM JAR differs from its staging manifest")
    packaging_spec = importlib.util.spec_from_file_location("reader_ordinary_jar", Path(__file__).with_name("runtime-packaging.py"))
    packaging = importlib.util.module_from_spec(packaging_spec)
    packaging_spec.loader.exec_module(packaging)
    if digest(jar) != digest(packaging.JAR):
        raise ValueError("Packaged JVM JAR differs from this run's freshly built ordinary JAR")
    if staging.get("sourcePins") != json.loads((REPO / "scripts/legado-ios/runtime-lock.json").read_bytes()):
        raise ValueError("Packaged runtime pin differs from this checkout")
    if staging.get("runtimeNotices") != notice_validation:
        raise ValueError("Packaged runtime notices differ from their staging manifest")
    return {"validation": validation, "jar": packaging.inspect_jar(jar), "notices": notice_validation}


def finalize(app, source, with_jvm=False):
    if re.fullmatch(r"[0-9a-f]{40}", source) is None:
        raise ValueError("A full source SHA is required")
    app = checked_path(app)
    if app.name != MAIN_PRODUCT:
        raise ValueError("The experience must retain the YueduReader.app product")
    if with_jvm:
        verify_jvm_payload(app)
    else:
        no_jvm_payload(app)
    bundles = {MAIN_PRODUCT: app, **extension_bundles(app)}
    # Check all bundle/configuration identities before mutating unsigned output.
    for bundle in bundles.values():
        read_info(bundle)
        with checked_path(bundle / "GoogleService-Info.plist").open("rb") as stream:
            if plistlib.load(stream) != synthetic_config():
                raise ValueError("Built GoogleService-Info.plist is not the exact synthetic configuration")
        if (bundle / "_CodeSignature").exists():
            raise ValueError("Expected unsigned app/extension output before packaging")
    for name, bundle in bundles.items():
        info = read_info(bundle)
        info.update(LOCAL_FLAGS)
        info["GatewayBaseURL"] = ""
        info["YueduExperienceSourceCommit"] = source
        info["GitCommitSHA"] = source[:7]
        if name == MAIN_PRODUCT:
            if info.get("CFBundleIdentifier") != MAIN_BUNDLE or info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"] or info.get("MinimumOSVersion") != ("18.0" if with_jvm else "17.0"):
                raise ValueError("Main product must retain its iPhoneOS identity and the selected minimum iOS")
            info["GIDClientID"] = GOOGLE_CLIENT
            # Preserve yuedu/legado document-import URLs, replacing only Google's
            # inherited OAuth redirect identity in this unsigned experience.
            for item in info.get("CFBundleURLTypes", []):
                schemes = item.get("CFBundleURLSchemes", [])
                item["CFBundleURLSchemes"] = [GOOGLE_REVERSED if value.startswith("com.googleusercontent.apps.") else value
                                               for value in schemes]
        (bundle / "Info.plist").write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY, sort_keys=False))
    return bundle_summary(app, with_jvm=with_jvm)


def bundle_summary(app, with_jvm=False):
    runtime = verify_jvm_payload(app) if with_jvm else None
    if not with_jvm:
        no_jvm_payload(app)
    bundles = {MAIN_PRODUCT: app, **extension_bundles(app)}
    result = []
    for name, bundle in bundles.items():
        info = read_info(bundle)
        for key, value in LOCAL_FLAGS.items():
            if info.get(key) is not value:
                raise ValueError("Required local-experience flag is missing: " + key)
        if info.get("GatewayBaseURL") != "":
            raise ValueError("The local experience must not contain a configured gateway")
        if not info.get("CFBundleShortVersionString") or not info.get("CFBundleVersion"):
            raise ValueError("Bundle version/build are missing")
        result.append({"bundle": name, "bundleIdentifier": info["CFBundleIdentifier"],
                       "executable": info["CFBundleExecutable"],
                       "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
                       "infoPlistSHA256": digest(bundle / "Info.plist"),
                       "syntheticGoogleConfigSHA256": digest(bundle / "GoogleService-Info.plist")})
    if len({(item["version"], item["build"]) for item in result}) != 1:
        raise ValueError("App and extensions have mismatched version/build values")
    return {"bundles": result, "localFlags": LOCAL_FLAGS, "extensionsPreserved": True,
            "jvmPayloadIncluded": with_jvm, "runtimePayload": runtime, "upstreamCredentialsUsed": False}


def require_no_bundled_sources(roots):
    """Reject historical source-pack resources without reading or modifying them."""
    names = ("BuiltInBookSources.json", "BuiltInBookSources.manifest.json")
    for root in roots:
        root = checked_path(root)
        if not root.is_dir():
            raise ValueError("The source-pack exclusion check requires an existing directory")
        if any(next(root.rglob(name), None) is not None for name in names):
            raise ValueError("Built-in book-source resources are disabled for reader packages; import sources in the app")
    return {"included": False}


def bundled_sources(app, resource_root=None):
    root = resource_root if resource_root is not None else REPO / "Resources"
    names = ("BuiltInBookSources.json", "BuiltInBookSources.manifest.json")
    source_paths = [root / name for name in names]
    built_paths = [app / name for name in names]
    if not any(path.exists() for path in source_paths):
        if any(path.exists() for path in built_paths):
            raise ValueError("Unexpected bundled book sources absent from this checkout")
        return {"included": False}
    if not all(path.is_file() for path in (*source_paths, *built_paths)):
        raise ValueError("Both the source pack and its manifest must be packaged")
    metadata = json.loads(source_paths[1].read_bytes())
    expected = metadata.get("sha256")
    if (type(metadata.get("schemaVersion")) is not int or metadata["schemaVersion"] != 1
            or not isinstance(metadata.get("version"), str) or not metadata["version"].strip()
            or not isinstance(expected, str) or re.fullmatch(r"[0-9a-f]{64}", expected) is None
            or digest(source_paths[0]) != expected or digest(built_paths[0]) != expected
            or source_paths[1].read_bytes() != built_paths[1].read_bytes()):
        raise ValueError("Bundled book-source bytes/manifest differ from the pinned resource")
    sources = json.loads(built_paths[0].read_bytes())
    if not isinstance(sources, list) or not sources or not all(isinstance(item, dict) for item in sources):
        raise ValueError("Bundled book sources must contain a nonempty source array")
    return {"included": True, "version": metadata["version"], "sha256": expected,
            "bytes": built_paths[0].stat().st_size, "sourceCount": len(sources),
            "mainJsSourceCount": sum(isinstance(item.get("mainJs"), str) and bool(item["mainJs"].strip()) for item in sources),
            "realSourceAvailabilityValidated": False}


def manifest(app, ipa, settings, source, xcode, overlay, with_jvm=False, diagnostic=False):
    require_no_bundled_sources([REPO / "Resources", app])
    summary = bundle_summary(app, with_jvm=with_jvm)
    info = read_info(app)
    if info.get("YueduExperienceSourceCommit") != source:
        raise ValueError("Packaged app source stamp differs from HEAD")
    for item in summary["bundles"]:
        if item["version"] != settings.get("version") or item["build"] != settings.get("build"):
            raise ValueError("Packaged version differs from the actual main target build settings")
    dirty = bool(subprocess.check_output(["git", "-C", str(REPO), "status", "--porcelain"], text=True).strip())
    tracked = subprocess.check_output(["git", "-C", str(REPO), "diff", "--name-only", "HEAD"], text=True).splitlines()
    original = subprocess.check_output(["git", "-C", str(REPO), "show", "HEAD:" + PROJECT])
    has_project_overlay = review_project_overlay(overlay, original, (REPO / PROJECT).read_bytes())
    expected_tracked = [PROJECT] if has_project_overlay else []
    if tracked != expected_tracked or (has_project_overlay and not dirty):
        raise ValueError("Expected exactly the recorded project bundle-ID overlay as a tracked change")
    resolved = REPO / "Yuedu-Reader.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    result = {"schemaVersion": 1, "artifactKind": "legado-mainjs-reader-prototype" if with_jvm else "yuedu-local-reader-experience", "createdAt": utc_now(),
            "sourceCommit": source, "workingTreeDirty": dirty, "version": info["CFBundleShortVersionString"],
            "expectedTrackedOverlay": has_project_overlay, "trackedChanges": tracked, "projectOverlay": overlay,
            "build": info["CFBundleVersion"], "bundleIdentifier": info["CFBundleIdentifier"],
            "displayName": info.get("CFBundleDisplayName", info.get("CFBundleName")),
            "configuration": "Release", "architecture": "arm64", "platform": "iPhoneOS", "minimumIOS": "18.0" if with_jvm else "17.0",
            "actualBuildSettings": settings, "xcode": xcode, "developerDirectory": os.environ.get("DEVELOPER_DIR"),
            "swiftPackageResolvedSHA256": digest(resolved), "bundleValidation": summary,
            "bundledBookSources": bundled_sources(app),
            "ipaSHA256": digest(ipa), "ipaBytes": ipa.stat().st_size,
            "readerRoute": "Original traditional text WebBook and finite mainJs via Rhino/JVM; native CoreText reader" if with_jvm else "Native CoreText reader; JVM-backed default source routes unavailable without the embedded runtime",
            "jvmIntegratedIntoReading": with_jvm, "nativeJVMCompiled": with_jvm,
            "mainJsRouteExecutionValidated": False,
            "syntheticBackendConfiguration": True, "backendServicesConfigured": False,
            "deviceCompilationPassed": True, "signed": False, "deviceValidationPassed": False,
            "simulatorExecution": "not_run", "functionalAcceptance": "not_run",
            "limitations": ["Unsigned: sign the app and embedded extensions before installation.",
                            "Original traditional text consumers and finite mainJs use the JVM. Book-source and host coverage remains incomplete; full Legado compatibility is unverified." if with_jvm else "This package retains the CoreText reader without the JVM required by default source routes; it is not the full Legado port.",
                            "Accounts, subscription verification, CloudKit and remote backend features are not configured in local experience mode.",
                            "Compilation and packaging do not prove import/search/reading/TTS/RSS work on this device."]}
    if diagnostic:
        if (not with_jvm or settings.get("diagnosticOnly") is not True
                or settings.get("releaseAcceptance") is not False or settings.get("S3Acceptance") != "not_run"):
            raise ValueError("Diagnostic manifest requires its explicit verified settings")
        result.update(artifactKind=DIAGNOSTIC_KIND, diagnosticOnly=True, releaseAcceptance=False,
                      S3Acceptance="not_run", swiftOptimizationLevel="-Onone", swiftCompilationMode="singlefile",
                      productionConditionalBranches=True, packageBudget=diagnostic_package_budget(app, ipa))
        result["limitations"].insert(0, "Diagnostic compilation only: unoptimized Swift, no Release/S3 acceptance or performance claim.")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("validate-tag")
    sources = commands.add_parser("require-no-source-pack")
    sources.add_argument("--root", type=Path, action="append", required=True)
    staging = commands.add_parser("stage")
    staging.add_argument("--destination", type=Path, default=REPO / "GoogleService-Info.plist")
    overlay = commands.add_parser("overlay-project")
    overlay.add_argument("--project", type=Path, default=REPO / PROJECT)
    overlay.add_argument("--report", type=Path, required=True)
    inspect = commands.add_parser("inspect-settings")
    inspect.add_argument("--settings", type=Path, required=True)
    inspect.add_argument("--output", type=Path, required=True)
    inspect.add_argument("--with-jvm", action="store_true")
    inspect.add_argument("--diagnostic", action="store_true")
    final = commands.add_parser("finalize")
    final.add_argument("--app", type=Path, required=True)
    final.add_argument("--source", required=True)
    final.add_argument("--with-jvm", action="store_true")
    report = commands.add_parser("manifest")
    report.add_argument("--app", type=Path, required=True)
    report.add_argument("--ipa", type=Path, required=True)
    report.add_argument("--settings", type=Path, required=True)
    report.add_argument("--source", required=True)
    report.add_argument("--xcode-file", type=Path, required=True)
    report.add_argument("--output", type=Path, required=True)
    report.add_argument("--overlay", type=Path, required=True)
    report.add_argument("--with-jvm", action="store_true")
    report.add_argument("--diagnostic", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "validate-tag":
            value = validate_tag()
        elif args.command == "require-no-source-pack":
            value = require_no_bundled_sources(args.root)
        elif args.command == "stage":
            value = stage(args.destination)
        elif args.command == "overlay-project":
            value = overlay_project(args.project, args.report)
        elif args.command == "inspect-settings":
            value = inspect_settings(json.loads(args.settings.read_text(encoding="utf-8")), with_jvm=args.with_jvm,
                                     diagnostic=args.diagnostic)
            write_new_json(args.output, value)
            print(value["appPath"])
            return 0
        elif args.command == "finalize":
            value = finalize(args.app, args.source, with_jvm=args.with_jvm)
        else:
            value = manifest(args.app, args.ipa, json.loads(args.settings.read_text(encoding="utf-8")),
                             args.source, args.xcode_file.read_text(encoding="utf-8").strip(),
                             json.loads(args.overlay.read_text(encoding="utf-8")), with_jvm=args.with_jvm,
                             diagnostic=args.diagnostic)
            write_new_json(args.output, value)
        print(json.dumps(value, indent=2, ensure_ascii=False))
        return 0
    except Exception as error:
        print(f"{type(error).__name__}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
