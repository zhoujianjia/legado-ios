#!/usr/bin/env python3
"""Ordinary-payload guard tests; synthetic JAR headers are never executed."""
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
import zipfile

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("reader_runtime_packaging_tests", HERE / "runtime-packaging.py")
packaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packaging)


class OrdinaryJarGuardTests(unittest.TestCase):
    def jar(self, directory, extras):
        path = Path(directory) / "synthetic-header-check.jar"
        # The inspector validates the header and packaging, not JVM execution.
        header = struct.pack(">IHH", 0xCAFEBABE, 0, 65)
        vendor = packaging.REPO / "Packages/LegadoRuntime/vendor"
        with zipfile.ZipFile(path, "w") as jar:
            for name in packaging.REQUIRED:
                jar.writestr(name, header)
            jar.writestr("META-INF/MANIFEST.MF", "Manifest-Version: 1.0\nLegado-Engine-Tests: false\n")
            for name in ("manifest.json", "resolved-dependencies.json"):
                jar.writestr("META-INF/legado-provenance/runtime-http/" + name, (vendor / "runtime-http" / name).read_bytes())
            written = set()
            for directory in (vendor / "runtime-http/licenses", vendor / "probe/licenses"):
                for license in directory.rglob("*"):
                    if license.is_file():
                        name = "META-INF/licenses/jvm-http/" + license.relative_to(directory).as_posix()
                        if name not in written:
                            jar.writestr(name, license.read_bytes())
                            written.add(name)
            for name in extras:
                jar.writestr(name, header if name.endswith(".class") else b"public test fixture")
        return path

    def test_legitimate_xpath_node_test_class_is_not_a_unit_test(self):
        with tempfile.TemporaryDirectory() as directory:
            jar = self.jar(directory, ["org/seimicrawler/xpath/core/NodeTest.class"])
            result = packaging.inspect_jar(jar)
            self.assertFalse(result["testClassesIncluded"])
            self.assertEqual(result["maximumBaseClassMajor"], 65)

    def test_tls_fixture_certificates_keys_and_metadata_are_all_rejected(self):
        for name in ("fixture-manifest.json", "test-ca.der", "server-localhost.der", "server-private-key.pk8", "unrelated-ca.der"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                jar = self.jar(directory, ["io/yuedu/legado/tls-fixture-v1/" + name])
                with self.assertRaisesRegex(ValueError, "test fixtures or JUnit"):
                    packaging.inspect_jar(jar)

    def test_project_tests_nested_classes_and_optional_fixture_remain_rejected(self):
        for name in ("org/junit/Test.class", "fixtures/main-source.js",
                     "io/yuedu/legado/MainJsFacadeTest.class", "io/yuedu/legado/MainJsFacadeTest$Companion.class",
                     "io/legado/app/JsEngineCapabilitiesTest.class"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                jar = self.jar(directory, [name])
                with self.assertRaisesRegex(ValueError, "test fixtures or JUnit"):
                    packaging.inspect_jar(jar)


if __name__ == "__main__":
    unittest.main()
