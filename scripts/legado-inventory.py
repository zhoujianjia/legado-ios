#!/usr/bin/env python3
"""Audit the pinned Legado archive without extracting or executing its contents.

Uses Python's standard library only. Output excludes absolute paths, clocks, and
filesystem metadata so the same archive/catalogue produces identical bytes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import stat
import sys
import zipfile
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DOCS = ROOT / "docs" / "legado-ios"
MAX_ENTRY_BYTES = 32 * 1024 * 1024
MAX_TOTAL_BYTES = 256 * 1024 * 1024
DECLARATION = re.compile(
    r"^\s*(?:(?:public|internal|private|protected|override|open|abstract|final|"
    r"suspend|inline|tailrec|operator|infix|external|actual|expect|data|sealed|enum|"
    r"annotation|value)\s+)*(?:fun\s+(?:<[^>]+>\s*)?(?:[\w<>?.]+\.)?(?P<fun>\w+)\s*\("
    r"|(?:class|interface|object)\s+(?P<type>\w+))"
)


class InventoryError(ValueError):
    """The input cannot be audited against the selected baseline."""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def json_bytes(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def read_archive(archive: Path, lock: dict) -> tuple[dict, dict[str, bytes]]:
    """Read bounded regular ZIP entries, validate identities, never extract."""
    with archive.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    expected = lock["legado"]["sha256"]
    if digest != expected:
        raise InventoryError(f"archive SHA-256 mismatch: expected {expected}, got {digest}")
    files: dict[str, bytes] = {}
    total = 0
    with zipfile.ZipFile(archive) as source:
        seen: set[str] = set()
        entries = source.infolist()
        for entry in entries:
            name = entry.filename
            parts = PurePosixPath(name).parts
            if (not parts or name.startswith("/") or "\\" in name or ":" in name
                    or ".." in parts or "." in name.split("/") or "\x00" in name):
                raise InventoryError(f"unsafe archive path: {name!r}")
            if name in seen:
                raise InventoryError(f"duplicate archive path: {name}")
            seen.add(name)
            mode = entry.external_attr >> 16
            if stat.S_ISLNK(mode):
                raise InventoryError(f"symbolic link in archive: {name}")
            if entry.flag_bits & 1:
                raise InventoryError(f"encrypted archive entry: {name}")
            if entry.is_dir():
                continue
            total += entry.file_size
            if entry.file_size > MAX_ENTRY_BYTES or total > MAX_TOTAL_BYTES:
                raise InventoryError("archive exceeds uncompressed audit size limit")
            files[name] = source.read(entry)  # Also validates ZIP CRC.
        comment = source.comment.decode("utf-8", errors="strict")
    if comment != lock["legado"]["zip_comment"]:
        raise InventoryError("archive ZIP comment differs from baseline")
    for artifact in lock.get("engine", {}).get("archive_artifacts", []):
        path = artifact["path"]
        if path not in files or sha256(files[path]) != artifact["sha256"]:
            raise InventoryError(f"locked engine artifact differs or is missing: {path}")
    return {
        "sha256": digest,
        "zip_comment": comment,
        "entry_count": len(entries),
        "file_count": len(files),
        "uncompressed_file_bytes": total,
        "origin": lock["legado"]["origin"],
    }, files


def build_features(files: dict[str, bytes], catalogue: dict) -> list[dict]:
    features = []
    seen: set[str] = set()
    for item in catalogue["features"]:
        if item["id"] in seen:
            raise InventoryError(f"duplicate feature ID: {item['id']}")
        seen.add(item["id"])
        feature = dict(item)
        evidence = []
        for selector in item["evidence"]:
            path, needle = selector["path"], selector["contains"]
            if path not in files:
                raise InventoryError(f"feature {item['id']}: missing evidence {path}")
            lines = files[path].decode("utf-8-sig").splitlines()
            matches = [(n, line.strip()) for n, line in enumerate(lines, 1) if needle in line]
            if not matches:
                raise InventoryError(f"feature {item['id']}: evidence anchor {needle!r} absent from {path}")
            line, excerpt = matches[0]
            evidence.append({"path": path, "line": line, "excerpt": excerpt})
        feature["evidence"] = evidence
        # No source scan proves an iOS implementation or a runtime test passes.
        feature["status"] = "pending_ios_parity_validation"
        features.append(feature)
    return features


def build_inventory(archive: Path, lock: dict, catalogue: dict) -> dict:
    identity, files = read_archive(archive, lock)
    features = build_features(files, catalogue)
    declarations = []
    for name, data in sorted(files.items()):
        if not name.endswith(".kt") or "/src/main/" not in name:
            continue
        for line_number, line in enumerate(data.decode("utf-8-sig").splitlines(), 1):
            match = DECLARATION.match(line)
            if match:
                declarations.append({
                    "path": name, "line": line_number,
                    "kind": "function" if match.group("fun") else "type",
                    "name": match.group("fun") or match.group("type"),
                })
    mcp_path = "legado-master/app/src/main/java/io/legado/app/web/mcp/McpToolServer.kt"
    mcp_tools = []
    if mcp_path in files:
        lines = files[mcp_path].decode("utf-8-sig").splitlines()
        text = "\n".join(lines)
        for match in re.finditer(r'server\.addTool\(\s*name\s*=\s*"([^"]+)"', text):
            mcp_tools.append({"name": match.group(1), "path": mcp_path,
                              "line": text[:match.start()].count("\n") + 1})
    return {
        "schema_version": 1,
        "baseline": identity,
        "provenance_lock_sha256": sha256(json_bytes(lock)),
        "yuedu": lock["yuedu"],
        "engine": lock.get("engine", {}),
        "runtime": lock.get("runtime", {}),
        "catalogue_sha256": sha256(json_bytes(catalogue)),
        "interpretation": {
            "feature_status": "Source evidence only; no iOS parity claim.",
            "declarations": "Regex index of Kotlin main-source declarations; not an AST or exhaustive behavior specification.",
            "files": "Every regular archive file is fingerprinted; directories are counted only in entry_count.",
        },
        "features": features,
        "mcp_tools": mcp_tools,
        "kotlin_main_declarations": declarations,
        "files": [{"path": name, "bytes": len(data), "sha256": sha256(data)}
                  for name, data in sorted(files.items())],
    }


def markdown(inventory: dict) -> bytes:
    baseline = inventory["baseline"]
    lines = [
        "# Legado to iOS feature and acceptance matrix", "",
        "Generated by `scripts/legado-inventory.py`; edit `feature-catalog.json` and regenerate.", "",
        f"Baseline ZIP: `{baseline['sha256']}`; {baseline['entry_count']} entries, {baseline['file_count']} files.", "",
        "Every row is **pending iOS parity validation**. An upstream feature, similar Yuedu UI, or passing desktop JVM test does not establish iOS compatibility.",
        "This is a feature-domain acceptance checklist. `inventory.json` also fingerprints every archive file and indexes Kotlin main-source declarations to support further behavior auditing.", "",
        "Evidence refers to the locked ZIP, with 1-based line numbers. Its contents were neither extracted nor executed by this scan.", "",
        "| ID / phase | Original capability and behavior | Source evidence | iOS mapping | Acceptance scenario | Status / platform difference |",
        "| :--- | :--- | :--- | :--- | :--- | :--- |",
    ]
    def cell(value: str) -> str:
        return value.replace("|", "\\|").replace("\n", "<br>")
    for feature in inventory["features"]:
        evidence = "<br>".join(f"`{e['path']}:{e['line']}`" for e in feature["evidence"])
        values = [f"{feature['id']} / {feature['phase']}", feature["behavior"], evidence,
                  feature["ios_mapping"], feature["acceptance"],
                  "Pending iOS parity validation. " + feature.get("platform_difference", "")]
        lines.append("| " + " | ".join(cell(v) for v in values) + " |")
    lines.extend(["", "## MCP tool protocol inventory", "",
                  "Automatically extracted from `server.addTool(name = ...)`. Every tool requires request, response, error, access-control and foreground-lifecycle comparison.", "",
                  "| Tool | ZIP evidence |", "| :--- | :--- |"])
    for tool in inventory["mcp_tools"]:
        lines.append(f"| `{tool['name']}` | `{tool['path']}:{tool['line']}` |")
    lines.append("")
    return "\n".join(lines).encode("utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True, help="Pinned Legado ZIP (read only)")
    parser.add_argument("--lock", type=Path, default=DEFAULT_DOCS / "provenance-lock.json")
    parser.add_argument("--catalogue", type=Path, default=DEFAULT_DOCS / "feature-catalog.json")
    parser.add_argument("--output", type=Path, default=DEFAULT_DOCS)
    parser.add_argument("--check", action="store_true", help="Check generated bytes without writing")
    args = parser.parse_args(argv)
    try:
        lock = json.loads(args.lock.read_text(encoding="utf-8"))
        catalogue = json.loads(args.catalogue.read_text(encoding="utf-8"))
        inventory = build_inventory(args.archive, lock, catalogue)
        outputs = {"inventory.json": json_bytes(inventory), "feature-matrix.md": markdown(inventory)}
        if args.check:
            stale = [name for name, data in outputs.items()
                     if not (args.output / name).is_file() or (args.output / name).read_bytes() != data]
            if stale:
                raise InventoryError("generated files missing or stale: " + ", ".join(stale))
        else:
            args.output.mkdir(parents=True, exist_ok=True)
            for name, data in outputs.items():
                (args.output / name).write_bytes(data)
        print(f"{'Verified' if args.check else 'Generated'} {len(inventory['features'])} feature rows, "
              f"{len(inventory['files'])} file fingerprints, {len(inventory['mcp_tools'])} MCP tools")
        return 0
    except (InventoryError, OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        print(f"legado-inventory: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
