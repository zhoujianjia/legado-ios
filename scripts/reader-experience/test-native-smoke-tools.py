#!/usr/bin/env python3
"""Portable provenance guards using synthetic files, never native execution."""
import importlib.util
import copy
import json
import os
import re
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("native_smoke_tested", Path(__file__).with_name("native-smoke-tools.py"))
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
SOURCE = "a" * 40


class NativeSmokeProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def test_private_prepare_stamps_source_and_restores_module_hooks(self):
        info = self.root / "Info.plist"
        info.write_bytes(plistlib.dumps({}))
        overlay_record = self.root / "info-overlay.json"
        old_overlay, old_validate = native.smoke.overlay_info, native.smoke.validate_tag

        def prepare(work):
            self.assertEqual(work, self.root)
            self.assertEqual(native.smoke.validate_tag(), SOURCE)
            return native.smoke.overlay_info(info, overlay_record)

        with patch.object(native, "validate_tag", return_value=SOURCE), \
                patch.object(native.smoke, "prepare", side_effect=prepare), \
                patch.object(native, "source_inputs", return_value=[]):
            record = native.prepare(self.root)
            self.assertEqual(record["sourceCommitStamped"], SOURCE)
            native.smoke.require_source_stamp(plistlib.loads(info.read_bytes()), SOURCE)
            prior_info, prior_record = info.read_bytes(), overlay_record.read_bytes()
            with self.assertRaisesRegex(ValueError, "prior Info"):
                native.prepare(self.root)
            self.assertEqual(info.read_bytes(), prior_info)
            self.assertEqual(overlay_record.read_bytes(), prior_record)
        self.assertIs(native.smoke.overlay_info, old_overlay)
        self.assertIs(native.smoke.validate_tag, old_validate)

    def result_fixture(self):
        app = self.root / "products/YueduReader.app"
        app.mkdir(parents=True)
        info = {**native.smoke.config.LOCAL_FLAGS, "GatewayBaseURL": "",
                "GIDClientID": native.smoke.config.GOOGLE_CLIENT,
                "CFBundleExecutable": "YueduReader", "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
                "YueduExperienceSourceCommit": SOURCE, "GitCommitSHA": SOURCE[:7]}
        (app / "Info.plist").write_bytes(plistlib.dumps(info))
        (app / "YueduReader").write_bytes(b"synthetic executable, not a native payload")
        audit = {"sourceCommit": SOURCE, "infoOverlay": {"sourceCommitStamped": SOURCE}}
        settings = [{"target": native.smoke.config.MAIN_TARGET, "buildSettings": {
            "CONFIGURATION": "Debug", "PLATFORM_NAME": "iphonesimulator", "SWIFT_VERSION": "5.0",
            "ENABLE_DEBUG_DYLIB": "NO", "PRODUCT_BUNDLE_IDENTIFIER": native.smoke.config.MAIN_BUNDLE,
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG LEGADO_REQUIRE_NATIVE_MAINJS",
            "TARGET_BUILD_DIR": str(app.parent), "FULL_PRODUCT_NAME": app.name}}]
        records = {"overlays.json": audit, "build-settings.json": settings,
                   "native-exports.json": {"requiredDynamicExportsPresent": True},
                   "native-restore.json": {"sourceCommit": SOURCE},
                   "summary.json": {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}}
        return app, info, records

    def test_result_requires_exact_built_app_source_stamp(self):
        app, info, records = self.result_fixture()
        with patch.object(native, "validate_tag", return_value=SOURCE), \
                patch.object(native.smoke, "read_json", side_effect=lambda path: records[path.name]), \
                patch.object(native.smoke, "review_overlays"), \
                patch.object(native.smoke.config, "verify_jvm_payload", return_value={"synthetic": True}), \
                patch.object(native, "verify_group", side_effect=lambda work, group: {"summary": {"expectedTests": len(native.NATIVE_GROUPS[group]["methods"])}}):
            result = native.result(self.root)
            self.assertEqual(result["sourceCommitStamped"], SOURCE)
            self.assertEqual(result["sourceOverlays"]["infoOverlay"]["sourceCommitStamped"], SOURCE)
            self.assertEqual(result["originalReaderTests"]["expectedTests"], 24)
            self.assertFalse(result["deviceValidationPassed"])
            for key, value in (("YueduExperienceSourceCommit", "b" * 40), ("GitCommitSHA", "b" * 7),
                               ("YueduExperienceSourceCommit", None)):
                with self.subTest(key=key, value=value):
                    changed = {**info}
                    if value is None:
                        changed.pop(key)
                    else:
                        changed[key] = value
                    (app / "Info.plist").write_bytes(plistlib.dumps(changed))
                    with self.assertRaisesRegex(ValueError, "full and short"):
                        native.result(self.root)

    def test_result_rejects_unstamped_or_other_source_preparation(self):
        _, _, records = self.result_fixture()
        with patch.object(native, "validate_tag", return_value=SOURCE), \
                patch.object(native.smoke, "read_json", side_effect=lambda path: records[path.name]):
            for value in (None, "b" * 40):
                with self.subTest(value=value):
                    records["overlays.json"]["infoOverlay"] = {} if value is None else {"sourceCommitStamped": value}
                    with self.assertRaisesRegex(ValueError, "did not stamp"):
                        native.result(self.root)

    def cases(self, group):
        return {"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": "yuedu appTests/" + method + "()",
            "result": "Passed"} for method in native.NATIVE_GROUPS[group]["methods"]]}

    def test_native_groups_require_exact_qualified_methods_without_skips_or_duplicates(self):
        for group, spec in native.NATIVE_GROUPS.items():
            tree = self.cases(group)
            self.assertEqual(native.verify_cases(tree, group), sorted(spec["methods"]))
            for fault in ("missing", "duplicate", "skip", "failed", "foreign", "wrongTarget", "retry", "duplicateRun"):
                with self.subTest(group=group, fault=fault), self.assertRaises(ValueError):
                    changed = copy.deepcopy(tree); rows = changed["testNodes"]
                    if fault == "missing": rows.pop()
                    elif fault == "duplicate": rows.append(copy.deepcopy(rows[0]))
                    elif fault == "skip": rows[0]["result"] = "Skipped"
                    elif fault == "failed": rows[0]["result"] = "Failed"
                    elif fault == "foreign": rows[0]["nodeIdentifier"] = "OtherSuite/testOther()"
                    elif fault == "wrongTarget": rows[0]["nodeIdentifier"] = rows[0]["nodeIdentifier"].replace("yuedu appTests/", "otherTests/")
                    elif fault == "retry": rows[0]["children"] = [{"nodeType": "Repetition", "result": "Passed"}]
                    else: rows[0]["children"] = [{"nodeType": "Test Case Run", "result": "Passed"}] * 2
                    native.verify_cases(changed, group)

    def write_json(self, name, value):
        (self.root / name).write_text(json.dumps(value), encoding="utf-8")

    def group_fixture(self, group):
        source = {"sourceCommit": SOURCE, "sourceInputs": []}
        spec = native.NATIVE_GROUPS[group]
        commands = []
        summary = {"totalTestCount": len(spec["methods"]), "passedTests": len(spec["methods"]), "failedTests": 0, "skippedTests": 0}
        for index, (argv, output, seconds) in enumerate(zip(native.group_commands(self.root, group), native._group_outputs(self.root, group), (spec["seconds"] + 60, 60, 60))):
            value = summary if index == 1 else self.cases(group) if index == 2 else {"synthetic": True}
            output.write_text(json.dumps(value), encoding="utf-8")
            stderr = output.with_name(output.name + ".stderr.log"); stderr.write_bytes(b"")
            commands.append({"argv": argv, "exitCode": 0, "timedOut": False, "timeoutSeconds": seconds,
                "output": output.name, "stdout": native._fact(output), "stderr": stderr.name, "stderrFact": native._fact(stderr)})
        ledger = {"schemaVersion": 1, "group": group, "sourceBefore": source, "sourceAfter": source,
            "expectedMethods": list(spec["methods"]), "commands": commands, "error": None}
        previous = self.root / (native.NATIVE_GROUPS["mainjs"]["stem"] + "-execution.json")
        ledger["precedingMainJSExecution"] = {"path": previous.name, **native._fact(previous)} if group == "original" else None
        self.write_json(spec["stem"] + "-execution.json", ledger)
        return source, ledger

    def test_group_gate_binds_original_exits_exports_sources_and_raw_bytes(self):
        for group in native.NATIVE_GROUPS:
            source, ledger = self.group_fixture(group)
            name = native.NATIVE_GROUPS[group]["stem"] + "-execution.json"
            with patch.object(native, "_source_state", return_value=source):
                self.assertEqual(len(native.verify_group(self.root, group)["passedQualifiedMethods"]), len(native.NATIVE_GROUPS[group]["methods"]))
                for fault in ("exit", "timeout", "exports", "command", "source", "methods", "raw", "predecessor"):
                    with self.subTest(group=group, fault=fault):
                        changed = copy.deepcopy(ledger)
                        if fault == "exit": changed["commands"][0]["exitCode"] = 65
                        elif fault == "timeout": changed["commands"][0]["timedOut"] = True
                        elif fault == "exports": changed["commands"].pop()
                        elif fault == "command": changed["commands"][0]["argv"].append("-only-testing:otherTests/Other/test")
                        elif fault == "source": changed["sourceAfter"]["sourceCommit"] = "b" * 40
                        elif fault == "methods": changed["expectedMethods"].append("Other/test")
                        elif fault == "raw": changed["commands"][2]["stdout"]["sha256"] = "0" * 64
                        else: changed["precedingMainJSExecution"] = {"path": "other.json", "sha256": "0" * 64, "bytes": 0}
                        self.write_json(name, changed)
                        with self.assertRaises(ValueError): native.verify_group(self.root, group)
                self.write_json(name, ledger)

    def test_failed_first_native_host_retains_exports_and_allows_independent_second_diagnostics(self):
        source = {"sourceCommit": SOURCE, "sourceInputs": []}
        captures = []
        def capture(argv, output, seconds):
            captures.append(argv)
            group = "original" if output.name.startswith("original") else "mainjs"
            spec = native.NATIVE_GROUPS[group]
            value = {"totalTestCount": len(spec["methods"]), "passedTests": len(spec["methods"]), "failedTests": 0, "skippedTests": 0} if output.name == spec["summary"] else self.cases(group) if output.name == spec["tests"] else {"synthetic": True}
            output.write_text(json.dumps(value), encoding="utf-8")
            stderr = output.with_name(output.name + ".stderr.log"); stderr.write_bytes(b"")
            return {"argv": argv, "exitCode": 65 if len(captures) == 1 else 0, "timedOut": False,
                "timeoutSeconds": seconds, "output": output.name, "stdout": native._fact(output), "stderr": stderr.name, "stderrFact": native._fact(stderr)}
        with patch.object(native, "_source_state", return_value=source), patch.object(native, "_capture", side_effect=capture):
            first = native.run_group(self.root, "mainjs")
            self.assertFalse(first["passed"])
            second = native.run_group(self.root, "original")
            self.assertTrue(second["passed"])
            self.assertEqual(len(captures), 6)
            self.assertTrue((self.root / "summary.json").is_file())
            self.assertTrue((self.root / "original-summary.json").is_file())
            with self.assertRaises(ValueError): native.verify_group(self.root, "mainjs")
            with self.assertRaisesRegex(ValueError, "overwrite"): native.run_group(self.root, "mainjs")

    def test_source_closure_rejects_changed_bytes_wrong_source_and_source_only_mode(self):
        (self.root / "owned.swift").write_bytes(b"owned source")
        with patch.object(native.smoke, "REPO", self.root), patch.object(native, "SOURCE_INPUTS", ("owned.swift",)), \
                patch.object(native, "validate_tag", return_value=SOURCE), patch.object(native.smoke, "review_overlays"), \
                patch.object(native.smoke, "git", return_value=b"owned source"), \
                patch.dict(os.environ, {}, clear=True):
            self.write_json("overlays.json", {})
            prepared = {"sourceCommit": SOURCE, "sourceInputs": native.source_inputs()}
            self.write_json("native-source-inputs.json", prepared)
            self.assertEqual(native._source_state(self.root), prepared)
            (self.root / "owned.swift").write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "tracked HEAD"): native._source_state(self.root)
            (self.root / "owned.swift").write_bytes(b"owned source")
            self.write_json("native-source-inputs.json", {**prepared, "sourceCommit": "b" * 40})
            with self.assertRaisesRegex(ValueError, "source closure"): native._source_state(self.root)
            with patch.dict(os.environ, {"LEGADO_RUNTIME_SOURCE_ONLY": "1"}), self.assertRaisesRegex(ValueError, "unset"):
                native._source_state(self.root)


    def test_cache_gate_rejects_wrong_summary_methods_bool_leaves_and_source(self):
        repo = Path(__file__).resolve().parents[2]
        for suite in native.CACHE_CASES:
            relative = 'Tests/iOS/yuedu appTests/' + suite + '.swift'
            path = self.root / relative; path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes((repo / relative).read_bytes())
        summary = {'totalTestCount': 6, 'passedTests': 6, 'failedTests': 0, 'skippedTests': 0,
            'expectedFailures': 0, 'devicesAndConfigurations': [
                {'passedTests': 8, 'failedTests': 0, 'skippedTests': 0, 'expectedFailures': 0}]}
        rows = []
        for identity, count in native.CACHE_EXECUTIONS.items():
            row = {'nodeType': 'Test Case', 'nodeIdentifier': identity, 'result': 'Passed'}
            if count == 2: row['children'] = [{'nodeType':'Arguments','name':v,'result':'Passed'} for v in ['false','true']]
            rows.append(row)
        tree = {'testNodes': rows}
        result = native.verify_cache(summary, tree, self.root)
        self.assertEqual(result['expectedTests'], 6)
        self.assertEqual(result['expectedExecutions'], 8)
        for fault in ('empty', 'missing', 'duplicate', 'foreign', 'wrongTarget', 'skip', 'failed',
                      'zeroExecution', 'wrongGrain', 'missingDevice', 'extraDevice', 'expectedFailure',
                      'boolCounter', 'argumentMissing', 'argumentDuplicate', 'argumentChanged', 'argumentSkipped', 'retry'):
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                s, t = copy.deepcopy(summary), copy.deepcopy(tree)
                parameter = next(row for row in t['testNodes'] if row.get('children'))
                if fault == 'empty': t['testNodes'] = []
                elif fault == 'missing': t['testNodes'].pop()
                elif fault == 'duplicate': t['testNodes'].append(copy.deepcopy(t['testNodes'][0]))
                elif fault == 'foreign': t['testNodes'][0]['nodeIdentifier'] = 'Other/test()'
                elif fault == 'wrongTarget': t['testNodes'][0]['nodeIdentifier'] = 'otherTests/' + t['testNodes'][0]['nodeIdentifier']
                elif fault in ('skip','failed'): t['testNodes'][0]['result'] = 'Skipped' if fault == 'skip' else 'Failed'
                elif fault == 'zeroExecution': s['devicesAndConfigurations'][0]['passedTests'] = 0
                elif fault == 'wrongGrain': s['totalTestCount'] = s['passedTests'] = 8
                elif fault == 'missingDevice': s['devicesAndConfigurations'] = []
                elif fault == 'extraDevice': s['devicesAndConfigurations'] *= 2
                elif fault == 'expectedFailure': s['devicesAndConfigurations'][0]['expectedFailures'] = 1
                elif fault == 'boolCounter': s['failedTests'] = False
                elif fault == 'argumentMissing': parameter['children'].pop()
                elif fault == 'argumentDuplicate': parameter['children'][1]['name'] = 'false'
                elif fault == 'argumentChanged': parameter['children'][0]['name'] = '0'
                elif fault == 'argumentSkipped': parameter['children'][0]['result'] = 'Skipped'
                else: parameter['children'] = [{'nodeType':'Repetition','result':'Passed'}]
                native.verify_cache(s, t, self.root)
        source = self.root / 'Tests/iOS/yuedu appTests/ChapterCacheMigrationTests.swift'
        original = source.read_bytes()
        for before, after in [(b'[false, true]',b'[false, false]'),
                              (b'hasCachedState: Bool',b'hasCachedState: Int'),
                              (b'packageLoaderUpgradesDownloadedLegacyChapter',b'foreignCacheMethod')]:
            source.write_bytes(original.replace(before, after))
            with self.assertRaises(ValueError): native.verify_cache(summary, tree, self.root)
        source.write_bytes(original)

    def test_workflow_keeps_native_groups_in_separate_required_hosts_after_real_staging(self):
        repo = Path(__file__).resolve().parents[2]
        workflow = (repo / ".github/workflows/legado-native-reader-test.yml").read_text(encoding="utf-8")
        self.assertEqual(len(native.SOURCE_INPUTS), 137)
        self.assertEqual(len(native.ORIGINAL_LOGIN_ACTION_MATERIAL_INPUTS), 23)
        self.assertTrue(set(native.ORIGINAL_LOGIN_ACTION_MATERIAL_INPUTS) <= set(native.SOURCE_INPUTS))
        self.assertIn("Execute1 MainJS and24 original methods in separate required hosts", workflow)
        self.assertEqual(len(native.NATIVE_CORETEXT_COMPILE_INPUTS), 6)
        self.assertTrue(set(native.NATIVE_CORETEXT_COMPILE_INPUTS) <= set(native.SOURCE_INPUTS))
        for relative in native.NATIVE_CORETEXT_COMPILE_INPUTS:
            self.assertIn("import YueduCoreText", (repo / relative).read_text(encoding="utf-8").splitlines())
        self.assertEqual(len(native.SOURCE_INPUTS), len(set(native.SOURCE_INPUTS)))
        self.assertEqual(len(native.ORIGINAL_LOGIN_BROWSER_POST_INPUTS), 9)
        self.assertTrue(set(native.ORIGINAL_LOGIN_BROWSER_POST_INPUTS) <= set(native.SOURCE_INPUTS))
        self.assertIn('LegadoNativeOriginalLoginInfoTests/testNativeOriginalPostBrowserDisplaysPrefetchedHtmlAndReusesSingleHttpBody', native.NATIVE_GROUPS["original"]["methods"])
        self.assertEqual(len(native.ORIGINAL_LOGIN_BROWSER_AWAIT_INPUTS), 14)
        self.assertTrue(set(native.ORIGINAL_LOGIN_BROWSER_AWAIT_INPUTS) <= set(native.SOURCE_INPUTS))
        self.assertIn('LegadoNativeOriginalLoginInfoTests/testNativeOriginalAwaitBrowserConfirmsThroughRealPageAndCancelsWithoutLateCredentialWrite', native.NATIVE_GROUPS["original"]["methods"])
        self.assertEqual(len(native.ORIGINAL_LOGIN_BROWSER_INPUTS), 11)
        self.assertTrue(set(native.ORIGINAL_LOGIN_BROWSER_INPUTS) <= set(native.SOURCE_INPUTS))
        self.assertEqual(len(native.NATIVE_READER_REPAIR_INPUTS), 4)
        self.assertTrue(set(native.NATIVE_READER_REPAIR_INPUTS) <= set(native.SOURCE_INPUTS))
        self.assertEqual(len(native.LOGIN_V2_NATIVE_REPAIR_INPUTS), 21)
        self.assertTrue(set(native.LOGIN_V2_NATIVE_REPAIR_INPUTS) <= set(native.SOURCE_INPUTS))
        self.assertEqual(len(native.LOCAL_PRODUCT_CACHE_INPUTS), 10)
        self.assertTrue(set(native.LOCAL_PRODUCT_CACHE_INPUTS) <= set(native.SOURCE_INPUTS))
        self.assertIn("smoke-tools.py verify-local-product", workflow)
        self.assertIn("native-smoke-tools.py verify-cache", workflow)
        self.assertIn("$CACHE_COUNT_STATUS == 0", workflow)
        self.assertNotIn("--expected 41", workflow)
        self.assertTrue(set(native.LOGIN_EVENTS_DISMISS_LIFECYCLE_INPUTS) <= set(native.SOURCE_INPUTS))
        self.assertTrue(set(native.DELTA_REUSE_INPUTS) <= set(native.SOURCE_INPUTS))
        self.assertEqual(len(native.ORIGINAL_SOURCE_STATE_INPUTS), 20)
        self.assertTrue(set(native.ORIGINAL_SOURCE_STATE_INPUTS) <= set(native.SOURCE_INPUTS))
        self.assertEqual(native.NATIVE_F2_TEST_COMPILE_INPUTS, ('Tests/iOS/yuedu appTests/SelfRenewalDeveloperAuthenticationTests.swift', 'Tests/iOS/yuedu appTests/SelfRenewalAutomaticRenewalTests.swift'))
        self.assertTrue(set(native.NATIVE_F2_TEST_COMPILE_INPUTS) <= set(native.SOURCE_INPUTS))
        self.assertEqual(len(native.ORIGINAL_ROW_ACTION_INPUTS), 13)
        self.assertTrue(set(native.ORIGINAL_ROW_ACTION_INPUTS) <= set(native.SOURCE_INPUTS))
        self.assertEqual(len(native.ORIGINAL_LOGIN_UI_EXPLORE_INPUTS), 27)
        self.assertTrue(set(native.ORIGINAL_LOGIN_UI_EXPLORE_INPUTS) <= set(native.SOURCE_INPUTS))
        self.assertEqual(len(native.ORIGINAL_LOGIN_MAP_INPUTS), 11)
        self.assertTrue(set(native.ORIGINAL_LOGIN_MAP_INPUTS) <= set(native.SOURCE_INPUTS))
        self.assertEqual(native.NATIVE_GROUPS["mainjs"]["seconds"], 2700)
        self.assertEqual(len(native.NATIVE_GROUPS["mainjs"]["methods"]), 1)
        self.assertEqual(len(native.NATIVE_GROUPS["original"]["methods"]), 24)
        self.assertIn("unset LEGADO_RUNTIME_SOURCE_ONLY", workflow)
        self.assertIn("LEGADO_REQUIRE_NATIVE_MAINJS", workflow)
        self.assertIn("verify-native-exports.py", workflow)
        self.assertLess(workflow.index("stage-runtime.py"), workflow.index("run-group --group mainjs"))
        self.assertLess(workflow.index("run-group --group mainjs"), workflow.index("run-group --group original"))
        self.assertIn("$NATIVE_STATUS == 0 && $ORIGINAL_STATUS == 0", workflow)
        commands = {group: native.group_commands(self.root, group)[0] for group in native.NATIVE_GROUPS}
        self.assertNotEqual(commands["mainjs"], commands["original"])
        for group, argv in commands.items():
            self.assertEqual(argv.count("-resultBundlePath"), 1)
            self.assertIn("ENABLE_DEBUG_DYLIB=NO", argv)
            self.assertIn("SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG LEGADO_REQUIRE_NATIVE_MAINJS", argv)
            selectors = [value for value in argv if value.startswith("-only-testing:")]
            self.assertEqual(selectors, ["-only-testing:yuedu appTests/" + value for value in native.NATIVE_GROUPS[group]["methods"]])
            methods = native.NATIVE_GROUPS[group]["methods"]
            self.assertEqual(len(methods), len(set(methods)))
            for suite in {method.split("/")[0] for method in methods}:
                relative = "Tests/iOS/" + suite + ".swift"
                self.assertIn(relative, native.SOURCE_INPUTS)
                source = (repo / relative).read_text(encoding="utf-8")
                self.assertIn("final class " + suite + ": XCTestCase", source)
                declarations = re.findall(r"(?m)^\s+func (test\w+)\s*\(([^)]*)\)", source)
                self.assertEqual(len(declarations), len(set(name for name, _ in declarations)))
                self.assertEqual({name for name, _ in declarations},
                    {method.split("/")[1] for method in methods if method.split("/")[0] == suite})
                self.assertTrue(all(parameters == "" for _, parameters in declarations))
                if suite == "LegadoNativeOriginalLoginInfoTests":
                    # This suite throws directly under the required-native flag.
                    # Its source-only fallback must never run in this workflow.
                    self.assertEqual(source.count("try await requireNativeRuntime()"), 13)
                    self.assertRegex(source, r"#if LEGADO_REQUIRE_NATIVE_MAINJS\s+throw LegadoRuntimeError\(code: \"missing_runtime\"")
                    self.assertRegex(source, r'#else\s+if ProcessInfo\.processInfo\.environment\["LEGADO_REQUIRE_NATIVE_MAINJS"\] == "1"\s*\{\s*throw LegadoRuntimeError\(code: "missing_runtime"')
                    self.assertIn('throw XCTSkip("Requires real ordinary JAR/JNI and Keychain; source-only cannot pass")', source)
                else:
                    self.assertRegex(source, r"#if LEGADO_REQUIRE_NATIVE_MAINJS\s+required = true")


if __name__ == "__main__":
    unittest.main()
