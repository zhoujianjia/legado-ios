#!/usr/bin/env python3
"""Build a fresh JVM payload with one audited, immutable native runtime.

This protocol is separate from verify-runtime-reuse.py: the old replay still
requires an unchanged JVM tree. No old JVM payload is downloaded or restored.
Only the fixed native ZIP below is accepted, including its actual bytes/hash.
Static checks and Simulator execution do not pass any physical-device gate.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


replay = load("native_reuse_helpers", HERE / "verify-runtime-reuse.py")
verifier = load("native_reuse_validator", HERE / "verify-runtime.py")
# Probe 12: source-built Zero with the audited Darwin signal-PC accessors.
# Historical physical-device results remain tied to their own original builds.
BASELINE_RUN = 39083752761
BASELINE_SHA = "ce792982a30942e605fc935b733c5b41bef2736a"
BASELINE_ARTIFACT = 12120530642
BASELINE_DIGEST = "6d91463d6e28a1bcc6c1d5ba79ad88f5a8d1ba79d0e2e11e78b5fbd5520346ac"
BASELINE_BYTES = 89898489
SOURCE_WORKFLOW = ".github/workflows/legado-ios-prototype.yml"
SOURCE_WORKFLOW_BLOB = "acc22e4f49b24200f75f85b679564b4e8867d28c"
CURRENT_WORKFLOW = ".github/workflows/legado-ios-core-update.yml"
NATIVE_NAME = "legado-zero-source-build"
JVM_NAME = "legado-jvm-payload"
JVM_INPUTS = (
    "Packages/LegadoRuntime/jvm",
    "Packages/LegadoRuntime/vendor/maven",
    "Packages/LegadoRuntime/vendor/LICENSE",
    "Packages/LegadoRuntime/vendor/licenses",
    "Packages/LegadoRuntime/vendor/manifest.json",
    "Packages/LegadoRuntime/vendor/probe",
    "Packages/LegadoRuntime/vendor/runtime-http",
    "Packages/LegadoRuntime/vendor/scalar-rules",
)
REQUIRED_GRADLE_TASKS = ["test", "runtimeJar", "runtimeSmoke", "runtimeSuiteSmoke",
                         "runtimeWireSmoke", "runtimeCpuLoopSmoke", "probeDependencyEvidence"]
FRAMEWORK = "Packages/LegadoRuntime/Artifacts/OpenJDK.xcframework"
HOMES = {platform: f".build/legado-ios/{platform}-static/java-home"
         for platform in ("device", "simulator")}
LOCK = "scripts/legado-ios/runtime-lock.json"
ROOTS = (FRAMEWORK, *HOMES.values())
JAR_PATH = "Packages/LegadoRuntime/jvm/build/libs/legado-runtime.jar"
JVM_MANIFEST = "Packages/LegadoRuntime/jvm/build/libs/fresh-jvm.json"
REQUIRED_JAR_CLASSES = (
    "io/yuedu/legado/LegadoRuntime.class",
    "io/yuedu/legado/NativeHost.class",
    "org/htmlunit/corejs/javascript/Context.class",
    "org/apache/commons/text/StringEscapeUtils.class",
    "org/apache/commons/lang3/StringUtils.class",
    "io/legado/app/JsEngineCapabilitiesTest.class",
    "org/junit/runner/JUnitCore.class",
    "org/hamcrest/Matcher.class",
    "io/yuedu/legado/InteropSemanticSuite.class",
    "io/yuedu/legado/interop/InteropFixture.class",
    "io/yuedu/legado/MainJsResultMarshaller.class",
    "io/yuedu/legado/StaticScalarSelectorRule.class",
    "io/yuedu/legado/TlsCapabilityProbe.class",
    "io/yuedu/legado/HttpWireDiagnosticBridge.class",
    "io/yuedu/legado/OkHttpWireCapabilityProbe.class",
    "io/yuedu/legado/ReferenceLoopbackFixture.class",
    "io/yuedu/legado/ProbeOkHttpTransport.class",
    "io/yuedu/legado/CpuLoopDiagnosticBridge.class",
    "io/yuedu/legado/CpuLoopCapabilityProbe.class",
    "okhttp3/OkHttpClient.class",
    "okio/Buffer.class",
)
REQUIRED_JAR_RESOURCES = {
    "fixtures/main-source.js": "731f1f1f743b9bc393ea221a7118ff4a115ffa35947aa40c88ff088bb758a894",
}
MAX_ENTRIES = 120000
MAX_EXPANDED_BYTES = 2 * 1024 ** 3
MAX_ENTRY_BYTES = 512 * 1024 ** 2


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def current_checkout():
    current = replay.valid_sha(replay.git("rev-parse", "HEAD"))
    expected = os.environ.get("GITHUB_SHA")
    if expected is not None and expected != current:
        raise ValueError("Checkout does not match the current workflow SHA")
    validate_tag(os.environ.get("GITHUB_REF_NAME", ""), current)
    return current


def validate_tag(tag, current):
    replay.valid_sha(current)
    if tag != "legado-core-" + current[:7]:
        raise ValueError("Expected legado-core-<current SHA7> tag")


def source_inputs(current):
    if replay.git("status", "--porcelain", "--untracked-files=all", "--", *replay.NATIVE_INPUTS):
        raise ValueError("Native build inputs have uncommitted changes")
    checks = []
    for path in replay.NATIVE_INPUTS:
        try:
            before = replay.git("rev-parse", f"{BASELINE_SHA}:{path}")
        except RuntimeError as error:
            raise ValueError("Pinned native producer lacks a required build input; a fresh native build is required") from error
        after = replay.git("rev-parse", f"{current}:{path}")
        checks.append({"path": path, "sourceObject": before, "currentObject": after,
                       "matches": before == after})
    if not all(item["matches"] for item in checks):
        raise ValueError("Native inputs differ from the pinned native producer; a fresh native build is required")
    if replay.git("rev-parse", f"{BASELINE_SHA}:{SOURCE_WORKFLOW}") != SOURCE_WORKFLOW_BLOB:
        raise ValueError("Pinned native producer workflow blob differs")
    return checks


def jvm_inputs(current):
    # vendor/maven supplies the modified engine, and the other vendor paths are
    # consumed by runtimeJar. None may be omitted just because JVM_TREE differs.
    if replay.git("status", "--porcelain", "--untracked-files=all", "--", *JVM_INPUTS):
        raise ValueError("Fresh JVM inputs have uncommitted changes")
    return [{"path": path, "object": replay.git("rev-parse", f"{current}:{path}")}
            for path in JVM_INPUTS]


def checked_artifact(api, run_id, source_sha, name):
    candidates = [item for item in api.artifacts(run_id)
                  if item.get("name") == name and not item.get("expired", True)]
    if len(candidates) != 1:
        raise ValueError("Expected exactly one non-expired artifact: " + name)
    item = candidates[0]
    if type(item.get("id")) is not int or item["id"] <= 0:
        raise ValueError("Invalid artifact ID")
    if type(item.get("size_in_bytes")) is not int or item["size_in_bytes"] <= 0:
        raise ValueError("Invalid artifact size")
    if not isinstance(item.get("digest"), str) or re.fullmatch(r"sha256:[0-9a-f]{64}", item["digest"]) is None:
        raise ValueError("Artifact must have a SHA256 digest")
    origin = item.get("workflow_run", {})
    if origin.get("id") != run_id or origin.get("head_sha") != source_sha:
        raise ValueError("Artifact belongs to another run or source SHA")
    expires = item.get("expires_at")
    if not isinstance(expires, str) or datetime.fromisoformat(expires.replace("Z", "+00:00")) <= datetime.now(timezone.utc):
        raise ValueError("Artifact has expired or has no valid expiry")
    return {key: item[key] for key in ("id", "name", "size_in_bytes", "digest", "expires_at")}


def native_source(api):
    state = api.run(BASELINE_RUN)
    if (state.get("head_sha") != BASELINE_SHA or state.get("path") != SOURCE_WORKFLOW
            or state.get("name") != "Legado iOS Prototype" or state.get("status") != "completed"
            or state.get("conclusion") != "success"):
        raise ValueError("Native source run is not the successful, pinned native producer workflow")
    artifact = checked_artifact(api, BASELINE_RUN, BASELINE_SHA, NATIVE_NAME)
    if (artifact["id"] != BASELINE_ARTIFACT or artifact["size_in_bytes"] != BASELINE_BYTES
            or artifact["digest"] != "sha256:" + BASELINE_DIGEST):
        raise ValueError("Native artifact does not match the audited native producer ID, size and digest")
    return {"runID": BASELINE_RUN, "sourceSHA": BASELINE_SHA, "runAttempt": state.get("run_attempt"),
            "workflowPath": SOURCE_WORKFLOW, "workflowBlob": SOURCE_WORKFLOW_BLOB,
            "runURL": state.get("html_url"), "artifact": artifact}


def current_run_id():
    value = os.environ.get("GITHUB_RUN_ID", "")
    if not re.fullmatch(r"[1-9][0-9]*", value):
        raise ValueError("GITHUB_RUN_ID is required")
    return int(value)


def fresh_artifact(api, current):
    run_id = current_run_id()
    state = api.run(run_id)
    if state.get("head_sha") != current or state.get("path") != CURRENT_WORKFLOW:
        raise ValueError("Fresh JVM artifact must come from this core-update run and checkout")
    return checked_artifact(api, run_id, current, JVM_NAME)


def jar_details(jar):
    with zipfile.ZipFile(jar) as archive:
        entries = archive.infolist()
        names = [item.filename for item in entries]
        if len(names) != len(set(names)):
            raise ValueError("Fresh JAR has duplicate entries")
        missing = sorted(set(REQUIRED_JAR_CLASSES) - set(names))
        if missing:
            raise ValueError("Fresh JAR lacks required probe classes: " + ", ".join(missing))
        for name, expected in REQUIRED_JAR_RESOURCES.items():
            if name not in names or hashlib.sha256(archive.read(name)).hexdigest() != expected:
                raise ValueError("Fresh JAR lacks the locked original fixture resource: " + name)
        maximum = 0
        base_maximum = 0
        for item in entries:
            if item.filename.endswith(".class"):
                with archive.open(item) as stream:
                    header = stream.read(8)
                if len(header) != 8 or header[:4] != b"\xca\xfe\xba\xbe":
                    raise ValueError("Malformed class header in fresh JAR")
                minor, major = struct.unpack(">HH", header[4:])
                if minor == 65535:
                    raise ValueError("Preview bytecode is not allowed in the probe payload")
                maximum = max(maximum, major)
                if not item.filename.startswith("META-INF/versions/"):
                    base_maximum = max(base_maximum, major)
    return {"sha256": sha256(jar), "bytes": jar.stat().st_size,
            "maximumClassMajor": maximum, "maximumBaseClassMajor": base_maximum,
            "requiredClasses": list(REQUIRED_JAR_CLASSES), "requiredResources": REQUIRED_JAR_RESOURCES}


def record_jvm():
    current = current_checkout()
    manifest = replay.safe_path(REPO / JVM_MANIFEST)
    if manifest.exists():
        raise ValueError("Refusing to overwrite an existing fresh-JVM record")
    record = {"schemaVersion": 1, "recordedAt": replay.utc_now(),
              "repository": os.environ.get("GITHUB_REPOSITORY"), "runID": current_run_id(),
              "runAttempt": os.environ.get("GITHUB_RUN_ATTEMPT"), "sourceSHA": current,
              "workflowPath": CURRENT_WORKFLOW,
              "workflowBlob": replay.git("rev-parse", f"{current}:{CURRENT_WORKFLOW}"),
              "inputs": jvm_inputs(current), "includeEngineTests": True,
              "completedGradleTasks": REQUIRED_GRADLE_TASKS,
              "jar": jar_details(replay.safe_path(REPO / JAR_PATH)),
              "deviceValidationPassed": False}
    manifest.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    return record


def prepare(record):
    current = current_checkout()
    api = replay.GitHub(os.environ.get("GITHUB_REPOSITORY", ""), os.environ.get("GITHUB_TOKEN", ""))
    replay.fetch_source(BASELINE_SHA, api.token)
    record.update({"repository": api.repository, "currentSHA": current, "currentRunID": current_run_id(),
                   "native": native_source(api), "nativeInputChecks": source_inputs(current),
                   "jvmInputs": jvm_inputs(current), "freshJVMArtifact": fresh_artifact(api, current),
                   "status": "prepared"})
    if os.environ.get("GITHUB_OUTPUT"):
        with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as stream:
            stream.write(f"jvm_artifact_id={record['freshJVMArtifact']['id']}\n")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, new_url):
        return None


def download_url_response(api):
    # Follow GitHub's signed storage redirect ourselves so Authorization never
    # follows a cross-origin redirect. Neither signed URLs nor headers are logged.
    opener = urllib.request.build_opener(NoRedirect())
    request = urllib.request.Request(
        f"https://api.github.com/repos/{api.repository}/actions/artifacts/{BASELINE_ARTIFACT}/zip",
        headers={"Authorization": "Bearer " + api.token, "Accept": "application/vnd.github+json",
                 "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "legado-native-reuse"})
    try:
        return opener.open(request, timeout=60)
    except urllib.error.HTTPError as error:
        if error.code not in (301, 302, 303, 307, 308):
            raise RuntimeError(f"Native artifact download returned HTTP {error.code}") from None
        location = error.headers.get("Location", "")
    parsed = urllib.parse.urlsplit(location)
    hostname = parsed.hostname or ""
    allowed = (re.fullmatch(r"[a-z0-9-]+\.blob\.core\.windows\.net", hostname) is not None
               or hostname.endswith(".actions.githubusercontent.com"))
    if parsed.scheme != "https" or parsed.username or parsed.password or parsed.port not in (None, 443) or parsed.fragment or not allowed:
        raise ValueError("Native artifact redirect is not an approved HTTPS Actions storage host")
    return opener.open(urllib.request.Request(location, headers={"User-Agent": "legado-native-reuse"}), timeout=60)


def download_native(api, destination):
    destination = replay.safe_path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        with download_url_response(api) as response, destination.open("xb") as stream:
            started, count, digest = time.monotonic(), 0, hashlib.sha256()
            while True:
                block = response.read(1024 * 1024)
                if not block:
                    break
                count += len(block)
                if count > BASELINE_BYTES or time.monotonic() - started > 600:
                    raise ValueError("Native artifact download exceeded its pinned size or time budget")
                stream.write(block)
                digest.update(block)
    except (urllib.error.URLError, TimeoutError) as error:
        raise RuntimeError("Native artifact download failed: " + type(error).__name__) from None
    if count != BASELINE_BYTES or digest.hexdigest() != BASELINE_DIGEST:
        raise ValueError("Downloaded native ZIP bytes or SHA256 differ from the audited artifact")


def entry_path(name):
    if not name or "\\" in name or "\x00" in name or ":" in name:
        raise ValueError("Unsafe native ZIP path")
    value = name[:-1] if name.endswith("/") else name
    parts = value.split("/")
    if any(part in ("", ".", "..") for part in parts) or PurePosixPath(value).is_absolute():
        raise ValueError("Unsafe native ZIP path")
    return value


def allowed_entry(name, directory):
    if name == LOCK:
        return not directory
    if any(name == root or name.startswith(root + "/") for root in ROOTS):
        return True
    return directory and any(root.startswith(name + "/") for root in (*ROOTS, LOCK))


def extract_native(archive_path, destination):
    destination = replay.safe_path(destination)
    if destination.exists():
        raise ValueError("Refusing to overwrite an existing native extraction directory")
    with zipfile.ZipFile(archive_path) as archive:
        entries = archive.infolist()
        if len(entries) > MAX_ENTRIES:
            raise ValueError("Native ZIP contains too many entries")
        seen, total, checked = set(), 0, []
        for item in entries:
            name = entry_path(item.filename)
            if name.casefold() in seen:
                raise ValueError("Duplicate or case-colliding native ZIP path")
            seen.add(name.casefold())
            mode = stat.S_IFMT(item.external_attr >> 16)
            if mode not in (0, stat.S_IFDIR if item.is_dir() else stat.S_IFREG):
                raise ValueError("Native ZIP contains a symlink or special entry")
            if item.flag_bits & 1 or not allowed_entry(name, item.is_dir()):
                raise ValueError("Native ZIP entry is outside the permitted runtime roots")
            total += item.file_size
            if item.file_size > MAX_ENTRY_BYTES or total > MAX_EXPANDED_BYTES:
                raise ValueError("Native ZIP exceeds its extraction size limit")
            checked.append((item, name))
        # Validate the entire inventory before creating any extraction path.
        destination.mkdir(parents=True)
        for item, name in checked:
            target = replay.safe_path(destination / name)
            if item.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(item) as source, target.open("xb") as output:
                    shutil.copyfileobj(source, output, length=1024 * 1024)
    replay.safe_tree(destination)


def native_inventory(root):
    files = []
    for path in sorted(root.rglob("*")):
        if path.is_file():
            files.append({"path": path.relative_to(root).as_posix(), "bytes": path.stat().st_size,
                          "sha256": sha256(path)})
    return {"schemaVersion": 1, "origin": "consumer-verified", "files": files}


def native_bytecode_compatibility(home, maximum_base_major):
    # The historical build-6 exploded JavaHome had no release file.
    # build-zero.sh copies this optional image metadata only when it exists.
    # Its own java.base bytecode supplies a conservative compatibility ceiling;
    # this is not a measurement of the running VM's java.version property.
    relative = "modules/java.base/java/lang/Object.class"
    with (home / relative).open("rb") as stream:
        header = stream.read(8)
    if len(header) != 8 or header[:4] != b"\xca\xfe\xba\xbe":
        raise ValueError("Malformed native Object.class header")
    minor, major = struct.unpack(">HH", header[4:])
    if major < 45:
        raise ValueError("Invalid native Object.class major version")
    if minor == 65535:
        raise ValueError("Preview native Object.class bytecode is not allowed")
    if (major == 45 and minor > 3) or (major > 45 and minor != 0):
        raise ValueError("Invalid native Object.class minor version")
    result = {"source": relative, "nativeClassMajor": major, "nativeClassMinor": minor,
              "freshJarMaximumBaseClassMajor": maximum_base_major,
              "runtimeJavaVersionMeasured": False}
    release_path = home / "release"
    if release_path.exists():
        release = release_path.read_text(encoding="utf-8")
        declarations = [line for line in release.splitlines() if re.match(r"^\s*JAVA_VERSION\b", line)]
        match = re.fullmatch(
            r'JAVA_VERSION="(([1-9][0-9]*)(?:\.[0-9]+)*(?:-[A-Za-z0-9]+)?'
            r'(?:\+[0-9]+(?:-[A-Za-z0-9.-]+)?)?)"', declarations[0]
        ) if len(declarations) == 1 else None
        if match is None:
            raise ValueError("Native Java release does not declare one valid JAVA_VERSION")
        feature = int(match.group(2))
        if feature + 44 != major:
            raise ValueError("Native Java release and Object.class major version disagree")
        result["releaseDeclaration"] = {"source": "release", "javaVersion": match.group(1),
                                        "javaFeature": feature}
    if maximum_base_major > major:
        raise ValueError("Fresh JAR base bytecode exceeds the native Object.class compatibility ceiling")
    return result


def validate_layout(native, jar):
    artifact_lock = native / LOCK
    if artifact_lock.read_bytes() != (REPO / LOCK).read_bytes():
        raise ValueError("Native artifact lock differs from the current checkout")
    framework = native / FRAMEWORK
    with (framework / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    for item in info.get("AvailableLibraries", []):
        for key in ("LibraryIdentifier", "LibraryPath", "HeadersPath"):
            value = item.get(key, "Headers" if key == "HeadersPath" else "")
            entry_path(value)
    required = set(json.loads(artifact_lock.read_text(encoding="utf-8"))["requiredModules"])
    maximum_base_major = jar_details(jar)["maximumBaseClassMajor"]
    validation = {}
    for platform, relative in HOMES.items():
        home = native / relative
        actual = {path.name for path in (home / "modules").iterdir() if path.is_dir()}
        if actual != required:
            raise ValueError("Native module inventory differs from the pinned required modules")
        validation[platform] = verifier.validate(home, jar, framework)
        # Check only bytecode eligible on this VM; higher multi-release entries
        # are not loaded. Base classes must all fit the reused Java runtime.
        validation[platform]["bytecodeCompatibility"] = native_bytecode_compatibility(home, maximum_base_major)
    return validation


def verify_fresh_jvm(record):
    jar = replay.safe_path(REPO / JAR_PATH)
    manifest_path = replay.safe_path(REPO / JVM_MANIFEST)
    for path in (jar, manifest_path):
        replay.safe_tree(path)
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if (manifest.get("schemaVersion") != 1 or manifest.get("sourceSHA") != record["currentSHA"]
            or manifest.get("repository") != record["repository"]
            or manifest.get("runID") != record["currentRunID"]
            or manifest.get("workflowPath") != CURRENT_WORKFLOW
            or manifest.get("workflowBlob") != replay.git("rev-parse", f"{record['currentSHA']}:{CURRENT_WORKFLOW}")
            or manifest.get("inputs") != record["jvmInputs"]
            or manifest.get("includeEngineTests") is not True
            or manifest.get("completedGradleTasks") != REQUIRED_GRADLE_TASKS):
        raise ValueError("Fresh JVM provenance does not match this run and its current source inputs")
    details = jar_details(jar)
    if details != manifest.get("jar"):
        raise ValueError("Fresh JVM JAR hash, size or required classes differ from its producer record")
    return {"artifact": record["freshJVMArtifact"], "producer": manifest,
            "manifestSHA256": sha256(manifest_path)}


def restore(record):
    current = current_checkout()
    if record.get("status") != "prepared" or record.get("currentSHA") != current or record.get("currentRunID") != current_run_id():
        raise ValueError("Successful preparation for this checkout and workflow run is required")
    api = replay.GitHub(os.environ.get("GITHUB_REPOSITORY", ""), os.environ.get("GITHUB_TOKEN", ""))
    if record.get("repository") != api.repository or native_source(api) != record.get("native"):
        raise ValueError("Native artifact provenance changed after preparation")
    if (source_inputs(current) != record.get("nativeInputChecks")
            or jvm_inputs(current) != record.get("jvmInputs")
            or fresh_artifact(api, current) != record.get("freshJVMArtifact")):
        raise ValueError("Build inputs or fresh artifact changed after preparation")
    record["jvm"] = verify_fresh_jvm(record)
    destinations = [(path, replay.safe_path(REPO / path)) for path in ROOTS]
    if any(destination.exists() for _, destination in destinations):
        raise ValueError("Refusing to overwrite an existing native runtime product")
    work = replay.safe_path(REPO / ".build/native-reuse")
    archive = work / "native.zip"
    download_native(api, archive)
    record["nativeZIPVerification"] = {"sha256": sha256(archive), "bytes": archive.stat().st_size,
                                       "matchesAuditedPin": True}
    native = work / "extracted"
    extract_native(archive, native)
    record["validation"] = validate_layout(native, REPO / JAR_PATH)
    inventory = native_inventory(native)
    inventory_path = replay.safe_path(REPO / ".build/ci-logs/native-reuse-files.json")
    inventory_path.write_text(json.dumps(inventory, separators=(",", ":")) + "\n", encoding="utf-8")
    record["nativeInventory"] = {"origin": "consumer-verified", "path": inventory_path.relative_to(REPO).as_posix(),
                                 "sha256": sha256(inventory_path), "files": len(inventory["files"]),
                                 "bytes": sum(item["bytes"] for item in inventory["files"])}
    for relative, destination in destinations:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(native / relative, destination)
    # SwiftPM's conditional binary-target manifest must see the new artifact.
    (REPO / "Packages/LegadoRuntime/Package.swift").touch()
    record.update({"status": "restored", "restoredAt": replay.utc_now(), "nativeRuntimeRecompiled": False,
                   "jvmPayloadRecompiled": True, "currentAppCompilationRequired": True,
                   "runtimeExecutionVerified": False, "deviceValidationPassed": False})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("validate-tag", "record-jvm", "prepare", "restore"))
    args = parser.parse_args()
    if args.phase == "validate-tag":
        try:
            print(json.dumps({"sourceSHA": current_checkout()}), flush=True)
            return 0
        except Exception as error:
            print(f"{type(error).__name__}: {error}", file=sys.stderr)
            return 1
    if args.phase == "record-jvm":
        try:
            print(json.dumps(record_jvm(), indent=2), flush=True)
            return 0
        except Exception as error:
            print(f"{type(error).__name__}: {error}", file=sys.stderr)
            return 1
    report = replay.safe_path(REPO / ".build/ci-logs/native-reuse.json")
    report.parent.mkdir(parents=True, exist_ok=True)
    if args.phase == "prepare" and report.exists():
        print("Refusing to overwrite an existing native preparation record", file=sys.stderr)
        return 1
    record = {"schemaVersion": 1, "mode": "fresh-jvm-reused-native", "startedAt": replay.utc_now(),
              "status": "failed", "nativeRuntimeRecompiled": False, "jvmPayloadRecompiled": False,
              "currentAppCompilationRequired": True, "deviceValidationPassed": False}
    try:
        if args.phase == "prepare":
            prepare(record)
        else:
            record = json.loads(report.read_text(encoding="utf-8"))
            if record.get("mode") != "fresh-jvm-reused-native":
                raise ValueError("Unexpected native reuse protocol")
            restore(record)
    except (Exception, KeyboardInterrupt) as error:
        record.update({"status": "failed", "failure": f"{type(error).__name__}: {error}"})
        print(record["failure"], file=sys.stderr, flush=True)
    finally:
        record["recordedAt"] = replay.utc_now()
        report.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(record, indent=2), flush=True)
    return 0 if record["status"] in ("prepared", "restored") else 1


if __name__ == "__main__":
    sys.exit(main())
