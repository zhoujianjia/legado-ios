#!/usr/bin/env python3
"""Owned synthetic negative tests for the portable UMD fixture screen, not Swift execution."""
import copy
import importlib.util
import json
from pathlib import Path
import shutil
import struct
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("umd_fixture_screen", Path(__file__).with_name("inspect-umd-fixtures.py"))
SCREEN = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(SCREEN)
ROOT = Path(__file__).resolve().parents[2] / "Tests/iOS/yuedu appTests/Fixtures/UMD"

class UMDReferenceFixtureTests(unittest.TestCase):
    def setUp(self): self.original = (ROOT / "chinese-two-chapters/fixture.umd").read_bytes()
    def reject(self, data):
        with self.assertRaises((SCREEN.FixtureError, UnicodeDecodeError, __import__("zlib").error, struct.error)):
            SCREEN.walk(data)
    def records(self, data):
        result = []; pos = 4
        while pos < len(data):
            kind = int.from_bytes(data[pos + 1:pos + 3], "little") if data[pos] == 35 else None
            length = data[pos + 4] if kind is not None else int.from_bytes(data[pos + 5:pos + 9], "little")
            result.append((pos, kind, length)); pos += length
        return result
    def test_original_five_fixtures_and_fifteen_getters(self):
        result = SCREEN.inspect(ROOT)
        self.assertEqual((result["fixtures"], result["chapters"]), (5, 15))
        self.assertEqual((result["swiftExecuted"], result["iOSExecuted"]), (0, 0))
    def test_all_truncated_prefixes_rejected(self):
        for count in range(len(self.original)):
            with self.subTest(count=count): self.reject(self.original[:count])
    def test_image_nonzero_license_unknown_record(self):
        image = bytearray(self.original); image[9] = 2; self.reject(image)
        records = self.records(self.original)
        license_pos = next(pos for pos, kind, _ in records if kind == 241)
        license_data = bytearray(self.original); license_data[license_pos + 5] = 1; self.reject(license_data)
        unknown = bytearray(self.original); unknown[5] = 240; self.reject(unknown)
    def test_max_additional_length_and_bad_section_length(self):
        pos = next(pos for pos, kind, _ in self.records(self.original) if kind is None)
        data = bytearray(self.original); struct.pack_into("<I", data, pos + 5, 0xffffffff); self.reject(data)
        data = bytearray(self.original); data[8] = 4; self.reject(data)
    def test_wrong_offset_evenness_range_order(self):
        records = self.records(self.original); index = next(i for i, (_, kind, _) in enumerate(records) if kind == 131)
        payload = records[index + 1][0] + 9
        for delta, value in [(0, 2), (4, 3), (4, 0xffffffff)]:
            data = bytearray(self.original); struct.pack_into("<I", data, payload + delta, value); self.reject(data)
    def test_invalid_utf16_metadata(self):
        data = bytearray(self.original); data[17:19] = b"\x00\xd8"; self.reject(data)
    def test_zlib_wrapper_checksum_and_trailing_bytes(self):
        records = self.records(self.original); index = next(i for i, (_, kind, _) in enumerate(records) if kind == 132)
        pos, _, length = records[index + 2]
        for offset in (pos + 9, pos + length - 1):
            data = bytearray(self.original); data[offset] ^= 255; self.reject(data)
        data = bytearray(self.original); data.insert(pos + length, 0)
        struct.pack_into("<I", data, pos + 5, length + 1); struct.pack_into("<I", data, len(data) - 4, len(data)); self.reject(data)
    def test_declared_output_limit_and_actual_inflation_limit(self):
        pos = next(pos for pos, kind, _ in self.records(self.original) if kind == 11)
        for size in (2, 32 * 1024 * 1024 + 2):
            data = bytearray(self.original); struct.pack_into("<I", data, pos + 5, size); self.reject(data)
    def test_declared_end_size_and_tail(self):
        data = bytearray(self.original); struct.pack_into("<I", data, len(data) - 4, 0); self.reject(data)
        self.reject(self.original + b"x")
    def test_duplicate_json_and_nonfinite_rejected(self):
        for data in (b'{"id":1,"id":2}', b'{"id":NaN}', b'{"id":Infinity}'):
            with self.assertRaises(SCREEN.FixtureError): SCREEN.strict_json(data)
    def test_manifest_digest_or_identity_cannot_be_omitted(self):
        with tempfile.TemporaryDirectory(prefix="UMDOwnedGuard-") as temporary:
            target = Path(temporary) / "fixtures"; shutil.copytree(ROOT, target)
            data = json.loads((target / "provenance.json").read_bytes())
            data["files"].pop(); (target / "provenance.json").write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaises(SCREEN.FixtureError): SCREEN.inspect(target)
    def test_changed_fixture_bytes_rejected(self):
        with tempfile.TemporaryDirectory(prefix="UMDOwnedGuard-") as temporary:
            target = Path(temporary) / "fixtures"; shutil.copytree(ROOT, target)
            path = target / "chinese-two-chapters/fixture.umd"; path.write_bytes(path.read_bytes() + b"x")
            with self.assertRaises(SCREEN.FixtureError): SCREEN.inspect(target)

if __name__ == "__main__": unittest.main()
