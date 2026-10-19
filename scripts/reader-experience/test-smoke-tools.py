#!/usr/bin/env python3
"""Offline guard tests; these do not execute or claim the Simulator UI smoke."""
import copy
from contextlib import redirect_stderr, redirect_stdout
import io
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("reader_smoke_tests", HERE / "smoke-tools.py")
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)
SOURCE = "a" * 40


class SmokeEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def write(self, path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def source_info(self):
        return {"CFBundleURLTypes": [{"CFBundleURLSchemes": ["com.googleusercontent.apps.old", "yuedu", "legado"]}],
                "GatewayBaseURL": "https://upstream.invalid", "GIDClientID": "upstream"}

    def product_fixture(self):
        # Synthetic evidence with the frozen xcresult Test Case/Arguments shape;
        # never label these fixtures as actual font/iOS test executions.
        summary = {"totalTestCount": 50, "passedTests": 50, "failedTests": 0, "skippedTests": 0,
                   "expectedFailures": 0, "devicesAndConfigurations": [
                       {"passedTests": 68, "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}]}
        cases = []
        for identity, executions in sorted(smoke.LOCAL_PRODUCT_EXECUTIONS.items()):
            node = {"nodeType": "Test Case", "nodeIdentifier": identity, "result": "Passed"}
            if executions != 1:
                node["children"] = [{"nodeType": "Arguments", "name": "owned-fixture-" + str(index), "result": "Passed"}
                                    for index in range(executions)]
            cases.append(node)
        tree = {"testNodes": [{"nodeType": "Test Plan", "result": "Passed", "children": [
            {"nodeType": "Unit test bundle", "result": "Passed", "children": cases}]}]}
        return summary, tree

    def product_sources(self):
        inventory = smoke.local_product_source_inputs(HERE.parents[1])
        for record in inventory["sourceInputs"]:
            self.write(self.root / record["path"], (HERE.parents[1] / record["path"]).read_bytes())
        return inventory

    def product_cases(self, tree):
        return tree["testNodes"][0]["children"][0]["children"]

    def test_source_info_overlay_is_boolean_and_replaces_only_cloud_configuration(self):
        path = self.root / "Info.plist"
        original = plistlib.dumps(self.source_info())
        self.write(path, original)
        report = smoke.overlay_info(path, self.root / "info-overlay.json")
        info = plistlib.loads(path.read_bytes())
        smoke.require_local_info(info)
        self.assertEqual(info["CFBundleURLTypes"][0]["CFBundleURLSchemes"], [smoke.config.GOOGLE_REVERSED, "yuedu", "legado"])
        self.assertEqual(report["originalSHA256"], smoke.hashlib.sha256(original).hexdigest())
        self.assertEqual(report["overlaySHA256"], smoke.config.digest(path))
        self.assertNotIn("sourceCommitStamped", report)
        self.assertNotIn("YueduExperienceSourceCommit", info)

    def test_explicit_source_stamp_binds_full_and_short_sha_in_info_and_record(self):
        path = self.root / "Info.plist"
        self.write(path, plistlib.dumps(self.source_info()))
        report = smoke.overlay_info(path, self.root / "info-overlay.json", source_commit=SOURCE)
        info = plistlib.loads(path.read_bytes())
        smoke.require_source_stamp(info, SOURCE)
        self.assertEqual(report["sourceCommitStamped"], SOURCE)
        self.assertEqual(info["GitCommitSHA"], SOURCE[:7])
        self.assertEqual(report["overlaySHA256"], smoke.config.digest(path))

    def test_invalid_source_stamp_is_rejected_before_info_or_record_mutation(self):
        path = self.root / "Info.plist"
        original = plistlib.dumps(self.source_info())
        self.write(path, original)
        record = self.root / "info-overlay.json"
        for value in ("", "A" * 40, "a" * 39, "a" * 41, SOURCE + "\n", True):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "full lowercase"):
                smoke.overlay_info(path, record, source_commit=value)
            self.assertEqual(path.read_bytes(), original)
            self.assertFalse(record.exists())

    def test_source_overlay_refuses_overwriting_audit_before_mutation(self):
        path = self.root / "Info.plist"
        self.write(path, plistlib.dumps(self.source_info()))
        audit = self.root / "info-overlay.json"
        self.write(audit, b"previous evidence")
        original = path.read_bytes()
        with self.assertRaisesRegex(ValueError, "prior Info"):
            smoke.overlay_info(path, audit)
        self.assertEqual(path.read_bytes(), original)

    def test_local_info_rejects_string_flag_or_configured_gateway(self):
        info = {**smoke.config.LOCAL_FLAGS, "GatewayBaseURL": "", "GIDClientID": smoke.config.GOOGLE_CLIENT}
        smoke.require_local_info(info)
        for key, value in (("YueduLocalExperience", "YES"), ("GatewayBaseURL", "https://upstream.invalid")):
            with self.subTest(key=key), self.assertRaises(ValueError):
                smoke.require_local_info({**info, key: value})

    def test_exact_nonzero_test_counts_and_zero_skips_are_required(self):
        good = {"totalTestCount": 6, "passedTests": 6, "failedTests": 0, "skippedTests": 0}
        self.assertEqual(smoke.verify_summary(good, 6)["passedTests"], 6)
        for key, value in (("totalTestCount", 0), ("passedTests", 5), ("failedTests", 1), ("skippedTests", 1),
                           ("passedTests", True), ("skippedTests", None), ("totalTestCount", 7)):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                smoke.verify_summary({**good, key: value}, 6)

    def test_smoke_tag_must_match_current_sha7(self):
        with patch.object(smoke, "source_sha", return_value=SOURCE), \
                patch.dict(smoke.os.environ, {"GITHUB_SHA": SOURCE, "GITHUB_REF_NAME": "reader-smoke-aaaaaaa"}):
            self.assertEqual(smoke.validate_tag(), SOURCE)
            with patch.dict(smoke.os.environ, {"GITHUB_REF_NAME": "reader-experience-aaaaaaa"}), self.assertRaises(ValueError):
                smoke.validate_tag()
        with patch.object(smoke, "source_sha", return_value=SOURCE), \
                patch.dict(smoke.os.environ, {"GITHUB_SHA": SOURCE, "GITHUB_REF_NAME": "reader-measurements-aaaaaaa"}):
            self.assertEqual(smoke.validate_tag("reader-measurements-"), SOURCE)
            with self.assertRaises(ValueError):
                smoke.validate_tag()
            with patch.dict(smoke.os.environ, {"GITHUB_SHA": "b" * 40}), self.assertRaises(ValueError):
                smoke.validate_tag("reader-measurements-")
            with self.assertRaises(ValueError):
                smoke.validate_tag("reader-anything-")

    def test_parameterized_summary_separates_method_and_execution_counts(self):
        # An immutable xcresult from a previous actual run has six methods but
        # eight executions. Exercise its real schema rather than equating them.
        frozen = smoke.REPO / "docs/legado-ios/fixtures/ios-cache-summary-f73f0ae.json"
        summary = smoke.read_json(frozen)
        checked = smoke.verify_summary(summary, 6, 8)
        self.assertEqual(checked["expectedTests"], 6)
        self.assertEqual(checked["deviceExecutionCounts"]["passedTests"], 8)
        with self.assertRaises(ValueError):
            smoke.verify_summary(summary, 8, 8)
        with self.assertRaises(ValueError):
            smoke.verify_summary(summary, 6, 6)

    def test_execution_gate_rejects_missing_extra_skipped_or_failed_device_runs(self):
        good = {"totalTestCount": 18, "passedTests": 18, "failedTests": 0, "skippedTests": 0,
                "expectedFailures": 0, "devicesAndConfigurations": [
                    {"passedTests": 28, "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}]}
        self.assertEqual(smoke.verify_summary(good, 18, 28)["expectedExecutions"], 28)
        invalid = []
        # Old 13/23 evidence cannot accept the new five owned ordering cases.
        # Also reject each stale half of the method/execution count pair.
        for methods, executions in ((13, 23), (13, 28), (18, 23)):
            changed = copy.deepcopy(good)
            changed["totalTestCount"] = changed["passedTests"] = methods
            changed["devicesAndConfigurations"][0]["passedTests"] = executions
            invalid.append(changed)
        for value in (None, [], good["devicesAndConfigurations"] * 2, [None]):
            changed = copy.deepcopy(good)
            changed["devicesAndConfigurations"] = value
            invalid.append(changed)
        for key, value in (("passedTests", 27), ("passedTests", 29), ("passedTests", True), ("failedTests", 1),
                           ("skippedTests", 1), ("expectedFailures", 1), ("expectedFailures", None)):
            changed = copy.deepcopy(good)
            changed["devicesAndConfigurations"][0][key] = value
            invalid.append(changed)
        changed = copy.deepcopy(good)
        changed["expectedFailures"] = 1
        invalid.append(changed)
        for summary in invalid:
            with self.subTest(summary=summary), self.assertRaises(ValueError):
                smoke.verify_summary(summary, 18, 28)

    def test_local_product_source_inventory_binds_the_single_serialized_font_suite(self):
        inventory = self.product_sources()
        self.assertEqual(smoke.local_product_source_inputs(self.root), inventory)
        self.assertEqual((inventory["methodCount"], inventory["plannedExecutionCount"]), (50, 68))
        font = {key: count for key, count in inventory["expectedExecutionsByMethod"].items()
                if key.startswith("UserFontSettingsTests/")}
        self.assertEqual((len(font), sum(font.values())), (24, 42))
        self.assertEqual(len(inventory["sourceInputs"]), 8)
        self.assertNotIn("UserFontTransactionTests/failedImportPreservesLibrary(fault:global:)", inventory["expectedExecutionsByMethod"])

    def test_source_inventory_rejects_method_ownership_serialization_and_argument_drift(self):
        self.product_sources()
        directory = self.root / "Tests/iOS/yuedu appTests"
        transaction = directory / "UserFontTransactionTests.swift"
        settings = directory / "UserFontSettingsTests.swift"
        mutations = [
            (transaction, "func failedImportPreservesLibrary(", "func substitutedImportTest("),
            (transaction, "fault: FontFault", "wrongLabel: FontFault"),
            (transaction, "fault: FontFault", "fault: String"),
            (transaction, "extension UserFontSettingsTests {", "@Suite(.serialized) struct UserFontTransactionTests {"),
            (transaction, "case copyCandidate, metadata, copyOriginal, unregister, register, removeAfterMutation",
             "case copyCandidate, metadata, copyOriginal, unregister, register"),
            (transaction, "arguments: [false, true]", "arguments: [false, false]"),
            (transaction, "arguments: [false, true]", "arguments: [0, 1]"),
            (transaction, '"../outside.ttf", "/outside.ttf"', '"../outside.ttf", "owned.ttf"'),
            (settings, '.serialized', '.timeLimit(.minutes(1))'),
            (settings, "struct UserFontSettingsTests {", "struct SomeOtherFontTests {"),
        ]
        for path, old, new in mutations:
            original = path.read_text(encoding="utf-8")
            self.assertIn(old, original)
            try:
                path.write_text(original.replace(old, new, 1), encoding="utf-8")
                with self.subTest(old=old, new=new), self.assertRaises(ValueError):
                    smoke.local_product_source_inputs(self.root)
            finally:
                path.write_text(original, encoding="utf-8")
        original = transaction.read_text(encoding="utf-8")
        for suffix in ("\n@Test func failedDeletePreservesLibrary() {}\n", "\n@Test(\n func unsupportedDeclaration() {}\n"):
            try:
                transaction.write_text(original + suffix, encoding="utf-8")
                with self.subTest(suffix=suffix), self.assertRaises(ValueError):
                    smoke.local_product_source_inputs(self.root)
            finally:
                transaction.write_text(original, encoding="utf-8")
        transaction.unlink()
        with self.assertRaises(FileNotFoundError):
            smoke.local_product_source_inputs(self.root)

    def test_local_product_requires_exact_source_method_identities_and_argument_counts(self):
        summary, tree = self.product_fixture()
        checked = smoke.verify_local_product(summary, tree)
        self.assertEqual((checked["expectedTests"], checked["expectedExecutions"]), (50, 68))
        self.assertEqual(len(checked["passedCaseIdentifiers"]), 50)
        self.assertEqual(sum(checked["passedExecutionsByMethod"].values()), 68)
        # The actual Xcode identifier may include this known target prefix.
        for node in self.product_cases(tree):
            node["nodeIdentifier"] = "yuedu appTests/" + node["nodeIdentifier"]
        self.assertEqual(smoke.verify_local_product(summary, tree)["passedCaseIdentifiers"], checked["passedCaseIdentifiers"])

    def test_argument_walker_replays_the_actual_frozen_xcresult_schema(self):
        # This old cache fixture proves only the JSON walker schema, not font
        # behavior. It cannot satisfy the new local-product selection.
        tree = smoke.read_json(HERE.parents[1] / "docs/legado-ios/fixtures/ios-cache-tests-f73f0ae.json")
        archived = {
            "ChapterCacheMigrationTests/packageLoaderUpgradesDownloadedLegacyChapter()": 1,
            "ChapterCacheMigrationTests/corruptLegacyBodyDoesNotRewriteStoredChecksum(hasCachedState:)": 2,
            "ChapterCacheMigrationTests/legacyBodyWithoutChecksumRemainsUpgradeable(hasCachedState:)": 2,
            "ChapterCacheRepositoryWriteTests/emptyContentRejected()": 1,
            "ChapterCacheRepositoryWriteTests/bodyFailurePropagates()": 1,
            "ChapterCacheRepositoryWriteTests/writeIsReloadable()": 1,
        }
        with patch.object(smoke, "LOCAL_PRODUCT_EXECUTIONS", archived):
            checked = smoke.verify_local_product_cases(tree)
        self.assertEqual((len(checked["passedCaseIdentifiers"]), sum(checked["passedExecutionsByMethod"].values())), (6, 8))
        with self.assertRaises(ValueError):
            smoke.verify_local_product_cases(tree)

    def test_local_product_rejects_green_wrong_duplicate_or_missing_method_cases(self):
        _, tree = self.product_fixture()
        mutations = [lambda cases: cases.pop(),
                     lambda cases: cases.append(copy.deepcopy(cases[0])),
                     lambda cases: cases[0].update(nodeIdentifier="SomeOtherTests/looksGreen()"),
                     lambda cases: cases[0].update(nodeIdentifier="wrong target/" + cases[0]["nodeIdentifier"]),
                     lambda cases: cases[0].update(nodeIdentifier=True),
                     lambda cases: cases[0].pop("nodeIdentifier"),
                     lambda cases: cases[0].update(result="Skipped"),
                     lambda cases: cases[0].update(result="Failed"),
                     lambda cases: cases[0].update(children=[{"nodeType": "Arguments", "name": "extra", "result": "Passed"}])]
        for mutation in mutations:
            changed = copy.deepcopy(tree)
            mutation(self.product_cases(changed))
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                smoke.verify_local_product_cases(changed)
        # Same method count, but a duplicate replaces a missing intended method.
        changed = copy.deepcopy(tree)
        cases = self.product_cases(changed)
        cases[1] = copy.deepcopy(cases[0])
        with self.assertRaises(ValueError):
            smoke.verify_local_product_cases(changed)

    def test_local_product_rejects_missing_extra_duplicate_skipped_or_failed_argument_leaves(self):
        _, tree = self.product_fixture()
        def arguments(value):
            return next(node["children"] for node in self.product_cases(value) if node.get("children"))
        mutations = [lambda leaves: leaves.pop(),
                     lambda leaves: leaves.append(copy.deepcopy(leaves[0])),
                     lambda leaves: leaves[0].update(name=leaves[1]["name"]),
                     lambda leaves: leaves[0].update(name=""),
                     lambda leaves: leaves[0].update(result="Skipped"),
                     lambda leaves: leaves[0].update(result="Failed"),
                     lambda leaves: leaves[0].update(nodeType="Test Case"),
                     lambda leaves: leaves[0].update(children=[{}])]
        for mutation in mutations:
            changed = copy.deepcopy(tree)
            mutation(arguments(changed))
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                smoke.verify_local_product_cases(changed)
        changed = copy.deepcopy(tree)
        cases = {node["nodeIdentifier"]: node for node in self.product_cases(changed)}
        imports = cases["UserFontSettingsTests/failedImportPreservesLibrary(fault:global:)"]["children"]
        cancel = cases["UserFontSettingsTests/heldImportHasOnePublicationBoundary(cancelFirst:)"]["children"]
        cancel.append(imports.pop())  # total stays 68; per-method coverage changed.
        with self.assertRaises(ValueError):
            smoke.verify_local_product_cases(changed)

    def test_local_product_rejects_malformed_test_trees(self):
        for tree in ({}, {"testNodes": None}, {"testNodes": [None]},
                     {"testNodes": [{"nodeType": "Test Plan", "children": True}]},
                     {"testNodes": [{"nodeType": "Unknown"}]},
                     {"testNodes": [{"nodeType": "Test Plan", "result": "Skipped"}]}):
            with self.subTest(tree=tree), self.assertRaises(ValueError):
                smoke.verify_local_product_cases(tree)

    def test_local_product_summary_cannot_substitute_old_counts_or_hide_execution_failures(self):
        summary, tree = self.product_fixture()
        bad = []
        for total in (41, 47, 49, 51):
            bad.append({**summary, "totalTestCount": total, "passedTests": total})
        for key, value in (("passedTests", 47), ("passedTests", 64), ("passedTests", 67), ("passedTests", True),
                           ("failedTests", 1), ("skippedTests", 1), ("expectedFailures", 1)):
            changed = copy.deepcopy(summary)
            changed["devicesAndConfigurations"][0][key] = value
            bad.append(changed)
        bad.append({key: value for key, value in summary.items() if key != "devicesAndConfigurations"})
        for changed in bad:
            with self.subTest(summary=changed), self.assertRaises(ValueError):
                smoke.verify_local_product(changed, tree)

    def test_local_product_cli_requires_the_test_tree_and_emits_source_identities(self):
        summary, tree = self.product_fixture()
        summary_path, tree_path = self.root / "summary.json", self.root / "tests.json"
        self.write(summary_path, json.dumps(summary).encode())
        self.write(tree_path, json.dumps(tree).encode())
        argv = ["smoke-tools.py", "verify-local-product", "--summary", str(summary_path), "--tests", str(tree_path)]
        with patch.object(smoke.sys, "argv", argv), redirect_stdout(io.StringIO()) as output:
            self.assertEqual(smoke.main(), 0)
        self.assertEqual(len(json.loads(output.getvalue())["passedCaseIdentifiers"]), 50)
        with patch.object(smoke.sys, "argv", argv[:-2]), redirect_stderr(io.StringIO()) as errors, self.assertRaises(SystemExit):
            smoke.main()
        self.assertIn("--tests", errors.getvalue())

    def audit_fixture(self, source_commit=None, already_independent=False):
        family = smoke.config.MAIN_BUNDLE if already_independent else smoke.config.UPSTREAM_BUNDLE
        original_project = "\n".join("PRODUCT_BUNDLE_IDENTIFIER = " + family + suffix + ";"
                                     for suffix in ("", ".widget", ".shareextension", ".tests", ".uitests")
                                     for _ in range(2)).encode()
        originals = {smoke.INFO: plistlib.dumps(self.source_info()), smoke.config.PROJECT: original_project}
        self.write(self.root / smoke.INFO, originals[smoke.INFO])
        info = smoke.overlay_info(self.root / smoke.INFO, self.root / "info-overlay.json", source_commit=source_commit)
        self.write(self.root / smoke.config.PROJECT, original_project)
        project = smoke.config.overlay_project(self.root / smoke.config.PROJECT, self.root / "project-overlay.json")
        self.write(self.root / "GoogleService-Info.plist", plistlib.dumps(smoke.config.synthetic_config()))
        audit = {"sourceCommit": SOURCE, "projectOverlay": project, "infoOverlay": info}
        def git(*args, binary=False):
            if args[0] == "diff":
                return "\n".join(sorted({smoke.INFO} | ({smoke.config.PROJECT} if project["expectedTrackedOverlay"] else set())))
            if args[0] == "show":
                return originals[args[1].removeprefix("HEAD:")]
            raise AssertionError(args)
        return audit, git

    def test_independent_source_ids_require_no_project_mutation_and_no_fake_overlay(self):
        audit, git = self.audit_fixture(already_independent=True)
        project = audit["projectOverlay"]
        self.assertEqual(project["replacementCount"], 0)
        self.assertEqual(project["originalSHA256"], project["overlaySHA256"])
        with patch.object(smoke, "REPO", self.root), patch.object(smoke, "source_sha", return_value=SOURCE), \
                patch.object(smoke, "git", side_effect=git):
            smoke.review_overlays(audit)
            altered = copy.deepcopy(audit)
            altered["projectOverlay"]["replacementCount"] = 10
            with self.assertRaisesRegex(ValueError, "source identity"):
                smoke.review_overlays(altered)

    def test_stamped_review_rejects_record_and_info_source_mismatches(self):
        audit, git = self.audit_fixture(source_commit=SOURCE)
        with patch.object(smoke, "REPO", self.root), patch.object(smoke, "source_sha", return_value=SOURCE), \
                patch.object(smoke, "git", side_effect=git):
            smoke.review_overlays(audit)
            altered = copy.deepcopy(audit)
            altered["infoOverlay"]["sourceCommitStamped"] = "b" * 40
            with self.assertRaisesRegex(ValueError, "stamp differs"):
                smoke.review_overlays(altered)
            path = self.root / smoke.INFO
            original = path.read_bytes()
            for key, value in (("YueduExperienceSourceCommit", "b" * 40), ("GitCommitSHA", "b" * 7)):
                with self.subTest(key=key):
                    info = plistlib.loads(original)
                    info[key] = value
                    self.write(path, plistlib.dumps(info))
                    altered = copy.deepcopy(audit)
                    # Still reject a stamp mismatch when the audit's byte digest
                    # has been rewritten to match those incorrect Info bytes.
                    altered["infoOverlay"]["overlaySHA256"] = smoke.config.digest(path)
                    with self.assertRaisesRegex(ValueError, "full and short"):
                        smoke.review_overlays(altered)

    def test_overlay_review_rejects_tampered_source_or_additional_changes(self):
        audit, git = self.audit_fixture()
        with patch.object(smoke, "REPO", self.root), patch.object(smoke, "source_sha", return_value=SOURCE), \
                patch.object(smoke, "git", side_effect=git):
            smoke.review_overlays(audit)
            with patch.object(smoke, "git", return_value="Info.plist\nOther.swift"), self.assertRaisesRegex(ValueError, "Only the declared"):
                smoke.review_overlays(audit)
            self.write(self.root / smoke.config.PROJECT, b"tampered project")
            with self.assertRaisesRegex(ValueError, "differs from its audit"):
                smoke.review_overlays(audit)

    def test_result_requires_built_simulator_local_mode_and_keeps_device_pending(self):
        audit, git = self.audit_fixture()
        app = self.root / "products/YueduReader.app"
        info = {**smoke.config.LOCAL_FLAGS, "GatewayBaseURL": "", "GIDClientID": smoke.config.GOOGLE_CLIENT,
                "CFBundleIdentifier": smoke.config.MAIN_BUNDLE, "CFBundleExecutable": "YueduReader",
                "CFBundleSupportedPlatforms": ["iPhoneSimulator"]}
        self.write(app / "Info.plist", plistlib.dumps(info))
        self.write(app / "YueduReader", b"executable fixture")
        self.write(app / "GoogleService-Info.plist", plistlib.dumps(smoke.config.synthetic_config()))
        settings = [{"target": smoke.config.MAIN_TARGET, "buildSettings": {
            "CONFIGURATION": "Debug", "SWIFT_VERSION": "5.0", "PLATFORM_NAME": "iphonesimulator",
            "PRODUCT_BUNDLE_IDENTIFIER": smoke.config.MAIN_BUNDLE, "TARGET_BUILD_DIR": str(app.parent),
            "FULL_PRODUCT_NAME": app.name}}]
        unit = {"totalTestCount": 9, "passedTests": 9, "failedTests": 0, "skippedTests": 0}
        ui = {**unit, "totalTestCount": 1, "passedTests": 1}
        paging = {**unit, "totalTestCount": 12, "passedTests": 12}
        product, product_tests = self.product_fixture()
        self.product_sources()
        with patch.object(smoke, "REPO", self.root), patch.object(smoke, "source_sha", return_value=SOURCE), \
                patch.object(smoke, "git", side_effect=git):
            result = smoke.result(audit, settings, unit, ui, paging, product, product_tests)
            self.assertEqual(result["status"], "passed")
            self.assertFalse(result["deviceValidationPassed"])
            self.assertFalse(result["deliveredIPAExecuted"])
            self.assertFalse(result["paidFeatureOverrides"])
            self.assertEqual(result["configuration"], "Debug")
            self.assertEqual(result["targetedTests"]["cloudKitAndLocalServicesConfiguration"]["totalTestCount"], 9)
            self.assertEqual(result["targetedTests"]["localProductFeatures"]["totalTestCount"], 50)
            self.assertEqual(result["targetedTests"]["localProductFeatures"]["expectedExecutions"], 68)
            self.assertEqual(result["targetedTests"]["searchAutoPaging"]["totalTestCount"], 12)
            self.assertEqual(result["targetedTests"]["TXTReaderUI"]["totalTestCount"], 1)
            for key, value in (("totalTestCount", 0), ("totalTestCount", 11), ("totalTestCount", 19),
                               ("passedTests", 11), ("passedTests", True), ("failedTests", 1),
                               ("skippedTests", 1), ("skippedTests", None)):
                with self.subTest(paging=(key, value)), self.assertRaises(ValueError):
                    smoke.result(audit, settings, unit, ui, {**paging, key: value}, product, product_tests)
            for missing in paging:
                with self.subTest(missingPagingField=missing), self.assertRaises(ValueError):
                    smoke.result(audit, settings, unit, ui, {key: value for key, value in paging.items() if key != missing}, product, product_tests)
            with self.assertRaises(ValueError):
                smoke.result(audit, settings, unit, ui, None, product, product_tests)
            for change in ({"totalTestCount": 0}, {"passedTests": 26}, {"skippedTests": 1}, {"failedTests": 1}):
                with self.subTest(product=change), self.assertRaises(ValueError):
                    smoke.result(audit, settings, unit, ui, paging, {**product, **change}, product_tests)
            with self.assertRaises(ValueError):
                smoke.result(audit, settings, unit, ui, paging, product, None)
            info["YueduLocalExperience"] = False
            self.write(app / "Info.plist", plistlib.dumps(info))
            with self.assertRaisesRegex(ValueError, "local-mode Info"):
                smoke.result(audit, settings, unit, ui, paging, product, product_tests)

    def test_result_cli_requires_the_independent_paging_summary(self):
        args = ["smoke-tools.py", "result", "--audit", "audit.json", "--settings", "settings.json",
                "--unit", "configuration.json", "--ui", "txt.json", "--output", "result.json"]
        with patch.object(smoke.sys, "argv", args), redirect_stderr(io.StringIO()) as errors, \
                self.assertRaises(SystemExit) as failure:
            smoke.main()
        self.assertEqual(failure.exception.code, 2)
        self.assertIn("--paging", errors.getvalue())

    def test_result_cli_requires_local_product_method_evidence(self):
        args = ["smoke-tools.py", "result", "--audit", "audit.json", "--settings", "settings.json",
                "--unit", "configuration.json", "--ui", "txt.json", "--paging", "paging.json",
                "--product", "product.json", "--output", "result.json"]
        with patch.object(smoke.sys, "argv", args), redirect_stderr(io.StringIO()) as errors, self.assertRaises(SystemExit):
            smoke.main()
        self.assertIn("--product-tests", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
