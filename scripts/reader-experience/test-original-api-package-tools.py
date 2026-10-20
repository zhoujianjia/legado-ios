#!/usr/bin/env python3
"""Portable guards for source-only package evidence; never runs Swift or Git."""
import copy
from contextlib import ExitStack
import importlib.util
import json
import os
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("original_api_package_guard_tests", HERE / "original-api-package-tools.py")
api = importlib.util.module_from_spec(spec)
spec.loader.exec_module(api)
SHA = "a" * 40


class OriginalAPIPackageEvidenceTests(unittest.TestCase):
    def setUp(self):
        # Each fixture starts in the original ten-case mode. CI's currentcore
        # selection must only apply inside tests that explicitly select it.
        selection = patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": "all", "YUEDU_RENEWAL_PACKAGE_SELECTION": ""})
        selection.start()
        self.addCleanup(selection.stop)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.work = self.root / ".build/package-evidence"
        self.developer = self.root / "Xcode.app/Contents/Developer"
        self.swift = self.developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
        self.write(self.swift, b"synthetic tool handle; never executed")
        self.originals = {path: ("source fixture: " + path).encode() for path in api.SOURCE_INPUTS}
        for path, data in self.originals.items():
            self.write(self.root / path, data)
        self.env = {"GITHUB_SHA": SHA, "GITHUB_REF_NAME": "reader-renewal-" + SHA[:7],
                    "LEGADO_RUNTIME_SOURCE_ONLY": "1", "DEVELOPER_DIR": str(self.developer),
                    "_SWIFTPM_SKIP_TESTS_LIST": ""}

    def write(self, path, raw):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)

    def write_json(self, name, value):
        self.write(self.work / name, json.dumps(value).encode())

    def git(self, *args, binary=False):
        if args == ("rev-parse", "HEAD"):
            return SHA
        if args[0] == "show":
            return self.originals[args[1].removeprefix("HEAD:")]
        raise AssertionError(args)

    def context(self):
        stack = ExitStack()
        stack.enter_context(patch.object(api, "REPO", self.root))
        stack.enter_context(patch.object(api.smoke, "REPO", self.root))
        stack.enter_context(patch.object(api.smoke, "git", side_effect=self.git))
        stack.enter_context(patch.dict(os.environ, self.env))
        return stack

    def xml(self):
        root = ET.Element("testsuites")
        suite = ET.SubElement(root, "testsuite", name="TestResults", tests=str(len(api.expected_cases())), errors="0", failures="0")
        for case in sorted(api.expected_cases()):
            classname, method = case.split("/")
            ET.SubElement(suite, "testcase", classname=classname, name=method, time="0.01")
        return ET.tostring(root)

    def log(self, dot=False):
        lines = []
        for case in sorted(api.expected_cases()):
            classname, method = case.split("/")
            leaf = classname + "." + method if dot else "-[" + classname + " " + method + "]"
            lines.append("Test Case '" + leaf + "' passed (0.01 seconds).")
        return "\n".join(lines) + "\n"

    def built(self):
        inputs = api.prepare(self.work)
        self.write(self.work / "swift-executable.log", (str(self.swift) + "\n").encode())
        self.write(self.work / "swift-version.log", b"Apple Swift version 6.3.1\nTarget: arm64-apple-macosx26.0\n")
        self.write(self.work / "swift-test-help.log", ("SwiftPM help: " + " ".join(api.REQUIRED_FLAGS)).encode())
        self.write(self.work / "tests.log", self.log().encode())
        self.write(self.work / "xunit.xml", self.xml())
        self.write_json("execution.json", {"arguments": api.test_command(str(self.swift), self.work),
            "developerDirectory": str(self.developer), "runtimeSourceOnly": True,
            "exitCode": 0, "timedOut": False, "completed": True})
        return inputs

    def test_valid_xml_and_each_verbose_xctest_leaf_are_both_required(self):
        with self.context():
            inputs = self.built()
            result = api.result(self.work)
            self.assertEqual(len(inputs["sourceInputs"]), 22)
            self.assertEqual(inputs["packageSourceInputCount"], 15)
            self.assertEqual(result["passedCaseIdentifiers"], sorted(api.EXPECTED))
            self.assertEqual(result["verbosePassedCaseIdentifiers"], sorted(api.EXPECTED))
            self.assertEqual(result["totalTestCount"], 10)
            for key in ("jvmExecuted", "physicalDeviceValidationPassed", "selfRenewalVerified", "unattendedRenewalVerified"):
                self.assertIs(result[key], False)
            self.assertEqual(set(result["evidenceSHA256"]), set(api.EVIDENCE))
            self.write(self.work / "tests.log", self.log(dot=True).encode())
            self.assertEqual(api.result(self.work)["passedCaseIdentifiers"], sorted(api.EXPECTED))

    def test_exact_qualified_xml_rejects_missing_extra_duplicates_and_false_outcomes(self):
        mutations = []
        for attribute in ("failures", "errors", "skipped", "disabled"):
            mutations.append(lambda root, a=attribute: root[0].set(a, "1"))
        mutations += [lambda root: root[0].remove(root[0][0]),
                      lambda root: root[0].append(copy.deepcopy(root[0][0])),
                      lambda root: root[0][0].set("classname", "Other.LegadoOriginalAPITests"),
                      lambda root: root[0][0].set("name", "testUnselected"),
                      lambda root: root[0][0].set("status", "notrun"),
                      lambda root: root[0].set("tests", "true")]
        for outcome in ("skipped", "failure", "error"):
            mutations.append(lambda root, tag=outcome: ET.SubElement(root[0][0], tag))
        for mutation in mutations:
            root = ET.fromstring(self.xml()); mutation(root)
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                api.verify_xml(ET.tostring(root))
        for raw in (b"", b"<testsuites>", b"<!DOCTYPE x><testsuites/>", self.xml().decode().encode("utf-16")):
            with self.subTest(raw=raw[:30]), self.assertRaises(ValueError):
                api.verify_xml(raw)

    def test_summary_only_log_and_skipped_failed_duplicate_or_unqualified_cases_fail(self):
        good = self.log()
        bad = ["Executed 10 tests with 0 failures; passed", "\n".join(good.splitlines()[1:]), good + good.splitlines()[0],
               good.replace(" passed ", " skipped ", 1), good.replace(" passed ", " failed ", 1),
               good.replace("LegadoRuntimeTests.LegadoOriginalAPITests", "LegadoOriginalAPITests", 1),
               good.replace("LegadoRuntimeTests.LegadoOriginalAPITests", "Wrong.LegadoOriginalAPITests", 1)]
        for text in bad:
            with self.subTest(text=text[:70]), self.assertRaises(ValueError):
                api.verify_verbose_log(text)
        with self.context():
            self.built(); (self.work / "xunit.xml").unlink()
            with self.assertRaises(ValueError):
                api.result(self.work)

    def test_package_and_guard_sources_are_head_matched_and_immutable_after_prepare(self):
        with self.context():
            for path in api.SOURCE_INPUTS:
                self.write(self.root / path, b"changed input")
                with self.subTest(path=path), self.assertRaisesRegex(ValueError, "checked-out HEAD"):
                    api.prepare(self.work)
                self.assertFalse((self.work / "source-inputs.json").exists())
                self.write(self.root / path, self.originals[path])
            self.built()
            self.write(self.root / api.PACKAGE_INPUTS[3], b"changed after test")
            with self.assertRaises(ValueError):
                api.result(self.work)

    def test_new_unbound_compiled_files_missing_files_and_links_cannot_enter_the_closure(self):
        with self.context():
            extra = self.root / api.PACKAGE / "Sources/LegadoRuntime/Unreviewed.swift"
            self.write(extra, b"struct Unreviewed {}")
            with self.assertRaisesRegex(ValueError, "closure"):
                api.prepare(self.work)
            extra.unlink()
            target = self.root / api.PACKAGE_INPUTS[4]
            target.unlink()
            with self.assertRaisesRegex(ValueError, "closure"):
                api.prepare(self.work)
            self.write(target, self.originals[api.PACKAGE_INPUTS[4]])
            original = Path.is_symlink
            with patch.object(Path, "is_symlink", lambda path: path == target or original(path)), self.assertRaisesRegex(ValueError, "links"):
                api.prepare(self.work)

    def test_prepare_result_identity_filter_manifest_and_json_types_cannot_change(self):
        with self.context():
            inputs = self.built()
            mutations = [("selectionMode", "boundmaterials"), ("sourceCommit", "b" * 40),
                         ("filter", ".*"), ("parallelWorkers", True), ("runtimeSourceOnly", 1), ("schemaVersion", True)]
            for key, value in mutations:
                altered = {**inputs, key: value}; self.write_json("source-inputs.json", altered)
                with self.subTest(key=key), self.assertRaisesRegex(ValueError, "prepare/result"):
                    api.result(self.work)
            for key in ("sourceInputs", "qualifiedXCTestMethods"):
                altered = copy.deepcopy(inputs); altered[key].pop(); self.write_json("source-inputs.json", altered)
                with self.subTest(key=key), self.assertRaisesRegex(ValueError, "prepare/result"):
                    api.result(self.work)
            self.write_json("source-inputs.json", inputs)
            self.write(self.work / "source-inputs.json", b'{"schemaVersion": 1,"schemaVersion": 1}')
            with self.assertRaisesRegex(ValueError, "Duplicate"):
                api.result(self.work)

    def test_runtime_mode_tag_developer_directory_and_skip_overrides_fail_before_preparing(self):
        changes = ({"LEGADO_RUNTIME_SOURCE_ONLY": "0"}, {"LEGADO_RUNTIME_SOURCE_ONLY": ""},
                   {"GITHUB_SHA": "b" * 40}, {"GITHUB_REF_NAME": "reader-smoke-aaaaaaa"},
                   {"DEVELOPER_DIR": "relative/path"}, {"DEVELOPER_DIR": ""},
                   {"_SWIFTPM_SKIP_TESTS_LIST": "one-case"})
        with self.context():
            for change in changes:
                with self.subTest(change=change), patch.dict(os.environ, change), self.assertRaises(ValueError):
                    api.prepare(self.work)
                self.assertFalse(self.work.exists())
            self.built()
            with self.assertRaisesRegex(ValueError, "prior"):
                api.prepare(self.work)

    def test_real_command_status_and_serial_xctest_configuration_are_required(self):
        with self.context():
            self.built(); original = json.loads((self.work / "execution.json").read_text())
            changes = [{"exitCode": 1}, {"exitCode": False}, {"exitCode": 0.0}, {"completed": 1},
                       {"completed": False}, {"timedOut": True}, {"timedOut": 0}, {"runtimeSourceOnly": 1}]
            args = original["arguments"]
            changes += [{"arguments": [arg for arg in args if arg != "--disable-swift-testing"]},
                        {"arguments": [arg for arg in args if arg != "--parallel"]},
                        {"arguments": ["2" if arg == "1" else arg for arg in args]},
                        {"arguments": [".*" if arg == api.FILTER else arg for arg in args]}]
            for change in changes:
                self.write_json("execution.json", {**original, **change})
                with self.subTest(change=change), self.assertRaisesRegex(ValueError, "execution command"):
                    api.result(self.work)

    def test_actual_toolchain_version_help_and_evidence_files_cannot_be_missing_or_replaced(self):
        with self.context():
            self.built()
            for name in api.EVIDENCE:
                path = self.work / name; original = path.read_bytes(); path.unlink()
                with self.subTest(name=name), self.assertRaises(ValueError): api.result(self.work)
                self.write(path, original)
            for version in (b"", b"Swift version 5.10\nTarget: arm64-apple-macosx14.0", b"Swift version 6.3\nTarget: x86_64-unknown-linux"):
                self.write(self.work / "swift-version.log", version)
                with self.subTest(version=version), self.assertRaises(ValueError): api.result(self.work)
            self.write(self.work / "swift-version.log", b"Apple Swift version 6.3\nTarget: arm64-apple-macosx26.0")
            self.write(self.work / "swift-test-help.log", b"--parallel --num-workers --filter --verbose --xunit-output")
            with self.assertRaisesRegex(ValueError, "flags"): api.result(self.work)
            self.write(self.work / "swift-test-help.log", " ".join(api.REQUIRED_FLAGS).encode())
            self.write(self.work / "swift-executable.log", b"/different/SDK/usr/bin/swift")
            with self.assertRaisesRegex(ValueError, "toolchain"): api.result(self.work)

    def test_xml_log_byte_budgets_and_non_darwin_execution_remain_explicit(self):
        with self.context():
            self.built()
            with (self.work / "tests.log").open("wb") as handle: handle.truncate(16_777_217)
            with self.assertRaisesRegex(ValueError, "bounded"): api.result(self.work)
            with patch.object(api.sys, "platform", "win32"), self.assertRaisesRegex(ValueError, "requires macOS"):
                api.run(self.work)

    def test_exact_filter_matches_reviewed_methods_and_rejects_every_broadened_identity(self):
        self.assertEqual(len(api.EXPECTED), 10)
        for case in api.EXPECTED:
            self.assertIsNotNone(re.fullmatch(api.FILTER, case))
            self.assertIsNone(re.fullmatch(api.FILTER, "prefix" + case))
            self.assertIsNone(re.fullmatch(api.FILTER, case + "Suffix"))
        actual = set()
        for suite, methods in api.SUITES.items():
            text = (HERE.parents[1] / api.PACKAGE / "Tests/LegadoRuntimeTests" / (suite + ".swift")).read_text(encoding="utf-8")
            declarations = re.findall(r"\bfunc\s+(test\w+)\s*\(", text)
            for method in methods:
                self.assertEqual(declarations.count(method), 1)
                actual.add("LegadoRuntimeTests." + suite + "/" + method)
        self.assertEqual(actual, api.EXPECTED)

    def test_workflow_keeps_package_evidence_separate_and_has_no_binary_upload(self):
        wrapper = (HERE / "original-api-package-tests.sh").read_text(encoding="utf-8")
        self.assertIn('LEGADO_RUNTIME_SOURCE_ONLY', wrapper)
        self.assertIn('DEVELOPER_DIR', wrapper)
        self.assertNotIn('swift test', wrapper)
        workflow = (HERE.parents[1] / ".github/workflows/reader-renewal-probe.yml").read_text(encoding="utf-8")
        self.assertIn('bash scripts/reader-experience/original-api-package-tests.sh', workflow)
        self.assertIn('.build/reader-renewal-original-api/', workflow)
        self.assertIn('reader-renewal-original-api-evidence', workflow)
        self.assertNotIn('Packages/LegadoRuntime/.build', workflow)


    def test_currentcore_requires_six_new_methods_and_all_fifteen_compilation_sources(self):
        with self.context(),patch.dict(os.environ,{'YUEDU_RENEWAL_SELECTION':'currentcore'}):
            inputs=self.built();result=api.result(self.work)
            self.assertEqual(inputs['selectionMode'],'original-api-package-currentcore')
            self.assertEqual(len(inputs['sourceInputs']),22)
            self.assertEqual(inputs['packageSourceInputCount'],15)
            self.assertEqual(len(api.expected_cases()),16)
            self.assertEqual(result['totalTestCount'],16)
            self.assertEqual(set(result['passedCaseIdentifiers']),api.CURRENTCORE_EXPECTED)
            for case in api.CURRENTCORE_EXPECTED:self.assertIsNotNone(re.fullmatch(api.selected_filter(),case))
            self.assertEqual(len(api.EXPECTED),10)
            for suite,names in api.CURRENTCORE_SUITES.items():
                source=(HERE.parents[1]/api.PACKAGE/'Tests/LegadoRuntimeTests'/(suite+'.swift')).read_text(encoding='utf8')
                self.assertEqual(set(names),set(re.findall(r'\bfunc\s+(test\w+)\s*\(',source)))
            original=(self.work/'xunit.xml').read_bytes()
            root=ET.fromstring(original);suite=root.find('testsuite')
            cases=list(suite);suite.remove(cases[-1]);suite.set('tests','15')
            self.write(self.work/'xunit.xml',ET.tostring(root))
            with self.assertRaises(ValueError):api.result(self.work)
            self.write(self.work/'xunit.xml',original)
            with patch.dict(os.environ,{'YUEDU_RENEWAL_SELECTION':'handoffrenewal'}),self.assertRaises(ValueError):api.result(self.work)

    def test_currentcore_rejects_new_source_control_and_verbose_leaf_tampering(self):
        with self.context(),patch.dict(os.environ,{'YUEDU_RENEWAL_SELECTION':'currentcore'}):
            inputs=self.built()
            for suite in api.CURRENTCORE_SUITES:
                path=api.PACKAGE+'/Tests/LegadoRuntimeTests/'+suite+'.swift'
                old=self.originals[path];self.write(self.root/path,old+b'changed')
                with self.assertRaises(ValueError):api.result(self.work)
                self.write(self.root/path,old)
            changed=copy.deepcopy(inputs);changed['sourceInputs'].pop()
            self.write_json('source-inputs.json',changed)
            with self.assertRaises(ValueError):api.result(self.work)
            self.write_json('source-inputs.json',inputs)
            log=self.log();self.write(self.work/'tests.log',(log+log.splitlines()[0]+'\n').encode())
            with self.assertRaises(ValueError):api.result(self.work)


class PublicBatchPackageSelectionTests(unittest.TestCase):
    """Synthetic evidence guards only; no Swift, Git or real package execution."""
    setUp = OriginalAPIPackageEvidenceTests.setUp
    write = OriginalAPIPackageEvidenceTests.write
    write_json = OriginalAPIPackageEvidenceTests.write_json
    git = OriginalAPIPackageEvidenceTests.git
    context = OriginalAPIPackageEvidenceTests.context
    xml = OriginalAPIPackageEvidenceTests.xml
    log = OriginalAPIPackageEvidenceTests.log
    built = OriginalAPIPackageEvidenceTests.built

    def test_public_batch_is_one_explicit_extra_case_with_same_complete_package_source_boundary(self):
        extra = "LegadoRuntimeTests.LegadoOriginalAPITests/testTypedBatchReturnsMissingChapterIdentitiesAndDoesNotGrantSaves"
        source = (HERE.parents[1] / "Packages/LegadoRuntime/Tests/LegadoRuntimeTests/LegadoOriginalAPITests.swift").read_text(encoding="utf8")
        self.assertEqual(len(re.findall(r"func\s+" + extra.split("/")[1] + r"\s*\(", source)), 1)
        # Fixture default remains the original10 even if this test process was
        # launched by an environment that selects the explicit public batch.
        self.assertEqual(api.expected_cases(), api.EXPECTED)
        self.assertEqual(len(api.EXPECTED), 10)
        self.assertEqual(len(api.CURRENTCORE_EXPECTED), 16)
        self.assertEqual(api.PUBLICBATCH_EXPECTED, api.CURRENTCORE_EXPECTED | {extra})
        self.assertNotIn(extra, api.CURRENTCORE_EXPECTED)
        with patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": "currentcore"}):
            self.assertEqual(api.expected_cases(), api.CURRENTCORE_EXPECTED)
            self.assertEqual(api.selected_mode(), "original-api-package-currentcore")
        for flag, mode in (("unknown", "currentcore"), ("publicbatch", "handoffrenewal"), ("publicbatch", "all")):
            with self.subTest(flag=flag, mode=mode), patch.dict(os.environ,
                    {"YUEDU_RENEWAL_PACKAGE_SELECTION": flag, "YUEDU_RENEWAL_SELECTION": mode}):
                with self.assertRaises(ValueError): api.expected_cases()
                with self.assertRaises(ValueError): api.selected_mode()
        with self.context(), patch.dict(os.environ,
                {"YUEDU_RENEWAL_SELECTION": "currentcore", "YUEDU_RENEWAL_PACKAGE_SELECTION": "publicbatch"}):
            inputs = self.built()
            self.assertEqual(inputs["selectionMode"], "original-api-package-currentcore-publicbatch")
            self.assertEqual(inputs["packageSourceInputCount"], 15)
            self.assertEqual(len(inputs["sourceInputs"]), 22)
            self.assertEqual({item["path"] for item in inputs["sourceInputs"]}, set(api.PACKAGE_INPUTS + api.CONTROL_INPUTS))
            self.assertEqual(set(api.PACKAGE_INPUTS), {"Packages/LegadoRuntime/Package.swift"} | {
                path.relative_to(self.root).as_posix() for directory in ("Sources", "Tests")
                for path in (self.root / api.PACKAGE / directory).rglob("*") if path.is_file()})
            result = api.result(self.work)
            self.assertEqual(result["totalTestCount"], 17)
            self.assertEqual(result["passedCaseIdentifiers"], sorted(api.PUBLICBATCH_EXPECTED))
            self.assertEqual(result["verbosePassedCaseIdentifiers"], sorted(api.PUBLICBATCH_EXPECTED))
            self.assertEqual({case for case in api.PUBLICBATCH_EXPECTED if re.fullmatch(api.selected_filter(), case)}, api.PUBLICBATCH_EXPECTED)
            self.assertIn(api.selected_filter(), api.test_command(str(self.swift), self.work))
            original_xml = (self.work / "xunit.xml").read_bytes()
            for change in ("missing", "duplicate", "skip", "wrongSuite"):
                root = ET.fromstring(original_xml)
                node = next(item for item in root.iter("testcase") if item.get("name") == extra.split("/")[1])
                suite = next(item for item in root.iter("testsuite") if node in list(item))
                if change == "missing": suite.remove(node)
                elif change == "duplicate": suite.append(copy.deepcopy(node))
                elif change == "skip": ET.SubElement(node, "skipped")
                else: node.set("classname", "UnknownSuite")
                self.write(self.work / "xunit.xml", ET.tostring(root))
                with self.subTest(change=change), self.assertRaises(ValueError): api.result(self.work)
            self.write(self.work / "xunit.xml", original_xml)
            original_log = (self.work / "tests.log").read_bytes()
            lines = original_log.decode().splitlines(keepends=True)
            self.write(self.work / "tests.log", "".join(line for line in lines if extra.split("/")[1] not in line).encode())
            with self.assertRaises(ValueError): api.result(self.work)
            self.write(self.work / "tests.log", original_log)
            with patch.dict(os.environ, {"YUEDU_RENEWAL_PACKAGE_SELECTION": ""}):
                with self.assertRaises(ValueError): api.result(self.work)



class EffectsPackageSelectionTests(unittest.TestCase):
    """Explicit new18 selection; old10/default16/publicbatch17 retain their sets."""
    setUp = OriginalAPIPackageEvidenceTests.setUp
    write = OriginalAPIPackageEvidenceTests.write
    write_json = OriginalAPIPackageEvidenceTests.write_json
    git = OriginalAPIPackageEvidenceTests.git
    context = OriginalAPIPackageEvidenceTests.context
    xml = OriginalAPIPackageEvidenceTests.xml
    log = OriginalAPIPackageEvidenceTests.log
    built = OriginalAPIPackageEvidenceTests.built

    def test_effect_receipts_select_one_exact_extra_case_and_refuse_missing_duplicate_skip_or_alias(self):
        extra = "LegadoRuntimeTests.LegadoRuntimeTests/testCancelledExecutePreservesReportedEffectsFromSuccessAndErrorEnvelopes"
        self.assertEqual(api.EFFECTS_EXPECTED, api.PUBLICBATCH_EXPECTED | {extra})
        self.assertEqual(len(api.EXPECTED), 10); self.assertEqual(len(api.CURRENTCORE_EXPECTED), 16)
        self.assertEqual(len(api.PUBLICBATCH_EXPECTED), 17); self.assertEqual(len(api.EFFECTS_EXPECTED), 18)
        source = (HERE.parents[1] / "Packages/LegadoRuntime/Tests/LegadoRuntimeTests/LegadoRuntimeTests.swift").read_text(encoding="utf8")
        self.assertEqual(len(re.findall(r"\bfunc\s+" + extra.split("/")[1] + r"\s*\(", source)), 1)
        for mode, flag, expected in (("all", "", api.EXPECTED), ("currentcore", "", api.CURRENTCORE_EXPECTED),
                                     ("currentcore", "publicbatch", api.PUBLICBATCH_EXPECTED)):
            with patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": mode, "YUEDU_RENEWAL_PACKAGE_SELECTION": flag}):
                self.assertEqual(api.expected_cases(), expected)
                self.assertNotIn(extra, api.expected_cases())
        for flag, mode in (("unknown", "currentcore"), ("effects", "handoffrenewal"), ("effects", "all")):
            with self.subTest(flag=flag, mode=mode), patch.dict(os.environ,
                    {"YUEDU_RENEWAL_PACKAGE_SELECTION": flag, "YUEDU_RENEWAL_SELECTION": mode}):
                with self.assertRaises(ValueError): api.expected_cases()
                with self.assertRaises(ValueError): api.selected_mode()
        with self.context(), patch.dict(os.environ,
                {"YUEDU_RENEWAL_SELECTION": "currentcore", "YUEDU_RENEWAL_PACKAGE_SELECTION": "effects"}):
            inputs = self.built(); result = api.result(self.work)
            self.assertEqual(inputs["selectionMode"], "original-api-package-currentcore-effects")
            self.assertEqual(inputs["packageSourceInputCount"], 15); self.assertEqual(len(inputs["sourceInputs"]), 22)
            self.assertEqual(result["totalTestCount"], 18)
            self.assertEqual(result["passedCaseIdentifiers"], sorted(api.EFFECTS_EXPECTED))
            self.assertEqual(result["verbosePassedCaseIdentifiers"], sorted(api.EFFECTS_EXPECTED))
            self.assertIsNotNone(re.fullmatch(api.selected_filter(), extra))
            self.assertIsNone(re.fullmatch(api.selected_filter(), extra + "Alias"))
            original = (self.work / "xunit.xml").read_bytes()
            for change in ("missing", "duplicate", "skip", "wrongSuite"):
                root = ET.fromstring(original)
                node = next(item for item in root.iter("testcase") if item.get("name") == extra.split("/")[1])
                suite = next(item for item in root.iter("testsuite") if node in list(item))
                if change == "missing": suite.remove(node)
                elif change == "duplicate": suite.append(copy.deepcopy(node))
                elif change == "skip": ET.SubElement(node, "skipped")
                else: node.set("classname", "Other.LegadoRuntimeTests")
                self.write(self.work / "xunit.xml", ET.tostring(root))
                with self.subTest(change=change), self.assertRaises(ValueError): api.result(self.work)
            self.write(self.work / "xunit.xml", original)
            original_log = (self.work / "tests.log").read_bytes()
            self.write(self.work / "tests.log", "".join(line for line in original_log.decode().splitlines(True) if extra.split("/")[1] not in line).encode())
            with self.assertRaises(ValueError): api.result(self.work)
            self.write(self.work / "tests.log", original_log)
            with patch.dict(os.environ, {"YUEDU_RENEWAL_PACKAGE_SELECTION": "publicbatch"}):
                with self.assertRaises(ValueError): api.result(self.work)


class LoginUIPackageSelectionTests(unittest.TestCase):
    """Fresh explicit22 only; old10/default16/publicbatch17/effects18 are unchanged."""
    setUp = OriginalAPIPackageEvidenceTests.setUp
    write = OriginalAPIPackageEvidenceTests.write
    write_json = OriginalAPIPackageEvidenceTests.write_json
    git = OriginalAPIPackageEvidenceTests.git
    context = OriginalAPIPackageEvidenceTests.context
    xml = OriginalAPIPackageEvidenceTests.xml
    log = OriginalAPIPackageEvidenceTests.log
    built = OriginalAPIPackageEvidenceTests.built

    def test_loginui_four_actual_definitions_keep_all_historical_sets_filters_and_mode_boundaries(self):
        self.assertEqual(len(api.LOGINUI_EXTRA), 4)
        self.assertEqual(api.LOGINUI_EXPECTED, api.EFFECTS_EXPECTED | api.LOGINUI_EXTRA)
        source = (HERE.parents[1] / 'Packages/LegadoRuntime/Tests/LegadoRuntimeTests/LegadoOriginalAPITests.swift').read_text(encoding='utf8')
        for case in api.LOGINUI_EXTRA:
            self.assertEqual(len(re.findall(r'\bfunc\s+' + case.split('/')[1] + r'\s*\(', source)), 1)
        for mode, flag, expected, count in (
                ('all', '', api.EXPECTED, 10), ('currentcore', '', api.CURRENTCORE_EXPECTED, 16),
                ('currentcore', 'publicbatch', api.PUBLICBATCH_EXPECTED, 17),
                ('currentcore', 'effects', api.EFFECTS_EXPECTED, 18)):
            with patch.dict(os.environ, {'YUEDU_RENEWAL_SELECTION': mode, 'YUEDU_RENEWAL_PACKAGE_SELECTION': flag}):
                self.assertEqual(api.expected_cases(), expected)
                self.assertEqual(len(api.expected_cases()), count)
                self.assertTrue(api.LOGINUI_EXTRA.isdisjoint(api.expected_cases()))
        for flag, mode in (('loginui', 'all'), ('loginui', 'handoffrenewal'), ('unknown', 'currentcore')):
            with self.subTest(flag=flag, mode=mode), patch.dict(os.environ,
                    {'YUEDU_RENEWAL_SELECTION': mode, 'YUEDU_RENEWAL_PACKAGE_SELECTION': flag}):
                with self.assertRaises(ValueError): api.expected_cases()
                with self.assertRaises(ValueError): api.selected_mode()

    def test_loginui_fresh22_requires_every_xml_verbose_leaf_and_current_source_and_selection(self):
        with self.context(), patch.dict(os.environ,
                {'YUEDU_RENEWAL_SELECTION': 'currentcore', 'YUEDU_RENEWAL_PACKAGE_SELECTION': 'loginui'}):
            inputs = self.built(); result = api.result(self.work)
            self.assertEqual(inputs['selectionMode'], 'original-api-package-currentcore-loginui')
            self.assertEqual(inputs['packageSourceInputCount'], 15)
            self.assertEqual(len(inputs['sourceInputs']), 22)
            self.assertEqual(result['totalTestCount'], 22)
            self.assertEqual(result['passedCaseIdentifiers'], sorted(api.LOGINUI_EXPECTED))
            self.assertEqual(result['verbosePassedCaseIdentifiers'], sorted(api.LOGINUI_EXPECTED))
            self.assertIn(api.selected_filter(), api.test_command(str(self.swift), self.work))
            original = (self.work / 'xunit.xml').read_bytes()
            for case in sorted(api.LOGINUI_EXTRA):
                self.assertIsNotNone(re.fullmatch(api.selected_filter(), case))
                self.assertIsNone(re.fullmatch(api.selected_filter(), case + 'Alias'))
                for change in ('missing', 'duplicate', 'skip', 'wrongSuite'):
                    root = ET.fromstring(original)
                    node = next(item for item in root.iter('testcase') if item.get('name') == case.split('/')[1])
                    suite = next(item for item in root.iter('testsuite') if node in list(item))
                    if change == 'missing': suite.remove(node)
                    elif change == 'duplicate': suite.append(copy.deepcopy(node))
                    elif change == 'skip': ET.SubElement(node, 'skipped')
                    else: node.set('classname', 'Other.LegadoOriginalAPITests')
                    self.write(self.work / 'xunit.xml', ET.tostring(root))
                    with self.subTest(case=case, change=change), self.assertRaises(ValueError): api.result(self.work)
                self.write(self.work / 'xunit.xml', original)
                rawlog = (self.work / 'tests.log').read_bytes()
                self.write(self.work / 'tests.log', ''.join(line for line in rawlog.decode().splitlines(True)
                    if case.split('/')[1] not in line).encode())
                with self.assertRaises(ValueError): api.result(self.work)
                self.write(self.work / 'tests.log', rawlog)
            for path in ('Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoOriginalModels.swift',
                    'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoRuntime.swift',
                    'Packages/LegadoRuntime/Tests/LegadoRuntimeTests/LegadoOriginalAPITests.swift'):
                raw = self.originals[path]; self.write(self.root / path, raw + b' changed')
                with self.subTest(source=path), self.assertRaises(ValueError): api.result(self.work)
                self.write(self.root / path, raw)
            with patch.dict(os.environ, {'YUEDU_RENEWAL_PACKAGE_SELECTION': 'effects'}):
                with self.assertRaises(ValueError): api.result(self.work)


class DeltaReusePackageSelectionTests(unittest.TestCase):
    """Explicit new23; all older10/16/17/18/22 modes retain exact method sets."""
    setUp = OriginalAPIPackageEvidenceTests.setUp
    write = OriginalAPIPackageEvidenceTests.write
    write_json = OriginalAPIPackageEvidenceTests.write_json
    git = OriginalAPIPackageEvidenceTests.git
    context = OriginalAPIPackageEvidenceTests.context
    xml = OriginalAPIPackageEvidenceTests.xml
    log = OriginalAPIPackageEvidenceTests.log
    built = OriginalAPIPackageEvidenceTests.built

    def test_delta_one_actual_definition_preserves_all_five_old_modes_and_rejects_flag_aliases(self):
        extra = 'LegadoRuntimeTests.LegadoOriginalAPITests/testLoginUIDeltaReuseRequestAndTypedControlStateKeepRawRowsSeparate'
        self.assertEqual(api.DELTAREUSE_EXTRA, {extra})
        self.assertEqual(api.DELTAREUSE_EXPECTED, api.LOGINUI_EXPECTED | {extra})
        source = (HERE.parents[1] / 'Packages/LegadoRuntime/Tests/LegadoRuntimeTests/LegadoOriginalAPITests.swift').read_text(encoding='utf8')
        self.assertEqual(len(re.findall(r'\bfunc\s+' + extra.split('/')[1] + r'\s*\(', source)), 1)
        for mode, flag, expected, count in (
                ('all', '', api.EXPECTED, 10), ('currentcore', '', api.CURRENTCORE_EXPECTED, 16),
                ('currentcore', 'publicbatch', api.PUBLICBATCH_EXPECTED, 17),
                ('currentcore', 'effects', api.EFFECTS_EXPECTED, 18),
                ('currentcore', 'loginui', api.LOGINUI_EXPECTED, 22)):
            with patch.dict(os.environ, {'YUEDU_RENEWAL_SELECTION': mode, 'YUEDU_RENEWAL_PACKAGE_SELECTION': flag}):
                self.assertEqual(api.expected_cases(), expected)
                self.assertEqual(len(api.expected_cases()), count)
                self.assertNotIn(extra, api.expected_cases())
        for flag, mode in (('deltareuse', 'all'), ('deltareuse', 'handoffrenewal'), ('deltareuse-alias', 'currentcore')):
            with self.subTest(flag=flag, mode=mode), patch.dict(os.environ,
                    {'YUEDU_RENEWAL_SELECTION': mode, 'YUEDU_RENEWAL_PACKAGE_SELECTION': flag}):
                with self.assertRaises(ValueError): api.expected_cases()
                with self.assertRaises(ValueError): api.selected_mode()

    def test_delta_fresh23_requires_extra_xml_verbose_leaf_current_compilation_inputs_and_mode(self):
        extra = next(iter(api.DELTAREUSE_EXTRA))
        with self.context(), patch.dict(os.environ,
                {'YUEDU_RENEWAL_SELECTION': 'currentcore', 'YUEDU_RENEWAL_PACKAGE_SELECTION': 'deltareuse'}):
            inputs = self.built(); result = api.result(self.work)
            self.assertEqual(inputs['selectionMode'], 'original-api-package-currentcore-deltareuse')
            self.assertEqual(inputs['packageSourceInputCount'], 15)
            self.assertEqual(len(inputs['sourceInputs']), 22)
            self.assertEqual(result['totalTestCount'], 23)
            self.assertEqual(result['passedCaseIdentifiers'], sorted(api.DELTAREUSE_EXPECTED))
            self.assertEqual(result['verbosePassedCaseIdentifiers'], sorted(api.DELTAREUSE_EXPECTED))
            self.assertIn(api.selected_filter(), api.test_command(str(self.swift), self.work))
            self.assertIsNotNone(re.fullmatch(api.selected_filter(), extra))
            self.assertIsNone(re.fullmatch(api.selected_filter(), extra + 'Alias'))
            original = (self.work / 'xunit.xml').read_bytes()
            for change in ('missing', 'duplicate', 'skip', 'wrongSuite'):
                root = ET.fromstring(original)
                node = next(item for item in root.iter('testcase') if item.get('name') == extra.split('/')[1])
                suite = next(item for item in root.iter('testsuite') if node in list(item))
                if change == 'missing': suite.remove(node)
                elif change == 'duplicate': suite.append(copy.deepcopy(node))
                elif change == 'skip': ET.SubElement(node, 'skipped')
                else: node.set('classname', 'Other.LegadoOriginalAPITests')
                self.write(self.work / 'xunit.xml', ET.tostring(root))
                with self.subTest(change=change), self.assertRaises(ValueError): api.result(self.work)
            self.write(self.work / 'xunit.xml', original)
            rawlog = (self.work / 'tests.log').read_bytes()
            self.write(self.work / 'tests.log', ''.join(line for line in rawlog.decode().splitlines(True)
                if extra.split('/')[1] not in line).encode())
            with self.assertRaises(ValueError): api.result(self.work)
            self.write(self.work / 'tests.log', rawlog)
            for path in ('Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoOriginalModels.swift',
                    'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoRuntime.swift',
                    'Packages/LegadoRuntime/Tests/LegadoRuntimeTests/LegadoOriginalAPITests.swift'):
                raw = self.originals[path]; self.write(self.root / path, raw + b' changed')
                with self.subTest(source=path), self.assertRaises(ValueError): api.result(self.work)
                self.write(self.root / path, raw)
            with patch.dict(os.environ, {'YUEDU_RENEWAL_PACKAGE_SELECTION': 'loginui'}):
                with self.assertRaises(ValueError): api.result(self.work)

if __name__ == "__main__":
    unittest.main()
