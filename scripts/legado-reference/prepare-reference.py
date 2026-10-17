#!/usr/bin/env python3
"""Prepare the pinned, sanitized Android reference without executing its sources.

package accepts only the original archive identity below, strips legado-master/,
and never reads excluded file contents. stage verifies a reviewed manifest and
every snapshot member before creating a new destination. The only added file is
an inert Google Services configuration for reference tests, not a production
Firebase project. Neither command adds a harness, changes Gradle, or runs a build.

The manifest is a reviewed trust input, not a cryptographic signature. Sanitizing
filenames is not a general scan for secrets embedded inside business source code.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
import unicodedata
import zipfile
from pathlib import Path


ARCHIVE_SHA256 = "724dedcac2427cd1f02ca00af1eab7156146e6d9d3141ca4c92042d04ed7bcdd"
ARCHIVE_BYTES = 11_178_463
ARCHIVE_ROOT = "legado-master/"
SNAPSHOT_NAME = "source-snapshot.zip"
MANIFEST_NAME = "manifest.json"
MAX_TOTAL_BYTES = 100 * 1024 * 1024
MAX_ENTRY_BYTES = 16 * 1024 * 1024
MAX_SNAPSHOT_BYTES = 128 * 1024 * 1024
MAX_MANIFEST_BYTES = 4 * 1024 * 1024
MAX_ENTRIES = 10_000
FIXED_TIME = (1980, 1, 1, 0, 0, 0)
GITHUB_EXCLUSION = "Exclude the complete upstream .github tree, including signing material."
GOOGLE_EXCLUSION = "Exclude the upstream Firebase configuration; stage adds an inert test-only replacement."
TEST_CONFIGURATION_PATH = "app/google-services.json"
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
SECRET_SUFFIXES = {".pem", ".p12", ".pfx", ".jks", ".keystore", ".key", ".p8",
                   ".mobileprovision", ".cer", ".crt", ".certsigningrequest"}
RESERVED_WINDOWS_NAMES = {"con", "prn", "aux", "nul", *(f"com{i}" for i in range(1, 10)),
                          *(f"lpt{i}" for i in range(1, 10))}


class ReferenceError(ValueError):
    """The input cannot be safely prepared as this reference snapshot."""


def _json_bytes(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _file_sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def _unique_json_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ReferenceError("Duplicate JSON manifest key")
        result[key] = value
    return result


def _reject_json_constant(value: str) -> None:
    raise ReferenceError("Non-finite JSON manifest value")


def _path_key(path: str) -> str:
    return unicodedata.normalize("NFC", path.rstrip("/")).casefold()


def _safe_path(path: str, directory: bool = False) -> str:
    if not isinstance(path, str) or not path or "\\" in path or path.startswith("/"):
        raise ReferenceError("Unsafe archive path")
    if directory:
        if not path.endswith("/"):
            raise ReferenceError("Directory path lacks its trailing separator")
        path = path[:-1]
    parts = path.split("/")
    for part in parts:
        if (not part or part in {".", ".."} or part.endswith((".", " "))
                or any(ord(char) < 32 or char in '<>:"|?*' for char in part)
                or part.split(".", 1)[0].casefold() in RESERVED_WINDOWS_NAMES):
            raise ReferenceError("Unsafe archive path")
    return path


def _exclusion(path: str, directory: bool = False) -> str | None:
    if path == ".github" or path.startswith(".github/"):
        return GITHUB_EXCLUSION
    if not directory and path == TEST_CONFIGURATION_PATH:
        return GOOGLE_EXCLUSION
    return None


def _reject_secret_candidate(path: str) -> None:
    name = path.rsplit("/", 1)[-1].casefold()
    suffix = Path(name).suffix
    if (suffix in SECRET_SUFFIXES or name == ".env" or name.startswith(".env.")
            or name in {"id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "credentials.json"}
            or name.startswith("serviceaccount") and name.endswith(".json")
            or name in {"service-account.json", "google-services.json"}):
        raise ReferenceError(f"Unexpected sensitive-file candidate: {path}")


def _members(source: zipfile.ZipFile, strip_root: bool) -> list[tuple[str, zipfile.ZipInfo]]:
    infos = source.infolist()
    if len(infos) > MAX_ENTRIES:
        raise ReferenceError("Archive has too many entries")
    entries: list[tuple[str, zipfile.ZipInfo]] = []
    seen: dict[str, bool] = {}
    total = 0
    for info in infos:
        if info.orig_filename != info.filename or "\x00" in info.orig_filename:
            raise ReferenceError("NUL in archive path")
        directory = info.is_dir()
        _safe_path(info.filename, directory)
        name = info.filename
        if strip_root:
            if not name.startswith(ARCHIVE_ROOT):
                raise ReferenceError("Unexpected original archive root")
            name = name[len(ARCHIVE_ROOT):]
            if not name:
                if directory:
                    continue
                raise ReferenceError("Original root is not a directory")
        path = _safe_path(name, directory)
        key = _path_key(path)
        if key in seen:
            raise ReferenceError("Duplicate or case/normalization-colliding archive path")
        seen[key] = directory
        kind = stat.S_IFMT(info.external_attr >> 16)
        if kind not in ({0, stat.S_IFDIR} if directory else {0, stat.S_IFREG}):
            raise ReferenceError("Symbolic link or non-regular archive entry")
        if info.flag_bits & 1:
            raise ReferenceError("Encrypted archive entry")
        if info.file_size < 0 or info.file_size > MAX_ENTRY_BYTES:
            raise ReferenceError("Archive entry exceeds the size limit")
        if directory and info.file_size:
            raise ReferenceError("Directory entry contains data")
        total += info.file_size
        if total > MAX_TOTAL_BYTES:
            raise ReferenceError("Archive expanded size exceeds the limit")
        entries.append((path, info))
    for path in seen:
        components = path.split("/")
        for count in range(1, len(components)):
            if seen.get("/".join(components[:count])) is False:
                raise ReferenceError("File also used as an archive directory")
    return entries


def _read_member(source: zipfile.ZipFile, info: zipfile.ZipInfo) -> bytes:
    with source.open(info) as stream:
        data = stream.read(MAX_ENTRY_BYTES + 1)
    if len(data) != info.file_size or len(data) > MAX_ENTRY_BYTES:
        raise ReferenceError("Archive member length differs from its directory entry")
    return data


def _new_directory(destination: Path) -> None:
    if os.path.lexists(destination):
        raise ReferenceError("Destination already exists; refusing to overwrite it")
    destination.mkdir(parents=True, exist_ok=False)


def package_archive(archive: Path, output_directory: Path) -> dict:
    if os.path.lexists(output_directory):
        raise ReferenceError("Output directory already exists; refusing to overwrite it")
    files: dict[str, tuple[bytes, str]] = {}
    excluded: list[dict] = []
    with archive.open("rb") as stream:
        if os.fstat(stream.fileno()).st_size != ARCHIVE_BYTES:
            raise ReferenceError("Original archive byte size does not match the pinned input")
        if hashlib.file_digest(stream, "sha256").hexdigest() != ARCHIVE_SHA256:
            raise ReferenceError("Original archive SHA-256 does not match the pinned input")
        stream.seek(0)
        with zipfile.ZipFile(stream) as source:
            original_entries = len(source.infolist())
            original_files = sum(not info.is_dir() for info in source.infolist())
            for path, info in _members(source, strip_root=True):
                reason = _exclusion(path, info.is_dir())
                if reason:
                    excluded.append({"path": path + ("/" if info.is_dir() else ""),
                                     "isDirectory": info.is_dir(), "reason": reason})
                    continue  # Never open or read the excluded member.
                if info.is_dir():
                    continue
                _reject_secret_candidate(path)
                permissions = "0755" if (info.external_attr >> 16) & 0o111 else "0644"
                files[path] = (_read_member(source, info), permissions)
    if not files.get("LICENSE", (b"", ""))[0]:
        raise ReferenceError("The upstream LICENSE must be retained")
    _new_directory(output_directory)
    snapshot = output_directory / SNAPSHOT_NAME
    with snapshot.open("xb") as output:
        with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED, allowZip64=False) as bundle:
            for path, (data, permissions) in sorted(files.items()):
                info = zipfile.ZipInfo(path, FIXED_TIME)
                info.create_system = 3
                info.compress_type = zipfile.ZIP_STORED
                info.external_attr = (stat.S_IFREG | int(permissions, 8)) << 16
                bundle.writestr(info, data)
    manifest = {
        "schemaVersion": 1,
        "purpose": "Sanitized original Android source reference; test configuration only, no build or compatibility claim.",
        "originalArchiveSHA256": ARCHIVE_SHA256,
        "originalArchiveBytes": ARCHIVE_BYTES,
        "originalArchiveEntries": original_entries,
        "originalArchiveFiles": original_files,
        "strippedRoot": ARCHIVE_ROOT,
        "snapshotFileName": SNAPSHOT_NAME,
        "zipCompression": "stored",
        "snapshotSHA256": _file_sha256(snapshot),
        "snapshotBytes": snapshot.stat().st_size,
        "retainedFileCount": len(files),
        "retainedTotalBytes": sum(len(data) for data, _ in files.values()),
        "files": [{"path": path, "bytes": len(data), "sha256": _sha256(data), "mode": permissions}
                  for path, (data, permissions) in sorted(files.items())],
        "excluded": sorted(excluded, key=lambda item: item["path"]),
        "stageOnlyAddedFile": TEST_CONFIGURATION_PATH,
        "sanitizationBoundary": "Filename exclusions only; excluded contents were not read. Remaining source bytes are unchanged.",
    }
    with (output_directory / MANIFEST_NAME).open("xb") as output:
        output.write(_json_bytes(manifest))
    return manifest


def _manifest_files(manifest: dict) -> dict[str, dict]:
    if (type(manifest.get("schemaVersion")) is not int or manifest.get("schemaVersion") != 1
            or manifest.get("originalArchiveSHA256") != ARCHIVE_SHA256
            or manifest.get("originalArchiveBytes") != ARCHIVE_BYTES
            or manifest.get("strippedRoot") != ARCHIVE_ROOT
            or manifest.get("snapshotFileName") != SNAPSHOT_NAME
            or manifest.get("zipCompression") != "stored"
            or manifest.get("stageOnlyAddedFile") != TEST_CONFIGURATION_PATH):
        raise ReferenceError("Manifest does not identify the pinned reference format")
    digest = manifest.get("snapshotSHA256")
    if not isinstance(digest, str) or not SHA256_PATTERN.fullmatch(digest):
        raise ReferenceError("Invalid snapshot SHA-256 in manifest")
    rows = manifest.get("files")
    if not isinstance(rows, list) or not 1 <= len(rows) <= MAX_ENTRIES:
        raise ReferenceError("Invalid manifest file list")
    files: dict[str, dict] = {}
    seen: set[str] = set()
    total = 0
    for row in rows:
        if not isinstance(row, dict) or set(row) != {"path", "bytes", "sha256", "mode"}:
            raise ReferenceError("Invalid manifest file record")
        path = _safe_path(row["path"])
        if _exclusion(path) or _path_key(path) in seen:
            raise ReferenceError("Excluded or duplicate manifest file")
        _reject_secret_candidate(path)
        if (type(row["bytes"]) is not int or not 0 <= row["bytes"] <= MAX_ENTRY_BYTES
                or not isinstance(row["sha256"], str) or not SHA256_PATTERN.fullmatch(row["sha256"])
                or not isinstance(row["mode"], str) or row["mode"] not in {"0644", "0755"}):
            raise ReferenceError("Invalid manifest file size, digest or mode")
        seen.add(_path_key(path))
        files[path] = row
        total += row["bytes"]
    if (total > MAX_TOTAL_BYTES or manifest.get("retainedFileCount") != len(files)
            or type(manifest.get("retainedFileCount")) is not int
            or type(manifest.get("retainedTotalBytes")) is not int
            or manifest.get("retainedTotalBytes") != total or not files.get("LICENSE", {}).get("bytes")):
        raise ReferenceError("Manifest totals or LICENSE are invalid")
    excluded = manifest.get("excluded")
    if not isinstance(excluded, list):
        raise ReferenceError("Manifest exclusion list is absent")
    seen_excluded: set[str] = set()
    for row in excluded:
        if (not isinstance(row, dict) or set(row) != {"path", "isDirectory", "reason"}
                or type(row["isDirectory"]) is not bool):
            raise ReferenceError("Invalid manifest exclusion record")
        path = _safe_path(row["path"], row["isDirectory"])
        reason = _exclusion(path, row["isDirectory"])
        if reason is None or row["reason"] != reason or _path_key(path) in seen_excluded:
            raise ReferenceError("Unexpected or duplicate manifest exclusion")
        seen_excluded.add(_path_key(path))
    return files


def inert_google_services() -> bytes:
    clients = []
    for index, package in enumerate(("com.legado.app", "com.legado.app.debug")):
        clients.append({
            "client_info": {"mobilesdk_app_id": f"1:000000000000:android:000000000000000000000{index}",
                            "android_client_info": {"package_name": package}},
            "oauth_client": [],
            "api_key": [{"current_key": "LEGADO_REFERENCE_INERT_NOT_A_REAL_API_KEY"}],
            "services": {"appinvite_service": {"other_platform_oauth_client": []}},
        })
    return _json_bytes({"project_info": {"project_number": "000000000000", "project_id": "legado-reference-inert",
                                         "storage_bucket": "legado-reference-inert.invalid"},
                        "client": clients, "configuration_version": "1"})


def stage_reference(snapshot_directory: Path, destination: Path) -> dict:
    if os.path.lexists(destination):
        raise ReferenceError("Destination already exists; refusing to overwrite it")
    manifest_path, snapshot = snapshot_directory / MANIFEST_NAME, snapshot_directory / SNAPSHOT_NAME
    for path, limit in ((manifest_path, MAX_MANIFEST_BYTES), (snapshot, MAX_SNAPSHOT_BYTES)):
        if not stat.S_ISREG(path.lstat().st_mode) or path.stat().st_size > limit:
            raise ReferenceError("Snapshot input must be a bounded regular file, not a symbolic link")
    manifest = json.loads(manifest_path.read_bytes(), object_pairs_hook=_unique_json_object,
                          parse_constant=_reject_json_constant)
    if not isinstance(manifest, dict):
        raise ReferenceError("Manifest must be a JSON object")
    expected = _manifest_files(manifest)
    verified: dict[str, bytes] = {}
    with snapshot.open("rb") as stream:
        if (type(manifest.get("snapshotBytes")) is not int
                or os.fstat(stream.fileno()).st_size != manifest.get("snapshotBytes")
                or hashlib.file_digest(stream, "sha256").hexdigest() != manifest["snapshotSHA256"]):
            raise ReferenceError("Snapshot byte size or SHA-256 differs from manifest")
        stream.seek(0)
        with zipfile.ZipFile(stream) as source:
            members = _members(source, strip_root=False)
            if any(info.is_dir() for _, info in members):
                raise ReferenceError("Snapshot must contain only listed regular files")
            if {path for path, _ in members} != set(expected):
                raise ReferenceError("Snapshot and manifest file lists differ")
            for path, info in members:
                row = expected[path]
                mode = stat.S_IFREG | int(row["mode"], 8)
                if (info.file_size != row["bytes"] or info.compress_type != zipfile.ZIP_STORED
                        or info.external_attr >> 16 != mode):
                    raise ReferenceError("Snapshot member size, mode or format differs from manifest")
                data = _read_member(source, info)
                if _sha256(data) != row["sha256"]:
                    raise ReferenceError("Snapshot member SHA-256 differs from manifest")
                verified[path] = data
    # Validate the complete archive before creating any destination or writing files.
    _new_directory(destination)
    root = destination.resolve()
    for path, data in sorted(verified.items()):
        target = destination.joinpath(*path.split("/"))
        if not target.resolve().is_relative_to(root):
            raise ReferenceError("Destination path escaped the staging directory")
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as output:
            output.write(data)
        target.chmod(int(expected[path]["mode"], 8))
    configuration = destination / TEST_CONFIGURATION_PATH
    configuration.parent.mkdir(parents=True, exist_ok=True)
    synthetic = inert_google_services()
    with configuration.open("xb") as output:
        output.write(synthetic)
    return {"stagedFiles": len(verified), "addedTestConfiguration": TEST_CONFIGURATION_PATH,
            "addedTestConfigurationSHA256": _sha256(synthetic), "originalSourceBytesChanged": False,
            "buildExecuted": False}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    package = commands.add_parser("package", help="Create a new sanitized snapshot directory from the pinned original")
    package.add_argument("--archive", type=Path, required=True)
    package.add_argument("--output-directory", type=Path, required=True)
    stage = commands.add_parser("stage", help="Validate and extract into a new directory with inert test configuration")
    stage.add_argument("--snapshot-directory", type=Path, required=True)
    stage.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "package":
            manifest = package_archive(args.archive, args.output_directory)
            report = {key: manifest[key] for key in ("originalArchiveSHA256", "snapshotSHA256",
                                                     "retainedFileCount", "retainedTotalBytes")}
            report["excludedEntries"] = len(manifest["excluded"])
        else:
            report = stage_reference(args.snapshot_directory, args.destination)
    except (ReferenceError, OSError, zipfile.BadZipFile, RuntimeError, json.JSONDecodeError) as error:
        print(f"Reference preparation failed: {error}", file=sys.stderr)
        raise SystemExit(2) from error
    print(json.dumps(report, sort_keys=True, indent=2))


if __name__ == "__main__":
    main()
