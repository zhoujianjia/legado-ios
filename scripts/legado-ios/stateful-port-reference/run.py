#!/usr/bin/env python3
"""Replay one fixed Android stateful corpus through an explicitly pinned ordinary JVM JAR."""
import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import zipfile

if sys.flags.optimize:
    print("ValueError: Optimized Python disables required input assertions; use Python without -O/PYTHONOPTIMIZE", file=sys.stderr)
    sys.exit(1)

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
HARNESS = ROOT / "tools/legado-reference/androidTest/TraditionalStatefulGoldenTest.kt"
FIXTURE = ROOT / "Packages/LegadoRuntime/jvm/src/test/resources/fixtures/traditional-stateful-cases.json"
REFERENCE = ROOT / "docs/legado-ios/fixtures/android-traditional-stateful-golden.json"
PROVENANCE = "META-INF/legado-provenance/original-rule/manifest.json"
ARCHIVE_SHA = "724dedcac2427cd1f02ca00af1eab7156146e6d9d3141ca4c92042d04ed7bcdd"
PINS = {
    HARNESS: "87209b3b5381171bbdd09eb9bba36e83fe52b9e56d430e3bb93d419388c31b33",
    FIXTURE: "a7e0b23bc73c1a32c6d99466aebad25eee8e3c227e12e4d98efccb53d0008ddf",
    REFERENCE: "339802f01476cc61a004617bc8d14996c3eb0140fbdb1ea73ee05d56be6cdf38",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def file_record(path):
    return {"bytes": path.stat().st_size, "sha256": sha(path.read_bytes())}


def git_bytes(commit, path):
    require(not path.startswith("/") and ".." not in Path(path).parts, "Unsafe provenance source path")
    result = subprocess.run(["git", "-C", str(ROOT), "show", f"{commit}:{path}"], capture_output=True, timeout=30)
    require(result.returncode == 0, f"Cannot read committed provenance source: {path}")
    return result.stdout


def validate_jar(path, expected_sha, source_commit):
    require(re.fullmatch(r"[0-9a-f]{64}", expected_sha), "Expected JAR SHA256 must be lowercase hexadecimal")
    require(path.is_file() and sha(path.read_bytes()) == expected_sha, "Runtime JAR identity differs")
    resolved = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--verify", source_commit + "^{commit}"],
                              capture_output=True, text=True, timeout=30)
    require(resolved.returncode == 0, "Runtime source commit does not exist")
    commit = resolved.stdout.strip()
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)), "Runtime JAR has duplicate entry names")
        require(all(not x.startswith(("/", "\\")) and ".." not in x.replace("\\", "/").split("/") for x in names),
                "Runtime JAR contains unsafe entry names")
        forbidden = [x for x in names if x.startswith(("org/junit/", "junit/", "org/hamcrest/", "fixtures/"))
                     or "tls-fixture-v1/" in x
                     or (x.startswith(("io/yuedu/legado/", "io/legado/app/"))
                         and re.search(r"Test(?:\$[^/]*)?\.class$", x))]
        require(not forbidden, "Expected ordinary JAR; test classes/fixtures are present")
        raw = archive.read(PROVENANCE)
        manifest = json.loads(raw)
        require(manifest.get("originalArchiveSHA256") == ARCHIVE_SHA, "Original archive provenance differs")
        require(raw == git_bytes(commit, "Packages/LegadoRuntime/vendor/original-rule/manifest.json"),
                "Embedded original-rule manifest differs from the declared source commit")
        sources = manifest["portedSources"]
        require(sources and len({x["path"] for x in sources}) == len(sources), "Missing/duplicate ported source provenance")
        for item in sources:
            data = git_bytes(commit, item["path"])
            require(len(data) == item["bytes"] and sha(data) == item["sha256"],
                    "Ported source bytes differ: " + item["path"])
        classes = manifest["requiredRuntimeClasses"]
        require(classes and len({x["path"] for x in classes}) == len(classes), "Missing/duplicate runtime class provenance")
        class_records = {}
        for item in classes:
            name = item["path"]
            require(name.endswith(".class") and not name.startswith("META-INF/"), "Invalid runtime class name")
            data = archive.read(name)
            class_records[name[:-6].replace("/", ".")] = {"bytes": len(data), "sha256": sha(data)}
        for name in ("com.script.rhino.RhinoScriptEngine", "org.htmlunit.corejs.javascript.Context"):
            data = archive.read(name.replace(".", "/") + ".class")
            class_records[name] = {"bytes": len(data), "sha256": sha(data)}
        for item in manifest["runtimeResources"]:
            data = archive.read(item["path"])
            require(len(data) == item["bytes"] and sha(data) == item["sha256"], "Runtime resource provenance differs")
        for item in manifest["licenseFiles"]:
            name = "META-INF/licenses/original-rule/" + Path(item["path"]).name
            data = archive.read(name)
            require(len(data) == item["bytes"] and sha(data) == item["sha256"], "Runtime license provenance differs")
    return {"sourceCommit": commit, "jar": file_record(path), "embeddedProvenance": {"entry": PROVENANCE,
            "bytes": len(raw), "sha256": sha(raw)}, "portedSourceFilesVerified": len(sources),
            "ordinaryTestAndFixtureExclusionPassed": True, "classBytes": class_records}


def adapt_harness(source, patch):
    """Apply only this pinned harness's reviewed single-file unified diff."""
    original = source.splitlines(keepends=True)
    lines = patch.splitlines(keepends=True)
    require(lines[:2] == ["--- original-Android-harness\n", "+++ frozen-port-harness\n"], "Unexpected harness patch header")
    output, cursor, index = [], 0, 2
    while index < len(lines):
        match = re.fullmatch(r"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@.*\n", lines[index])
        require(match is not None, "Unexpected harness patch hunk")
        start = int(match[1]) - 1
        require(cursor <= start <= len(original), "Overlapping harness patch hunks")
        output.extend(original[cursor:start]); cursor = start; index += 1
        removed = added = 0
        while index < len(lines) and not lines[index].startswith("@@ "):
            line = lines[index]; prefix = line[:1]; value = line[1:]
            require(prefix in (" ", "+", "-"), "Unexpected harness patch instruction")
            if prefix in (" ", "-"):
                require(cursor < len(original) and original[cursor] == value, "Harness patch context differs")
                cursor += 1; removed += 1
            if prefix in (" ", "+"):
                output.append(value); added += 1
            index += 1
        require(removed == int(match[2] or 1) and added == int(match[4] or 1), "Harness patch hunk counts differ")
    output.extend(original[cursor:])
    adapted = "".join(output)
    actual = "".join(difflib.unified_diff(source.splitlines(keepends=True), adapted.splitlines(keepends=True),
                    fromfile="original-Android-harness", tofile="frozen-port-harness"))
    require(actual == patch, "Harness patch did not reproduce its reviewed diff")
    return adapted


CLASS_ORIGINS = r"""import com.google.gson.GsonBuilder;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;
public class RuntimeClassOrigins {
    public static void main(String[] args) throws Exception {
        Path expected = Path.of(args[0]).toRealPath();
        Map<String, Object> result = new LinkedHashMap<>();
        for (int i = 2; i < args.length; i++) {
            Class<?> value = Class.forName(args[i], false, RuntimeClassOrigins.class.getClassLoader());
            Path origin = Path.of(value.getProtectionDomain().getCodeSource().getLocation().toURI()).toRealPath();
            if (!origin.equals(expected)) throw new IllegalStateException("Runtime class did not load from the input JAR");
            byte[] bytes;
            try (var stream = value.getResourceAsStream("/" + args[i].replace('.', '/') + ".class")) {
                if (stream == null) throw new IllegalStateException("Runtime class bytes unavailable");
                bytes = stream.readAllBytes();
            }
            result.put(args[i], Map.of("loadedFromInputJar", true, "bytes", bytes.length,
                "sha256", HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes))));
        }
        Files.writeString(Path.of(args[1]), new GsonBuilder().setPrettyPrinting().create().toJson(result) + "\n");
    }
}
"""


def invoke(command, cwd, env, log, timeout):
    with log.open("xb") as stream:
        result = subprocess.run(command, cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
    require(result.returncode == 0, f"Command failed ({result.returncode}); inspect {log.name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime-jar", required=True, type=Path)
    parser.add_argument("--runtime-jar-sha256", required=True)
    parser.add_argument("--runtime-source-commit", required=True)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--gradle", default="gradle", help="Gradle 8.14.3 executable")
    parser.add_argument("--java-home", type=Path, default=os.environ.get("JAVA_HOME"))
    parser.add_argument("--offline", action="store_true", help="Require already-cached Kotlin build dependencies")
    args = parser.parse_args()
    output = args.output_dir.absolute()
    require(not output.exists(), "Output directory already exists; refusing to overwrite evidence")
    base = (ROOT / ".build").resolve()
    require(output.resolve().is_relative_to(base) and output.resolve() != base, "Output must be a fresh descendant of repository .build")
    require(all(not x.is_symlink() for x in [output, *output.parents] if x != x.parent), "Output ancestors must not be symbolic links")
    for path, expected in PINS.items():
        require(sha(path.read_bytes()) == expected, "Pinned reference input differs: " + str(path.relative_to(ROOT)))
    runtime = args.runtime_jar.resolve(strict=True)
    validated = validate_jar(runtime, args.runtime_jar_sha256, args.runtime_source_commit)
    require(args.java_home is not None, "Set JAVA_HOME or pass --java-home for JDK 21")
    java_home = args.java_home.resolve(strict=True)
    java = java_home / "bin" / ("java.exe" if os.name == "nt" else "java")
    version = subprocess.run([str(java), "-version"], capture_output=True, timeout=15)
    version_text = (version.stdout + version.stderr).decode("utf-8")
    require(version.returncode == 0 and re.search(r'version "21(?:\.|\")', version_text), "This bounded replay requires JDK 21")
    gradle = shutil.which(args.gradle)
    require(gradle is not None, "Gradle executable not found")
    gradle = str(Path(gradle).resolve(strict=True))
    source = HARNESS.read_text(encoding="utf-8")
    patch = (HERE / "harness-adaptations.patch").read_text(encoding="utf-8")
    adapted = adapt_harness(source, patch)
    reference = json.loads(REFERENCE.read_text(encoding="utf-8"))
    output.mkdir(parents=True, exist_ok=False)
    execution = {"schemaVersion": 1, "startedAtEpochSeconds": time.time(), "status": "running", "commands": [],
                 "javaVersion": version_text, "javaExecutable": file_record(java), "runtimeValidation": validated,
                 "toolFiles": {p.name: file_record(p) for p in sorted(HERE.iterdir()) if p.is_file()},
                 "mainProjectGradleTasksInvoked": [], "productSourcesOrTestsModified": False}
    try:
        kotlin_file = output / "src/main/kotlin/io/legado/app/reference/TraditionalStatefulGoldenTest.kt"
        kotlin_file.parent.mkdir(parents=True)
        kotlin_file.write_text(adapted, encoding="utf-8", newline="\n")
        helper = output / "src/main/java/RuntimeClassOrigins.java"
        helper.parent.mkdir(parents=True)
        helper.write_text(CLASS_ORIGINS, encoding="utf-8", newline="\n")
        (output / "harness-adaptations.diff").write_text(patch, encoding="utf-8", newline="\n")
        (output / "settings.gradle.kts").write_text('rootProject.name = "stateful-port-measurement"\n', encoding="utf-8")
        (output / "build.gradle.kts").write_text('plugins { kotlin("jvm") version "2.4.20"; application }\nrepositories { mavenCentral() }\ndependencies { implementation(files(providers.gradleProperty("measurementRuntimeJar").get())) }\nkotlin { jvmToolchain(21) }\n', encoding="utf-8")
        prep = {"schemaVersion": 1, "inputPins": {str(p.relative_to(ROOT)): file_record(p) for p in PINS},
                "runtimeValidation": validated, "referenceRunId": reference["referenceRunId"],
                "runtimeClasspath": ["build/classes/kotlin/main", "build/classes/java/main", str(runtime)],
                "generatedHarness": file_record(kotlin_file), "reviewedHarnessAdaptations": file_record(HERE / "harness-adaptations.patch"),
                "originalRulesOrOrderedCallsChanged": False, "explicitPortEnvironmentInjection": True,
                "iosValidationPassed": False, "deviceValidationPassed": False, "compatibilityValidationPassed": False}
        (output / "measurement-preparation.json").write_text(json.dumps(prep, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        env = os.environ.copy(); env["JAVA_HOME"] = str(java_home)
        compile_command = [gradle, "--no-daemon", "--console=plain", "--project-cache-dir", str(output / ".gradle"),
                           "--project-dir", str(output), "-PmeasurementRuntimeJar=" + str(runtime), "classes"]
        if args.offline:
            compile_command.insert(1, "--offline")
        execution["commands"].append(compile_command)
        invoke(compile_command, output, env, output / "compile.log", 300)
        cp = os.pathsep.join(str(p) for p in (output / "build/classes/kotlin/main", output / "build/classes/java/main", runtime))
        origins_command = [str(java), "-cp", cp, "RuntimeClassOrigins", str(runtime), str(output / "class-origins.json"), *validated["classBytes"]]
        execution["commands"].append(origins_command)
        invoke(origins_command, output, env, output / "class-origins.log", 30)
        origins = json.loads((output / "class-origins.json").read_text(encoding="utf-8"))
        require(set(origins) == set(validated["classBytes"]), "Runtime class origin set differs")
        require(all(origins[n] == {**v, "loadedFromInputJar": True} for n, v in validated["classBytes"].items()), "Runtime class origin/byte hashes differ")
        command = [str(java), "-Xmx512m", "-cp", cp, "io.legado.app.reference.TraditionalStatefulGoldenTest",
                   reference["referenceRunId"], str(FIXTURE), str(output / "port-observed.json"), args.runtime_jar_sha256]
        execution["commands"].append(command)
        invoke(command, output, env, output / "run.log", 60)
        execution["status"] = "observation-complete-pending-raw-comparison"
    except Exception as error:
        execution["status"] = "failed"
        execution["failure"] = type(error).__name__ + ": " + str(error)
        raise
    finally:
        execution["finishedAtEpochSeconds"] = time.time()
        (output / "execution-environment.json").write_text(json.dumps(execution, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    # Exact mismatches remain in the comparison; observation success never implies compatibility.
    subprocess.run([sys.executable, str(HERE / "compare.py"), "--runtime-jar", str(runtime),
                    "--runtime-jar-sha256", args.runtime_jar_sha256, "--output-dir", str(output)], check=True, timeout=30)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError, KeyError, zipfile.BadZipFile) as error:
        print(type(error).__name__ + ": " + str(error), file=sys.stderr)
        sys.exit(1)
