#!/usr/bin/env python3
"""Compare selected public original getters with separately collected Swift logs.

Fixture validation is not Swift execution. The observer deliberately has no
parity assertion, KnownIssue or skip: only this separate report compares values.
This helper is not connected to the existing zero-failure CI acceptance groups.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys

REPO = Path(__file__).resolve().parents[2]
MARKER = "SOURCE_RULE_DEFAULTS_SWIFT "
MODELS = {"SearchRule": ("checkKeyWord", "getCheckKeyWord"), "ExploreRule": ("bookList", "getBookList"),
          "BookInfoRule": ("init", "getInit"), "TocRule": ("chapterList", "getChapterList"),
          "ContentRule": ("callBackJs", "getCallBackJs")}
FORMS = ("absent", "null", "empty", "whitespace", "boolean", "number-exponent", "object", "array")
ROUTES = ("direct-rule", *(shape + ":" + kind for shape in ("single", "array", "envelope")
                          for kind in ("object-rule", "string-rule")))
FROZEN = {"rule-defaults-original-cases.json": "78cb973cc7fb97a8bdb32ff13c202c31e1d6c0966c31428c4faf101c01dc1f44",
          "rule-defaults-original-results.jsonl": "467bbfe63a14a0f99acfb8e90a40391fdd43077cee5a67b09de52d0e162c931f",
          "rule-defaults-original-probe.kt": "f0f01a42b4fc70e4e1972e2516eb8a9d509bf437fa06b96c41d63698718524d1",
          "rule-defaults-original-provenance.json": "a37cc35b48e234dbea0a48bd39d7980df4cb9b0684ba3b5d7a671bdbf65cbf0e"}
UNKNOWN = "Tests/iOS/yuedu appTests/Fixtures/RuleDefaultsReference/unknown-field-cases.jsonl"


class RawNumber(str):
    """A JSON number lexeme, never parsed through a binary float."""


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def strict_json(text, *, numbers=False):
    def pairs(entries):
        value = {}
        for key, item in entries:
            require(key not in value, "Duplicate JSON key: " + key)
            value[key] = item
        return value
    def constant(value):
        raise ValueError("Non-JSON constant: " + value)
    options = {"object_pairs_hook": pairs, "parse_constant": constant}
    if numbers:
        options.update(parse_int=RawNumber, parse_float=RawNumber)
    return json.loads(text, **options)


def tagged(value):
    if isinstance(value, RawNumber): return {"kind": "number", "rawToken": str(value)}
    if value is None: return {"kind": "null"}
    if type(value) is bool: return {"kind": "boolean", "value": value}
    if type(value) is str: return {"kind": "string", "value": value}
    if type(value) is list: return {"kind": "array", "values": [tagged(item) for item in value]}
    if type(value) is dict: return {"kind": "object", "values": {key: tagged(item) for key, item in sorted(value.items())}}
    raise ValueError("Unexpected parsed JSON value type")


def projection(container, key):
    require(type(container) is dict, "Expected an encoded JSON object")
    return {"kind": "absent"} if key not in container else tagged(container[key])


def load_references(repo=REPO):
    directory = repo / "docs/legado-ios/fixtures"
    evidence = []
    for name, expected in FROZEN.items():
        data = (directory / name).read_bytes()
        require(sha(data) == expected, "Frozen original evidence changed: " + name)
        evidence.append({"path": str((directory / name).relative_to(repo)), "bytes": len(data), "sha256": expected})
    cases = strict_json((directory / "rule-defaults-original-cases.json").read_text(encoding="utf-8"), numbers=True)
    rows = [strict_json(line) for line in (directory / "rule-defaults-original-results.jsonl").read_text(encoding="utf-8").splitlines()]
    require(type(cases) is list and len(cases) == len(rows) == 40, "The original reference must contain exactly forty cases")
    expected_ids = {model + "/" + form for model in MODELS for form in FORMS}
    indexed = {}
    inputs = {}
    for item in cases:
        identity = item["model"] + "/" + item["form"]
        require(identity not in inputs, "Duplicate original input identity")
        inputs[identity] = item
    for row in rows:
        identity = row["model"] + "/" + row["form"]
        require(identity in expected_ids and identity not in indexed, "Unexpected or duplicate original observation")
        require((row["field"], row["getter"]) == MODELS[row["model"]], "Original getter/field mapping changed")
        require(type(row["inputHasField"]) is bool and row["inputHasField"] == (row["form"] != "absent"), "Original key presence differs")
        require(row["getterReturnType"] == "java.lang.String", "Original getter is not nullable String")
        require(row["getterValue"] is None or type(row["getterValue"]) is str, "Original getter has an unexpected type")
        raw = inputs[identity]["rule"]
        if row["inputHasField"]:
            require(tagged(raw[row["field"]]) == tagged(strict_json(row["inputValueJSON"], numbers=True)), "Raw wire token differs from original case")
        else:
            require(row["field"] not in raw and row["inputValueJSON"] == "<absent>", "Absent wire form changed")
        getter = row["getterValue"]
        expected = {"kind": "absent"} if getter is None else tagged(getter)
        require(projection(row["defaultGson"], row["field"]) == expected, "Default Gson must omit nullable null, without erasing empty text")
        require(projection(row["serializeNullsGson"], row["field"]) == tagged(getter), "serializeNulls is a distinct explicit diagnostic")
        if row["form"] == "number-exponent":
            require(row["inputValueJSON"] == getter == "1e3", "Original exponent lexeme changed")
        if row["form"] in ("object", "array"):
            require(getter == row["inputValueJSON"], "Original container-to-String conversion changed")
        if row["form"] == "whitespace": require(getter.encode() == " \t\r\n\u2003 ".encode(), "Original whitespace changed")
        if row["form"] == "empty": require(getter == "", "Empty text became missing")
        indexed[identity] = row
    require(set(inputs) == set(indexed) == expected_ids, "Original model/form coverage differs")
    return indexed, evidence


def load_unknown(repo=REPO):
    data = (repo / UNKNOWN).read_bytes()
    rows = [strict_json(line) for line in data.decode("utf-8").splitlines()]
    require(len(rows) == 13 and len({row["identity"] for row in rows}) == 13, "Unknown-field fixture matrix differs")
    indexed = {}
    for row in rows:
        source = strict_json(row["sourceJSON"], numbers=True)
        expected = tagged(strict_json(row["expectedValueJSON"], numbers=True))
        container = source if row["containerKey"] is None else source[row["containerKey"]]
        if type(container) is str: container = strict_json(container, numbers=True)
        require(projection(container, row["unknownKey"]) == expected, "Unknown-field source fixture does not contain its declared value")
        require(expected["values"]["number"] == {"kind": "number", "rawToken": "1e3"}, "Unknown number token changed")
        indexed[row["identity"]] = row
    return indexed, {"path": UNKNOWN, "bytes": len(data), "sha256": sha(data)}


def parse_observations(log):
    require(len(log.encode("utf-8")) <= 64 * 1024**2, "Observation log exceeds bounded size")
    observations = []
    for line in log.splitlines():
        if MARKER not in line: continue
        require(line.count(MARKER) == 1, "Ambiguous observation marker")
        raw = line.split(MARKER, 1)[1]
        require(len(raw.encode("utf-8")) <= 256 * 1024, "Observation row exceeds bounded size")
        observations.append(strict_json(raw))
    return observations


def compare_observations(reference, unknown, observations):
    expected = {("originalRule", identity, route) for identity in reference for route in ROUTES}
    expected.update(("unknownField", identity, route) for identity in unknown for route in ("single", "array", "envelope"))
    found, differences = set(), []
    reference_snapshots = unknown_snapshots = 0
    for row in observations:
        require(type(row) is dict and set(row) == {"kind", "identity", "route", "snapshots"}, "Unexpected observation envelope")
        key = (row["kind"], row["identity"], row["route"])
        require(key in expected and key not in found, "Unexpected or duplicate observation identity/route")
        found.add(key)
        stages = ["decoded-rule"] if row["route"] == "direct-rule" else ["imported", "edited", "export-reloaded"]
        if row["kind"] == "unknownField": stages.append("stored-reloaded")
        snapshots = row["snapshots"]
        require(type(snapshots) is list and [item.get("stage") for item in snapshots if type(item) is dict] == stages,
                "Missing, reordered or malformed observation stages")
        for item in snapshots:
            require(type(item) is dict and set(item) == {"stage", "getterValue", "encodedJSON"}, "Unexpected observation snapshot")
            require(item["getterValue"] is None or type(item["getterValue"]) is str, "Swift getter must be nullable String")
            require(type(item["encodedJSON"]) is str, "Encoded model JSON must remain raw text")
            encoded = strict_json(item["encodedJSON"], numbers=True)
            require(type(encoded) is dict, "Encoded snapshot must be an object")
            if row["kind"] == "originalRule":
                original = reference[row["identity"]]
                pairs = (("getterValue", tagged(original["getterValue"]), tagged(item["getterValue"])),
                         ("defaultGsonField", projection(original["defaultGson"], original["field"]), projection(encoded, original["field"])))
                reference_snapshots += 1
            else:
                original = unknown[row["identity"]]
                container = encoded if original["containerKey"] is None else encoded.get(original["containerKey"], {})
                if type(container) is str: container = strict_json(container, numbers=True)
                pairs = (("forwardUnknownField", tagged(strict_json(original["expectedValueJSON"], numbers=True)),
                          projection(container, original["unknownKey"])),)
                unknown_snapshots += 1
            for contract, wanted, actual in pairs:
                if wanted != actual:
                    differences.append({"kind": row["kind"], "identity": row["identity"], "route": row["route"],
                                        "stage": item["stage"], "contract": contract, "expected": wanted, "actual": actual})
    require(found == expected, "Observation collection is incomplete")
    return {"observationCollectionComplete": True, "observationRows": len(found), "selectedGetterSnapshots": reference_snapshots,
            "forwardUnknownSnapshots": unknown_snapshots, "selectedContractsMatch": not differences, "differenceCount": len(differences),
            "differences": differences, "fullSourceSchemaCompatibilityEstablished": False,
            "scope": "Five selected original getters and their selected default-Gson fields; forward unknown-field cases are a separate project preservation contract. Whole-model serializers/rule execution are not accepted.",
            "serializeNullsPolicy": "Validated only as an explicit original diagnostic fixture. Never used as the app export expectation.",
            "runtimeSemantics": "Nullable/empty/whitespace representation differences are reported; callback execution eligibility and other rule execution behavior are not inferred."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=Path, help="Actual separately retained observer stdout; without it, validate fixture contracts only")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    require(not args.output.exists(), "Refusing to overwrite prior evidence")
    reference, evidence = load_references()
    unknown, unknown_evidence = load_unknown()
    result = {"schemaVersion": 1, "originalReferenceRows": len(reference), "forwardUnknownFixtures": len(unknown),
              "frozenOriginalEvidence": evidence, "forwardUnknownEvidence": unknown_evidence,
              "fixtureContractsValidated": True, "observationLogProvided": args.log is not None,
              "swiftCompilationAttested": False, "iosRuntimeExecutionAttested": False,
              "fullSourceSchemaCompatibilityEstablished": False}
    if args.log is not None:
        raw = args.log.read_bytes()
        result.update(compare_observations(reference, unknown, parse_observations(raw.decode("utf-8"))))
        result["observationLog"] = {"path": str(args.log), "bytes": len(raw), "sha256": sha(raw),
                                    "provenance": "Supplied text log only. Bind actual XCTest/source/build evidence separately; text alone does not attest execution."}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2); stream.write("\n")
    print(json.dumps({"fixtureContractsValidated": True, "observationLogProvided": args.log is not None,
                      "selectedContractsMatch": result.get("selectedContractsMatch"), "output": str(args.output)}))
    return 0 if args.log is None or result["selectedContractsMatch"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
