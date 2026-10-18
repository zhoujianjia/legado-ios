#!/usr/bin/env python3
"""Package a fresh ordinary reader JAR with the audited source-built Zero VM."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import struct
import zipfile


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
spec = importlib.util.spec_from_file_location("reader_native_helpers", HERE.parent / "legado-ios/verify-native-reuse.py")
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
JAR = REPO / native.JAR_PATH
REQUIRED = ("io/yuedu/legado/LegadoRuntime.class", "io/yuedu/legado/NativeHost.class",
            "io/yuedu/legado/ProductionHttpTransport.class", "io/yuedu/legado/RuntimeSessionOptions.class",
            "io/yuedu/legado/StaticScalarSelectorRule.class", "org/htmlunit/corejs/javascript/Context.class",
            "okhttp3/OkHttpClient.class", "org/brotli/dec/BrotliInputStream.class",
            "org/apache/commons/text/StringEscapeUtils.class", "org/apache/commons/lang3/StringUtils.class")
PROJECT_TEST_CLASSES = (
    "io/legado/app/JsEngineCapabilitiesTest",
    "io/legado/app/model/analyzeRule/AnalyzeByJSoupDomTest",
    "io/legado/app/model/analyzeRule/AnalyzeByJSonPathErrorPolicyTest",
    *("io/yuedu/legado/" + name for name in (
        "CpuLoopCapabilityProbeTest", "DeclarativeSourceTest", "InteropSemanticSuiteTest", "LegadoRuntimeTest",
        "MainJsFacadeTest", "MainJsResultMarshallerTest", "MainJsScopeTest", "OkHttpWireCapabilityProbeTest",
        "ProductionHttpTransportTest", "SourceHttpSemanticsTest", "StaticRuleReplacementTest", "TlsCapabilityProbeTest",
        "StaticScalarSelectorRuleTest", "DeclarativeScalarSelectorTest")),
)


def scalar_manifest():
    return json.loads((REPO / "Packages/LegadoRuntime/vendor/scalar-rules/manifest.json").read_bytes())


def inspect_jar(jar):
    with zipfile.ZipFile(jar) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)) or not set(REQUIRED).issubset(names):
            raise ValueError("Ordinary reader JAR has duplicate entries or lacks the production engine/HTTP classes")
        forbidden = ("org/junit/", "org/hamcrest/", "fixtures/", "io/yuedu/legado/tls-fixture-v1/", "io/legado/app/JsEngineCapabilitiesTest",
                     "io/yuedu/legado/ProbeOkHttpTransport", "io/yuedu/legado/CpuLoopCapabilityProbe",
                     "io/yuedu/legado/ReferenceLoopbackFixture", "io/yuedu/legado/OkHttpWireCapabilityProbe",
                     "io/yuedu/legado/ProductionHttpTransportTest")
        if any(name.startswith(forbidden) or any(name == test + ".class" or name.startswith(test + "$")
                                                for test in PROJECT_TEST_CLASSES) for name in names):
            raise ValueError("Reader JAR must not package optional test fixtures or JUnit")
        if b"Legado-Engine-Tests: false" not in archive.read("META-INF/MANIFEST.MF"):
            raise ValueError("Reader JAR must declare ordinary packaging")
        for name in ("manifest.json", "resolved-dependencies.json"):
            if archive.read("META-INF/legado-provenance/runtime-http/" + name) != (REPO / "Packages/LegadoRuntime/vendor/runtime-http" / name).read_bytes():
                raise ValueError("Packaged production HTTP provenance differs from this source checkout")
        for directory in (REPO / "Packages/LegadoRuntime/vendor/runtime-http/licenses", REPO / "Packages/LegadoRuntime/vendor/probe/licenses"):
            for license in directory.rglob("*"):
                if license.is_file() and archive.read("META-INF/licenses/jvm-http/" + license.relative_to(directory).as_posix()) != license.read_bytes():
                    raise ValueError("Packaged production HTTP license differs from its source")
        scalar = REPO / "Packages/LegadoRuntime/vendor/scalar-rules"
        scalar_origin = scalar_manifest()
        for name in ("manifest.json", "resolved-dependencies.json"):
            entry = "META-INF/legado-provenance/scalar-rules/" + name
            if entry not in names or archive.read(entry) != (scalar / name).read_bytes():
                raise ValueError("Packaged scalar-rule provenance differs from this source checkout")
        if hashlib.sha256((scalar / "resolved-dependencies.json").read_bytes()).hexdigest() != scalar_origin["resolvedGraphSHA256"]:
            raise ValueError("Scalar-rule dependency graph differs from its recorded hash")
        for item in scalar_origin["requiredRuntimeClasses"]:
            if hashlib.sha256(archive.read(item["path"])).hexdigest() != item["sha256"]:
                raise ValueError("Packaged commons-text/lang3 class differs from its pinned release bytes")
        for item in scalar_origin["licenseFiles"]:
            expected = (scalar / item["path"]).read_bytes()
            entry = "META-INF/licenses/scalar-rules/" + item["path"].removeprefix("licenses/")
            if (hashlib.sha256(expected).hexdigest() != item["sha256"]
                    or entry not in names or archive.read(entry) != expected):
                raise ValueError("Packaged scalar-rule license/NOTICE differs from its pinned release bytes")
        for item in scalar_origin["packagedJarMetadata"]:
            expected = (scalar / item["path"]).read_bytes()
            if (hashlib.sha256(expected).hexdigest() != item["sha256"]
                    or item["jarEntry"] not in names or archive.read(item["jarEntry"]) != expected):
                raise ValueError("Packaged scalar-rule Maven version metadata differs from its pinned release bytes")
        origin = json.loads((REPO / "Packages/LegadoRuntime/vendor/runtime-http/manifest.json").read_bytes())
        for source in origin["encodingSources"]:
            actual = REPO / "Packages/LegadoRuntime" / source["portedPath"]
            if native.sha256(actual) != source["portedSHA256"]:
                raise ValueError("Ported charset source differs from its recorded bytes")
        maximum = 0
        for name in names:
            if name.endswith(".class") and not name.startswith("META-INF/versions/"):
                with archive.open(name) as stream:
                    header = stream.read(8)
                if len(header) != 8 or header[:4] != b"\xca\xfe\xba\xbe":
                    raise ValueError("Malformed reader class header")
                minor, major = struct.unpack(">HH", header[4:])
                if minor == 65535:
                    raise ValueError("Preview bytecode is unsupported")
                maximum = max(maximum, major)
    return {"sha256": native.sha256(jar), "bytes": jar.stat().st_size,
            "maximumBaseClassMajor": maximum, "requiredClasses": list(REQUIRED), "testClassesIncluded": False}


def audit_native(root, jar):
    details = inspect_jar(jar)
    if (root / native.LOCK).read_bytes() != (REPO / native.LOCK).read_bytes():
        raise ValueError("Extracted native artifact pin differs from this checkout")
    required = set(json.loads((REPO / native.LOCK).read_bytes())["requiredModules"])
    result = {}
    for platform, relative in native.HOMES.items():
        home = root / relative
        if {path.name for path in (home / "modules").iterdir() if path.is_dir()} != required:
            raise ValueError("Native module inventory differs from its pin")
        result[platform] = native.verifier.validate(home, jar, root / native.FRAMEWORK)
        result[platform]["bytecodeCompatibility"] = native.native_bytecode_compatibility(home, details["maximumBaseClassMajor"])
    return {"jar": details, "nativeLayout": result, "nativeExecutionVerified": False, "deviceValidationPassed": False}


def validate_tag():
    source = native.replay.valid_sha(native.replay.git("rev-parse", "HEAD"))
    if os.environ.get("GITHUB_SHA") != source or os.environ.get("GITHUB_REF_NAME") != "reader-legado-" + source[:7]:
        raise ValueError("Expected reader-legado-<current SHA7> and matching checkout")
    return source


def restore():
    source = validate_tag()
    if native.replay.git("status", "--porcelain", "--untracked-files=no"):
        raise ValueError("Reader native restoration requires a clean tracked checkout")
    api = native.replay.GitHub(os.environ.get("GITHUB_REPOSITORY", ""), os.environ.get("GITHUB_TOKEN", ""))
    native.replay.fetch_source(native.BASELINE_SHA, api.token)
    provenance = native.native_source(api)
    inputs = native.source_inputs(source)
    destinations = [(relative, native.replay.safe_path(REPO / relative)) for relative in native.ROOTS]
    if any(destination.exists() for _, destination in destinations):
        raise ValueError("Refusing to overwrite existing native runtime products")
    work = native.replay.safe_path(REPO / ".build/reader-native")
    archive, extracted = work / "native.zip", work / "extracted"
    native.download_native(api, archive)
    native.extract_native(archive, extracted)
    result = audit_native(extracted, JAR)
    for relative, destination in destinations:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(extracted / relative, destination)
    (REPO / "Packages/LegadoRuntime/Package.swift").touch()
    return {"schemaVersion": 1, "sourceCommit": source, "workflowRunID": os.environ.get("GITHUB_RUN_ID"),
            "status": "restored", "nativeProducer": provenance, "nativeInputChecks": inputs,
            "nativeZIP": {"bytes": archive.stat().st_size, "sha256": native.sha256(archive)},
            "nativeRuntimeRecompiled": False, "freshOrdinaryJVMRequired": True,
            "scope": "Audited native reuse and this checkout's ordinary JAR; no historical device acceptance is transferred.", **result}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("validate-tag", "restore", "audit", "inspect-jar"))
    parser.add_argument("--native-root", type=Path)
    parser.add_argument("--jar", type=Path, default=JAR)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.phase == "validate-tag":
        result = {"sourceCommit": validate_tag()}
    elif args.phase == "restore":
        result = restore()
    elif args.phase == "inspect-jar":
        result = inspect_jar(args.jar)
    else:
        if args.native_root is None:
            parser.error("audit requires --native-root")
        result = audit_native(args.native_root, args.jar)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open("x", encoding="utf-8") as stream:
            json.dump(result, stream, indent=2)
            stream.write("\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
