#!/usr/bin/env python3
"""Small portable admission/settings/budget checks; no Apple build or runtime claim."""
import copy
from contextlib import contextmanager, nullcontext
import fnmatch
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("renewal_diagnostic_gate_tests", HERE / "renewal-diagnostic-tools.py")
diagnostic = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostic)
config = diagnostic.config
SOURCE = "a" * 40


class DiagnosticGates(unittest.TestCase):
    def settings(self, root):
        return [{"target": target, "buildSettings": {
            "CONFIGURATION": "Release", "SWIFT_VERSION": "5.0", "IPHONEOS_DEPLOYMENT_TARGET": "18.0",
            "PLATFORM_NAME": "iphoneos", "FULL_PRODUCT_NAME": product, "PRODUCT_BUNDLE_IDENTIFIER": identifier,
            "ARCHS": "arm64", "CODE_SIGNING_ALLOWED": "NO", "CODE_SIGNING_REQUIRED": "NO", "ENABLE_DEBUG_DYLIB": "NO",
            "CODE_SIGN_ENTITLEMENTS": "", "GATEWAY_BASE_URL": "", "YUEDU_LOCAL_EXPERIENCE": "YES",
            "TARGET_BUILD_DIR": str(root), "MARKETING_VERSION": "3.0", "CURRENT_PROJECT_VERSION": "29",
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone", "SWIFT_COMPILATION_MODE": "singlefile",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "", "GCC_PREPROCESSOR_DEFINITIONS": "NDEBUG=1",
            "OTHER_SWIFT_FLAGS": "-D YUEDU_LOCAL_EXPERIENCE"}}
            for target, (product, identifier) in config.DIAGNOSTIC_TARGETS.items()]

    @contextmanager
    def controlled_build(self):
        """Real files/settings/bundles/ZIP; only the independent JNI audit is owned."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve(); build = root / "build"; work = root / "work"
            payload = build / "output/Payload"; app = payload / config.MAIN_PRODUCT
            app.mkdir(parents=True); work.mkdir(); (root / "Resources").mkdir()
            bundles = [app]
            for name in config.EXTENSIONS:
                bundle = app / "PlugIns" / name; bundle.mkdir(parents=True); bundles.append(bundle)
            for index, bundle in enumerate(bundles):
                info = {"CFBundleIdentifier": config.MAIN_BUNDLE if index == 0 else config.EXTENSIONS[bundle.name][0],
                    "CFBundleExecutable": "owned-executable", "CFBundleShortVersionString": "3.0", "CFBundleVersion": "29",
                    "YueduExperienceSourceCommit": SOURCE, "GatewayBaseURL": "", **config.LOCAL_FLAGS}
                if index:
                    info["NSExtension"] = {"NSExtensionPointIdentifier": config.EXTENSIONS[bundle.name][1]}
                (bundle / "Info.plist").write_bytes(plistlib.dumps(info))
                (bundle / "owned-executable").write_bytes(b"owned-portable-fixture")
                (bundle / "GoogleService-Info.plist").write_bytes(plistlib.dumps(config.synthetic_config()))
            ipa = build / "output/YueduReader-experience-unsigned.ipa"
            with zipfile.ZipFile(ipa, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                for item in app.rglob("*"):
                    if item.is_file(): archive.write(item, "Payload/" + str(item.relative_to(payload)).replace(os.sep, "/"))
            raw_settings = self.settings(payload)
            (build / "build-settings.json").write_text(json.dumps(raw_settings))
            proof = {"sourceCommit": SOURCE, "workflowRunID": "123", "status": "restored", "nativeRuntimeRecompiled": False}
            (build / "native-reuse.json").write_text(json.dumps(proof))
            (work / "native-restore.json").write_text(json.dumps(proof))
            receipt = {"sourceCommit": SOURCE, "workflowRunID": "123"}
            # Windows does not execute JNI. Its separate payload validator is
            # the sole controlled boundary; every package/version gate below runs.
            with patch.object(config, "verify_jvm_payload", return_value={"ownedPortableJNIAudit": True}) as native_audit, \
                    patch.multiple(diagnostic, REPO=root, BUILD=build, WORK=work):
                settings = config.inspect_settings(raw_settings, with_jvm=True, diagnostic=True)
                manifest = {"artifactKind": config.DIAGNOSTIC_KIND, "sourceCommit": SOURCE,
                    "diagnosticOnly": True, "releaseAcceptance": False, "S3Acceptance": "not_run",
                    "configuration": "Release", "platform": "iPhoneOS", "architecture": "arm64", "build": "29",
                    "signed": False, "deviceCompilationPassed": True, "jvmIntegratedIntoReading": True,
                    "deviceValidationPassed": False, "actualBuildSettings": settings,
                    "ipaBytes": ipa.stat().st_size, "ipaSHA256": diagnostic.full.fact(ipa)["sha256"],
                    "bundleValidation": config.bundle_summary(app, with_jvm=True),
                    "packageBudget": config.diagnostic_package_budget(app, ipa)}
                manifest_path = build / "output/build-manifest.json"
                manifest_path.write_text(json.dumps(manifest))
                yield SimpleNamespace(root=root, build=build, work=work, app=app, ipa=ipa,
                    bundles=bundles, manifest=manifest, manifest_path=manifest_path,
                    receipt=receipt, raw_settings=raw_settings, proof=proof, native_audit=native_audit)

    def test_validate_build_accepts_new_three_bundle_version_and_rejects_older_versions(self):
        self.assertEqual(config.DIAGNOSTIC_BUILD_VERSION, "29")
        shell = (HERE / "build.sh").read_text(encoding="utf-8")
        self.assertEqual(re.findall(r"(?m)^  CURRENT_PROJECT_VERSION=([0-9]+)$", shell), ["29"])
        with self.controlled_build() as fixture:
            validated = diagnostic.validate_build(fixture.receipt)
            self.assertEqual(validated["manifest"], fixture.manifest)
            self.assertEqual([row["build"] for row in validated["manifest"]["bundleValidation"]["bundles"]], ["29"] * 3)
            self.assertTrue(validated["packageBudget"]["crcVerified"])
            for version in ("27", "28"):
                invalid = copy.deepcopy(fixture.manifest); invalid["build"] = version
                fixture.manifest_path.write_text(json.dumps(invalid))
                with self.subTest(manifest_build=version), self.assertRaisesRegex(ValueError, "build29 diagnostic manifest"):
                    diagnostic.validate_build(fixture.receipt)
                fixture.manifest_path.write_text(json.dumps(fixture.manifest))
                # Exercise every actual embedded bundle and its identity gate.
                for bundle in fixture.bundles:
                    path = bundle / "Info.plist"; original = path.read_bytes()
                    info = plistlib.loads(original); info["CFBundleVersion"] = version
                    path.write_bytes(plistlib.dumps(info))
                    try:
                        with self.subTest(bundle=bundle.name, build=version), self.assertRaises(ValueError):
                            diagnostic.validate_build(fixture.receipt)
                    finally: path.write_bytes(original)
                # A coherent old App/Widget/Share set must also fail even when
                # its real bundle summary is honestly recorded in the manifest.
                originals = [(bundle / "Info.plist", (bundle / "Info.plist").read_bytes()) for bundle in fixture.bundles]
                for path, raw in originals:
                    info = plistlib.loads(raw); info["CFBundleVersion"] = version; path.write_bytes(plistlib.dumps(info))
                invalid = copy.deepcopy(fixture.manifest); invalid["bundleValidation"] = config.bundle_summary(fixture.app, with_jvm=True)
                fixture.manifest_path.write_text(json.dumps(invalid))
                try:
                    with self.subTest(all_bundles_build=version), self.assertRaisesRegex(ValueError, "embedded bundle source/build"):
                        diagnostic.validate_build(fixture.receipt)
                finally:
                    for path, raw in originals: path.write_bytes(raw)
                    fixture.manifest_path.write_text(json.dumps(fixture.manifest))
                invalid_settings = copy.deepcopy(fixture.raw_settings)
                for row in invalid_settings: row["buildSettings"]["CURRENT_PROJECT_VERSION"] = version
                (fixture.build / "build-settings.json").write_text(json.dumps(invalid_settings))
                try:
                    with self.subTest(settings_build=version), self.assertRaises(ValueError): diagnostic.validate_build(fixture.receipt)
                finally: (fixture.build / "build-settings.json").write_text(json.dumps(fixture.raw_settings))
            self.assertEqual(diagnostic.validate_build(fixture.receipt)["manifest"]["build"], "29")

    def test_validate_build_retains_manifest_source_runtime_settings_hash_and_budget_gates(self):
        with self.controlled_build() as fixture:
            for key,value in (("artifactKind", "other"), ("sourceCommit", "b" * 40), ("diagnosticOnly", False),
                    ("releaseAcceptance", True), ("S3Acceptance", "passed"), ("configuration", "Debug"),
                    ("platform", "iPhoneSimulator"), ("architecture", "x86_64"), ("signed", True),
                    ("deviceCompilationPassed", False), ("jvmIntegratedIntoReading", False), ("deviceValidationPassed", True),
                    ("actualBuildSettings", {}), ("ipaBytes", 1), ("ipaSHA256", "0" * 64),
                    ("bundleValidation", {}), ("packageBudget", {})):
                invalid = copy.deepcopy(fixture.manifest); invalid[key] = value
                fixture.manifest_path.write_text(json.dumps(invalid))
                with self.subTest(manifest_field=key), self.assertRaises(ValueError): diagnostic.validate_build(fixture.receipt)
            fixture.manifest_path.write_text(json.dumps(fixture.manifest))
            for bundle in fixture.bundles:
                path=bundle / "Info.plist"; original=path.read_bytes()
                info=plistlib.loads(original); info["YueduExperienceSourceCommit"]="b" * 40
                path.write_bytes(plistlib.dumps(info))
                invalid=copy.deepcopy(fixture.manifest); invalid["bundleValidation"]=config.bundle_summary(fixture.app,with_jvm=True)
                fixture.manifest_path.write_text(json.dumps(invalid))
                try:
                    with self.subTest(source_bundle=bundle.name), self.assertRaisesRegex(ValueError,"embedded bundle source/build"):
                        diagnostic.validate_build(fixture.receipt)
                finally:
                    path.write_bytes(original); fixture.manifest_path.write_text(json.dumps(fixture.manifest))
            fixture.native_audit.side_effect=ValueError("owned JNI payload rejected")
            with self.assertRaisesRegex(ValueError,"owned JNI payload rejected"): diagnostic.validate_build(fixture.receipt)
            fixture.native_audit.side_effect=None
            for key,value in (("sourceCommit","b"*40),("workflowRunID","456"),("status","changed"),("nativeRuntimeRecompiled",True)):
                proof=dict(fixture.proof,**{key:value})
                (fixture.build/"native-reuse.json").write_text(json.dumps(proof))
                with self.subTest(restoration_field=key),self.assertRaisesRegex(ValueError,"native restoration proof changed"):
                    diagnostic.validate_build(fixture.receipt)
            (fixture.build/"native-reuse.json").write_text(json.dumps(fixture.proof))
            source_pack=fixture.root/"Resources/BuiltInBookSources.json";source_pack.write_text("[]")
            try:
                with self.assertRaisesRegex(ValueError,"source resources|book-source resources"): diagnostic.validate_build(fixture.receipt)
            finally: source_pack.unlink()
            with patch.object(config,"DIAGNOSTIC_FILE_BYTES",1),self.assertRaisesRegex(ValueError,"file exceeds"):
                diagnostic.validate_build(fixture.receipt)
            self.assertTrue(diagnostic.validate_build(fixture.receipt)["packageBudget"]["crcVerified"])

    def test_three_actual_targets_require_diagnostic_settings_without_debug_or_optimization_override(self):
        with tempfile.TemporaryDirectory() as tmp:
            valid = self.settings(Path(tmp).resolve())
            result = config.inspect_settings(valid, with_jvm=True, diagnostic=True)
            self.assertEqual(set(result["diagnosticTargets"]), set(config.DIAGNOSTIC_TARGETS))
            self.assertTrue(result["diagnosticOnly"])
            self.assertFalse(result["releaseAcceptance"])
            self.assertEqual(result["S3Acceptance"], "not_run")
            # The ordinary path retains its original output contract.
            self.assertNotIn("diagnosticOnly", config.inspect_settings(valid, with_jvm=True))
            for index in range(3):
                for key, value in [("CONFIGURATION", "Debug"), ("SWIFT_OPTIMIZATION_LEVEL", "-O"),
                    ("SWIFT_COMPILATION_MODE", "wholemodule"), ("ENABLE_DEBUG_DYLIB", "YES"), ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "DEBUG"),
                    ("GCC_PREPROCESSOR_DEFINITIONS", "DEBUG=0"), ("OTHER_SWIFT_FLAGS", "-DDEBUG=0"),
                    ("OTHER_SWIFT_FLAGS", "-D DEBUG"), ("OTHER_SWIFT_FLAGS", "-Osize"),
                    ("OTHER_SWIFT_FLAGS", "-whole-module-optimization"), ("CURRENT_PROJECT_VERSION", "17"),
                    ("PRODUCT_BUNDLE_IDENTIFIER", "changed.fixture"), ("PLATFORM_NAME", "iphonesimulator")]:
                    invalid = copy.deepcopy(valid); invalid[index]["buildSettings"][key] = value
                    with self.subTest(target=index, key=key, value=value), self.assertRaises(ValueError):
                        config.inspect_settings(invalid, with_jvm=True, diagnostic=True)
            for invalid in (valid[:-1], valid + [valid[1]]):
                with self.assertRaises(ValueError):
                    config.inspect_settings(invalid, with_jvm=True, diagnostic=True)
            with self.assertRaises(ValueError):
                config.inspect_settings(valid, with_jvm=False, diagnostic=True)

    def test_exact_diagnostic_tag_does_not_trigger_other_builds_and_rejects_wrong_source_or_refs(self):
        tag = "yuedu-renewal-diagnostic-" + SOURCE[:7]
        env = {"GITHUB_SHA": SOURCE, "GITHUB_RUN_ID": "123", "GITHUB_REF_NAME": tag, "GITHUB_REF": "refs/tags/" + tag}
        with patch.object(diagnostic.native.smoke, "source_sha", return_value=SOURCE), patch.object(diagnostic.sys, "platform", "darwin"):
            with patch.dict(os.environ, env, clear=True):
                self.assertEqual(diagnostic.source(), SOURCE)
            for key, value in [("GITHUB_SHA", "b" * 40), ("GITHUB_REF", "refs/heads/" + tag),
                               ("GITHUB_REF_NAME", "yuedu-renewal-package-" + SOURCE[:7]), ("GITHUB_RUN_ID", "")]:
                with self.subTest(key=key), patch.dict(os.environ, dict(env, **{key: value}), clear=True), self.assertRaises(ValueError):
                    diagnostic.source()
        for pattern in ("reader-renewal-*", "legado-native-reader-test-*", "reader-legado-*", "yuedu-renewal-package-*"):
            self.assertFalse(fnmatch.fnmatchcase(tag, pattern))
        self.assertEqual(diagnostic.ENROLLMENT_CASE,
            "SelfRenewalDeveloperAuthenticationTests/connectsOnlyThroughActualMaterialAccountValidation")
        summary = {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0,
            "expectedFailures": 0, "devicesAndConfigurations": [
                {"passedTests": 1, "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}]}
        case = {"nodeType": "Test Case", "nodeIdentifier": "yuedu appTests/" + diagnostic.ENROLLMENT_CASE + "()", "result": "Passed"}
        tree = {"testNodes": [{"nodeType": "Test Suite", "children": [case]}]}
        self.assertEqual(diagnostic.verify_enrollment(summary, tree)["cases"], [diagnostic.ENROLLMENT_CASE])
        for invalid in ({"testNodes": []}, {"testNodes": [case, case]},
                {"testNodes": [dict(case, result="Failed")]},
                {"testNodes": [dict(case, nodeIdentifier="OtherTests/anotherCase()")]},
                {"testNodes": [dict(case, children={})]}):
            with self.subTest(tree=invalid), self.assertRaises(ValueError):
                diagnostic.verify_enrollment(summary, invalid)
        for invalid in (dict(summary, totalTestCount=2, failedTests=1), dict(summary, expectedFailures=1),
                dict(summary, devicesAndConfigurations=[]), dict(summary, passedTests=0, skippedTests=1)):
            with self.subTest(summary=invalid), self.assertRaises(ValueError):
                diagnostic.verify_enrollment(invalid, tree)
        workflow = (HERE.parents[1] / ".github/workflows/yuedu-renewal-diagnostic.yml").read_text()
        self.assertLess(workflow.index("name: Retain the diagnostic unsigned device package"), workflow.index("prepare-simulator"))
        self.assertLess(workflow.index("prepare-simulator"), workflow.index("run-enrollment"))
        self.assertLess(workflow.index("name: Retain the diagnostic unsigned device package"), workflow.index("run-source-change"))
        self.assertLess(workflow.index("name: Retain the diagnostic unsigned device package"), workflow.index("run-current-app-preparation"))
        self.assertLess(workflow.index("name: Retain the diagnostic unsigned device package"), workflow.index("run-original-source-admission"))
        phases = ("run-enrollment", "run-current-app-preparation", "run-original-source-admission",
                  "run-original-preview-completion", "run-first-pairing-configuration", "run-source-change")
        self.assertEqual([workflow.index(phase) for phase in phases], sorted(workflow.index(phase) for phase in phases))
        self.assertNotIn("continue-on-error", workflow)
        self.assertNotIn("renewal-package-tools.py run", workflow)
        self.assertNotIn("full-application-signing-tools.py", workflow)

    def test_focused_authentication_group_is_an_explicit_private_simulator_overlay(self):
        original = (diagnostic.REPO / config.PROJECT).read_bytes()
        ordinary, ordinary_record = config.project_overlay(original)
        focused, record = config.project_overlay(original, diagnostic_auth_tests=True)
        self.assertNotEqual(ordinary, focused)
        self.assertEqual(record["diagnosticAuthTestRoot"], config.DIAGNOSTIC_AUTH_TEST_ROOT)
        self.assertTrue(record["expectedTrackedOverlay"])
        self.assertIn(b'path = "' + config.DIAGNOSTIC_AUTH_TEST_ROOT.encode() + b'";', focused)
        for path in (b"path = Modules;", b"path = Targets/Yuedu;", b"path = Widget;", b"path = ShareExtension;"):
            self.assertEqual(original.count(path), focused.count(path))
        settings = diagnostic.native.smoke.config
        original_adapter = settings.project_overlay
        with diagnostic.enrollment_project_overlay():
            self.assertEqual(settings.project_overlay(original), (focused, record))
            self.assertTrue(settings.review_project_overlay(record, original, focused))
            with self.assertRaises(ValueError):
                settings.review_project_overlay(record, original, focused.replace(b"path = Modules;", b"path = Elsewhere;"))
        self.assertIs(settings.project_overlay, original_adapter)
        self.assertEqual(config.project_overlay(original), (ordinary, ordinary_record))
        with self.assertRaises(ValueError):
            config.review_project_overlay(record, original, focused)
        for changed in (original.replace(b"path = Tests/iOS;", b"path = OtherTests;"), original + original):
            with self.assertRaises(ValueError):
                config.project_overlay(changed, diagnostic_auth_tests=True)

    def test_focused_source_closure_rejects_extra_changed_or_missing_inputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            stage = root / config.DIAGNOSTIC_AUTH_TEST_ROOT
            for relative in diagnostic.FOCUSED_SOURCES:
                target = root / relative; target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes((diagnostic.REPO / relative).read_bytes())
            resource = root / diagnostic.SDK_RESOURCE
            resource.write_text('{"controlledFixture":true}')
            unrelated = resource.with_name("UnrelatedTests.swift")
            unrelated.write_text("import Testing\n@Test func unrelated() {}\n")
            with patch.object(diagnostic, "REPO", root), patch.object(diagnostic, "SIMULATOR_TESTS", stage):
                record = diagnostic.enrollment_source_stage(create=True)
                self.assertEqual(len(diagnostic.ENROLLMENT_SOURCES), 4)
                self.assertEqual(record["swiftSourceCount"], 19)
                self.assertEqual(record, diagnostic.enrollment_source_stage())
                self.assertEqual({row["sourcePath"] for row in record["files"]},
                    {*diagnostic.FOCUSED_SOURCES, diagnostic.SDK_RESOURCE})
                self.assertEqual({path.name for path in stage.rglob("*.swift")},
                    {Path(relative).name for relative in diagnostic.FOCUSED_SOURCES})
                self.assertTrue(unrelated.is_file())
                self.assertFalse((stage / "yuedu appTests" / unrelated.name).exists())
                for omitted in (*diagnostic.CURRENT_APP_PREPARATION_SOURCES, *diagnostic.ORIGINAL_SOURCE_ADMISSION_SOURCES,
                                *diagnostic.ORIGINAL_PREVIEW_COMPLETION_SOURCES, *diagnostic.FIRST_PAIRING_CONFIGURATION_SOURCES):
                    with self.subTest(omitted=omitted), patch.object(diagnostic, "FOCUSED_SOURCES",
                            tuple(path for path in diagnostic.FOCUSED_SOURCES if path != omitted)), self.assertRaises(ValueError):
                        diagnostic.enrollment_source_stage()
                with self.assertRaises(ValueError):
                    diagnostic.enrollment_source_stage(create=True)
                for relative in (diagnostic.ENROLLMENT_SOURCES[1], *diagnostic.ORIGINAL_SOURCE_ADMISSION_SOURCES,
                                 *diagnostic.ORIGINAL_PREVIEW_COMPLETION_SOURCES, *diagnostic.FIRST_PAIRING_CONFIGURATION_SOURCES):
                    fixture = stage / Path(relative).relative_to("Tests/iOS")
                    raw = fixture.read_bytes(); fixture.write_bytes(raw + b"\n// changed\n")
                    with self.assertRaises(ValueError):
                        diagnostic.enrollment_source_stage()
                    fixture.write_bytes(raw)
                    extra = fixture.with_name("Unexpected.swift"); extra.write_text("// unexpected source")
                    with self.assertRaises(ValueError):
                        diagnostic.enrollment_source_stage()
                    extra.unlink(); fixture.unlink()
                    with self.assertRaises(FileNotFoundError):
                        diagnostic.enrollment_source_stage()
                    fixture.write_bytes(raw)

    def test_source_picker_case_gates_reject_missing_duplicate_wrong_failed_or_skipped_cases(self):
        self.assertEqual([len(cases) for cases in diagnostic.SOURCE_CHANGE_GROUPS.values()], [7, 7, 11, 8])
        self.assertEqual(len(set(diagnostic.FOCUSED_SOURCES)), 19)
        for cases in (*diagnostic.SOURCE_CHANGE_GROUPS.values(), diagnostic.ORIGINAL_SOURCE_ADMISSION_CASES,
                      *diagnostic.ORIGINAL_PREVIEW_COMPLETION_GROUPS.values(), diagnostic.FIRST_PAIRING_CONFIGURATION_CASES):
            count = len(cases)
            summary = {"totalTestCount": count, "passedTests": count, "failedTests": 0, "skippedTests": 0,
                "expectedFailures": 0, "devicesAndConfigurations": [
                    {"passedTests": count, "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}]}
            nodes = [{"nodeType": "Test Case", "nodeIdentifier": "yuedu appTests/" + case + "()", "result": "Passed"}
                     for case in cases]
            tree = {"testNodes": [{"nodeType": "Test Suite", "children": list(reversed(nodes))}]}
            self.assertEqual(set(diagnostic.verify_cases(summary, tree, cases)["cases"]), set(cases))
            for invalid in (nodes[:-1], nodes + [nodes[0]],
                    *((nodes[:-1] + [nodes[0]],) if count > 1 else ()),
                    [dict(nodes[0], result="Failed"), *nodes[1:]],
                    [dict(nodes[0], nodeIdentifier="OtherTests/anotherCase()"), *nodes[1:]]):
                with self.subTest(cases=cases, tree=invalid), self.assertRaises(ValueError):
                    diagnostic.verify_cases(summary, {"testNodes": invalid}, cases)
            for invalid in (dict(summary, passedTests=count - 1, skippedTests=1),
                    dict(summary, expectedFailures=1), dict(summary, devicesAndConfigurations=[])):
                with self.subTest(cases=cases, summary=invalid), self.assertRaises(ValueError):
                    diagnostic.verify_cases(invalid, tree, cases)
        with self.assertRaises(ValueError):
            diagnostic.verify_cases({}, {}, ())
        with self.assertRaises(ValueError):
            diagnostic.verify_cases({}, {}, (diagnostic.ENROLLMENT_CASE, diagnostic.ENROLLMENT_CASE))

    def test_current_app_group_requires_all_four_exact_cases_and_existing_transitive_sources(self):
        self.assertEqual(diagnostic.CURRENT_APP_PREPARATION_CASES, tuple("SelfRenewalAppExecutionTests/" + name for name in (
            "preparesCurrentApplicationWithoutDeviceOrRemoteWork",
            "appOwnerPreparesAndSubmitsActualCandidateWithoutAutomaticRetry",
            "appSessionCancellationDrainsActualTransportAndKeepsCandidate",
            "restoresValidatedMaterialObservationAfterColdBootstrap")))
        self.assertEqual({Path(path).name for path in diagnostic.CURRENT_APP_PREPARATION_SOURCES}, {
            "SelfRenewalAppExecutionTests.swift", "SelfRenewalControlledPackageSignerTests.swift",
            "SelfRenewalControlledPackageFixture.swift", "SelfRenewalSDKOwnedPackageFixture.swift",
            "SelfRenewalAuthenticatedInstallationFixture.swift", "SelfRenewalSigningOwnedPKIFixture.swift"})
        self.assertTrue(set(diagnostic.CURRENT_APP_PREPARATION_SOURCES) <= set(diagnostic.FOCUSED_SOURCES) <= set(diagnostic.INPUTS))
        self.assertEqual(sum(Path(path).name == "SelfRenewalSigningOwnedPKIFixture.swift" for path in diagnostic.FOCUSED_SOURCES), 1)
        for name in ("SelfRenewalAppOwner.swift", "SelfRenewalAppSession.swift"):
            self.assertIn("Modules/Services/SelfRenewal/" + name, diagnostic.INPUTS)
        cases = diagnostic.CURRENT_APP_PREPARATION_CASES
        summary = {"totalTestCount": 4, "passedTests": 4, "failedTests": 0, "skippedTests": 0,
            "expectedFailures": 0, "devicesAndConfigurations": [
                {"passedTests": 4, "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}]}
        nodes = [{"nodeType": "Test Case", "nodeIdentifier": "yuedu appTests/" + case + "()", "result": "Passed"}
                 for case in cases]
        self.assertEqual(diagnostic.verify_cases(summary, {"testNodes": nodes}, cases)["cases"], list(cases))
        for invalid in (nodes[:-1], nodes + [nodes[0]], nodes[:-1] + [nodes[0]],
                [dict(nodes[0], result="Failed"), *nodes[1:]],
                [*nodes[:-1], dict(nodes[-1], nodeIdentifier=diagnostic.ENROLLMENT_CASE + "()")]):
            with self.subTest(tree=invalid), self.assertRaises(ValueError):
                diagnostic.verify_cases(summary, {"testNodes": invalid}, cases)
        for invalid in (dict(summary, totalTestCount=3, passedTests=3),
                dict(summary, passedTests=3, failedTests=1), dict(summary, passedTests=3, skippedTests=1),
                dict(summary, expectedFailures=1), dict(summary, devicesAndConfigurations=[])):
            with self.subTest(summary=invalid), self.assertRaises(ValueError):
                diagnostic.verify_cases(invalid, {"testNodes": nodes}, cases)

    def test_original_admission_roster_binds_actual_service_and_its_exact_budget_cases(self):
        self.assertEqual(diagnostic.ORIGINAL_SOURCE_ADMISSION_SOURCES,
            ("Tests/iOS/yuedu appTests/LegadoOriginalSourceRevisionBudgetTests.swift",))
        self.assertEqual(diagnostic.ORIGINAL_SOURCE_ADMISSION_CASES,
            tuple("LegadoOriginalSourceRevisionBudgetTests/" + name for name in (
                "scans1310OriginalSourcesThroughOwnedExecutor", "retainsRevisionHighWaterAfterLargeScan",
                "rejectsCountBudgetWithoutDamagingAdmittedSources",
                "enforcesUTF8PayloadBudgetWithoutConsumingRejectedAdmission")))
        self.assertTrue(set(diagnostic.ORIGINAL_SOURCE_ADMISSION_SOURCES) <= set(diagnostic.FOCUSED_SOURCES) <= set(diagnostic.INPUTS))
        for name in ("LegadoMainJSSourceService.swift", "LegadoPersistentStateHost.swift"):
            self.assertIn("Modules/Services/Online/" + name, diagnostic.INPUTS)

    def test_additional_invocations_keep_independent_budgets_and_reject_execution_failure(self):
        for label, cases, run, unverified in (
                ("current-app-preparation", diagnostic.CURRENT_APP_PREPARATION_CASES,
                 diagnostic.run_current_app_preparation, "actualDeviceRenewalValidated"),
                ("original-source-admission", diagnostic.ORIGINAL_SOURCE_ADMISSION_CASES,
                 diagnostic.run_original_source_admission, "physicalDeviceSourceSwitchVerified"),
                ("first-pairing-configuration", diagnostic.FIRST_PAIRING_CONFIGURATION_CASES,
                 diagnostic.run_first_pairing_configuration, "actualDeviceRenewalValidated")):
            with self.subTest(group=label):
                self.check_controlled_invocation(label, cases, run, unverified)

    def check_controlled_invocation(self, label, cases, run, unverified, suffix="()"):
        count = len(cases)
        prefix = "renewal-diagnostic-" + label
        summary = {"totalTestCount": count, "passedTests": count, "failedTests": 0, "skippedTests": 0,
            "expectedFailures": 0, "devicesAndConfigurations": [
                {"passedTests": count, "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}]}
        tree = {"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": "yuedu appTests/" + case + suffix, "result": "Passed"}
                              for case in cases]}
        for execution_failed in (False, True):
            with self.subTest(execution_failed=execution_failed), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp).resolve()
                work = root / "work"; work.mkdir()
                logs = root / "logs"; logs.mkdir()
                simulator = root / "simulator"; simulator.mkdir()
                produced = root / "produced"; produced.mkdir()
                resource = root / diagnostic.SDK_RESOURCE; resource.parent.mkdir(parents=True)
                resource.write_text("{}")
                manifest = produced / "sdk-produced-fixture-manifest.json"; manifest.write_text("{}")
                (simulator / "overlays.json").write_text("{}")
                receipt = {"sourceCommit": SOURCE}
                staged = {"test-only-stage": True}
                diagnostic.full.write_new(work / "enrollment-prepared.json", dict(receipt,
                    requiredCase=diagnostic.ENROLLMENT_CASE, testSourceStage=staged,
                    fixture=diagnostic.full.fact(resource), producerManifest=diagnostic.full.fact(manifest)))
                calls = []
                def command(directory, name, argv, seconds):
                    calls.append((name, [str(value) for value in argv], seconds))
                    if name.endswith("-test"):
                        if execution_failed:
                            raise RuntimeError("test execution failed or timed out")
                    else:
                        diagnostic.full.write_new(directory / (name + ".log"), summary if name.endswith("-summary") else tree)
                with patch.multiple(diagnostic, REPO=root, WORK=work, LOGS=logs, SIMULATOR=simulator, PRODUCED=produced), \
                        patch.object(diagnostic, "check_binding", return_value=receipt), \
                        patch.object(diagnostic, "enrollment_source_stage", return_value=staged), \
                        patch.object(diagnostic, "enrollment_project_overlay", side_effect=nullcontext), \
                        patch.object(diagnostic.native.smoke, "review_overlays"), \
                        patch.object(diagnostic.full, "command", side_effect=command):
                    if execution_failed:
                        with self.assertRaisesRegex(RuntimeError, "Controlled regression groups failed: " + label) as failure:
                            run()
                        self.assertIsInstance(failure.exception.__cause__, RuntimeError)
                        self.assertEqual(str(failure.exception.__cause__), "test execution failed or timed out")
                    else:
                        run()
                self.assertEqual([name for name, _, _ in calls], [prefix + "-" + kind
                    for kind in ("test", "summary", "tests")])
                argv = calls[0][1]
                self.assertEqual(calls[0][2], 660)
                self.assertEqual(argv[argv.index("-t") + 1], "600")
                self.assertEqual(argv[argv.index("-resultBundlePath") + 1], str(root / (".build/" + prefix + ".xcresult")))
                self.assertEqual([arg for arg in argv if arg.startswith("-only-testing:")],
                    ["-only-testing:yuedu appTests/" + case + suffix for case in cases])
                self.assertIn("SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG LEGADO_REQUIRE_NATIVE_MAINJS", argv)
                result = json.loads((logs / (prefix + "-result.json")).read_bytes())
                self.assertEqual(result["status"], "failed" if execution_failed else "passed")
                self.assertEqual(result["requiredCases"], list(cases))
                self.assertFalse(result[unverified])

    def test_failed_group_is_persisted_before_later_independent_group_and_overall_failure(self):
        self._check_failed_group_isolation(dict(list(diagnostic.SOURCE_CHANGE_GROUPS.items())[:2]))

    def test_original_preview_completion_keeps_real_native_case_and_isolates_lifecycle_failures(self):
        groups = diagnostic.ORIGINAL_PREVIEW_COMPLETION_GROUPS
        self.assertEqual(list(groups), ["original-preview-lifecycle", "original-preview-native"])
        self.assertEqual([len(cases) for cases in groups.values()], [7, 1])
        self.assertEqual(groups["original-preview-native"],
            ("LegadoNativeOriginalReaderTests/testNativeOriginalWebBookPreviewTransferAndReopen",))
        self.assertEqual(set(diagnostic.ORIGINAL_PREVIEW_COMPLETION_SOURCES), {
            "Tests/iOS/yuedu appTests/LegadoPreviewStateOwnerTests.swift",
            "Tests/iOS/LegadoNativeOriginalReaderTests.swift",
            "Tests/iOS/yuedu appTests/SelfRenewalUserDataHandoffTests.swift"})
        self.assertTrue(set(diagnostic.ORIGINAL_PREVIEW_COMPLETION_SOURCES) <= set(diagnostic.FOCUSED_SOURCES) <= set(diagnostic.INPUTS))
        for path in ("Modules/Services/Online/LegadoMainJSSourceService.swift",
                "Modules/Services/Online/LegadoPersistentStateHost.swift",
                "Modules/Services/Online/LegadoPreviewStateOwner.swift",
                "Modules/Services/LibraryStore/OriginalRuntimeCommitCancellation.swift"):
            self.assertIn(path, diagnostic.INPUTS)
        for label, cases in groups.items():
            run = lambda: diagnostic.run_controlled_groups({label: cases}, regression_scope="owned-test",
                unverified={"physicalDeviceSourceSwitchVerified": False})
            self.check_controlled_invocation(label, cases, run, "physicalDeviceSourceSwitchVerified",
                suffix="" if label == "original-preview-native" else "()")
        # Actual controlled runner: a failed lifecycle invocation must persist its
        # failure before the independent real-native selector is attempted. Even
        # all-Passed exports cannot excuse a failed execution or a skipped case.
        self._check_failed_group_isolation(groups)

    def test_first_pairing_configuration_selects_only_four_owned_fixture_cases(self):
        self.assertEqual(diagnostic.FIRST_PAIRING_CONFIGURATION_CASES,
            tuple("SelfRenewalPairingIdentityImportTests/" + name for name in (
                "firstBindingPreservesReadyCandidateNamespaceMaterialsAndAnisette",
                "firstBindingRejectsUnknownOrRemoteFactsBeforeP12Import",
                "firstBindingChecksActualCandidateAndCancellationBeforeP12Import",
                "firstBindingLostAcknowledgementKeepsCandidateAndActualIdentity")))
        self.assertEqual(set(diagnostic.FIRST_PAIRING_CONFIGURATION_SOURCES), {
            "Tests/iOS/yuedu appTests/SelfRenewalPairingIdentityImportTests.swift",
            "Tests/iOS/yuedu appTests/SelfRenewalPairingOwnedPKCS12Fixture.swift"})
        self.assertTrue(set(diagnostic.FIRST_PAIRING_CONFIGURATION_SOURCES) <= set(diagnostic.FOCUSED_SOURCES) <= set(diagnostic.INPUTS))
        for path in ("Modules/Services/SelfRenewal/SelfRenewalAppSession.swift",
                "Modules/Services/SelfRenewal/SelfRenewalAppOwner.swift",
                "Modules/Services/SelfRenewal/SelfRenewalControlledRenewalCoordinator.swift",
                "Modules/Services/SelfRenewal/SelfRenewalPairingIdentityImport.swift",
                "Modules/Features/Settings/SelfRenewalSettingsView.swift"):
            self.assertIn(path, diagnostic.INPUTS)

    def _check_failed_group_isolation(self, groups):
        first, second = groups
        for mode in ("execution", "summary", "tree", "skipped", "export", "evidence-write"):
            with self.subTest(failure=mode), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp).resolve()
                work = root / "work"; work.mkdir()
                logs = root / "logs"; logs.mkdir()
                simulator = root / "simulator"; simulator.mkdir()
                produced = root / "produced"; produced.mkdir()
                resource = root / diagnostic.SDK_RESOURCE; resource.parent.mkdir(parents=True)
                resource.write_text("{}")
                manifest = produced / "sdk-produced-fixture-manifest.json"; manifest.write_text("{}")
                (simulator / "overlays.json").write_text("{}")
                receipt = {"sourceCommit": SOURCE}
                staged = {"test-only-stage": True}
                write_new = diagnostic.full.write_new
                write_new(work / "enrollment-prepared.json", dict(receipt,
                    requiredCase=diagnostic.ENROLLMENT_CASE, testSourceStage=staged,
                    fixture=diagnostic.full.fact(resource), producerManifest=diagnostic.full.fact(manifest)))
                first_result = logs / ("renewal-diagnostic-" + first + "-result.json")
                bundles, prior_failure_observed = [], []

                def write_result(path, value):
                    if mode == "evidence-write" and path == first_result:
                        raise OSError("failed result persistence unavailable")
                    write_new(path, value)

                def command(directory, name, argv, seconds):
                    argv = [str(value) for value in argv]
                    label = next(label for label in groups if name.startswith("renewal-diagnostic-" + label + "-"))
                    cases = groups[label]
                    if name.endswith("-test"):
                        bundle = Path(argv[argv.index("-resultBundlePath") + 1])
                        bundle.mkdir(parents=True)
                        bundles.append(bundle)
                        self.assertEqual(seconds, 660)
                        self.assertEqual(argv[argv.index("-t") + 1], "600")
                        self.assertEqual([arg for arg in argv if arg.startswith("-only-testing:")],
                            ["-only-testing:yuedu appTests/" + case +
                             ("" if label == "original-preview-native" else "()") for case in cases])
                        if label == second:
                            prior_failure_observed.append(json.loads(first_result.read_bytes())["status"])
                        if label == first and mode in ("execution", "evidence-write"):
                            raise RuntimeError("first group actual execution failed")
                        return
                    if label == first and mode == "export":
                        raise RuntimeError("first group xcresult export unavailable")
                    count = len(cases)
                    if name.endswith("-summary"):
                        counts = {"passedTests": count, "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}
                        if label == first and mode in ("summary", "skipped"):
                            counts["passedTests"] -= 1
                            counts["failedTests" if mode == "summary" else "skippedTests"] = 1
                        value = {"totalTestCount": count, **counts, "devicesAndConfigurations": [dict(counts)]}
                    else:
                        nodes = [{"nodeType": "Test Case", "nodeIdentifier": "yuedu appTests/" + case +
                                  ("" if label == "original-preview-native" else "()"),
                                  "result": "Passed"} for case in cases]
                        if label == first and mode == "tree":
                            nodes[0]["result"] = "Failed"
                        value = {"testNodes": nodes}
                    write_new(directory / (name + ".log"), value)

                with patch.multiple(diagnostic, REPO=root, WORK=work, LOGS=logs, SIMULATOR=simulator, PRODUCED=produced), \
                        patch.object(diagnostic, "check_binding", return_value=receipt), \
                        patch.object(diagnostic, "enrollment_source_stage", return_value=staged), \
                        patch.object(diagnostic, "enrollment_project_overlay", side_effect=nullcontext), \
                        patch.object(diagnostic.native.smoke, "review_overlays"), \
                        patch.object(diagnostic.full, "command", side_effect=command), \
                        patch.object(diagnostic.full, "write_new", side_effect=write_result):
                    if mode == "evidence-write":
                        with self.assertRaisesRegex(OSError, "failed result persistence unavailable"):
                            diagnostic.run_controlled_groups(groups, regression_scope="portable owned fixture",
                                unverified={"physicalDeviceSourceSwitchVerified": False})
                    else:
                        with self.assertRaisesRegex(RuntimeError, "Controlled regression groups failed: " + first) as failure:
                            diagnostic.run_controlled_groups(groups, regression_scope="portable owned fixture",
                                unverified={"physicalDeviceSourceSwitchVerified": False})
                        self.assertIsNotNone(failure.exception.__cause__)
                if mode == "evidence-write":
                    self.assertEqual(len(bundles), 1)
                    self.assertEqual(prior_failure_observed, [])
                    self.assertFalse(first_result.exists())
                    self.assertFalse((logs / ("renewal-diagnostic-" + second + "-result.json")).exists())
                    continue
                self.assertEqual(prior_failure_observed, ["failed"])
                self.assertEqual(len(bundles), 2)
                self.assertEqual(len(set(bundles)), 2)
                self.assertTrue(all(bundle.is_dir() for bundle in bundles))
                for label, expected_status in ((first, "failed"), (second, "passed")):
                    result = json.loads((logs / ("renewal-diagnostic-" + label + "-result.json")).read_bytes())
                    self.assertEqual(result["status"], expected_status)
                    self.assertEqual(result["requiredCases"], list(groups[label]))
                    self.assertFalse(result["physicalDeviceSourceSwitchVerified"])
                first_failed = json.loads(first_result.read_bytes())
                self.assertEqual(first_failed["observed"] is not None, mode == "execution")
                second_passed = json.loads((logs / ("renewal-diagnostic-" + second + "-result.json")).read_bytes())
                self.assertEqual(second_passed["cases"], list(groups[second]))
                self.assertEqual(second_passed["summary"]["passedTests"], len(groups[second]))

    def test_real_file_and_zip_budget_gates_and_old_s3_kind_rejection(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve(); app = root / "App"; app.mkdir()
            item = app / "executable"; item.write_bytes(b"synthetic-owned" * 2)
            ipa = root / "input.ipa"
            def archive(values):
                with zipfile.ZipFile(ipa, "w", compression=zipfile.ZIP_DEFLATED) as stream:
                    for name, value in values.items(): stream.writestr(name, value)
            archive({"Payload/App/executable": item.read_bytes()})
            # Small thresholds exercise the same strict production comparisons
            # without allocating hundreds of MiB of synthetic fixture data.
            with patch.object(config, "DIAGNOSTIC_FILE_BYTES", 512), patch.object(config, "DIAGNOSTIC_PACKAGE_BYTES", 1024):
                self.assertTrue(config.diagnostic_package_budget(app, ipa)["crcVerified"])
                item.write_bytes(b"x" * 513)
                with self.assertRaisesRegex(ValueError, "file exceeds"):
                    config.diagnostic_package_budget(app, ipa)
                item.write_bytes(b"x" * 400)
                (app / "second").write_bytes(b"x" * 400); (app / "third").write_bytes(b"x" * 400)
                with self.assertRaisesRegex(ValueError, "app exceeds"):
                    config.diagnostic_package_budget(app, ipa)
                (app / "second").unlink(); (app / "third").unlink(); item.write_bytes(b"small")
                archive({"Payload/App/executable": b"x" * 513})
                with self.assertRaisesRegex(ValueError, "ZIP entry"):
                    config.diagnostic_package_budget(app, ipa)
                archive({str(i): b"x" * 400 for i in range(3)})
                with self.assertRaisesRegex(ValueError, "ZIP exceeds"):
                    config.diagnostic_package_budget(app, ipa)
            producer = diagnostic.full.load("diagnostic_old_s3_gate_test", HERE / "owned-package-fixture/full-application-package.py")
            build = root / "build"; (build / "output").mkdir(parents=True)
            (build / "output/build-manifest.json").write_text(json.dumps({
                "sourceCommit": SOURCE, "artifactKind": config.DIAGNOSTIC_KIND, "configuration": "Release",
                "platform": "iPhoneOS", "architecture": "arm64", "signed": False,
                "deviceCompilationPassed": True, "jvmIntegratedIntoReading": True, "deviceValidationPassed": False}))
            base = SimpleNamespace(HERE=HERE / "owned-package-fixture", run=lambda argv: SOURCE.encode())
            with self.assertRaisesRegex(ValueError, "fresh Release"):
                producer.validate_input(base, build)


if __name__ == "__main__":
    unittest.main()
