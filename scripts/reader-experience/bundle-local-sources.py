#!/usr/bin/env python3
"""Historical local source-pack tool retained to reproduce prior build audits.

Current reader packages contain no built-in sources. This tool is not part of
the current build or delivery flow; import sources in the app instead.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import zipfile


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def bundle(ipa, cloud_manifest, sources_path, destination, report_path):
    paths = [path.resolve() for path in (ipa, cloud_manifest, sources_path, destination, report_path)]
    if len(set(paths)) != 5 or destination.exists() or report_path.exists():
        raise ValueError("Use distinct inputs and absent output paths")
    manifest = json.loads(cloud_manifest.read_bytes())
    source_commit = manifest.get("sourceCommit")
    if not isinstance(source_commit, str) or re.fullmatch(r"[0-9a-f]{40}", source_commit) is None:
        raise ValueError("Cloud build manifest requires a full lowercase source commit")
    original_hash = digest(ipa)
    if manifest.get("ipaSHA256") != original_hash or manifest.get("ipaBytes") != ipa.stat().st_size or manifest.get("signed") is not False:
        raise ValueError("Unsigned cloud IPA does not match its build manifest")
    source_bytes = sources_path.read_bytes()
    sources = json.loads(source_bytes.decode("utf-8-sig"))
    if not isinstance(sources, list) or not sources or not all(isinstance(item, dict) for item in sources):
        raise ValueError("Book sources must be a nonempty object array")
    source_hash = hashlib.sha256(source_bytes).hexdigest()
    source_manifest = {"schemaVersion": 1, "version": "local-sources-" + source_hash[:16], "sha256": source_hash}
    with zipfile.ZipFile(ipa) as archive:
        entries = archive.infolist()
        names = [item.filename for item in entries]
        if len(names) != len(set(names)) or len(entries) > 200_000 or sum(item.file_size for item in entries) > 2 * 1024 ** 3:
            raise ValueError("Unexpected duplicate or oversized IPA inventory")
        for name in names:
            path = PurePosixPath(name)
            if path.is_absolute() or ".." in path.parts or "\\" in name:
                raise ValueError("Unsafe IPA entry")
        roots = [name[:-len("/Info.plist")] for name in names if name.startswith("Payload/") and name.endswith(".app/Info.plist") and name.count("/") == 2]
        if len(roots) != 1:
            raise ValueError("Expected one main application")
        root = roots[0]
        info = plistlib.loads(archive.read(root + "/Info.plist"))
        if info.get("CFBundleIdentifier") != "local.zhoujianjia.legado-reader" or info.get("YueduLocalExperience") is not True:
            raise ValueError("Expected the isolated local reader")
        # These are the exact full/short stamps written by stage-config.finalize.
        if (info.get("YueduExperienceSourceCommit") != source_commit
                or info.get("GitCommitSHA") != source_commit[:7]):
            raise ValueError("Packaged source stamps differ from the cloud build manifest")
        if any(name.startswith(root + "/_CodeSignature/") or name == root + "/embedded.mobileprovision" for name in names):
            raise ValueError("Local source insertion requires an unsigned main application")
        additions = {root + "/BuiltInBookSources.json": source_bytes,
                     root + "/BuiltInBookSources.manifest.json": (json.dumps(source_manifest, indent=2) + "\n").encode()}
        destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.open("xb") as output_file:
            with zipfile.ZipFile(output_file, "w", compression=zipfile.ZIP_DEFLATED, allowZip64=True) as output:
                for entry in entries:
                    if entry.filename in additions:
                        continue
                    with archive.open(entry) as reader, output.open(copy.copy(entry), "w") as writer:
                        shutil.copyfileobj(reader, writer, length=1024 * 1024)
                for name, value in additions.items():
                    entry = zipfile.ZipInfo(name)
                    entry.create_system = 3
                    entry.external_attr = 0o100644 << 16
                    entry.compress_type = zipfile.ZIP_DEFLATED
                    output.writestr(entry, value)
        preserved = 0
        with zipfile.ZipFile(destination) as output:
            for entry in entries:
                if entry.filename in additions:
                    continue
                other = output.getinfo(entry.filename)
                if (entry.external_attr != other.external_attr or entry.create_system != other.create_system
                        or entry.file_size != other.file_size):
                    raise ValueError("Original IPA permissions or entry size changed")
                with archive.open(entry) as old, output.open(entry.filename) as new:
                    if hashlib.file_digest(old, "sha256").digest() != hashlib.file_digest(new, "sha256").digest():
                        raise ValueError("Original non-source IPA contents changed")
                preserved += 1
            for name, expected in additions.items():
                if output.read(name) != expected:
                    raise ValueError("Local book-source payload differs from input")
    report = {"schemaVersion": 1, "sourceCommit": source_commit,
              "cloudIPA_SHA256": original_hash, "cloudBuildManifestSHA256": digest(cloud_manifest),
              "ipaSHA256": digest(destination), "ipaBytes": destination.stat().st_size,
              "postBuildLocalResourceInsertion": True, "originalBookSourceBytesPreserved": True,
              "bookSourcesUploaded": False, "bundledBookSources": {**source_manifest, "sourceCount": len(sources),
                  "bytes": len(source_bytes), "mainJsSourceCount": sum(bool(item.get("mainJs")) for item in sources)},
              "originalNonSourceEntriesVerified": preserved, "originalNonSourceBytesAndPermissionsPreserved": True,
              "signed": False, "deviceValidationPassed": False, "realBookSourcesValidated": False,
              "cloudBuildManifest": manifest}
    report_path.parent.mkdir(parents=True, exist_ok=True)
    with report_path.open("x", encoding="utf-8") as stream:
        json.dump(report, stream, indent=2)
        stream.write("\n")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("ipa", "cloud-manifest", "sources", "output", "report"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    report = bundle(args.ipa, args.cloud_manifest, args.sources, args.output, args.report)
    print(json.dumps({key: report[key] for key in ("ipaSHA256", "ipaBytes", "bundledBookSources", "signed")}))


if __name__ == "__main__":
    main()
