import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("data_smoke_tested", Path(__file__).with_name("data-smoke-tools.py"))
data = importlib.util.module_from_spec(spec)
spec.loader.exec_module(data)


class SourceDataEvidenceTests(unittest.TestCase):
    def test_only_current_source_tag_is_accepted(self):
        source = "a" * 40
        with patch.object(data.smoke, "source_sha", return_value=source):
            for sha, tag in [(source, "legado-reader-data-aaaaaaa"),
                             (source, "reader-smoke-aaaaaaa"), ("b" * 40, "legado-reader-data-aaaaaaa")]:
                with patch.dict(os.environ, {"GITHUB_SHA": sha, "GITHUB_REF_NAME": tag}):
                    if sha == source and tag == "legado-reader-data-aaaaaaa":
                        self.assertEqual(data.validate_tag(), source)
                    else:
                        with self.assertRaises(ValueError):
                            data.validate_tag()

    def test_package_xml_requires_every_test_without_skips_or_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "tests.xml"
            for cases, valid in [("<testcase/><testcase/>", True), ("", False),
                                 ("<testcase/>", False), ("<testcase/><testcase><skipped/></testcase>", False),
                                 ("<testcase/><testcase><failure/></testcase>", False),
                                 ("<testcase/><testcase><error/></testcase>", False)]:
                path.write_text("<testsuites><testsuite>" + cases + "</testsuite></testsuites>", encoding="utf-8")
                if valid:
                    self.assertEqual(data.verify_xml(path, 2)["executed"], 2)
                else:
                    with self.assertRaises(ValueError):
                        data.verify_xml(path, 2)

    def test_private_module_keeps_original_smoke_tag_contract(self):
        original = data.smoke.validate_tag
        source = "a" * 40
        with patch.object(data.smoke, "source_sha", return_value=source), \
                patch.dict(os.environ, {"GITHUB_SHA": source, "GITHUB_REF_NAME": "legado-reader-data-aaaaaaa"}):
            with self.assertRaises(ValueError):
                original()


if __name__ == "__main__":
    unittest.main()
