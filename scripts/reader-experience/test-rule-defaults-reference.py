#!/usr/bin/env python3
"""Portable comparison guards only; all observer rows here are synthetic."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("rule_reference_guard_tests", HERE / "rule-defaults-reference.py")
reference = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reference)


class RuleReferenceGuards(unittest.TestCase):
    def setUp(self):
        self.original, self.evidence = reference.load_references()
        self.unknown, _ = reference.load_unknown()

    def synthetic_observations(self):
        # Shapes only. Never emit these as a retained actual Swift log.
        result = []
        for identity, row in self.original.items():
            for route in reference.ROUTES:
                stages = ["decoded-rule"] if route == "direct-rule" else ["imported", "edited", "export-reloaded"]
                result.append({"kind": "originalRule", "identity": identity, "route": route, "snapshots": [
                    {"stage": stage, "getterValue": row["getterValue"], "encodedJSON": json.dumps(row["defaultGson"], ensure_ascii=False)}
                    for stage in stages]})
        for identity, row in self.unknown.items():
            for route in ("single", "array", "envelope"):
                result.append({"kind": "unknownField", "identity": identity, "route": route, "snapshots": [
                    {"stage": stage, "getterValue": None, "encodedJSON": row["sourceJSON"]}
                    for stage in ("imported", "edited", "export-reloaded", "stored-reloaded")]})
        return result

    def compare(self, observations):
        return reference.compare_observations(self.original, self.unknown, observations)

    def test_frozen_reference_contracts_keep_all_forty_wire_forms(self):
        self.assertEqual(len(self.original), 40)
        self.assertEqual(len(self.evidence), 4)
        self.assertEqual(len(self.unknown), 13)
        for model in reference.MODELS:
            absent = self.original[model + "/absent"]
            null = self.original[model + "/null"]
            empty = self.original[model + "/empty"]
            field = absent["field"]
            self.assertNotIn(field, absent["defaultGson"])
            self.assertNotIn(field, null["defaultGson"])
            self.assertIsNone(absent["serializeNullsGson"][field])
            self.assertEqual(empty["defaultGson"][field], "")
            self.assertEqual(self.original[model + "/number-exponent"]["getterValue"], "1e3")

    def test_complete_synthetic_shape_matches_selected_contracts_only(self):
        checked = self.compare(self.synthetic_observations())
        self.assertTrue(checked["selectedContractsMatch"])
        self.assertEqual(checked["observationRows"], 319)
        self.assertEqual(checked["selectedGetterSnapshots"], 760)
        self.assertEqual(checked["forwardUnknownSnapshots"], 156)
        self.assertFalse(checked["fullSourceSchemaCompatibilityEstablished"])

    def test_incomplete_duplicate_unrelated_or_changed_routes_are_rejected(self):
        observations = self.synthetic_observations()
        for mutate in (lambda rows: rows.pop(), lambda rows: rows.append(copy.deepcopy(rows[0])),
                       lambda rows: rows[0].update(identity="SearchRule/not-a-case"),
                       lambda rows: rows[0].update(route="some-other-import"),
                       lambda rows: rows[0].update(snapshots=[]),
                       lambda rows: rows[1]["snapshots"].reverse()):
            changed = copy.deepcopy(observations)
            mutate(changed)
            with self.subTest(mutate=mutate), self.assertRaises(ValueError): self.compare(changed)

    def test_exponent_string_rewrite_is_a_real_difference(self):
        observations = self.synthetic_observations()
        row = next(row for row in observations if row["identity"] == "ContentRule/number-exponent")
        row["snapshots"][0]["getterValue"] = "1000"
        result = self.compare(observations)
        self.assertFalse(result["selectedContractsMatch"])
        self.assertEqual(result["differenceCount"], 1)
        self.assertEqual(result["differences"][0]["contract"], "getterValue")

    def test_whitespace_and_unicode_are_compared_without_trimming_or_normalizing(self):
        observations = self.synthetic_observations()
        row = next(row for row in observations if row["identity"] == "SearchRule/whitespace")
        row["snapshots"][0]["getterValue"] = row["snapshots"][0]["getterValue"].strip()
        self.assertFalse(self.compare(observations)["selectedContractsMatch"])
        self.assertNotEqual(reference.tagged("e\u0301"), reference.tagged("\u00e9"))

    def test_default_gson_and_explicit_serialize_nulls_are_not_conflated(self):
        observations = self.synthetic_observations()
        row = next(row for row in observations if row["identity"] == "ContentRule/absent")
        row["snapshots"][0]["encodedJSON"] = '{"callBackJs":null}'
        checked = self.compare(observations)
        self.assertEqual(checked["differenceCount"], 1)
        self.assertEqual(checked["differences"][0]["expected"], {"kind": "absent"})
        self.assertEqual(checked["differences"][0]["actual"], {"kind": "null"})

    def test_unknown_field_loss_and_numeric_lexeme_changes_are_observed(self):
        for replacement in (None, "1000", '"1e3"'):
            observations = self.synthetic_observations()
            row = next(row for row in observations if row["kind"] == "unknownField" and row["identity"] == "root")
            if replacement is None:
                raw = reference.strict_json(row["snapshots"][0]["encodedJSON"])
                raw.pop("xPublicFutureField")
                row["snapshots"][0]["encodedJSON"] = json.dumps(raw)
            else:
                row["snapshots"][0]["encodedJSON"] = row["snapshots"][0]["encodedJSON"].replace('"number":1e3', '"number":' + replacement)
            checked = self.compare(observations)
            self.assertFalse(checked["selectedContractsMatch"])
            self.assertEqual(checked["differenceCount"], 1)
            self.assertEqual(checked["differences"][0]["contract"], "forwardUnknownField")

    def test_parser_rejects_duplicate_keys_non_json_and_malformed_snapshots(self):
        for raw in ('{"kind":1,"kind":2}', '{"number":NaN}'):
            with self.assertRaises(ValueError): reference.strict_json(raw)
        for changed in ({"stage": "decoded-rule", "getterValue": 1, "encodedJSON": "{}"},
                        {"stage": "decoded-rule", "getterValue": None, "encodedJSON": "[]"},
                        {"stage": "decoded-rule", "getterValue": None, "encodedJSON": "{", "extra": True}):
            observations = self.synthetic_observations()
            observations[0]["snapshots"] = [changed]
            with self.subTest(changed=changed), self.assertRaises(ValueError): self.compare(observations)
        self.assertEqual(reference.parse_observations("unrelated log only"), [])


if __name__ == "__main__": unittest.main()
