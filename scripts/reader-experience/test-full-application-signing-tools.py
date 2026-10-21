#!/usr/bin/env python3
"""Portable protocol guards only: no Apple build/signing/Swift execution."""
import ast
import copy
import fnmatch
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import tempfile
from types import SimpleNamespace
import unittest
import zipfile
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("full_signing_guarded_tools", HERE / "full-application-signing-tools.py")
tools = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tools)


class FullApplicationSigningProtocolTests(unittest.TestCase):
    def test_native_proof_requires_same_job_both_platforms_and_current_ordinary_jar(self):
        pin = SimpleNamespace(BASELINE_BYTES=123, BASELINE_DIGEST="a" * 64)
        audited = {"jar": {"sha256": "b" * 64, "bytes": 10}, "nativeLayout": {"device": {"ok": True}, "simulator": {"ok": True}}}
        proof = {"workflowRunID": "1234", "sourceCommit": "c" * 40, "status": "restored",
            "nativeRuntimeRecompiled": False, "freshOrdinaryJVMRequired": True, "nativeExecutionVerified": False,
            "deviceValidationPassed": False, "nativeZIP": {"bytes": 123, "sha256": "a" * 64}, **audited}
        tools.validate_reuse(proof, "c" * 40, "1234", audited, pin)
        variants = [{"workflowRunID": "1233"}, {"sourceCommit": "d" * 40}, {"status": "pending"},
            {"nativeRuntimeRecompiled": True}, {"freshOrdinaryJVMRequired": False}, {"deviceValidationPassed": True},
            {"nativeZIP": {"bytes": 123, "sha256": "f" * 64}}, {"nativeLayout": {"simulator": {"ok": True}}},
            {"jar": {"sha256": "e" * 64, "bytes": 10}}]
        for changes in variants:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                tools.validate_reuse(dict(proof, **changes), "c" * 40, "1234", audited, pin)
        quick = tools.load("package_only_protocol_guard", HERE / "renewal-package-tools.py")
        sha = "c" * 40
        tag = "yuedu-renewal-package-" + sha[:7]
        workflow = (quick.REPO / ".github/workflows/yuedu-renewal-package.yml").read_text(encoding="utf-8")
        self.assertIn("- 'yuedu-renewal-package-*'", workflow)
        self.assertIn("YUEDU_PACKAGE_REPOSITORY_PRIVATE: ${{ github.event.repository.private }}", workflow)
        self.assertNotIn("github.event.repository.private == true", workflow)
        self.assertIn(".build/renewal-package-public/source.zip", workflow)
        self.assertIn("retention-days: 1", workflow)
        self.assertIn(quick.POLICY, quick.INPUTS)
        for pattern in ("reader-renewal-*", "legado-native-reader-test-*", "reader-legado-*"):
            self.assertFalse(fnmatch.fnmatchcase(tag, pattern))
        environment = {"GITHUB_SHA": sha, "GITHUB_RUN_ID": "1234", "GITHUB_REF_NAME": tag,
                       "GITHUB_REF": "refs/tags/" + tag}
        with patch.object(quick.sys, "platform", "darwin"), patch.object(quick.native.smoke, "source_sha", return_value=sha), \
                patch.dict(quick.os.environ, environment, clear=True):
            self.assertEqual(quick.source(), sha)
            # Private imported callers opt into the new validator. Original
            # Native/full-signing command-line admissions still reject this tag.
            with self.assertRaises(ValueError):
                quick.native.validate_tag()
            with patch.object(quick.full.subprocess, "check_output", return_value=sha):
                with self.assertRaises(ValueError):
                    quick.full.admission()
            for changes in ({"GITHUB_SHA": "d" * 40}, {"GITHUB_REF": "refs/heads/" + tag},
                            {"GITHUB_REF_NAME": "reader-renewal-package-" + sha[:7]},
                            {"GITHUB_RUN_ID": ""}):
                with self.subTest(changes=changes), patch.dict(quick.os.environ, changes), self.assertRaises(ValueError):
                    quick.source()
        # Synthetic copy/admission protocol only: these bytes are not an IPA.
        # The production validator is delegated, never claimed executed here.
        with tempfile.TemporaryDirectory() as name:
            root = Path(name).resolve()
            policy = json.loads((quick.REPO / quick.POLICY).read_bytes())
            policy_path = root / quick.POLICY
            policy_path.parent.mkdir(parents=True)
            policy_bytes = json.dumps(policy).encode()
            policy_path.write_bytes(policy_bytes)
            with patch.dict(quick.os.environ, {"YUEDU_PACKAGE_REPOSITORY_PRIVATE": "false"}), \
                    patch.object(quick, "REPO", root), \
                    patch.object(quick, "check_binding", side_effect=AssertionError("Unauthorized export read private files")):
                for changed in ({"publicRepositoryIPAUploadsEnabled": False},
                        {"temporaryPublicUploadAuthorization": None},
                        {"temporaryPublicUploadAuthorization": dict(policy["temporaryPublicUploadAuthorization"], artifactRetentionDays=2)},
                        {"temporaryPublicUploadAuthorization": dict(policy["temporaryPublicUploadAuthorization"], exactGitSourceSnapshotIncluded=False)},
                        {"temporaryPublicUploadAuthorization": dict(policy["temporaryPublicUploadAuthorization"], privateBookSourceUploadAuthorized=True)}):
                    policy_path.write_text(json.dumps(dict(policy, **changed)))
                    with self.subTest(policy=changed), self.assertRaises(ValueError):
                        quick.export_unsigned()
                policy_path.write_bytes(policy_bytes)
                authorization = quick.upload_authorization()
                self.assertFalse(authorization["repositoryPrivate"])
                self.assertFalse(authorization["licenseClearanceEstablished"])
                self.assertEqual(authorization["artifactRetentionDays"], 1)
                self.assertEqual(authorization["sha256"], hashlib.sha256(policy_bytes).hexdigest())
            def archive_bytes(path, *, commit=sha, include_policy=True, content=policy_bytes, private_pack=False):
                with zipfile.ZipFile(path, "w") as archive:
                    archive.comment = commit.encode()
                    archive.writestr("README.md", b"SYNTHETIC-SOURCE-SNAPSHOT")
                    if include_policy:
                        archive.writestr(quick.POLICY, content)
                    if private_pack:
                        archive.writestr("Resources/BuiltInBookSources.json", b"[]")
            with self.assertRaises(ValueError):
                quick.verify_source_archive(root / "missing-source.zip", sha, authorization)
            for index, options in enumerate(({"include_policy": False}, {"commit": "d" * 40},
                    {"content": b"{}"}, {"private_pack": True})):
                bad_archive = root / ("invalid-source-" + str(index) + ".zip")
                archive_bytes(bad_archive, **options)
                with self.subTest(source=options), self.assertRaises(ValueError):
                    quick.verify_source_archive(bad_archive, sha, authorization)
            build = root / quick.full.PRIVATE / "device-build"
            output = build / "output"
            output.mkdir(parents=True)
            expected = {file: ("SYNTHETIC-" + file).encode() for file in quick.OUTPUTS}
            for file, raw in expected.items():
                (output / file).write_bytes(raw)
            produced = root / quick.full.PRIVATE / "produced"
            produced.mkdir()
            (produced / "never-export.p12").write_bytes(b"SYNTHETIC-PRIVATE-NEVER-READ")
            work = root / quick.full.WORK
            work.mkdir(parents=True)
            (work / "prepared.json").write_text(json.dumps({"sourceCommit": sha, "workflowRunID": "1234", "completeApplicationBuilt": True}))
            receipt = {"sourceCommit": sha, "workflowRunID": "1234"}
            validator = SimpleNamespace(validate_input=unittest.mock.Mock(return_value={}))
            original_open = Path.open
            def guarded_open(path, *args, **kwargs):
                if produced in path.parents or path == produced:
                    raise AssertionError("Export read the private controlled producer directory")
                return original_open(path, *args, **kwargs)
            def synthetic_git_archive(argv, **kwargs):
                self.assertEqual(argv, ["git", "-C", str(root), "archive", "--format=zip", "--output",
                    str(root / "public/source.zip"), "HEAD"])
                self.assertEqual(kwargs["timeout"], 60)
                archive_bytes(Path(argv[-2]))
                return SimpleNamespace(returncode=0)
            with patch.dict(quick.os.environ, {"YUEDU_PACKAGE_REPOSITORY_PRIVATE": "false"}), \
                    patch.object(quick, "REPO", root), patch.object(quick, "PUBLIC", root / "public"), \
                    patch.object(quick, "check_binding", return_value=receipt), \
                    patch.object(quick.full, "load", side_effect=[object(), validator]), \
                    patch.object(quick.subprocess, "run", side_effect=synthetic_git_archive), patch.object(Path, "open", guarded_open):
                quick.export_unsigned()
            validator.validate_input.assert_called_once()
            self.assertEqual({path.name for path in (root / "public").iterdir()}, set(quick.OUTPUTS) | {"delivery-binding.json", "source.zip"})
            for file, raw in expected.items():
                self.assertEqual((root / "public" / file).read_bytes(), raw)
            delivery = json.loads((root / "public/delivery-binding.json").read_bytes())
            self.assertEqual(delivery["sourceCommit"], sha)
            self.assertEqual(delivery["S3Acceptance"], "pending-separate-result")
            self.assertFalse(delivery["controlledResignedOutputExported"])
            self.assertEqual(delivery["distributionPolicy"], authorization)
            self.assertEqual(delivery["exactGitSourceSnapshot"]["sourceCommit"], sha)
            self.assertEqual(delivery["files"]["source.zip"], tools.fact(root / "public/source.zip"))

    def test_required_resource_hashes_and_cleanup_are_bound_without_minimal_substitution(self):
        # Bytes below are deliberately NOT an IPA; this guard tests staging
        # integrity only. Production Swift must still parse/verify the real IPA.
        with tempfile.TemporaryDirectory() as name:
            # Resolve this owned temporary root before checking child resources;
            # system temp-directory aliases must not change the input policy.
            root = Path(name).resolve(strict=True)
            archive = root / tools.RESOURCE_NAMES[1]
            archive.write_bytes(b"protocol-integrity-only-not-an-IPA")
            value = tools.fact(archive)
            meta = {"schema": 1, "kind": "full-current-source-iphoneos-jvm-application", "sourceCommit": "c" * 40,
                "archiveFile": tools.RESOURCE_NAMES[1], "archiveBytes": value["bytes"], "archiveSHA256": value["sha256"],
                "privateMaterialArtifacts": 0, "realAppleAccountUsed": False, "controlledOriginalSigningOnly": True,
                "realDeviceExecution": False, "allUnrelatedDeviceBuildFilesPreserved": True}
            (root / tools.RESOURCE_NAMES[0]).write_text(json.dumps(meta))
            producer = {"fullApplication": meta, "temporaryOwnedKeychainDeleted": True,
                "temporaryUserSearchListRestoredAndOwnedAbsent": True, "privateMaterialArtifacts": 0,
                "privateKeyFilesOutsideKeychain": 0, "userAdminSystemTrustChanged": False,
                "publicOutputs": [{"path": path.name, **tools.fact(path)} for path in root.iterdir()]}
            tools.resource_binding(root, "c" * 40, producer)
            for changes in ({"temporaryOwnedKeychainDeleted": False}, {"privateMaterialArtifacts": 1},
                            {"temporaryUserSearchListRestoredAndOwnedAbsent": False}, {"fullApplication": {}}):
                with self.subTest(changes=changes), self.assertRaises(ValueError):
                    tools.resource_binding(root, "c" * 40, dict(producer, **changes))
            with self.assertRaises(ValueError):
                tools.resource_binding(root, "d" * 40, producer)
            archive.write_bytes(b"changed")
            with self.assertRaises(ValueError):
                tools.resource_binding(root, "c" * 40, producer)
            archive.unlink()
            (root / "owned-sdk-package.json").write_text("{}")
            with self.assertRaises(ValueError):
                tools.resource_binding(root, "c" * 40, producer)

    def test_exact_case_gate_rejects_zero_duplicate_wrong_failed_and_skipped_results(self):
        node = {"nodeType": "Test Case", "nodeIdentifier": "yuedu appTests/" + tools.CASE + "()", "result": "Passed"}
        tree = {"testNodes": [{"nodeType": "Test Suite", "children": [node]}]}
        self.assertEqual(tools.verify_cases(tree), [tools.CASE])
        for variant in ({"testNodes": []}, {"testNodes": [node, node]},
                        {"testNodes": [dict(node, nodeIdentifier="Other/test()")]},
                        {"testNodes": [dict(node, result="Failed")]}, {"testNodes": [dict(node, result="Skipped")]}):
            with self.subTest(variant=variant), self.assertRaises(ValueError):
                tools.verify_cases(variant)
        # Early evidence is a bounded diagnostic projection of existing fixed
        # outputs, not a new test host or a replacement for the gate above.
        secret = 'SYNTHETIC-NEVER-EXPORT-SECRET'
        with tempfile.TemporaryDirectory() as name:
            work = Path(name).resolve()
            unknown = tools.early_summary(work, 'a' * 40, '1234')
            self.assertIsNone(unknown['observedExecuted'])
            self.assertEqual(unknown['failureTags'], ['unknown'])
            self.assertFalse(unknown['productionSigningAcceptance'])
            prepared = {'sourceCommit': 'a' * 40, 'workflowRunID': '1234', 'anchor': secret}
            (work / 'prepared.json').write_text(json.dumps(prepared))
            (work / 'result.json').write_text(json.dumps({'sourceCommit': 'a' * 40, 'status': 'failed', 'private': secret}))
            outside = work / 'never-follow-argv-or-output-path'
            outside.write_text(secret)
            for phase in ('full-application-test', 'full-application-summary', 'full-application-tests'):
                (work / (phase + '-execution.json')).write_text(json.dumps({'argv': [secret, str(outside)],
                    'exitCode': 1 if phase.endswith('-test') else 0, 'timeoutSeconds': 3660 if phase.endswith('-test') else 60,
                    'timedOut': False, 'output': {'path': str(outside), 'bytes': 42, 'sha256': 'b' * 64}}))
            failure = {'nodeType': 'Failure Message', 'name': 'SelfRenewalCodeDirectoryHashVerifier.swift:181: Caught error: .missingSpecialSlot(1)'}
            failed_node = dict(node, result='Failed', children=[failure])
            (work / 'full-application-test.log').write_text(secret)
            (work / 'full-application-summary.log').write_text(json.dumps({'totalTestCount': 1, 'passedTests': 0,
                'failedTests': 1, 'skippedTests': 0, 'expectedFailures': 0, 'freeText': secret,
                'testFailures': [{'testIdentifierString': tools.CASE + '()', 'failureText': 'Caught error: .missingSpecialSlot(1)'}]}))
            (work / 'full-application-tests.log').write_text(json.dumps({'testNodes': [failed_node], 'PKI': secret}))
            original_open = Path.open
            def guarded_open(path, *args, **kwargs):
                if path == outside:
                    raise AssertionError('Early projection followed an untrusted argv/output path')
                return original_open(path, *args, **kwargs)
            with patch.object(Path, 'open', guarded_open):
                projected = tools.early_summary(work, 'a' * 40, '1234')
            self.assertEqual((projected['observedExecuted'], projected['observedPassed'], projected['observedFailed']), (1, 0, 1))
            self.assertTrue(projected['exactCaseSelectionObserved'])
            self.assertEqual(projected['failureTags'], ['missingSpecialSlot'])
            self.assertEqual(projected['fixedOutputFacts']['full-application-test.log'], {
                'bytes': len(secret), 'sha256': hashlib.sha256(secret.encode()).hexdigest()})
            encoded = json.dumps(projected)
            for withheld in (secret, str(outside), 'argv', 'anchor', 'PKI', 'SelfRenewalCodeDirectoryHashVerifier.swift'):
                self.assertNotIn(withheld, encoded)
            self.assertLess(len(encoded), 8192)
            original_tree = (work / 'full-application-tests.log').read_bytes()
            original_failure_name = failure['name']
            failure['name'] = 'SelfRenewalFullApplicationSignerTests.swift:15: Caught error: sizeLimit'
            (work / 'full-application-tests.log').write_text(json.dumps({'testNodes': [dict(failed_node, children=[failure])]}))
            bounded = tools.early_summary(work, 'a' * 40, '1234')
            self.assertEqual(bounded['failureTags'], ['missingSpecialSlot', 'sizeLimit'])
            self.assertEqual((bounded['observedExecuted'], bounded['observedPassed'], bounded['observedFailed']), (1, 0, 1))
            (work / 'full-application-tests.log').write_bytes(original_tree)
            failure['name'] = original_failure_name
            summary_path = work / 'full-application-summary.log'
            summary_bytes = summary_path.read_bytes(); summary_path.unlink()
            self.assertIsNone(tools.early_summary(work, 'a' * 40, '1234')['observedExecuted'])
            summary_path.write_bytes(summary_bytes)
            for phase in ('full-application-test', 'full-application-summary', 'full-application-tests'):
                ledger_path = work / (phase + '-execution.json')
                ledger_bytes = ledger_path.read_bytes()
                for field, value in (('exitCode', None), ('exitCode', True), ('exitCode', 'invalid'), ('exitCode', 256),
                        ('timeoutSeconds', None), ('timeoutSeconds', True), ('timeoutSeconds', 0), ('timeoutSeconds', 'invalid'),
                        ('timedOut', None), ('timedOut', 'false'), ('timedOut', True)):
                    ledger = json.loads(ledger_bytes)
                    if value is None: ledger.pop(field)
                    else: ledger[field] = value
                    ledger_path.write_text(json.dumps(ledger))
                    with self.subTest(phase=phase, field=field, value=value):
                        self.assertIsNone(tools.early_summary(work, 'a' * 40, '1234')['observedExecuted'])
                ledger_path.write_bytes(ledger_bytes)
            tree_path = work / 'full-application-tests.log'
            tree_bytes = tree_path.read_bytes()
            summary_object = json.loads(summary_bytes)
            for changed_summary, changed_tree in (
                    (summary_object, {'testNodes': []}),
                    (dict(summary_object, passedTests=1, failedTests=0), {'testNodes': [failed_node]}),
                    (dict(summary_object, totalTestCount=2), {'testNodes': [failed_node]})):
                summary_path.write_text(json.dumps(changed_summary))
                tree_path.write_text(json.dumps(changed_tree))
                self.assertIsNone(tools.early_summary(work, 'a' * 40, '1234')['observedExecuted'])
            summary_path.write_text(json.dumps(dict(summary_object, totalTestCount=0, failedTests=0)))
            tree_path.write_text(json.dumps({'testNodes': []}))
            zero = tools.early_summary(work, 'a' * 40, '1234')
            self.assertEqual((zero['observedExecuted'], zero['observedPassed'], zero['observedFailed']), (0, 0, 0))
            self.assertFalse(zero['exactCaseSelectionObserved'])
            summary_path.write_bytes(summary_bytes)
            deep_bytes = ('{"nested":' * 1200 + '0' + '}' * 1200).encode()
            tree_path.write_bytes(deep_bytes)
            original_loads = json.loads
            def decoder_with_recursion_failure(raw, *args, **kwargs):
                # Decoder recursion thresholds differ across Python versions.
                # Inject only this bounded deep fixture's decoder exception.
                if raw == deep_bytes: raise RecursionError('Synthetic deep decoder refusal')
                return original_loads(raw, *args, **kwargs)
            with patch.object(tools.json, 'loads', side_effect=decoder_with_recursion_failure):
                deep = tools.early_summary(work, 'a' * 40, '1234')
            self.assertEqual(deep['testsState'], 'invalid')
            self.assertIsNone(deep['observedExecuted'])
            tree_path.write_bytes(tree_bytes)
            restored = tools.early_summary(work, 'a' * 40, '1234')
            self.assertEqual((restored['observedExecuted'], restored['observedPassed'], restored['observedFailed']), (1, 0, 1))
            for variant in ({'testNodes': [dict(failed_node, nodeIdentifier=secret)]},
                            {'testNodes': [dict(failed_node, result=secret)]}, {'testNodes': None}):
                (work / 'full-application-tests.log').write_text(json.dumps(variant))
                observed = tools.early_summary(work, 'a' * 40, '1234')
                self.assertIsNone(observed['observedExecuted'])
                self.assertFalse(observed['productionSigningAcceptance'])
                self.assertNotIn(secret, json.dumps(observed))
            failure['name'] = 'Caught error: UnknownPrivateError(' + secret + ')'
            (work / 'full-application-summary.log').write_text('{}')
            (work / 'full-application-tests.log').write_text(json.dumps({'testNodes': [dict(failed_node, children=[failure])]}))
            observed = tools.early_summary(work, 'a' * 40, '1234')
            self.assertEqual(observed['failureTags'], ['unknown'])
            self.assertGreater(observed['unknownFailureOccurrencesWithheld'], 0)
            self.assertNotIn(secret, json.dumps(observed))
            execution_path = work / 'full-application-test-execution.json'
            execution = json.loads(execution_path.read_text()); execution['timedOut'] = True
            execution_path.write_text(json.dumps(execution))
            self.assertIsNone(tools.early_summary(work, 'a' * 40, '1234')['observedExecuted'])
            (work / 'prepared.json').write_text(json.dumps(dict(prepared, workflowRunID='5678')))
            unbound = tools.early_summary(work, 'a' * 40, '1234')
            self.assertEqual(unbound['sourceBinding'], 'unknown')
            self.assertIsNone(unbound['observedExecuted'])
            (work / 'full-application-tests.log').write_bytes(b'x' * 1_048_577)
            self.assertEqual(tools.early_summary(work, 'a' * 40, '1234')['testsState'], 'oversize')

    def test_producer_minimal_default_body_is_unchanged_and_full_branch_is_explicit(self):
        candidate = ast.parse((HERE / "owned-package-fixture/generate-sdk-owned-package.py").read_text())
        main = next(v for v in candidate.body if isinstance(v, ast.FunctionDef) and v.name == "main")
        branch = next(v for v in ast.walk(main) if isinstance(v, ast.If)
            and ast.dump(v.test) == ast.dump(ast.Compare(left=ast.Name(id="full", ctx=ast.Load()), ops=[ast.IsNot()], comparators=[ast.Constant(None)]))
            and any(isinstance(x, ast.Assign) and any(isinstance(y, ast.Name) and y.id == "full_extra" for y in x.targets) for x in v.body))
        minimal = branch.orelse
        # The frozen baseline is used when this guard is run in the preparation
        # stage; canonical CI additionally checks the explicit new branch below.
        stage = next((p for p in HERE.parents if p.name == "s3-full-application-signing-step"), None)
        if stage is not None:
            baseline = ast.parse((stage / "rawbaseline/scripts/reader-experience/owned-package-fixture/generate-sdk-owned-package.py").read_text())
            old_main = next(v for v in baseline.body if isinstance(v, ast.FunctionDef) and v.name == "main")
            body = next(v.body for v in ast.walk(old_main) if isinstance(v, ast.Try)
                and any(isinstance(x, ast.Assign) and any(isinstance(y, ast.Name) and y.id == "app" for y in x.targets) for x in v.body))
            start = next(i for i, v in enumerate(body) if isinstance(v, ast.Assign) and any(isinstance(y, ast.Name) and y.id == "app" for y in v.targets))
            end = next(i for i, v in enumerate(body) if isinstance(v, ast.Expr) and isinstance(v.value, ast.Call)
                and isinstance(v.value.func, ast.Attribute) and v.value.func.attr == "write_text"
                and "owned-sdk-package.json" in ast.unparse(v)) + 1
            old = body[start:end]
            # CMS/codesign definitions were moved without changing their bodies.
            old = [v for v in old if not isinstance(v, ast.FunctionDef)
                and not (isinstance(v, ast.Assign) and any(isinstance(y, ast.Name) and y.id == "identity" for y in v.targets))]
            self.assertEqual(ast.dump(ast.Module(body=minimal, type_ignores=[])), ast.dump(ast.Module(body=old, type_ignores=[])))
            for name in ("cms", "codesign"):
                self.assertEqual(ast.dump(next(v for v in ast.walk(old_main) if isinstance(v, ast.FunctionDef) and v.name == name)),
                    ast.dump(next(v for v in ast.walk(main) if isinstance(v, ast.FunctionDef) and v.name == name)))
        self.assertTrue(minimal)
        text = ast.unparse(main)
        self.assertIn("--full-application-build", text)
        self.assertIn("full.validate_input", text)
        self.assertIn("full.produce", text)
        # The Xcode full-device build replaces static SPM binaries with a
        # codeless-framework arm64 stub and lipo -create preserves a FAT32
        # wrapper even for one architecture. Inspect without flattening it.
        full_spec = importlib.util.spec_from_file_location("full_component_shape_guard",
            HERE / 'owned-package-fixture/full-application-package.py')
        full = importlib.util.module_from_spec(full_spec)
        full_spec.loader.exec_module(full)
        # Synthetic metadata only: no Apple SDK, codesign or real App input.
        main_info = {'CFBundleIdentifier': 'test.owned.reader', 'CFBundleExecutable': 'Reader',
            'CFBundleShortVersionString': '3.0.0', 'CFBundleVersion': '14',
            'CFBundlePackageType': 'APPL', 'CFBundleSupportedPlatforms': ['iPhoneOS']}
        roles = {'.': None, 'PlugIns/yuedu_app_ShareExtension.appex': 'com.apple.share-services',
            'PlugIns/yuedu_app_Widget.appex': 'com.apple.widgetkit-extension'}
        for relative, point in roles.items():
            info = copy.deepcopy(main_info)
            if point is not None:
                info['CFBundlePackageType'] = 'XPC!'
                info['NSExtension'] = {'NSExtensionPointIdentifier': point}
            original = copy.deepcopy(info)
            full.validate_expected_bundle_metadata(info, relative)
            self.assertEqual(info, original)
            for field in ('CFBundleIdentifier', 'CFBundleExecutable', 'CFBundleShortVersionString',
                          'CFBundleVersion', 'CFBundlePackageType', 'CFBundleSupportedPlatforms'):
                missing = copy.deepcopy(info)
                del missing[field]
                with self.subTest(bundle=relative, missing=field), self.assertRaises(ValueError):
                    full.validate_expected_bundle_metadata(missing, relative)
            for field, value in (('CFBundleIdentifier', 'test..reader'), ('CFBundleIdentifier', '.reader'),
                    ('CFBundleIdentifier', 'reader.'), ('CFBundleIdentifier', 'x' * 256),
                    ('CFBundleIdentifier', 1), ('CFBundleExecutable', '../Reader'),
                    ('CFBundleExecutable', 'sub\\Reader'), ('CFBundleExecutable', '.'),
                    ('CFBundleExecutable', 'x' * 256), ('CFBundleShortVersionString', ''),
                    ('CFBundleShortVersionString', 'x' * 65), ('CFBundleVersion', 14),
                    ('CFBundleVersion', '14 '), ('CFBundlePackageType', 'FMWK'),
                    ('CFBundleSupportedPlatforms', ['iPhoneSimulator'])):
                invalid = dict(info, **{field: value})
                with self.subTest(bundle=relative, invalid=field, value=value), self.assertRaises(ValueError):
                    full.validate_expected_bundle_metadata(invalid, relative)
            invalid = copy.deepcopy(info)
            if point is None:
                invalid['NSExtension'] = {'NSExtensionPointIdentifier': 'com.apple.share-services'}
            else:
                del invalid['NSExtension']
            with self.subTest(bundle=relative, missing_or_extra_extension=True), self.assertRaises(ValueError):
                full.validate_expected_bundle_metadata(invalid, relative)
            if point is not None:
                invalid = dict(info, NSExtension={'NSExtensionPointIdentifier': 'wrong.extension'})
                with self.subTest(bundle=relative, wrong_extension=True), self.assertRaises(ValueError):
                    full.validate_expected_bundle_metadata(invalid, relative)
        # Existing build input bytes must explicitly retain the extension role.
        for relative in ('ShareExtension/Info.plist', 'Widget/Info.plist'):
            self.assertEqual(plistlib.loads((HERE.parents[1] / relative).read_bytes())['CFBundlePackageType'], 'XPC!')
        self.assertTrue({'ShareExtension/Info.plist', 'Widget/Info.plist'} <= {
            row['path'] for row in tools.signing_source_inputs()})
        full_ast = ast.parse((HERE / 'owned-package-fixture/full-application-package.py').read_text())
        production = next(v for v in full_ast.body if isinstance(v, ast.FunctionDef) and v.name == 'produce')
        validation_call = next(v for v in ast.walk(production) if isinstance(v, ast.Call)
            and isinstance(v.func, ast.Name) and v.func.id == 'validate_expected_bundle_metadata')
        signing_call = next(v for v in ast.walk(production) if isinstance(v, ast.Call)
            and isinstance(v.func, ast.Name) and v.func.id == 'codesign')
        self.assertLess(validation_call.lineno, signing_call.lineno)
        cpu = 0x0100000c
        thin = struct.pack('<8I', 0xfeedfacf, cpu, 0, 6, 1, 24, 0, 0) + struct.pack('<6I', 0x32, 24, 2, 0, 0, 0)
        offset = 4096
        fat = struct.pack('>7I', 0xcafebabe, 1, cpu, 0, offset, len(thin), 12) + bytes(offset - 28) + thin
        with tempfile.TemporaryDirectory() as name:
            binary = Path(name) / 'native-component'
            for raw, container, start in [(thin, 'thin64', 0), (fat, 'fat32-single-arm64', offset)]:
                binary.write_bytes(raw)
                shape = full.native_component_shape(binary)
                self.assertEqual((shape['container'], shape['architectures'], shape['sliceOffset']), (container, 1, start))
                self.assertEqual((shape['cpuType'], shape['cpuSubtype'], shape['fileType']), (cpu, 0, 6))
                self.assertEqual(shape['sliceBytes'], len(thin))
                self.assertEqual(binary.read_bytes(), raw)  # no slice selection, stripping or rewriting
            def patched(raw, index, value, order):
                result = bytearray(raw); struct.pack_into(order + 'I', result, index, value); return bytes(result)
            variants = {
                'ar-is-not-code': b'!<arch>\n' + bytes(48),
                'fat64': patched(fat, 0, 0xcafebabf, '>'),
                'multiple-architectures': patched(fat, 4, 2, '>'),
                'wrong-outer-cpu': patched(fat, 8, 0x01000007, '>'),
                'wrong-outer-subtype': patched(fat, 12, 2, '>'),
                'overlapping-table': patched(fat, 16, 16, '>'),
                'misaligned-offset': patched(fat, 16, offset + 1, '>'),
                'alignment-overflow': patched(fat, 24, 31, '>'),
                'truncated-slice': fat[:-1],
                'trailing-bytes': fat + b'x',
                'wrong-inner-cpu': patched(thin, 4, 0x01000007, '<'),
                'arm64e-is-not-admitted': patched(thin, 8, 2, '<'),
                'object-is-not-executable': patched(thin, 12, 1, '<'),
                'commands-outside-slice': patched(thin, 20, 1048577, '<'),
                'unknown-container': b'\x7fELF' + thin[4:],
            }
            for label, raw in variants.items():
                with self.subTest(nativeShape=label), self.assertRaises(ValueError):
                    binary.write_bytes(raw)
                    full.native_component_shape(binary)
        # These are execution-policy contracts, not completed Apple builds.
        # Device compilation and the independently compiled one-case Simulator
        # signer both receive a bounded hour; its parent retains 60s headroom.
        orchestration = ast.parse((HERE / 'full-application-signing-tools.py').read_text())
        calls = {call.args[1].value: call for call in ast.walk(orchestration)
            if isinstance(call, ast.Call) and isinstance(call.func, ast.Name) and call.func.id == 'command'
            and len(call.args) >= 4 and isinstance(call.args[1], ast.Constant)}
        self.assertEqual(calls['full-device-build'].args[3].value, 3600)
        test = calls['full-application-test']
        self.assertEqual(test.args[3].value, 3660)
        argv = test.args[2].elts
        flag = next(i for i, value in enumerate(argv) if isinstance(value, ast.Constant) and value.value == '-t')
        self.assertEqual(argv[flag + 1].value, '3600')
        self.assertIn("'-only-testing:yuedu appTests/' + CASE + '()'", ast.unparse(test))
        workflow = (HERE.parents[1] / '.github/workflows/legado-native-reader-test.yml').read_text()
        self.assertIn("timeout-minutes: ${{ startsWith(github.ref_name, 'legado-native-reader-test-cold-') && 120 || 150 }}", workflow)
        # Exports and all non-compilation stage budgets retain their values.
        self.assertEqual(calls['device-runtime-stage'].args[3].value, 300)
        self.assertEqual(calls['full-owned-producer'].args[3].value, 360)
        self.assertEqual(next(call for call in ast.walk(orchestration) if isinstance(call, ast.Call)
            and isinstance(call.func, ast.Name) and call.func.id == 'command'
            and len(call.args) >= 4 and isinstance(call.args[1], ast.BinOp)).args[3].value, 60)
        # Reproduce a file growing after its stale stat sample, before the
        # read stream opens. Both returned values must describe that one stream.
        with tempfile.TemporaryDirectory() as name:
            path = Path(name) / 'growing.log'
            path.write_bytes(b'active compiler\n')
            previous_size = path.stat().st_size
            trailer = b'** BUILD INTERRUPTED **\n'
            self.assertEqual(len(trailer), 24)
            class GrowingFile:
                def stat(self):
                    return SimpleNamespace(st_size=previous_size)
                def open(self, mode):
                    self_mode = mode
                    with path.open('ab') as output:
                        output.write(trailer)
                    return path.open(self_mode)
            value = tools.fact(GrowingFile())
            actual = path.read_bytes()
            self.assertNotEqual(previous_size, len(actual))
            self.assertEqual(value, {'bytes': len(actual), 'sha256': hashlib.sha256(actual).hexdigest()})


if __name__ == "__main__":
    unittest.main(verbosity=2)
