#!/usr/bin/env python3
"""Portable evidence guards; no Simulator, signing or device access occurs here."""
import base64
import copy
from contextlib import ExitStack
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import zipfile
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
                            "LEGADO_RUNTIME_SOURCE_ONLY": "1", "YUEDU_DEST": "id=synthetic-simulator",
                            "YUEDU_RENEWAL_SELECTION": "all", "YUEDU_RENEWAL_PORTABLE_GUARDS_OUTCOME": "success"}

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
        cases = []
        for case in sorted(probe.EXPECTED_CASES[group]):
            parameter = probe.parameter_cases(group).get(case)
            identifier = "target/" + case + ("(" + parameter + ":)" if parameter else "()")
            node = {"nodeType": "Test Case", "nodeIdentifier": identifier, "name": case.split("/")[-1] + "()", "result": "Passed"}
            if parameter:
                node["nodeIdentifierURL"] = "test://owned/" + identifier
                node["children"] = [{"nodeType": "Arguments", "name": value, "result": "Passed",
                                     "children": [{"nodeType": "Test Case Run", "result": "Passed"}]} for value in ("false", "true")]
            cases.append(node)
        return {"testNodes": [{"nodeType": "Test Plan", "name": "All tests", "children": cases}]}

    def built_fixture(self):
        probe.prepare(self.work)
        if probe.selection_mode() in ('handoffrenewal', 'currentcore'):
            self.write(self.work/'xcode-version.log',b'Portable guard version fixture; no SDK executed\n')
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
        for group in probe.selected_cases():
            count = probe.expected_leaf_count(group)
            self.write_json(group + "-summary.json", {"totalTestCount": count, "passedTests": count,
                                                      "failedTests": 0, "skippedTests": 0})
            self.write_json(group + "-tests.json", self.tree(group))
        return app

    def sdk_public_fixture(self):
        """Hermetic guard inputs, never an actual SDK execution or acceptance."""
        source = (HERE.parents[1] / "Tests/iOS/yuedu appTests/SelfRenewalControlledPackageFixture.swift").read_text(encoding="utf-8")
        def raw(name):
            match = re.search(r"static let " + name + r' = """(.*?)"""', source, re.S)
            self.assertIsNotNone(match)
            return base64.b64decode("".join(match[1].split()), validate=True)
        anchor = raw("anchorBase64")
        executable, library = raw("dysymtabExecutableBase64"), raw("dysymtabLibraryBase64")
        directory = self.root / ".build/hermetic-producer-output"
        directory.mkdir(parents=True)
        outputs = {name: b"public hermetic guard fixture\n" for name in probe._sdk_output_names()}
        outputs["root.cert.der"] = anchor
        rows = []
        for role in ("main", "share", "widget", "framework"):
            macho = library if role == "framework" else executable
            commands, kind, primary, cms = probe._sdk_macho(macho, role)
            outputs.update({role + ".macho": macho, role + ".primary.cd": primary,
                            role + ".verified.cd": primary, role + ".detached.cms": cms})
            rows.append({"role": role, "bytes": len(macho), "sha256": hashlib.sha256(macho).hexdigest(),
                         "loadCommands": commands, "fileType": kind, "originalDetachedCMSActuallyVerified": True})
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as archive: archive.writestr("Payload/owned.txt", "guard fixture")
        archive = buffer.getvalue(); archive_hash = hashlib.sha256(archive).hexdigest()
        outputs["owned-sdk-package.ipa"] = archive
        outputs["owned-sdk-package.json"] = json.dumps({"schema": 1, "archive": base64.b64encode(archive).decode(),
            "anchor": base64.b64encode(anchor).decode(), "verificationEpochSeconds": 1792540800,
            "archiveSHA256": archive_hash, "actualSDKProducedMachOs": rows}, sort_keys=True).encode()
        for name, data in outputs.items(): self.write(directory / name, data)
        commands = ([{"argv": ["xcrun", "clang", "owned.c"], "exitCode": 0}] * 4 +
                    [{"argv": ["codesign", "--sign", "owned-identity"], "exitCode": 0}] * 4 +
                    [{"argv": ["openssl", "cms", "-verify"], "exitCode": 0}] * 4 +
                    [{"argv": ["security", "delete-keychain", "temporary-owned"], "exitCode": 0}])
        manifest = {"schema": 1, "privateKeyFilesOutsideKeychain": 0, "privateMaterialArtifacts": 0,
            "temporaryOwnedKeychainDeleted": True, "realAppleAccountUsed": False,
            "sourceInputs": [{"path": name, "bytes": len(self.originals[probe.SDK_TOOL_ROOT + name]),
                              "sha256": hashlib.sha256(self.originals[probe.SDK_TOOL_ROOT + name]).hexdigest()}
                             for name in probe.SDK_TOOL_NAMES],
            "publicOutputs": [{"path": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                              for name, data in sorted(outputs.items())], "commands": commands,
            "actualSDKProducedMachOs": rows, "archiveBytes": len(archive), "archiveSHA256": archive_hash}
        self.write(directory / "sdk-produced-fixture-manifest.json", json.dumps(manifest).encode())
        return directory

    def sdk_runtime_fixture(self):
        directory = self.sdk_public_fixture()
        binding = probe.stage_sdk_fixture(self.work, directory)
        probe.verify_sdk_fixture(self.work, "before-build")
        bundle = self.root / "products/yuedu appTests.xctest"
        resource = (self.root / probe.SDK_RESOURCE).read_bytes()
        self.write(bundle / "owned-sdk-package.json", resource)
        self.write_json("sdk-test-build-settings.json", [{"target": "yuedu appTests", "buildSettings": {
            "CONFIGURATION": "Debug", "PLATFORM_NAME": "iphonesimulator", "TARGET_BUILD_DIR": str(bundle.parent),
            "FULL_PRODUCT_NAME": bundle.name}}])
        marker = (probe.SDK_MARKER + " resourceSHA256=" + binding["resource"]["sha256"] +
                  " resourceBytes=" + str(len(resource)) + " archiveSHA256=" + binding["archive"]["sha256"] +
                  " archiveBytes=" + str(binding["archive"]["bytes"]) + "\n")
        self.write(self.work / (probe.selection_mode() + "-tests.log"), marker.encode())
        probe.verify_sdk_fixture(self.work, "after-tests")
        return directory, bundle

    def transaction_details_fixture(self, native_exit=0, group="transactionrenewal"):
        tree = self.tree(group)
        commands = []; exports = []
        bundle = str(self.work / (group + ".xcresult"))
        def command(name, raw, argv):
            path = self.work / name; self.write(path, raw); self.write(path.with_suffix(path.suffix + ".stderr.log"), b"")
            commands.append({"argv": argv, "exitCode": 0, "timedOut": False, "oversized": False,
                "output": name, "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest(),
                "stderr": name + ".stderr.log", "stderrBytes": 0, "stderrSHA256": hashlib.sha256(b"").hexdigest()})
        command((group + "-summary.json"), (self.work / (group + "-summary.json")).read_bytes(), ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", bundle])
        command((group + "-tests.json"), (self.work / (group + "-tests.json")).read_bytes(), ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", bundle])
        command("xcresulttool-tests-help.log", b"nodeIdentifier result Arguments", ["xcrun", "xcresulttool", "get", "test-results", "tests", "--help"])
        command("xcresulttool-test-details-help.log", b"testIdentifier testResult testRuns", ["xcrun", "xcresulttool", "get", "test-results", "test-details", "--help"])
        nodes = probe._test_nodes(tree)
        for index, method in enumerate(sorted(probe.parameter_cases(group))):
            node = next(node for node in nodes if probe._qualified_method(node["nodeIdentifier"]) == method)
            name = "transaction-parameter-" + str(index) + ".json"
            detail = {"testIdentifier": node["nodeIdentifier"], "testIdentifierURL": node["nodeIdentifierURL"],
                      "testResult": "Passed", "testRuns": node["children"]}
            command(name, json.dumps(detail).encode(), ["xcrun", "xcresulttool", "get", "test-results", "test-details", "--path", bundle, "--test-id", node["nodeIdentifierURL"]])
            exports.append({"method": method, "file": name, "testID": node["nodeIdentifierURL"]})
        self.write_json((group + "-extraction.json"), {"schemaVersion": 1, "group": group,
            "originalXCTestExitCode": native_exit, "commands": commands, "parameterExports": exports})

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
            self.assertEqual(record["selectionMode"], "all")
            self.assertEqual(len(record["intendedTests"]["unit"]), 8)
            self.assertEqual(len(record["intendedTests"]["discovery"]), 16)
            self.assertEqual(len(record["intendedTests"]["replacement"]), 5)
            self.assertEqual(len(record["intendedTests"]["ui"]), 1)
            paths = {item["path"] for item in record["sourceInputs"]}
            self.assertEqual(len(record["sourceInputs"]), 322)
            self.assertTrue({"scripts/reader-experience/inspect-renewal-report.py",
                             "scripts/reader-experience/renewal-report-schema1.py",
                             "scripts/reader-experience/test-inspect-renewal-report.py",
                             "Modules/Services/SelfRenewal/SelfRenewalMaterialInventory.swift",
                             "Tests/iOS/yuedu appTests/SelfRenewalMaterialInventoryTests.swift",
                             "Modules/Services/SelfRenewal/SelfRenewalMachOSignatureReader.swift",
                             "Tests/iOS/yuedu appTests/SelfRenewalMachOSignatureReaderTests.swift",
                             "Modules/Services/SelfRenewal/SelfRenewalCodeDirectoryHashVerifier.swift",
                             "Tests/iOS/yuedu appTests/SelfRenewalCodeDirectoryHashVerifierTests.swift",
                             "Modules/Services/SelfRenewal/SelfRenewalCMSVerifier.swift",
                             "Modules/Services/SelfRenewal/SelfRenewalProvisioningProfileVerifier.swift",
                             "Tests/iOS/yuedu appTests/SelfRenewalCMSFixture.swift",
                             "Tests/iOS/yuedu appTests/SelfRenewalCMSVerifierTests.swift",
                             "Tests/iOS/yuedu appTests/SelfRenewalProvisioningProfileVerifierTests.swift"} <= paths)
            self.assertEqual(set(record["intendedTests"]), {"unit", "discovery", "replacement", "ui"})
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
                self.assertEqual(set(result.get("passedMethodIdentifiers", result["passedCaseIdentifiers"])), probe.EXPECTED_CASES[group])
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
            self.assertEqual(result["targetedTests"]["replacement"]["totalTestCount"], 5)
            self.assertEqual(result["targetedTests"]["ui"]["totalTestCount"], 1)
            self.assertEqual(result["unselectedTestGroups"], ["materials", "signature", "cryptography", "sealedmaterials", "boundmaterials", "controlledsigning", "integratedrenewal", "transactionrenewal", "handoffrenewal", "currentcore"])
            self.assertEqual(result["executionPlatform"], "ios-simulator")
            for key in ("iphoneTransportVerified", "selfRenewalVerified", "unattendedRenewalVerified",
                        "physicalDeviceValidationPassed", "appleAccountUsed", "pairingRecordUsed",
                        "ipaGenerated", "ipaUploaded", "serviceIdentityVerified"):
                self.assertIs(result[key], False, key)
            self.assertEqual(result["computerPoweredOff"], "notMeasured")
            self.assertEqual(result["companionAppsAbsent"], "notMeasured")
            self.assertEqual(result["evidenceSHA256"]["unit-tests.json"], smoke.config.digest(self.work / "unit-tests.json"))
            self.assertEqual(result["evidenceSHA256"]["discovery-tests.json"], smoke.config.digest(self.work / "discovery-tests.json"))
            self.assertEqual(result["evidenceSHA256"]["replacement-tests.json"], smoke.config.digest(self.work / "replacement-tests.json"))
            self.assertEqual(result["builtDiscoveryMetadata"]["bonjourServices"], list(probe.BONJOUR_SERVICES))
            self.assertEqual(len(result["builtDiscoveryMetadata"]["localizedUsageDescriptions"]), 5)
            self.assertEqual(next(item for item in result["sourceInputs"] if item["path"] == smoke.INFO)["sha256"],
                             hashlib.sha256(self.originals[smoke.INFO]).hexdigest())

    def test_result_rejects_skips_missing_counts_and_incorrect_group_counts(self):
        with self.context():
            self.built_fixture()
            for group in probe.selected_cases():
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

    def test_replacement_selection_requires_only_its_five_exact_cases_and_never_accepts_unselected_groups(self):
        with self.context(), patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": "replacement"}):
            self.built_fixture()
            inputs = smoke.read_json(self.work / "source-inputs.json")
            self.assertEqual(inputs["selectionMode"], "replacement")
            self.assertEqual(inputs["intendedTests"], {"replacement": sorted(probe.EXPECTED_CASES["replacement"])})
            for group in ("unit", "discovery", "materials", "signature", "ui", "cryptography", "sealedmaterials", "boundmaterials", "controlledsigning", "integratedrenewal", "transactionrenewal"):
                self.assertFalse((self.work / (group + "-summary.json")).exists())
                self.assertFalse((self.work / (group + "-tests.json")).exists())
                # Even unrelated leftover files cannot become accepted test evidence.
                self.write(self.work / (group + "-summary.json"), b"not selected; not JSON")
                self.write(self.work / (group + "-tests.json"), b"not selected; not JSON")
            result = probe.result(self.work)
            self.assertEqual(result["selectionMode"], "replacement")
            self.assertEqual(set(result["targetedTests"]), {"replacement"})
            self.assertEqual(result["targetedTests"]["replacement"]["totalTestCount"], 5)
            self.assertEqual(set(result["unselectedTestGroups"]), {"unit", "discovery", "materials", "signature", "ui", "cryptography", "sealedmaterials", "boundmaterials", "controlledsigning", "integratedrenewal", "transactionrenewal", "handoffrenewal", "currentcore"})
            for mode in ("all", "implementation", "signature", "cryptography", "sealedmaterials", "boundmaterials", "controlledsigning", "integratedrenewal", "transactionrenewal"):
                with patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": mode}), \
                        self.assertRaisesRegex(ValueError, "source-input audit"):
                    probe.result(self.work)
            for group in result["unselectedTestGroups"]:
                self.assertNotIn(group + "-summary.json", result["evidenceSHA256"])
                self.assertNotIn(group + "-tests.json", result["evidenceSHA256"])
            for suffix in ("-summary.json", "-tests.json"):
                path = self.work / ("replacement" + suffix)
                original = path.read_bytes()
                path.unlink()
                with self.assertRaises(FileNotFoundError):
                    probe.result(self.work)
                self.write(path, original)
            tree = self.tree("replacement")
            tree["testNodes"][0]["children"][0]["nodeIdentifier"] = "OtherTests/looksPassed()"
            self.write_json("replacement-tests.json", tree)
            with self.assertRaisesRegex(ValueError, "Unexpected"):
                probe.result(self.work)

    def test_selection_rejects_invalid_values_before_prepare_and_prepare_result_mode_changes(self):
        with self.context():
            for mode in ("", "Replacement", "Implementation", "Signature", "Cryptography", "Sealedmaterials", "Boundmaterials", "Controlledsigning", "materials", "unit",
                         "all,replacement", "replacement,materials", "signature,materials", "signature,cryptography", "cryptography,sealedmaterials", "sealedmaterials,boundmaterials", "boundmaterials,controlledsigning"):
                with patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": mode}), \
                        patch.object(smoke, "prepare") as prepare, self.assertRaisesRegex(ValueError, "YUEDU_RENEWAL_SELECTION"):
                    probe.prepare(self.work)
                prepare.assert_not_called()
                self.assertFalse((self.work / "source-inputs.json").exists())
            with patch.dict(os.environ):
                os.environ.pop("YUEDU_RENEWAL_SELECTION")
                self.assertEqual(probe.selection_mode(), "all")
            self.built_fixture()
            original = smoke.read_json(self.work / "source-inputs.json")
            for mode in ("replacement", "implementation", "signature", "cryptography", "sealedmaterials", "boundmaterials", "controlledsigning", "integratedrenewal", "transactionrenewal"):
                with patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": mode}), \
                        self.assertRaisesRegex(ValueError, "source-input audit"):
                    probe.result(self.work)
            changed = copy.deepcopy(original)
            changed["selectionMode"] = "replacement"
            self.write_json("source-inputs.json", changed)
            with self.assertRaisesRegex(ValueError, "source-input audit"):
                probe.result(self.work)
            self.write_json("source-inputs.json", original)

    def test_implementation_selection_accepts_only_eleven_exact_policy_and_material_cases(self):
        with self.context(), patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": "implementation"}):
            self.built_fixture()
            inputs = smoke.read_json(self.work / "source-inputs.json")
            expected = {group: sorted(probe.EXPECTED_CASES[group]) for group in ("replacement", "materials")}
            self.assertEqual(inputs["selectionMode"], "implementation")
            self.assertEqual(inputs["intendedTests"], expected)
            self.assertEqual(sum(map(len, expected.values())), 11)
            self.assertEqual(len(inputs["sourceInputs"]), 322)
            for group in ("unit", "discovery", "signature", "ui", "cryptography", "sealedmaterials", "boundmaterials", "controlledsigning", "integratedrenewal", "transactionrenewal"):
                for suffix in ("-summary.json", "-tests.json"):
                    self.assertFalse((self.work / (group + suffix)).exists())
                    self.write(self.work / (group + suffix), b"unselected evidence must not be read")
            result = probe.result(self.work)
            self.assertEqual(set(result["targetedTests"]), {"replacement", "materials"})
            self.assertEqual(result["targetedTests"]["replacement"]["totalTestCount"], 5)
            self.assertEqual(result["targetedTests"]["materials"]["totalTestCount"], 6)
            self.assertEqual(set(result["unselectedTestGroups"]), {"unit", "discovery", "signature", "ui", "cryptography", "sealedmaterials", "boundmaterials", "controlledsigning", "integratedrenewal", "transactionrenewal", "handoffrenewal", "currentcore"})
            for group in result["unselectedTestGroups"]:
                for suffix in ("-summary.json", "-tests.json"):
                    self.assertNotIn(group + suffix, result["evidenceSHA256"])
            for mode in ("all", "replacement", "signature", "cryptography", "sealedmaterials", "boundmaterials", "controlledsigning", "integratedrenewal", "transactionrenewal"):
                with patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": mode}), \
                        self.assertRaisesRegex(ValueError, "source-input audit"):
                    probe.result(self.work)
            for group in ("replacement", "materials"):
                for suffix in ("-summary.json", "-tests.json"):
                    path = self.work / (group + suffix)
                    original = path.read_bytes()
                    path.unlink()
                    with self.assertRaises(FileNotFoundError):
                        probe.result(self.work)
                    self.write(path, original)
            summary = smoke.read_json(self.work / "materials-summary.json")
            for change in ({"skippedTests": 1}, {"failedTests": 1}, {"totalTestCount": 5}, {"passedTests": True}):
                self.write_json("materials-summary.json", {**summary, **change})
                with self.subTest(change=change), self.assertRaises(ValueError):
                    probe.result(self.work)
            self.write_json("materials-summary.json", summary)
            tree = self.tree("materials")
            tree["testNodes"][0]["children"][0]["nodeIdentifier"] = "OtherTests/looksPassed()"
            self.write_json("materials-tests.json", tree)
            with self.assertRaisesRegex(ValueError, "Unexpected"):
                probe.result(self.work)

    def test_material_module_and_tests_are_required_exact_source_bound_inputs(self):
        paths = ("Modules/Services/SelfRenewal/SelfRenewalMaterialInventory.swift",
                 "Tests/iOS/yuedu appTests/SelfRenewalMaterialInventoryTests.swift")
        with self.context(), patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": "implementation"}):
            for path in paths:
                self.assertIn(path, probe.SOURCE_INPUTS)
                self.write(self.root / path, b"uncommitted material input")
                with self.subTest(path=path), self.assertRaisesRegex(ValueError, "differs from checked-out HEAD"):
                    probe.prepare(self.work)
                self.assertFalse((self.work / "source-inputs.json").exists())
                self.write(self.root / path, self.originals[path])
            self.built_fixture()
            inputs = smoke.read_json(self.work / "source-inputs.json")
            self.assertEqual(len(inputs["sourceInputs"]), len({item["path"] for item in inputs["sourceInputs"]}))
            for path in paths:
                changed = copy.deepcopy(inputs)
                item = next(item for item in changed["sourceInputs"] if item["path"] == path)
                item["sha256"] = "0" * 64
                self.write_json("source-inputs.json", changed)
                with self.subTest(path=path), self.assertRaisesRegex(ValueError, "source-input audit"):
                    probe.result(self.work)
            self.write_json("source-inputs.json", inputs)

    def test_cli_verification_rejects_groups_outside_each_exact_mode(self):
        expected = {"all": {"unit", "discovery", "replacement", "ui"},
                    "replacement": {"replacement"}, "implementation": {"replacement", "materials"},
                    "signature": {"signature"}, "cryptography": {"cryptography"},
                    "sealedmaterials": {"sealedmaterials"}, "boundmaterials": {"boundmaterials"}, "controlledsigning": {"controlledsigning"}, "integratedrenewal": {"integratedrenewal"}, "transactionrenewal": {"transactionrenewal"}, "handoffrenewal": {"handoffrenewal"}}
        with self.context():
            for mode, groups in expected.items():
                for group in probe.EXPECTED_CASES:
                    count = probe.expected_leaf_count(group)
                    self.write_json("cli-summary.json", {"totalTestCount": count, "passedTests": count,
                                                         "failedTests": 0, "skippedTests": 0})
                    self.write_json("cli-tests.json", self.tree(group))
                    if mode == 'handoffrenewal' and group == 'handoffrenewal':
                        self.write_json(group+'-summary.json', {"totalTestCount":count,"passedTests":count,"failedTests":0,"skippedTests":0})
                        self.write_json(group+'-tests.json', self.tree(group))
                        self.transaction_details_fixture(group=group)
                    output, errors = io.StringIO(), io.StringIO()
                    argv = ["renewal-probe-tools.py", "verify-tests", "--group", group,
                            "--summary", str(self.work / "cli-summary.json"),
                            "--tests", str(self.work / "cli-tests.json")]
                    with self.subTest(mode=mode, group=group), \
                            patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": mode}), \
                            patch.object(probe.sys, "argv", argv), \
                            patch.object(probe.sys, "stdout", output), patch.object(probe.sys, "stderr", errors):
                        status = probe.main()
                    self.assertEqual(status, 0 if group in groups else 1)
                    if group in groups:
                        self.assertEqual(json.loads(output.getvalue())["expectedTests"], count)
                    else:
                        self.assertIn("not part of YUEDU_RENEWAL_SELECTION", errors.getvalue())

    def test_signature_selection_accepts_only_nine_exact_structural_cases(self):
        with self.context(), patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": "signature"}):
            self.built_fixture()
            inputs = smoke.read_json(self.work / "source-inputs.json")
            self.assertEqual(inputs["selectionMode"], "signature")
            self.assertEqual(inputs["intendedTests"], {"signature": sorted(probe.EXPECTED_CASES["signature"])})
            self.assertEqual(len(inputs["intendedTests"]["signature"]), 9)
            self.assertEqual(len(inputs["sourceInputs"]), 322)
            for group in ("unit", "discovery", "replacement", "materials", "ui", "cryptography", "sealedmaterials", "boundmaterials", "controlledsigning", "integratedrenewal", "transactionrenewal"):
                for suffix in ("-summary.json", "-tests.json"):
                    self.assertFalse((self.work / (group + suffix)).exists())
                    self.write(self.work / (group + suffix), b"unselected evidence is not accepted")
            result = probe.result(self.work)
            self.assertEqual(set(result["targetedTests"]), {"signature"})
            self.assertEqual(result["targetedTests"]["signature"]["totalTestCount"], 9)
            self.assertEqual(set(result["unselectedTestGroups"]), {"unit", "discovery", "replacement", "materials", "ui", "cryptography", "sealedmaterials", "boundmaterials", "controlledsigning", "integratedrenewal", "transactionrenewal", "handoffrenewal", "currentcore"})
            for key in ("iphoneTransportVerified", "selfRenewalVerified", "unattendedRenewalVerified",
                        "physicalDeviceValidationPassed", "appleAccountUsed", "pairingRecordUsed",
                        "ipaGenerated", "ipaUploaded", "serviceIdentityVerified"):
                self.assertIs(result[key], False, key)
            self.assertIn("no CMS ASN.1", " ".join(result["limitations"]))
            for group in result["unselectedTestGroups"]:
                for suffix in ("-summary.json", "-tests.json"):
                    self.assertNotIn(group + suffix, result["evidenceSHA256"])
            for mode in ("all", "replacement", "implementation", "cryptography", "sealedmaterials", "boundmaterials", "controlledsigning", "integratedrenewal", "transactionrenewal"):
                with patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": mode}), \
                        self.assertRaisesRegex(ValueError, "source-input audit"):
                    probe.result(self.work)
            changed = copy.deepcopy(inputs)
            changed["intendedTests"]["signature"].pop()
            self.write_json("source-inputs.json", changed)
            with self.assertRaisesRegex(ValueError, "source-input audit"):
                probe.result(self.work)
            self.write_json("source-inputs.json", inputs)
            for suffix in ("-summary.json", "-tests.json"):
                path = self.work / ("signature" + suffix)
                original = path.read_bytes()
                path.unlink()
                with self.assertRaises(FileNotFoundError):
                    probe.result(self.work)
                self.write(path, original)
            summary = smoke.read_json(self.work / "signature-summary.json")
            for change in ({"skippedTests": 1}, {"failedTests": 1}, {"totalTestCount": 8}, {"passedTests": True}):
                self.write_json("signature-summary.json", {**summary, **change})
                with self.subTest(change=change), self.assertRaises(ValueError):
                    probe.result(self.work)
            self.write_json("signature-summary.json", summary)
            tree = self.tree("signature")
            tree["testNodes"][0]["children"][0]["nodeIdentifier"] = "OtherTests/looksPassed()"
            self.write_json("signature-tests.json", tree)
            with self.assertRaisesRegex(ValueError, "Unexpected"):
                probe.result(self.work)

    def test_signature_module_and_tests_are_required_exact_source_bound_inputs(self):
        paths = ("Modules/Services/SelfRenewal/SelfRenewalMachOSignatureReader.swift",
                 "Tests/iOS/yuedu appTests/SelfRenewalMachOSignatureReaderTests.swift")
        with self.context(), patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": "signature"}):
            for path in paths:
                self.assertIn(path, probe.SOURCE_INPUTS)
                self.write(self.root / path, b"uncommitted signature input")
                with self.subTest(path=path), self.assertRaisesRegex(ValueError, "differs from checked-out HEAD"):
                    probe.prepare(self.work)
                self.assertFalse((self.work / "source-inputs.json").exists())
                self.write(self.root / path, self.originals[path])
            self.built_fixture()
            inputs = smoke.read_json(self.work / "source-inputs.json")
            self.assertEqual(len(inputs["sourceInputs"]), len({item["path"] for item in inputs["sourceInputs"]}))
            for path in paths:
                changed = copy.deepcopy(inputs)
                item = next(item for item in changed["sourceInputs"] if item["path"] == path)
                item["sha256"] = "0" * 64
                self.write_json("source-inputs.json", changed)
                with self.subTest(path=path), self.assertRaisesRegex(ValueError, "source-input audit"):
                    probe.result(self.work)
            self.write_json("source-inputs.json", inputs)

    def test_cryptography_selection_requires_exact_twenty_five_cases_and_keeps_artifacts_separate(self):
        with self.context(), patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": "cryptography"}):
            self.built_fixture()
            inputs = smoke.read_json(self.work / "source-inputs.json")
            self.assertEqual(inputs["selectionMode"], "cryptography")
            self.assertEqual(inputs["intendedTests"], {"cryptography": sorted(probe.EXPECTED_CASES["cryptography"])})
            self.assertEqual(len(inputs["intendedTests"]["cryptography"]), 25)
            self.assertEqual(len(inputs["sourceInputs"]), 322)
            for group in probe.EXPECTED_CASES:
                if group == "cryptography":
                    continue
                for suffix in ("-summary.json", "-tests.json"):
                    self.assertFalse((self.work / (group + suffix)).exists())
                    self.write(self.work / (group + suffix), b"independent unselected artifact is not accepted")
            result = probe.result(self.work)
            self.assertEqual(set(result["targetedTests"]), {"cryptography"})
            self.assertEqual(result["targetedTests"]["cryptography"]["totalTestCount"], 25)
            accepted = set(result["targetedTests"]["cryptography"]["passedCaseIdentifiers"])
            self.assertEqual(accepted, probe.EXPECTED_CASES["cryptography"])
            self.assertTrue(probe.EXPECTED_CASES["signature"] <= accepted)
            self.assertIn("signature", result["unselectedTestGroups"])
            self.assertIn("may overlap", result["unselectedTestGroupsMeaning"])
            counts = {suite: sum(case.startswith(suite + "/") for case in accepted)
                      for suite in (probe.SIGNATURE_SUITE, probe.HASH_SUITE, probe.CMS_SUITE, probe.PROFILE_SUITE)}
            self.assertEqual(list(counts.values()), [9, 7, 7, 2])
            self.assertIn("do not establish Apple provisioning authority", " ".join(result["limitations"]))
            for group in result["unselectedTestGroups"]:
                for suffix in ("-summary.json", "-tests.json"):
                    self.assertNotIn(group + suffix, result["evidenceSHA256"])
            for mode in ("all", "replacement", "implementation", "signature", "sealedmaterials", "boundmaterials", "controlledsigning", "integratedrenewal", "transactionrenewal"):
                with patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": mode}), \
                        self.assertRaisesRegex(ValueError, "source-input audit"):
                    probe.result(self.work)
            changed = copy.deepcopy(inputs)
            changed["intendedTests"]["cryptography"].pop()
            self.write_json("source-inputs.json", changed)
            with self.assertRaisesRegex(ValueError, "source-input audit"):
                probe.result(self.work)
            self.write_json("source-inputs.json", inputs)
            for suffix in ("-summary.json", "-tests.json"):
                path = self.work / ("cryptography" + suffix)
                original = path.read_bytes()
                path.unlink()
                with self.assertRaises(FileNotFoundError):
                    probe.result(self.work)
                self.write(path, original)
            summary = smoke.read_json(self.work / "cryptography-summary.json")
            for change in ({"skippedTests": 1}, {"failedTests": 1}, {"totalTestCount": 24}, {"passedTests": True}):
                self.write_json("cryptography-summary.json", {**summary, **change})
                with self.subTest(change=change), self.assertRaises(ValueError):
                    probe.result(self.work)
            self.write_json("cryptography-summary.json", summary)
            for suite in counts:
                tree = self.tree("cryptography")
                leaves = tree["testNodes"][0]["children"]
                selected = next(leaf for leaf in leaves if "/" + suite + "/" in leaf["nodeIdentifier"])
                selected["result"] = "Failed"
                self.write_json("cryptography-tests.json", tree)
                with self.subTest(suite=suite), self.assertRaisesRegex(ValueError, "Unexpected"):
                    probe.result(self.work)

    def test_cryptography_inputs_cannot_be_mutated_or_removed_from_the_source_binding(self):
        paths = ("Modules/Services/SelfRenewal/SelfRenewalCodeDirectoryHashVerifier.swift",
                 "Tests/iOS/yuedu appTests/SelfRenewalCodeDirectoryHashVerifierTests.swift",
                 "Modules/Services/SelfRenewal/SelfRenewalCMSVerifier.swift",
                 "Modules/Services/SelfRenewal/SelfRenewalProvisioningProfileVerifier.swift",
                 "Tests/iOS/yuedu appTests/SelfRenewalCMSFixture.swift",
                 "Tests/iOS/yuedu appTests/SelfRenewalCMSVerifierTests.swift",
                 "Tests/iOS/yuedu appTests/SelfRenewalProvisioningProfileVerifierTests.swift")
        with self.context(), patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": "cryptography"}):
            for path in paths:
                self.assertIn(path, probe.SOURCE_INPUTS)
                self.write(self.root / path, b"uncommitted cryptography input")
                with self.subTest(path=path), self.assertRaisesRegex(ValueError, "differs from checked-out HEAD"):
                    probe.prepare(self.work)
                self.assertFalse((self.work / "source-inputs.json").exists())
                self.write(self.root / path, self.originals[path])
            self.built_fixture()
            inputs = smoke.read_json(self.work / "source-inputs.json")
            for path in paths:
                for change in ("digest", "remove"):
                    changed = copy.deepcopy(inputs)
                    item = next(item for item in changed["sourceInputs"] if item["path"] == path)
                    if change == "digest":
                        item["sha256"] = "0" * 64
                    else:
                        changed["sourceInputs"].remove(item)
                    self.write_json("source-inputs.json", changed)
                    with self.subTest(path=path, change=change), self.assertRaisesRegex(ValueError, "source-input audit"):
                        probe.result(self.work)
            self.write_json("source-inputs.json", inputs)

    def test_sealedmaterials_accepts_only_the_exact_forty_eight_affected_methods(self):
        with self.context(), patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": "sealedmaterials"}):
            self.built_fixture()
            inputs = smoke.read_json(self.work / "source-inputs.json")
            expected = probe.EXPECTED_CASES["sealedmaterials"]
            self.assertEqual(inputs["selectionMode"], "sealedmaterials")
            self.assertEqual(inputs["intendedTests"], {"sealedmaterials": sorted(expected)})
            self.assertEqual(len(inputs["sourceInputs"]), 322)
            self.assertEqual(len(expected), 48)
            self.assertTrue(probe.EXPECTED_CASES["cryptography"] | probe.EXPECTED_CASES["materials"] <= expected)
            suites = (probe.SIGNATURE_SUITE, probe.HASH_SUITE, probe.CMS_SUITE,
                      probe.PROFILE_SUITE, probe.MATERIALS_SUITE, probe.SIGNED_CODE_SUITE, probe.RESOURCE_SUITE)
            self.assertEqual([sum(case.startswith(suite + "/") for case in expected) for suite in suites],
                             [9, 7, 7, 2, 6, 7, 10])
            for group in probe.EXPECTED_CASES:
                if group != "sealedmaterials":
                    for suffix in ("-summary.json", "-tests.json"):
                        self.assertFalse((self.work / (group + suffix)).exists())
                        self.write(self.work / (group + suffix), b"unselected historical evidence must not be accepted")
            result = probe.result(self.work)
            self.assertEqual(set(result["targetedTests"]), {"sealedmaterials"})
            self.assertEqual(result["targetedTests"]["sealedmaterials"]["totalTestCount"], 48)
            self.assertEqual(set(result["targetedTests"]["sealedmaterials"]["passedCaseIdentifiers"]), expected)
            for group in result["unselectedTestGroups"]:
                for suffix in ("-summary.json", "-tests.json"):
                    self.assertNotIn(group + suffix, result["evidenceSHA256"])
            for key in ("iphoneTransportVerified", "selfRenewalVerified", "unattendedRenewalVerified",
                        "physicalDeviceValidationPassed", "appleAccountUsed", "pairingRecordUsed",
                        "ipaGenerated", "ipaUploaded", "serviceIdentityVerified"):
                self.assertIs(result[key], False, key)
            self.assertIn("Nested requirements", " ".join(result["limitations"]))
            for mode in ("all", "replacement", "implementation", "signature", "cryptography", "boundmaterials", "controlledsigning", "integratedrenewal", "transactionrenewal"):
                with patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": mode}), \
                        self.assertRaisesRegex(ValueError, "source-input audit"):
                    probe.result(self.work)
            for suffix in ("-summary.json", "-tests.json"):
                path = self.work / ("sealedmaterials" + suffix)
                original = path.read_bytes()
                path.unlink()
                with self.assertRaises(FileNotFoundError):
                    probe.result(self.work)
                self.write(path, original)
            summary = smoke.read_json(self.work / "sealedmaterials-summary.json")
            for change in ({"skippedTests": 1}, {"failedTests": 1}, {"totalTestCount": 47}, {"passedTests": True}):
                self.write_json("sealedmaterials-summary.json", {**summary, **change})
                with self.subTest(change=change), self.assertRaises(ValueError):
                    probe.result(self.work)
            self.write_json("sealedmaterials-summary.json", summary)
            for suite in suites:
                tree = self.tree("sealedmaterials")
                leaf = next(node for node in tree["testNodes"][0]["children"]
                            if "/" + suite + "/" in node["nodeIdentifier"])
                leaf["result"] = "Skipped"
                self.write_json("sealedmaterials-tests.json", tree)
                with self.subTest(suite=suite), self.assertRaisesRegex(ValueError, "Unexpected"):
                    probe.result(self.work)

    def test_sealedmaterials_new_inputs_are_required_and_cannot_hide_source_changes(self):
        paths = ("Modules/Services/SelfRenewal/SelfRenewalSignedCodeVerifier.swift",
                 "Tests/iOS/yuedu appTests/SelfRenewalSignedCodeFixture.swift",
                 "Tests/iOS/yuedu appTests/SelfRenewalSignedCodeVerifierTests.swift",
                 "Modules/Services/SelfRenewal/SelfRenewalResourceSealVerifier.swift",
                 "Tests/iOS/yuedu appTests/SelfRenewalResourceFixture.swift",
                 "Tests/iOS/yuedu appTests/SelfRenewalResourceSealVerifierTests.swift")
        with self.context(), patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": "sealedmaterials"}):
            for path in paths:
                self.assertIn(path, probe.SOURCE_INPUTS)
                self.write(self.root / path, b"uncommitted sealed-material input")
                with self.subTest(path=path), self.assertRaisesRegex(ValueError, "differs from checked-out HEAD"):
                    probe.prepare(self.work)
                self.assertFalse((self.work / "source-inputs.json").exists())
                self.write(self.root / path, self.originals[path])
            self.built_fixture()
            inputs = smoke.read_json(self.work / "source-inputs.json")
            for path in paths:
                for change in ("digest", "remove"):
                    changed = copy.deepcopy(inputs)
                    item = next(item for item in changed["sourceInputs"] if item["path"] == path)
                    if change == "digest":
                        item["sha256"] = "0" * 64
                    else:
                        changed["sourceInputs"].remove(item)
                    self.write_json("source-inputs.json", changed)
                    with self.subTest(path=path, change=change), self.assertRaisesRegex(ValueError, "source-input audit"):
                        probe.result(self.work)
            self.write_json("source-inputs.json", inputs)

    def test_sealedmaterials_expected_identities_match_real_swift_test_declarations(self):
        # Read the checked-out Swift declarations independently of the synthetic
        # xcresult trees, so a renamed or accidentally selected extra method
        # cannot be hidden by the generated portable fixtures.
        actual = set()
        for suite in (probe.SIGNATURE_SUITE, probe.HASH_SUITE, probe.CMS_SUITE,
                      probe.PROFILE_SUITE, probe.MATERIALS_SUITE, probe.SIGNED_CODE_SUITE, probe.RESOURCE_SUITE):
            relative = "Tests/iOS/yuedu appTests/" + suite + ".swift"
            self.assertIn(relative, probe.SOURCE_INPUTS)
            text = (HERE.parent.parent / relative).read_text(encoding="utf-8")
            methods = re.findall(r"(?m)^\s*func\s+(\w+)\s*\(", text)
            self.assertEqual(len(methods), len(set(methods)), suite)
            actual.update(suite + "/" + method for method in methods)
        self.assertEqual(actual, probe.EXPECTED_CASES["sealedmaterials"])

    def test_boundmaterials_accepts_only_exact_affected_leaves_and_rejects_cross_mode_or_incomplete_evidence(self):
        with self.context(), patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": "boundmaterials"}):
            self.built_fixture()
            inputs = smoke.read_json(self.work / "source-inputs.json")
            expected = probe.EXPECTED_CASES["boundmaterials"]
            self.assertEqual(inputs["selectionMode"], "boundmaterials")
            self.assertEqual(inputs["intendedTests"], {"boundmaterials": sorted(expected)})
            self.assertEqual(len(inputs["sourceInputs"]), 322)
            self.assertEqual(len(expected), 78)
            self.assertTrue(probe.EXPECTED_CASES["sealedmaterials"] <= expected)
            suites = (probe.SIGNATURE_SUITE, probe.HASH_SUITE, probe.CMS_SUITE, probe.PROFILE_SUITE,
                      probe.MATERIALS_SUITE, probe.SIGNED_CODE_SUITE, probe.RESOURCE_SUITE,
                      probe.NESTED_SUITE, probe.MODERN_PROFILE_SUITE, probe.APPLICATION_MATERIAL_SUITE, probe.PERSISTENT_STATE_SUITE)
            self.assertEqual([sum(case.startswith(suite + "/") for case in expected) for suite in suites],
                             [9, 7, 7, 2, 6, 7, 10, 8, 8, 5, 9])
            for group in probe.EXPECTED_CASES:
                if group != "boundmaterials":
                    for suffix in ("-summary.json", "-tests.json"):
                        self.assertFalse((self.work / (group + suffix)).exists())
                        self.write(self.work / (group + suffix), b"unselected evidence cannot be accepted")
            result = probe.result(self.work)
            self.assertEqual(set(result["targetedTests"]), {"boundmaterials"})
            self.assertEqual(result["targetedTests"]["boundmaterials"]["totalTestCount"], 78)
            self.assertEqual(set(result["targetedTests"]["boundmaterials"]["passedCaseIdentifiers"]), expected)
            self.assertEqual(set(result["unselectedTestGroups"]), set(probe.EXPECTED_CASES) - {"boundmaterials"})
            for group in result["unselectedTestGroups"]:
                for suffix in ("-summary.json", "-tests.json"):
                    self.assertNotIn(group + suffix, result["evidenceSHA256"])
            for key in ("iphoneTransportVerified", "selfRenewalVerified", "unattendedRenewalVerified",
                        "physicalDeviceValidationPassed", "appleAccountUsed", "pairingRecordUsed",
                        "ipaGenerated", "ipaUploaded", "serviceIdentityVerified"):
                self.assertIs(result[key], False, key)
            self.assertIn("inner DER", " ".join(result["limitations"]))
            self.assertIn("unresolved", " ".join(result["limitations"]))
            for mode in ("all", "replacement", "implementation", "signature", "cryptography", "sealedmaterials", "controlledsigning"):
                with patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": mode}), self.assertRaisesRegex(ValueError, "source-input audit"):
                    probe.result(self.work)
            changed = copy.deepcopy(inputs)
            changed["intendedTests"]["boundmaterials"].pop()
            self.write_json("source-inputs.json", changed)
            with self.assertRaisesRegex(ValueError, "source-input audit"):
                probe.result(self.work)
            self.write_json("source-inputs.json", inputs)
            for suffix in ("-summary.json", "-tests.json"):
                path = self.work / ("boundmaterials" + suffix)
                original = path.read_bytes()
                path.unlink()
                with self.assertRaises(FileNotFoundError):
                    probe.result(self.work)
                self.write(path, original)
            summary = smoke.read_json(self.work / "boundmaterials-summary.json")
            for change in ({"skippedTests": 1}, {"failedTests": 1}, {"totalTestCount": 77}, {"passedTests": True}):
                self.write_json("boundmaterials-summary.json", {**summary, **change})
                with self.subTest(change=change), self.assertRaises(ValueError):
                    probe.result(self.work)
            self.write_json("boundmaterials-summary.json", summary)
            for suite in suites:
                tree = self.tree("boundmaterials")
                leaf = next(node for node in tree["testNodes"][0]["children"] if "/" + suite + "/" in node["nodeIdentifier"])
                leaf["result"] = "Skipped"
                self.write_json("boundmaterials-tests.json", tree)
                with self.subTest(suite=suite), self.assertRaisesRegex(ValueError, "Unexpected"):
                    probe.result(self.work)

    def test_boundmaterials_new_inputs_are_required_and_hash_bound_before_and_after_tests(self):
        paths = ("Modules/Services/SelfRenewal/SelfRenewalNestedCodeRequirementsVerifier.swift",
                 "Tests/iOS/yuedu appTests/SelfRenewalNestedCodeRequirementsVerifierTests.swift",
                 "Tests/iOS/yuedu appTests/SelfRenewalNestedResourceFixture.swift",
                 "Modules/Services/SelfRenewal/SelfRenewalDERPropertyList.swift",
                 "Modules/Services/SelfRenewal/SelfRenewalApplicationMaterialVerifier.swift",
                 "Tests/iOS/yuedu appTests/SelfRenewalModernProfileFixture.swift",
                 "Tests/iOS/yuedu appTests/SelfRenewalModernProfileVerifierTests.swift",
                 "Tests/iOS/yuedu appTests/SelfRenewalApplicationMaterialFixture.swift",
                 "Tests/iOS/yuedu appTests/SelfRenewalApplicationMaterialVerifierTests.swift",
                 "Modules/Core/RuleEngine/ModernParser/ModernParserBridge.swift",
                 "Modules/Core/RuleEngine/ModernParser/BookSourceRuntimeStateStore.swift",
                 "Modules/Core/RuleEngine/ModernParser/Login/LoginManager.swift",
                 "Modules/Core/RuleEngine/ModernParser/JS/LegadoCacheBridge.swift",
                 "Modules/Services/Online/LegadoPersistentStateHost.swift",
                 "Modules/Services/Online/LegadoMainJSSourceService.swift",
                 "Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoRuntime.swift",
                 "Tests/iOS/yuedu appTests/LegadoPersistentStateHostTests.swift")
        with self.context(), patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": "boundmaterials"}):
            for path in paths:
                self.assertIn(path, probe.SOURCE_INPUTS)
                self.write(self.root / path, b"changed bound-material input")
                with self.subTest(path=path), self.assertRaisesRegex(ValueError, "differs from checked-out HEAD"):
                    probe.prepare(self.work)
                self.assertFalse((self.work / "source-inputs.json").exists())
                self.write(self.root / path, self.originals[path])
            self.built_fixture()
            inputs = smoke.read_json(self.work / "source-inputs.json")
            for path in paths:
                for change in ("digest", "remove"):
                    changed = copy.deepcopy(inputs)
                    item = next(item for item in changed["sourceInputs"] if item["path"] == path)
                    if change == "digest":
                        item["sha256"] = "0" * 64
                    else:
                        changed["sourceInputs"].remove(item)
                    self.write_json("source-inputs.json", changed)
                    with self.subTest(path=path, change=change), self.assertRaisesRegex(ValueError, "source-input audit"):
                        probe.result(self.work)
            self.write_json("source-inputs.json", inputs)

    def test_boundmaterials_leaf_set_matches_all_actual_selected_swift_declarations(self):
        actual = set()
        for suite in (probe.SIGNATURE_SUITE, probe.HASH_SUITE, probe.CMS_SUITE, probe.PROFILE_SUITE,
                      probe.MATERIALS_SUITE, probe.SIGNED_CODE_SUITE, probe.RESOURCE_SUITE,
                      probe.NESTED_SUITE, probe.MODERN_PROFILE_SUITE, probe.APPLICATION_MATERIAL_SUITE, probe.PERSISTENT_STATE_SUITE):
            relative = "Tests/iOS/yuedu appTests/" + suite + ".swift"
            self.assertIn(relative, probe.SOURCE_INPUTS)
            text = (HERE.parent.parent / relative).read_text(encoding="utf-8")
            # Fixture actors implement ordinary instance methods too; only
            # declarations explicitly carrying Swift Testing's @Test are leaves.
            methods = re.findall(r"(?m)^[ \t]*@Test(?:\([^\n]*\))?[ \t]*\n[ \t]*func[ \t]+(\w+)[ \t]*\(", text)
            self.assertEqual(len(methods), len(set(methods)), suite)
            actual.update(suite + "/" + method for method in methods if suite != probe.PERSISTENT_STATE_SUITE or suite + "/" + method in probe.EXPECTED_CASES["boundmaterials"])
        self.assertEqual(actual, probe.EXPECTED_CASES["boundmaterials"])

    def test_boundmaterials_wrapper_and_workflow_keep_one_cold_result_and_legacy_modes(self):
        wrapper = (HERE / "renewal-probe-tests.sh").read_text(encoding="utf-8")
        branch = re.search(r"if \[\[ \$YUEDU_RENEWAL_SELECTION == boundmaterials \]\]; then\n(.*?)\nfi", wrapper, re.S)
        self.assertIsNotNone(branch)
        body = branch.group(1)
        self.assertEqual(body.count('bash "$REPO_DIR/scripts/xctest.sh"'), 1)
        self.assertIn('-t 2700 --', body)
        self.assertEqual(body.count('-resultBundlePath "$WORK/boundmaterials.xcresult"'), 1)
        selected = set(re.findall(r"-only-testing:'yuedu appTests/([^']+)'", body))
        expected = probe.EXPECTED_CASES["boundmaterials"]
        self.assertEqual({case for case in expected if case in selected or case.split("/")[0] in selected}, expected)
        self.assertNotIn(probe.PERSISTENT_STATE_SUITE, selected)
        self.assertEqual(sum(item.startswith(probe.PERSISTENT_STATE_SUITE + "/") for item in selected), 9)
        for forbidden in (probe.UNIT_SUITE, probe.DISCOVERY_SUITE, probe.REPLACEMENT_SUITE, probe.UI_SUITE):
            self.assertNotIn(forbidden, body)
        self.assertIn('$YUEDU_RENEWAL_SELECTION != boundmaterials', wrapper)
        self.assertIn('if [[ $YUEDU_RENEWAL_SELECTION == all ]]; then REPLACEMENT_TIMEOUT=900; fi', wrapper)
        for mode in ("signature", "cryptography", "sealedmaterials"):
            old = re.search(r"if \[\[ \$YUEDU_RENEWAL_SELECTION == " + mode + r" \]\]; then\n(.*?)\nfi", wrapper, re.S)
            self.assertIsNotNone(old)
            self.assertIn('-t 2700 --', old.group(1))
        workflow = (HERE.parent.parent / ".github/workflows/reader-renewal-probe.yml").read_text(encoding="utf-8")
        self.assertIn('YUEDU_RENEWAL_SELECTION: currentcore', workflow)
        self.assertIn('LEGADO_RUNTIME_SOURCE_ONLY: \'1\'', workflow)
        self.assertIn('463 unique qualified native definitions', workflow)
        self.assertIn('do not establish Apple/device/account authorization', workflow)

    def test_controlledsigning_requires_only_its_twenty_three_exact_native_leaves(self):
        with self.context(), patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": "controlledsigning"}):
            self.built_fixture()
            inputs = smoke.read_json(self.work / "source-inputs.json")
            expected = probe.EXPECTED_CASES["controlledsigning"]
            self.assertEqual(len(inputs["sourceInputs"]), 322)
            self.assertEqual(inputs["intendedTests"], {"controlledsigning": sorted(expected)})
            self.assertEqual(len(expected), 23)
            suites = (probe.IPA_SUITE, probe.VAULT_SUITE, probe.CONTROLLED_SIGNER_SUITE)
            self.assertEqual([sum(case.startswith(suite + "/") for case in expected) for suite in suites], [9, 7, 7])
            self.assertEqual({mode: sum(len(probe.EXPECTED_CASES[group]) for group in groups)
                              for mode, groups in probe.SELECTION_GROUPS.items()},
                             {"all": 30, "replacement": 5, "implementation": 11, "signature": 9,
                              "cryptography": 25, "sealedmaterials": 48, "boundmaterials": 78, "controlledsigning": 23, "integratedrenewal": 140, "transactionrenewal": 178, "handoffrenewal": 253, "currentcore": 463})
            for group in probe.EXPECTED_CASES:
                if group != "controlledsigning":
                    for suffix in ("-summary.json", "-tests.json"):
                        self.write(self.work / (group + suffix), b"unselected evidence is not accepted")
            result = probe.result(self.work)
            self.assertEqual(set(result["targetedTests"]), {"controlledsigning"})
            self.assertEqual(set(result["targetedTests"]["controlledsigning"]["passedCaseIdentifiers"]), expected)
            self.assertEqual(set(result["unselectedTestGroups"]), set(probe.EXPECTED_CASES) - {"controlledsigning"})
            for key in ("iphoneTransportVerified", "selfRenewalVerified", "unattendedRenewalVerified",
                        "physicalDeviceValidationPassed", "appleAccountUsed", "pairingRecordUsed", "ipaGenerated", "ipaUploaded"):
                self.assertIs(result[key], False)
            for mode in probe.SELECTION_GROUPS:
                if mode != "controlledsigning":
                    with patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": mode}), self.assertRaisesRegex(ValueError, "source-input audit"):
                        probe.result(self.work)
            changed = copy.deepcopy(inputs); changed["intendedTests"]["controlledsigning"].pop()
            self.write_json("source-inputs.json", changed)
            with self.assertRaisesRegex(ValueError, "source-input audit"): probe.result(self.work)
            self.write_json("source-inputs.json", inputs)
            summary = smoke.read_json(self.work / "controlledsigning-summary.json")
            for change in ({"totalTestCount": 22}, {"totalTestCount": 24}, {"failedTests": 1},
                           {"skippedTests": 1}, {"passedTests": True}):
                self.write_json("controlledsigning-summary.json", {**summary, **change})
                with self.subTest(change=change), self.assertRaises(ValueError): probe.result(self.work)
            self.write_json("controlledsigning-summary.json", summary)
            for suite in suites:
                tree = self.tree("controlledsigning")
                leaf = next(node for node in tree["testNodes"][0]["children"] if "/" + suite + "/" in node["nodeIdentifier"])
                leaf["result"] = "Skipped"; self.write_json("controlledsigning-tests.json", tree)
                with self.subTest(suite=suite), self.assertRaises(ValueError): probe.result(self.work)
            for suffix in ("-summary.json", "-tests.json"):
                path = self.work / ("controlledsigning" + suffix); original = path.read_bytes(); path.unlink()
                with self.assertRaises(FileNotFoundError): probe.result(self.work)
                self.write(path, original)

    def test_controlledsigning_new_sources_and_existing_keychain_dependency_are_hash_bound(self):
        paths = ("Modules/Services/SelfRenewal/SelfRenewalIPAArchiveValidator.swift",
                 "Modules/Services/SelfRenewal/SelfRenewalIPAUnpacker.swift",
                 "Tests/iOS/yuedu appTests/SelfRenewalIPAArchiveFixture.swift",
                 "Tests/iOS/yuedu appTests/SelfRenewalIPAUnpackerTests.swift",
                 "Modules/Services/SelfRenewal/SelfRenewalSigningMaterialVault.swift",
                 "Tests/iOS/yuedu appTests/SelfRenewalSigningOwnedPKIFixture.swift",
                 "Tests/iOS/yuedu appTests/SelfRenewalSigningMaterialVaultTests.swift",
                 "Modules/Services/SelfRenewal/SelfRenewalControlledMachOSigner.swift",
                 "Tests/iOS/yuedu appTests/SelfRenewalControlledMachOSignerTests.swift",
                 "Tests/iOS/yuedu appTests/SelfRenewalControlledSigningFixture.swift",
                 "Modules/Core/RuleEngine/ModernParser/Login/KeychainHelper.swift",
                 "Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoOriginalModels.swift")
        with self.context(), patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": "controlledsigning"}):
            for path in paths:
                self.assertIn(path, probe.SOURCE_INPUTS)
                self.write(self.root / path, b"changed controlled signing input")
                with self.subTest(path=path), self.assertRaisesRegex(ValueError, "checked-out HEAD"): probe.prepare(self.work)
                self.assertFalse((self.work / "source-inputs.json").exists())
                self.write(self.root / path, self.originals[path])
            self.built_fixture(); inputs = smoke.read_json(self.work / "source-inputs.json")
            for path in paths:
                for change in ("digest", "remove"):
                    altered = copy.deepcopy(inputs)
                    item = next(item for item in altered["sourceInputs"] if item["path"] == path)
                    if change == "digest": item["sha256"] = "0" * 64
                    else: altered["sourceInputs"].remove(item)
                    self.write_json("source-inputs.json", altered)
                    with self.subTest(path=path, change=change), self.assertRaisesRegex(ValueError, "source-input audit"):
                        probe.result(self.work)
            self.write_json("source-inputs.json", inputs)

    def test_controlledsigning_source_methods_wrapper_and_workflow_keep_sdk_groups_independent(self):
        actual = set()
        for suite in (probe.IPA_SUITE, probe.VAULT_SUITE, probe.CONTROLLED_SIGNER_SUITE):
            relative = "Tests/iOS/yuedu appTests/" + suite + ".swift"
            self.assertIn(relative, probe.SOURCE_INPUTS)
            source = (HERE.parents[1] / relative).read_text(encoding="utf-8")
            methods = re.findall(r"(?m)^[ \t]*@Test(?:\([^\n]*\))?[ \t]*\n[ \t]*func[ \t]+(\w+)[ \t]*\(", source)
            actual.update(suite + "/" + method for method in methods)
        # The same Vault suite now also declares the explicitly current-core
        # CSR/baseline cases. Preserve the historical23 qualified methods while
        # rejecting a missing old method or any unaccounted new declaration.
        current_only = {case for case in probe.CURRENTCORE_ACCOUNT_QUALIFIED_CASES
                        if case.startswith(probe.VAULT_SUITE + "/")}
        self.assertEqual(len(current_only), 4)
        self.assertTrue(current_only <= probe.EXPECTED_CASES["currentcore"])
        self.assertTrue(current_only.isdisjoint(probe.EXPECTED_CASES["controlledsigning"]))
        self.assertEqual(actual, probe.EXPECTED_CASES["controlledsigning"] | current_only)
        wrapper = (HERE / "renewal-probe-tests.sh").read_text(encoding="utf-8")
        branch = re.search(r"if \[\[ \$YUEDU_RENEWAL_SELECTION == controlledsigning \]\]; then\n(.*?)\nfi", wrapper, re.S)
        self.assertIsNotNone(branch); body = branch.group(1)
        self.assertEqual(body.count('bash "$REPO_DIR/scripts/xctest.sh"'), 1)
        self.assertIn('-t 2700 --', body)
        self.assertEqual(body.count('-resultBundlePath "$WORK/controlledsigning.xcresult"'), 1)
        selectors = re.findall(r"-only-testing:'yuedu appTests/([^']+)'", body)
        historical_vault = {case for case in probe.EXPECTED_CASES['controlledsigning'] if case.startswith(probe.VAULT_SUITE + '/')}
        self.assertEqual(len(selectors), len(set(selectors)))
        self.assertEqual(set(selectors), {probe.IPA_SUITE, probe.CONTROLLED_SIGNER_SUITE} | historical_vault)
        expanded = [case for selector in selectors for case in actual
                    if case == selector or case.split('/')[0] == selector]
        self.assertEqual(len(expanded), len(set(expanded)))
        self.assertEqual(set(expanded), probe.EXPECTED_CASES['controlledsigning'])
        self.assertIn('$YUEDU_RENEWAL_SELECTION != controlledsigning', wrapper)
        self.assertIn('if [[ $YUEDU_RENEWAL_SELECTION == all ]]; then REPLACEMENT_TIMEOUT=900; fi', wrapper)
        self.assertNotIn('LegadoOriginalAPITests', body)
        workflow = (HERE.parents[1] / ".github/workflows/reader-renewal-probe.yml").read_text(encoding="utf-8")
        self.assertIn('YUEDU_RENEWAL_SELECTION: currentcore', workflow)
        self.assertIn('463 unique qualified native definitions', workflow)
        self.assertIn('ten-case source-only SwiftPM pass at a835f8b', workflow)
        self.assertIn('unattended renewal', workflow.lower())


    def test_integrated_leaf_union_matches_source_and_excludes_storage_benchmark(self):
        expected = probe.EXPECTED_CASES["integratedrenewal"]
        self.assertEqual(len(expected), 140)
        additional = {suite + "/" + method for suite, methods in probe.INTEGRATED_ADDITIONAL_CASES.items() for method in methods}
        self.assertEqual(len(additional), 39)
        self.assertEqual(expected, probe.EXPECTED_CASES["boundmaterials"] | probe.EXPECTED_CASES["controlledsigning"] |
                         additional)
        self.assertEqual(len(probe.SOURCE_INPUTS), 322)
        self.assertEqual(len(set(probe.SOURCE_INPUTS)), 322)
        for path in probe.SOURCE_INPUTS:
            self.assertTrue((HERE.parents[1] / path).is_file(), path)
        selected_suites = {case.split("/")[0] for case in expected}
        actual = set(); available = set()
        for suite in selected_suites:
            source = (HERE.parents[1] / ("Tests/iOS/yuedu appTests/" + suite + ".swift")).read_text(encoding="utf-8")
            methods = re.findall(r"(?m)^[ \t]*@Test(?:\([^\n]*\))?[ \t]*\n[ \t]*func[ \t]+(\w+)[ \t]*\(", source)
            available.update(suite + "/" + method for method in methods)
            if suite == probe.BOOK_STORAGE_SUITE:
                self.assertEqual(len(methods), 13)
                methods = [method for method in methods if "benchmark" not in method.lower()]
                self.assertEqual(len(methods), 12)
            if suite == probe.VAULT_SUITE:
                current_only = {case for case in probe.CURRENTCORE_ACCOUNT_QUALIFIED_CASES
                                if case.startswith(suite + "/")}
                historical = {case for case in expected if case.startswith(suite + "/")}
                self.assertEqual(len(current_only), 4)
                self.assertTrue(current_only <= probe.EXPECTED_CASES["currentcore"])
                self.assertTrue(current_only.isdisjoint(expected))
                self.assertEqual({suite + "/" + method for method in methods}, historical | current_only)
                methods = [method for method in methods if suite + "/" + method not in current_only]
            actual.update(suite + "/" + method for method in methods if suite != probe.PERSISTENT_STATE_SUITE or suite + "/" + method in expected)
        self.assertEqual(actual, expected)
        wrapper = (HERE / "renewal-probe-tests.sh").read_text(encoding="utf-8")
        branches = re.findall(r"if \[\[ \$YUEDU_RENEWAL_SELECTION == integratedrenewal \]\]; then\n(.*?)\nfi", wrapper, re.S)
        selected_branches = [body for body in branches if "INTEGRATED_TESTS=(" in body]
        self.assertEqual(len(selected_branches), 1)
        body = selected_branches[0]
        self.assertEqual(body.count('bash "$REPO_DIR/scripts/xctest.sh"'), 1)
        self.assertEqual(body.count('-resultBundlePath "$WORK/integratedrenewal.xcresult"'), 1)
        self.assertIn('-t 2700 --', body)
        self.assertNotIn('benchmark', body.lower())
        self.assertNotIn('original-api-package-tests.sh', body)
        selectors = re.findall(r"-only-testing:'yuedu appTests/([^']+)'", body)
        self.assertEqual(len(selectors), len(set(selectors)))
        selected = set(selectors)
        expanded = [case for selector in selectors for case in available
                    if case == selector or case.split("/")[0] == selector]
        self.assertEqual(len(expanded), len(set(expanded)))
        self.assertEqual(set(expanded), expected)
        self.assertEqual(len([item for item in selected if item.startswith(probe.BOOK_STORAGE_SUITE + "/")]), 12)
        self.assertLess(wrapper.index('export DEVELOPER_DIR='), wrapper.index('generate-sdk-owned-package.py'))
        self.assertLess(wrapper.index('stage-sdk-fixture'), wrapper.index('INTEGRATED_TESTS=('))
        self.assertIn('SDK_PRODUCED="$REPO_DIR/.build/reader-renewal-sdk-produced-public"', wrapper)
        workflow = (HERE.parents[1] / '.github/workflows/reader-renewal-probe.yml').read_text(encoding="utf-8")
        self.assertIn("env.YUEDU_RENEWAL_SELECTION == 'controlledsigning'", workflow)
        self.assertNotIn('.build/reader-renewal-sdk-produced-public/', workflow)
        loader = (HERE.parents[1] / 'Tests/iOS/yuedu appTests/SelfRenewalSDKOwnedPackageFixture.swift').read_text(encoding="utf-8")
        self.assertIn(probe.SDK_MARKER + ' resourceSHA256=', loader)
        self.assertIn('SHA256.hash(data: raw)', loader)

    def test_integrated_result_requires_actual_resource_chain_and_preserves_unverified_boundaries(self):
        with self.context(), patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": "integratedrenewal", "DEVELOPER_DIR": "owned-toolchain"}):
            self.built_fixture()
            with self.assertRaises(FileNotFoundError): probe.result(self.work)
            self.sdk_runtime_fixture()
            result = probe.result(self.work)
            self.assertEqual(result['targetedTests']['integratedrenewal']['totalTestCount'], 140)
            self.assertEqual(set(result['targetedTests']), {'integratedrenewal'})
            self.assertEqual(result['sdkFixtureRuntimeEvidence']['requiredSDKCasePassed'], probe.SDK_REQUIRED_CASE)
            self.assertIs(result['ipaGenerated'], True)
            self.assertIs(result['ipaUploaded'], True)
            self.assertEqual(result['ipaKind'], 'owned-sdk-fixture-only')
            for key in ('distributionIPAGenerated', 'iphoneTransportVerified', 'selfRenewalVerified',
                        'unattendedRenewalVerified', 'physicalDeviceValidationPassed', 'appleAccountUsed', 'pairingRecordUsed'):
                self.assertIs(result[key], False)
            for phase in ('before-build', 'after-tests'):
                with self.assertRaises(FileExistsError): probe.verify_sdk_fixture(self.work, phase)
            for name in ('sdk-fixture-binding.json', 'sdk-fixture-before-build.json', 'sdk-fixture-after-tests.json', 'sdk-test-build-settings.json'):
                self.assertIn(name, result['evidenceSHA256'])
            with patch.dict(os.environ, {'DEVELOPER_DIR': 'different-toolchain'}), self.assertRaisesRegex(ValueError, 'binding changed'):
                probe.result(self.work)

    def test_integrated_runtime_rejects_missing_stale_malformed_or_excess_loader_markers(self):
        with self.context(), patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": "integratedrenewal", "DEVELOPER_DIR": "owned-toolchain"}):
            self.built_fixture(); self.sdk_runtime_fixture()
            path = self.work / 'integratedrenewal-tests.log'; original = path.read_bytes()
            for changed in (b'no actual loader was called', probe.SDK_MARKER.encode(),
                            original.replace(b'resourceSHA256=', b'resourceSHA256=0'),
                            original.replace(b'archiveBytes=', b'archiveBytes=1'), original * 17):
                self.write(path, changed)
                with self.subTest(changed=changed[:80]), self.assertRaises(ValueError): probe.result(self.work)
            self.write(path, original)
            self.assertEqual(probe.result(self.work)['status'], 'passed')
            tree = self.tree('integratedrenewal')
            node = next(node for node in tree['testNodes'][0]['children'] if probe.SDK_REQUIRED_CASE in node['nodeIdentifier'])
            node['result'] = 'Skipped'; self.write_json('integratedrenewal-tests.json', tree)
            with self.assertRaises(ValueError): probe.result(self.work)

    def test_integrated_resource_and_generated_public_bytes_cannot_change_before_or_after_execution(self):
        with self.context(), patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": "integratedrenewal", "DEVELOPER_DIR": "owned-toolchain"}):
            self.built_fixture(); _, bundle = self.sdk_runtime_fixture()
            paths = [self.root / probe.SDK_RESOURCE, bundle / 'owned-sdk-package.json',
                     self.work / 'sdk-produced-public/main.macho', self.work / 'sdk-produced-public/owned-sdk-package.ipa',
                     self.work / 'sdk-produced-public/sdk-produced-fixture-manifest.json']
            for path in paths:
                original = path.read_bytes(); path.chmod(0o644); self.write(path, original + b' ')
                with self.subTest(path=path.name), self.assertRaises(ValueError): probe.result(self.work)
                self.write(path, original)
            extra = self.work / 'sdk-produced-public/unreviewed.key'; self.write(extra, b'unexpected')
            with self.assertRaisesRegex(ValueError, 'non-public'): probe.result(self.work)
            extra.unlink()
            self.assertEqual(probe.result(self.work)['status'], 'passed')

    def test_integrated_producer_metadata_cannot_bypass_real_raw_output_checks_or_leak_private_data(self):
        with self.context(), patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": "integratedrenewal", "DEVELOPER_DIR": "owned-toolchain"}):
            probe.prepare(self.work); produced = self.sdk_public_fixture()
            inputs = smoke.read_json(self.work / 'source-inputs.json')['sourceInputs']
            path = produced / 'sdk-produced-fixture-manifest.json'; original = path.read_bytes(); baseline = json.loads(original)
            for changed in ({'temporaryOwnedKeychainDeleted': False}, {'privateMaterialArtifacts': 1},
                            {'sourceInputs': []}, {'commands': []}, {'publicOutputs': baseline['publicOutputs'][:-1]},
                            {'archiveSHA256': '0' * 64}, {'actualSDKProducedMachOs': []}):
                self.write(path, json.dumps({**baseline, **changed}).encode())
                with self.subTest(changed=list(changed)), self.assertRaises(ValueError): probe._verify_sdk_public(produced, inputs)
            self.write(path, original)
            data_path = produced / 'openssl-version.log'; data_original = data_path.read_bytes()
            private = b'-----BEGIN PRIVATE KEY-----\nhermetic refusal\n-----END PRIVATE KEY-----'
            self.write(data_path, private)
            changed = copy.deepcopy(baseline)
            entry = next(item for item in changed['publicOutputs'] if item['path'] == data_path.name)
            entry.update(bytes=len(private), sha256=hashlib.sha256(private).hexdigest())
            self.write(path, json.dumps(changed).encode())
            with self.assertRaisesRegex(ValueError, 'Private material'): probe.stage_sdk_fixture(self.work, produced)
            self.assertFalse((self.work / 'sdk-produced-public').exists())
            self.assertFalse((self.root / probe.SDK_RESOURCE).exists())
            self.write(path, original); self.write(data_path, data_original)
            binding = probe.stage_sdk_fixture(self.work, produced)
            self.assertEqual(len(binding['publicOutputs']), 43)
            with self.assertRaisesRegex(ValueError, 'replace existing'): probe.stage_sdk_fixture(self.work, produced)

    def test_integrated_dependencies_remain_exactly_source_bound_after_staging(self):
        paths = ('Modules/Services/SelfRenewal/SelfRenewalControlledPackageSigner.swift',
                 'Modules/Services/SelfRenewal/SelfRenewalAuthenticatedInstallationClient.swift',
                 'Tests/iOS/yuedu appTests/SelfRenewalSDKOwnedPackageFixture.swift',
                 'Modules/Services/Online/LegadoBookStateOwner.swift',
                 'Modules/Services/LibraryStore/BookChapterStore.swift',
                 'Modules/Services/Online/ChapterCacheRepository.swift',
                 probe.SDK_TOOL_ROOT + 'generate-sdk-owned-package.py',
                 probe.SDK_TOOL_ROOT + 'ImportOwnedIdentity.swift',
                 probe.SDK_TOOL_ROOT + 'OwnedIdentitySearch.h',
                 probe.SDK_TOOL_ROOT + 'OwnedIdentitySearch.c',
                 probe.SDK_TOOL_ROOT + 'framework.c')
        with self.context(), patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": "integratedrenewal", "DEVELOPER_DIR": "owned-toolchain"}):
            for path in paths:
                self.write(self.root / path, b'changed integrated dependency')
                with self.subTest(path=path), self.assertRaisesRegex(ValueError, 'checked-out HEAD'): probe.prepare(self.work)
                self.write(self.root / path, self.originals[path])
            self.built_fixture(); self.sdk_runtime_fixture()
            inputs = smoke.read_json(self.work / 'source-inputs.json')
            for path in paths:
                changed = copy.deepcopy(inputs)
                changed['sourceInputs'] = [item for item in changed['sourceInputs'] if item['path'] != path]
                self.write_json('source-inputs.json', changed)
                with self.subTest(path=path), self.assertRaisesRegex(ValueError, 'source-input audit'): probe.result(self.work)
            self.write_json('source-inputs.json', inputs)
            self.assertEqual(probe.result(self.work)['status'], 'passed')


    def test_transaction_union_has_178_definitions_and_180_exact_bool_leaves(self):
        expected = probe.EXPECTED_CASES['transactionrenewal']
        self.assertEqual(len(expected), 178)
        self.assertEqual(probe.expected_leaf_count('transactionrenewal'), 180)
        self.assertEqual(expected - probe.EXPECTED_CASES['integratedrenewal'],
                         {suite + '/' + method for suite, methods in probe.TRANSACTION_ADDITIONAL_CASES.items() for method in methods})
        self.assertEqual(len(expected - probe.EXPECTED_CASES['integratedrenewal']), 38)
        checked = probe.verify_cases(self.tree('transactionrenewal'), 'transactionrenewal')
        self.assertEqual(len(checked['passedMethodIdentifiers']), 178)
        self.assertEqual(len(checked['passedCaseIdentifiers']), 180)
        self.assertEqual(len(set(checked['passedCaseIdentifiers'])), 180)
        for row in checked['passedArgumentCases']:
            self.assertEqual(sorted(row['values']), ['false', 'true'])
            self.assertEqual(row['parameter'], 'interrupt')
        for suite, methods in probe.TRANSACTION_ADDITIONAL_CASES.items():
            source = (HERE.parents[1] / ('Tests/iOS/yuedu appTests/' + suite + '.swift')).read_text(encoding='utf-8')
            declared = set(re.findall(r'\bfunc (\w+)\s*\(', source))
            self.assertLessEqual(set(methods), declared)
        for suite, method in (case.split('/') for case in probe.PARAMETER_CASES):
            source = (HERE.parents[1] / ('Tests/iOS/yuedu appTests/' + suite + '.swift')).read_text(encoding='utf-8')
            self.assertRegex(source, r'@Test[^\n]*arguments: \[false, true\]\)[^\n]*\n\s*func ' + method + r'\(interrupt: Bool\)')

    def test_transaction_rejects_duplicate_missing_renamed_or_skipped_argument_executions(self):
        for method in probe.PARAMETER_CASES:
            for mutation in ('missing', 'duplicate-value', 'unknown', 'bool-number', 'skipped', 'failed', 'duplicate-run', 'repetition', 'display-only'):
                tree = self.tree('transactionrenewal')
                parent = next(node for node in probe._test_nodes(tree) if probe._qualified_method(node['nodeIdentifier']) == method)
                args = parent['children']
                if mutation == 'missing': args.pop()
                elif mutation == 'duplicate-value': args[1]['name'] = args[0]['name']
                elif mutation == 'unknown': args[0]['name'] = 'other: false'
                elif mutation == 'bool-number': args[0]['name'] = '0'
                elif mutation in ('skipped', 'failed'): args[0]['result'] = mutation.title()
                elif mutation == 'duplicate-run': args[0]['children'].append(copy.deepcopy(args[0]['children'][0]))
                elif mutation == 'repetition': args[0]['children'][0]['nodeType'] = 'Repetition'
                elif mutation == 'display-only': args[0]['nodeType'] = 'Test Value'
                with self.subTest(method=method, mutation=mutation), self.assertRaises(ValueError):
                    probe.verify_cases(tree, 'transactionrenewal')
        tree = self.tree('transactionrenewal'); tree['testNodes'][0]['children'].append(copy.deepcopy(tree['testNodes'][0]['children'][0]))
        with self.assertRaises(ValueError): probe.verify_cases(tree, 'transactionrenewal')
        tree = self.tree('transactionrenewal'); node = tree['testNodes'][0]['children'][0]; node['nodeIdentifier'] = 'wrongSuite/wrongMethod()'
        with self.assertRaises(ValueError): probe.verify_cases(tree, 'transactionrenewal')

    def test_transaction_result_binds_native_exit_arguments_details_and_sdk_resource(self):
        with self.context(), patch.dict(os.environ, {'YUEDU_RENEWAL_SELECTION': 'transactionrenewal', 'DEVELOPER_DIR': 'owned-toolchain'}):
            self.built_fixture(); self.sdk_runtime_fixture(); self.transaction_details_fixture()
            result = probe.result(self.work)
            self.assertEqual(result['targetedTests']['transactionrenewal']['totalTestCount'], 180)
            self.assertEqual(result['targetedTests']['transactionrenewal']['expectedQualifiedMethodDefinitions'], 178)
            for key in ('selfRenewalVerified', 'unattendedRenewalVerified', 'physicalDeviceValidationPassed', 'iphoneTransportVerified'):
                self.assertIs(result[key], False)
            path = self.work / 'transactionrenewal-extraction.json'; original = path.read_bytes(); baseline = json.loads(original)
            for native_exit in (65, 124, 1):
                self.write(path, json.dumps({**baseline, 'originalXCTestExitCode': native_exit}).encode())
                with self.subTest(exit=native_exit), self.assertRaises(ValueError): probe.result(self.work)
            self.write(path, original)
            for changed in ({'commands': baseline['commands'][:-1]}, {'parameterExports': baseline['parameterExports'][:1]}):
                self.write(path, json.dumps({**baseline, **changed}).encode())
                with self.assertRaises(ValueError): probe.result(self.work)
            self.write(path, original)
            detail = self.work / 'transaction-parameter-0.json'; original_detail = detail.read_bytes(); detail.write_bytes(original_detail.replace(b'Passed', b'Skipped'))
            with self.assertRaises(ValueError): probe.result(self.work)
            detail.write_bytes(original_detail)
            inputs = smoke.read_json(self.work / 'source-inputs.json'); altered = copy.deepcopy(inputs)
            altered['intendedArgumentCases'][next(iter(probe.PARAMETER_CASES))]['values'] = [True, True]
            self.write_json('source-inputs.json', altered)
            with self.assertRaisesRegex(ValueError, 'argument source-input audit'): probe.result(self.work)
            self.write_json('source-inputs.json', inputs)
            self.assertEqual(probe.result(self.work)['status'], 'passed')

    def test_transaction_collector_preserves_actual_failure_and_partial_raw_exports(self):
        with self.context(), patch.dict(os.environ, {'YUEDU_RENEWAL_SELECTION': 'transactionrenewal'}):
            probe.prepare(self.work)
            def capture(argv, target, **kwargs):
                if '--help' in argv: raw = b'nodeIdentifier result Arguments testIdentifier testResult testRuns'
                elif 'summary' in argv: raw = b'{"totalTestCount":0,"passedTests":0,"failedTests":0,"skippedTests":0}'
                else: raw = b'{"testNodes":[]}'
                self.write(target, raw); self.write(target.with_suffix(target.suffix + '.stderr.log'), b'')
                return {'argv': argv, 'exitCode': 0, 'timedOut': False, 'oversized': False, 'output': target.name}
            with patch.object(probe, '_capture_xcresult', side_effect=capture):
                record = probe.collect_xcresult(self.work, 'transactionrenewal', 65)
            self.assertEqual(record['originalXCTestExitCode'], 65)
            self.assertTrue((self.work / 'transactionrenewal-tests.json').exists())
            self.assertTrue((self.work / 'transactionrenewal-summary.json').exists())
            self.assertIn('error', record['parameterExports'][0])
            with self.assertRaises(ValueError): probe.verify_cases(smoke.read_json(self.work / 'transactionrenewal-tests.json'), 'transactionrenewal')

    def test_bounded_export_runs_real_owned_child_and_retains_nonzero_timeout_and_size_outcomes(self):
        self.work.mkdir(parents=True)
        row = probe._capture_xcresult([sys.executable, '-c', 'import sys;print("owned compile error");sys.exit(65)'], self.work / 'nonzero.log', seconds=5)
        self.assertEqual(row['exitCode'], 65); self.assertIs(row['timedOut'], False)
        self.assertEqual((self.work / 'nonzero.log').read_bytes().strip(), b'owned compile error')
        row = probe._capture_xcresult([sys.executable, '-c', 'import sys;sys.stdout.buffer.write(b"x"*65536)'], self.work / 'oversize.log', seconds=5, maximum=1024)
        self.assertIs(row['oversized'], True)
        self.assertLessEqual((self.work / 'oversize.log').stat().st_size, 1024)
        row = probe._capture_xcresult([sys.executable, '-c', 'import threading;threading.Event().wait()'], self.work / 'timeout.log', seconds=0.1)
        self.assertIs(row['timedOut'], True)

    def test_transaction_wrapper_is_one_cold_run_retains_failure_exit_and_rechecks_independent_spm(self):
        wrapper = (HERE / 'renewal-probe-tests.sh').read_text(encoding='utf-8')
        body = re.search(r'if \[\[ \$YUEDU_RENEWAL_SELECTION == transactionrenewal \]\]; then\n(.*?)\nfi', wrapper, re.S)[1]
        self.assertEqual(body.count('bash "$REPO_DIR/scripts/xctest.sh"'), 1)
        self.assertEqual(body.count('-resultBundlePath "$WORK/transactionrenewal.xcresult"'), 1)
        self.assertIn('-t 2700 --', body)
        selectors = set(re.findall(r"-only-testing:'yuedu appTests/([^']+)'", body))
        expected = {case + ('(interrupt:)' if case in probe.PARAMETER_CASES else '') for case in probe.EXPECTED_CASES['transactionrenewal']}
        self.assertEqual(selectors, expected)
        self.assertIn('NATIVE_EXIT=$?', body)
        self.assertIn('EXPORT_EXIT=$?', body)
        self.assertLess(body.index('collect-xcresult'), body.index('[[ $NATIVE_EXIT == 0 ]] || exit "$NATIVE_EXIT"'))
        self.assertLess(body.index('[[ $NATIVE_EXIT == 0 ]]'), body.index('[[ $EXPORT_EXIT == 0 ]]'))
        self.assertNotIn('benchmark', body.lower())
        self.assertNotIn('SelfRenewalProbeUITests', body)
        self.assertIn('trap preserve_failed_xcresults EXIT', wrapper)
        workflow = (HERE.parents[1] / '.github/workflows/reader-renewal-probe.yml').read_text(encoding='utf-8')
        self.assertIn("env.YUEDU_RENEWAL_SELECTION == 'transactionrenewal'", workflow)
        self.assertIn("!cancelled() && steps.toolchain.outcome == 'success'", workflow)
        self.assertIn('private keys/P12/passwords are never artifact members', workflow)
        self.assertIn('original-api-package-tests.sh', workflow)
        self.assertEqual(len(probe.SOURCE_INPUTS), 322)
        self.assertEqual(len(set(probe.SOURCE_INPUTS)), 322)
        for path in probe.SOURCE_INPUTS: self.assertTrue((HERE.parents[1] / path).is_file(), path)


    def handoff_ledger_fixture(self):
        """Portable fabricated evidence exercises guards; it is never SDK proof."""
        source = probe._handoff_source_state(self.work)
        rows = []
        commands = probe._handoff_commands(self.work, 0)
        for name, timeout in zip(probe.HANDOFF_PHASES, probe.HANDOFF_TIMEOUTS):
            output = probe._handoff_output(self.work, name)
            if not output.exists(): self.write(output, b"guard phase output\n")
            if name == 'native': self.write(output, b'xcodebuild status: 0; wrapper verdict stop: false\n')
            raw = output.read_bytes(); stderr = output.with_suffix(output.suffix + '.stderr.log')
            self.write(stderr, b'')
            command = {'argv': commands[name], 'exitCode': 0, 'timedOut': False, 'oversized': False,
                       'output': output.name, 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(),
                       'stderr': stderr.name, 'stderrBytes': 0, 'stderrSHA256': hashlib.sha256(b'').hexdigest()}
            row = {'schemaVersion': 1, 'phase': name, 'timeoutSeconds': timeout, 'sourceBefore': source,
                   'sourceAfter': source, 'state': 'succeeded', 'blockedBy': [], 'intendedArgv': commands[name],
                   'command': command, 'elapsedSeconds': 0.1}
            if name == 'native':
                raw = (self.work/'handoffrenewal-tests.log').read_bytes()
                row['nativeLog'] = {'path': 'handoffrenewal-tests.log', 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
                row['reportedXcodebuildStatuses'] = [{'exitCode': 0, 'wrapperVerdictStop': False}]
                row['wrapperReportedBudgetTimeout'] = False
            self.write_json('handoff-phase-' + name + '.json', row); rows.append(row)
        ledger = {'schemaVersion': 1, 'selectionMode': 'handoffrenewal', 'source': source,
                  'qualifiedMethodDefinitions': 253, 'argumentLeaves': 255, 'phaseOrder': list(probe.HANDOFF_PHASES),
                  'phases': rows, 'firstFailure': None, 'allPhasesSucceeded': True}
        self.write_json('historical-package-evidence.json', probe.historical_package_evidence())
        ledger['phaseRecords']=[probe._handoff_fact(self.work,'handoff-phase-'+name+'.json') for name in probe.HANDOFF_PHASES]
        ledger['historicalPackageEvidence']=probe._handoff_fact(self.work,'historical-package-evidence.json')
        self.write_json('handoff-pipeline.json', ledger)
        return ledger

    def test_handoff_exact_union_preserves_all_prior_methods_and_both_bool_leaves(self):
        expected = probe.EXPECTED_CASES['handoffrenewal']
        self.assertEqual(expected, probe.EXPECTED_CASES['transactionrenewal'] | probe.HANDOFF_ADDITIONAL_CASES)
        self.assertEqual(sum(map(len, probe.HANDOFF_NEW_CASES.values())), 27)
        self.assertEqual(sum(map(len, probe.HANDOFF_REGRESSION_CASES.values())), 17)
        self.assertEqual(len(expected), 253); self.assertEqual(probe.expected_leaf_count('handoffrenewal'), 255)
        self.assertIn(probe.SDK_REQUIRED_CASE, expected)
        self.assertEqual(probe.expected_leaf_count('transactionrenewal'), 180)
        self.assertEqual(len(probe.EXPECTED_CASES['integratedrenewal']), 140)
        actual = set()
        for suite in set(probe.HANDOFF_NEW_CASES) | set(probe.HANDOFF_REGRESSION_CASES) | set(probe.HANDOFF_COOKIE_READ_CASES):
            paths = probe.HANDOFF_TEST_SOURCE_PATHS.get(suite, ('Tests/iOS/yuedu appTests/' + suite + '.swift',))
            source = ''
            for relative in paths:
                self.assertIn(relative, probe.SOURCE_INPUTS)
                part = (HERE.parents[1] / relative).read_text(encoding='utf-8')
                self.assertRegex(part, r'(?m)^(?:final class|struct|extension) ' + re.escape(suite) + r'\b')
                source += part + '\n'
            methods = set(re.findall(r'(?m)^\s*func\s+(\w+)\s*\(', source))
            selected = set(probe.HANDOFF_NEW_CASES.get(suite, [])) | set(probe.HANDOFF_REGRESSION_CASES.get(suite, [])) | set(probe.HANDOFF_COOKIE_READ_CASES.get(suite, []))
            self.assertLessEqual(selected, methods)
            if suite.startswith('ReadingPosition'):
                self.assertEqual(selected, {name for name in methods if name.startswith('test')})
            elif suite in probe.HANDOFF_NEW_CASES:
                self.assertEqual(selected,set(re.findall(r'(?m)^\s*@Test(?:\([^\n]*\))?\s*\n\s*func\s+(\w+)\s*\(',source)))
            actual |= {suite+'/'+name for name in selected}
        for table in (probe.HANDOFF_COOKIE_NEW_CASES,probe.HANDOFF_COOKIE_REGRESSION_CASES):
            for suite,names in table.items():
                relative=probe.HANDOFF_COOKIE_SOURCE_PATHS.get(suite,'Tests/iOS/yuedu appTests/'+suite+'.swift')
                self.assertIn(relative,probe.SOURCE_INPUTS)
                source=(HERE.parents[1]/relative).read_text(encoding='utf-8')
                methods=set(re.findall(r'(?m)^\s*func\s+(\w+)\s*\(',source))
                self.assertLessEqual(set(names),methods)
                actual|={suite+'/'+name for name in names}
        self.assertEqual(sum(map(len,probe.HANDOFF_COOKIE_NEW_CASES.values())),13)
        self.assertEqual(sum(map(len,probe.HANDOFF_COOKIE_REGRESSION_CASES.values())),16)
        self.assertEqual(actual, probe.HANDOFF_ADDITIONAL_CASES)
        self.assertNotIn('ReadingPositionWriteOrderingTests', {case.split('/')[0] for case in expected})
        self.assertEqual(len([case for case in expected if case.startswith('ReadingPositionStorePersistenceTests/')]), 16)
        wrong_suite = self.tree('handoffrenewal')
        row = next(row for row in wrong_suite['testNodes'][0]['children']
                   if '/testCheckedAdmissionCompletesAfterCancellationBehindTheExistingWriter()' in row['nodeIdentifier'])
        row['nodeIdentifier'] = row['nodeIdentifier'].replace('ReadingPositionStorePersistenceTests/', 'ReadingPositionWriteOrderingTests/')
        with self.assertRaises(ValueError): probe.verify_cases(wrong_suite, 'handoffrenewal')
        checked = probe.verify_cases(self.tree('handoffrenewal'), 'handoffrenewal')
        self.assertEqual(checked['expectedTests'], 255)
        for mode in probe.SELECTION_GROUPS:
            if mode == 'handoffrenewal': continue
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                group = next(iter(probe.SELECTION_GROUPS[mode]))
                probe.verify_cases(self.tree('handoffrenewal'), group)
        for change in ('missing', 'duplicate', 'skip', 'wrongValue', 'requiredSDK'):
            tree = self.tree('handoffrenewal'); nodes = tree['testNodes'][0]['children']
            if change == 'missing': nodes.pop()
            elif change == 'duplicate': nodes.append(copy.deepcopy(nodes[0]))
            elif change == 'skip': nodes[0]['result'] = 'Skipped'
            elif change == 'requiredSDK': nodes[:] = [node for node in nodes if probe.SDK_REQUIRED_CASE not in node['nodeIdentifier']]
            else: next(node for node in nodes if '(interrupt:)' in node['nodeIdentifier'])['children'][0]['name'] = 'unknown'
            with self.subTest(change=change), self.assertRaises(ValueError): probe.verify_cases(tree, 'handoffrenewal')

    def test_handoff_commands_wrapper_workflow_bind_one_complete_native_and_separate_history(self):
        with self.context(), patch.dict(os.environ, {'YUEDU_RENEWAL_SELECTION': 'handoffrenewal'}):
            commands = probe._handoff_commands(self.work)
            native = commands['native']
            self.assertEqual(native.count('-resultBundlePath'), 1)
            self.assertEqual(native[native.index('-t')+1], '2700')
            selected = [value.removeprefix('-only-testing:yuedu appTests/') for value in native if value.startswith('-only-testing:')]
            expected = {case + ('(interrupt:)' if case in probe.PARAMETER_CASES else '') for case in probe.EXPECTED_CASES['handoffrenewal']}
            self.assertEqual(set(selected), expected); self.assertEqual(len(selected), 253)
            self.assertNotIn('test', commands['build-settings'])
            self.assertEqual(commands['test-settings'][-1], 'test')
            self.assertIn('-showBuildSettings', commands['test-settings'])
        wrapper = (HERE/'renewal-probe-tests.sh').read_text(encoding='utf-8')
        branch = re.search(r'if \[\[ \$YUEDU_RENEWAL_SELECTION == handoffrenewal \]\]; then\n(.*?)\nfi', wrapper, re.S)[1]
        self.assertIn('run-handoff --work', branch); self.assertIn('exit $?', branch)
        self.assertLess(wrapper.index('run-handoff --work'), wrapper.index('generate-sdk-owned-package.py'))
        workflow = (HERE.parents[1]/'.github/workflows/reader-renewal-probe.yml').read_text(encoding='utf-8')
        self.assertIn('YUEDU_RENEWAL_SELECTION: currentcore', workflow)
        self.assertIn('466 exact execution leaves', workflow)
        self.assertIn("env.YUEDU_RENEWAL_SELECTION == 'handoffrenewal'", workflow)
        self.assertIn("steps.source.outcome == 'success'", workflow)
        self.assertIn("YUEDU_RENEWAL_PORTABLE_GUARDS_OUTCOME: ${{ steps.guards.outcome }}", workflow)
        self.assertNotIn('.build/reader-renewal-sdk-produced-public/', workflow)
        self.assertIn('test-producer-timeouts.py', workflow)

    def test_handoff_pipeline_preserves_real_first_failure_and_still_runs_full_native_once(self):
        for failure_phase in ('producer','stage'):
            with self.subTest(firstFailure=failure_phase):
                self.root=Path(self.temp.name).resolve()/failure_phase
                for path,raw in self.originals.items(): self.write(self.root/path,raw)
                self.work=self.root/'.build'/('handoff-'+failure_phase)
                with self.context(), patch.dict(os.environ, {'YUEDU_RENEWAL_SELECTION': 'handoffrenewal'}):
                    probe.prepare(self.work)
                    self.write(self.work/'xcode-version.log',b'Portable guard version fixture; no SDK executed\n')
                    source = probe._handoff_source_state(self.work)
                    # Actual portable child exits exercise the pipeline; these children
                    # are not codesign/XCTest and cannot produce SDK acceptance.
                    invoked = []
                    def capture(argv, output, **options):
                        name = output.name.removeprefix('handoff-').removesuffix('.log')
                        invoked.append(name)
                        status = 7 if name == failure_phase else 65 if name == 'native' else 0
                        return original_capture([sys.executable, '-c', 'import sys;print("portable phase");sys.exit('+str(status)+')'], output, **options)
                    original_capture = probe._capture_xcresult
                    with patch.object(probe, 'historical_package_evidence', return_value={'historicalOnly': True}), patch.object(probe, '_capture_xcresult', side_effect=capture):
                        completed = probe.run_handoff(self.work)
                    self.assertEqual(completed['exitCode'], 7)
                    self.assertEqual(completed['firstFailure'], {'phase': failure_phase, 'exitCode': 7})
                    self.assertEqual(invoked.count('native'), 1)
                    self.assertIn('export', invoked); self.assertIn('cases', invoked)
                    self.assertEqual(invoked.count('stage'),0 if failure_phase=='producer' else 1)
                    self.assertNotIn('before-build', invoked); self.assertNotIn('after-tests', invoked)
                    self.assertNotIn('result', invoked); self.assertFalse((self.work/'result.json').exists())
                    ledger = smoke.read_json(self.work/'handoff-pipeline.json')
                    self.assertEqual([row['phase'] for row in ledger['phases']], list(probe.HANDOFF_PHASES))
                    native = next(row for row in ledger['phases'] if row['phase']=='native')
                    self.assertEqual(native['command']['exitCode'], 65)
                    self.assertEqual(native['sourceBefore'], source); self.assertEqual(native['sourceAfter'], source)
                    self.assertIs(ledger['allPhasesSucceeded'], False)
                    with self.assertRaises(ValueError): probe.verify_handoff_pipeline(self.work)

    def test_handoff_phase_records_real_timeout_and_integrity_failure_without_success(self):
        self.work.mkdir(parents=True)
        source = {'source': 'portable'}
        argv = [sys.executable, '-c', 'import threading;threading.Event().wait()']
        with patch.object(probe, '_handoff_source_state', return_value=source):
            timed = probe._run_handoff_phase(self.work, 'producer', argv, 0.1, source)
        self.assertIs(timed['command']['timedOut'], True); self.assertEqual(probe._phase_exit(timed), 124)
        self.assertEqual(timed['state'], 'failed')
        with patch.object(probe, '_handoff_source_state', side_effect=[source, {'source': 'changed'}]):
            changed = probe._run_handoff_phase(self.work, 'stage', [sys.executable, '-c', 'print("done")'], 5, source)
        self.assertEqual(changed['state'], 'failed'); self.assertEqual(changed['command']['exitCode'], 0)
        self.assertEqual(probe._phase_exit(changed), 1)
        self.assertIsNone(probe._phase_exit({'state':'blocked'}))
        self.assertEqual(probe._handoff_blockers('native', [
            {'phase':'producer','state':'failed','command':{'exitCode':1},'sourceBefore':source,'sourceAfter':source},
            {'phase':'boot','state':'succeeded','command':{'exitCode':0},'sourceBefore':source,'sourceAfter':source}]), [])

    def test_handoff_result_rejects_failed_missing_changed_phase_and_required_sdk_fixture(self):
        with self.context(), patch.dict(os.environ, {'YUEDU_RENEWAL_SELECTION':'handoffrenewal','DEVELOPER_DIR':'owned-toolchain'}), patch.object(probe,'historical_package_evidence',return_value={'historicalOnly':True}):
            self.built_fixture(); self.sdk_runtime_fixture(); self.transaction_details_fixture(group='handoffrenewal')
            with self.assertRaises(FileNotFoundError): probe.result(self.work)
            ledger = self.handoff_ledger_fixture()
            with patch.dict(os.environ,{"YUEDU_RENEWAL_PORTABLE_GUARDS_OUTCOME":"failure"}), self.assertRaises(ValueError):
                probe.result(self.work)
            accepted = probe.result(self.work)
            self.assertEqual(accepted['targetedTests']['handoffrenewal']['expectedTests'],255)
            self.assertEqual(accepted['targetedTests']['handoffrenewal']['expectedQualifiedMethodDefinitions'],253)
            self.assertEqual(len(accepted['limitations']),6)
            self.assertEqual(accepted['historicalIndependentPackageEvidence'],{'historicalOnly':True})
            for change in ('missing','duplicate','timeout','blocked','source','command'):
                altered=copy.deepcopy(ledger)
                if change=='missing': altered['phases'].pop()
                elif change=='duplicate': altered['phases'].append(altered['phases'][0])
                elif change=='timeout': altered['phases'][0]['command']['timedOut']=True
                elif change=='blocked': altered['phases'][0]['state']='blocked'
                elif change=='source': altered['phases'][0]['sourceAfter']['sourceCommit']='b'*40
                else: altered['phases'][0]['command']['argv']=['true']
                self.write_json('handoff-pipeline.json',altered)
                with self.subTest(change=change),self.assertRaises(ValueError):probe.result(self.work)
            self.write_json('handoff-pipeline.json',ledger)
            for path in (self.work/'handoff-producer.log',self.work/'handoffrenewal-tests.log',self.work/'historical-package-evidence.json'):
                old=path.read_bytes();self.write(path,old+b' ')
                with self.subTest(path=path.name),self.assertRaises((ValueError,json.JSONDecodeError)):probe.result(self.work)
                self.write(path,old)
            self.write_json('handoffrenewal-tests.json',self.tree('transactionrenewal'))
            with self.assertRaises(ValueError):probe.result(self.work)

    def test_handoff_preparation_binding_and_historical_comparisons_cannot_imply_new_tag_pass(self):
        with self.context(),patch.dict(os.environ,{'YUEDU_RENEWAL_SELECTION':'handoffrenewal'}):
            record=probe.prepare(self.work)
            self.assertEqual(record['intendedQualifiedMethodDefinitions'],253)
            self.assertEqual(record['intendedArgumentLeafCount'],255)
            self.assertEqual(set(record['intendedTests']),{'handoffrenewal'})
            for field,value in (('intendedQualifiedMethodDefinitions',178),('intendedArgumentLeafCount',180)):
                changed=copy.deepcopy(record);changed[field]=value;self.write_json('source-inputs.json',changed)
                with self.assertRaisesRegex(ValueError,'argument source-input audit'):probe.result(self.work)
            self.write_json('source-inputs.json',record)
            self.write(self.root/'Modules/Core/BookSource/BookSourceStore.swift',b'changed source')
            with self.assertRaisesRegex(ValueError,'checked-out HEAD'):probe._handoff_source_state(self.work)
        rows=copy.deepcopy(probe.HISTORICAL_PACKAGE_INPUTS)
        for row in rows:
            raw=('historical reference '+row['path']).encode();row['bytes']=len(raw);row['sha256']=hashlib.sha256(raw).hexdigest()
            self.originals[row['path']]=raw;self.write(self.root/row['path'],raw)
        with self.context(),patch.object(probe,'HISTORICAL_PACKAGE_INPUTS',rows):
            historical=probe.historical_package_evidence()
            self.assertIs(historical['all19Unchanged'],True);self.assertIs(historical['package12Unchanged'],True)
            self.assertIs(historical['newTagPackageAcceptance'],False)
            workflow='.github/workflows/reader-renewal-probe.yml';raw=b'new workflow same package source'
            self.originals[workflow]=raw;self.write(self.root/workflow,raw)
            changed=probe.historical_package_evidence()
            self.assertEqual(changed['unchangedInputs'],18);self.assertIs(changed['all19Unchanged'],False)
            self.assertIs(changed['package12Unchanged'],True);self.assertIs(changed['newTagPackageExecutionPerformed'],False)
            self.write(self.root/workflow,raw+b' dirty')
            with self.assertRaisesRegex(ValueError,'changed from this Git source'):probe.historical_package_evidence()


    def currentcore_ledger_fixture(self):
            """Portable fabricated evidence exercises guards; it is never SDK proof."""
            source = probe._currentcore_source_state(self.work)
            rows = []
            commands = probe._currentcore_commands(self.work, 0)
            for name, timeout in zip(probe.CURRENTCORE_PHASES, probe.CURRENTCORE_TIMEOUTS):
                output = probe._currentcore_output(self.work, name)
                if not output.exists(): self.write(output, b"guard phase output\n")
                if name == 'native': self.write(output, b'xcodebuild status: 0; wrapper verdict stop: false\n')
                raw = output.read_bytes(); stderr = output.with_suffix(output.suffix + '.stderr.log')
                self.write(stderr, b'')
                command = {'argv': commands[name], 'exitCode': 0, 'timedOut': False, 'oversized': False,
                           'output': output.name, 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(),
                           'stderr': stderr.name, 'stderrBytes': 0, 'stderrSHA256': hashlib.sha256(b'').hexdigest()}
                row = {'schemaVersion': 1, 'phase': name, 'timeoutSeconds': timeout, 'sourceBefore': source,
                       'sourceAfter': source, 'state': 'succeeded', 'blockedBy': [], 'intendedArgv': commands[name],
                       'command': command, 'elapsedSeconds': 0.1}
                if name == 'native':
                    raw = (self.work/'currentcore-tests.log').read_bytes()
                    row['nativeLog'] = {'path': 'currentcore-tests.log', 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
                    row['reportedXcodebuildStatuses'] = [{'exitCode': 0, 'wrapperVerdictStop': False}]
                    row['wrapperReportedBudgetTimeout'] = False
                self.write_json('currentcore-phase-' + name + '.json', row); rows.append(row)
            ledger = {'schemaVersion': 1, 'selectionMode': 'currentcore', 'source': source,
                      'qualifiedMethodDefinitions': 463, 'argumentLeaves': 466, 'phaseOrder': list(probe.CURRENTCORE_PHASES),
                      'phases': rows, 'firstFailure': None, 'allPhasesSucceeded': True}
            self.write_json('historical-package-evidence.json', probe.historical_package_evidence())
            ledger['phaseRecords']=[probe._currentcore_fact(self.work,'currentcore-phase-'+name+'.json') for name in probe.CURRENTCORE_PHASES]
            ledger['historicalPackageEvidence']=probe._currentcore_fact(self.work,'historical-package-evidence.json')
            self.write_json('currentcore-pipeline.json', ledger)
            return ledger


    def test_currentcore_exact_ast_union_source_boundaries_arguments_and_one_new_budget(self):
        expected=probe.EXPECTED_CASES['currentcore']
        declared=set()
        for suite,names in probe.CURRENTCORE_ADDITIONAL_CASES.items():
            source=(HERE.parents[1]/('Tests/iOS/yuedu appTests/'+suite+'.swift')).read_text(encoding='utf8')
            actual=set(re.findall(r'(?m)^[ \t]*@Test[^\n]*\n(?:[ \t]*@[^\n]*\n)*[ \t]*func[ \t]+(\w+)[ \t]*\(',source))
            self.assertEqual(set(names) | set(probe.CURRENTCORE_SOURCE_LOGIN_CASES.get(suite, ())) | set(probe.CURRENTCORE_FOREGROUND_LIFECYCLE_CASES.get(suite, ())),actual,suite)
            declared|={suite+'/'+name for name in names}
        self.assertEqual(expected,probe.EXPECTED_CASES['handoffrenewal']|declared|probe.CURRENTCORE_NEW_QUALIFIED_CASES|probe.CURRENTCORE_LIVE_QUALIFIED_CASES|probe.CURRENTCORE_GLYPH_QUALIFIED_CASES|probe.CURRENTCORE_SOURCE_LOGIN_QUALIFIED_CASES|probe.CURRENTCORE_MATERIAL_REFRESH_QUALIFIED_CASES|probe.CURRENTCORE_LOGIN_ACTION_REGRESSION_QUALIFIED_CASES|probe.CURRENTCORE_EXPLORE_LIFECYCLE_QUALIFIED_CASES|probe.CURRENTCORE_FOREGROUND_LIFECYCLE_QUALIFIED_CASES)
        self.assertEqual(len(expected),463);self.assertEqual(probe.expected_leaf_count('currentcore'),466)
        self.assertIn(probe.SDK_REQUIRED_CASE,expected)
        self.assertEqual(len(probe.SOURCE_INPUTS),322);self.assertEqual(len(set(probe.SOURCE_INPUTS)),322)
        self.assertEqual(len(probe.SDK_TOOL_NAMES),7)
        self.assertEqual(probe.expected_leaf_count('handoffrenewal'),255)
        for group in ('transactionrenewal','handoffrenewal','currentcore'):
            checked=probe.verify_cases(self.tree(group),group)
            self.assertEqual(checked['expectedTests'],probe.expected_leaf_count(group))
        for change in ('requiredSDK','missing','duplicate','wrongValue','skip'):
            changed=self.tree('currentcore');nodes=changed['testNodes'][0]['children']
            if change=='requiredSDK':nodes[:]=[row for row in nodes if probe.SDK_REQUIRED_CASE not in row['nodeIdentifier']]
            elif change=='missing':nodes.pop()
            elif change=='duplicate':nodes.append(copy.deepcopy(nodes[0]))
            elif change=='skip':nodes[0]['result']='Skipped'
            else:next(row for row in nodes if '(interrupt:)' in row['nodeIdentifier'])['children'][0]['name']='unknown'
            with self.subTest(change=change),self.assertRaises(ValueError):probe.verify_cases(changed,'currentcore')
        with self.context(),patch.dict(os.environ,{'YUEDU_RENEWAL_SELECTION':'currentcore'}):
            inputs=probe.prepare(self.work);commands=probe._currentcore_commands(self.work)
            self.assertEqual(inputs['intendedQualifiedMethodDefinitions'],463)
            self.assertEqual(inputs['intendedArgumentLeafCount'],466)
            native=commands['native'];self.assertEqual(native.count('-resultBundlePath'),1)
            self.assertEqual(native[native.index('-t')+1],'3600')
            selected=[row.removeprefix('-only-testing:yuedu appTests/') for row in native if row.startswith('-only-testing:')]
            self.assertEqual(len(selected),463)
            self.assertEqual(set(selected),{case+('('+probe.parameter_cases('currentcore')[case]+':)' if case in probe.parameter_cases('currentcore') else '') for case in expected})
            old=probe._handoff_commands(self.work)['native'];self.assertEqual(old[old.index('-t')+1],'2700')
        wrapper=(HERE/'renewal-probe-tests.sh').read_text(encoding='utf8')
        branch=re.search(r'if \[\[ \$YUEDU_RENEWAL_SELECTION == currentcore \]\]; then\n(.*?)\nfi',wrapper,re.S)[1]
        self.assertIn('run-currentcore --work',branch);self.assertIn('exit $?',branch)
        workflow=(HERE.parents[1]/'.github/workflows/reader-renewal-probe.yml').read_text(encoding='utf8')
        self.assertIn('YUEDU_RENEWAL_SELECTION: currentcore',workflow)
        self.assertIn('timeout-minutes: 125',workflow)
        self.assertIn('Package source-only selection is22',workflow)
        self.assertIn("steps.guards.outcome",workflow)

    def test_currentcore_pipeline_preserves_real_first_failure_and_still_runs_full_native_once(self):
            for failure_phase in ('producer','stage'):
                with self.subTest(firstFailure=failure_phase):
                    self.root=Path(self.temp.name).resolve()/failure_phase
                    for path,raw in self.originals.items(): self.write(self.root/path,raw)
                    self.work=self.root/'.build'/('currentcore-'+failure_phase)
                    with self.context(), patch.dict(os.environ, {'YUEDU_RENEWAL_SELECTION': 'currentcore'}):
                        probe.prepare(self.work)
                        self.write(self.work/'xcode-version.log',b'Portable guard version fixture; no SDK executed\n')
                        source = probe._currentcore_source_state(self.work)
                        # Actual portable child exits exercise the pipeline; these children
                        # are not codesign/XCTest and cannot produce SDK acceptance.
                        invoked = []
                        def capture(argv, output, **options):
                            name = output.name.removeprefix('currentcore-').removesuffix('.log')
                            invoked.append(name)
                            status = 7 if name == failure_phase else 65 if name == 'native' else 0
                            return original_capture([sys.executable, '-c', 'import sys;print("portable phase");sys.exit('+str(status)+')'], output, **options)
                        original_capture = probe._capture_xcresult
                        with patch.object(probe, 'historical_package_evidence', return_value={'historicalOnly': True}), patch.object(probe, '_capture_xcresult', side_effect=capture):
                            completed = probe.run_currentcore(self.work)
                        self.assertEqual(completed['exitCode'], 7)
                        self.assertEqual(completed['firstFailure'], {'phase': failure_phase, 'exitCode': 7})
                        self.assertEqual(invoked.count('native'), 1)
                        self.assertIn('export', invoked); self.assertIn('cases', invoked)
                        self.assertEqual(invoked.count('stage'),0 if failure_phase=='producer' else 1)
                        self.assertNotIn('before-build', invoked); self.assertNotIn('after-tests', invoked)
                        self.assertNotIn('result', invoked); self.assertFalse((self.work/'result.json').exists())
                        ledger = smoke.read_json(self.work/'currentcore-pipeline.json')
                        self.assertEqual([row['phase'] for row in ledger['phases']], list(probe.CURRENTCORE_PHASES))
                        native = next(row for row in ledger['phases'] if row['phase']=='native')
                        self.assertEqual(native['command']['exitCode'], 65)
                        self.assertEqual(native['sourceBefore'], source); self.assertEqual(native['sourceAfter'], source)
                        self.assertIs(ledger['allPhasesSucceeded'], False)
                        with self.assertRaises(ValueError): probe.verify_currentcore_pipeline(self.work)

    def test_currentcore_result_rejects_failed_missing_changed_phase_and_required_sdk_fixture(self):
            with self.context(), patch.dict(os.environ, {'YUEDU_RENEWAL_SELECTION':'currentcore','DEVELOPER_DIR':'owned-toolchain'}), patch.object(probe,'historical_package_evidence',return_value={'historicalOnly':True}):
                self.built_fixture(); self.sdk_runtime_fixture(); self.transaction_details_fixture(group='currentcore')
                with self.assertRaises(FileNotFoundError): probe.result(self.work)
                ledger = self.currentcore_ledger_fixture()
                with patch.dict(os.environ,{"YUEDU_RENEWAL_PORTABLE_GUARDS_OUTCOME":"failure"}), self.assertRaises(ValueError):
                    probe.result(self.work)
                accepted = probe.result(self.work)
                self.assertEqual(accepted['targetedTests']['currentcore']['expectedTests'],466)
                self.assertEqual(accepted['targetedTests']['currentcore']['expectedQualifiedMethodDefinitions'],463)
                self.assertEqual(len(accepted['limitations']),5)
                self.assertEqual(accepted['historicalIndependentPackageEvidence'],{'historicalOnly':True})
                for change in ('missing','duplicate','timeout','blocked','source','command'):
                    altered=copy.deepcopy(ledger)
                    if change=='missing': altered['phases'].pop()
                    elif change=='duplicate': altered['phases'].append(altered['phases'][0])
                    elif change=='timeout': altered['phases'][0]['command']['timedOut']=True
                    elif change=='blocked': altered['phases'][0]['state']='blocked'
                    elif change=='source': altered['phases'][0]['sourceAfter']['sourceCommit']='b'*40
                    else: altered['phases'][0]['command']['argv']=['true']
                    self.write_json('currentcore-pipeline.json',altered)
                    with self.subTest(change=change),self.assertRaises(ValueError):probe.result(self.work)
                self.write_json('currentcore-pipeline.json',ledger)
                for path in (self.work/'currentcore-producer.log',self.work/'currentcore-tests.log',self.work/'historical-package-evidence.json'):
                    old=path.read_bytes();self.write(path,old+b' ')
                    with self.subTest(path=path.name),self.assertRaises((ValueError,json.JSONDecodeError)):probe.result(self.work)
                    self.write(path,old)
                self.write_json('currentcore-tests.json',self.tree('transactionrenewal'))
                with self.assertRaises(ValueError):probe.result(self.work)




class AccountCoreSelectionTests(unittest.TestCase):
    """Portable guard cases only. Fabricated xcresult data never proves SDK execution."""
    setUp = RenewalProbeEvidenceTests.setUp
    write = RenewalProbeEvidenceTests.write
    write_json = RenewalProbeEvidenceTests.write_json
    git = RenewalProbeEvidenceTests.git
    context = RenewalProbeEvidenceTests.context
    tree = RenewalProbeEvidenceTests.tree

    def test_account_case_inventory_matches_actual_suite_extensions_and_closure(self):
        new = probe.CURRENTCORE_NEW_QUALIFIED_CASES
        self.assertEqual(len(new), 59)
        self.assertEqual(len(probe.EXPECTED_CASES['currentcore']), 463)
        self.assertEqual(probe.expected_leaf_count('currentcore'), 466)
        self.assertIn(probe.SDK_REQUIRED_CASE, probe.EXPECTED_CASES['currentcore'])
        self.assertEqual(set(probe.PARAMETER_CASES.values()), {'interrupt'})
        for suite, names in (probe.CURRENTCORE_ACCOUNT_CASES | probe.CURRENTCORE_PUBLIC_CASES).items():
            declared = []
            for relative in probe.CURRENTCORE_NEW_SOURCE_PATHS[suite]:
                self.assertIn(relative, probe.SOURCE_INPUTS)
                source = (HERE.parents[1] / relative).read_text(encoding='utf8')
                declared.extend(re.findall(r'(?m)^[ \t]*@Test[^\n]*\n(?:[ \t]*@[^\n]*\n)*[ \t]*func[ \t]+(\w+)[ \t]*\(', source))
            self.assertEqual(len(declared), len(set(declared)), suite)
            old = {case.split('/', 1)[1] for case in probe.EXPECTED_CASES['handoffrenewal'] if case.startswith(suite + '/')}
            self.assertEqual(set(declared), old | set(names) | set(probe.CURRENTCORE_LIVE_CASES.get(suite, ())) | set(probe.CURRENTCORE_MATERIAL_REFRESH_CASES.get(suite, ())), suite)
        # Only five named existing cases are selected from these media suites.
        # Other methods (including the explicitly live-network test) stay out.
        for suite, names in probe.CURRENTCORE_RENDERER_REGRESSION_CASES.items():
            declared = []
            for relative in probe.CURRENTCORE_RENDERER_SOURCE_PATHS[suite]:
                self.assertIn(relative, probe.SOURCE_INPUTS)
                source = (HERE.parents[1] / relative).read_text(encoding='utf8')
                declared.extend(re.findall(r'(?m)^[ \t]*func[ \t]+(\w+)[ \t]*\(', source))
            self.assertTrue(set(names) <= set(declared), suite)
            selected = {case.split('/', 1)[1] for case in probe.EXPECTED_CASES['currentcore'] if case.startswith(suite + '/')}
            self.assertEqual(selected, set(names), suite)
        self.assertEqual(len(probe.SOURCE_INPUTS), 322)
        self.assertEqual(len(set(probe.SOURCE_INPUTS)), 322)
        self.assertIn(probe.CURRENTCORE_TRUST_GUARD_SOURCE, probe.SOURCE_INPUTS)
        self.assertIn(probe.CURRENTCORE_HEALTH_CONFORMANCE_SOURCE, probe.SOURCE_INPUTS)
        workflow = (HERE.parents[1] / '.github/workflows/reader-renewal-probe.yml').read_text(encoding='utf8')
        self.assertEqual(workflow.count('python -B scripts/reader-experience/owned-package-fixture/test-producer-user-trust.py -v'), 1)
        for name in ('SelfRenewalDeveloperAccountClient', 'SelfRenewalDeveloperAccountTransport',
                     'SelfRenewalGSASRP', 'SelfRenewalDeveloperAuthentication'):
            self.assertIn('Modules/Services/SelfRenewal/' + name + '.swift', probe.SOURCE_INPUTS)

    def test_account_native_admission_rejects_every_missing_duplicated_skipped_or_spoofed_new_case(self):
        accepted = probe.verify_cases(self.tree('currentcore'), 'currentcore')
        self.assertEqual(accepted['expectedTests'], 466)
        self.assertEqual(accepted['expectedQualifiedMethodDefinitions'], 463)
        for case in sorted(probe.CURRENTCORE_NEW_QUALIFIED_CASES):
            for fault in ('missing', 'duplicate', 'skip', 'wrongSuite'):
                tree = self.tree('currentcore'); rows = tree['testNodes'][0]['children']
                selected = next(row for row in rows if row['nodeIdentifier'] == 'target/' + case + '()')
                if fault == 'missing': rows.remove(selected)
                elif fault == 'duplicate': rows.append(copy.deepcopy(selected))
                elif fault == 'skip': selected['result'] = 'Skipped'
                else: selected['nodeIdentifier'] = 'target/UnknownSuite/' + case.split('/', 1)[1] + '()'
                with self.subTest(case=case, fault=fault), self.assertRaises(ValueError):
                    probe.verify_cases(tree, 'currentcore')

    def test_account_preparation_binds_new_sources_and_uses_one_complete_native_command(self):
        with self.context(), patch.dict(os.environ, {'YUEDU_RENEWAL_SELECTION': 'currentcore'}):
            prepared = probe.prepare(self.work)
            self.write(self.work / 'xcode-version.log', b'Portable guard only; no Swift SDK executed\n')
            self.assertEqual(prepared['intendedQualifiedMethodDefinitions'], 463)
            self.assertEqual(prepared['intendedArgumentLeafCount'], 466)
            commands = probe._currentcore_commands(self.work)
            native = commands['native']
            self.assertEqual(native.count('-resultBundlePath'), 1)
            self.assertEqual(native[native.index('-t') + 1], '3600')
            selected = [item.removeprefix('-only-testing:yuedu appTests/') for item in native if item.startswith('-only-testing:')]
            self.assertEqual(len(selected), 463)
            self.assertTrue(probe.CURRENTCORE_NEW_QUALIFIED_CASES <= set(selected))
            probe._currentcore_source_state(self.work)
            new_paths = ('Modules/Services/SelfRenewal/SelfRenewalDeveloperAccountClient.swift',
                'Modules/Services/SelfRenewal/SelfRenewalDeveloperAccountTransport.swift',
                'Modules/Services/SelfRenewal/SelfRenewalGSASRP.swift',
                'Modules/Services/SelfRenewal/SelfRenewalDeveloperAuthentication.swift',
                'Tests/iOS/yuedu appTests/SelfRenewalDeveloperAccountClientTests.swift',
                'Tests/iOS/yuedu appTests/SelfRenewalAccountSessionTests.swift',
                'Tests/iOS/yuedu appTests/SelfRenewalDeveloperAuthenticationTests.swift')
            new_paths += tuple(path for path in probe.CURRENTCORE_PUBLIC_SOURCE_INPUTS if path not in new_paths)
            new_paths += tuple(path for path in probe.CURRENTCORE_RENDERER_SOURCE_INPUTS if path not in new_paths)
            new_paths += (probe.CURRENTCORE_HEALTH_CONFORMANCE_SOURCE,)
            new_paths += (probe.CURRENTCORE_TRUST_GUARD_SOURCE,)
            for relative in new_paths:
                original = (self.root / relative).read_bytes()
                self.write(self.root / relative, original + b' changed after preparation')
                with self.subTest(input=relative), self.assertRaisesRegex(ValueError, 'checked-out HEAD'):
                    probe._currentcore_source_state(self.work)
                self.write(self.root / relative, original)
            old = copy.deepcopy(prepared)
            old.update(intendedQualifiedMethodDefinitions=314, intendedArgumentLeafCount=316)
            self.write_json('source-inputs.json', old)
            with self.assertRaises(ValueError): probe._currentcore_source_state(self.work)



class EnrollmentRecoverySelectionTests(unittest.TestCase):
    """New qualified identities only; synthetic results never prove SDK execution."""
    setUp = RenewalProbeEvidenceTests.setUp
    write = RenewalProbeEvidenceTests.write
    write_json = RenewalProbeEvidenceTests.write_json
    git = RenewalProbeEvidenceTests.git
    context = RenewalProbeEvidenceTests.context
    tree = RenewalProbeEvidenceTests.tree

    def test_expired_enrollment_has_four_exact_client_methods_and_preserves_native_gates(self):
        names = {
            "appSessionEnrollsAfterRealInstalledAndPublishedProfileExpiry",
            "appSessionReconcilesExpiredEnrollmentAndRetainsLogoutDenial",
            "appSessionEnrollmentRejectsChangedBundleAndMissingManifest",
            "appSessionExpiredEnrollmentRetainsRealUploadIntentBarrier",
        }
        suite = "SelfRenewalDeveloperAccountClientTests"
        cases = {suite + "/" + name for name in names}
        self.assertEqual(len(probe.EXPECTED_CASES["currentcore"]), 463)
        self.assertEqual(probe.expected_leaf_count("currentcore"), 466)
        self.assertTrue(cases <= probe.CURRENTCORE_ACCOUNT_QUALIFIED_CASES)
        self.assertTrue(cases.isdisjoint(probe.EXPECTED_CASES["handoffrenewal"]))
        self.assertIn(probe.SDK_REQUIRED_CASE, probe.EXPECTED_CASES["currentcore"])
        self.assertEqual(set(probe.PARAMETER_CASES.values()), {"interrupt"})
        self.assertEqual(len(probe.PARAMETER_CASES), 2)
        self.assertEqual(len(probe.SOURCE_INPUTS), 322)
        self.assertEqual(len(set(probe.SOURCE_INPUTS)), 322)
        self.assertIn("Tests/iOS/LegadoNativeOriginalReaderTests.swift", probe.SOURCE_INPUTS)
        relative = "Tests/iOS/yuedu appTests/SelfRenewalAccountSessionTests.swift"
        self.assertIn(relative, probe.CURRENTCORE_ACCOUNT_SOURCE_PATHS[suite])
        text = (HERE.parents[1] / relative).read_text(encoding="utf8")
        for name in names:
            positions = list(re.finditer(r"\bfunc\s+" + name + r"\s*\(", text))
            self.assertEqual(len(positions), 1)
            extensions = list(re.finditer(r"\bextension\s+(\w+)", text[:positions[0].start()]))
            self.assertEqual(extensions[-1][1], suite)
        accepted = probe.verify_cases(self.tree("currentcore"), "currentcore")
        self.assertEqual(accepted["expectedTests"], 466)
        for case in sorted(cases):
            for fault in ("missing", "duplicate", "skip", "wrongSuite"):
                tree = self.tree("currentcore"); rows = tree["testNodes"][0]["children"]
                selected = next(row for row in rows if row["nodeIdentifier"] == "target/" + case + "()")
                if fault == "missing": rows.remove(selected)
                elif fault == "duplicate": rows.append(copy.deepcopy(selected))
                elif fault == "skip": selected["result"] = "Skipped"
                else: selected["nodeIdentifier"] = "target/SelfRenewalAccountSessionTests/" + case.split("/", 1)[1] + "()"
                with self.subTest(case=case, fault=fault), self.assertRaises(ValueError):
                    probe.verify_cases(tree, "currentcore")
        with self.context(), patch.dict(os.environ, {"YUEDU_RENEWAL_SELECTION": "currentcore"}):
            prepared = probe.prepare(self.work)
            self.assertEqual(prepared["intendedQualifiedMethodDefinitions"], 463)
            self.assertEqual(prepared["intendedArgumentLeafCount"], 466)
            command = probe._currentcore_commands(self.work)["native"]
            self.assertEqual(command.count("-resultBundlePath"), 1)
            self.assertEqual(command[command.index("-t") + 1], "3600")
            selected = {value.removeprefix("-only-testing:yuedu appTests/") for value in command if value.startswith("-only-testing:")}
            expected_selectors = {case + "(" + probe.parameter_cases("currentcore")[case] + ":)" if case in probe.parameter_cases("currentcore") else case
                for case in probe.EXPECTED_CASES["currentcore"]}
            self.assertEqual(selected, expected_selectors)
        workflow = (HERE.parents[1] / ".github/workflows/reader-renewal-probe.yml").read_text(encoding="utf8")
        self.assertIn("463 unique qualified native definitions", workflow)
        self.assertIn("466 exact execution leaves", workflow)
        self.assertIn("&& 'loginui' || ''", workflow)



class LiveCoreSelectionTests(unittest.TestCase):
    """Source declarations and fabricated results exercise admission, never SDK acceptance."""
    setUp = RenewalProbeEvidenceTests.setUp
    write = RenewalProbeEvidenceTests.write
    write_json = RenewalProbeEvidenceTests.write_json
    git = RenewalProbeEvidenceTests.git
    context = RenewalProbeEvidenceTests.context
    tree = RenewalProbeEvidenceTests.tree

    def test_later_core_union_matches_real_suite_owners_without_widening_old_modes(self):
        expected = probe.EXPECTED_CASES['currentcore']
        added = probe.CURRENTCORE_LIVE_QUALIFIED_CASES
        self.assertEqual(len(added), 60)
        self.assertEqual(len(expected), 463)
        self.assertEqual(probe.expected_leaf_count('currentcore'), 466)
        self.assertIn(probe.SDK_REQUIRED_CASE, expected)
        self.assertEqual(probe.PARAMETER_CASES, {
            'TXTReaderIndexMigrationTests/migrationPreservesBookmarksAndReplaysInterruptedCommit': 'interrupt',
            'AozoraTXTTests/storedV6LocationsMigrateOnce': 'interrupt'})
        self.assertEqual(len(probe.SOURCE_INPUTS), 322)
        self.assertEqual(len(probe.CURRENTCORE_LIVE_SOURCE_INPUTS), 47)
        for suite, selected in probe.CURRENTCORE_LIVE_CASES.items():
            actual = []
            for relative in probe.CURRENTCORE_LIVE_SOURCE_PATHS[suite]:
                self.assertIn(relative, probe.SOURCE_INPUTS)
                source = (HERE.parents[1] / relative).read_text(encoding='utf8')
                actual.extend(re.findall(r'(?m)^[ \t]*@Test[^\n]*\n(?:[ \t]*@[^\n]*\n)*[ \t]*func[ \t]+(\w+)[ \t]*\(', source))
                self.assertNotRegex(source, r'@Test[^\n]*arguments:')
                if suite == 'SelfRenewalDeveloperAccountClientTests':
                    self.assertIn('extension ' + suite, source)
            self.assertEqual(len(actual), len(set(actual)), suite)
            self.assertTrue(set(selected) <= set(actual), suite)
            self.assertTrue({suite + '/' + name for name in actual} <= expected, suite)
            if suite != 'SelfRenewalDeveloperAccountClientTests':
                self.assertEqual(set(actual), set(selected) | set(probe.CURRENTCORE_EXPLORE_LIFECYCLE_CASES.get(suite, ())) | set(probe.CURRENTCORE_FOREGROUND_LIFECYCLE_CASES.get(suite, ())), suite)
            for group in probe.EXPECTED_CASES:
                if group != 'currentcore':
                    self.assertTrue(added.isdisjoint(probe.EXPECTED_CASES[group]), group)

    def test_later_core_cases_and_sources_cannot_be_missing_duplicated_skipped_or_spoofed(self):
        for case in sorted(probe.CURRENTCORE_LIVE_QUALIFIED_CASES):
            for fault in ('missing', 'duplicate', 'skip', 'wrongSuite'):
                tree = self.tree('currentcore'); rows = tree['testNodes'][0]['children']
                node = next(row for row in rows if row['nodeIdentifier'] == 'target/' + case + '()')
                if fault == 'missing': rows.remove(node)
                elif fault == 'duplicate': rows.append(copy.deepcopy(node))
                elif fault == 'skip': node['result'] = 'Skipped'
                else: node['nodeIdentifier'] = 'target/UnknownSuite/' + case.split('/', 1)[1] + '()'
                with self.subTest(case=case, fault=fault), self.assertRaises(ValueError):
                    probe.verify_cases(tree, 'currentcore')
        with self.context(), patch.dict(os.environ, {'YUEDU_RENEWAL_SELECTION': 'currentcore'}):
            prepared = probe.prepare(self.work)
            self.write(self.work / 'xcode-version.log', b'Portable guard only; no SDK executed\n')
            command = probe._currentcore_commands(self.work)['native']
            self.assertEqual(command.count('-resultBundlePath'), 1)
            self.assertEqual(command[command.index('-t') + 1], '3600')
            self.assertEqual(sum(value.startswith('-only-testing:') for value in command), 463)
            for relative in probe.CURRENTCORE_LIVE_SOURCE_INPUTS:
                raw = (self.root / relative).read_bytes()
                self.write(self.root / relative, raw + b' dirty')
                with self.subTest(source=relative), self.assertRaisesRegex(ValueError, 'checked-out HEAD'):
                    probe._currentcore_source_state(self.work)
                self.write(self.root / relative, raw)
            self.assertEqual(prepared['intendedArgumentLeafCount'], 466)


class GlyphCheckpointSelectionTests(unittest.TestCase):
    """Three reviewed Bool pairs; fabricated exports exercise guards, never SDK evidence."""
    setUp = RenewalProbeEvidenceTests.setUp
    write = RenewalProbeEvidenceTests.write
    write_json = RenewalProbeEvidenceTests.write_json
    git = RenewalProbeEvidenceTests.git
    context = RenewalProbeEvidenceTests.context
    tree = RenewalProbeEvidenceTests.tree

    def test_glyph_case_sources_and_currentcore_only_bool_identity_are_exact(self):
        glyph = 'CoreTextPagedScrollAppearanceTests/authoredCompositionMatchesScroll'
        self.assertEqual(len(probe.CURRENTCORE_GLYPH_QUALIFIED_CASES), 11)
        self.assertEqual(probe.parameter_cases('currentcore'), probe.PARAMETER_CASES | {glyph: 'nestedBackdrop'})
        for mode in ('transactionrenewal', 'handoffrenewal'):
            self.assertEqual(probe.parameter_cases(mode), probe.PARAMETER_CASES)
        self.assertEqual(probe.expected_leaf_count('transactionrenewal'), 180)
        self.assertEqual(probe.expected_leaf_count('handoffrenewal'), 255)
        self.assertEqual(len(probe.EXPECTED_CASES['currentcore']), 463)
        self.assertEqual(probe.expected_leaf_count('currentcore'), 466)
        for suite, names in probe.CURRENTCORE_GLYPH_CASES.items():
            source = (HERE.parents[1] / probe.CURRENTCORE_GLYPH_SOURCE_PATHS[suite][0]).read_text(encoding='utf8')
            self.assertIn(probe.CURRENTCORE_GLYPH_SOURCE_PATHS[suite][0], probe.SOURCE_INPUTS)
            for name in names:
                self.assertEqual(len(re.findall(r'\bfunc\s+' + name + r'\s*\(', source)), 1, name)
                self.assertIn(suite + '/' + name, probe.EXPECTED_CASES['currentcore'])
        source = (HERE.parents[1] / probe.CURRENTCORE_GLYPH_SOURCE_PATHS['CoreTextPagedScrollAppearanceTests'][0]).read_text(encoding='utf8')
        self.assertRegex(source, r'@Test\(arguments: \[false, true\]\) @MainActor\s+func authoredCompositionMatchesScroll\(nestedBackdrop: Bool\)')
        tree = self.tree('currentcore')
        accepted = probe.verify_cases(tree, 'currentcore')
        self.assertIn(glyph + '[nestedBackdrop=false]', accepted['passedCaseIdentifiers'])
        self.assertIn(glyph + '[nestedBackdrop=true]', accepted['passedCaseIdentifiers'])
        for fault in ('missing', 'duplicate', 'wrongValueLabel', 'wrongSignature'):
            changed = copy.deepcopy(tree)
            node = next(node for node in changed['testNodes'][0]['children'] if glyph in node['nodeIdentifier'])
            if fault == 'missing': node['children'].pop()
            elif fault == 'duplicate': node['children'][1] = copy.deepcopy(node['children'][0])
            elif fault == 'wrongValueLabel': node['children'][0]['name'] = 'interrupt: false'
            else: node['nodeIdentifier'] = node['nodeIdentifier'].replace('(nestedBackdrop:)', '(interrupt:)')
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                probe.verify_cases(changed, 'currentcore')
        with self.context(), patch.dict(os.environ, {'YUEDU_RENEWAL_SELECTION': 'currentcore'}):
            prepared = probe.prepare(self.work)
            self.assertEqual(len(prepared['intendedArgumentCases']), 3)
            selected = probe._currentcore_commands(self.work)['native']
            self.assertIn('-only-testing:yuedu appTests/' + glyph + '(nestedBackdrop:)', selected)
            self.assertEqual(sum(value.startswith('-only-testing:') for value in selected), 463)

    def test_currentcore_exports_and_requires_all_three_actual_parameter_details(self):
        tree = self.tree('currentcore')
        count = 466
        nodes = probe._test_nodes(tree)
        def capture(argv, output, **options):
            if '--help' in argv:
                raw = b'Arguments nodeIdentifier result testIdentifier testResult testRuns'
            elif 'summary' in argv:
                raw = json.dumps({'totalTestCount': count, 'passedTests': count, 'failedTests': 0, 'skippedTests': 0}).encode()
            elif 'tests' in argv:
                raw = json.dumps(tree).encode()
            else:
                node = next(node for node in nodes if node.get('nodeIdentifierURL') == argv[-1])
                raw = json.dumps({'testIdentifier': node['nodeIdentifier'], 'testIdentifierURL': node['nodeIdentifierURL'],
                    'testResult': 'Passed', 'testRuns': node['children']}).encode()
            self.write(output, raw)
            self.write(output.with_suffix(output.suffix + '.stderr.log'), b'')
            return {'argv': argv, 'exitCode': 0, 'timedOut': False, 'oversized': False,
                'output': output.name, 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(),
                'stderr': output.name + '.stderr.log', 'stderrBytes': 0, 'stderrSHA256': hashlib.sha256(b'').hexdigest()}
        with self.context(), patch.dict(os.environ, {'YUEDU_RENEWAL_SELECTION': 'currentcore'}), patch.object(probe, '_capture_xcresult', side_effect=capture):
            record = probe.collect_xcresult(self.work, 'currentcore', 0)
            self.assertEqual(len(record['commands']), 7)
            self.assertEqual(len(record['parameterExports']), 3)
            probe.verify_transaction_details(self.work, tree, 'currentcore')
            changed = copy.deepcopy(record)
            changed['parameterExports'].pop()
            self.write_json('currentcore-extraction.json', changed)
            with self.assertRaises(ValueError): probe.verify_transaction_details(self.work, tree, 'currentcore')




class SourceLoginCheckpointSelectionTests(unittest.TestCase):
    """Actual Swift declarations and guarded synthetic results, never SDK acceptance."""
    setUp = RenewalProbeEvidenceTests.setUp
    write = RenewalProbeEvidenceTests.write
    write_json = RenewalProbeEvidenceTests.write_json
    git = RenewalProbeEvidenceTests.git
    context = RenewalProbeEvidenceTests.context
    tree = RenewalProbeEvidenceTests.tree

    def test_raw_login_selection_preserves_old_suite_methods_modes_parameters_and_required_sdk(self):
        added = probe.CURRENTCORE_SOURCE_LOGIN_QUALIFIED_CASES
        self.assertEqual(added, {
            'LegadoPersistentStateHostTests/rawLoginInfoUsesCredentialOwnerAndSurvivesReopen',
            'LegadoPersistentStateHostTests/rawLoginInfoRejectsFailedWritesAndCancelledMutations',
            'LegadoPersistentStateHostTests/rawLoginInfoMigratesLegacyAndClaimsCommitBeforeMutation'})
        for suite, selected in probe.CURRENTCORE_SOURCE_LOGIN_CASES.items():
            relative = 'Tests/iOS/yuedu appTests/' + suite + '.swift'
            source = (HERE.parents[1] / relative).read_text(encoding='utf8')
            declarations = re.findall(r'(?m)^[ \t]*@Test[^\n]*\n(?:[ \t]*@[^\n]*\n)*[ \t]*func[ \t]+(\w+)[ \t]*\(([^)]*)\)', source)
            self.assertEqual({name for name, _ in declarations}, set(probe.CURRENTCORE_ADDITIONAL_CASES[suite]) | set(selected))
            self.assertEqual(len(declarations), 13)
            for name, parameters in declarations:
                if name in selected: self.assertEqual(parameters, '')
        self.assertEqual(len(probe.EXPECTED_CASES['currentcore']), 463)
        self.assertEqual(probe.expected_leaf_count('currentcore'), 466)
        self.assertEqual(len(probe.parameter_cases('currentcore')), 3)
        self.assertIn(probe.SDK_REQUIRED_CASE, probe.EXPECTED_CASES['currentcore'])
        for group in probe.EXPECTED_CASES:
            if group != 'currentcore': self.assertTrue(added.isdisjoint(probe.EXPECTED_CASES[group]))
        self.assertEqual(len(probe.SOURCE_INPUTS), 322)
        self.assertEqual(len(probe.CURRENTCORE_SOURCE_STATE_INPUTS), 20)
        self.assertTrue(set(probe.CURRENTCORE_SOURCE_STATE_INPUTS) <= set(probe.SOURCE_INPUTS))
        self.assertEqual(len(probe.CURRENTCORE_LOGIN_MAP_INPUTS), 11)
        self.assertTrue(set(probe.CURRENTCORE_LOGIN_MAP_INPUTS) <= set(probe.SOURCE_INPUTS))

    def test_raw_login_missing_duplicate_skipped_foreign_and_changed_sources_fail_closed(self):
        for case in sorted(probe.CURRENTCORE_SOURCE_LOGIN_QUALIFIED_CASES):
            for fault in ('missing', 'duplicate', 'skip', 'wrongSuite'):
                tree = self.tree('currentcore'); rows = tree['testNodes'][0]['children']
                node = next(row for row in rows if row['nodeIdentifier'] == 'target/' + case + '()')
                if fault == 'missing': rows.remove(node)
                elif fault == 'duplicate': rows.append(copy.deepcopy(node))
                elif fault == 'skip': node['result'] = 'Skipped'
                else: node['nodeIdentifier'] = 'target/OtherSuite/' + case.split('/', 1)[1] + '()'
                with self.subTest(case=case, fault=fault), self.assertRaises(ValueError):
                    probe.verify_cases(tree, 'currentcore')
        with self.context(), patch.dict(os.environ, {'YUEDU_RENEWAL_SELECTION': 'currentcore'}):
            prepared = probe.prepare(self.work)
            self.write(self.work / 'xcode-version.log', b'Portable guard only; no SDK execution\n')
            command = probe._currentcore_commands(self.work)['native']
            self.assertEqual(command.count('-resultBundlePath'), 1)
            self.assertEqual(command[command.index('-t') + 1], '3600')
            self.assertEqual(sum(value.startswith('-only-testing:') for value in command), 463)
            for case in probe.CURRENTCORE_SOURCE_LOGIN_QUALIFIED_CASES:
                self.assertIn('-only-testing:yuedu appTests/' + case, command)
            self.assertEqual(prepared['intendedArgumentLeafCount'], 466)
            for relative in dict.fromkeys(probe.CURRENTCORE_SOURCE_STATE_INPUTS + probe.CURRENTCORE_LOGIN_MAP_INPUTS):
                original = self.originals[relative]
                self.write(self.root / relative, original + b'changed')
                with self.subTest(source=relative), self.assertRaisesRegex(ValueError, 'checked-out HEAD'):
                    probe._currentcore_source_state(self.work)
                self.write(self.root / relative, original)




class MaterialPublicationAndLoginActionSelectionTests(unittest.TestCase):
    """Source identities and synthetic provenance guards, never SDK acceptance."""
    setUp = RenewalProbeEvidenceTests.setUp
    write = RenewalProbeEvidenceTests.write
    write_json = RenewalProbeEvidenceTests.write_json
    git = RenewalProbeEvidenceTests.git
    context = RenewalProbeEvidenceTests.context
    tree = RenewalProbeEvidenceTests.tree

    def test_combined_checkpoint_keeps_four_real_material_methods_and_exact_login_inputs(self):
        added = probe.CURRENTCORE_MATERIAL_REFRESH_QUALIFIED_CASES
        self.assertEqual(added, {'SelfRenewalDeveloperAccountClientTests/appSessionMaterialReconnectRejectsChangedCurrentBundleAndKeepsPublication', 'SelfRenewalDeveloperAccountClientTests/appSessionCancelledPostPublicationReconnectRetainsItsActualReceipt', 'SelfRenewalDeveloperAccountClientTests/appOwnerInitialMaterialPublicationConnectsWithoutLifecycleRestart', 'SelfRenewalDeveloperAccountClientTests/appOwnerMaterialFinalizationConnectsWithoutRepeatedEnrollment'})
        source = (HERE.parents[1] / 'Tests/iOS/yuedu appTests/SelfRenewalAccountSessionTests.swift').read_text(encoding='utf8')
        declarations = re.findall(r'(?m)^[ \t]*@Test[^\n]*\n(?:[ \t]*@[^\n]*\n)*[ \t]*func[ \t]+(\w+)[ \t]*\(([^)]*)\)', source)
        self.assertEqual(len(declarations), 19)
        self.assertEqual(len(declarations), len({name for name, _ in declarations}))
        for case in added:
            self.assertEqual([args for name, args in declarations if name == case.split('/')[1]], [''])
        self.assertEqual(probe.CURRENTCORE_LOGIN_ACTION_REGRESSION_QUALIFIED_CASES,
            {'BookSourceLoginTests/blankLoginFieldIsRequired'})
        caller = (HERE.parents[1] / 'Tests/iOS/yuedu appTests/BookSourceLoginTests.swift').read_text(encoding='utf8')
        self.assertEqual(re.findall(r'func blankLoginFieldIsRequired\s*\(([^)]*)\)', caller), [''])
        self.assertEqual(len(probe.EXPECTED_CASES['currentcore']), 463)
        self.assertEqual(probe.expected_leaf_count('currentcore'), 466)
        self.assertEqual(len(probe.parameter_cases('currentcore')), 3)
        self.assertIn(probe.SDK_REQUIRED_CASE, probe.EXPECTED_CASES['currentcore'])
        for group in probe.EXPECTED_CASES:
            if group != 'currentcore':
                self.assertTrue((added | probe.CURRENTCORE_LOGIN_ACTION_REGRESSION_QUALIFIED_CASES).isdisjoint(probe.EXPECTED_CASES[group]))
        self.assertEqual(len(probe.CURRENTCORE_LOGIN_ACTION_MATERIAL_INPUTS), 23)
        self.assertTrue(set(probe.CURRENTCORE_LOGIN_ACTION_MATERIAL_INPUTS) <= set(probe.SOURCE_INPUTS))
        self.assertEqual(len(probe.SOURCE_INPUTS), 322)
        wrapper = (HERE / 'renewal-probe-tests.sh').read_text(encoding='utf8')
        self.assertIn('463 definitions,466 argument leaves', wrapper)
        workflow = (HERE.parents[1] / '.github/workflows/reader-renewal-probe.yml').read_text(encoding='utf8')
        self.assertIn('Execute463 current-core definitions with466 exact native argument leaves', workflow)
        self.assertIn('Execute22 independent current-source macOS package XCTest cases', workflow)

    def test_material_cases_and_every_actual_combined_source_retain_fail_closed_admission(self):
        for case in sorted(probe.CURRENTCORE_MATERIAL_REFRESH_QUALIFIED_CASES | probe.CURRENTCORE_LOGIN_ACTION_REGRESSION_QUALIFIED_CASES):
            for fault in ('missing', 'duplicate', 'skip', 'wrongSuite'):
                tree = self.tree('currentcore'); rows = tree['testNodes'][0]['children']
                node = next(row for row in rows if row['nodeIdentifier'] == 'target/' + case + '()')
                if fault == 'missing': rows.remove(node)
                elif fault == 'duplicate': rows.append(copy.deepcopy(node))
                elif fault == 'skip': node['result'] = 'Skipped'
                else: node['nodeIdentifier'] = 'target/OtherSuite/' + case.split('/', 1)[1] + '()'
                with self.subTest(case=case, fault=fault), self.assertRaises(ValueError): probe.verify_cases(tree, 'currentcore')
        with self.context(), patch.dict(os.environ, {'YUEDU_RENEWAL_SELECTION': 'currentcore'}):
            prepared = probe.prepare(self.work)
            self.write(self.work / 'xcode-version.log', b'Portable guard only; no SDK execution\n')
            command = probe._currentcore_commands(self.work)['native']
            self.assertEqual(command.count('-resultBundlePath'), 1)
            self.assertEqual(command[command.index('-t') + 1], '3600')
            self.assertEqual(sum(value.startswith('-only-testing:') for value in command), 463)
            self.assertEqual(prepared['intendedArgumentLeafCount'], 466)
            for relative in probe.CURRENTCORE_LOGIN_ACTION_MATERIAL_INPUTS:
                raw = self.originals[relative]
                self.write(self.root / relative, raw + b' changed')
                with self.subTest(source=relative), self.assertRaisesRegex(ValueError, 'checked-out HEAD'):
                    probe._currentcore_source_state(self.work)
                self.write(self.root / relative, raw)



class LoginUIExploreCheckpointSelectionTests(unittest.TestCase):
    """Real declaration identities and fail-closed fabricated result/source guards."""
    setUp = RenewalProbeEvidenceTests.setUp
    write = RenewalProbeEvidenceTests.write
    write_json = RenewalProbeEvidenceTests.write_json
    git = RenewalProbeEvidenceTests.git
    context = RenewalProbeEvidenceTests.context
    tree = RenewalProbeEvidenceTests.tree

    def test_reviewed_app_methods_and_ui_fixture_keep_exact_scope_and_parameter_identities(self):
        added = probe.CURRENTCORE_EXPLORE_LIFECYCLE_QUALIFIED_CASES
        self.assertEqual(added, {'LegadoOriginalExploreLifecycleTests/pagePauseDrainsCategoryLoadBeforeReentry', 'DiscoverViewModelReloadTests/failedContextOpenDoesNotPublishCachedCategories', 'DiscoverViewModelReloadTests/cachedCategoriesBuildThePage', 'LegadoOriginalExploreLifecycleTests/failedPagePauseRetainsPendingUntilNextPageLifetime', 'DiscoverViewModelReloadTests/exploreOffGivesAnEmptyPage', 'LegadoOriginalExploreLifecycleTests/pagePauseRejectsEditedSourceBeforeSaving', 'DiscoverViewModelReloadTests/reloadStartsSectionsAnew'})
        for suite, names in probe.CURRENTCORE_EXPLORE_LIFECYCLE_CASES.items():
            relative = 'Tests/iOS/yuedu appTests/' + suite + '.swift'
            self.assertIn(relative, probe.SOURCE_INPUTS)
            source = (HERE.parents[1] / relative).read_text(encoding='utf8')
            declarations = re.findall(r'(?m)^[ \t]*@Test[^\n]*\n(?:[ \t]*@[^\n]*\n)*[ \t]*func[ \t]+(\w+)[ \t]*\(([^)]*)\)', source)
            self.assertEqual(len(declarations), len({name for name, _ in declarations}))
            for name in names:
                self.assertEqual([args for method, args in declarations if method == name], [''])
        caller = (HERE.parents[1] / 'Tests/iOS/yuedu appTests/BookSourceLoginTests.swift').read_text(encoding='utf8')
        self.assertEqual(re.findall(r'func blankLoginFieldIsRequired\s*\(([^)]*)\)\s*throws', caller), [''])
        self.assertIn('BookSourceLoginTests/blankLoginFieldIsRequired', probe.EXPECTED_CASES['currentcore'])
        self.assertEqual(len(probe.EXPECTED_CASES['currentcore']), 463)
        self.assertEqual(probe.expected_leaf_count('currentcore'), 466)
        self.assertEqual(len(probe.parameter_cases('currentcore')), 3)
        self.assertIn(probe.SDK_REQUIRED_CASE, probe.EXPECTED_CASES['currentcore'])
        for group in probe.EXPECTED_CASES:
            if group != 'currentcore': self.assertTrue(added.isdisjoint(probe.EXPECTED_CASES[group]))
        self.assertEqual(len(probe.CURRENTCORE_ROW_ACTION_INPUTS), 13)
        self.assertTrue(set(probe.CURRENTCORE_ROW_ACTION_INPUTS) <= set(probe.SOURCE_INPUTS))
        self.assertEqual(len(probe.CURRENTCORE_LOGIN_UI_EXPLORE_INPUTS), 27)
        self.assertTrue(set(probe.CURRENTCORE_LOGIN_UI_EXPLORE_INPUTS) <= set(probe.SOURCE_INPUTS))
        self.assertEqual(len(probe.SOURCE_INPUTS), 322)
        workflow = (HERE.parents[1] / '.github/workflows/reader-renewal-probe.yml').read_text(encoding='utf8')
        self.assertIn('Execute463 current-core definitions with466 exact native argument leaves', workflow)
        self.assertIn('Execute22 independent current-source macOS package XCTest cases', workflow)

    def test_new_app_cases_and_every_ui_page_owner_fail_closed_with_one_mandatory_sdk_invocation(self):
        for case in sorted(probe.CURRENTCORE_EXPLORE_LIFECYCLE_QUALIFIED_CASES):
            for fault in ('missing', 'duplicate', 'skip', 'wrongSuite'):
                tree = self.tree('currentcore'); rows = tree['testNodes'][0]['children']
                node = next(row for row in rows if row['nodeIdentifier'] == 'target/' + case + '()')
                if fault == 'missing': rows.remove(node)
                elif fault == 'duplicate': rows.append(copy.deepcopy(node))
                elif fault == 'skip': node['result'] = 'Skipped'
                else: node['nodeIdentifier'] = 'target/OtherSuite/' + case.split('/', 1)[1] + '()'
                with self.subTest(case=case, fault=fault), self.assertRaises(ValueError): probe.verify_cases(tree, 'currentcore')
        with self.context(), patch.dict(os.environ, {'YUEDU_RENEWAL_SELECTION': 'currentcore'}):
            prepared = probe.prepare(self.work)
            self.write(self.work / 'xcode-version.log', b'Portable guard only; no Swift SDK execution\n')
            command = probe._currentcore_commands(self.work)['native']
            self.assertEqual(command.count('-resultBundlePath'), 1)
            self.assertEqual(command[command.index('-t') + 1], '3600')
            self.assertEqual(sum(value.startswith('-only-testing:') for value in command), 463)
            self.assertIn('-only-testing:yuedu appTests/' + probe.SDK_REQUIRED_CASE, command)
            self.assertEqual(prepared['intendedArgumentLeafCount'], 466)
            for relative in dict.fromkeys(probe.CURRENTCORE_LOGIN_UI_EXPLORE_INPUTS + probe.CURRENTCORE_ROW_ACTION_INPUTS):
                raw = self.originals[relative]
                self.write(self.root / relative, raw + b' changed')
                with self.subTest(source=relative), self.assertRaisesRegex(ValueError, 'checked-out HEAD'):
                    probe._currentcore_source_state(self.work)
                self.write(self.root / relative, raw)


class LoginEventsDismissForegroundCheckpointTests(unittest.TestCase):
    """Exact source identities and synthetic evidence; no SDK/native execution."""
    setUp = RenewalProbeEvidenceTests.setUp
    write = RenewalProbeEvidenceTests.write
    write_json = RenewalProbeEvidenceTests.write_json
    git = RenewalProbeEvidenceTests.git
    context = RenewalProbeEvidenceTests.context
    tree = RenewalProbeEvidenceTests.tree

    def test_foreground_four_definitions_are_exact_and_preserve_old_modes_and_three_pairs(self):
        added = probe.CURRENTCORE_FOREGROUND_LIFECYCLE_QUALIFIED_CASES
        self.assertEqual(added, {
            'SelfRenewalAppOwnerTests/startupBootstrapCannotLaunchAfterBackground',
            'SelfRenewalAppOwnerTests/latestActivationWaitsForBootstrapAndRunsOnce',
            'SelfRenewalAppOwnerTests/backgroundGrantUsesSameWorkerAndSurvivesSceneCleanup',
            'SelfRenewalAppOwnerTests/cancelledForegroundBootstrapCannotCreateWorker'})
        relative = 'Tests/iOS/yuedu appTests/SelfRenewalAppOwnerTests.swift'
        source = (HERE.parents[1] / relative).read_text(encoding='utf8')
        declared = re.findall(r'(?m)^[ \t]*@Test[^\n]*\n(?:[ \t]*@[^\n]*\n)*[ \t]*func[ \t]+(\w+)[ \t]*\(([^)]*)\)', source)
        self.assertEqual(len(declared), 10)
        self.assertEqual(len({name for name, _ in declared}), 10)
        for case in added:
            self.assertEqual([args for name, args in declared if name == case.split('/')[1]], [''])
        self.assertEqual(len(probe.EXPECTED_CASES['currentcore']), 463)
        self.assertEqual(probe.expected_leaf_count('currentcore'), 466)
        self.assertEqual(len(probe.parameter_cases('currentcore')), 3)
        self.assertEqual(probe.parameter_cases('handoffrenewal'), probe.PARAMETER_CASES)
        self.assertIn(probe.SDK_REQUIRED_CASE, probe.EXPECTED_CASES['currentcore'])
        for group, cases in probe.EXPECTED_CASES.items():
            if group != 'currentcore': self.assertTrue(added.isdisjoint(cases), group)
        bound = set(probe.CURRENTCORE_LOGIN_EVENTS_DISMISS_LIFECYCLE_INPUTS)
        self.assertEqual(len(bound), 29)
        self.assertTrue(bound <= set(probe.SOURCE_INPUTS))
        self.assertEqual(len(probe.SOURCE_INPUTS), 322)
        self.assertEqual(len(set(probe.SOURCE_INPUTS)), 322)
        for path in ('Targets/Yuedu/SharedApp/yuedu_appApp.swift',
                'Modules/Services/SelfRenewal/SelfRenewalBackgroundTaskBridge.swift',
                'Tests/iOS/yuedu appTests/SelfRenewalForegroundMaterialRevalidationTests.swift',
                'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginUIEventsTest.kt',
                'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourcePersistLoginInfoTest.kt'):
            self.assertIn(path, bound)
        workflow = (HERE.parents[1] / '.github/workflows/reader-renewal-probe.yml').read_text(encoding='utf8')
        self.assertIn("&& 'loginui' || ''", workflow)
        self.assertIn('Execute22 independent current-source macOS package XCTest cases', workflow)

    def test_new_methods_and_all_three_slice_inputs_reject_tampering_before_single_required_sdk_run(self):
        for case in sorted(probe.CURRENTCORE_FOREGROUND_LIFECYCLE_QUALIFIED_CASES):
            for fault in ('missing', 'duplicate', 'skip', 'wrongSuite'):
                tree = self.tree('currentcore'); rows = tree['testNodes'][0]['children']
                node = next(row for row in rows if row['nodeIdentifier'] == 'target/' + case + '()')
                if fault == 'missing': rows.remove(node)
                elif fault == 'duplicate': rows.append(copy.deepcopy(node))
                elif fault == 'skip': node['result'] = 'Skipped'
                else: node['nodeIdentifier'] = 'target/OtherSuite/' + case.split('/', 1)[1] + '()'
                with self.subTest(case=case, fault=fault), self.assertRaises(ValueError):
                    probe.verify_cases(tree, 'currentcore')
        with self.context(), patch.dict(os.environ, {'YUEDU_RENEWAL_SELECTION': 'currentcore'}):
            prepared = probe.prepare(self.work)
            self.write(self.work / 'xcode-version.log', b'Portable guard only; no SDK execution\n')
            command = probe._currentcore_commands(self.work)['native']
            self.assertEqual(command.count('-resultBundlePath'), 1)
            self.assertEqual(command[command.index('-t') + 1], '3600')
            self.assertEqual(sum(value.startswith('-only-testing:') for value in command), 463)
            self.assertIn('-only-testing:yuedu appTests/' + probe.SDK_REQUIRED_CASE, command)
            self.assertEqual(prepared['intendedArgumentLeafCount'], 466)
            for relative in probe.CURRENTCORE_LOGIN_EVENTS_DISMISS_LIFECYCLE_INPUTS:
                raw = self.originals[relative]
                self.write(self.root / relative, raw + b' changed')
                with self.subTest(source=relative), self.assertRaisesRegex(ValueError, 'checked-out HEAD'):
                    probe._currentcore_source_state(self.work)
                self.write(self.root / relative, raw)

if __name__ == "__main__":
    unittest.main()
