#!/usr/bin/env python3
"""Fetch fixed source revisions and verify libffi bytes. Never fetch an unsigned JVM binary."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import urllib.request

HERE = Path(__file__).resolve().parent


def prepared_edits() -> dict[str, frozenset[str]]:
    """Allow only the reviewed outputs of this directory's three fixed stages."""
    stages = []
    for name in ("zero-wx", "zero-signal-context", "zero-code-cache"):
        spec = importlib.util.spec_from_file_location("fetch_prepared_" + name.replace("-", "_"),
                                                     HERE / ("prepare-" + name + ".py"))
        stage = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(stage)
        stages.append(stage)
    wx, signal, code_cache = stages
    if (wx.TARGET_RELATIVE_PATH != signal.TARGET_RELATIVE_PATH
            or signal.TARGET_SOURCE_SHA256 != wx.PREPARED_SHA256
            or signal.PREPARED_SHA256 != wx.SIGNAL_PREPARED_SHA256
            or code_cache.TARGET_RELATIVE_PATH == wx.TARGET_RELATIVE_PATH):
        raise ValueError("Pinned source preparation stages do not form the expected pipeline")
    return {wx.TARGET_RELATIVE_PATH: frozenset((wx.PREPARED_SHA256, signal.PREPARED_SHA256)),
            code_cache.TARGET_RELATIVE_PATH: frozenset((code_cache.PREPARED_SHA256,))}


def checkout(repository: str, revision: str, destination: Path,
             allowed_edits: dict[str, frozenset[str]] | None = None) -> None:
    if not destination.exists():
        subprocess.run(["git", "init", str(destination)], check=True)
        subprocess.run(["git", "-C", str(destination), "remote", "add", "origin", repository], check=True)
    configured = subprocess.check_output(["git", "-C", str(destination), "remote", "get-url", "origin"], text=True).strip()
    if configured != repository:
        raise ValueError(f"Source origin mismatch in {destination}")
    changes = subprocess.check_output(["git", "-C", str(destination), "status", "--porcelain"], text=True)
    # Keep only the exact, reviewed source adaptation across an incremental build.
    # Any other edited bytes still stop checkout before git can overwrite them.
    unexpected = []
    for line in changes.splitlines():
        relative = line[3:]
        if relative == "src/hotspot/os/bsd/symbol_keeper.cpp":
            continue  # Generated from the separately hash-checked ios-tools input.
        path = destination / relative
        expected = (allowed_edits or {}).get(relative)
        if (isinstance(expected, (set, frozenset)) and path.is_file() and not path.is_symlink()
                and hashlib.sha256(path.read_bytes()).hexdigest() in expected):
            continue
        unexpected.append(line)
    changes = "\n".join(unexpected)
    if changes:
        raise ValueError(f"Source checkout contains edits: {destination}")
    subprocess.run(["git", "-C", str(destination), "fetch", "--depth=1", "origin", revision], check=True)
    subprocess.run(["git", "-C", str(destination), "checkout", "--detach", revision], check=True)
    actual = subprocess.check_output(["git", "-C", str(destination), "rev-parse", "HEAD"], text=True).strip()
    if actual != revision:
        raise ValueError(f"Source revision mismatch: {actual}")

def main() -> None:
    if sys.version_info < (3, 12):
        raise SystemExit("Python 3.12+ is required for safe source archive extraction")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", type=Path, default=HERE.parents[1] / ".build" / "legado-ios")
    args = parser.parse_args()
    work = args.work_dir.resolve()
    work.mkdir(parents=True, exist_ok=True)
    lock = json.loads((HERE / "runtime-lock.json").read_text(encoding="utf-8"))
    mobile_edits = prepared_edits()
    for name, folder in [("openjdkMobile", "mobile"), ("iosTools", "ios-tools")]:
        edits = mobile_edits if name == "openjdkMobile" else None
        checkout(lock[name]["repository"], lock[name]["commit"], work / folder, edits)
    ffi = lock["libffi"]
    archive = work / f"libffi-{ffi['version']}.tar.gz"
    if not archive.exists():
        with urllib.request.urlopen(ffi["url"]) as source, archive.open("wb") as output:
            while chunk := source.read(1024 * 1024): output.write(chunk)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != ffi["sha256"]:
        raise ValueError("libffi archive SHA-256 mismatch; remove the bad cached archive and retry")
    if not (work / f"libffi-{ffi['version']}").exists():
        with tarfile.open(archive) as source:
            for entry in source.getmembers():
                target = (work / entry.name).resolve()
                if not target.is_relative_to(work) or entry.issym() or entry.islnk():
                    raise ValueError(f"Unsafe source archive member: {entry.name}")
            source.extractall(work, filter="data")
    print(json.dumps({"workDirectory": str(work), "sourcePinsVerified": True}))

if __name__ == "__main__": main()
