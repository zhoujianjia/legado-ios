#!/usr/bin/env python3
"""Portable protocol guards only: no Apple build/signing/Swift execution."""
import ast
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

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
