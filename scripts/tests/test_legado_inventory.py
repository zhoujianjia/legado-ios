"""Regression tests for archive identity, evidence, safety and reproducibility."""

import importlib.util
import stat
import tempfile
import unittest
import warnings
import zipfile
from pathlib import Path


SPEC = importlib.util.spec_from_file_location(
    "legado_inventory", Path(__file__).resolve().parents[1] / "legado-inventory.py"
)
inventory = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(inventory)


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.archive = self.directory / "source.zip"
        self.source_path = "legado-master/app/src/main/java/example/Engine.kt"
        self.source = b"package example\n\nobject Engine {\n    fun run() = 42\n}\n"
        self.catalogue = {"features": [{
            "id": "core.example", "phase": "core", "behavior": "Example function",
            "ios_mapping": "Native adapter", "acceptance": "Returns 42",
            "evidence": [{"path": self.source_path, "contains": "fun run()"}],
        }]}
        self.write_archive([(self.source_path, self.source)])

    def write_archive(self, entries):
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(self.archive, "w") as output:
                for name, data in entries:
                    output.writestr(name, data)
                output.comment = b"fixture-revision"
        self.lock = {
            "legado": {"sha256": inventory.sha256(self.archive.read_bytes()),
                       "zip_comment": "fixture-revision", "origin": "test fixture"},
            "yuedu": {"commit": "test-baseline"},
        }

    def build(self):
        return inventory.build_inventory(self.archive, self.lock, self.catalogue)

    def test_reports_actual_evidence_lines_and_hashes(self):
        result = self.build()
        self.assertEqual(result["features"][0]["evidence"][0]["line"], 4)
        self.assertEqual(result["files"][0]["sha256"], inventory.sha256(self.source))
        self.assertEqual(result["features"][0]["status"], "pending_ios_parity_validation")
        self.assertEqual([(d["name"], d["line"]) for d in result["kotlin_main_declarations"]],
                         [("Engine", 3), ("run", 4)])

    def test_is_deterministic_and_never_extracts_archive(self):
        before = set(self.directory.rglob("*"))
        self.assertEqual(inventory.json_bytes(self.build()), inventory.json_bytes(self.build()))
        self.assertEqual(inventory.markdown(self.build()), inventory.markdown(self.build()))
        self.assertEqual(set(self.directory.rglob("*")), before)

    def test_archive_hash_mismatch_is_rejected_before_source_use(self):
        self.lock["legado"]["sha256"] = "0" * 64
        with self.assertRaisesRegex(inventory.InventoryError, "SHA-256 mismatch"):
            self.build()

    def test_locked_engine_bytes_are_verified(self):
        self.lock["engine"] = {"archive_artifacts": [{
            "path": self.source_path, "sha256": "0" * 64,
        }]}
        with self.assertRaisesRegex(inventory.InventoryError, "locked engine artifact"):
            self.build()

    def test_size_limit_rejects_before_reading_entry(self):
        previous = inventory.MAX_ENTRY_BYTES
        self.addCleanup(setattr, inventory, "MAX_ENTRY_BYTES", previous)
        inventory.MAX_ENTRY_BYTES = 1
        with self.assertRaisesRegex(inventory.InventoryError, "size limit"):
            self.build()

    def test_zip_revision_hint_must_match_locked_comment(self):
        self.lock["legado"]["zip_comment"] = "different-revision"
        with self.assertRaisesRegex(inventory.InventoryError, "ZIP comment"):
            self.build()

    def test_missing_evidence_does_not_silently_generate_a_row(self):
        self.catalogue["features"][0]["evidence"][0]["contains"] = "missingFunction"
        with self.assertRaisesRegex(inventory.InventoryError, "evidence anchor"):
            self.build()

    def test_duplicate_paths_and_feature_ids_are_rejected(self):
        self.catalogue["features"].append(dict(self.catalogue["features"][0]))
        with self.assertRaisesRegex(inventory.InventoryError, "duplicate feature ID"):
            self.build()
        self.write_archive([(self.source_path, self.source), (self.source_path, self.source)])
        with self.assertRaisesRegex(inventory.InventoryError, "duplicate archive path"):
            self.build()

    def test_unsafe_paths_are_rejected(self):
        for path in ("../outside.kt", "/absolute.kt", "C:/drive.kt", "safe\\..\\outside.kt", "safe/./file.kt"):
            with self.subTest(path=path):
                self.write_archive([(path, b"unused")])
                with self.assertRaisesRegex(inventory.InventoryError, "unsafe archive path"):
                    self.build()

    def test_symbolic_links_are_rejected(self):
        link = zipfile.ZipInfo("legado-master/link")
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        self.write_archive([(link, b"../../outside")])
        with self.assertRaisesRegex(inventory.InventoryError, "symbolic link"):
            self.build()

    def test_check_mode_fails_for_stale_output_without_writing(self):
        lock_file, catalogue_file = self.directory / "lock.json", self.directory / "catalogue.json"
        lock_file.write_bytes(inventory.json_bytes(self.lock))
        catalogue_file.write_bytes(inventory.json_bytes(self.catalogue))
        output = self.directory / "output"
        arguments = ["--archive", str(self.archive), "--lock", str(lock_file),
                     "--catalogue", str(catalogue_file), "--output", str(output)]
        self.assertEqual(inventory.main(arguments), 0)
        self.assertEqual(inventory.main(arguments + ["--check"]), 0)
        target = output / "inventory.json"
        target.write_text("stale", encoding="utf-8")
        self.assertEqual(inventory.main(arguments + ["--check"]), 1)
        self.assertEqual(target.read_text(encoding="utf-8"), "stale")

    def test_mcp_inventory_uses_tool_registration_not_other_names(self):
        path = "legado-master/app/src/main/java/io/legado/app/web/mcp/McpToolServer.kt"
        text = b'name = "server"\nserver.addTool(\n name = "get_source",\n)\nserver.addTool(name = "eval_js")\n'
        self.write_archive([(self.source_path, self.source), (path, text)])
        self.assertEqual([(tool["name"], tool["line"]) for tool in self.build()["mcp_tools"]],
                         [("get_source", 2), ("eval_js", 5)])


if __name__ == "__main__":
    unittest.main()
