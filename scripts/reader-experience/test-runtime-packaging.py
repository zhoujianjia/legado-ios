#!/usr/bin/env python3
"""Ordinary-payload guard tests; synthetic JAR headers are never executed."""
import importlib.util
import hashlib
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("reader_runtime_packaging_tests", HERE / "runtime-packaging.py")
packaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packaging)


class OrdinaryJarGuardTests(unittest.TestCase):
    def setUp(self):
        # Synthetic headers stand in for release classes only in this test.
        # The real inspector still hashes actual release classes against its
        # source manifest, and the assembled real JAR is audited separately.
        self.header = struct.pack(">IHH", 0xCAFEBABE, 0, 65)
        self.scalar = packaging.scalar_manifest()
        for item in self.scalar["requiredRuntimeClasses"]:
            item["sha256"] = hashlib.sha256(self.header).hexdigest()
        self.manifest_patch = patch.object(packaging, "scalar_manifest", return_value=self.scalar)
        self.manifest_patch.start()
        self.addCleanup(self.manifest_patch.stop)

    def jar(self, directory, extras, overrides=None, missing=()):
        path = Path(directory) / "synthetic-header-check.jar"
        # The inspector validates the header and packaging, not JVM execution.
        header = self.header
        vendor = packaging.REPO / "Packages/LegadoRuntime/vendor"
        contents = {name: header for name in packaging.REQUIRED}
        contents["META-INF/MANIFEST.MF"] = b"Manifest-Version: 1.0\nLegado-Engine-Tests: false\n"
        for name in ("manifest.json", "resolved-dependencies.json"):
            for scope in ("runtime-http", "scalar-rules"):
                contents["META-INF/legado-provenance/" + scope + "/" + name] = (vendor / scope / name).read_bytes()
        for directory in (vendor / "runtime-http/licenses", vendor / "probe/licenses"):
            for license in directory.rglob("*"):
                if license.is_file():
                    contents.setdefault("META-INF/licenses/jvm-http/" + license.relative_to(directory).as_posix(), license.read_bytes())
        for item in self.scalar["licenseFiles"]:
            contents["META-INF/licenses/scalar-rules/" + item["path"].removeprefix("licenses/")] = (vendor / "scalar-rules" / item["path"]).read_bytes()
        for item in self.scalar["packagedJarMetadata"]:
            contents[item["jarEntry"]] = (vendor / "scalar-rules" / item["path"]).read_bytes()
        for name in extras:
            contents[name] = header if name.endswith(".class") else b"public test fixture"
        contents.update(overrides or {})
        for name in missing:
            contents.pop(name)
        with zipfile.ZipFile(path, "w") as jar:
            for name, data in contents.items():
                jar.writestr(name, data)
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
                     "io/legado/app/JsEngineCapabilitiesTest.class",
                     "io/legado/app/model/analyzeRule/AnalyzeByJSonPathErrorPolicyTest.class",
                     "io/yuedu/legado/StaticScalarSelectorRuleTest.class",
                     "io/yuedu/legado/DeclarativeScalarSelectorTest.class",
                     "fixtures/android-scalar-selector-golden.json"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                jar = self.jar(directory, [name])
                with self.assertRaisesRegex(ValueError, "test fixtures or JUnit"):
                    packaging.inspect_jar(jar)

    def test_scalar_classes_are_required_and_old_bytes_cannot_masquerade_as_new_versions(self):
        for item in self.scalar["requiredRuntimeClasses"]:
            with self.subTest(item=item["path"]), tempfile.TemporaryDirectory() as directory:
                jar = self.jar(directory, [], missing=[item["path"]])
                with self.assertRaisesRegex(ValueError, "lacks the production"):
                    packaging.inspect_jar(jar)
                jar = self.jar(directory, [], overrides={item["path"]: struct.pack(">IHH", 0xCAFEBABE, 0, 64)})
                with self.assertRaisesRegex(ValueError, "class differs"):
                    packaging.inspect_jar(jar)

    def test_each_versioned_license_and_notice_must_match_original_release_bytes(self):
        for item in self.scalar["licenseFiles"]:
            name = "META-INF/licenses/scalar-rules/" + item["path"].removeprefix("licenses/")
            with self.subTest(item=item["path"]), tempfile.TemporaryDirectory() as directory:
                jar = self.jar(directory, [], missing=[name])
                with self.assertRaisesRegex(ValueError, "license/NOTICE differs"):
                    packaging.inspect_jar(jar)
                jar = self.jar(directory, [], overrides={name: b"old version NOTICE is not the current release"})
                with self.assertRaisesRegex(ValueError, "license/NOTICE differs"):
                    packaging.inspect_jar(jar)

    def test_scalar_graph_and_maven_version_metadata_cannot_be_stale(self):
        for item in self.scalar["packagedJarMetadata"]:
            with self.subTest(item=item["jarEntry"]), tempfile.TemporaryDirectory() as directory:
                jar = self.jar(directory, [], overrides={item["jarEntry"]: b"version=3.12.0\n"})
                with self.assertRaisesRegex(ValueError, "Maven version metadata differs"):
                    packaging.inspect_jar(jar)
        for name in ("manifest.json", "resolved-dependencies.json"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                jar = self.jar(directory, [], overrides={"META-INF/legado-provenance/scalar-rules/" + name: b"{}"})
                with self.assertRaisesRegex(ValueError, "scalar-rule provenance differs"):
                    packaging.inspect_jar(jar)


if __name__ == "__main__":
    unittest.main()
