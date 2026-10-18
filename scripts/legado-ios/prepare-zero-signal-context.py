#!/usr/bin/env python3
"""Port pinned Darwin ARM64 signal-PC accessors to Zero; not TLS validation."""
import argparse
import hashlib
import json
from pathlib import Path


TARGET_RELATIVE_PATH = "src/hotspot/os_cpu/bsd_zero/os_bsd_zero.cpp"
DONOR_RELATIVE_PATH = "src/hotspot/os_cpu/bsd_aarch64/os_bsd_aarch64.cpp"
# mobile@c1ed06aaef34c8dccf71e236d1ffa20918a77cfb after prepare-zero-wx.py.
TARGET_SOURCE_SHA256 = "702ba78cb0c9c19e0c178d2dd34479b2a03ff2aa3c43de903755c3d49b866dcc"
DONOR_SOURCE_SHA256 = "78a0c5aa1d2b5b696ef94ded1f5d50d0aeb8a8e93bd4e13428bcc198ecf021a5"
PREPARED_SHA256 = "3eeff75065b744cb7943c28ccfb5d68511a6b3740f0c94d5314eb2b995cde6e3"
GETTER_ANCHOR = b"address os::Posix::ucontext_get_pc("
SETTER_ANCHOR = b"void os::Posix::ucontext_set_pc("
OLD_BLOCK = b"""address os::Posix::ucontext_get_pc(const ucontext_t* uc) {
  ShouldNotCallThis();
  return nullptr;
}

void os::Posix::ucontext_set_pc(ucontext_t * uc, address pc) {
  ShouldNotCallThis();
}"""
DONOR_MACROS = (
    b"#define DU3_PREFIX(s, m) __ ## s.__ ## m\n",
    b"#define context_pc   uc_mcontext->DU3_PREFIX(ss,pc)\n",
)
DONOR_GETTER = b"""address os::Posix::ucontext_get_pc(const ucontext_t * uc) {
  return (address)uc->context_pc;
}"""
DONOR_SETTER = b"""void os::Posix::ucontext_set_pc(ucontext_t * uc, address pc) {
  uc->context_pc = (intptr_t)pc ;
}"""


def _backport(target: bytes, donor: bytes) -> bytes:
    """Replace just the two stubs, retaining their exact non-ARM64 fallback."""
    if (target.count(OLD_BLOCK) != 1 or target.count(GETTER_ANCHOR) != 1
            or target.count(SETTER_ANCHOR) != 1
            or b"#define DU3_PREFIX" in target or b"#define context_pc" in target):
        raise ValueError("Expected only the pinned Zero signal-PC stubs")
    parts = (*DONOR_MACROS, DONOR_GETTER, DONOR_SETTER)
    if (any(donor.count(part) != 1 for part in parts)
            or donor.count(GETTER_ANCHOR) != 1 or donor.count(SETTER_ANCHOR) != 1
            or donor.count(b"#define DU3_PREFIX") != 1
            or donor.count(b"#define context_pc") != 1):
        raise ValueError("Expected unique, complete pinned Darwin signal-PC definitions")
    # Copy complete source bytes from the same-revision donor. This reads/writes
    # a saved PC only; it does not change signal dispatch or execution permissions.
    copied = [donor[donor.index(part):donor.index(part) + len(part)] for part in parts]
    replacement = (b"#ifdef MACOS_AARCH64\n" + copied[0] + copied[1] + b"\n"
                   + copied[2] + b"\n\n" + copied[3] + b"\n#else\n" + OLD_BLOCK
                   + b"\n#endif // MACOS_AARCH64")
    return target.replace(OLD_BLOCK, replacement)


def prepare(mobile_root: Path) -> dict:
    target = mobile_root / TARGET_RELATIVE_PATH
    donor = mobile_root / DONOR_RELATIVE_PATH
    target_data, donor_data = target.read_bytes(), donor.read_bytes()
    target_hash = hashlib.sha256(target_data).hexdigest()
    if hashlib.sha256(donor_data).hexdigest() != DONOR_SOURCE_SHA256:
        raise ValueError("Pinned signal-PC donor SHA-256 mismatch; refusing to modify Zero")
    if target_hash == PREPARED_SHA256:
        changed = False
    elif target_hash == TARGET_SOURCE_SHA256:
        prepared = _backport(target_data, donor_data)
        if hashlib.sha256(prepared).hexdigest() != PREPARED_SHA256:
            raise ValueError("Prepared Zero signal-PC SHA-256 mismatch; refusing to modify Zero")
        target.write_bytes(prepared)
        changed = True
    else:
        raise ValueError("Pinned WX-prepared Zero source SHA-256 mismatch; refusing to modify Zero")
    return {"target": TARGET_RELATIVE_PATH, "targetSourceSHA256": TARGET_SOURCE_SHA256,
            "donorSourceSHA256": DONOR_SOURCE_SHA256, "preparedSHA256": PREPARED_SHA256,
            "changed": changed, "changesSignalHandler": False, "enablesIOSJIT": False,
            "provesTLS": False}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mobile-root", required=True, type=Path)
    print(json.dumps(prepare(parser.parse_args().mobile_root), indent=2))


if __name__ == "__main__":
    main()
