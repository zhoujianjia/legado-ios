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
            raw = bytes.fromhex("cafebabe00000048") + name.encode("ascii")
            cls.expected[name] = raw
        cls.expected["java.base/example/empty.dat"] = b""
        cls.expected["java.base/example/payload.dat"] = bytes(range(256)) * 97
        cls.expected["java.base/example/\u8bfb\U0001f4d6.txt"] = b"modified-UTF8 filename"
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
        for name, raw in self.expected.items():
            self.assertEqual(image.content(image.by_name["/" + name]), raw)
        self.assertEqual(self.report["moduleCount"], 13)
        self.assertEqual(self.report["moduleDescriptorCount"], 13)
        self.assertTrue(self.report["allResourceBytesPreserved"])
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


if __name__ == "__main__":
    unittest.main()
