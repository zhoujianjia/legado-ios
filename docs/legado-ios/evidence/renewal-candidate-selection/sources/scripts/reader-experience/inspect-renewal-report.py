#!/usr/bin/env python3
"""Check one explicitly named diagnostic export; never discover user files.

Schema 1 retains the frozen build 10/11 contract. Schema 2 is source independent:
--manifest binds its declarations, while --manifest-sha256 must come from an
independent delivery audit to establish that binding's provenance. JSON and an
external digest do not attest a physical device, a signed installation or renewal.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import sys

HERE = Path(__file__).resolve().parent
LEGACY_SHA256 = "fcc1d82ec99af4ce4a576cce9e2992f0099b7da0f3c7f8933dd018178890bd8b"
legacy_path = HERE / "renewal-report-schema1.py"
if hashlib.sha256(legacy_path.read_bytes()).hexdigest() != LEGACY_SHA256:
    raise RuntimeError("Frozen schema-one contract changed")
spec = importlib.util.spec_from_file_location("frozen_schema_one", legacy_path)
legacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(legacy)
InvalidReport = legacy.InvalidReport
require = legacy.require
exact_object = legacy.exact_object
integer = legacy.integer
boolean = legacy.boolean
network_error = legacy.network_error
MAX_INPUT_BYTES = 64 * 1024
FALSE_FLAGS = legacy.REPORT_FALSE_FLAGS
INTERPRETATION = (
    "Opt-in dynamic remote-pairing discovery, same-device address ownership checks, and TCP connection only. "
    "DNS-SD queries may be sent; no application frames are sent on TCP. Device service identity, "
    "automatic renewal, and installation remain unverified."
)
SELECTION_INTERPRETATION = INTERPRETATION + (
    " At most four selected endpoints may be attempted; unselected candidates remain untested."
)
OUTCOMES = {
    "tcpConnected", "noLocalCandidate", "discoveryTimedOut", "discoveryUnavailable", "resolutionFailed",
    "transportFailed", "timedOut", "cancelled", "interfaceChanged", "discoveryChanged", "limitExceeded", "internalError",
}
PHASES = {"snapshotting", "discovering", "resolving", "checkingOwnership", "connecting", "completed"}
TCP_OUTCOMES = {"tcpConnected", "transportFailed", "timedOut", "cancelled", "internalError"}
SELECTION_FIELDS = {"eligibleEndpointCount", "skippedEndpointCount", "endpointSelectionLimit"}


def elapsed(value, name):
    try:
        valid = type(value) in {int, float} and math.isfinite(value) and value >= 0
    except OverflowError:
        valid = False
    require(valid, name + " must be finite and nonnegative")
    return value


def choice(value, choices, name):
    require(type(value) is str and value in choices, name + " has an unsupported value")
    return value


def finite_json_float(text):
    value = float(text)
    require(math.isfinite(value), "JSON contains a non-finite numeric value")
    return value


def read_bounded_json(path):
    with path.open("rb") as handle:
        data = handle.read(MAX_INPUT_BYTES + 1)
    require(len(data) <= MAX_INPUT_BYTES, "input exceeds the 64 KiB inspector limit")
    try:
        value = json.loads(data.decode("utf-8"), object_pairs_hook=legacy.reject_duplicate_keys,
                           parse_constant=legacy.reject_nonfinite, parse_float=finite_json_float)
    except (UnicodeError, ValueError, RecursionError) as error:
        if isinstance(error, InvalidReport):
            raise
        raise InvalidReport("input is not valid bounded UTF-8 JSON") from None
    return value, data


def inspect_tcp(value, index):
    name = "discovery.tcpAttempts[" + str(index) + "]"
    attempt = exact_object(value, {"family", "addressCategory", "outcome", "elapsedMilliseconds"},
                           {"networkError", "lastWaitingError"}, name)
    family = choice(attempt["family"], {"ipv4", "ipv6"}, name + ".family")
    category = choice(attempt["addressCategory"], {"loopback", "localInterface"}, name + ".addressCategory")
    outcome = choice(attempt["outcome"], TCP_OUTCOMES, name + ".outcome")
    duration = elapsed(attempt["elapsedMilliseconds"], name + ".elapsedMilliseconds")
    error = network_error(attempt.get("networkError"), name + ".networkError")
    waiting = network_error(attempt.get("lastWaitingError"), name + ".lastWaitingError")
    require((error is not None) == (outcome == "transportFailed"), name + " has inconsistent terminal network evidence")
    require(outcome != "internalError" or waiting is None, name + " claims waiting before adapter initialization")
    return {"family": family, "addressCategory": category, "outcome": outcome,
            "elapsedMilliseconds": duration, "networkError": error, "lastWaitingError": waiting}


def inspect_discovery(value):
    record = exact_object(value, {
        "discoveryStarted", "outcome", "phase", "elapsedMilliseconds", "discoveredServiceCount",
        "resolvedAddressCount", "rejectedAddressCount", "approvedEndpointCount",
        "tcpConnectionAttemptsStarted", "tcpAttempts", "tcpApplicationPayloadBytesSent", "serviceIdentityVerified",
    }, {"networkError", "lastWaitingError", *SELECTION_FIELDS}, "discovery")
    started = boolean(record["discoveryStarted"], "discovery.discoveryStarted")
    outcome = choice(record["outcome"], OUTCOMES, "discovery.outcome")
    phase = choice(record["phase"], PHASES, "discovery.phase")
    duration = elapsed(record["elapsedMilliseconds"], "discovery.elapsedMilliseconds")
    services = integer(record["discoveredServiceCount"], 0, 9, "discovery.discoveredServiceCount")
    resolved = integer(record["resolvedAddressCount"], 0, 33, "discovery.resolvedAddressCount")
    rejected = integer(record["rejectedAddressCount"], 0, min(resolved, 32), "discovery.rejectedAddressCount")
    approved = integer(record["approvedEndpointCount"], 0, 4, "discovery.approvedEndpointCount")
    attempts_started = integer(record["tcpConnectionAttemptsStarted"], 0, approved, "discovery.tcpConnectionAttemptsStarted")
    selection = {}
    present_selection = SELECTION_FIELDS.intersection(record)
    if present_selection:
        require(present_selection == SELECTION_FIELDS, "selection counts must be present together")
        require(phase in {"checkingOwnership", "connecting", "completed"}
                and outcome not in {"limitExceeded", "discoveryChanged"},
                "selection counts require a normally closed discovery window")
        eligible = integer(record["eligibleEndpointCount"], 0, min(32, resolved), "discovery.eligibleEndpointCount")
        skipped = integer(record["skippedEndpointCount"], 0, 32, "discovery.skippedEndpointCount")
        limit = integer(record["endpointSelectionLimit"], 4, 4, "discovery.endpointSelectionLimit")
        require(approved == min(eligible, limit), "approved endpoints differ from the bounded selection")
        require(skipped == eligible - approved, "skipped endpoints differ from the selection remainder")
        if phase == "checkingOwnership" and outcome in {"internalError", "cancelled", "timedOut"}:
            require(approved > 0, "post-selection ownership interruption requires a selected endpoint")
        selection = {"eligibleEndpointCount": eligible, "skippedEndpointCount": skipped,
                     "endpointSelectionLimit": limit}
    require(type(record["tcpApplicationPayloadBytesSent"]) is int and record["tcpApplicationPayloadBytesSent"] == 0,
            "TCP application payload count must remain integer zero")
    require(record["serviceIdentityVerified"] is False, "service identity must remain unverified")
    values = record["tcpAttempts"]
    require(type(values) is list and len(values) <= 4, "discovery TCP attempts must be a bounded array")
    attempts = [inspect_tcp(attempt, index) for index, attempt in enumerate(values)]
    completed = len(attempts)
    pending = attempts_started - completed
    require(pending in {0, 1}, "started and completed TCP attempt counts are inconsistent")
    error = network_error(record.get("networkError"), "discovery.networkError")
    waiting = network_error(record.get("lastWaitingError"), "discovery.lastWaitingError")

    require(started == (phase != "snapshotting"), "discoveryStarted contradicts the phase")
    require(resolved == 0 or services > 0, "resolved addresses require a discovered service")
    require(approved <= resolved, "approved endpoints exceed resolved observations")
    require(phase != "discovering" or services == 0, "a discovered service moves the operation to resolution")
    require(phase != "resolving" or services > 0, "resolution phase requires a discovered service")
    if phase in {"snapshotting", "discovering", "resolving"}:
        require(approved == 0 and attempts_started == 0, "TCP cannot precede the closed discovery window")
    if not started:
        require(services == resolved == rejected == approved == attempts_started == completed == 0,
                "a probe that never started discovery cannot contain observations")
        require(error is None and waiting is None, "a probe before discovery cannot contain network errors")
    if services == 9 or resolved == 33:
        require(outcome == "limitExceeded" and phase == "resolving", "overflow counters require a resolution limit outcome")
        require(not (services == 9 and resolved == 33), "both overflow guards cannot be crossed in one run")
    if pending:
        require(phase == "connecting" and outcome in {"cancelled", "timedOut"},
                "one uncompleted TCP attempt is possible only during cancellation or the overall deadline")
    if phase == "connecting":
        require(attempts_started > 0, "connecting phase requires a started TCP attempt")
    if phase == "checkingOwnership" and approved > 0:
        require(attempts_started < approved, "ownership selection requires a remaining endpoint")
    families = [attempt["family"] for attempt in attempts]
    require(families == sorted(families), "TCP attempts violate the stable IPv4-before-IPv6 order")
    for index, attempt in enumerate(attempts):
        if attempt["outcome"] in {"tcpConnected", "cancelled"}:
            require(index == completed - 1 and pending == 0 and outcome == attempt["outcome"],
                    "a terminal TCP success or cancellation must finish the overall operation")

    allowed_phases = {
        "tcpConnected": {"completed"},
        "noLocalCandidate": {"checkingOwnership"},
        "discoveryTimedOut": {"checkingOwnership"},
        "discoveryUnavailable": {"discovering", "resolving", "checkingOwnership"},
        "resolutionFailed": {"checkingOwnership"},
        "transportFailed": {"connecting", "checkingOwnership"},
        "timedOut": PHASES - {"completed"},
        "cancelled": PHASES - {"completed"},
        "interfaceChanged": {"checkingOwnership"},
        "discoveryChanged": {"discovering", "resolving"},
        "limitExceeded": {"discovering", "resolving", "checkingOwnership"},
        "internalError": {"snapshotting", "checkingOwnership"},
    }
    require(phase in allowed_phases[outcome], "discovery outcome contradicts its terminal phase")
    require((phase == "completed") == (outcome == "tcpConnected"), "completed phase requires TCP readiness")
    if outcome == "tcpConnected":
        require(completed > 0 and attempts[-1]["outcome"] == "tcpConnected", "TCP readiness lacks a completed TCP attempt")
    elif outcome == "transportFailed":
        require(completed > 0 and pending == 0, "transport failure requires completed unsuccessful TCP attempts")
    elif outcome == "noLocalCandidate":
        require(resolved > 0 and attempts_started == 0, "no-local-candidate outcome has inconsistent observation counts")
        require(approved > 0 or error is None, "empty candidates with a resolution error must retain that distinct outcome")
    elif outcome == "resolutionFailed":
        require(error is not None and services > 0 and approved == attempts_started == 0,
                "resolution failure must retain its error without approved TCP endpoints")
    elif outcome == "discoveryTimedOut":
        require(resolved == approved == attempts_started == 0 and error is None and waiting is None,
                "an empty completed discovery window must not invent an error cause")
    elif outcome == "interfaceChanged":
        require(approved > 0 and pending == 0 and attempts_started < approved, "interface change must occur before the next connection")
    elif outcome in {"limitExceeded", "discoveryChanged"}:
        require(approved == attempts_started == 0, "a discovery limit/change cannot follow an approved connection")
        if outcome == "limitExceeded" and phase == "checkingOwnership":
            require(resolved >= 5, "an endpoint budget overflow requires at least five resolved observations")
    if outcome == "discoveryUnavailable" and phase == "checkingOwnership":
        require(waiting is not None and error is None and resolved == approved == attempts_started == 0,
                "post-window discovery unavailability must retain waiting separately from resolution failure")
    if outcome == "timedOut" and phase == "connecting":
        require(pending == 1, "the overall connection deadline must retain its in-flight attempt")
    if outcome == "cancelled" and phase == "connecting" and pending == 0:
        require(completed > 0 and attempts[-1]["outcome"] == "cancelled", "completed TCP cancellation must retain its terminal attempt")
    if any(attempt["outcome"] == "cancelled" for attempt in attempts):
        require(phase == "connecting", "TCP cancellation cannot resume ownership selection")
    return {"discoveryStarted": started, "outcome": outcome, "phase": phase, "elapsedMilliseconds": duration,
            "discoveredServiceCount": services, "resolvedAddressCount": resolved, "rejectedAddressCount": rejected,
            "approvedEndpointCount": approved, "tcpConnectionAttemptsStarted": attempts_started, "tcpAttempts": attempts,
            "networkError": error, "lastWaitingError": waiting,
            "tcpApplicationPayloadBytesSent": 0, "serviceIdentityVerified": False, **selection}


def inspect_schema_two(value):
    envelope = exact_object(value, {"schemaVersion", "report", "operatingSystem", "computerPoweredOff",
        "companionAppsAbsent", "dynamicRemotePairingDiscoveryAttempted", "interpretation"},
        {"appVersion", "appBuild", "sourceCommit"}, "envelope")
    require(type(envelope["schemaVersion"]) is int and envelope["schemaVersion"] == 2, "unsupported envelope schemaVersion")
    if "appBuild" in envelope:
        require(type(envelope["appBuild"]) is str and re.fullmatch(r"[1-9][0-9]{0,9}", envelope["appBuild"]) is not None,
                "appBuild must be a canonical bounded build string")
    if "sourceCommit" in envelope:
        require(type(envelope["sourceCommit"]) is str and re.fullmatch(r"[0-9a-f]{40}", envelope["sourceCommit"]) is not None,
                "sourceCommit must be a full lowercase Git SHA")
    if "appVersion" in envelope:
        legacy.bounded_string(envelope["appVersion"], 128, "appVersion")
    legacy.bounded_string(envelope["operatingSystem"], 512, "operatingSystem")
    for name in ("computerPoweredOff", "companionAppsAbsent"):
        require(envelope[name] == "notMeasured", name + " must remain notMeasured")
    require(type(envelope["interpretation"]) is str
            and envelope["interpretation"] in {INTERPRETATION, SELECTION_INTERPRETATION},
            "interpretation differs from the dynamic TCP-only scope")
    report = exact_object(envelope["report"], {"schemaVersion", "startedAt", "finishedAt", "executionEnvironment",
        "attempts", "cancelled", "remotePairingDiscovery", *FALSE_FLAGS}, set(), "report")
    require(type(report["schemaVersion"]) is int and report["schemaVersion"] == 2, "unsupported report schemaVersion")
    require(report["executionEnvironment"] == "device", "report must declare the device export environment")
    require(legacy.iso_date(report["finishedAt"], "report.finishedAt") >= legacy.iso_date(report["startedAt"], "report.startedAt"),
            "report finish precedes its start")
    for flag in FALSE_FLAGS:
        require(report[flag] is False, "report." + flag + " must remain false")
    require(type(report["attempts"]) is list and len(report["attempts"]) == 0, "dynamic reports must contain no fixed-port attempts")
    discovery = inspect_discovery(report["remotePairingDiscovery"])
    require(boolean(report["cancelled"], "report.cancelled") == (discovery["outcome"] == "cancelled"),
            "report cancellation flag contradicts the discovery outcome")
    require(boolean(envelope["dynamicRemotePairingDiscoveryAttempted"], "dynamicRemotePairingDiscoveryAttempted") == discovery["discoveryStarted"],
            "dynamic discovery metadata contradicts the actual start flag")
    return {"schemaVersion": 2, "declaredExecutionPlatform": "ios-device", "declaredAppBuild": envelope.get("appBuild"),
            "declaredSourceCommit": envelope.get("sourceCommit"), "knownBuildSourcePairMatches": False,
            "reportedCancelled": report["cancelled"], "discoveryFactsFromReport": discovery,
            "dynamicRemotePairingDiscoveryAttempted": discovery["discoveryStarted"],
            "computerPoweredOff": "notMeasured", "companionAppsAbsent": "notMeasured",
            **{flag: False for flag in FALSE_FLAGS}, "interpretation": envelope["interpretation"]}


def manifest_binding(envelope, manifest_path=None, expected_digest=None):
    require(expected_digest is None or (type(expected_digest) is str and re.fullmatch(r"[0-9a-f]{64}", expected_digest) is not None),
            "expected manifest digest must be lowercase SHA256")
    require(manifest_path is not None or expected_digest is None, "manifest digest requires an explicit manifest path")
    result = {"provenanceEstablished": False, "manifestBindingStatus": "notSupplied", "manifestSHA256": None,
              "manifestDigestMatched": False, "manifestBuildSourcePairMatched": False}
    if manifest_path is None:
        return result
    try:
        manifest, raw = read_bounded_json(manifest_path)
        require(type(manifest) is dict and type(manifest.get("schemaVersion")) is int and manifest["schemaVersion"] == 1,
                "unsupported manifest schema")
        for key, expected in {"configuration": "Release", "platform": "iPhoneOS", "architecture": "arm64",
                              "bundleIdentifier": "local.zhoujianjia.legado-reader"}.items():
            require(manifest.get(key) == expected, "manifest is not the intended device reader")
        require(manifest.get("signed") is False, "manifest is not the unsigned delivery manifest")
        require(type(manifest.get("build")) is str and re.fullmatch(r"[1-9][0-9]{0,9}", manifest["build"]) is not None, "invalid manifest build")
        require(type(manifest.get("sourceCommit")) is str and re.fullmatch(r"[0-9a-f]{40}", manifest["sourceCommit"]) is not None, "invalid manifest source")
        require(type(manifest.get("ipaSHA256")) is str and re.fullmatch(r"[0-9a-f]{64}", manifest["ipaSHA256"]) is not None, "invalid manifest IPA digest")
        integer(manifest.get("ipaBytes"), 1, 2**40, "manifest.ipaBytes")
        legacy.bounded_string(manifest.get("version"), 128, "manifest.version")
    except (OSError, InvalidReport, OverflowError, RecursionError):
        result["manifestBindingStatus"] = "unverifiable"
        return result
    result["manifestSHA256"] = hashlib.sha256(raw).hexdigest()
    if expected_digest is not None and expected_digest != result["manifestSHA256"]:
        result["manifestBindingStatus"] = "digestMismatch"
        return result
    if envelope.get("appBuild") is None or envelope.get("sourceCommit") is None:
        result["manifestBindingStatus"] = "reportProvenanceMissing"
        return result
    require(envelope["appBuild"] == manifest["build"] and envelope["sourceCommit"] == manifest["sourceCommit"],
            "report build/source does not match the selected manifest")
    require(envelope.get("appVersion") is None or envelope["appVersion"] == manifest["version"],
            "report version does not match the selected manifest")
    result["manifestBuildSourcePairMatched"] = True
    result["manifestDigestMatched"] = expected_digest is not None
    result["provenanceEstablished"] = expected_digest is not None
    result["manifestBindingStatus"] = "verifiedDigestAndPairMatched" if expected_digest else "pairMatchedWithoutIndependentDigest"
    return result


def inspect_envelope(value, manifest_path=None, manifest_sha256=None):
    require(type(value) is dict and type(value.get("report")) is dict, "envelope must contain a report object")
    schema = value["report"].get("schemaVersion")
    require(type(schema) is int and schema in {1, 2}, "unsupported report schemaVersion")
    facts = legacy.inspect_envelope(value) if schema == 1 else inspect_schema_two(value)
    binding = manifest_binding(value, manifest_path, manifest_sha256)
    return {**facts, **binding, "status": "manifest-bound-contract-checked" if binding["provenanceEstablished"] else "schema-only-contract-checked",
            "deviceAuthenticityAttested": False, "manifestDeliveryOrDeviceInstallationAttested": False,
            "automaticSelfRenewalImplemented": False, "automaticSelfRenewalVerified": False,
            "unattendedRenewalVerified": False, "allTransportFeasibility": "notDetermined", "otherTransportsExcluded": False,
            "deadlineSchedulingAccuracyEstablished": False,
            "provenanceMeaning": "Build/source declarations match the exact manifest digest supplied from an independent audit; no device or delivery attestation is created.",
            "evidenceLimit": "Only declarations in an explicitly selected JSON file were checked. Waiting, no discovery result and TCP readiness establish neither permission cause, VPN state, computer independence, authenticated service nor renewal."}


def inspect_file(path, manifest_path=None, manifest_sha256=None):
    value, raw = read_bounded_json(path)
    return {**inspect_envelope(value, manifest_path, manifest_sha256), "inputByteCount": len(raw),
            "inputSHA256": hashlib.sha256(raw).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--manifest", type=Path, help="Exact delivery manifest path; no automatic file discovery")
    parser.add_argument("--manifest-sha256", help="Expected lowercase digest from the independent delivery audit, not from the report")
    args = parser.parse_args()
    try:
        result = inspect_file(args.report, args.manifest, args.manifest_sha256)
    except (OSError, InvalidReport, OverflowError, RecursionError):
        print(json.dumps({"status": "rejected", "reason": "The explicitly selected report or binding does not satisfy the diagnostic contract",
                          "provenanceEstablished": False, "automaticSelfRenewalVerified": False}), file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=True, indent=2, allow_nan=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
