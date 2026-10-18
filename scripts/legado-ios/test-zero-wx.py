#!/usr/bin/env python3
"""Portable checks for bounded source adaptation; not native compilation proof."""
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("prepare_zero_wx_test", HERE / "prepare-zero-wx.py")
wx = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wx)

LICENSE = b"/* Original copyright and license must remain byte-identical. */\n"
PREFIX = LICENSE + b"// Existing include\n" + wx.INCLUDE_ANCHOR + b"// Unrelated Zero implementation\n"
SUFFIX = b"\nvoid os::setup_fpu() {}\n"
HOOKS = b"""THREAD_LOCAL bool os::_jit_exec_enabled;
void os::current_thread_enable_wx(WXMode mode) {
  bool exec_enabled = mode != WXWrite;
#ifndef __IOS__
  permit_forbidden_function::pthread_jit_write_protect_np(exec_enabled);
#endif
  _jit_exec_enabled = exec_enabled;
}
bool Thread::wx_enable_write() {
  _wx_state = WXWrite;
  return true;
}
void os::thread_wx_enable_write_impl() {
  Thread::current()->wx_enable_write();
}
"""
TARGET = PREFIX + wx.OLD_BLOCK + SUFFIX
DONOR = LICENSE + wx.DEFAULT_MODE + b"\n#ifdef MACOS_AARCH64\n" + HOOKS + wx.DONOR_END + b"\n// Other backend code\n"


def digest(data): return hashlib.sha256(data).hexdigest()


class ZeroWXTests(unittest.TestCase):
    def test_changes_only_old_block_and_thread_include(self):
        prepared = wx._backport(TARGET, DONOR)
        expected = (PREFIX.replace(wx.INCLUDE_ANCHOR, wx.INCLUDE_ANCHOR + wx.THREAD_INCLUDE)
                    + b"#ifdef MACOS_AARCH64\n" + wx.DEFAULT_MODE + b"\n" + HOOKS + wx.DONOR_END + SUFFIX)
        self.assertEqual(prepared, expected)
        self.assertTrue(prepared.startswith(LICENSE))
        self.assertIn(b"#ifndef __IOS__\n  permit_forbidden_function::pthread_jit_write_protect_np", prepared)

    def test_incomplete_or_duplicate_blocks_rejected(self):
        for target, donor in [(TARGET + wx.OLD_BLOCK, DONOR),
                              (TARGET.replace(wx.OLD_BLOCK, b""), DONOR),
                              (TARGET, DONOR.replace(wx.REQUIRED_HOOKS[-1], b""))]:
            with self.subTest(target=target, donor=donor), self.assertRaises(ValueError):
                wx._backport(target, donor)

    def test_unknown_sources_never_overwrite_target(self):
        for change_donor in [False, True]:
            with self.subTest(change_donor=change_donor), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                target, donor = self.write_sources(root)
                if change_donor:
                    donor.write_bytes(DONOR + b"unknown edit")
                else:
                    target.write_bytes(TARGET + b"unknown edit")
                original = target.read_bytes()
                with patch.multiple(wx, TARGET_SOURCE_SHA256=digest(TARGET), DONOR_SOURCE_SHA256=digest(DONOR)), self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                    wx.prepare(root)
                self.assertEqual(target.read_bytes(), original)

    def test_expected_prepared_hash_checked_before_writing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target, _ = self.write_sources(root)
            with patch.multiple(wx, TARGET_SOURCE_SHA256=digest(TARGET), DONOR_SOURCE_SHA256=digest(DONOR), PREPARED_SHA256="unexpected"), self.assertRaisesRegex(ValueError, "Prepared Zero"):
                wx.prepare(root)
            self.assertEqual(target.read_bytes(), TARGET)

    def test_idempotent_and_still_rechecks_donor(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target, donor = self.write_sources(root)
            prepared = wx._backport(TARGET, DONOR)
            with patch.multiple(wx, TARGET_SOURCE_SHA256=digest(TARGET), DONOR_SOURCE_SHA256=digest(DONOR), PREPARED_SHA256=digest(prepared)):
                self.assertTrue(wx.prepare(root)["changed"])
                self.assertEqual(target.read_bytes(), prepared)
                with patch.object(Path, "write_bytes", side_effect=AssertionError("Idempotent preparation must not rewrite")):
                    self.assertFalse(wx.prepare(root)["changed"])
                donor.write_bytes(DONOR + b"changed after preparation")
                with self.assertRaisesRegex(ValueError, "donor SHA-256 mismatch"):
                    wx.prepare(root)
                self.assertEqual(target.read_bytes(), prepared)

    def test_exact_signal_successor_is_not_rewritten_and_still_requires_pinned_donor(self):
        self.assertEqual(wx.SIGNAL_PREPARED_SHA256,
                         "3eeff75065b744cb7943c28ccfb5d68511a6b3740f0c94d5314eb2b995cde6e3")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target, donor = self.write_sources(root)
            successor = wx._backport(TARGET, DONOR) + b"\n// Bounded signal successor fixture\n"
            target.write_bytes(successor)
            with patch.multiple(wx, TARGET_SOURCE_SHA256=digest(TARGET), DONOR_SOURCE_SHA256=digest(DONOR),
                                SIGNAL_PREPARED_SHA256=digest(successor)):
                with patch.object(Path, "write_bytes", side_effect=AssertionError("Successor must not be rewritten")):
                    self.assertFalse(wx.prepare(root)["changed"])
                self.assertEqual(target.read_bytes(), successor)
                donor.write_bytes(DONOR + b"changed after signal preparation")
                with self.assertRaisesRegex(ValueError, "donor SHA-256 mismatch"):
                    wx.prepare(root)
                self.assertEqual(target.read_bytes(), successor)
                donor.write_bytes(DONOR)
                target.write_bytes(successor + b"unknown edit")
                with self.assertRaisesRegex(ValueError, "Pinned Zero source SHA-256 mismatch"):
                    wx.prepare(root)
                self.assertEqual(target.read_bytes(), successor + b"unknown edit")

    def write_sources(self, root):
        target, donor = root / wx.TARGET_RELATIVE_PATH, root / wx.DONOR_RELATIVE_PATH
        target.parent.mkdir(parents=True)
        donor.parent.mkdir(parents=True)
        target.write_bytes(TARGET)
        donor.write_bytes(DONOR)
        return target, donor


if __name__ == "__main__": unittest.main()
