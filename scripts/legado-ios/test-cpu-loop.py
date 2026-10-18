#!/usr/bin/env python3
"""Synthetic guard tests; these never execute an iOS app, JVM or CPU workload."""
from copy import deepcopy
import importlib.util
import json
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location("cpu_loop_guard", Path(__file__).with_name("verify-cpu-loop.py"))
cpu = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cpu)


def synthetic_capability():
    cases = []
    for index, name in enumerate(("public-cancel", "absolute-deadline")):
        token = f"12345678-1234-1234-1234-{index:012d}"
        task, session = "cpu-task-" + str(index), "cpu-session-" + str(index)
        item = {"name": name, "passed": True, "taskId": task, "sessionId": session, "token": token,
                "childDeadlineEpochMs": 5000, "contextExited": True, "sessionClosed": True,
                "signal": {"token": token, "iterations": 16384, "checksum": 402644992, "recordedNanoTime": 100},
                "cpuSample": {"passed": True, "sampledNanoTime": 110, "workerId": 9,
                    "stack": ["org.htmlunit.corejs.javascript.Interpreter.interpretLoop(Interpreter.java:123)"]},
                "sessionEnvelope": json.dumps({"ok": True, "sessionId": session}),
                "closeEnvelope": '{"ok":true}',
                "operationEnvelope": json.dumps({"ok": False, "taskId": task,
                    "error": {"code": "CANCELLED" if index == 0 else "TIMEOUT"}}),
                "recovery": {"workerId": 9, "contextExited": True, "operationEnvelope": json.dumps({
                    "ok": True, "taskId": "cpu-recovery-" + str(index), "result": 42})}}
        if index == 0:
            item.update(cancelRequestedNanoTime=120, cancelEnvelope=json.dumps({"ok": True, "taskId": task, "cancelled": True}))
        cases.append(item)
    return {"suite": "CpuLoopCapabilityProbe", "passed": True, "interpreted": True,
            "fixtureOnly": True, "g4ValidationPassed": False, "parentDeadlineEpochMs": 10000,
            "cases": cases, "cleanup": {"workerStopped": True, "sessionsClosed": True, "registryEmpty": True, "errors": []}}


class CpuLoopGuardTests(unittest.TestCase):
    def rejects(self, changed):
        with self.assertRaises(ValueError):
            cpu.verify(changed)

    def test_complete_fixed_evidence_passes_without_promoting_full_gates(self):
        result = cpu.verify(synthetic_capability())
        self.assertTrue(result["passed"])
        self.assertFalse(result["g4ValidationPassed"])
        self.assertFalse(result["fullStabilityGatePassed"])

    def test_supplied_pass_or_signal_cannot_replace_cpu_stack(self):
        for stack in ([], ["org.htmlunit.corejs.javascript.NativeJavaMethod.call(Java.java:1)"],
                      ["org.htmlunit.corejs.javascript.Interpreter.interpretLoop(Interpreter.java:1)",
                       "io.yuedu.legado.CpuLoopCapabilityProbe$workload$1.call(Probe.kt:1)"]):
            value = synthetic_capability(); value["cases"][0]["cpuSample"]["stack"] = stack
            self.rejects(value)

    def test_changed_signal_checksum_or_temporal_order_fails(self):
        for field, replacement in (("iterations", True), ("checksum", 1), ("token", "unrelated"), ("recordedNanoTime", 111)):
            value = synthetic_capability(); value["cases"][0]["signal"][field] = replacement
            self.rejects(value)
        value = synthetic_capability(); value["cases"][0]["cancelRequestedNanoTime"] = 109
        self.rejects(value)

    def test_distinct_error_and_real_public_cancel_envelopes_are_required(self):
        for index, envelope in ((0, '{"ok":true}'), (1, '{"ok":false,"taskId":"cpu-task-1","error":{"code":"CANCELLED"}}')):
            value = synthetic_capability(); value["cases"][index]["operationEnvelope"] = envelope
            self.rejects(value)
        value = synthetic_capability(); value["cases"][0]["cancelEnvelope"] = '{"ok":true,"cancelled":false}'
        self.rejects(value)

    def test_wrong_deadline_or_reused_identity_fails(self):
        value = synthetic_capability(); value["cases"][0]["childDeadlineEpochMs"] = 10001
        self.rejects(value)
        value = synthetic_capability(); value["cases"][1]["token"] = value["cases"][0]["token"]
        self.rejects(value)
        value = synthetic_capability(); value["cases"][1] = deepcopy(value["cases"][0])
        self.rejects(value)

    def test_recovery_and_owned_resource_cleanup_cannot_be_omitted(self):
        for field, replacement in (("workerId", 10), ("contextExited", False), ("operationEnvelope", '{"ok":false}')):
            value = synthetic_capability(); value["cases"][0]["recovery"][field] = replacement
            self.rejects(value)
        for field in ("workerStopped", "sessionsClosed", "registryEmpty"):
            value = synthetic_capability(); value["cleanup"][field] = False
            self.rejects(value)

    def test_missing_failed_malformed_or_promoted_report_fails_closed(self):
        for value in (None, {}, {**synthetic_capability(), "passed": 1},
                      {**synthetic_capability(), "g4ValidationPassed": True}):
            self.rejects(value)


if __name__ == "__main__":
    unittest.main()
