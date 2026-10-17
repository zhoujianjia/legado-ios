#!/usr/bin/env python3
"""Backport pinned Apple W^X state handling to Zero without enabling iOS JIT."""
import argparse
import hashlib
import json
from pathlib import Path

TARGET_RELATIVE_PATH = "src/hotspot/os_cpu/bsd_zero/os_bsd_zero.cpp"
DONOR_RELATIVE_PATH = "src/hotspot/os_cpu/bsd_aarch64/os_bsd_aarch64.cpp"
# Both files are from mobile@c1ed06aaef34c8dccf71e236d1ffa20918a77cfb.
TARGET_SOURCE_SHA256 = "8451f0f8bea69dbb16e6f26c1dbd4c7b3e96e39850206e5a0e91940bf030da08"
DONOR_SOURCE_SHA256 = "78a0c5aa1d2b5b696ef94ded1f5d50d0aeb8a8e93bd4e13428bcc198ecf021a5"
PREPARED_SHA256 = "702ba78cb0c9c19e0c178d2dd34479b2a03ff2aa3c43de903755c3d49b866dcc"
INCLUDE_ANCHOR = b'#include "runtime/stubRoutines.hpp"\n'
THREAD_INCLUDE = b'#include "runtime/thread.inline.hpp"\n'
OLD_BLOCK = b"""#if defined(AARCH64) && defined(__APPLE__)
void os::current_thread_enable_wx(WXMode mode) {
#ifndef __IOS__
  pthread_jit_write_protect_np(mode == WXExec);
#endif
}
#endif"""
DONOR_START = b"#ifdef MACOS_AARCH64\nTHREAD_LOCAL bool os::_jit_exec_enabled;"
DONOR_END = b"\n#endif // MACOS_AARCH64"
DEFAULT_MODE = b"WXMode DefaultWXWriteMode;"
REQUIRED_HOOKS = (
    b"THREAD_LOCAL bool os::_jit_exec_enabled;",
    b"void os::current_thread_enable_wx(WXMode mode) {",
    b"bool Thread::wx_enable_write() {",
    b"void os::thread_wx_enable_write_impl() {",
)


def _backport(target: bytes, donor: bytes) -> bytes:
    """Transplant only the complete donor hooks, its default mode, and an include."""
    if target.count(OLD_BLOCK) != 1 or target.count(INCLUDE_ANCHOR) != 1 or THREAD_INCLUDE in target:
        raise ValueError("Expected exactly the pinned Zero W^X block and include anchor")
    if donor.count(DONOR_START) != 1 or donor.count(DEFAULT_MODE) != 1:
        raise ValueError("Expected exactly the pinned donor W^X state implementation")
    start = donor.index(DONOR_START) + len(b"#ifdef MACOS_AARCH64\n")
    end = donor.find(DONOR_END, start)
    if end < 0:
        raise ValueError("Pinned donor W^X closing guard is missing")
    hooks = donor[start:end]
    if any(hooks.count(hook) != 1 for hook in REQUIRED_HOOKS):
        raise ValueError("Pinned donor W^X hooks are incomplete")
    # Keep the donor's #ifndef __IOS__ around the real pthread permission call.
    # This ports state transitions rather than supplying empty linker stubs.
    replacement = b"#ifdef MACOS_AARCH64\n" + DEFAULT_MODE + b"\n" + hooks + DONOR_END
    return target.replace(INCLUDE_ANCHOR, INCLUDE_ANCHOR + THREAD_INCLUDE).replace(OLD_BLOCK, replacement)


def prepare(mobile_root: Path) -> dict:
    target = mobile_root / TARGET_RELATIVE_PATH
    donor = mobile_root / DONOR_RELATIVE_PATH
    target_data, donor_data = target.read_bytes(), donor.read_bytes()
    target_hash = hashlib.sha256(target_data).hexdigest()
    if hashlib.sha256(donor_data).hexdigest() != DONOR_SOURCE_SHA256:
        raise ValueError("Pinned W^X donor SHA-256 mismatch; refusing to modify Zero")
    if target_hash == PREPARED_SHA256:
        changed = False
    elif target_hash == TARGET_SOURCE_SHA256:
        prepared = _backport(target_data, donor_data)
        if hashlib.sha256(prepared).hexdigest() != PREPARED_SHA256:
            raise ValueError("Prepared Zero W^X SHA-256 mismatch; refusing to modify Zero")
        target.write_bytes(prepared)
        changed = True
    else:
        raise ValueError("Pinned Zero source SHA-256 mismatch; refusing to modify Zero")
    return {"target": TARGET_RELATIVE_PATH, "targetSourceSHA256": TARGET_SOURCE_SHA256,
            "donorSourceSHA256": DONOR_SOURCE_SHA256, "preparedSHA256": PREPARED_SHA256,
            "changed": changed, "enablesIOSJIT": False}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mobile-root", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(prepare(args.mobile_root), indent=2))


if __name__ == "__main__": main()
