#!/usr/bin/env python3
"""Inspect one explicitly named read-only SelfRenewalProbe export; never search for files.

This checks declarations and the current Swift export contract. A JSON document is
not an attestation of a real iPhone, signing, installation, or automatic renewal.
The 64 KiB input limit is an inspector resource limit, not a transport claim.
"""

from __future__ import annotations

import argparse
from datetime import datetime
import hashlib
import json
import math
from pathlib import Path
import sys


KNOWN_BUILDS = {
    "10": "594fd21552ea6513f900f1fcc8be328fc07e893f",
    "11": "ccdddd30853179b0c7a6b3d134f902c28f12e9f4",
}
MAX_INPUT_BYTES = 64 * 1024
MAX_PAYLOAD_BYTES = 16 * 1024
QUERY_TIMEOUT_SECONDS = 3
LOCKDOWN_TYPE = "com.apple.mobile.lockdown"
INTERPRETATION = (
    "Fixed loopback lockdown QueryType only. "
    "No automatic renewal or installation has been proven."
)
REPORT_FALSE_FLAGS = (
    "testTransportInjected", "tlsAttempted", "sessionStarted", "pairingAttempted",
    "accountAccessed", "signingAttempted", "installationAttempted", "renewalProven",
)
OUTCOMES = {
    "lockdownConfirmed", "protocolError", "unexpectedService", "invalidResponse",
    "transportFailed", "peerClosed", "timedOut", "cancelled", "internalError",
}
PHASES = {"connecting", "sendingQuery", "receivingHeader", "receivingPayload", "completed"}
PROTOCOL_ERRORS = {
    "InvalidResponse", "MissingHostID", "InvalidHostID", "MissingPairRecord",
    "InvalidPairRecord", "PasswordProtected", "UserDeniedPairing",
    "PairingDialogResponsePending", "PairingProhibitedOverThisConnection",
    "ServiceProhibited", "unrecognized_error",
}


class InvalidReport(ValueError):
    """A fixed diagnostic without any report content or private local path."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise InvalidReport(message)


def exact_object(value: object, required: set[str], optional: set[str], name: str) -> dict:
    require(type(value) is dict, name + " must be an object")
    require(required <= value.keys(), name + " is missing required fields")
    require(value.keys() <= required | optional, name + " contains unsupported fields")
    return value


def bounded_string(value: object, maximum: int, name: str) -> str:
    require(type(value) is str and 0 < len(value) <= maximum, name + " must be a bounded nonempty string")
    require(not any(ord(char) < 32 or ord(char) == 127 for char in value), name + " contains control characters")
    return value


def integer(value: object, minimum: int, maximum: int, name: str) -> int:
    require(type(value) is int and minimum <= value <= maximum, name + " is outside its integer bounds")
    return value


def boolean(value: object, name: str) -> bool:
    require(type(value) is bool, name + " must be a JSON boolean")
    return value


def iso_date(value: object, name: str) -> datetime:
    text = bounded_string(value, 40, name)
    # JSONEncoder.dateEncodingStrategy.iso8601 uses UTC and whole seconds.
    require(len(text) == 20 and text.endswith("Z"), name + " must use the export UTC ISO8601 format")
    try:
        return datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        raise InvalidReport(name + " is not a valid ISO8601 date") from None


def network_error(value: object, name: str) -> dict | None:
    if value is None:
        return None
    record = exact_object(value, {"domain", "code"}, set(), name)
    require(type(record["domain"]) is str and record["domain"] in {"posix", "dns", "tls", "unknown"}, name + " has an unsupported domain")
    integer(record["code"], -(2**63), 2**63 - 1, name + ".code")
    require(record["domain"] != "unknown" or record["code"] == 0, name + " has an inconsistent unknown error")
    return {"domain": record["domain"], "code": record["code"]}


def inspect_attempt(value: object, expected_address: str, index: int) -> dict:
    name = "report.attempts[" + str(index) + "]"
    attempt = exact_object(value, {
        "address", "port", "outcome", "phase", "tcpConnected", "lockdownConfirmed",
        "elapsedMilliseconds", "receivedByteCount",
    }, {"networkError", "lastWaitingError", "protocolError", "lockdownType"}, name)
    require(attempt["address"] == expected_address, name + " differs from the fixed endpoint order")
    require(type(attempt["port"]) is int and attempt["port"] == 62078, name + " is not the fixed port")
    outcome, phase = attempt["outcome"], attempt["phase"]
    require(type(outcome) is str and outcome in OUTCOMES, name + " has an unknown outcome")
    require(type(phase) is str and phase in PHASES, name + " has an unknown phase")
    connected = boolean(attempt["tcpConnected"], name + ".tcpConnected")
    confirmed = boolean(attempt["lockdownConfirmed"], name + ".lockdownConfirmed")
    elapsed = attempt["elapsedMilliseconds"]
    try:
        finite_elapsed = type(elapsed) in {int, float} and math.isfinite(elapsed) and elapsed >= 0
    except OverflowError:
        finite_elapsed = False
    require(finite_elapsed, name + " has invalid elapsed time")
    # Source counts the four-byte prefix plus at most one 16 KiB payload.
    received = integer(attempt["receivedByteCount"], 0, MAX_PAYLOAD_BYTES + 4, name + ".receivedByteCount")
    error = network_error(attempt.get("networkError"), name + ".networkError")
    waiting = network_error(attempt.get("lastWaitingError"), name + ".lastWaitingError")
    protocol = attempt.get("protocolError")
    service = attempt.get("lockdownType")
    require(confirmed == (outcome == "lockdownConfirmed"), name + " has inconsistent service confirmation")
    require((phase == "completed") == confirmed, name + " has an inconsistent completed phase")
    require(service == (LOCKDOWN_TYPE if confirmed else None), name + " exports an unexpected service type")
    require((error is not None) == (outcome == "transportFailed"), name + " has inconsistent final network evidence")
    if outcome == "protocolError":
        require(type(protocol) is str and protocol in PROTOCOL_ERRORS, name + " has an unnormalized protocol error")
    else:
        require(protocol is None, name + " has an unexpected protocol error")
    if not connected:
        require(phase == "connecting" and received == 0, name + " claims traffic before TCP connection")
        require(outcome in {"transportFailed", "timedOut", "cancelled"}, name + " claims a response without TCP")
    else:
        require(phase != "connecting", name + " has an inconsistent connected phase")
    if outcome in {"lockdownConfirmed", "protocolError", "unexpectedService"}:
        require(connected and received >= 5, name + " lacks framed service-response evidence")
        require(phase == ("completed" if confirmed else "receivingPayload"), name + " has an inconsistent service-response phase")
    if phase == "sendingQuery":
        require(received == 0, name + " claims received bytes before the receive phase")
    if phase == "receivingHeader":
        require(received <= 4, name + " exceeds the fixed header size")
    if phase == "receivingPayload":
        require(received >= 4, name + " lacks a complete frame header")
    return {
        "endpoint": "127.0.0.1:62078" if expected_address == "127.0.0.1" else "[::1]:62078",
        "reportedOutcome": outcome,
        "reportedPhase": phase,
        "tcpConnectionReported": connected,
        "queryTypeServiceConfirmedInReport": confirmed,
        "reportedElapsedMilliseconds": elapsed,
        "reportedReceivedByteCount": received,
        "normalizedNetworkError": error,
        "normalizedLastWaitingError": waiting,
        "normalizedProtocolError": protocol,
    }


def inspect_envelope(value: object) -> dict:
    envelope = exact_object(value, {
        "report", "appBuild", "sourceCommit", "operatingSystem", "computerPoweredOff",
        "companionAppsAbsent", "dynamicRemotePairingDiscoveryAttempted", "interpretation",
    }, {"appVersion"}, "envelope")
    build = envelope["appBuild"]
    require(type(build) is str and build in KNOWN_BUILDS, "appBuild must be known build 10 or 11")
    require(envelope["sourceCommit"] == KNOWN_BUILDS[build], "appBuild/sourceCommit provenance mismatch")
    if envelope.get("appVersion") is not None:
        bounded_string(envelope["appVersion"], 128, "appVersion")
    bounded_string(envelope["operatingSystem"], 512, "operatingSystem")
    require(envelope["computerPoweredOff"] == "notMeasured", "computerPoweredOff must remain notMeasured")
    require(envelope["companionAppsAbsent"] == "notMeasured", "companionAppsAbsent must remain notMeasured")
    require(envelope["dynamicRemotePairingDiscoveryAttempted"] is False, "dynamic discovery must remain false")
    require(envelope["interpretation"] == INTERPRETATION, "export interpretation differs from the fixed read-only scope")
    report = exact_object(envelope["report"], {
        "schemaVersion", "startedAt", "finishedAt", "executionEnvironment", "attempts", "cancelled",
        *REPORT_FALSE_FLAGS,
    }, set(), "report")
    require(type(report["schemaVersion"]) is int and report["schemaVersion"] == 1, "unsupported report schemaVersion")
    require(report["executionEnvironment"] == "device", "report must declare the Swift device environment, not Simulator")
    started = iso_date(report["startedAt"], "report.startedAt")
    finished = iso_date(report["finishedAt"], "report.finishedAt")
    require(finished >= started, "report finish precedes its start")
    cancelled = boolean(report["cancelled"], "report.cancelled")
    for flag in REPORT_FALSE_FLAGS:
        require(report[flag] is False, "report." + flag + " must remain false")
    attempts = report["attempts"]
    require(type(attempts) is list and len(attempts) == 2, "report must contain exactly two fixed-endpoint attempts")
    normalized = [inspect_attempt(attempt, address, index) for index, (attempt, address) in enumerate(zip(attempts, ("127.0.0.1", "::1")))]
    require(cancelled or all(attempt["outcome"] != "cancelled" for attempt in attempts), "report cancellation flag contradicts an attempt")
    return {
        "schemaVersion": 1,
        "status": "read-only-report-contract-checked",
        "declaredExecutionPlatform": "ios-device",
        "deviceAuthenticityAttested": False,
        "declaredAppBuild": build,
        "declaredSourceCommit": KNOWN_BUILDS[build],
        "knownBuildSourcePairMatches": True,
        "reportedCancelled": cancelled,
        "configuredTimeoutSecondsPerEndpoint": QUERY_TIMEOUT_SECONDS,
        "deadlineSchedulingAccuracyEstablished": False,
        "maximumResponsePayloadBytes": MAX_PAYLOAD_BYTES,
        "endpointFactsFromReport": normalized,
        "computerPoweredOff": "notMeasured",
        "companionAppsAbsent": "notMeasured",
        "dynamicRemotePairingDiscoveryAttempted": False,
        **{flag: False for flag in REPORT_FALSE_FLAGS},
        "automaticSelfRenewalImplemented": False,
        "automaticSelfRenewalVerified": False,
        "unattendedRenewalVerified": False,
        "allTransportFeasibility": "notDetermined",
        "otherTransportsExcluded": False,
        "interpretation": INTERPRETATION,
        "evidenceLimit": "These are declarations in one user-selected JSON file; no device attestation or renewal operation is established.",
    }


def reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        require(key not in result, "JSON contains a duplicate object key")
        result[key] = value
    return result


def reject_nonfinite(_: str) -> None:
    raise InvalidReport("JSON contains a non-finite numeric constant")


def inspect_file(path: Path) -> dict:
    # The only input read is this caller-provided path. No directory enumeration.
    with path.open("rb") as handle:
        payload = handle.read(MAX_INPUT_BYTES + 1)
    require(len(payload) <= MAX_INPUT_BYTES, "report exceeds the inspector 64 KiB resource limit")
    try:
        value = json.loads(payload.decode("utf-8"), object_pairs_hook=reject_duplicate_keys, parse_constant=reject_nonfinite)
    except (UnicodeError, json.JSONDecodeError, RecursionError):
        raise InvalidReport("report is not valid bounded UTF-8 JSON") from None
    return {**inspect_envelope(value), "inputByteCount": len(payload), "inputSHA256": hashlib.sha256(payload).hexdigest()}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path, help="Exact JSON path explicitly selected by the user; no automatic discovery")
    args = parser.parse_args()
    try:
        result = inspect_file(args.report)
    except (OSError, InvalidReport, OverflowError, RecursionError) as error:
        message = str(error) if isinstance(error, InvalidReport) else "The explicitly selected report could not be read or validated"
        print(json.dumps({"status": "rejected", "reason": message, "automaticSelfRenewalVerified": False}), file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=True, indent=2, allow_nan=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
