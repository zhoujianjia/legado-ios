#!/usr/bin/env python3
"""Owned synthetic fixtures only; no phone report, account or pairing input is read."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("current_report_inspector", HERE / "inspect-renewal-report.py")
inspector = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(inspector)


def tcp(outcome="tcpConnected", family="ipv4"):
    record = {"family": family, "addressCategory": "localInterface", "outcome": outcome, "elapsedMilliseconds": 1.25}
    if outcome == "transportFailed":
        record["networkError"] = {"domain": "posix", "code": 1}
    return record


def fixture(**changes):
    discovery = {"discoveryStarted": True, "outcome": "discoveryTimedOut", "phase": "checkingOwnership",
        "elapsedMilliseconds": 3001.2, "discoveredServiceCount": 0, "resolvedAddressCount": 0,
        "rejectedAddressCount": 0, "approvedEndpointCount": 0, "tcpConnectionAttemptsStarted": 0,
        "tcpAttempts": [], "tcpApplicationPayloadBytesSent": 0, "serviceIdentityVerified": False}
    discovery.update(changes)
    return {"schemaVersion": 2, "appBuild": "42", "sourceCommit": "b" * 40, "appVersion": "3.0.0",
        "operatingSystem": "Owned synthetic fixture; no real device was run",
        "computerPoweredOff": "notMeasured", "companionAppsAbsent": "notMeasured",
        "dynamicRemotePairingDiscoveryAttempted": discovery["discoveryStarted"], "interpretation": inspector.INTERPRETATION,
        "report": {"schemaVersion": 2, "startedAt": "2026-10-19T00:00:00Z", "finishedAt": "2026-10-19T00:00:08Z",
            "executionEnvironment": "device", "attempts": [], "cancelled": discovery["outcome"] == "cancelled",
            **{flag: False for flag in inspector.FALSE_FLAGS}, "remotePairingDiscovery": discovery}}


def connected(**changes):
    return fixture(**{"outcome": "tcpConnected", "phase": "completed", "discoveredServiceCount": 1,
        "resolvedAddressCount": 1, "approvedEndpointCount": 1, "tcpConnectionAttemptsStarted": 1,
        "tcpAttempts": [tcp()], **changes})


def schema_one(build="11"):
    return {"appBuild": build, "appVersion": "3.0.0", "sourceCommit": inspector.legacy.KNOWN_BUILDS[build],
        "operatingSystem": "Owned synthetic schema-one fixture", "computerPoweredOff": "notMeasured",
        "companionAppsAbsent": "notMeasured", "dynamicRemotePairingDiscoveryAttempted": False,
        "interpretation": inspector.legacy.INTERPRETATION,
        "report": {"schemaVersion": 1, "startedAt": "2026-10-19T00:00:00Z", "finishedAt": "2026-10-19T00:00:07Z",
            "executionEnvironment": "device", "cancelled": False, **{flag: False for flag in inspector.FALSE_FLAGS},
            "attempts": [{"address": address, "port": 62078, "outcome": "timedOut", "phase": "connecting",
                "tcpConnected": False, "lockdownConfirmed": False, "elapsedMilliseconds": 3100.5,
                "receivedByteCount": 0} for address in ("127.0.0.1", "::1")]}}


class SyntheticInspectorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def write(self, name, value):
        path = self.root / name
        path.write_bytes(json.dumps(value).encode())
        return path

    def reject(self, record):
        with self.assertRaises(inspector.InvalidReport):
            inspector.inspect_envelope(record)

    def discovery(self, record):
        return record["report"]["remotePairingDiscovery"]

    def manifest(self, report=None, **changes):
        report = report or fixture()
        value = {"schemaVersion": 1, "build": report.get("appBuild", "42"), "sourceCommit": report.get("sourceCommit", "b" * 40),
            "version": "3.0.0", "configuration": "Release", "platform": "iPhoneOS", "architecture": "arm64",
            "bundleIdentifier": "local.zhoujianjia.legado-reader", "signed": False, "ipaSHA256": "c" * 64, "ipaBytes": 1234}
        value.update(changes)
        path = self.write("synthetic-manifest.json", value)
        return path, hashlib.sha256(path.read_bytes()).hexdigest()

    def test_schema_one_known_builds_remain_compatible_and_unattested(self):
        for build in ("10", "11"):
            result = inspector.inspect_envelope(schema_one(build))
            self.assertTrue(result["knownBuildSourcePairMatches"])
            self.assertFalse(result["provenanceEstablished"])
            self.assertFalse(result["deviceAuthenticityAttested"])
            self.assertEqual(result["status"], "schema-only-contract-checked")
        bad = schema_one()
        bad["sourceCommit"] = inspector.legacy.KNOWN_BUILDS["10"]
        self.reject(bad)
        bad = schema_one()
        bad["appBuild"] = "42"
        self.reject(bad)

    def test_schema_one_does_not_accept_schema_two_or_private_additions(self):
        for mutate in (lambda r: r.__setitem__("schemaVersion", 2),
                       lambda r: r["report"].__setitem__("remotePairingDiscovery", {}),
                       lambda r: r["report"]["attempts"][0].__setitem__("port", 49152),
                       lambda r: r["report"]["attempts"][0].__setitem__("PairRecord", "owned-secret")):
            record = schema_one()
            mutate(record)
            self.reject(record)

    def test_schema_two_empty_and_tcp_ready_are_never_renewal_evidence(self):
        for record in (fixture(), connected()):
            result = inspector.inspect_envelope(record)
            self.assertFalse(result["provenanceEstablished"])
            self.assertFalse(result["deviceAuthenticityAttested"])
            self.assertFalse(result["automaticSelfRenewalImplemented"])
            self.assertFalse(result["automaticSelfRenewalVerified"])
            self.assertFalse(result["otherTransportsExcluded"])
            self.assertEqual(result["computerPoweredOff"], "notMeasured")
            self.assertEqual(result["companionAppsAbsent"], "notMeasured")
            self.assertFalse(result["discoveryFactsFromReport"]["serviceIdentityVerified"])
            self.assertNotIn("Owned synthetic fixture", json.dumps(result))

    def test_snapshot_prestart_outcomes_remain_consistent(self):
        for outcome in ("cancelled", "timedOut", "internalError"):
            result = inspector.inspect_envelope(fixture(discoveryStarted=False, outcome=outcome, phase="snapshotting"))
            self.assertFalse(result["dynamicRemotePairingDiscoveryAttempted"])
        for change in ({"discoveredServiceCount": 1}, {"resolvedAddressCount": 1}, {"lastWaitingError": {"domain": "posix", "code": 1}},
                       {"discoveryStarted": True}, {"outcome": "discoveryTimedOut"}):
            self.reject(fixture(**{"discoveryStarted": False, "outcome": "internalError", "phase": "snapshotting", **change}))

    def test_early_discovery_failures_changes_and_limits_need_no_error_guess(self):
        for phase, services in (("discovering", 0), ("resolving", 1)):
            for outcome in ("discoveryUnavailable", "discoveryChanged", "limitExceeded", "cancelled", "timedOut"):
                inspector.inspect_envelope(fixture(phase=phase, outcome=outcome, discoveredServiceCount=services))
        inspector.inspect_envelope(fixture(phase="discovering", outcome="discoveryUnavailable", networkError={"domain": "dns", "code": -65570}))

    def test_overflow_counts_include_the_observation_that_crossed_the_guard(self):
        for changes in ({"discoveredServiceCount": 9, "resolvedAddressCount": 0},
                        {"discoveredServiceCount": 1, "resolvedAddressCount": 33, "rejectedAddressCount": 32}):
            inspector.inspect_envelope(fixture(outcome="limitExceeded", phase="resolving", **changes))
        for changes in ({"discoveredServiceCount": 10}, {"resolvedAddressCount": 34},
                        {"discoveredServiceCount": 9, "resolvedAddressCount": 33},
                        {"discoveredServiceCount": 9, "outcome": "discoveryChanged"}):
            self.reject(fixture(**{"outcome": "limitExceeded", "phase": "resolving", "discoveredServiceCount": 1, **changes}))

    def test_resolution_errors_waiting_and_empty_windows_are_distinct(self):
        dns = {"domain": "dns", "code": -65570}
        inspector.inspect_envelope(fixture(outcome="resolutionFailed", discoveredServiceCount=1, networkError=dns))
        result = inspector.inspect_envelope(fixture(outcome="discoveryUnavailable", lastWaitingError=dns))
        self.assertEqual(result["discoveryFactsFromReport"]["lastWaitingError"], dns)
        for record in (fixture(outcome="resolutionFailed", discoveredServiceCount=1),
                       fixture(outcome="discoveryUnavailable"), fixture(networkError=dns), fixture(lastWaitingError=dns)):
            self.reject(record)

    def test_removed_expired_and_budget_limited_candidates_have_valid_counts(self):
        inspector.inspect_envelope(fixture(outcome="noLocalCandidate", discoveredServiceCount=1, resolvedAddressCount=1))
        inspector.inspect_envelope(fixture(outcome="noLocalCandidate", discoveredServiceCount=1, resolvedAddressCount=1,
                                           rejectedAddressCount=1, approvedEndpointCount=1))
        inspector.inspect_envelope(fixture(outcome="limitExceeded", discoveredServiceCount=1, resolvedAddressCount=5))
        for changes in ({"resolvedAddressCount": 0}, {"rejectedAddressCount": 2}, {"approvedEndpointCount": 5},
                        {"phase": "resolving"}):
            self.reject(fixture(**{"outcome": "noLocalCandidate", "discoveredServiceCount": 1, "resolvedAddressCount": 1, **changes}))

    def test_overall_deadline_or_cancel_can_interrupt_exactly_one_tcp_attempt(self):
        for outcome in ("timedOut", "cancelled"):
            for completed in (0, 1):
                inspector.inspect_envelope(fixture(outcome=outcome, phase="connecting", discoveredServiceCount=1,
                    resolvedAddressCount=2, approvedEndpointCount=2, tcpConnectionAttemptsStarted=completed + 1,
                    tcpAttempts=[tcp("timedOut")] * completed))
        for delta in (-1, 2):
            self.reject(fixture(outcome="timedOut", phase="connecting", discoveredServiceCount=1,
                resolvedAddressCount=3, approvedEndpointCount=3, tcpConnectionAttemptsStarted=1 + delta,
                tcpAttempts=[tcp("timedOut")]))
        self.reject(connected(tcpConnectionAttemptsStarted=2, approvedEndpointCount=2, resolvedAddressCount=2))

    def test_ownership_failure_can_follow_completed_unsuccessful_attempts(self):
        for outcome in ("interfaceChanged", "internalError", "timedOut", "cancelled", "transportFailed"):
            inspector.inspect_envelope(fixture(outcome=outcome, phase="checkingOwnership", discoveredServiceCount=1,
                resolvedAddressCount=2, approvedEndpointCount=2, tcpConnectionAttemptsStarted=1, tcpAttempts=[tcp("timedOut")]))
        self.reject(fixture(outcome="interfaceChanged", phase="checkingOwnership", discoveredServiceCount=1,
            resolvedAddressCount=1, approvedEndpointCount=1, tcpConnectionAttemptsStarted=1, tcpAttempts=[tcp("timedOut")]))
        self.reject(fixture(outcome="internalError", phase="checkingOwnership", discoveredServiceCount=1,
            resolvedAddressCount=1, approvedEndpointCount=1, tcpConnectionAttemptsStarted=1, tcpAttempts=[tcp("timedOut")]))

    def test_tcp_ready_cancelled_and_failure_terminate_in_the_right_order(self):
        inspector.inspect_envelope(connected(resolvedAddressCount=2, approvedEndpointCount=2, tcpConnectionAttemptsStarted=2,
                                             tcpAttempts=[tcp("timedOut"), tcp("tcpConnected", "ipv6")]))
        inspector.inspect_envelope(fixture(outcome="transportFailed", phase="connecting", discoveredServiceCount=1,
            resolvedAddressCount=1, approvedEndpointCount=1, tcpConnectionAttemptsStarted=1, tcpAttempts=[tcp("internalError")]))
        inspector.inspect_envelope(fixture(outcome="cancelled", phase="connecting", discoveredServiceCount=1,
            resolvedAddressCount=1, approvedEndpointCount=1, tcpConnectionAttemptsStarted=1, tcpAttempts=[tcp("cancelled")]))
        for attempts in ([tcp("tcpConnected"), tcp("timedOut")], [tcp("cancelled"), tcp("tcpConnected")],
                         [tcp("timedOut", "ipv6"), tcp("tcpConnected", "ipv4")]):
            self.reject(connected(resolvedAddressCount=2, approvedEndpointCount=2, tcpConnectionAttemptsStarted=2, tcpAttempts=attempts))
        self.reject(connected(phase="connecting"))

    def test_tcp_errors_are_normalized_and_cannot_claim_unattempted_stages(self):
        valid = fixture(outcome="transportFailed", phase="connecting", discoveredServiceCount=1, resolvedAddressCount=1,
            approvedEndpointCount=1, tcpConnectionAttemptsStarted=1, tcpAttempts=[tcp("transportFailed")])
        inspector.inspect_envelope(valid)
        for key, value in (("outcome", "resolutionFailed"), ("family", "host-name"), ("addressCategory", "peer"),
                           ("networkError", None), ("elapsedMilliseconds", True)):
            record = copy.deepcopy(valid)
            self.discovery(record)["tcpAttempts"][0][key] = value
            self.reject(record)
        record = connected()
        self.discovery(record)["tcpAttempts"][0]["networkError"] = {"domain": "posix", "code": 1}
        self.reject(record)

    def test_unknown_and_private_fields_are_rejected_at_every_report_level(self):
        for target in ("envelope", "report", "discovery", "tcp", "error"):
            for field in ("hostname", "address", "port", "TXT", "interfaceIndex", "PairRecord", "AppleID", "description"):
                record = connected()
                if target == "envelope":
                    value = record
                elif target == "report":
                    value = record["report"]
                elif target == "discovery":
                    value = self.discovery(record)
                elif target == "tcp":
                    value = self.discovery(record)["tcpAttempts"][0]
                else:
                    self.discovery(record)["lastWaitingError"] = {"domain": "dns", "code": -65570}
                    value = self.discovery(record)["lastWaitingError"]
                value[field] = "owned-secret-never-export"
                self.reject(record)

    def test_false_flags_context_and_tcp_payload_use_strict_json_types(self):
        for flag in inspector.FALSE_FLAGS:
            for value in (True, 0, None, "false"):
                record = connected()
                record["report"][flag] = value
                self.reject(record)
        for field in ("tcpApplicationPayloadBytesSent", "serviceIdentityVerified"):
            for value in (True, 0.0, None, "false"):
                record = connected()
                self.discovery(record)[field] = value
                self.reject(record)
        record = connected()
        self.discovery(record)["tcpApplicationPayloadBytesSent"] = False
        self.reject(record)
        for field in ("computerPoweredOff", "companionAppsAbsent"):
            record = connected()
            record[field] = True
            self.reject(record)
        for field in ("discoveredServiceCount", "resolvedAddressCount", "rejectedAddressCount", "approvedEndpointCount", "tcpConnectionAttemptsStarted"):
            record = connected()
            self.discovery(record)[field] = True
            self.reject(record)

    def test_full_four_endpoint_budget_preserves_serial_terminal_attempts(self):
        result = inspector.inspect_envelope(connected(resolvedAddressCount=4, approvedEndpointCount=4,
            tcpConnectionAttemptsStarted=4, tcpAttempts=[tcp("timedOut"), tcp("internalError"),
                tcp("transportFailed", "ipv6"), tcp("tcpConnected", "ipv6")]))
        self.assertEqual(len(result["discoveryFactsFromReport"]["tcpAttempts"]), 4)

    def test_envelope_version_environment_start_and_cancel_match_the_report(self):
        for mutate in (lambda r: r.__setitem__("schemaVersion", True),
                       lambda r: r["report"].__setitem__("schemaVersion", 1),
                       lambda r: r["report"].__setitem__("executionEnvironment", "simulator"),
                       lambda r: r["report"].__setitem__("cancelled", True),
                       lambda r: r["report"].__setitem__("attempts", [{}]),
                       lambda r: r.__setitem__("dynamicRemotePairingDiscoveryAttempted", False),
                       lambda r: r.__setitem__("interpretation", "renewal passed"),
                       lambda r: r.__setitem__("sourceCommit", "6b3a3bd"),
                       lambda r: r.__setitem__("appBuild", 42)):
            record = connected()
            mutate(record)
            self.reject(record)

    def test_elapsed_accepts_late_scheduling_without_claiming_deadline_accuracy(self):
        result = inspector.inspect_envelope(connected(elapsedMilliseconds=123456.75))
        self.assertFalse(result["deadlineSchedulingAccuracyEstablished"])
        for number in (-1, True, float("nan"), float("inf"), 10**1000):
            self.reject(connected(elapsedMilliseconds=number))

    def test_duplicate_nonfinite_invalid_utf8_and_oversized_inputs_are_rejected(self):
        encoded = json.dumps(connected()).encode()
        for raw in (b'{"report":{},"report":{}}', encoded.replace(b'3001.2', b'NaN'),
                    encoded.replace(b'3001.2', b'1e400'),
                    b'{"x":Infinity}', b'\xff', b' ' * (inspector.MAX_INPUT_BYTES + 1), b'[' * 2000):
            path = self.root / "owned-invalid.json"
            path.write_bytes(raw)
            with self.assertRaises(inspector.InvalidReport):
                inspector.inspect_file(path)

    def test_explicit_manifest_without_external_digest_is_only_schema_checked(self):
        record = connected()
        path, _ = self.manifest(record)
        result = inspector.inspect_envelope(record, path)
        self.assertTrue(result["manifestBuildSourcePairMatched"])
        self.assertFalse(result["provenanceEstablished"])
        self.assertEqual(result["status"], "schema-only-contract-checked")

    def test_external_manifest_digest_binds_a_future_source_without_hardcoding_build_twelve(self):
        for record in (connected(), schema_one("11")):
            path, digest = self.manifest(record)
            result = inspector.inspect_envelope(record, path, digest)
            self.assertTrue(result["provenanceEstablished"])
            self.assertTrue(result["manifestDigestMatched"])
            self.assertFalse(result["manifestDeliveryOrDeviceInstallationAttested"])
            self.assertFalse(result["deviceAuthenticityAttested"])
            self.assertFalse(result["automaticSelfRenewalVerified"])

    def test_unverifiable_or_wrong_digest_manifests_never_establish_provenance(self):
        record = connected()
        path, _ = self.manifest(record)
        result = inspector.inspect_envelope(record, path, "0" * 64)
        self.assertFalse(result["provenanceEstablished"])
        self.assertEqual(result["manifestBindingStatus"], "digestMismatch")
        for raw in (b"invalid JSON", b'{"schemaVersion":1,"schemaVersion":1}', b"x" * (inspector.MAX_INPUT_BYTES + 1)):
            path.write_bytes(raw)
            result = inspector.inspect_envelope(record, path, "0" * 64)
            self.assertFalse(result["provenanceEstablished"])
            self.assertEqual(result["manifestBindingStatus"], "unverifiable")
        path.unlink()
        self.assertFalse(inspector.inspect_envelope(record, path)["provenanceEstablished"])

    def test_mismatched_valid_manifest_build_source_or_version_is_rejected(self):
        record = connected()
        for change in ({"build": "43"}, {"sourceCommit": "a" * 40}, {"version": "3.0.1"}):
            path, digest = self.manifest(record, **change)
            with self.assertRaises(inspector.InvalidReport):
                inspector.inspect_envelope(record, path, digest)
        with self.assertRaises(inspector.InvalidReport):
            inspector.inspect_envelope(record, None, "a" * 64)

    def test_missing_optional_source_metadata_can_only_produce_schema_only(self):
        record = connected()
        record.pop("appBuild")
        record.pop("sourceCommit")
        result = inspector.inspect_envelope(record)
        self.assertIsNone(result["declaredSourceCommit"])
        path, digest = self.manifest()
        self.assertFalse(inspector.inspect_envelope(record, path, digest)["provenanceEstablished"])

    def test_cli_reads_only_explicit_inputs_and_does_not_echo_rejected_private_values(self):
        path = self.write("owned-report.json", connected())
        result = subprocess.run([sys.executable, "-B", str(HERE / "inspect-renewal-report.py"), str(path)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertFalse(json.loads(result.stdout)["provenanceEstablished"])
        path.write_bytes(b'{"report":{},"private":"owned-secret-never-export"}')
        result = subprocess.run([sys.executable, "-B", str(HERE / "inspect-renewal-report.py"), str(path)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("owned-secret-never-export", result.stderr)
        self.assertNotIn(str(path), result.stderr)

    def test_bounded_selection_keeps_skipped_count_independent_of_tcp_early_success(self):
        changes = dict(discoveredServiceCount=2, resolvedAddressCount=6, rejectedAddressCount=1,
                       approvedEndpointCount=4, eligibleEndpointCount=5, skippedEndpointCount=1,
                       endpointSelectionLimit=4)
        for record in (connected(**changes), fixture(**changes, outcome="transportFailed", phase="connecting",
                tcpConnectionAttemptsStarted=4, tcpAttempts=[tcp("transportFailed")] * 4)):
            result = inspector.inspect_envelope(record)
            facts = result["discoveryFactsFromReport"]
            self.assertEqual((facts["eligibleEndpointCount"], facts["approvedEndpointCount"],
                              facts["skippedEndpointCount"], facts["endpointSelectionLimit"]), (5, 4, 1, 4))
            self.assertFalse(result["automaticSelfRenewalVerified"])
            self.assertFalse(facts["serviceIdentityVerified"])
        self.assertEqual(inspector.inspect_envelope(connected(**changes))[
            "discoveryFactsFromReport"]["tcpConnectionAttemptsStarted"], 1)
        for interpretation in (inspector.INTERPRETATION, inspector.SELECTION_INTERPRETATION):
            record = connected(**changes)
            record["interpretation"] = interpretation
            self.assertEqual(inspector.inspect_envelope(record)["interpretation"], interpretation)
        for interpretation in (inspector.SELECTION_INTERPRETATION + " ",
                               inspector.SELECTION_INTERPRETATION.replace("four selected", "five selected"),
                               inspector.SELECTION_INTERPRETATION[:-1], None, []):
            record = connected(**changes)
            record["interpretation"] = interpretation
            self.reject(record)

    def test_selection_accepts_empty_four_and_thirty_two_endpoint_boundaries(self):
        empty = fixture(eligibleEndpointCount=0, skippedEndpointCount=0, endpointSelectionLimit=4)
        self.assertEqual(inspector.inspect_envelope(empty)["discoveryFactsFromReport"]["eligibleEndpointCount"], 0)
        for eligible in (1, 2, 3, 4, 32):
            approved = min(eligible, 4)
            record = connected(resolvedAddressCount=eligible, approvedEndpointCount=approved,
                eligibleEndpointCount=eligible, skippedEndpointCount=eligible - approved, endpointSelectionLimit=4)
            self.assertEqual(inspector.inspect_envelope(record)["discoveryFactsFromReport"]["skippedEndpointCount"],
                             max(0, eligible - 4))

    def test_selection_triplet_requires_all_fields_and_strict_integer_values(self):
        fields = {"eligibleEndpointCount": 1, "skippedEndpointCount": 0, "endpointSelectionLimit": 4}
        for name in fields:
            partial = connected()
            self.discovery(partial)[name] = fields[name]
            self.reject(partial)
            partial = connected(**fields)
            del self.discovery(partial)[name]
            self.reject(partial)
            for value in (True, False, None, 1.0, "1", -1, 10**1000):
                record = connected(**fields)
                self.discovery(record)[name] = value
                self.reject(record)

    def test_selection_rejects_wrong_arithmetic_limits_and_resolved_caps(self):
        valid = dict(discoveredServiceCount=2, resolvedAddressCount=6, approvedEndpointCount=4,
                     eligibleEndpointCount=5, skippedEndpointCount=1, endpointSelectionLimit=4)
        for change in ({"skippedEndpointCount": 0}, {"skippedEndpointCount": 2},
                       {"endpointSelectionLimit": 3}, {"endpointSelectionLimit": 5},
                       {"approvedEndpointCount": 3}, {"eligibleEndpointCount": 4},
                       {"eligibleEndpointCount": 7, "skippedEndpointCount": 3},
                       {"eligibleEndpointCount": 33, "resolvedAddressCount": 33, "skippedEndpointCount": 29}):
            self.reject(connected(**{**valid, **change}))

    def test_selection_counts_cannot_precede_a_normal_closed_window(self):
        counts = dict(eligibleEndpointCount=0, skippedEndpointCount=0, endpointSelectionLimit=4)
        # The new app uses its updated scope text even when selection never starts.
        early = fixture(discoveryStarted=False, outcome="cancelled", phase="snapshotting")
        early["interpretation"] = inspector.SELECTION_INTERPRETATION
        self.assertEqual(inspector.inspect_envelope(early)["interpretation"], inspector.SELECTION_INTERPRETATION)
        for phase, services in (("snapshotting", 0), ("discovering", 0), ("resolving", 1)):
            record = fixture(**counts, discoveryStarted=phase != "snapshotting", outcome="cancelled",
                             phase=phase, discoveredServiceCount=services)
            self.reject(record)
        for outcome in ("limitExceeded", "discoveryChanged"):
            for phase in ("discovering", "resolving", "checkingOwnership"):
                self.reject(fixture(**counts, outcome=outcome, phase=phase, discoveredServiceCount=1,
                                    resolvedAddressCount=6))
        for outcome in ("internalError", "cancelled", "timedOut"):
            self.reject(fixture(**counts, outcome=outcome))

    def test_selection_counts_survive_later_snapshot_ttl_cancel_and_deadline_failures(self):
        counts = dict(discoveredServiceCount=2, resolvedAddressCount=6, approvedEndpointCount=4,
                      eligibleEndpointCount=5, skippedEndpointCount=1, endpointSelectionLimit=4)
        for outcome in ("interfaceChanged", "internalError", "cancelled", "timedOut"):
            facts = inspector.inspect_envelope(fixture(**counts, outcome=outcome))["discoveryFactsFromReport"]
            self.assertEqual(facts["skippedEndpointCount"], 1)
            self.assertEqual(facts["tcpConnectionAttemptsStarted"], 0)
        # Rejections on revalidation can refer to candidates counted as eligible earlier.
        inspector.inspect_envelope(fixture(**counts, outcome="noLocalCandidate", rejectedAddressCount=5))
        for outcome in ("cancelled", "timedOut"):
            inspector.inspect_envelope(fixture(**counts, outcome=outcome, phase="connecting",
                tcpConnectionAttemptsStarted=2, tcpAttempts=[tcp("timedOut")]))

    def test_legacy_schema_two_reports_keep_their_original_absent_selection_fields(self):
        for record in (fixture(), connected(), fixture(outcome="limitExceeded", discoveredServiceCount=2,
                resolvedAddressCount=6, rejectedAddressCount=1)):
            facts = inspector.inspect_envelope(record)["discoveryFactsFromReport"]
            self.assertFalse(inspector.SELECTION_FIELDS.intersection(facts))

    def test_schema_one_contract_retains_the_frozen_original_bytes(self):
        raw = (HERE / "renewal-report-schema1.py").read_bytes()
        self.assertEqual(len(raw), 13187)
        self.assertEqual(hashlib.sha256(raw).hexdigest(), inspector.LEGACY_SHA256)


if __name__ == "__main__":
    unittest.main()
