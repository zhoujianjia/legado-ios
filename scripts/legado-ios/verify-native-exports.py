#!/usr/bin/env python3
"""Check bootstrap/network dlsym entries in the final Mach-O export trie."""
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
    # java.net is not covered by the pinned ios-tools symbol keeper. The builtin
    # OnLoad hooks are needed as well as methods: net initializes IP availability.
    "JNI_OnLoad_net",
    "JNI_OnLoad_nio",
    "Java_java_net_InetAddress_isIPv4Available",
    "Java_java_net_InetAddress_isIPv6Supported",
    "Java_java_net_Inet4AddressImpl_getLocalHostName",
    "Java_java_net_Inet4AddressImpl_lookupAllHostAddr",
    "Java_java_net_Inet4AddressImpl_getHostByAddr",
    "Java_java_net_Inet4AddressImpl_isReachable0",
    "Java_java_net_Inet6AddressImpl_getLocalHostName",
    "Java_java_net_Inet6AddressImpl_lookupAllHostAddr",
    "Java_java_net_Inet6AddressImpl_getHostByAddr",
    "Java_java_net_Inet6AddressImpl_isReachable0",
    "Java_java_net_NetworkInterface_getAll",
    "Java_java_net_NetworkInterface_getByName0",
    "Java_java_net_NetworkInterface_getByIndex0",
    "Java_java_net_NetworkInterface_boundInetAddress0",
    "Java_java_net_NetworkInterface_getByInetAddress0",
    "Java_java_net_NetworkInterface_isUp0",
    "Java_java_net_NetworkInterface_isLoopback0",
    "Java_java_net_NetworkInterface_supportsMulticast0",
    "Java_java_net_NetworkInterface_isP2P0",
    "Java_java_net_NetworkInterface_getMacAddr0",
    "Java_java_net_NetworkInterface_getMTU0",
    "Java_java_net_NetworkInterface_init",
    "Java_sun_net_PortConfig_getLower0",
    "Java_sun_net_PortConfig_getUpper0",
    "Java_sun_net_spi_DefaultProxySelector_init",
    "Java_sun_net_spi_DefaultProxySelector_getSystemProxies",
    "Java_sun_net_dns_ResolverConfigurationImpl_fallbackDomain0",
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
