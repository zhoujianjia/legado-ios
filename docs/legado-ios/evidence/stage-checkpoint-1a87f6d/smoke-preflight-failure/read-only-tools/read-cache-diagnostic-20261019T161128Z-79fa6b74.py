"""Exactly one cache-diagnostic run/jobs read per selected run; no polling/retries."""
import ast
import concurrent.futures
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import threading
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile

BASE = Path(__file__).resolve().parent
ROOT = BASE.parents[1]
PREFIX = Path(__file__).stem.removeprefix("read-")
DEST = BASE / PREFIX
assert not DEST.exists()
DEST.mkdir()
original = BASE / "read-after-font-checkpoint.py"
tree = ast.parse(original.read_text(encoding="utf-8"), filename=str(original))
cut = next(i for i, node in enumerate(tree.body) if isinstance(node, ast.Assign)
           and any(isinstance(target, ast.Name) and target.id == "parser" for target in node.targets))
tree.body = tree.body[:cut]
namespace = {"__file__": str(original), "__name__": "frozen_checkpoint_helpers"}
exec(compile(tree, str(original), "exec"), namespace)
extract_safely, request, write_json = (namespace[name] for name in ("extract_safely", "request", "write_json"))
SPECS = {
    "reader": (39272843081, "a76d380fdc108db83be68961905ee49edd209571", "reader-legado-a76d380", ".github/workflows/legado-reader.yml", {"legado-native-reader-unsigned", "legado-native-reader-build-evidence"}),
    "smokeC": (39281083749, "1a87f6d57b2e3f215b86930fdfa75fdd52ce2e06", "reader-smoke-1a87f6d", ".github/workflows/reader-smoke.yml", {"reader-smoke-evidence"}),
    "renewalC": (39281084369, "1a87f6d57b2e3f215b86930fdfa75fdd52ce2e06", "reader-renewal-1a87f6d", ".github/workflows/reader-renewal-probe.yml", {"reader-renewal-probe-evidence"}),
}
lock = threading.Lock()
uncompressed_reserved = 0


def utc():
    return datetime.now(timezone.utc).isoformat()


def meta(path):
    raw = path.read_bytes()
    return {"path": str(path), "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}


def api_once(kind, phase):
    run_id = SPECS[kind][0]
    suffix = "" if phase == "run" else "/" + phase
    query = urllib.parse.urlencode({"observation": PREFIX + "-" + kind + "-" + phase + "-" + uuid.uuid4().hex})
    url = namespace["REPO_API"] + "runs/" + str(run_id) + suffix + "?" + query
    headers = {**namespace["HEADERS"], "Cache-Control": "no-cache", "Pragma": "no-cache"}
    info = {"kind": kind, "phase": phase, "requestURL": url, "requestHeaders": headers,
            "requestStartedAtUTC": utc(), "requestCount": 1, "errors": []}
    value = None
    try:
        try:
            response = urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=45)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            info.update({"headersReceivedAtUTC": utc(), "statusCode": response.status,
                         "finalURL": response.geturl(), "responseHeaders": list(response.headers.items()),
                         "cacheIndicators": {name: response.headers.get(name) for name in
                             ("Date", "Age", "Cache-Control", "Expires", "ETag", "Last-Modified", "Vary", "X-GitHub-Request-Id", "X-Cache", "Via")}})
            raw = response.read()
        info["bodyReceivedAtUTC"] = utc()
        path = DEST / (kind + "-" + phase + ".raw.json")
        with path.open("xb") as stream:
            stream.write(raw)
        info["rawBody"] = meta(path)
        assert info["statusCode"] == 200
        value = json.loads(raw)
    except Exception as error:
        info["errors"].append({"type": type(error).__name__, "message": str(error)})
    write_json(DEST / (kind + "-" + phase + ".http.json"), info)
    return value, info


def inspect(kind, pair):
    run_id, source, tag, workflow, expected = SPECS[kind]
    (run, run_http), (jobs, jobs_http) = pair
    record = {"kind": kind, "runID": run_id, "expectedSourceCommit": source, "expectedTag": tag,
              "expectedWorkflow": workflow, "artifacts": [], "errors": [], "httpEvidence": [run_http, jobs_http]}
    try:
        assert run is not None and jobs is not None and not run_http["errors"] and not jobs_http["errors"]
        assert run["id"] == run_id and run["head_sha"] == source and run["head_branch"] == tag and run["path"] == workflow
        assert run["event"] == "push"
        assert len(jobs["jobs"]) == 1
        job = jobs["jobs"][0]
        assert job["run_id"] == run_id and ("head_sha" not in job or job["head_sha"] == source)
        record.update({"url": run["html_url"], "sourceCommit": source, "sourceTagWorkflowBound": True,
                       "runStatus": run["status"], "runConclusion": run.get("conclusion"),
                       "jobStatus": job["status"], "jobConclusion": job.get("conclusion"),
                       "steps": [{key: step.get(key) for key in ("number", "name", "status", "conclusion", "started_at", "completed_at")} for step in job.get("steps", [])]})
        terminal = (run["status"] == job["status"] == "completed" and run.get("conclusion") == job.get("conclusion")
                    and run.get("conclusion") is not None)
        record["consistentCompletedRunAndJob"] = terminal
        record["artifactListQueried"] = False
        if terminal:
            listing, artifact_http = api_once(kind, "artifacts")
            record["artifactListQueried"] = True
            record["artifactListHTTP"] = artifact_http
            assert listing is not None and not artifact_http["errors"]
            artifacts = listing["artifacts"]
            assert len({item["name"] for item in artifacts}) == len(artifacts)
            assert {item["name"] for item in artifacts} <= expected
            if run["conclusion"] == "success":
                assert {item["name"] for item in artifacts} == expected
            for artifact in artifacts:
                item = {"id": artifact["id"], "name": artifact["name"]}
                try:
                    assert not artifact["expired"] and artifact.get("digest", "").startswith("sha256:")
                    assert artifact["size_in_bytes"] <= 512 * 1024**2
                    if artifact.get("workflow_run") and artifact["workflow_run"].get("head_sha"):
                        assert artifact["workflow_run"]["head_sha"] == source
                    archive_path = DEST / (kind + "-" + artifact["name"] + ".zip")
                    digest, count = hashlib.sha256(), 0
                    download = "https://nightly.link/zhoujianjia/legado-ios/actions/runs/" + str(run_id) + "/" + artifact["name"] + ".zip"
                    with request(download) as stream, archive_path.open("xb") as output:
                        while block := stream.read(1024 * 1024):
                            count += len(block)
                            assert count <= 512 * 1024**2
                            digest.update(block)
                            output.write(block)
                    assert count == artifact["size_in_bytes"]
                    assert "sha256:" + digest.hexdigest() == artifact["digest"]
                    item.update({"bytes": count, "sha256": digest.hexdigest(), "githubArtifactDigestMatched": True, "archivePath": str(archive_path)})
                    with zipfile.ZipFile(archive_path) as archive:
                        size = sum(entry.file_size for entry in archive.infolist())
                    global uncompressed_reserved
                    with lock:
                        assert uncompressed_reserved + size < 3 * 1024**3
                        uncompressed_reserved += size
                    destination = ROOT / ".build" / ("b12-" + uuid.uuid4().hex[:10])
                    assert not destination.exists()
                    extract_safely(archive_path, destination)
                    item.update({"extractedRoot": str(destination), "uncompressedBytes": size,
                                 "auditEntryPoints": [str(path) for path in destination.rglob("*") if path.is_file() and (path.suffix == ".ipa" or path.name in {"build-manifest.json", "LocalBookshelf-source.zip", "result.json", "unit-summary.json", "discovery-summary.json", "ui-summary.json", "driver.log", "unit-tests.log", "local-product-tests.log"})]})
                except Exception as error:
                    item["error"] = {"type": type(error).__name__, "message": str(error)}
                    record["errors"].append(item["error"])
                record["artifacts"].append(item)
    except Exception as error:
        record["errors"].append({"type": type(error).__name__, "message": str(error)})
    record["observedAtUTC"] = utc()
    record["uniqueNoCacheRequestIsNotFreshnessProof"] = True
    write_json(DEST / (kind + "-inspection.json"), record)
    print(json.dumps({key: value for key, value in record.items() if key not in ("httpEvidence", "steps", "artifactListHTTP")}, indent=2), flush=True)
    return record


with concurrent.futures.ThreadPoolExecutor(max_workers=6) as executor:
    futures = {(kind, phase): executor.submit(api_once, kind, phase) for kind in SPECS for phase in ("run", "jobs")}
    responses = {key: future.result() for key, future in futures.items()}
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
    futures = {kind: executor.submit(inspect, kind, [responses[(kind, phase)] for phase in ("run", "jobs")]) for kind in SPECS}
    results = {kind: future.result() for kind, future in futures.items()}
prior_path = BASE / "reader-C-bounded-20261019T160855Z-ae89de97-index.json"
prior = json.loads(prior_path.read_bytes())
differences = [{"kind": kind, "priorRunStatus": prior["results"][kind]["status"],
                "diagnosticRunStatus": results[kind].get("runStatus"), "diagnosticJobStatus": results[kind].get("jobStatus"),
                "diagnosticRunConclusion": results[kind].get("runConclusion"), "diagnosticJobConclusion": results[kind].get("jobConclusion")}
               for kind in SPECS]
index = {"schemaVersion": 1, "kind": "one-cache-diagnostic-round", "observedAtUTC": utc(), "results": results,
         "priorRead": meta(prior_path), "differences": differences, "pollingPerformed": False,
         "runJobsReadsPerRun": 1, "oldRenewalAOrFontBQueried": False, "sourceOrDocsOrCanonicalEdited": False,
         "aggregateUncompressedBytes": uncompressed_reserved, "frozenDownloadExtractHelper": meta(original),
         "uniqueQueryAndNoCacheIsNotFreshnessProof": True}
write_json(DEST / "index.json", index)
print(json.dumps({"index": meta(DEST / "index.json"), "differences": differences, "boundedRoundFinished": True}), flush=True)
