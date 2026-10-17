#!/usr/bin/env python3
"""Keep the pinned iOS Zero code cache non-executable; never enable JIT."""
import argparse
import hashlib
import json
from pathlib import Path


TARGET_RELATIVE_PATH = "src/hotspot/share/memory/memoryReserver.cpp"
# Complete unmodified file from mobile@c1ed06aaef34c8dccf71e236d1ffa20918a77cfb.
TARGET_SOURCE_SHA256 = "b04ee67ec46ab113d21e5a71638c0f99fc9232243e9c2cb965cb31796be96d6f"
PREPARED_SHA256 = "b48140304e19ed5951fb19fd377ef911cf43690bc50088b7b7c9192f3355d582"
FUNCTION_ANCHOR = b"ReservedSpace CodeMemoryReserver::reserve("
OLD_BLOCK = b"""ReservedSpace CodeMemoryReserver::reserve(size_t size,
                                          size_t alignment,
                                          size_t page_size) {
  return MemoryReserver::reserve(nullptr /* requested_address */,
                                 size,
                                 alignment,
                                 page_size,
                                 ExecMem,
                                 mtCode);
}"""
NEW_BLOCK = b"""ReservedSpace CodeMemoryReserver::reserve(size_t size,
                                          size_t alignment,
                                          size_t page_size) {
  // Zero stores metadata and pointers to precompiled C++ interpreter functions.
  // Its iOS code cache must remain data, without requesting executable pages.
#if defined(__IOS__) && defined(ZERO)
  constexpr bool executable = !ExecMem;
#else
  constexpr bool executable = ExecMem;
#endif
  return MemoryReserver::reserve(nullptr /* requested_address */,
                                 size,
                                 alignment,
                                 page_size,
                                 executable,
                                 mtCode);
}"""


def _adapt(source: bytes) -> bytes:
    if source.count(FUNCTION_ANCHOR) != 1 or source.count(OLD_BLOCK) != 1 or NEW_BLOCK in source:
        raise ValueError("Expected exactly the pinned CodeMemoryReserver::reserve implementation")
    return source.replace(OLD_BLOCK, NEW_BLOCK, 1)


def prepare(mobile_root: Path) -> dict:
    target = mobile_root / TARGET_RELATIVE_PATH
    data = target.read_bytes()
    source_hash = hashlib.sha256(data).hexdigest()
    if source_hash == PREPARED_SHA256:
        changed = False
    elif source_hash == TARGET_SOURCE_SHA256:
        prepared = _adapt(data)
        if hashlib.sha256(prepared).hexdigest() != PREPARED_SHA256:
            raise ValueError("Prepared Zero code-cache SHA-256 mismatch; refusing to modify source")
        target.write_bytes(prepared)
        changed = True
    else:
        raise ValueError("Pinned Zero code-cache source SHA-256 mismatch; refusing to modify source")
    return {"target": TARGET_RELATIVE_PATH, "targetSourceSHA256": TARGET_SOURCE_SHA256,
            "preparedSHA256": PREPARED_SHA256, "changed": changed,
            "nonExecutableCodeCacheCondition": "defined(__IOS__) && defined(ZERO)",
            "enablesIOSJIT": False}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mobile-root", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(prepare(args.mobile_root), indent=2))


if __name__ == "__main__":
    main()
