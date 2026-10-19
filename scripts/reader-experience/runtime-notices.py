#!/usr/bin/env python3
"""Offline staging/verification of separately owned, pinned runtime notices.

This never modifies a Java home, JAR, native archive or the native producer lock.
The material inventory is not a license-combination or corresponding-source audit.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import stat


REPO = Path(__file__).resolve().parents[2]
VENDOR = REPO / "Packages/LegadoRuntime/vendor/openjdk-notices"
MANIFEST_SHA256 = "0b60c9ed3e2b6e4c70f36627db630c8b3b0b72a0a5b016c5b9d9f580d3e4574a"


def checked_path(path):
    path = Path(path).absolute()
    for item in (path, *path.parents):
        if item.is_symlink() or getattr(item, "is_junction", lambda: False)():
            raise ValueError("Refusing a symlink or junction in a runtime-notice path")
    return path.resolve()


def relative_path(value):
    if (not isinstance(value, str) or not value or "\\" in value or ":" in value
            or any(ord(c) < 32 or ord(c) == 127 for c in value)
            or value.startswith("/") or any(p in ("", ".", "..") for p in value.split("/"))):
        raise ValueError("Unsafe runtime-notice relative path")
    return PurePosixPath(value)


def inventory(root):
    """Include directories as well, so unlisted empty directories cannot pass."""
    root = checked_path(root)
    if not root.is_dir():
        raise ValueError("Runtime Notices directory is missing")
    result = {}
    folded = set()
    for entry in root.rglob("*"):
        checked_path(entry)
        name = entry.relative_to(root).as_posix()
        relative_path(name)
        if name.casefold() in folded:
            raise ValueError("Duplicate case-insensitive runtime-notice path")
        folded.add(name.casefold())
        mode = entry.lstat().st_mode
        if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
            raise ValueError("Runtime notices require regular files/directories")
        result[name] = "directory" if stat.S_ISDIR(mode) else "file"
    return result


def load_manifest(vendor):
    vendor = checked_path(vendor)
    path = checked_path(vendor / "manifest.json")
    if not path.is_file():
        raise ValueError("Runtime-notice manifest is missing")
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != MANIFEST_SHA256:
        raise ValueError("Runtime-notice manifest differs from its reviewed fingerprint")
    value = json.loads(raw)
    lock = json.loads(checked_path(REPO / "scripts/legado-ios/runtime-lock.json").read_bytes())
    if value["sourcePins"] != {k: lock[k] for k in ("openjdkMobile", "iosTools", "libffi", "requiredModules")}:
        raise ValueError("Runtime-notice source pins differ from the native runtime lock")
    return raw, value


def verify(directory, vendor=None):
    vendor = VENDOR if vendor is None else Path(vendor)
    directory = checked_path(directory)
    manifest_bytes, manifest = load_manifest(vendor)
    expected = {"manifest.json": "file"}
    aggregate = hashlib.sha256()
    for item in manifest["files"]:
        relative = relative_path(item["path"])
        if item["path"] in expected:
            raise ValueError("Duplicate runtime-notice manifest entry")
        expected[item["path"]] = "file"
        for parent in relative.parents:
            if parent != PurePosixPath("."):
                expected[parent.as_posix()] = "directory"
    if inventory(directory) != expected:
        raise ValueError("Runtime-notice inventory has missing or extra paths")
    if checked_path(directory / "manifest.json").read_bytes() != manifest_bytes:
        raise ValueError("Packaged runtime-notice manifest differs from this checkout")
    for item in manifest["files"]:
        path = checked_path(directory / item["path"])
        if path.stat().st_size != item["bytes"]:
            raise ValueError("Runtime-notice bytes differ from the pinned original: " + item["path"])
        data = path.read_bytes()
        if len(data) != item["bytes"] or hashlib.sha256(data).hexdigest() != item["sha256"]:
            raise ValueError("Runtime-notice bytes differ from the pinned original: " + item["path"])
        if "gitBlob" in item:
            blob = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
            if blob != item["gitBlob"]:
                raise ValueError("Runtime-notice Git blob differs: " + item["path"])
        aggregate.update(item["path"].encode() + b"\0" + item["sha256"].encode() + b"\n")
    return {"schemaVersion": 1, "verified": True, "manifestSHA256": MANIFEST_SHA256,
            "noticeFileCount": len(manifest["files"]), "noticeBytes": sum(f["bytes"] for f in manifest["files"]),
            "filePathSHA256Aggregate": aggregate.hexdigest(), "requiredModuleCount": len(manifest["moduleCoverage"]),
            "staticArchiveGroupCount": len(manifest["staticArchiveComposition"]),
            "sourcePins": manifest["sourcePins"], "coverage": manifest["coverage"],
            "scope": manifest["scope"]}


def stage(destination, vendor=None):
    """Copy into a fresh runtime-owned Notices child; never replace caller data."""
    vendor = VENDOR if vendor is None else Path(vendor)
    vendor, destination = checked_path(vendor), checked_path(destination)
    if destination.name != "Notices":
        raise ValueError("Runtime notices may only stage into a Notices directory")
    if (vendor == destination or vendor.is_relative_to(destination) or destination.is_relative_to(vendor)):
        raise ValueError("Runtime-notice staging must be separate from its source")
    report = verify(vendor, vendor)
    if destination.exists():
        raise ValueError("Refusing to overwrite an existing runtime Notices directory")
    destination.mkdir(parents=True)
    manifest_bytes, manifest = load_manifest(vendor)
    for item in manifest["files"]:
        target = checked_path(destination / item["path"])
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as stream:
            stream.write(checked_path(vendor / item["path"]).read_bytes())
    with (destination / "manifest.json").open("xb") as stream:
        stream.write(manifest_bytes)
    if verify(destination, vendor) != report:
        raise ValueError("Staged runtime-notice validation changed")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    checking = commands.add_parser("verify")
    checking.add_argument("--directory", type=Path, default=VENDOR)
    staging = commands.add_parser("stage")
    staging.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = verify(args.directory) if args.command == "verify" else stage(args.destination)
    except (OSError, ValueError) as error:
        parser.exit(1, str(error) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
