#!/usr/bin/env python3
"""Check bounded iOS Zero source adaptation; not native execution proof."""
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("prepare_zero_code_cache_test", HERE / "prepare-zero-code-cache.py")
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)

PREFIX = b"/* Copyright and license remain unchanged. */\n// Other memory reservations\n"
SUFFIX = b"\n// Heap and file mappings remain unchanged.\n"
SOURCE = PREFIX + cache.OLD_BLOCK + SUFFIX


def digest(data):
    return hashlib.sha256(data).hexdigest()


class ZeroCodeCacheTests(unittest.TestCase):
    def test_changes_only_the_unique_code_reservation(self):
        prepared = cache._adapt(SOURCE)
        self.assertEqual(prepared, PREFIX + cache.NEW_BLOCK + SUFFIX)
        self.assertEqual(prepared.count(cache.FUNCTION_ANCHOR), 1)
        self.assertNotIn(cache.OLD_BLOCK, prepared)

    def test_only_ios_zero_changes_executable_metadata(self):
        prepared = cache._adapt(SOURCE)
        guard = b"#if defined(__IOS__) && defined(ZERO)\n"
        self.assertEqual(prepared.count(guard), 1)
        before, conditional = prepared.split(guard)
        ios_zero, conditional = conditional.split(b"#else\n")
        other_targets, after = conditional.split(b"#endif\n")
        self.assertEqual(ios_zero, b"  constexpr bool executable = !ExecMem;\n")
        self.assertEqual(other_targets, b"  constexpr bool executable = ExecMem;\n")
        self.assertNotIn(b"#if", before + after)
        self.assertIn(b"                                 executable,\n                                 mtCode);", after)
        self.assertNotIn(b"MAP_JIT", prepared)
        self.assertNotIn(b"PROT_EXEC", prepared)

    def test_missing_duplicate_and_ambiguous_targets_rejected(self):
        candidates = [SOURCE.replace(cache.OLD_BLOCK, b""), SOURCE + cache.OLD_BLOCK,
                      SOURCE + cache.FUNCTION_ANCHOR + b"size_t different) {}\n",
                      SOURCE.replace(cache.OLD_BLOCK, cache.NEW_BLOCK)]
        for source in candidates:
            with self.subTest(source=source), self.assertRaises(ValueError):
                cache._adapt(source)

    def test_unknown_source_never_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = self.write_source(root, SOURCE + b"unexpected edit")
            original = target.read_bytes()
            with patch.object(cache, "TARGET_SOURCE_SHA256", digest(SOURCE)), self.assertRaisesRegex(ValueError, "source SHA-256 mismatch"):
                cache.prepare(root)
            self.assertEqual(target.read_bytes(), original)

    def test_prepared_hash_checked_before_writing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = self.write_source(root, SOURCE)
            with patch.multiple(cache, TARGET_SOURCE_SHA256=digest(SOURCE), PREPARED_SHA256="unexpected"), self.assertRaisesRegex(ValueError, "Prepared Zero code-cache SHA-256 mismatch"):
                cache.prepare(root)
            self.assertEqual(target.read_bytes(), SOURCE)

    def test_preparation_is_idempotent_and_rechecks_prepared_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = self.write_source(root, SOURCE)
            prepared = cache._adapt(SOURCE)
            with patch.multiple(cache, TARGET_SOURCE_SHA256=digest(SOURCE), PREPARED_SHA256=digest(prepared)):
                first = cache.prepare(root)
                self.assertTrue(first["changed"])
                self.assertFalse(first["enablesIOSJIT"])
                self.assertEqual(target.read_bytes(), prepared)
                with patch.object(Path, "write_bytes", side_effect=AssertionError("Idempotent preparation must not rewrite")):
                    self.assertFalse(cache.prepare(root)["changed"])
                target.write_bytes(prepared + b"unexpected edit")
                original = target.read_bytes()
                with self.assertRaisesRegex(ValueError, "source SHA-256 mismatch"):
                    cache.prepare(root)
                self.assertEqual(target.read_bytes(), original)

    def write_source(self, root, data):
        target = root / cache.TARGET_RELATIVE_PATH
        target.parent.mkdir(parents=True)
        target.write_bytes(data)
        return target


if __name__ == "__main__":
    unittest.main()
