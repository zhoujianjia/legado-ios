#!/usr/bin/env python3
"""Portable evidence guards; no Simulator, signing or device access occurs here."""
import copy
from contextlib import ExitStack
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("renewal_probe_guard_tests", HERE / "renewal-probe-tools.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
smoke = probe.smoke
SOURCE = "a" * 40
FALLBACK = "Used for local book services and an explicit same-device connection diagnostic."


class RenewalProbeEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.work = self.root / ".build/reader-renewal-probe"
        self.originals = {path: ("source fixture: " + path + "\n").encode() for path in probe.SOURCE_INPUTS}
        self.originals[smoke.INFO] = plistlib.dumps({"CFBundleURLTypes": [], "GatewayBaseURL": "upstream",
                                                  "NSBonjourServices": list(probe.BONJOUR_SERVICES)})
        identifiers = "\n".join(
            "PRODUCT_BUNDLE_IDENTIFIER = " + smoke.config.MAIN_BUNDLE + suffix + ";"
            for suffix in ("", ".widget", ".shareextension", ".tests", ".uitests")
            for _ in range(2))
        self.originals[smoke.config.PROJECT] = (identifiers + "\n" +
            ('INFOPLIST_KEY_NSLocalNetworkUsageDescription = "' + FALLBACK + '";\n') * 2).encode()
        for language in probe.LANGUAGES:
            self.originals["Resources/" + language + ".lproj/InfoPlist.strings"] = (
                '"' + probe.USAGE_KEY + '" = "synthetic privacy purpose ' + language + '";\n').encode()
        for path, data in self.originals.items():
            self.write(self.root / path, data)
        self.environment = {"GITHUB_SHA": SOURCE, "GITHUB_REF_NAME": "reader-renewal-aaaaaaa",
                            "LEGADO_RUNTIME_SOURCE_ONLY": "1", "YUEDU_DEST": "id=synthetic-simulator"}

    def write(self, path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def write_json(self, name, record):
        self.write(self.work / name, json.dumps(record).encode())

    def git(self, *args, binary=False):
        if args[0] == "show":
            return self.originals[args[1].removeprefix("HEAD:")]
        if args[0] == "status":
            return ""
        if args[0] == "diff":
            return "\n".join(sorted(path for path, original in self.originals.items()
                                    if (self.root / path).read_bytes() != original))
        raise AssertionError(args)

    def context(self):
        stack = ExitStack()
        stack.enter_context(patch.object(smoke, "REPO", self.root))
        stack.enter_context(patch.object(smoke, "source_sha", return_value=SOURCE))
        stack.enter_context(patch.object(smoke, "git", side_effect=self.git))
        stack.enter_context(patch.dict(os.environ, self.environment))
        return stack

    def tree(self, group):
        return {"testNodes": [{"nodeType": "Test Plan", "name": "All tests", "children": [
            {"nodeType": "Test Case", "nodeIdentifier": "target/" + case + "()",
             "name": case.split("/")[-1] + "()", "result": "Passed"}
            for case in sorted(probe.EXPECTED_CASES[group])]}]}

    def built_fixture(self):
        probe.prepare(self.work)
        app = self.root / "products/YueduReader.app"
        info = {**smoke.config.LOCAL_FLAGS, "GatewayBaseURL": "", "GIDClientID": smoke.config.GOOGLE_CLIENT,
                "CFBundleIdentifier": smoke.config.MAIN_BUNDLE, "CFBundleExecutable": "YueduReader",
                "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
                "NSBonjourServices": list(probe.BONJOUR_SERVICES), probe.USAGE_KEY: FALLBACK,
                "YueduExperienceSourceCommit": SOURCE, "GitCommitSHA": SOURCE[:7]}
        self.write(app / "Info.plist", plistlib.dumps(info))
        self.write(app / "YueduReader", b"fixture executable never uploaded")
        self.write(app / "GoogleService-Info.plist", plistlib.dumps(smoke.config.synthetic_config()))
        for index, language in enumerate(probe.LANGUAGES):
            value = "synthetic privacy purpose " + language
            path = app / (language + ".lproj/InfoPlist.strings")
            # Exercise the formats Xcode can retain or compile for localized strings.
            if index < 2:
                raw = plistlib.dumps({probe.USAGE_KEY: value}, fmt=(plistlib.FMT_BINARY if index == 0 else plistlib.FMT_XML))
            else:
                raw = ('"' + probe.USAGE_KEY + '" = "' + value + '";\n').encode("utf-16" if index == 2 else "utf-8")
            self.write(path, raw)
        self.write_json("build-settings.json", [{"target": smoke.config.MAIN_TARGET, "buildSettings": {
            "CONFIGURATION": "Debug", "SWIFT_VERSION": "5.0", "PLATFORM_NAME": "iphonesimulator",
            "PRODUCT_BUNDLE_IDENTIFIER": smoke.config.MAIN_BUNDLE, "TARGET_BUILD_DIR": str(app.parent),
            "FULL_PRODUCT_NAME": app.name}}])
        for group in probe.EXPECTED_CASES:
            count = len(probe.EXPECTED_CASES[group])
            self.write_json(group + "-summary.json", {"totalTestCount": count, "passedTests": count,
                                                      "failedTests": 0, "skippedTests": 0})
            self.write_json(group + "-tests.json", self.tree(group))
        return app

    def test_new_tag_is_explicit_and_does_not_widen_default_smoke(self):
        with self.context():
            self.assertEqual(probe.validate_tag(), SOURCE)
            with self.assertRaisesRegex(ValueError, "reader-smoke-"):
                smoke.validate_tag()
            with patch.dict(os.environ, {"GITHUB_REF_NAME": "reader-smoke-aaaaaaa"}):
                self.assertEqual(smoke.validate_tag(), SOURCE)
                with self.assertRaisesRegex(ValueError, "reader-renewal-"):
                    probe.validate_tag()
            for source, ref in (("b" * 40, "reader-renewal-aaaaaaa"), (SOURCE, "reader-renewal-bbbbbbb"),
                                (SOURCE, "reader-renewal-AAAAAAA"), (SOURCE, "reader-renewal-aaaaaaa-extra")):
                with self.subTest(source=source, ref=ref), patch.dict(os.environ, {"GITHUB_SHA": source, "GITHUB_REF_NAME": ref}), \
                        self.assertRaises(ValueError):
                    probe.validate_tag()
            for prefix in ("", "reader-", "reader-experience-", "reader-renewal-.*", True):
                with self.subTest(prefix=prefix), self.assertRaisesRegex(ValueError, "Unsupported"):
                    smoke.validate_tag(prefix)

    def test_prepare_stamps_source_and_preserves_zero_owned_id_overlay(self):
        with self.context():
            record = probe.prepare(self.work)
            audit = smoke.read_json(self.work / "overlays.json")
            smoke.review_overlays(audit)
            self.assertEqual(audit["projectOverlay"]["replacementCount"], 0)
            self.assertEqual(audit["expectedTrackedChanges"], [smoke.INFO])
            smoke.require_source_stamp(plistlib.loads((self.root / smoke.INFO).read_bytes()), SOURCE)
            self.assertEqual(record["sourceCommit"], SOURCE)
            self.assertEqual(len(record["intendedTests"]["unit"]), 8)
            self.assertEqual(len(record["intendedTests"]["discovery"]), 16)
            self.assertEqual(len(record["intendedTests"]["ui"]), 1)
            paths = {item["path"] for item in record["sourceInputs"]}
            self.assertEqual(len(record["sourceInputs"]), 32)
            self.assertTrue({"scripts/reader-experience/inspect-renewal-report.py",
                             "scripts/reader-experience/renewal-report-schema1.py",
                             "scripts/reader-experience/test-inspect-renewal-report.py"} <= paths)
            self.assertEqual(record["sourceInputs"][0]["sha256"], hashlib.sha256(self.originals[probe.SOURCE_INPUTS[0]]).hexdigest())

    def test_prepare_rejects_runtime_payload_mode_before_mutation(self):
        with self.context():
            for value in ("", "0", "true"):
                with self.subTest(value=value), patch.dict(os.environ, {"LEGADO_RUNTIME_SOURCE_ONLY": value}), \
                        self.assertRaisesRegex(ValueError, "SOURCE_ONLY=1"):
                    probe.prepare(self.work)
            self.assertEqual((self.root / smoke.INFO).read_bytes(), self.originals[smoke.INFO])
            self.assertFalse((self.work / "overlays.json").exists())

    def test_prepare_rejects_changed_probe_inputs_and_prior_evidence(self):
        with self.context():
            path = probe.SOURCE_INPUTS[0]
            self.write(self.root / path, b"altered test input")
            with self.assertRaisesRegex(ValueError, "differs from checked-out HEAD"):
                probe.prepare(self.work)
            self.write(self.root / path, self.originals[path])
            probe.prepare(self.work)
            with self.assertRaisesRegex(ValueError, "overwrite"):
                probe.prepare(self.work)

    def test_actual_case_identities_not_just_summary_count_are_required(self):
        for group in probe.EXPECTED_CASES:
            with self.subTest(group=group):
                result = probe.verify_cases(self.tree(group), group)
                self.assertEqual(set(result["passedCaseIdentifiers"]), probe.EXPECTED_CASES[group])
                for change in ("duplicate", "empty", "unrelated", "skipped", "failed", "missing-id"):
                    tree = self.tree(group)
                    cases = tree["testNodes"][0]["children"]
                    if change == "duplicate":
                        cases.append(copy.deepcopy(cases[0]))
                    elif change == "empty":
                        cases.clear()
                    elif change == "unrelated":
                        cases[0]["nodeIdentifier"] = "SomeOtherTests/looksSuccessful()"
                    elif change == "missing-id":
                        cases[0].pop("nodeIdentifier")
                    else:
                        cases[0]["result"] = change.title()
                    with self.subTest(change=change), self.assertRaises(ValueError):
                        probe.verify_cases(tree, group)
        for tree in ({}, {"testNodes": None}, {"testNodes": [None]}, {"testNodes": [{"children": True}]}):
            with self.subTest(tree=tree), self.assertRaises(ValueError):
                probe.verify_cases(tree, "unit")

    def test_valid_result_keeps_real_device_and_renewal_unverified(self):
        with self.context():
            self.built_fixture()
            result = probe.result(self.work)
            self.assertEqual(result["status"], "passed")
            self.assertEqual(result["targetedTests"]["unit"]["totalTestCount"], 8)
            self.assertEqual(result["targetedTests"]["discovery"]["totalTestCount"], 16)
            self.assertEqual(result["targetedTests"]["ui"]["totalTestCount"], 1)
            self.assertEqual(result["executionPlatform"], "ios-simulator")
            for key in ("iphoneTransportVerified", "selfRenewalVerified", "unattendedRenewalVerified",
                        "physicalDeviceValidationPassed", "appleAccountUsed", "pairingRecordUsed",
                        "ipaGenerated", "ipaUploaded", "serviceIdentityVerified"):
                self.assertIs(result[key], False, key)
            self.assertEqual(result["computerPoweredOff"], "notMeasured")
            self.assertEqual(result["companionAppsAbsent"], "notMeasured")
            self.assertEqual(result["evidenceSHA256"]["unit-tests.json"], smoke.config.digest(self.work / "unit-tests.json"))
            self.assertEqual(result["evidenceSHA256"]["discovery-tests.json"], smoke.config.digest(self.work / "discovery-tests.json"))
            self.assertEqual(result["builtDiscoveryMetadata"]["bonjourServices"], list(probe.BONJOUR_SERVICES))
            self.assertEqual(len(result["builtDiscoveryMetadata"]["localizedUsageDescriptions"]), 5)
            self.assertEqual(next(item for item in result["sourceInputs"] if item["path"] == smoke.INFO)["sha256"],
                             hashlib.sha256(self.originals[smoke.INFO]).hexdigest())

    def test_result_rejects_skips_missing_counts_and_incorrect_group_counts(self):
        with self.context():
            self.built_fixture()
            for group in probe.EXPECTED_CASES:
                original = smoke.read_json(self.work / (group + "-summary.json"))
                for change in ({"skippedTests": 1}, {"failedTests": 1}, {"totalTestCount": 0},
                               {"passedTests": True}, {"totalTestCount": 64}):
                    with self.subTest(group=group, change=change):
                        self.write_json(group + "-summary.json", {**original, **change})
                        with self.assertRaises(ValueError):
                            probe.result(self.work)
                for name in original:
                    self.write_json(group + "-summary.json", {k: v for k, v in original.items() if k != name})
                    with self.assertRaises(ValueError):
                        probe.result(self.work)
                self.write_json(group + "-summary.json", original)

    def test_result_rejects_changed_source_audit_and_working_source(self):
        with self.context():
            self.built_fixture()
            inputs = smoke.read_json(self.work / "source-inputs.json")
            changed = copy.deepcopy(inputs)
            changed["sourceInputs"][0]["sha256"] = "0" * 64
            self.write_json("source-inputs.json", changed)
            with self.assertRaisesRegex(ValueError, "source-input audit"):
                probe.result(self.work)
            self.write_json("source-inputs.json", inputs)
            self.write(self.root / probe.SOURCE_INPUTS[0], b"changed code after tests")
            with self.assertRaisesRegex(ValueError, "Only the declared"):
                probe.result(self.work)

    def test_result_rejects_missing_source_stamp_in_audit_or_built_info(self):
        with self.context():
            app = self.built_fixture()
            audit = smoke.read_json(self.work / "overlays.json")
            changed = copy.deepcopy(audit)
            changed["infoOverlay"].pop("sourceCommitStamped")
            self.write_json("overlays.json", changed)
            with self.assertRaisesRegex(ValueError, "stamp its exact source"):
                probe.result(self.work)
            self.write_json("overlays.json", audit)
            info = plistlib.loads((app / "Info.plist").read_bytes())
            info["YueduExperienceSourceCommit"] = "b" * 40
            self.write(app / "Info.plist", plistlib.dumps(info))
            with self.assertRaisesRegex(ValueError, "full and short"):
                probe.result(self.work)

    def test_result_rejects_device_host_real_cloud_config_and_jvm_payload(self):
        with self.context():
            app = self.built_fixture()
            info = plistlib.loads((app / "Info.plist").read_bytes())
            self.write(app / "Info.plist", plistlib.dumps({**info, "CFBundleSupportedPlatforms": ["iPhoneOS"]}))
            with self.assertRaisesRegex(ValueError, "Simulator reader"):
                probe.result(self.work)
            self.write(app / "Info.plist", plistlib.dumps(info))
            self.write(app / "GoogleService-Info.plist", plistlib.dumps({"API_KEY": "unexpected real configuration"}))
            with self.assertRaisesRegex(ValueError, "synthetic Firebase"):
                probe.result(self.work)
            self.write(app / "GoogleService-Info.plist", plistlib.dumps(smoke.config.synthetic_config()))
            self.write(app / "LegadoRuntime/legado-runtime.jar", b"unexpected staged runtime")
            with self.assertRaisesRegex(ValueError, "JVM payload"):
                probe.result(self.work)

    def test_built_metadata_rejects_missing_duplicate_or_broadened_bonjour_services(self):
        with self.context():
            app = self.built_fixture()
            info = plistlib.loads((app / "Info.plist").read_bytes())
            for value in (None, [], [probe.BONJOUR_SERVICES[0]], [probe.BONJOUR_SERVICES[1]] * 2,
                          list(probe.BONJOUR_SERVICES) + ["_other._tcp"],
                          [probe.BONJOUR_SERVICES[0], "_remotepairing._tcp."], True):
                with self.subTest(services=value):
                    changed = {**info}
                    if value is None:
                        changed.pop("NSBonjourServices")
                    else:
                        changed["NSBonjourServices"] = value
                    self.write(app / "Info.plist", plistlib.dumps(changed))
                    with self.assertRaisesRegex(ValueError, "Built Bonjour services"):
                        probe.result(self.work)

    def test_built_privacy_fallback_must_match_both_actual_project_configurations(self):
        with self.context():
            app = self.built_fixture()
            info = plistlib.loads((app / "Info.plist").read_bytes())
            for value in (None, "", "old purpose without the explicit diagnostic", False):
                with self.subTest(fallback=value):
                    changed = {**info}
                    if value is None:
                        changed.pop(probe.USAGE_KEY)
                    else:
                        changed[probe.USAGE_KEY] = value
                    self.write(app / "Info.plist", plistlib.dumps(changed))
                    with self.assertRaisesRegex(ValueError, "privacy fallback"):
                        probe.result(self.work)
            self.write(app / "Info.plist", plistlib.dumps(info))
            project = self.root / smoke.config.PROJECT
            original = project.read_bytes()
            for raw in (original.replace(FALLBACK.encode(), b"different second configuration", 1),
                        original.replace(('INFOPLIST_KEY_NSLocalNetworkUsageDescription = "' + FALLBACK + '";\n').encode(), b"", 1)):
                self.write(project, raw)
                with self.assertRaisesRegex(ValueError, "privacy fallback"):
                    probe.verify_built_discovery_metadata(app, info)
            self.write(project, original)

    def test_all_five_built_privacy_localizations_are_required_and_source_matched(self):
        with self.context():
            app = self.built_fixture()
            for language in probe.LANGUAGES:
                path = app / (language + ".lproj/InfoPlist.strings")
                original = path.read_bytes()
                for raw in (plistlib.dumps({probe.USAGE_KEY: "different built purpose"}),
                            plistlib.dumps({"Unrelated": "missing privacy purpose"}),
                            plistlib.dumps({probe.USAGE_KEY: False}),
                            ('"' + probe.USAGE_KEY + '" = "one";\n"' + probe.USAGE_KEY + '" = "two";\n').encode(),
                            b"x" * (64 * 1024 + 1)):
                    with self.subTest(language=language, fixture=raw[:30]):
                        self.write(path, raw)
                        with self.assertRaises(ValueError):
                            probe.result(self.work)
                path.unlink()
                with self.assertRaises(FileNotFoundError):
                    probe.result(self.work)
                self.write(path, original)

    def test_discovery_summary_and_exact_method_identity_evidence_cannot_be_omitted(self):
        with self.context():
            self.built_fixture()
            for name in ("discovery-summary.json", "discovery-tests.json"):
                path = self.work / name
                original = path.read_bytes()
                path.unlink()
                with self.assertRaises(FileNotFoundError):
                    probe.result(self.work)
                self.write(path, original)

    def test_metadata_inputs_cannot_use_an_unreviewed_overlay_to_hide_source_changes(self):
        with self.context():
            probe.prepare(self.work)
            audit = smoke.read_json(self.work / "overlays.json")
            self.assertEqual(len(probe.source_inputs(audit)), len(probe.SOURCE_INPUTS))
            with self.assertRaisesRegex(ValueError, "differs from checked-out HEAD"):
                probe.source_inputs()
            changed = copy.deepcopy(audit)
            changed["infoOverlay"]["overlaySHA256"] = "0" * 64
            with self.assertRaisesRegex(ValueError, "differs from checked-out HEAD"):
                probe.source_inputs(changed)
            target = self.root / "Resources/en.lproj/InfoPlist.strings"
            self.write(target, b'"NSLocalNetworkUsageDescription" = "unreviewed change";\n')
            with self.assertRaisesRegex(ValueError, "differs from checked-out HEAD"):
                probe.source_inputs(audit)

    def test_privacy_strings_decode_unicode_escapes_without_changing_literal_backslashes(self):
        path = self.root / "privacy-escape-fixture.strings"
        for encoded, expected in ((r'"purpose \U4E2D"', "purpose \u4e2d"),
                                  (r'"purpose \\U4E2D"', r"purpose \U4E2D"),
                                  (r'"purpose \\\U4E2D"', "purpose \\\u4e2d")):
            with self.subTest(encoded=encoded):
                self.write(path, ('"' + probe.USAGE_KEY + '" = ' + encoded + ';\n').encode())
                self.assertEqual(probe.decoded_strings_value(path, probe.USAGE_KEY), expected)


if __name__ == "__main__":
    unittest.main()
