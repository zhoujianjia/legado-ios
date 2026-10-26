#!/usr/bin/env python3
"""Portable regressions for runtime layout validation and safe resource staging."""
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import zipfile

HERE = Path(__file__).resolve().parent

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

verify = load("verify_runtime_test", HERE / "verify-runtime.py")
stager = load("stage_runtime_test", HERE / "stage-runtime.py")
keeper = load("prepare_symbol_keeper_test", HERE / "prepare-symbol-keeper.py")
app_runtime = load("prepare_app_runtime_test", HERE / "prepare-app-runtime.py")


class SymbolKeeperTests(unittest.TestCase):
    def test_removes_only_the_known_stale_registration(self):
        retained = b"extern void* Java_java_lang_System_registerNatives;\nextern \"C\" void loadfunctions() {}\n"
        fixture = b"\n".join(keeper.REGISTRATION_LINES) + b"\n" + retained
        self.assertEqual(keeper.remove_stale_registration(fixture), retained)

    def test_changed_or_duplicate_registration_rejected(self):
        fixture = b"\n".join(keeper.REGISTRATION_LINES) + b"\n"
        for source in [fixture.replace(keeper.REGISTRATION_LINES[1], b""),
                       fixture + keeper.REGISTRATION_LINES[0] + b"\n",
                       fixture.replace(b"l2252", b"l9999")]:
            with self.subTest(source=source), self.assertRaisesRegex(ValueError, "exactly the three"):
                keeper.remove_stale_registration(source)

    def test_changed_upstream_source_rejected_before_writing(self):
        with tempfile.TemporaryDirectory() as temporary:
            source, destination = Path(temporary) / "source.cpp", Path(temporary) / "destination.cpp"
            source.write_bytes(b"\n".join(keeper.REGISTRATION_LINES) + b"\n")
            destination.write_bytes(b"existing destination")
            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                keeper.prepare(source, destination)
            self.assertEqual(destination.read_bytes(), b"existing destination")

class RuntimeToolsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.java_home = self.root / "source-java-home"
        modules = json.loads((HERE / "runtime-lock.json").read_text(encoding="utf-8"))["requiredModules"]
        for module in modules:
            path = self.java_home / "modules" / module
            path.mkdir(parents=True)
            (path / "module-info.class").write_bytes(b"test fixture")
        for module, name in verify.PROBES.items():
            path = self.java_home / "modules" / module / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"test fixture")
        for name in verify.REQUIRED_DATA_FILES:
            path = self.java_home / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"synthetic data fixture; not a runnable JDK")
        self.jar = self.root / "runtime.jar"
        with zipfile.ZipFile(self.jar, "w") as archive:
            for name in ["io/yuedu/legado/LegadoRuntime.class", "io/yuedu/legado/NativeHost.class", "org/htmlunit/corejs/javascript/Context.class"]:
                archive.writestr(name, b"test fixture")
    def tearDown(self): self.temporary.cleanup()
    def test_missing_beans_dependency_rejected(self):
        (self.java_home / "modules/java.desktop/java/beans/Introspector.class").unlink()
        with self.assertRaisesRegex(ValueError, "Introspector"):
            verify.validate(self.java_home, self.jar)
    def test_missing_runtime_data_rejected(self):
        for name in verify.REQUIRED_DATA_FILES:
            with self.subTest(name=name):
                path = self.java_home / name
                original = path.read_bytes()
                path.unlink()
                with self.assertRaisesRegex(ValueError, "Missing or unreadable JDK runtime data"):
                    verify.validate(self.java_home, self.jar)
                path.write_bytes(original)
    def test_empty_security_configuration_rejected(self):
        (self.java_home / "conf/security/java.security").write_bytes(b"")
        with self.assertRaisesRegex(ValueError, "Empty JDK runtime data: conf/security/java.security"):
            verify.validate(self.java_home, self.jar)
    def test_wrong_exploded_layout_rejected(self):
        (self.java_home / "lib/modules").mkdir(parents=True)
        with self.assertRaisesRegex(ValueError, "reserved for a jimage"):
            verify.validate(self.java_home, self.jar)
    def test_thin_jar_rejected(self):
        with zipfile.ZipFile(self.jar, "w") as archive: archive.writestr("io/yuedu/legado/LegadoRuntime.class", b"test fixture")
        with self.assertRaisesRegex(ValueError, "NativeHost"):
            verify.validate(self.java_home, self.jar)
    def test_staging_preserves_readme_and_records_unverified_device_gate(self):
        destination = self.root / "Resources/LegadoRuntime"
        destination.mkdir(parents=True)
        (destination / "README.md").write_text("Preserve documentation", encoding="utf-8")
        manifest = stager.stage(self.java_home, self.jar, destination)
        self.assertFalse(manifest["deviceValidationPassed"])
        self.assertTrue((destination / "java-home/modules/java.xml/module-info.class").is_file())
        for name in verify.REQUIRED_DATA_FILES:
            self.assertEqual((destination / "java-home" / name).read_bytes(), (self.java_home / name).read_bytes())
        self.assertEqual((destination / "README.md").read_text(encoding="utf-8"), "Preserve documentation")
        with self.assertRaisesRegex(ValueError, "already exists"):
            stager.stage(self.java_home, self.jar, destination)
        stager.stage(self.java_home, self.jar, destination, replace=True)
        self.assertTrue((destination / "README.md").is_file())
    def test_staging_cannot_replace_source(self):
        with self.assertRaisesRegex(ValueError, "separate"):
            stager.stage(self.java_home, self.jar, self.java_home)

    def test_module_image_staging_retains_bytes_and_installs_at_native_boot_path(self):
        # The writer treats class bodies as opaque bytes. These fixtures verify
        # package integrity; actual JVM loading is a separate native CI gate.
        probes = set(stager.images.PROBES)
        probes.update(module + "/module-info.class" for module in stager.images.MODULES)
        for name in probes:
            path = self.java_home / "modules" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(bytes.fromhex("cafebabe00000048") + name.encode("ascii"))
        extra = self.java_home / "modules/java.base/fixture/unobserved.dat"
        extra.parent.mkdir(parents=True)
        extra.write_bytes(b"unchanged resource")
        original = {path.relative_to(self.java_home).as_posix(): path.read_bytes()
                    for path in self.java_home.rglob("*") if path.is_file()}
        app = self.app(staged=False)
        manifest = stager.stage(self.java_home, self.jar, app / "LegadoRuntime", module_format="jimage")
        self.assertEqual(manifest["layout"], "jimage-java-home/lib/modules")
        self.assertTrue(manifest["moduleImageCreation"]["allResourceBytesPreserved"])
        self.assertNotIn("resourcePaths", manifest["moduleImage"])
        self.assertFalse((app / "LegadoRuntime/java-home/modules").exists())
        self.assertEqual(original, {path.relative_to(self.java_home).as_posix(): path.read_bytes()
                                    for path in self.java_home.rglob("*") if path.is_file()})
        app_runtime.prepare(app)
        image = app / "lib/lib/modules"
        self.assertTrue(image.is_file())
        self.assertEqual(verify.validate(app / "lib", self.jar)["moduleImage"], manifest["moduleImage"])
        self.assertFalse(app_runtime.prepare(app)["changed"])
        # A structurally valid modification of a non-probe resource still must
        # fail its exact staging binding before an incremental build accepts it.
        parsed = stager.images._Image(image)
        row = parsed.by_name["/java.base/fixture/unobserved.dat"]
        raw = bytearray(image.read_bytes())
        raw[row["begin"]] ^= 1
        image.write_bytes(raw)
        with self.assertRaisesRegex(ValueError, "differs from its staging manifest"):
            app_runtime.prepare(app)

    def test_replacement_requires_ownership_marker(self):
        destination = self.root / "existing"
        destination.mkdir()
        (destination / "java-home").mkdir()
        with self.assertRaisesRegex(ValueError, "ownership marker"):
            stager.stage(self.java_home, self.jar, destination, replace=True)

    def app(self, staged=True):
        app = self.root / "Probe.app"
        app.mkdir()
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Probe"}))
        (app / "Probe").write_bytes(b"synthetic bundle executable")
        if staged:
            stager.stage(self.java_home, self.jar, app / "LegadoRuntime")
        return app

    def test_app_runtime_moves_one_home_and_is_idempotent(self):
        app = self.app()
        original_manifest = (app / "LegadoRuntime/runtime-manifest.json").read_bytes()
        prepared = app_runtime.prepare(app)
        self.assertTrue(prepared["changed"])
        self.assertTrue(prepared["staticValidationPassed"])
        self.assertFalse(prepared["deviceValidationPassed"])
        self.assertEqual(prepared["javaHomeRelativePath"], "lib")
        self.assertFalse((app / "LegadoRuntime/java-home").exists())
        self.assertTrue((app / "lib/modules/java.base/java/lang/Object.class").is_file())
        self.assertTrue((app / "lib" / app_runtime.OWNER_FILE).is_file())
        self.assertEqual((app / "LegadoRuntime/runtime-manifest.json").read_bytes(), original_manifest)
        self.assertFalse(app_runtime.prepare(app)["changed"])

    def test_app_runtime_replaces_owned_home_after_incremental_copy(self):
        app = self.app()
        app_runtime.prepare(app)
        (app / "lib/old-runtime-only.txt").write_bytes(b"old payload")
        (self.java_home / "new-runtime-only.txt").write_bytes(b"new payload")
        stager.stage(self.java_home, self.jar, app / "LegadoRuntime", replace=True)
        self.assertTrue(app_runtime.prepare(app)["changed"])
        self.assertTrue((app / "lib/new-runtime-only.txt").is_file())
        self.assertFalse((app / "lib/old-runtime-only.txt").exists())
        self.assertFalse((app / "LegadoRuntime/java-home").exists())
        self.assertEqual(list(app.glob(".legado-runtime-lib-previous-*")), [])

    def test_app_runtime_source_only_is_explicitly_unavailable(self):
        app = self.app(staged=False)
        result = app_runtime.prepare(app)
        self.assertFalse(result["javaHomePresent"])
        self.assertFalse(result["staticValidationPassed"])
        self.assertEqual(result["layout"], "source-only")
        self.assertFalse((app / "lib").exists())

    def test_bad_app_runtime_source_preserves_old_home(self):
        app = self.app()
        app_runtime.prepare(app)
        sentinel = app / "lib/preserve.txt"
        sentinel.write_bytes(b"keep original owned home")
        stager.stage(self.java_home, self.jar, app / "LegadoRuntime", replace=True)
        (app / "LegadoRuntime/java-home/conf/security/java.security").unlink()
        with self.assertRaisesRegex(ValueError, "Missing or unreadable JDK runtime data"):
            app_runtime.prepare(app)
        self.assertEqual(sentinel.read_bytes(), b"keep original owned home")
        self.assertTrue((app / "LegadoRuntime/java-home").is_dir())

    def test_app_runtime_missing_marker_preserves_old_home(self):
        app = self.app()
        app_runtime.prepare(app)
        stager.stage(self.java_home, self.jar, app / "LegadoRuntime", replace=True)
        (app / "LegadoRuntime/runtime-manifest.json").unlink()
        with self.assertRaisesRegex(ValueError, "ownership marker"):
            app_runtime.prepare(app)
        self.assertTrue((app / "lib/modules/java.base/java/lang/Object.class").is_file())
        self.assertTrue((app / "LegadoRuntime/java-home").is_dir())

    def test_app_runtime_refuses_unknown_existing_lib(self):
        app = self.app()
        (app / "lib").mkdir()
        sentinel = app / "lib/preserve.txt"
        sentinel.write_bytes(b"unowned data")
        with self.assertRaisesRegex(ValueError, "unowned"):
            app_runtime.prepare(app)
        self.assertEqual(sentinel.read_bytes(), b"unowned data")

    def test_app_runtime_requires_local_bundle_executable(self):
        app = self.app()
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "../outside"}))
        with self.assertRaisesRegex(ValueError, "bundle-local executable"):
            app_runtime.prepare(app)
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Absent"}))
        with self.assertRaisesRegex(ValueError, "executable is absent"):
            app_runtime.prepare(app)

    def test_app_runtime_rejects_escape_before_any_mutation(self):
        app = self.app()
        with self.assertRaisesRegex(ValueError, "escapes"):
            app_runtime.checked_path(app.resolve() / ".." / "outside", app.resolve())
        self.assertTrue((app / "LegadoRuntime/java-home").is_dir())

    def test_app_runtime_rename_failure_restores_old_home(self):
        app = self.app()
        app_runtime.prepare(app)
        sentinel = app / "lib/preserve.txt"
        sentinel.write_bytes(b"old payload")
        stager.stage(self.java_home, self.jar, app / "LegadoRuntime", replace=True)
        original_rename = Path.rename
        source = (app / "LegadoRuntime/java-home").resolve()
        def fail_source(path, target):
            if path == source:
                raise OSError("synthetic rename failure")
            return original_rename(path, target)
        with patch.object(Path, "rename", fail_source), self.assertRaisesRegex(OSError, "synthetic rename failure"):
            app_runtime.prepare(app)
        self.assertEqual(sentinel.read_bytes(), b"old payload")
        self.assertTrue(source.is_dir())
        self.assertEqual(list(app.glob(".legado-runtime-lib-previous-*")), [])

    def test_app_runtime_rejects_source_and_destination_links(self):
        app = self.app()
        outside = self.root / "outside"
        outside.mkdir()
        target = outside / "data.txt"
        target.write_bytes(b"external data")
        nested = app / "LegadoRuntime/java-home/escape.txt"
        try:
            nested.symlink_to(target)
        except OSError:
            self.skipTest("Host does not permit creating symlinks")
        with self.assertRaisesRegex(ValueError, "symlinked"):
            app_runtime.prepare(app)
        nested.unlink()
        (app / "lib").symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlinked"):
            app_runtime.prepare(app)
        self.assertEqual(target.read_bytes(), b"external data")

if __name__ == "__main__": unittest.main()
