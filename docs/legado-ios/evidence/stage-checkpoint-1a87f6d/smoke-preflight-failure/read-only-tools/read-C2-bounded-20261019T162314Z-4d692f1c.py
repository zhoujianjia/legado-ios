"""One C-only run/jobs observation; reuse frozen network/download safety code."""
import ast
import concurrent.futures
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path

BASE = Path(__file__).resolve().parent
TEMPLATE = BASE / "read-cache-diagnostic-20261019T161128Z-79fa6b74.py"
HELPER = BASE / "read-after-font-checkpoint.py"
assert hashlib.sha256(TEMPLATE.read_bytes()).hexdigest() == "c996ec8b9c99c05080bc56d37d0f22af77ce6c49c513151750146d07bf25a2cf"
assert hashlib.sha256(HELPER.read_bytes()).hexdigest() == "39f2256d17aa67cb69c68d1412f4a9c1d49a148dca6d8ae6dd9e30314342ad56"
tree = ast.parse(TEMPLATE.read_text(encoding="utf-8"), filename=str(TEMPLATE))
cut = next(i for i, node in enumerate(tree.body) if isinstance(node, ast.With))
assert isinstance(tree.body[cut].items[0].context_expr, ast.Call)
assert ast.unparse(tree.body[cut].items[0].context_expr.func) == "concurrent.futures.ThreadPoolExecutor"
tree.body = tree.body[:cut]
ns = {"__file__": str(Path(__file__).resolve()), "__name__": "frozen_C_only_observation"}
exec(compile(tree, str(TEMPLATE), "exec"), ns)
ns["SPECS"] = {kind: ns["SPECS"][kind] for kind in ("smokeC", "renewalC")}
assert ns["SPECS"]["smokeC"][0] == 39281083749
assert ns["SPECS"]["renewalC"][0] == 39281084369
assert all(item[1] == "1a87f6d57b2e3f215b86930fdfa75fdd52ce2e06" for item in ns["SPECS"].values())
assert datetime.now(timezone.utc) >= datetime(2026, 10, 19, 16, 24, tzinfo=timezone.utc)
SPECS, DEST = ns["SPECS"], ns["DEST"]
api_once, inspect, write_json, meta = (ns[key] for key in ("api_once", "inspect", "write_json", "meta"))

with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
    futures = {(kind, phase): executor.submit(api_once, kind, phase)
               for kind in SPECS for phase in ("run", "jobs")}
    responses = {key: future.result() for key, future in futures.items()}
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
    futures = {kind: executor.submit(inspect, kind, [responses[(kind, phase)] for phase in ("run", "jobs")])
               for kind in SPECS}
    results = {kind: future.result() for kind, future in futures.items()}

prior_path = BASE / "cache-diagnostic-20261019T161128Z-79fa6b74/index.json"
prior = json.loads(prior_path.read_bytes())
differences = [{"kind": kind,
                "priorRunStatus": prior["results"][kind].get("runStatus"),
                "priorJobStatus": prior["results"][kind].get("jobStatus"),
                "currentRunStatus": results[kind].get("runStatus"),
                "currentJobStatus": results[kind].get("jobStatus"),
                "currentRunConclusion": results[kind].get("runConclusion"),
                "currentJobConclusion": results[kind].get("jobConclusion")}
               for kind in SPECS]
index = {"schemaVersion": 1, "kind": "one-C-only-bounded-run-jobs-observation",
         "observedAtUTC": ns["utc"](), "results": results,
         "priorRead": meta(prior_path), "differences": differences,
         "pollingPerformed": False, "runJobsReadsPerRun": 1,
         "AReleaseOrARenewalOrFontBQueried": False,
         "sourceOrDocsOrCanonicalEdited": False,
         "aggregateUncompressedBytes": ns["uncompressed_reserved"],
         "frozenDownloadExtractHelper": meta(HELPER),
         "frozenReadTemplate": meta(TEMPLATE), "freshWrapper": meta(Path(__file__).resolve()),
         "uniqueQueryAndNoCacheIsNotFreshnessProof": True}
write_json(DEST / "index.json", index)
entries = [meta(path) for path in sorted(DEST.rglob("*")) if path.is_file()]
write_json(DEST / "evidence-manifest.json", {"schemaVersion": 1,
           "kind": "C-only-bounded-observation-original-local-files",
           "files": entries, "excludesItself": True,
           "downloadedArchives": [item for record in results.values() for item in record["artifacts"]]})
print(json.dumps({"index": meta(DEST / "index.json"),
                  "manifest": meta(DEST / "evidence-manifest.json"),
                  "differences": differences, "boundedRoundFinished": True}), flush=True)
