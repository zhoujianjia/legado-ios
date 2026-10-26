#!/usr/bin/env python3
"""Audit the clean reader and reject Java files that IPA signers misclassify."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import struct
import subprocess

REPO = Path(__file__).resolve().parents[2]
BUILD = "31"
FORBIDDEN = re.compile(rb"selfrenewal|self[-_]renewal|anisette|new\.ani\.sidestore", re.I)
UI_MARKERS = tuple(text.encode(encoding) for text in ("自簽與續簽", "自签与续签", "自續簽驗證")
                   for encoding in ("utf-8", "utf-16-be", "utf-16-le"))
TARGETS = {
    "yuedu app": ("local.zhoujianjia.legado-reader", "YueduReader.app"),
    "Yuedu-Reader Widget": ("local.zhoujianjia.legado-reader.widget", "yuedu_app_Widget.appex"),
    "Yuedu-Reader ShareExtension": ("local.zhoujianjia.legado-reader.shareextension", "yuedu_app_ShareExtension.appex"),
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def reject_bytes(raw, location):
    require(FORBIDDEN.search(raw) is None and not any(marker in raw for marker in UI_MARKERS),
            "Archived feature marker in " + str(location))


def signing_binary_audit(header, byte_count, location):
    """Match the signer's magic-based admission, then validate FAT bounds.

    Java class files share CAFEBABE with FAT Mach-O. Every such resource must be
    inside the JDK module image or a JAR, while real FAT frameworks stay intact.
    """
    magics = {b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
              b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True)}
    kind = magics.get(header[:4])
    if kind is None:
        return False
    require(len(header) >= 8, "Truncated FAT header: " + str(location))
    order, wide = kind
    count = struct.unpack_from(order + "I", header, 4)[0]
    require(0 < count < 40, "FAT/Java header would fail IPA signing: " + str(location))
    record_size = 32 if wide else 20
    require(len(header) >= 8 + count * record_size, "Truncated FAT architecture table: " + str(location))
    for index in range(count):
        offset = 8 + index * record_size
        start, size = struct.unpack_from(order + ("QQ" if wide else "II"), header, offset + 8)
        require(size > 0 and start >= 8 + count * record_size and start + size <= byte_count,
                "FAT slice bounds exceed file size: " + str(location))
    return True


def source_audit():
    count = 0
    for relative in ("Modules", "Targets", "Resources", "Widget", "ShareExtension"):
        for path in (REPO / relative).rglob("*"):
            if not path.is_file():
                continue
            reject_bytes(path.relative_to(REPO).as_posix().encode(), path)
            if path.suffix in (".swift", ".strings", ".plist", ".entitlements"):
                reject_bytes(path.read_bytes(), path)
                count += 1
    for rel in ("Info.plist", "Yuedu-Reader.xcodeproj/project.pbxproj"):
        reject_bytes((REPO / rel).read_bytes(), rel)
    # The archive must stay outside every synchronized source/resource group.
    project = (REPO / "Yuedu-Reader.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
    require(re.search(r"\bpath\s*=\s*\"?archive(?:/|;)", project, re.I) is None,
            "Archive joined an Xcode source group")
    archived = list((REPO / "archive/self-renewal-20261025/Modules").rglob("*.swift"))
    require(len(archived) == 40, "Expected the complete 40-file archived implementation")
    return {"activeTextFilesChecked": count, "archivedSwiftFiles": len(archived),
            "archiveOutsideApplicationGroups": True}


def settings_audit(items):
    require(isinstance(items, list) and len(items) == 3, "Expected three actual target settings")
    facts = {}
    for target, (identifier, product) in TARGETS.items():
        matches = [i["buildSettings"] for i in items if i.get("target") == target]
        require(len(matches) == 1, "Missing/duplicate target settings: " + target)
        settings = matches[0]
        expected = {"CONFIGURATION": "Release", "PLATFORM_NAME": "iphoneos", "ARCHS": "arm64",
                    "SWIFT_VERSION": "5.0", "SWIFT_OPTIMIZATION_LEVEL": "-O",
                    "SWIFT_COMPILATION_MODE": "wholemodule", "ENABLE_DEBUG_DYLIB": "NO",
                    "PRODUCT_BUNDLE_IDENTIFIER": identifier, "FULL_PRODUCT_NAME": product,
                    "CURRENT_PROJECT_VERSION": BUILD, "CODE_SIGNING_ALLOWED": "NO",
                    "CODE_SIGNING_REQUIRED": "NO", "CODE_SIGN_ENTITLEMENTS": ""}
        for key, value in expected.items():
            require(settings.get(key, "" if value == "" else None) == value,
                    "Unexpected Release setting: " + target + " " + key)
        conditions = (settings.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "") + " "
                      + settings.get("GCC_PREPROCESSOR_DEFINITIONS", "")).split()
        flags = settings.get("OTHER_SWIFT_FLAGS", "").split()
        require(not any(t == "DEBUG" or t.startswith("DEBUG=") for t in conditions), "DEBUG target")
        require(not any(t.startswith("-DDEBUG") for t in flags), "DEBUG Swift flags")
        require(not any(flags[i] == "-D" and flags[i+1].startswith("DEBUG") for i in range(len(flags)-1)),
                "DEBUG Swift flags")
        require(not any(t in ("-Onone", "-Ounchecked", "-single-file") for t in flags),
                "Conflicting optimization flags")
        facts[target] = expected
    return facts


def compiled_inputs(items):
    main = next(i["buildSettings"] for i in items if i.get("target") == "yuedu app")
    objroot = Path(main["OBJROOT"])
    require(objroot.is_absolute() and objroot.is_dir(), "Actual compiler intermediates absent")
    rosters = []
    for path in objroot.rglob("*.SwiftFileList"):
        raw = path.read_bytes()
        if b"/Modules/" not in raw or b"/Targets/Yuedu/" not in raw:
            continue
        reject_bytes(raw, path)
        require(b"/archive/" not in raw.lower(), "Archive in actual Swift compiler input")
        rosters.append({"name": path.name, "sha256": hashlib.sha256(raw).hexdigest(),
                        "lines": len(raw.splitlines())})
    require(rosters, "Actual main application Swift compiler inputs absent")
    return rosters


def app_audit(app):
    require(app.is_dir() and app.name == "YueduReader.app", "Reader app absent")
    count = total = fat_count = 0
    infos = []
    for bundle in (app, app / "PlugIns/yuedu_app_Widget.appex", app / "PlugIns/yuedu_app_ShareExtension.appex"):
        info = plistlib.loads((bundle / "Info.plist").read_bytes())
        require(info.get("CFBundleVersion") == BUILD, "Unexpected packaged build")
        expected = next(value[0] for value in TARGETS.values() if value[1] == bundle.name)
        require(info.get("CFBundleIdentifier") == expected, "Unexpected packaged identity")
        # SideStore versions without name transliteration submit this raw value
        # as Apple's appIdName; localized InfoPlist.strings can keep the UI name.
        display_name = info.get("CFBundleDisplayName", info.get("CFBundleName"))
        require(isinstance(display_name, str) and re.fullmatch(r"[A-Za-z0-9]+(?: [A-Za-z0-9]+)*", display_name),
                "Default bundle name must use ASCII letters/numbers/spaces for sideload registration: " + bundle.name)
        require(not any("selfrenewal" in str(v).lower() for v in info.get("BGTaskSchedulerPermittedIdentifiers", [])),
                "Archived background task identifier")
        infos.append({"bundle": bundle.name, "identifier": expected, "build": BUILD,
                      "defaultDisplayName": display_name})
    for path in app.rglob("*"):
        require(not path.is_symlink(), "Unexpected package symlink")
        rel = path.relative_to(app)
        reject_bytes(rel.as_posix().encode(), rel)
        require("archive" not in {part.lower() for part in rel.parts}, "Reference archive in app")
        if not path.is_file():
            continue
        require(path.suffix.lower() not in (".ipa", ".p12", ".pfx", ".swift", ".mobileprovision"),
                "Unexpected source, signing or nested installer payload")
        count += 1
        total += path.stat().st_size
        with path.open("rb") as stream:
            fat_count += signing_binary_audit(stream.read(1288), path.stat().st_size, rel)
            stream.seek(0)
            tail = b""
            while chunk := stream.read(1 << 20):
                reject_bytes(tail + chunk, rel)
                tail = chunk[-128:]
    return {"filesScanned": count, "bytesScanned": total, "bundles": infos,
            "fatFrameworksChecked": fat_count, "signerMisclassifiedJavaResourcesAbsent": True,
            "archivedMarkersAbsent": True, "referenceArchiveAbsent": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-only", action="store_true")
    parser.add_argument("--app", type=Path)
    parser.add_argument("--settings", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    source = subprocess.check_output(["git", "-C", str(REPO), "rev-parse", "HEAD"], text=True).strip()
    require(re.fullmatch(r"[0-9a-f]{40}", source) is not None, "Invalid source identity")
    report = {"schemaVersion": 1, "build": BUILD, "sourceCommit": source,
              "workflowRunID": os.environ.get("GITHUB_RUN_ID"),
              "sourceExclusion": source_audit()}
    if not args.source_only:
        require(args.app is not None and args.settings is not None, "Actual app/settings required")
        settings = json.loads(args.settings.read_bytes())
        report.update(actualBuildSettings=settings_audit(settings), compilerInputs=compiled_inputs(settings),
                      packageExclusion=app_audit(args.app))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x", encoding="utf-8") as stream:
        json.dump(report, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
    print(json.dumps({"status": "passed", "build": BUILD, "sourceOnly": args.source_only}))


if __name__ == "__main__":
    main()
