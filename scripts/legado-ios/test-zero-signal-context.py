#!/usr/bin/env python3
"""Check bounded signal-PC source adaptation, not native or TLS execution."""
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("prepare_zero_signal_context_test", HERE / "prepare-zero-signal-context.py")
signal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signal)

LICENSE = b"/* Original copyright and GPL license stay byte-identical. */\n"
PREFIX = LICENSE + b"// Existing includes and Zero methods.\n"
SUFFIX = b"\n// Signal handler, W^X hooks and all other methods stay unchanged.\n"
TARGET = PREFIX + signal.OLD_BLOCK + SUFFIX
DONOR = (LICENSE + b"#ifdef __APPLE__\n" + b"".join(signal.DONOR_MACROS)
         + b"#endif\n" + signal.DONOR_GETTER + b"\n\n" + signal.DONOR_SETTER + b"\n")


def digest(data):
    return hashlib.sha256(data).hexdigest()


class ZeroSignalContextTests(unittest.TestCase):
    def test_only_unique_pc_stubs_change_and_license_stays_identical(self):
        prepared = signal._backport(TARGET, DONOR)
        replacement = (b"#ifdef MACOS_AARCH64\n" + b"".join(signal.DONOR_MACROS) + b"\n"
                       + signal.DONOR_GETTER + b"\n\n" + signal.DONOR_SETTER
                       + b"\n#else\n" + signal.OLD_BLOCK + b"\n#endif // MACOS_AARCH64")
        self.assertEqual(prepared, PREFIX + replacement + SUFFIX)
        self.assertEqual(prepared[:len(LICENSE)], LICENSE)

    def test_only_apple_arm64_uses_real_context_access_other_targets_keep_stubs(self):
        prepared = signal._backport(TARGET, DONOR)
        before, branches = prepared.split(b"#ifdef MACOS_AARCH64\n")
        apple_arm64, branches = branches.split(b"#else\n")
        other_targets, after = branches.split(b"#endif // MACOS_AARCH64")
        self.assertEqual(before, PREFIX)
        self.assertEqual(after, SUFFIX)
        self.assertEqual(other_targets, signal.OLD_BLOCK + b"\n")
        for definition in (*signal.DONOR_MACROS, signal.DONOR_GETTER, signal.DONOR_SETTER):
            self.assertEqual(apple_arm64.count(definition), 1)
        self.assertNotIn(b"ShouldNotCallThis", apple_arm64)
        self.assertNotIn(b"#define", other_targets)

    def test_missing_duplicate_or_ambiguous_target_is_rejected(self):
        candidates = [TARGET.replace(signal.OLD_BLOCK, b""), TARGET + signal.OLD_BLOCK,
                      TARGET + signal.GETTER_ANCHOR, TARGET + signal.SETTER_ANCHOR,
                      TARGET + signal.DONOR_MACROS[0], TARGET + signal.DONOR_MACROS[1]]
        for target in candidates:
            with self.subTest(target=target), self.assertRaises(ValueError):
                signal._backport(target, DONOR)

    def test_donor_missing_duplicate_or_incomplete_definitions_are_rejected(self):
        for definition in (*signal.DONOR_MACROS, signal.DONOR_GETTER, signal.DONOR_SETTER):
            for donor in [DONOR.replace(definition, b""), DONOR + definition]:
                with self.subTest(definition=definition, donor=donor), self.assertRaises(ValueError):
                    signal._backport(TARGET, donor)
        for anchor in [signal.GETTER_ANCHOR, signal.SETTER_ANCHOR, b"#define DU3_PREFIX", b"#define context_pc"]:
            with self.subTest(anchor=anchor), self.assertRaises(ValueError):
                signal._backport(TARGET, DONOR + anchor)

    def test_unknown_target_or_donor_never_overwrites_target(self):
        for change_donor in [False, True]:
            with self.subTest(change_donor=change_donor), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                target, donor = self.write_sources(root)
                changed = donor if change_donor else target
                changed.write_bytes(changed.read_bytes() + b"unexpected source edit")
                original = target.read_bytes()
                with self.expected_hashes(), self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                    signal.prepare(root)
                self.assertEqual(target.read_bytes(), original)

    def test_output_digest_is_checked_before_writing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target, _ = self.write_sources(root)
            with self.expected_hashes(), patch.object(signal, "PREPARED_SHA256", "unexpected"), self.assertRaisesRegex(ValueError, "Prepared Zero signal-PC SHA-256 mismatch"):
                signal.prepare(root)
            self.assertEqual(target.read_bytes(), TARGET)

    def test_idempotent_no_write_and_donor_still_rechecked(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target, donor = self.write_sources(root)
            with self.expected_hashes():
                first = signal.prepare(root)
                self.assertTrue(first["changed"])
                self.assertFalse(first["changesSignalHandler"])
                self.assertFalse(first["enablesIOSJIT"])
                self.assertFalse(first["provesTLS"])
                prepared = target.read_bytes()
                with patch.object(Path, "write_bytes", side_effect=AssertionError("Idempotent preparation must not rewrite")):
                    self.assertFalse(signal.prepare(root)["changed"])
                donor.write_bytes(DONOR + b"unexpected donor edit")
                with self.assertRaisesRegex(ValueError, "donor SHA-256 mismatch"):
                    signal.prepare(root)
                self.assertEqual(target.read_bytes(), prepared)

    def test_modified_prepared_source_is_rejected_without_write(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target, _ = self.write_sources(root)
            with self.expected_hashes():
                signal.prepare(root)
                target.write_bytes(target.read_bytes() + b"unexpected prepared edit")
                original = target.read_bytes()
                with self.assertRaisesRegex(ValueError, "source SHA-256 mismatch"):
                    signal.prepare(root)
                self.assertEqual(target.read_bytes(), original)

    def expected_hashes(self):
        return patch.multiple(signal, TARGET_SOURCE_SHA256=digest(TARGET),
                              DONOR_SOURCE_SHA256=digest(DONOR),
                              PREPARED_SHA256=digest(signal._backport(TARGET, DONOR)))

    def write_sources(self, root):
        target, donor = root / signal.TARGET_RELATIVE_PATH, root / signal.DONOR_RELATIVE_PATH
        target.parent.mkdir(parents=True)
        donor.parent.mkdir(parents=True)
        target.write_bytes(TARGET)
        donor.write_bytes(DONOR)
        return target, donor


if __name__ == "__main__":
    unittest.main()
