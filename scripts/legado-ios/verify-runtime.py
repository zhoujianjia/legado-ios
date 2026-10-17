#!/usr/bin/env python3
"""Reject incomplete Zero payloads; this is static validation, not a JVM execution test."""
import argparse
import json
from pathlib import Path
import plistlib
import zipfile

HERE = Path(__file__).resolve().parent
PROBES = {
    "java.base": "java/lang/Object.class",
    "java.xml": "javax/xml/parsers/DocumentBuilderFactory.class",
    "java.desktop": "java/beans/Introspector.class",
}

def validate(java_home: Path, jar: Path | None = None, xcframework: Path | None = None) -> dict:
    lock = json.loads((HERE / "runtime-lock.json").read_text(encoding="utf-8"))
    for module in lock["requiredModules"]:
        if not (java_home / "modules" / module / "module-info.class").is_file():
            raise ValueError(f"Missing required exploded module: {module}")
    for module, probe in PROBES.items():
        if not (java_home / "modules" / module / probe).is_file():
            raise ValueError(f"Missing required class: {module}/{probe}")
    if (java_home / "lib/modules").is_dir():
        raise ValueError("Exploded modules belong in java.home/modules; lib/modules is reserved for a jimage file")
    if jar is not None:
        with zipfile.ZipFile(jar) as archive:
            names = set(archive.namelist())
            for name in ["io/yuedu/legado/LegadoRuntime.class", "io/yuedu/legado/NativeHost.class"]:
                if name not in names: raise ValueError(f"JAR is missing facade class: {name}")
            if not any(name.endswith("/javascript/Context.class") for name in names):
                raise ValueError("JAR is missing the pinned Rhino engine; supply a fat JAR")
    if xcframework is not None:
        with (xcframework / "Info.plist").open("rb") as source: info = plistlib.load(source)
        slices = info.get("AvailableLibraries", [])
        for simulator in [False, True]:
            matching = [s for s in slices if s.get("SupportedPlatform") == "ios" and (s.get("SupportedPlatformVariant") == "simulator") == simulator and "arm64" in s.get("SupportedArchitectures", [])]
            if not matching: raise ValueError(f"Missing arm64 {'simulator' if simulator else 'device'} XCFramework slice")
            for item in matching:
                folder = xcframework / item["LibraryIdentifier"]
                if not (folder / item["LibraryPath"]).is_file(): raise ValueError("XCFramework library file is missing")
                if not (folder / item.get("HeadersPath", "Headers") / "jni.h").is_file(): raise ValueError("XCFramework JNI header is missing")
    return {"staticValidationPassed": True, "modules": lock["requiredModules"], "deviceValidationPassed": False}

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--java-home", required=True, type=Path)
    parser.add_argument("--jar", type=Path)
    parser.add_argument("--xcframework", type=Path)
    args = parser.parse_args()
    print(json.dumps(validate(args.java_home, args.jar, args.xcframework), indent=2))

if __name__ == "__main__": main()
