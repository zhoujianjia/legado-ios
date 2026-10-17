#!/usr/bin/env python3
"""Check bootstrap dlsym entries in the final Mach-O export trie, without running it."""
import argparse
import json
from pathlib import Path
import re
import subprocess


# Pinned Mobile classLoader.cpp load_java_library/load_jimage_library and
# nativeLookup.cpp lookup_style and verifier.cpp require these exports even with
# exploded modules. Older class files need libverify's inference verifier.
# Direct-call entries such as JNI_CreateJavaVM do not need dynamic exports.
REQUIRED_EXPORTS = (
    "JDK_Canonicalize",
    "JIMAGE_Open",
    "JIMAGE_Close",
    "JIMAGE_FindResource",
    "JIMAGE_GetResource",
    "VerifyClassForMajorVersion",
    "Java_java_lang_Class_registerNatives",
    "Java_java_lang_ClassLoader_registerNatives",
    "Java_java_lang_System_registerNatives",
    "Java_java_lang_Thread_registerNatives",
)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    exports = subprocess.check_output(
        ["xcrun", "dyld_info", "-arch", "arm64", "-exports", str(args.executable)],
        text=True,
    )
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.with_suffix(".log").write_text(exports, encoding="utf-8")
    missing = [name for name in REQUIRED_EXPORTS
               if not re.search(r"(?<!\S)_" + re.escape(name) + r"(?!\S)", exports)]
    record = {
        "schemaVersion": 1,
        "requiredDynamicExportsPresent": not missing,
        "requiredExports": list(REQUIRED_EXPORTS),
        "missingExports": missing,
        "deviceValidationPassed": False,
    }
    args.report.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(record, indent=2))
    if missing:
        raise SystemExit("Missing required dynamic exports: " + ", ".join(missing))


if __name__ == "__main__":
    main()
