#!/usr/bin/env python3
"""Portable regressions for runtime layout validation and safe resource staging."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

HERE = Path(__file__).resolve().parent

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

verify = load("verify_runtime_test", HERE / "verify-runtime.py")
stager = load("stage_runtime_test", HERE / "stage-runtime.py")

class RuntimeToolsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
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
        self.jar = self.root / "runtime.jar"
        with zipfile.ZipFile(self.jar, "w") as archive:
            for name in ["io/yuedu/legado/LegadoRuntime.class", "io/yuedu/legado/NativeHost.class", "org/htmlunit/corejs/javascript/Context.class"]:
                archive.writestr(name, b"test fixture")
    def tearDown(self): self.temporary.cleanup()
    def test_missing_beans_dependency_rejected(self):
        (self.java_home / "modules/java.desktop/java/beans/Introspector.class").unlink()
        with self.assertRaisesRegex(ValueError, "Introspector"):
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
        self.assertEqual((destination / "README.md").read_text(encoding="utf-8"), "Preserve documentation")
        with self.assertRaisesRegex(ValueError, "already exists"):
            stager.stage(self.java_home, self.jar, destination)
        stager.stage(self.java_home, self.jar, destination, replace=True)
        self.assertTrue((destination / "README.md").is_file())
    def test_staging_cannot_replace_source(self):
        with self.assertRaisesRegex(ValueError, "separate"):
            stager.stage(self.java_home, self.jar, self.java_home)
    def test_replacement_requires_ownership_marker(self):
        destination = self.root / "existing"
        destination.mkdir()
        (destination / "java-home").mkdir()
        with self.assertRaisesRegex(ValueError, "ownership marker"):
            stager.stage(self.java_home, self.jar, destination, replace=True)

if __name__ == "__main__": unittest.main()
