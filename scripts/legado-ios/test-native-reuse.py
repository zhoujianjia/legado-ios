#!/usr/bin/env python3
"""Offline regressions for the separate fresh-JVM/native-reuse protocol."""
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import shutil
import stat
import struct
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
import zipfile


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("native_reuse_tests", HERE / "verify-native-reuse.py")
reuse = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reuse)
CURRENT = "a" * 40


def artifact(name=reuse.NATIVE_NAME, run=reuse.BASELINE_RUN, source=reuse.BASELINE_SHA):
    return {"id": reuse.BASELINE_ARTIFACT, "name": name, "size_in_bytes": reuse.BASELINE_BYTES,
            "digest": "sha256:" + reuse.BASELINE_DIGEST, "expired": False,
            "expires_at": "2100-01-01T00:00:00Z", "workflow_run": {"id": run, "head_sha": source}}


class FakeAPI:
    repository = "owner/repository"
    token = "not-a-real-token"

    def __init__(self):
        self.state = {"head_sha": reuse.BASELINE_SHA, "path": reuse.SOURCE_WORKFLOW,
                      "name": "Legado iOS Prototype", "status": "completed", "conclusion": "success",
                      "run_attempt": 1, "html_url": "https://github.com/owner/repository/actions/runs/1"}
        self.inventory = [artifact()]

    def run(self, run_id):
        return self.state

    def artifacts(self, run_id):
        return self.inventory


class NativeIdentityTests(unittest.TestCase):
    def test_tag_requires_this_protocol_and_exact_sha7(self):
        reuse.validate_tag("legado-core-" + CURRENT[:7], CURRENT)
        for tag in ("legado-core-bbbbbbb", "legado-replay-1-aaaaaaa", "legado-core-aaaaaaaa"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                reuse.validate_tag(tag, CURRENT)

    def test_only_native_inputs_are_compared_jvm_may_change(self):
        def git(*args):
            if args[0] == "status":
                self.assertNotIn(reuse.replay.JVM_TREE, args)
                return ""
            if args[1] == reuse.BASELINE_SHA + ":" + reuse.SOURCE_WORKFLOW:
                return reuse.SOURCE_WORKFLOW_BLOB
            self.assertIn(args[1].split(":", 1)[1], reuse.replay.NATIVE_INPUTS)
            return "b" * 40
        with patch.object(reuse.replay, "git", side_effect=git):
            result = reuse.source_inputs(CURRENT)
        self.assertEqual(len(result), 7)
        self.assertIn("scripts/legado-ios/prepare-zero-signal-context.py", reuse.replay.NATIVE_INPUTS)
        self.assertTrue(all(item["matches"] for item in result))

    def test_every_native_input_change_blocks_reuse(self):
        for changed in reuse.replay.NATIVE_INPUTS:
            def git(*args):
                if args[0] == "status":
                    return ""
                return "c" * 40 if args[1] == CURRENT + ":" + changed else "b" * 40
            with self.subTest(path=changed), patch.object(reuse.replay, "git", side_effect=git):
                with self.assertRaisesRegex(ValueError, "fresh native build"):
                    reuse.source_inputs(CURRENT)

    def test_new_required_input_missing_from_producer_requires_fresh_build(self):
        def git(*args):
            if args[0] == "status":
                return ""
            if args[1] == reuse.BASELINE_SHA + ":scripts/legado-ios/prepare-zero-signal-context.py":
                raise RuntimeError("git object does not exist")
            return "b" * 40
        with patch.object(reuse.replay, "git", side_effect=git):
            with self.assertRaisesRegex(ValueError, "required build input; a fresh native build"):
                reuse.source_inputs(CURRENT)

    def test_dirty_native_inputs_and_wrong_workflow_blob_rejected(self):
        with patch.object(reuse.replay, "git", return_value="dirty"):
            with self.assertRaisesRegex(ValueError, "uncommitted"):
                reuse.source_inputs(CURRENT)
        with patch.object(reuse.replay, "git", side_effect=lambda *a: "" if a[0] == "status" else "b" * 40):
            with self.assertRaisesRegex(ValueError, "workflow blob"):
                reuse.source_inputs(CURRENT)

    def test_successful_fixed_producer_and_artifact(self):
        self.assertEqual((reuse.BASELINE_RUN, reuse.BASELINE_SHA, reuse.BASELINE_ARTIFACT,
                          reuse.BASELINE_BYTES, reuse.BASELINE_DIGEST, reuse.SOURCE_WORKFLOW_BLOB),
                         (39083752761, "ce792982a30942e605fc935b733c5b41bef2736a", 12120530642,
                          89898489, "6d91463d6e28a1bcc6c1d5ba79ad88f5a8d1ba79d0e2e11e78b5fbd5520346ac",
                          "acc22e4f49b24200f75f85b679564b4e8867d28c"))
        self.assertEqual(reuse.native_source(FakeAPI())["artifact"]["id"], reuse.BASELINE_ARTIFACT)

    def test_wrong_source_workflow_or_failed_producer_rejected(self):
        for key, value in (("head_sha", CURRENT), ("path", "untrusted.yml"), ("name", "Other"),
                           ("status", "in_progress"), ("conclusion", "failure")):
            api = FakeAPI()
            api.state[key] = value
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "pinned native producer"):
                reuse.native_source(api)

    def test_wrong_pinned_artifact_id_digest_or_size_rejected(self):
        for key, value in (("id", 1), ("size_in_bytes", 1), ("digest", "sha256:" + "0" * 64)):
            api = FakeAPI()
            api.inventory[0][key] = value
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "audited native producer"):
                reuse.native_source(api)

    def test_duplicate_expired_missing_digest_or_foreign_artifact_rejected(self):
        for mutate in (lambda a: a.append(copy.deepcopy(a[0])), lambda a: a[0].update(expired=True),
                       lambda a: a[0].update(digest=None), lambda a: a[0]["workflow_run"].update(id=1),
                       lambda a: a[0]["workflow_run"].update(head_sha=CURRENT),
                       lambda a: a[0].update(expires_at="2000-01-01T00:00:00Z")):
            api = FakeAPI()
            mutate(api.inventory)
            with self.subTest(inventory=api.inventory), self.assertRaises(ValueError):
                reuse.native_source(api)

    def test_jvm_vendor_maven_and_notice_inputs_are_in_provenance(self):
        with patch.object(reuse.replay, "git", side_effect=lambda *a: "" if a[0] == "status" else "b" * 40):
            inputs = reuse.jvm_inputs(CURRENT)
        self.assertIn("Packages/LegadoRuntime/vendor/maven", [item["path"] for item in inputs])
        self.assertIn("Packages/LegadoRuntime/vendor/manifest.json", [item["path"] for item in inputs])

    def test_fresh_artifact_requires_current_run_and_workflow_identity(self):
        api = FakeAPI()
        api.state.update(head_sha=CURRENT, path=reuse.CURRENT_WORKFLOW)
        api.inventory = [artifact(name=reuse.JVM_NAME, run=123, source=CURRENT)]
        with patch.object(reuse, "current_run_id", return_value=123):
            self.assertEqual(reuse.fresh_artifact(api, CURRENT)["name"], reuse.JVM_NAME)
            api.inventory[0]["workflow_run"]["id"] = reuse.BASELINE_RUN
            with self.assertRaisesRegex(ValueError, "another run"):
                reuse.fresh_artifact(api, CURRENT)
            api.state["path"] = reuse.SOURCE_WORKFLOW
            with self.assertRaisesRegex(ValueError, "this core-update run"):
                reuse.fresh_artifact(api, CURRENT)


class NativeFilesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.patchers = [patch.object(reuse, "REPO", self.root), patch.object(reuse.replay, "REPO", self.root)]
        for patcher in self.patchers:
            patcher.start()
            self.addCleanup(patcher.stop)

    def write(self, relative, data=b"fixture"):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def zip(self, entries):
        archive = self.root / "test.zip"
        with zipfile.ZipFile(archive, "w") as output:
            for name, data in entries:
                output.writestr(name, data)
        return archive

    def jar(self, version=65, omit=(), minor=0):
        jar = self.root / reuse.JAR_PATH
        jar.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(jar, "w") as output:
            for name in reuse.REQUIRED_JAR_CLASSES:
                if name not in omit:
                    output.writestr(name, b"\xca\xfe\xba\xbe" + struct.pack(">HH", minor, version) + b"fixture")
            for name in reuse.REQUIRED_JAR_RESOURCES:
                if name not in omit:
                    output.writestr(name, (HERE.parents[1] / "Packages/LegadoRuntime/jvm/src/test/resources" / name).read_bytes())
        return jar

    def test_original_fixture_resource_missing_or_changed_is_rejected(self):
        resource = next(iter(reuse.REQUIRED_JAR_RESOURCES))
        jar = self.jar(omit=(resource,))
        with self.assertRaisesRegex(ValueError, "locked original fixture resource"):
            reuse.jar_details(jar)
        jar = self.jar()
        with zipfile.ZipFile(jar) as archive:
            contents = [(item.filename, archive.read(item)) for item in archive.infolist()]
        with zipfile.ZipFile(jar, "w") as archive:
            for name, raw in contents:
                archive.writestr(name, raw + b"unreviewed change" if name == resource else raw)
        with self.assertRaisesRegex(ValueError, "locked original fixture resource"):
            reuse.jar_details(jar)

    def native(self, release=None):
        native = self.root / "source"
        native.mkdir()
        lock = (HERE / "runtime-lock.json").read_bytes()
        self.write("source/" + reuse.LOCK, lock)
        self.write(reuse.LOCK, lock)
        libraries = []
        for simulator in (False, True):
            identifier = "ios-arm64" + ("-simulator" if simulator else "")
            item = {"LibraryIdentifier": identifier, "LibraryPath": "libOpenJDK.a", "HeadersPath": "Headers",
                    "SupportedPlatform": "ios", "SupportedArchitectures": ["arm64"]}
            if simulator:
                item["SupportedPlatformVariant"] = "simulator"
            libraries.append(item)
            self.write(f"source/{reuse.FRAMEWORK}/{identifier}/libOpenJDK.a")
            self.write(f"source/{reuse.FRAMEWORK}/{identifier}/Headers/jni.h")
        self.write(f"source/{reuse.FRAMEWORK}/Info.plist", plistlib.dumps({"AvailableLibraries": libraries}))
        for home in reuse.HOMES.values():
            for module in json.loads(lock)["requiredModules"]:
                self.write(f"source/{home}/modules/{module}/module-info.class")
            for module, path in reuse.verifier.PROBES.items():
                self.write(f"source/{home}/modules/{module}/{path}")
            self.write(f"source/{home}/modules/java.base/java/lang/Object.class",
                       b"\xca\xfe\xba\xbe" + struct.pack(">HH", 0, 72) + b"fixture")
            for path in reuse.verifier.REQUIRED_DATA_FILES:
                self.write(f"source/{home}/{path}")
            if release is not None:
                self.write(f"source/{home}/release", release)
        return native

    def test_path_attack_or_extra_old_jar_is_rejected_before_any_extraction(self):
        for name in ("../outside", "/absolute", "C:/escape", "bad\\path", "a/./b", "a//b",
                     reuse.JAR_PATH, ".github/workflows/extra.yml"):
            with self.subTest(name=name):
                archive = self.zip([(name, b"untrusted")])
                destination = self.root / "extracted"
                with self.assertRaises(ValueError):
                    reuse.extract_native(archive, destination)
                self.assertFalse(destination.exists())

    def test_duplicate_case_collision_symlink_and_size_limit_rejected(self):
        prefix = reuse.FRAMEWORK + "/"
        archive = self.zip([(prefix + "A", b"a"), (prefix + "a", b"b")])
        with self.assertRaisesRegex(ValueError, "case-colliding"):
            reuse.extract_native(archive, self.root / "extracted")
        entry = zipfile.ZipInfo(prefix + "link")
        entry.create_system = 3
        entry.external_attr = (stat.S_IFLNK | 0o777) << 16
        archive = self.zip([(entry, b"../../outside")])
        with self.assertRaisesRegex(ValueError, "symlink"):
            reuse.extract_native(archive, self.root / "extracted")
        archive = self.zip([(prefix + "large", b"12345")])
        with patch.object(reuse, "MAX_EXPANDED_BYTES", 4), self.assertRaisesRegex(ValueError, "size limit"):
            reuse.extract_native(archive, self.root / "extracted")

    def test_existing_extraction_destination_is_never_overwritten(self):
        archive = self.zip([(reuse.FRAMEWORK + "/library", b"new")])
        destination = self.root / "extracted"
        destination.mkdir()
        sentinel = destination / "sentinel"
        sentinel.write_bytes(b"original")
        with self.assertRaisesRegex(ValueError, "overwrite"):
            reuse.extract_native(archive, destination)
        self.assertEqual(sentinel.read_bytes(), b"original")

    def test_actual_downloaded_bytes_and_digest_are_both_checked(self):
        data = b"native archive fixture"
        api = FakeAPI()
        for expected_size, expected_hash, succeeds in ((len(data), hashlib.sha256(data).hexdigest(), True),
                (len(data), "0" * 64, False), (len(data) + 1, hashlib.sha256(data).hexdigest(), False)):
            path = self.root / (str(expected_size) + expected_hash + ".zip")
            with patch.object(reuse, "BASELINE_BYTES", expected_size), patch.object(reuse, "BASELINE_DIGEST", expected_hash), \
                    patch.object(reuse, "download_url_response", return_value=io.BytesIO(data)):
                if succeeds:
                    reuse.download_native(api, path)
                    self.assertEqual(path.read_bytes(), data)
                else:
                    with self.assertRaisesRegex(ValueError, "bytes or SHA256"):
                        reuse.download_native(api, path)

    def test_download_redirect_does_not_forward_token(self):
        requests = []
        def open_request(request, timeout):
            requests.append(request)
            if len(requests) == 1:
                raise urllib.error.HTTPError(request.full_url, 302, "redirect",
                    {"Location": "https://test.blob.core.windows.net/artifact?signature=test"}, None)
            return io.BytesIO(b"archive")
        opener = unittest.mock.Mock()
        opener.open.side_effect = open_request
        with patch.object(reuse.urllib.request, "build_opener", return_value=opener):
            with reuse.download_url_response(FakeAPI()) as response:
                self.assertEqual(response.read(), b"archive")
        self.assertIsNotNone(requests[0].get_header("Authorization"))
        self.assertIsNone(requests[1].get_header("Authorization"))

    def test_unapproved_redirect_is_rejected(self):
        opener = unittest.mock.Mock()
        opener.open.side_effect = urllib.error.HTTPError("https://api.github.com/test", 302, "redirect",
            {"Location": "https://attacker.example/artifact"}, None)
        with patch.object(reuse.urllib.request, "build_opener", return_value=opener):
            with self.assertRaisesRegex(ValueError, "approved HTTPS"):
                reuse.download_url_response(FakeAPI())

    def test_native_layout_has_all_modules_classes_data_and_fresh_jar(self):
        jar, native = self.jar(), self.native()
        result = reuse.validate_layout(native, jar)
        compatibility = result["device"]["bytecodeCompatibility"]
        self.assertEqual(compatibility["source"], "modules/java.base/java/lang/Object.class")
        self.assertEqual(compatibility["nativeClassMajor"], 72)
        self.assertEqual(compatibility["freshJarMaximumBaseClassMajor"], 65)
        self.assertFalse(compatibility["runtimeJavaVersionMeasured"])
        self.assertNotIn("releaseDeclaration", compatibility)
        for relative in reuse.HOMES.values():
            self.assertFalse((native / relative / "release").exists())
        self.assertTrue(result["simulator"]["staticValidationPassed"])
        missing = native / reuse.HOMES["device"] / "modules/java.desktop/java/beans/Introspector.class"
        missing.unlink()
        with self.assertRaisesRegex(ValueError, "Missing required class"):
            reuse.validate_layout(native, jar)

    def test_optional_release_is_parsed_and_cross_checked_against_native_class(self):
        jar, native = self.jar(), self.native(release=b'JAVA_VERSION="28-internal"\n')
        result = reuse.validate_layout(native, jar)
        self.assertEqual(result["device"]["bytecodeCompatibility"]["releaseDeclaration"],
                         {"source": "release", "javaVersion": "28-internal", "javaFeature": 28})
        release = native / reuse.HOMES["device"] / "release"
        for content in (b'JAVA_VERSION="27-internal"\n', b'JAVA_VERSION="29-internal"\n'):
            release.write_bytes(content)
            with self.subTest(content=content), self.assertRaisesRegex(ValueError, "disagree"):
                reuse.validate_layout(native, jar)

    def test_present_but_invalid_release_does_not_use_class_header_as_fallback(self):
        jar, native = self.jar(), self.native(release=b"")
        release = native / reuse.HOMES["device"] / "release"
        for content in (b"", b'JAVA_VERSION="garbage"\n', b'JAVA_VERSION="28 garbage"\n', b'JAVA_VERSION="28+garbage"\n',
                        b'JAVA_VERSION="28-internal" unexpected\n',
                        b'JAVA_VERSION="28-internal"\nJAVA_VERSION="28"\n',
                        b'JAVA_VERSION="28-internal"\nJAVA_VERSION=garbage\n'):
            release.write_bytes(content)
            with self.subTest(content=content), self.assertRaisesRegex(ValueError, "valid JAVA_VERSION"):
                reuse.validate_layout(native, jar)

    def test_malformed_preview_or_invalid_native_class_header_rejected_without_release(self):
        jar, native = self.jar(), self.native()
        object_class = native / reuse.HOMES["device"] / "modules/java.base/java/lang/Object.class"
        invalid = (b"", b"bad magic", b"\xca\xfe\xba\xbe" + struct.pack(">HH", 0, 44),
                   b"\xca\xfe\xba\xbe" + struct.pack(">HH", 65535, 72),
                   b"\xca\xfe\xba\xbe" + struct.pack(">HH", 1, 72))
        for header in invalid:
            object_class.write_bytes(header)
            with self.subTest(header=header), self.assertRaisesRegex(ValueError, "native Object.class"):
                reuse.validate_layout(native, jar)

    def test_exact_native_class_major_is_allowed_but_newer_or_preview_jar_is_rejected(self):
        native = self.native()
        result = reuse.validate_layout(native, self.jar(version=72))
        self.assertEqual(result["device"]["bytecodeCompatibility"]["freshJarMaximumBaseClassMajor"], 72)
        with self.assertRaisesRegex(ValueError, "base bytecode"):
            reuse.validate_layout(native, self.jar(version=73))
        with self.assertRaisesRegex(ValueError, "Preview bytecode"):
            reuse.validate_layout(native, self.jar(version=72, minor=65535))

    def test_changed_native_lock_or_missing_module_rejected(self):
        jar, native = self.jar(), self.native()
        lock = native / reuse.LOCK
        original = lock.read_bytes()
        lock.write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "lock differs"):
            reuse.validate_layout(native, jar)
        lock.write_bytes(original)
        shutil.rmtree(native / reuse.HOMES["device"] / "modules/java.xml")
        with self.assertRaisesRegex(ValueError, "module inventory"):
            reuse.validate_layout(native, jar)

    def test_missing_new_suite_and_too_new_base_bytecode_rejected(self):
        jar = self.jar(omit=("io/yuedu/legado/InteropSemanticSuite.class",))
        with self.assertRaisesRegex(ValueError, "required probe classes"):
            reuse.jar_details(jar)
        jar = self.jar(version=80)
        native = self.native()
        with self.assertRaisesRegex(ValueError, "base bytecode"):
            reuse.validate_layout(native, jar)

    def fresh_record(self):
        jar = self.jar()
        record = {"currentSHA": CURRENT, "repository": "owner/repository", "currentRunID": 123,
                  "jvmInputs": [{"path": "Packages/LegadoRuntime/jvm", "object": "b" * 40}],
                  "freshJVMArtifact": {"id": 999, "digest": "sha256:" + "d" * 64}}
        manifest = {"schemaVersion": 1, "sourceSHA": CURRENT, "repository": record["repository"], "runID": 123,
                    "workflowPath": reuse.CURRENT_WORKFLOW, "workflowBlob": "c" * 40,
                    "inputs": record["jvmInputs"], "includeEngineTests": True,
                    "completedGradleTasks": ["test", "runtimeJar", "runtimeSmoke", "runtimeSuiteSmoke"],
                    "jar": reuse.jar_details(jar)}
        self.write(reuse.JVM_MANIFEST, json.dumps(manifest).encode())
        return record, manifest

    def test_fresh_manifest_requires_current_run_source_tree_and_jar_bytes(self):
        record, manifest = self.fresh_record()
        with patch.object(reuse.replay, "git", return_value="c" * 40):
            self.assertEqual(reuse.verify_fresh_jvm(record)["producer"]["sourceSHA"], CURRENT)
            for key, value in (("runID", 1), ("sourceSHA", reuse.BASELINE_SHA), ("inputs", []),
                               ("includeEngineTests", False)):
                changed = {**manifest, key: value}
                self.write(reuse.JVM_MANIFEST, json.dumps(changed).encode())
                with self.subTest(key=key), self.assertRaisesRegex(ValueError, "provenance"):
                    reuse.verify_fresh_jvm(record)
            self.write(reuse.JVM_MANIFEST, json.dumps(manifest).encode())
            with (self.root / reuse.JAR_PATH).open("ab") as stream:
                stream.write(b"tampering")
            with self.assertRaisesRegex(ValueError, "JAR hash"):
                reuse.verify_fresh_jvm(record)

    def test_restore_copies_only_native_and_preserves_fresh_jar(self):
        record, _ = self.fresh_record()
        native = self.native()
        archive = self.zip([(path.relative_to(native).as_posix(), path.read_bytes())
                            for path in native.rglob("*") if path.is_file()])
        self.write("Packages/LegadoRuntime/Package.swift")
        (self.root / ".build/ci-logs").mkdir(parents=True)
        record.update(status="prepared", native={"sourceSHA": reuse.BASELINE_SHA}, nativeInputChecks=["checks"])
        before = reuse.sha256(self.root / reuse.JAR_PATH)
        def download(api, destination):
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(archive, destination)
        with patch.object(reuse, "current_checkout", return_value=CURRENT), \
                patch.object(reuse, "current_run_id", return_value=123), \
                patch.object(reuse.replay, "GitHub", return_value=FakeAPI()), \
                patch.object(reuse, "native_source", return_value=record["native"]), \
                patch.object(reuse, "source_inputs", return_value=record["nativeInputChecks"]), \
                patch.object(reuse, "jvm_inputs", return_value=record["jvmInputs"]), \
                patch.object(reuse, "fresh_artifact", return_value=record["freshJVMArtifact"]), \
                patch.object(reuse.replay, "git", return_value="c" * 40), \
                patch.object(reuse, "download_native", side_effect=download):
            reuse.restore(record)
        self.assertEqual(reuse.sha256(self.root / reuse.JAR_PATH), before)
        self.assertEqual(record["status"], "restored")
        self.assertTrue(record["jvmPayloadRecompiled"])
        self.assertFalse(record["nativeRuntimeRecompiled"])
        self.assertFalse(record["deviceValidationPassed"])
        for path in reuse.ROOTS:
            self.assertTrue((self.root / path).is_dir())

    def test_prepare_to_restore_input_change_stops_before_download(self):
        record = {"status": "prepared", "currentSHA": CURRENT, "currentRunID": 123,
                  "repository": "owner/repository", "native": {"sourceSHA": reuse.BASELINE_SHA},
                  "nativeInputChecks": ["before"]}
        with patch.object(reuse, "current_checkout", return_value=CURRENT), \
                patch.object(reuse, "current_run_id", return_value=123), \
                patch.object(reuse.replay, "GitHub", return_value=FakeAPI()), \
                patch.object(reuse, "native_source", return_value=record["native"]), \
                patch.object(reuse, "source_inputs", return_value=["changed"]), \
                patch.object(reuse, "download_native") as download:
            with self.assertRaisesRegex(ValueError, "changed after preparation"):
                reuse.restore(record)
            download.assert_not_called()

    def test_restore_refuses_existing_native_before_download(self):
        record, _ = self.fresh_record()
        record.update(status="prepared", native={"sourceSHA": reuse.BASELINE_SHA}, nativeInputChecks=["checks"])
        sentinel = self.write(reuse.FRAMEWORK + "/sentinel", b"existing native")
        with patch.object(reuse, "current_checkout", return_value=CURRENT), \
                patch.object(reuse, "current_run_id", return_value=123), \
                patch.object(reuse.replay, "GitHub", return_value=FakeAPI()), \
                patch.object(reuse, "native_source", return_value=record["native"]), \
                patch.object(reuse, "source_inputs", return_value=record["nativeInputChecks"]), \
                patch.object(reuse, "jvm_inputs", return_value=record["jvmInputs"]), \
                patch.object(reuse, "fresh_artifact", return_value=record["freshJVMArtifact"]), \
                patch.object(reuse.replay, "git", return_value="c" * 40), \
                patch.object(reuse, "download_native") as download:
            with self.assertRaisesRegex(ValueError, "overwrite"):
                reuse.restore(record)
            download.assert_not_called()
        self.assertEqual(sentinel.read_bytes(), b"existing native")


if __name__ == "__main__":
    unittest.main()
