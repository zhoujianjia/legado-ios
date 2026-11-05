#!/usr/bin/env python3
"""Exercise removal gates against retained payloads and conflicting build settings."""
import importlib.util
import plistlib
import struct
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("clean_audit", Path(__file__).with_name("clean-package-audit.py"))
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class CleanPackageTests(unittest.TestCase):
    def test_binary_and_localized_markers_are_rejected(self):
        for raw in (b"$sSelfRenewalOwner", b"SELF_RENEWAL", b"anisette", b"https://new.ani.sidestore.io",
                    "自簽與續簽".encode(), "自签与续签".encode("utf-16-be")):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                audit.reject_bytes(raw, "fixture")
        audit.reject_bytes(b"Reader source search cache and ordinary TLS certificate", "fixture")

    def settings(self):
        return [{"target": name, "buildSettings": dict(
            CONFIGURATION="Release", PLATFORM_NAME="iphoneos", ARCHS="arm64", SWIFT_VERSION="5.0",
            SWIFT_OPTIMIZATION_LEVEL="-O", SWIFT_COMPILATION_MODE="wholemodule", ENABLE_DEBUG_DYLIB="NO",
            PRODUCT_BUNDLE_IDENTIFIER=identifier, FULL_PRODUCT_NAME=product, CURRENT_PROJECT_VERSION="33",
            CODE_SIGNING_ALLOWED="NO", CODE_SIGNING_REQUIRED="NO", CODE_SIGN_ENTITLEMENTS="")}
            for name, (identifier, product) in audit.TARGETS.items()]

    def test_every_embedded_target_must_be_optimized_and_production(self):
        self.assertEqual(len(audit.settings_audit(self.settings())), 3)
        for key, value in (("CURRENT_PROJECT_VERSION", "29"), ("SWIFT_OPTIMIZATION_LEVEL", "-Onone"),
                           ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "DEBUG"), ("OTHER_SWIFT_FLAGS", "-D DEBUG"),
                           ("CODE_SIGNING_ALLOWED", "YES")):
            items = self.settings()
            items[-1]["buildSettings"][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                audit.settings_audit(items)
        with self.assertRaises(ValueError):
            audit.settings_audit(self.settings()[:2])

    def test_actual_compiler_roster_rejects_archive_and_removed_code(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "YueduReader.SwiftFileList"
            items = self.settings()
            items[0]["buildSettings"]["OBJROOT"] = temporary
            normal = b"/checkout/Modules/Reader.swift\n/checkout/Targets/Yuedu/App.swift\n"
            path.write_bytes(normal)
            self.assertEqual(len(audit.compiled_inputs(items)), 1)
            for extra in (b"/checkout/archive/reference.swift\n", b"/checkout/Modules/SelfRenewalOwner.swift\n"):
                path.write_bytes(normal + extra)
                with self.assertRaises(ValueError):
                    audit.compiled_inputs(items)

    def test_app_scan_checks_archives_binaries_and_embedded_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "YueduReader.app"
            for identifier, product in audit.TARGETS.values():
                bundle = app if product == app.name else app / "PlugIns" / product
                bundle.mkdir(parents=True)
                (bundle / "Info.plist").write_bytes(plistlib.dumps({"CFBundleVersion": "33", "CFBundleIdentifier": identifier,
                                                                 "CFBundleDisplayName": "Reader"}))
            self.assertEqual(len(audit.app_audit(app)["bundles"]), 3)
            payload = app / "reader.binary"
            payload.write_bytes(b"x" * ((1 << 20) - 5) + b"SelfRenewal")
            with self.assertRaises(ValueError):
                audit.app_audit(app)
            payload.write_bytes(b"reader")
            reference = app / "archive"
            reference.mkdir()
            with self.assertRaises(ValueError):
                audit.app_audit(app)
            reference.rmdir()
            (app / "PlugIns/yuedu_app_Widget.appex/Info.plist").write_bytes(plistlib.dumps({"CFBundleVersion": "29"}))
            with self.assertRaises(ValueError):
                audit.app_audit(app)

    def test_default_sideload_name_gate_covers_app_and_each_extension(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "YueduReader.app"
            for identifier, product in audit.TARGETS.values():
                bundle = app if product == app.name else app / "PlugIns" / product
                bundle.mkdir(parents=True)
                (bundle / "Info.plist").write_bytes(plistlib.dumps({"CFBundleVersion": "33", "CFBundleIdentifier": identifier,
                                                                 "CFBundleDisplayName": "Reader"}))
            localized = app / "zh-Hans.lproj/InfoPlist.strings"
            localized.parent.mkdir()
            localized.write_text('"CFBundleDisplayName" = "阅读";\n', encoding="utf-8")
            self.assertEqual(len(audit.app_audit(app)["bundles"]), 3)
            for _, product in audit.TARGETS.values():
                path = (app if product == app.name else app / "PlugIns" / product) / "Info.plist"
                original = path.read_bytes()
                info = plistlib.loads(original)
                info["CFBundleDisplayName"] = "阅读"
                path.write_bytes(plistlib.dumps(info))
                with self.subTest(product=product), self.assertRaisesRegex(ValueError, "sideload registration"):
                    audit.app_audit(app)
                path.write_bytes(original)

    def test_build33_is_required_by_all_target_settings_and_packaged_bundles(self):
        self.assertEqual(audit.BUILD, "33")
        build_script = Path(__file__).with_name("build.sh").read_text(encoding="utf-8")
        self.assertIn("CURRENT_PROJECT_VERSION=33", build_script)
        self.assertTrue(all(settings["CURRENT_PROJECT_VERSION"] == "33"
                            for settings in audit.settings_audit(self.settings()).values()))
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "YueduReader.app"
            paths = []
            for identifier, product in audit.TARGETS.values():
                bundle = app if product == app.name else app / "PlugIns" / product
                bundle.mkdir(parents=True)
                path = bundle / "Info.plist"
                path.write_bytes(plistlib.dumps({"CFBundleVersion": "33", "CFBundleIdentifier": identifier,
                                                 "CFBundleDisplayName": "Reader"}))
                paths.append(path)
            self.assertTrue(all(bundle["build"] == "33" for bundle in audit.app_audit(app)["bundles"]))
            for index, path in enumerate(paths):
                original = path.read_bytes()
                for version in ("32", "34", "", 33):
                    settings = self.settings()
                    settings[index]["buildSettings"]["CURRENT_PROJECT_VERSION"] = version
                    info = plistlib.loads(original)
                    info["CFBundleVersion"] = version
                    path.write_bytes(plistlib.dumps(info))
                    with self.subTest(target=settings[index]["target"], version=version):
                        with self.assertRaisesRegex(ValueError, "CURRENT_PROJECT_VERSION"):
                            audit.settings_audit(settings)
                        with self.assertRaisesRegex(ValueError, "packaged build"):
                            audit.app_audit(app)
                    path.write_bytes(original)

    def test_signer_resource_gate_rejects_java_and_preserves_real_fat_frameworks(self):
        java_class = bytes.fromhex("cafebabe00000048") + bytes(40)
        with self.assertRaisesRegex(ValueError, "FAT/Java header"):
            audit.signing_binary_audit(java_class, 336, "lib/modules/java.base/java/lang/Object.class")
        fat = struct.pack(">IIiiIII", 0xcafebabe, 1, 0x100000c, 0, 4096, 128, 12)
        self.assertTrue(audit.signing_binary_audit(fat, 4224, "Frameworks/Valid.framework/Valid"))
        with self.assertRaisesRegex(ValueError, "FAT slice bounds"):
            audit.signing_binary_audit(fat, 4200, "Frameworks/Truncated.framework/Truncated")
        self.assertFalse(audit.signing_binary_audit(bytes.fromhex("dadafeca01000100"), 1000, "lib/lib/modules"))


if __name__ == "__main__":
    unittest.main()
