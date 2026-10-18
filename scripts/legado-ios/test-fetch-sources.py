#!/usr/bin/env python3
"""Check exact incremental source allowlists without fetching or building native code."""
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("fetch_sources_tested", HERE / "fetch-sources.py")
fetch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fetch)
ORIGIN = "https://github.com/openjdk/mobile.git"
REVISION = "c1ed06aaef34c8dccf71e236d1ffa20918a77cfb"
ZERO = "src/hotspot/os_cpu/bsd_zero/os_bsd_zero.cpp"
CACHE = "src/hotspot/share/memory/memoryReserver.cpp"
WX_BYTES = b"reviewed WX prepared test bytes"
SIGNAL_BYTES = b"reviewed WX and signal prepared test bytes"
CACHE_BYTES = b"reviewed code-cache prepared test bytes"


def digest(data):
    return hashlib.sha256(data).hexdigest()


class FetchSourcesTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.allowed = {ZERO: frozenset((digest(WX_BYTES), digest(SIGNAL_BYTES))),
                        CACHE: frozenset((digest(CACHE_BYTES),))}

    def source(self, relative, data):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def git_output(self, changes, origin=ORIGIN, revision=REVISION):
        def output(argv, **kwargs):
            command = argv[3:]
            if command == ["remote", "get-url", "origin"]:
                return origin + "\n"
            if command == ["status", "--porcelain"]:
                return changes
            if command == ["rev-parse", "HEAD"]:
                return revision + "\n"
            self.fail("Unexpected git read: " + repr(argv))
        return output

    def test_closed_allowlist_contains_only_three_reviewed_outputs_from_fixed_stages(self):
        self.assertEqual(fetch.prepared_edits(), {
            ZERO: frozenset(("702ba78cb0c9c19e0c178d2dd34479b2a03ff2aa3c43de903755c3d49b866dcc",
                             "3eeff75065b744cb7943c28ccfb5d68511a6b3740f0c94d5314eb2b995cde6e3")),
            CACHE: frozenset(("b48140304e19ed5951fb19fd377ef911cf43690bc50088b7b7c9192f3355d582",))})

    def test_each_reviewed_prepared_state_is_accepted_without_rewriting_source(self):
        # Local synthetic bytes exercise matching; the preceding test locks the
        # actual production hash metadata. All git subprocesses are mocked.
        for zero in (WX_BYTES, SIGNAL_BYTES):
            self.source(ZERO, zero)
            self.source(CACHE, CACHE_BYTES)
            changes = " M " + ZERO + "\n M " + CACHE + "\n"
            with self.subTest(zero=zero), patch.object(fetch.subprocess, "check_output", side_effect=self.git_output(changes)), \
                    patch.object(fetch.subprocess, "run") as run:
                fetch.checkout(ORIGIN, REVISION, self.root, self.allowed)
            self.assertEqual([call.args[0][3:] for call in run.call_args_list],
                             [["fetch", "--depth=1", "origin", REVISION], ["checkout", "--detach", REVISION]])
            self.assertEqual((self.root / ZERO).read_bytes(), zero)
            self.assertEqual((self.root / CACHE).read_bytes(), CACHE_BYTES)

    def test_unknown_bytes_unknown_paths_and_hash_strings_are_rejected_before_fetch(self):
        bad = [(ZERO, SIGNAL_BYTES + b"unreviewed edit", self.allowed),
               (CACHE, WX_BYTES, self.allowed),
               ("src/hotspot/unreviewed.cpp", SIGNAL_BYTES, self.allowed),
               (ZERO, SIGNAL_BYTES, {ZERO: digest(SIGNAL_BYTES)}),
               (ZERO, SIGNAL_BYTES, {ZERO: "prefix" + digest(SIGNAL_BYTES) + "suffix"})]
        for relative, data, allowed in bad:
            self.source(relative, data)
            with self.subTest(relative=relative, allowed=allowed), \
                    patch.object(fetch.subprocess, "check_output", side_effect=self.git_output(" M " + relative + "\n")), \
                    patch.object(fetch.subprocess, "run") as run:
                with self.assertRaisesRegex(ValueError, "Source checkout contains edits"):
                    fetch.checkout(ORIGIN, REVISION, self.root, allowed)
            run.assert_not_called()
            self.assertEqual((self.root / relative).read_bytes(), data)

    def test_symlink_is_rejected_before_fetch_even_when_target_bytes_are_reviewed(self):
        path = self.source(ZERO, SIGNAL_BYTES)
        # Avoid platform-specific symlink creation privileges on Windows while
        # exercising the same Path.is_symlink boundary used by checkout.
        with patch.object(Path, "is_symlink", autospec=True, side_effect=lambda p: p == path), \
                patch.object(fetch.subprocess, "check_output", side_effect=self.git_output(" M " + ZERO + "\n")), \
                patch.object(fetch.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "Source checkout contains edits"):
                fetch.checkout(ORIGIN, REVISION, self.root, self.allowed)
        run.assert_not_called()

    def test_wrong_origin_rejected_before_status_or_fetch_and_wrong_commit_still_rejected(self):
        with patch.object(fetch.subprocess, "check_output", side_effect=self.git_output("", origin="https://invalid.example/mobile.git")) as read, \
                patch.object(fetch.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "Source origin mismatch"):
                fetch.checkout(ORIGIN, REVISION, self.root, self.allowed)
        self.assertEqual(read.call_count, 1)
        run.assert_not_called()
        with patch.object(fetch.subprocess, "check_output", side_effect=self.git_output("", revision="0" * 40)), \
                patch.object(fetch.subprocess, "run"):
            with self.assertRaisesRegex(ValueError, "Source revision mismatch"):
                fetch.checkout(ORIGIN, REVISION, self.root, self.allowed)


if __name__ == "__main__":
    unittest.main()
