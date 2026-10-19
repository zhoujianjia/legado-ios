#!/usr/bin/env python3
"""Archive existing actual C evidence once. No network, tests or git operations.

Only the fresh docs/legado-ios/evidence/renewal-actual-1a87f6d directory is written.
Original acquisition, extraction, audit inputs and all existing documents stay intact.
"""
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import stat
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[2]
DEST = ROOT / "docs/legado-ios/evidence/renewal-actual-1a87f6d"
ACQUISITION = ROOT / ".build/renewal-discovery/C-completed-job-evidence-20261019T1640"
OBSERVATION = ROOT / ".build/renewal-discovery/C-renewal-after-umd-20261019T1638"
EXTRACTED = ROOT / ".build/b12-2e93221697"
AUDIT_PATH = ROOT / ".build/renewal-discovery/C-renewal-actual-independent-audit.json"
AUDIT_RAW = ROOT / ".build/renewal-discovery/C-renewal-actual-independent-audit-raw"
SOURCE = "1a87f6d57b2e3f215b86930fdfa75fdd52ce2e06"
ZIP_PIN = "bfa6496f86183fced6a95125bfe6ac0faa278971fe09b95593933919983eebcc"
AUDIT_PIN = "f5e00d24f53689fd9ceb6b45fc4061b7c5c9d3c6c95d258fb2d3bf0d3e5672f9"
RAW_MANIFEST_PIN = "8d930b2c716b8d601721371ec4380cac8e692fbc82976a05aab7d0f02ff31ce6"
ACQUISITION_MANIFEST_PIN = "4a5bd3138e6ff2b730bea2ad30391b74b82cea443845fc4bbdd9200e48f7423e"
OBSERVATION_MANIFEST_PIN = "6105aad1ff965a3a6635475b96a0d4256418f693aaabc86772f91d2af5c8cc31"
sys.dont_write_bytecode = True


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def rel(path):
    return path.relative_to(ROOT).as_posix()


def owned(path, missing=False):
    require(path.is_absolute() and path.is_relative_to(ROOT), "Path outside repository")
    for ancestor in (path, *path.parents):
        try:
            info = ancestor.lstat()
        except FileNotFoundError:
            require(missing and ancestor == path, "Missing input/parent: " + str(ancestor))
        else:
            require(not stat.S_ISLNK(info.st_mode) and not (getattr(info, "st_file_attributes", 0) & 0x400),
                    "Symlink/junction/reparse path refused: " + str(ancestor))
        if ancestor == ROOT:
            break
    require(path.resolve(strict=not missing).is_relative_to(ROOT), "Resolved path outside repository")


def read(path):
    owned(path)
    require(path.is_file(), "Not a regular file: " + str(path))
    return path.read_bytes()


def parse(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "Duplicate JSON key")
            result[key] = value
        return result
    return json.loads(data.decode("utf-8"), object_pairs_hook=unique)


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def pinned(path, digest, size=None):
    data = read(path)
    require(sha(data) == digest and (size is None or len(data) == size), "Frozen input mismatch: " + rel(path))
    return data


def safe_name(name):
    require(name and "\\" not in name and ":" not in name and not name.startswith("/"), "Unsafe archive name")
    pieces = name.split("/")
    require(all(part and part not in (".", "..") for part in pieces), "Unsafe archive component")
    require(PurePosixPath(name).as_posix() == name, "Noncanonical archive name")
    return name


def main():
    require(len(sys.argv) == 1, "No arguments accepted")
    owned(DEST.parent)
    require(not DEST.exists() and not DEST.is_symlink(), "Existing archive directory refused")
    protected_paths = [ROOT / path for path in (
        "docs/legado-ios/completion-plan.json", "docs/legado-ios/reader-launch-memory-batch.json",
        "docs/legado-ios/umd-parser-preparation-batch.json", "docs/legado-ios/native-reader-experience-build12.json")]
    protected = {path: read(path) for path in protected_paths if path.exists()}
    output = {}

    def add(name, data, source, kind):
        safe_name(name)
        require(name not in output, "Duplicate destination")
        output[name] = {"data": data, "source": source, "kind": kind}

    def original(path, name, digest=None, size=None, kind="original-existing-evidence"):
        data = read(path) if digest is None else pinned(path, digest, size)
        add(name, data, rel(path), kind)
        return data

    audit = parse(original(AUDIT_PATH, "C-renewal-actual-independent-audit.json", AUDIT_PIN, 17505,
                           "independent-offline-audit-original"))
    require(audit["sourceCommit"] == SOURCE and audit["runID"] == 39281084369
            and audit["status"] == "passed-for-actual-C-read-only-diagnostic-test-scope"
            and audit["unresolvedBlockingFindings"] == [], "Unexpected independent audit")
    require(audit["job"]["status"] == "completed" and audit["job"]["conclusion"] == "success"
            and audit["aggregateRun"]["savedStatus"] == "in_progress"
            and audit["aggregateRun"]["savedConclusion"] is None
            and audit["aggregateRun"]["successfulCompletionInferred"] is False, "Original status conflict lost")

    def copy_manifest(directory, manifest_name, digest, prefix):
        data = original(directory / manifest_name, prefix + "/" + manifest_name, digest,
                        kind="original-acquisition-manifest")
        record = parse(data)
        require(record["excludesItself"] is True, "Original manifest self-exclusion changed")
        listed = set()
        for entry in record["files"]:
            path = Path(entry["path"])
            require(path.parent == directory and path.name not in listed, "Unexpected original manifest member")
            listed.add(path.name)
            if path.name.endswith(".zip"):
                require(path.name == "renewalC-reader-renewal-probe-evidence.zip", "Unexpected artifact")
                original(path, "original-reader-renewal-probe-evidence.zip", entry["sha256"], entry["bytes"], "original-GitHub-artifact-ZIP")
            else:
                original(path, prefix + "/" + path.name, entry["sha256"], entry["bytes"])
        require({p.name for p in directory.iterdir()} == listed | {manifest_name}, "Acquisition directory member set changed")
        return record

    copy_manifest(ACQUISITION, "evidence-manifest.json", ACQUISITION_MANIFEST_PIN, "acquisition")
    copy_manifest(OBSERVATION, "evidence-manifest.json", OBSERVATION_MANIFEST_PIN, "api-observation")
    artifact_data = output["original-reader-renewal-probe-evidence.zip"]["data"]
    require(sha(artifact_data) == ZIP_PIN and len(artifact_data) == 2260954, "Wrong original ZIP")
    retrieval = parse(output["acquisition/retrieval-record.json"]["data"])
    require(retrieval["sourceCommit"] == SOURCE and retrieval["runID"] == 39281084369
            and retrieval["actualJobStatus"] == "completed" and retrieval["actualJobConclusion"] == "success"
            and retrieval["savedAggregateRunStatus"] == "in_progress" and retrieval["savedAggregateRunConclusion"] is None
            and retrieval["aggregateRunCompletionInferred"] is False, "Retrieval conflict changed")
    artifact_api = parse(output["acquisition/renewalC-artifacts.raw.json"]["data"])
    require(len(artifact_api["artifacts"]) == 1, "Unexpected original artifact inventory")
    api_artifact = artifact_api["artifacts"][0]
    require(api_artifact["digest"] == "sha256:" + ZIP_PIN and api_artifact["id"] == 12203686066
            and api_artifact["workflow_run"]["head_sha"] == SOURCE
            and api_artifact["workflow_run"]["id"] == 39281084369, "Original GitHub digest/source mismatch")
    run = parse(output["api-observation/renewalC-run.raw.json"]["data"])
    jobs = parse(output["api-observation/renewalC-jobs.raw.json"]["data"])
    require(run["head_sha"] == SOURCE and run["id"] == 39281084369 and run["status"] == "in_progress"
            and run["conclusion"] is None, "Original aggregate response changed")
    require(len(jobs["jobs"]) == 1, "Unexpected original jobs response")
    job = jobs["jobs"][0]
    require(job["id"] == audit["job"]["id"] == 118155310210 and job["status"] == "completed"
            and job["conclusion"] == "success" and len(job["steps"]) == 11
            and all(step["status"] == "completed" and step["conclusion"] == "success" for step in job["steps"]),
            "Original completed job/steps mismatch")

    raw_manifest = parse(original(AUDIT_RAW / "completed-manifest.json", "completed-manifest.json", RAW_MANIFEST_PIN, 29221,
                                  "original-independent-raw-completed-manifest"))
    require(raw_manifest["excludesItself"] is True and len(raw_manifest["files"]) == 122
            and raw_manifest["audit"]["sha256"] == AUDIT_PIN, "Unexpected original independent raw manifest")
    raw_data = {}
    raw_members = []
    for entry in raw_manifest["files"]:
        path = Path(entry["path"])
        require(path.parent == AUDIT_RAW and path.name not in raw_data, "Unexpected independent raw member")
        data = pinned(path, entry["sha256"], entry["bytes"])
        safe_name(path.name)
        raw_data[path.name] = data
        raw_members.append({"path": path.name, "source": rel(path), "bytes": len(data), "sha256": sha(data)})
    require({p.name for p in AUDIT_RAW.iterdir()} == set(raw_data) | {"completed-manifest.json"},
            "Independent raw directory member set changed")
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(raw_data.items()):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | 0o644) << 16
            archive.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    raw_zip = stream.getvalue()
    with zipfile.ZipFile(io.BytesIO(raw_zip)) as archive:
        require(set(archive.namelist()) == set(raw_data) and len(archive.infolist()) == 122,
                "Generated independent raw ZIP inventory mismatch")
        require(all(archive.read(name) == data for name, data in raw_data.items()), "Generated independent raw ZIP bytes mismatch")
    add("independent-audit-raw.zip", raw_zip, rel(AUDIT_RAW), "lossless-container-of-122-existing-independent-raw-files")
    add("independent-audit-raw-members.json", encoded({
        "schemaVersion": 1, "archive": "independent-audit-raw.zip", "archiveSHA256": sha(raw_zip),
        "files": sorted(raw_members, key=lambda item: item["path"]), "members": 122,
        "uncompressedBytes": sum(len(data) for data in raw_data.values()),
        "originalCompletedManifestSeparate": "completed-manifest.json", "originalBytesPreserved": True
    }), "generated-from-original-completed-manifest-and-reverified-member-bytes", "lossless-member-index")
    for name in ("actual-read-only-commands.json", "archive-members.json", "source-input-comparison.json"):
        add(name, raw_data[name], rel(AUDIT_RAW / name), "readable-original-independent-index")
    auditor = raw_manifest["auditorScript"]
    original(Path(auditor["path"]), "audit-C-renewal-actual-offline.py", auditor["sha256"], auditor["bytes"],
             "original-auditor-source-not-executed-by-archiver")
    expected_members = parse(raw_data["archive-members.json"])
    expected = {entry["path"]: entry for entry in expected_members["files"]}
    require(len(expected) == 163 and expected_members["allExtractedBytesMatchOriginalZIP"] is True,
            "Unexpected independently recorded artifact members")
    seen = set()
    actual_members = []
    with zipfile.ZipFile(io.BytesIO(artifact_data)) as archive:
        require(len(archive.infolist()) == 163, "Original ZIP member count changed")
        for info in archive.infolist():
            name = safe_name(info.filename)
            require(not info.is_dir() and name.casefold() not in seen and not (info.flag_bits & 1), "Invalid/duplicate/encrypted ZIP member")
            seen.add(name.casefold())
            mode = info.external_attr >> 16
            require(stat.S_IFMT(mode) in (0, stat.S_IFREG), "Nonregular original ZIP member")
            require(info.file_size <= 512 * 1024 * 1024 and name in expected, "Unexpected original ZIP member")
            data = archive.read(info)
            entry = expected[name]
            require((len(data), sha(data)) == (entry["bytes"], entry["sha256"]), "Original ZIP/member hash mismatch")
            require(read(EXTRACTED / name) == data, "Existing extracted original differs from ZIP")
            actual_members.append({"path": name, "bytes": len(data), "sha256": sha(data)})
            pieces = name.split("/")
            if len(pieces) == 2 and pieces[0] in ("reader-renewal-probe", "ci-logs"):
                add(name, data, rel(EXTRACTED / name), "readable-original-artifact-file")
    require(len(actual_members) == 163 and sum(item["bytes"] for item in actual_members) == 12023046,
            "Original ZIP expanded inventory mismatch")
    require({item["path"] for item in actual_members} == set(expected), "Original member set mismatch")
    require(audit["actualSwiftOrXCTestMethods"] == audit["actualExecutions"] == 22,
            "Independent actual test count changed")
    for key, count in (("unit", 8), ("discovery", 13), ("ui", 1)):
        group = audit["groups"][key]
        require(group["actualMethods"] == group["actualExecutions"] == count
                and group["failures"] == group["skips"] == group["expectedFailures"] == 0,
                "Independent actual group scope changed")
    original(Path(__file__).resolve(), Path(__file__).name, kind="archiver-source")
    payload_entries = [{"path": name, "source": item["source"], "bytes": len(item["data"]),
                        "sha256": sha(item["data"]), "kind": item["kind"]} for name, item in sorted(output.items())]
    record = {
        "schemaVersion": 1, "archivedAtUTC": datetime.now(timezone.utc).isoformat(),
        "kind": "lossless-archive-of-actual-C-read-only-renewal-diagnostic-evidence",
        "说明": "仅归档原始 C Simulator 诊断证据与既有独审，不查询 CI、不重跑任何测试。aggregate API 原件仍为 in_progress/null，同时保存实际单 job completed/success 与全部 11 步成功；不把二者改写成整次 run 终态。C smoke 的独立 preflight 失败不因本归档变为通过。",
        "sourceCommit": SOURCE, "sourceTag": "reader-renewal-1a87f6d", "runID": 39281084369,
        "actualJob": audit["job"], "aggregateRun": audit["aggregateRun"],
        "artifact": {"path": "original-reader-renewal-probe-evidence.zip", "bytes": len(artifact_data),
                     "sha256": ZIP_PIN, "githubDigestRecheckedAgainstSavedOriginalAPI": True,
                     "members": 163, "uncompressedBytes": 12023046,
                     "allMemberHashesRecheckedAgainstOriginalZIPAndExistingExtractedBytes": True,
                     "allThreeOriginalXCResultBundlesPreservedInsideOriginalZIP": True,
                     "deepXCResultFilesNotIndividuallyDuplicated": True,
                     "originalMemberIndex": "archive-members.json"},
        "independentAudit": {"path": "C-renewal-actual-independent-audit.json", "sha256": AUDIT_PIN,
                             "status": audit["status"], "newAuditOrOriginalTestReexecutionPerformed": False,
                             "originalRawMembers": 122, "originalRawManifestSeparate": "completed-manifest.json",
                             "originalRawManifestSHA256": RAW_MANIFEST_PIN,
                             "losslessRawContainer": "independent-audit-raw.zip",
                             "memberHashIndex": "independent-audit-raw-members.json"},
        "actualScopeAlreadyAudited": {"unitMethodsAndExecutions": 8, "discoveryMethodsAndExecutions": 13,
                                     "UIMethodsAndExecutions": 1, "totalMethodsAndExecutions": 22,
                                     "failures": 0, "skips": 0, "expectedFailures": 0,
                                     "sourceInputs": 29, "portablePreflight": [24, 16],
                                     "theseCountsAreNotNewRunsByArchiver": True,
                                     "device": audit["device"], "Xcode": audit["Xcode"]},
        "exclusions": audit["exclusions"], "builtHostBoundary": audit["builtHostBoundary"],
        "payloadFiles": payload_entries, "payloadFileCount": len(payload_entries),
        "payloadBytes": sum(item["bytes"] for item in payload_entries),
        "directoryManifest": "archive-directory-manifest.json",
        "manifestIncludesRecordAndExcludesOnlyItself": True,
        "protectedExistingDocumentsSHA256": {rel(path): sha(data) for path, data in protected.items()},
        "performed": {"offlineExistingEvidenceReadAndLosslessPackaging": True, "networkQueries": 0,
                      "testRuns": 0, "gitOperations": 0, "CIQueriesOrTriggers": 0,
                      "canonicalOrBatchModified": False, "DownloadsModified": False, "privateInputsRead": False}
    }
    require(chr(0xFFFD) not in record["说明"] and chr(63) not in record["说明"], "Generated prose encoding failure")
    add("archive-record.json", encoded(record), "generated-offline-archive-index", "archive-record")
    directory_manifest = {
        "schemaVersion": 1, "files": [{"path": name, "bytes": len(item["data"]), "sha256": sha(item["data"])}
                                     for name, item in sorted(output.items())],
        "listedFiles": len(output), "listedBytes": sum(len(item["data"]) for item in output.values()),
        "totalDirectoryFilesIncludingThisManifest": len(output) + 1, "excludesItself": True
    }
    add("archive-directory-manifest.json", encoded(directory_manifest), "generated-complete-directory-index", "directory-manifest")
    # All source validation completed before creating the one permitted destination.
    DEST.mkdir(exist_ok=False)
    for name, item in sorted(output.items()):
        target = DEST / name
        target.parent.mkdir(parents=True, exist_ok=True)
        owned(target, missing=True)
        with target.open("xb") as stream:
            stream.write(item["data"])
        require(read(target) == item["data"], "Written archive bytes differ")
    final_files = [path for path in DEST.rglob("*") if path.is_file()]
    require({path.relative_to(DEST).as_posix() for path in final_files} == set(output), "Final directory inventory mismatch")
    require(all(read(path) == data for path, data in protected.items()), "Existing protected documents changed")
    manifest_data = read(DEST / "archive-directory-manifest.json")
    final_bytes = sum(len(read(path)) for path in final_files)
    print(json.dumps({"directory": rel(DEST), "files": len(final_files), "bytes": final_bytes,
                      "manifest": rel(DEST / "archive-directory-manifest.json"), "manifestSHA256": sha(manifest_data),
                      "archiveRecordSHA256": sha(read(DEST / "archive-record.json")),
                      "originalZIPUnchanged": sha(read(ACQUISITION / "renewalC-reader-renewal-probe-evidence.zip")) == ZIP_PIN,
                      "aggregateRun": "in_progress", "actualJob": "completed/success", "newTestsOrNetwork": 0}))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"{type(error).__name__}: {error}; original evidence is untouched; existing destination refuses; inspect partial new archive if present.", file=sys.stderr)
        sys.exit(1)
