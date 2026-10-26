#!/usr/bin/env python3
"""Exercise actual pinned-writer roundtrip and independent image corruption gates."""
import importlib.util
import os
from pathlib import Path
import struct
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("jimage_tools", HERE / "jimage-tools.py")
IMAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(IMAGE)


def module_descriptor(module):
    def utf8(value):
        raw = IMAGE._mutf8_bytes(value)
        return b"\x01" + struct.pack(">H", len(raw)) + raw
    constants = [utf8("module-info"), b"\x07\x00\x01", utf8("Module"),
                 utf8(module), b"\x13\x00\x04", utf8("SourceFile"), utf8("module-info.java")]
    requires = b"\x00\x00"
    if module != "java.base":
        constants += [utf8("java.base"), b"\x13\x00\x08"]
        requires = struct.pack(">4H", 1, 9, 0x8000, 0)
    content = struct.pack(">3H", 5, 0, 0) + requires + struct.pack(">4H", 0, 0, 0, 0)
    return (bytes.fromhex("cafebabe00000048") + struct.pack(">H", len(constants) + 1)
            + b"".join(constants) + struct.pack(">7H", 0x8000, 2, 0, 0, 0, 0, 2)
            + struct.pack(">HI", 3, len(content)) + content + struct.pack(">HIH", 6, 2, 7))


class JimageToolsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="yuedu-jimage-tests-")
        cls.work = Path(cls.temporary.name)
        cls.modules = cls.work / "exploded"
        cls.modules.mkdir()
        names = set(IMAGE.PROBES) | {module + "/module-info.class" for module in IMAGE.MODULES}
        cls.expected = {}
        for name in sorted(names):
            # Opaque bytes intentionally contain the newer runtime class header;
            # the build JDK must never try to parse/recompile these test payloads.
            raw = (module_descriptor(name.split("/")[0]) if name.endswith("/module-info.class")
                   else bytes.fromhex("cafebabe00000048") + name.encode("ascii"))
            cls.expected[name] = raw
        cls.expected["java.base/example/empty.dat"] = b""
        cls.expected["java.base/example/payload.dat"] = bytes(range(256)) * 97
        cls.expected["java.base/example/\u8bfb\U0001f4d6.txt"] = b"modified-UTF8 filename"
        cls.expected["java.base/resource/only/messages.properties"] = b"resource-only package"
        cls.expected["java.base/META-INF/fixture/notice.txt"] = b"not a package"
        cls.expected["java.base/jdk/internal/constant/ConstantUtils.class"] = bytes.fromhex("cafebabe00000048")
        for name, raw in cls.expected.items():
            path = cls.modules / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(raw)
        cls.output = cls.work / "modules"
        java_home = os.environ.get("YUEDU_JIMAGE_TEST_JAVA_HOME")
        if not java_home:
            local = sorted((HERE.parents[1] / ".tools/jdk21").glob("*/bin/javac.exe"))
            if local:
                java_home = local[-1].parents[1]
        cls.report = IMAGE.create(cls.modules, cls.output, java_home)
        cls.raw = cls.output.read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def changed(self, name, mutate):
        raw = bytearray(self.raw)
        mutate(raw)
        path = self.work / name
        path.write_bytes(raw)
        return path

    def test_complete_roundtrip_keeps_newer_class_bytes_and_resource_names(self):
        image = IMAGE._Image(self.output)
        self.assertEqual(set(image.resources), set(self.expected))
        packages = IMAGE.module_packages(self.expected)
        for name, raw in self.expected.items():
            actual = image.content(image.by_name["/" + name])
            self.assertEqual((self.modules / name).read_bytes(), raw)
            if name.endswith("/module-info.class"):
                module = name.split("/")[0]
                record = IMAGE.verify_descriptor_augmentation(raw, actual, module, packages[module])
                self.assertTrue(record["originalConstantPoolPreserved"])
                self.assertTrue(record["originalAttributesPreserved"])
                self.assertEqual(IMAGE._module_info(actual, module)["packages"], set(packages[module]))
            else:
                self.assertEqual(actual, raw)
        self.assertEqual(self.report["moduleCount"], 13)
        self.assertEqual(self.report["moduleDescriptorCount"], 13)
        self.assertFalse(self.report["allResourceBytesPreserved"])
        self.assertTrue(self.report["allNonDescriptorResourceBytesPreserved"])
        self.assertTrue(self.report["descriptorOnlyModulePackagesAugmentationVerified"])
        self.assertTrue(self.report["modulePackagesVerified"])
        self.assertEqual(len(self.report["descriptorTransformations"]), 13)
        self.assertTrue(self.report["standardResourceTreesVerified"])
        self.assertTrue(self.report["perfectHashLookupsVerified"])

    def test_rejects_old_version_instead_of_relabeling_it(self):
        path = self.changed("old-version", lambda raw: struct.pack_into("<I", raw, 4, 0x10000))
        with self.assertRaisesRegex(ValueError, "version 1.1"):
            IMAGE.inspect(path)

    def test_rejects_truncated_index(self):
        path = self.work / "truncated"
        path.write_bytes(self.raw[:30])
        with self.assertRaisesRegex(ValueError, "index exceeds"):
            IMAGE.inspect(path)

    def test_rejects_redirect_tampering(self):
        image = IMAGE._Image(self.output)
        slot = IMAGE._hash_name("/java.base/java/lang/Object.class") % len(image.redirect)
        path = self.changed("redirect", lambda raw: struct.pack_into("<i", raw, 28 + slot * 4, -999999))
        with self.assertRaisesRegex(ValueError, "Perfect-hash"):
            IMAGE.inspect(path)

    def test_rejects_unknown_attribute(self):
        image = IMAGE._Image(self.output)
        location = image.by_name["/java.base/java/lang/Object.class"]["location"]
        start = 28 + len(image.redirect) * 8 + location
        path = self.changed("attribute", lambda raw: raw.__setitem__(start, 0xF8))
        with self.assertRaisesRegex(ValueError, "location attributes"):
            IMAGE.inspect(path)

    def test_rejects_missing_required_module_probe(self):
        image = IMAGE._Image(self.output)
        row = image.by_name["/java.base/java/lang/Object.class"]
        path = self.changed("class-header", lambda raw: raw.__setitem__(row["begin"], 0))
        with self.assertRaisesRegex(ValueError, "non-pinned class"):
            IMAGE.inspect(path)

    def test_rejects_preview_class_without_falsifying_preview_flags(self):
        path = self.modules / "java.base/example/Preview.class"
        path.write_bytes(bytes.fromhex("cafebabeffff0048"))
        try:
            with self.assertRaisesRegex(ValueError, "preview or non-pinned"):
                IMAGE.create(self.modules, self.work / "preview-image")
        finally:
            path.unlink()

    def test_refuses_existing_output_without_rewriting_it(self):
        with self.assertRaisesRegex(ValueError, "new file"):
            IMAGE.create(self.modules, self.output)
        self.assertEqual(self.output.read_bytes(), self.raw)

    def test_packages_follow_all_resource_parents_without_invented_ancestors(self):
        actual = IMAGE.module_packages([
            "java.base/a/b/Thing.class", "java.base/resource/only/messages.properties",
            "java.base/META-INF/fixture/notice.txt", "java.base/module-info.class",
            "java.base/META-INF/preview/preview/pkg/Thing.class", "java.base/class/Bad.class",
            "java.base/\u8bfb\u8005/\u5305/\u4e66.class", "java.base/$money/pkg2/data",
            "java.base/combining/e\u0301/data", "java.base/9invalid/file"])
        self.assertEqual(set(actual["java.base"]), {"a.b", "resource.only", "preview.pkg",
                         "\u8bfb\u8005.\u5305", "$money.pkg2", "combining.e\u0301"})

    def test_descriptor_augmentation_is_idempotent_and_exact(self):
        original = module_descriptor("java.base")
        output, record = IMAGE.augment_module_descriptor(original, ["jdk.internal.constant", "\u8bfb\u8005.\u5305"], "java.base")
        before, after = IMAGE._module_info(original), IMAGE._module_info(output)
        self.assertEqual(after["constantPool"][:len(before["constantPool"])], before["constantPool"])
        self.assertEqual([row["raw"] for row in after["attributes"][:-1]],
                         [row["raw"] for row in before["attributes"]])
        again, second = IMAGE.augment_module_descriptor(output, ["\u8bfb\u8005.\u5305", "jdk.internal.constant"], "java.base")
        self.assertEqual(again, output)
        self.assertTrue(record["changed"])
        self.assertFalse(second["changed"])
        with self.assertRaisesRegex(ValueError, "Existing ModulePackages"):
            IMAGE.augment_module_descriptor(output, ["java.lang"], "java.base")
        damaged = output[:-1] + bytes([output[-1] ^ 1])
        with self.assertRaises(ValueError):
            IMAGE.verify_descriptor_augmentation(original, damaged, "java.base", ["jdk.internal.constant", "\u8bfb\u8005.\u5305"])

    def test_descriptor_parser_rejects_truncation_wrong_module_and_body_changes(self):
        original = module_descriptor("java.base")
        for offset in (0, 8, 9, 11, len(original) - 1):
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                IMAGE._module_info(original[:offset], "java.base")
        with self.assertRaisesRegex(ValueError, "name differs"):
            IMAGE._module_info(original, "java.xml")
        output, _ = IMAGE.augment_module_descriptor(original, ["java.lang"], "java.base")
        altered = output.replace(b"module-info.java", b"module-info.javb")
        with self.assertRaisesRegex(ValueError, "exact ModulePackages-only"):
            IMAGE.verify_descriptor_augmentation(original, altered, "java.base", ["java.lang"])

    def test_inspect_rejects_descriptor_package_metadata_tampering(self):
        image = IMAGE._Image(self.output)
        row = image.by_name["/java.base/module-info.class"]
        descriptor = image.content(row)
        changed = descriptor.replace(b"jdk/internal/constant", b"jdk/internal/constanx")
        self.assertNotEqual(changed, descriptor)
        path = self.changed("descriptor-package", lambda raw: raw.__setitem__(slice(row["begin"], row["end"]), changed))
        with self.assertRaisesRegex(ValueError, "ModulePackages differs"):
            IMAGE.inspect(path)


if __name__ == "__main__":
    unittest.main()
