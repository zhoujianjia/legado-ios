#!/usr/bin/env python3
"""Adapt one stale upstream native registration for the exact pinned Mobile sources."""
import argparse
import hashlib
import json
from pathlib import Path

# ios-tools@2f0a489b48cdb13901185be051004f7a9c23bf14:
# openjdk-ext/src/hotspot/symbol_keeper.cpp lines 381, 831 and 1281 retain
# a JNI method absent from mobile@c1ed06aaef34c8dccf71e236d1ffa20918a77cfb.
# UnixNativeDispatcher.c lines 391-398 now report this capability in init().
PINNED_SOURCE_SHA256 = "db8636b8e24cbd4420a9de5f92cdeaa1fc18a15d6153ac4262084af3f404bee2"
STALE_SYMBOL = b"Java_sun_nio_fs_UnixNativeDispatcher_fchmodatNoFollowSupported0"
REGISTRATION_LINES = (
    b"extern void* " + STALE_SYMBOL + b";",
    b"void* l2252 = " + STALE_SYMBOL + b";",
    b'fprintf(stderr, "' + STALE_SYMBOL + b': %p\\n", l2252);',
)


def remove_stale_registration(source: bytes) -> bytes:
    lines = source.splitlines(keepends=True)
    stripped = [line.rstrip(b"\r\n") for line in lines]
    if source.count(STALE_SYMBOL) != 3 or any(stripped.count(line) != 1 for line in REGISTRATION_LINES):
        raise ValueError("Expected exactly the three known stale symbol registration lines")
    return b"".join(line for line, content in zip(lines, stripped) if content not in REGISTRATION_LINES)


def prepare(source: Path, destination: Path) -> dict:
    data = source.read_bytes()
    source_hash = hashlib.sha256(data).hexdigest()
    if source_hash != PINNED_SOURCE_SHA256:
        raise ValueError("Pinned symbol_keeper.cpp SHA-256 mismatch; review source revisions before adapting")
    prepared = remove_stale_registration(data)
    destination.write_bytes(prepared)
    return {"sourceSHA256": source_hash, "preparedSHA256": hashlib.sha256(prepared).hexdigest(),
            "removedNativeRegistration": STALE_SYMBOL.decode("ascii"), "removedLines": 3}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--destination", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(prepare(args.source, args.destination), indent=2))


if __name__ == "__main__": main()
