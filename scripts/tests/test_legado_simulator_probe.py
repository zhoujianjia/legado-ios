"""Portable checks for Simulator run labelling; these do not execute an iOS app."""
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "legado-ios/run-simulator-probe.py"
spec = importlib.util.spec_from_file_location("legado_simulator_probe_tested", SCRIPT)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
SHA = "6af471799bfb128c19d5cb78e03357844e79158f"


class SimulatorSourceStampTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.app = self.root / "products/LegadoRuntimeProbe.app"
        self.app.mkdir(parents=True)
        self.info = {"CFBundleIdentifier": probe.BUNDLE_ID, "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
                     "CFBundleExecutable": "LegadoRuntimeProbe", "CFBundleVersion": "9", "Unrelated": ["keep"]}
        self.plist = self.app / "Info.plist"
        self.plist.write_bytes(plistlib.dumps(self.info))
        (self.app / "LegadoRuntimeProbe").write_bytes(b"existing-executable")
        self.settings = [{"target": "LegadoRuntimeProbe", "buildSettings": {
            "PLATFORM_NAME": "iphonesimulator", "TARGET_BUILD_DIR": str(self.app.parent),
            "FULL_PRODUCT_NAME": self.app.name}}]

    def test_stamp_persists_exact_head_and_preserves_other_metadata_and_executable(self):
        probe.stamp_simulator_source(probe.built_app(self.settings), SHA)
        actual = plistlib.loads(self.plist.read_bytes())
        self.assertEqual(actual, {**self.info, "LegadoSourceCommit": SHA})
        self.assertEqual((self.app / "LegadoRuntimeProbe").read_bytes(), b"existing-executable")

    def test_invalid_git_head_is_rejected_before_modifying_bundle(self):
        before = self.plist.read_bytes()
        for invalid in ("", SHA[:39], SHA + "0", SHA + "\nother", "g" * 40, "HEAD"):
            with self.subTest(invalid=invalid), self.assertRaisesRegex(RuntimeError, "40-hex"):
                probe.stamp_simulator_source(self.app, invalid)
            self.assertEqual(self.plist.read_bytes(), before)

    def make_run(self, valid_bundle=True, require_native_tcp=False, require_native_tls=False, require_native_http_wire=False):
        if not valid_bundle:
            self.plist.write_bytes(plistlib.dumps({**self.info, "CFBundleIdentifier": "wrong.bundle"}))
        run = probe.ProbeRun(self.root, self.root / "evidence", 60, require_native_tcp=require_native_tcp,
                             require_native_tls=require_native_tls, require_native_http_wire=require_native_http_wire)
        container = self.root / "simulator-data"
        container.mkdir(exist_ok=True)
        calls = []

        def command(name, argv, **kwargs):
            calls.append((name, argv))
            responses = {"resolve-xcode": "/Applications/TestXcode/Contents/Developer\n",
                         "resolve-destination": "id=chosen-simulator\n",
                         "build-settings": json.dumps(self.settings), "source-commit": SHA + "\n",
                         "simulator-inventory": json.dumps({"devices": {"runtime": [
                             {"udid": "chosen-simulator", "state": "Booted"}]}}),
                         "app-container": str(container), "launch": probe.BUNDLE_ID + ": 123\n"}
            if name == "simulator-codesign":
                self.assertEqual(plistlib.loads(self.plist.read_bytes())["LegadoSourceCommit"], SHA)
                self.assertEqual(run.result["sourceCommit"], SHA)
            return responses.get(name, "")

        run.command = command
        return run, calls

    def test_runner_labels_verified_simulator_app_before_signing_and_records_scope(self):
        run, calls = self.make_run()
        # External tools and process completion are mocked only to test runner
        # ordering; this is deliberately not Simulator execution evidence.
        with patch.object(probe.sys, "platform", "darwin"), patch.object(probe, "wait_for_probe"):
            run.run("iPhone")
        names = [name for name, _ in calls]
        self.assertLess(names.index("build-settings"), names.index("source-commit"))
        self.assertLess(names.index("source-commit"), names.index("simulator-codesign"))
        self.assertEqual(dict(calls)["source-commit"], ["git", "rev-parse", "HEAD"])
        self.assertEqual(run.result["sourceCommit"], SHA)
        self.assertEqual(run.result["sourceCommitStamp"],
                         {"kind": "runner-checkout-label", "provesCompiledBinarySourceIdentity": False})

    def test_unverified_bundle_never_gets_a_checkout_label_or_signature(self):
        run, calls = self.make_run(valid_bundle=False)
        before = self.plist.read_bytes()
        with patch.object(probe.sys, "platform", "darwin"), self.assertRaisesRegex(RuntimeError, "bundle identifier"):
            run.run("iPhone")
        self.assertNotIn("source-commit", [name for name, _ in calls])
        self.assertNotIn("simulator-codesign", [name for name, _ in calls])
        self.assertEqual(self.plist.read_bytes(), before)
        self.assertNotIn("sourceCommit", run.result)

    def write_tcp_report(self, run, capability, **overrides):
        report = {"passed": True, "executionPlatform": "ios-simulator", "sourceCommit": SHA,
                  "probeProgress": {"probe-progress.json": {"executionPlatform": "ios-simulator",
                      "processIdentifier": run.pid, "recordedAt": run.launched_at + 0.01}},
                  "nativeTCPProbe": capability, **overrides}
        path = run.container / probe.DIAGNOSTICS_PATH / "exports/LegadoProbe-report.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(report), encoding="utf-8")
        return path

    def test_required_native_tcp_accepts_current_run_true_and_records_gate(self):
        run, _ = self.make_run(require_native_tcp=True)
        capability = {"passed": True, "loopbackOnly": True, "provesTLSOrHTTPCompatibility": False}
        with patch.object(probe.sys, "platform", "darwin"), patch.object(probe, "wait_for_probe",
                side_effect=lambda *args: self.write_tcp_report(run, capability)):
            run.run("iPhone")
        self.assertEqual(run.result["status"], "passed")
        self.assertTrue(run.result["capabilityRequired"]["nativeTCP"])
        self.assertTrue(run.result["nativeTCPGate"]["passed"])
        self.assertEqual(run.result["nativeTCPGate"]["probe"], capability)
        self.assertEqual(len(run.result["nativeTCPGate"]["reportSHA256"]), 64)

    def test_required_native_tcp_false_missing_and_non_boolean_never_pass(self):
        for capability in ({"passed": False, "errorCode": "jni_7", "failure": "missing native symbol"},
                           None, {}, {"passed": 1}, {"passed": "true"}):
            run, _ = self.make_run(require_native_tcp=True)
            with self.subTest(capability=capability), patch.object(probe.sys, "platform", "darwin"), \
                    patch.object(probe, "wait_for_probe", side_effect=lambda *args: self.write_tcp_report(run, capability)):
                with self.assertRaisesRegex(RuntimeError, "Required native TCP capability failed") as failure:
                    run.run("iPhone")
            self.assertEqual(run.result["status"], "failed")
            self.assertFalse(run.result["simulatorValidationPassed"])
            self.assertFalse(run.result["nativeTCPGate"]["passed"])
            self.assertEqual(run.result["nativeTCPGate"]["probe"], capability)
            if isinstance(capability, dict) and capability.get("errorCode"):
                self.assertIn("jni_7: missing native symbol", str(failure.exception))

    def test_required_native_tcp_rejects_report_from_another_source_or_process(self):
        for override in ({"sourceCommit": "b" * 40}, {"probeProgress": {}},
                         {"probeProgress": {"probe-progress.json": {"executionPlatform": "ios-simulator",
                             "processIdentifier": 999, "recordedAt": 1}}}):
            run, _ = self.make_run(require_native_tcp=True)
            with self.subTest(override=override), patch.object(probe.sys, "platform", "darwin"), \
                    patch.object(probe, "wait_for_probe", side_effect=lambda *args:
                        self.write_tcp_report(run, {"passed": True}, **override)):
                with self.assertRaisesRegex(RuntimeError, "Required native TCP report"):
                    run.run("iPhone")
            self.assertEqual(run.result["status"], "failed")
            self.assertFalse(run.result["nativeTCPGate"]["passed"])

    def tls_capability(self):
        return {"suite": "TlsCapabilityProbe", "passed": True, "loopbackOnly": True,
                "provesHTTPCompatibility": False,
                "cases": [{"name": name, "passed": True} for name in
                    ("trusted-tls12", "trusted-tls13", "untrusted-ca", "wrong-host")],
                "cleanup": {"serverStopped": True, "timerStopped": True, "errors": []}}

    def test_required_native_tls_accepts_four_current_run_cases_and_preserves_both_gates(self):
        run, _ = self.make_run(require_native_tcp=True, require_native_tls=True)
        capability = self.tls_capability()
        with patch.object(probe.sys, "platform", "darwin"), patch.object(probe, "wait_for_probe",
                side_effect=lambda *args: self.write_tcp_report(run, {"passed": True}, nativeTLSProbe=capability)):
            run.run("iPhone")
        self.assertEqual(run.result["status"], "passed")
        self.assertEqual(run.result["capabilityRequired"], {"nativeTCP": True, "nativeTLS": True, "nativeHTTPWire": False})
        self.assertTrue(run.result["nativeTCPGate"]["passed"])
        self.assertTrue(run.result["nativeTLSGate"]["passed"])
        self.assertEqual(run.result["nativeTLSGate"]["probe"], capability)
        self.assertEqual(run.result["nativeTLSGate"]["reportSHA256"], run.result["nativeTCPGate"]["reportSHA256"])

    def test_required_native_tls_false_missing_non_boolean_and_cleanup_failure_never_pass(self):
        failed = {**self.tls_capability(), "passed": False, "failure": [
            {"type": "java.lang.UnsatisfiedLinkError", "message": "TLS native entry missing"}]}
        case_false = self.tls_capability()
        case_false["cases"][2]["passed"] = False
        case_non_boolean = self.tls_capability()
        case_non_boolean["cases"][1]["passed"] = 1
        worker_running = self.tls_capability()
        worker_running["cleanup"]["serverStopped"] = False
        cleanup_error = self.tls_capability()
        cleanup_error["cleanup"]["errors"] = ["socket close failed"]
        for capability in (failed, None, {**self.tls_capability(), "passed": 1},
                           case_false, case_non_boolean, worker_running, cleanup_error):
            run, _ = self.make_run(require_native_tls=True)
            with self.subTest(capability=capability), patch.object(probe.sys, "platform", "darwin"), \
                    patch.object(probe, "wait_for_probe", side_effect=lambda *args:
                        self.write_tcp_report(run, None, nativeTLSProbe=capability)):
                with self.assertRaisesRegex(RuntimeError, "Required native TLS capability failed") as failure:
                    run.run("iPhone")
            self.assertEqual(run.result["status"], "failed")
            self.assertFalse(run.result["simulatorValidationPassed"])
            self.assertTrue(run.result["capabilityRequired"]["nativeTLS"])
            self.assertFalse(run.result["nativeTLSGate"]["passed"])
            self.assertEqual(run.result["nativeTLSGate"]["probe"], capability)
            if capability is failed:
                self.assertIn("TLS native entry missing", str(failure.exception))

    def test_required_native_tls_rejects_missing_duplicate_or_wrong_suite_cases(self):
        missing_case = self.tls_capability()
        missing_case["cases"].pop()
        duplicate_case = self.tls_capability()
        duplicate_case["cases"][3]["name"] = "trusted-tls12"
        extra_case = self.tls_capability()
        extra_case["cases"].append({"name": "unexpected", "passed": True})
        for capability in (missing_case, duplicate_case, extra_case, {**self.tls_capability(), "suite": "OtherSuite"}):
            run, _ = self.make_run(require_native_tls=True)
            with self.subTest(capability=capability), patch.object(probe.sys, "platform", "darwin"), \
                    patch.object(probe, "wait_for_probe", side_effect=lambda *args:
                        self.write_tcp_report(run, None, nativeTLSProbe=capability)):
                with self.assertRaisesRegex(RuntimeError, "Required native TLS capability failed"):
                    run.run("iPhone")
            self.assertEqual(run.result["status"], "failed")
            self.assertFalse(run.result["nativeTLSGate"]["passed"])
            self.assertEqual(run.result["nativeTLSGate"]["probe"], capability)


    def http_wire_capability(self):
        spec = importlib.util.spec_from_file_location("runner_http_wire_synthetic_fixture", SCRIPT.with_name("test-http-wire.py"))
        fixtures = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fixtures)
        return fixtures.synthetic_capability()

    def test_required_native_http_wire_links_raw_bytes_and_requires_original_strict_comparison(self):
        run, _ = self.make_run(require_native_tcp=True, require_native_tls=True, require_native_http_wire=True)
        capability = self.http_wire_capability()
        with patch.object(probe.sys, "platform", "darwin"), patch.object(probe, "wait_for_probe",
                side_effect=lambda *args: self.write_tcp_report(run, {"passed": True},
                    nativeTLSProbe=self.tls_capability(), nativeHTTPWireProbe=capability)):
            run.run("iPhone")
        self.assertEqual(run.result["status"], "passed")
        gate = run.result["nativeHTTPWireGate"]
        self.assertTrue(gate["passed"])
        self.assertEqual(gate["wireVerification"]["strictComparison"]["differenceCount"], 0)
        self.assertEqual(gate["reportSHA256"], run.result["nativeTLSGate"]["reportSHA256"])
        self.assertFalse(gate["wireVerification"]["g4ValidationPassed"])
        self.assertTrue(Path(gate["comparisonPath"]).is_file())

    def test_missing_or_failed_native_http_wire_never_passes_the_required_gate(self):
        for capability in (None, {}, {"passed": False, "failure": "native HTTP unavailable"}):
            run, _ = self.make_run(require_native_http_wire=True)
            with self.subTest(capability=capability), patch.object(probe.sys, "platform", "darwin"), \
                    patch.object(probe, "wait_for_probe", side_effect=lambda *args:
                        self.write_tcp_report(run, None, nativeHTTPWireProbe=capability)):
                with self.assertRaisesRegex(RuntimeError, "Required native HTTP wire capability failed"):
                    run.run("iPhone")
            self.assertFalse(run.result["simulatorValidationPassed"])
            self.assertFalse(run.result["nativeHTTPWireGate"]["passed"])
            self.assertEqual(run.result["nativeHTTPWireGate"]["probe"], capability)

    def test_native_http_success_flag_does_not_override_a_real_strict_difference(self):
        run, _ = self.make_run(require_native_http_wire=True)
        capability = self.http_wire_capability()
        capability["readingChain"]["snapshot"]["cache"]["lastKey"] = "changed"
        with patch.object(probe.sys, "platform", "darwin"), patch.object(probe, "wait_for_probe",
                side_effect=lambda *args: self.write_tcp_report(run, None, nativeHTTPWireProbe=capability)):
            with self.assertRaisesRegex(RuntimeError, "strict comparison did not pass"):
                run.run("iPhone")
        gate = run.result["nativeHTTPWireGate"]
        self.assertFalse(gate["passed"])
        self.assertGreater(gate["wireVerification"]["strictComparison"]["differenceCount"], 0)
        self.assertTrue(Path(gate["comparisonPath"]).is_file())


if __name__ == "__main__":
    unittest.main()
