from pathlib import Path
import ast, datetime, hashlib, json, subprocess, symtable, uuid
BASE = Path(__file__).resolve().parents[2]
A = "a76d380fdc108db83be68961905ee49edd209571"
C = "1a87f6d57b2e3f215b86930fdfa75fdd52ce2e06"
root = BASE / ".build/renewal-discovery"
stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
out = root / ("build12-A-C-scope-" + stamp + "-" + uuid.uuid4().hex[:8])
out.mkdir()
sha = lambda b: hashlib.sha256(b).hexdigest()
commands = []
def git(*args):
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    result = subprocess.run(["git", *args], cwd=BASE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    number = len(commands) + 1
    stdout, stderr = out / f"{number:03}.stdout", out / f"{number:03}.stderr"
    stdout.write_bytes(result.stdout); stderr.write_bytes(result.stderr)
    commands.append(dict(argv=["git", *args], cwd=str(BASE), startedAtUTC=started, exitCode=result.returncode,
        stdout=str(stdout.relative_to(BASE)).replace("\\", "/"), stdoutSHA256=sha(result.stdout), stdoutBytes=len(result.stdout),
        stderr=str(stderr.relative_to(BASE)).replace("\\", "/"), stderrSHA256=sha(result.stderr), stderrBytes=len(result.stderr)))
    (out / "commands.json").write_bytes((json.dumps(commands, indent=2) + "\n").encode())
    if result.returncode: raise RuntimeError(commands[-1])
    return result.stdout
assert git("rev-parse", A + "^{commit}").decode().strip() == A
assert git("rev-parse", C + "^{commit}").decode().strip() == C
cache = {}
def blob(commit, path):
    if (commit, path) not in cache:
        cache[commit, path] = (git("show", commit + ":" + path), git("rev-parse", commit + ":" + path).decode().strip())
    return cache[commit, path]
def compare(path):
    aa, ao = blob(A, path); cc, co = blob(C, path)
    return dict(path=path, A=dict(commit=A, gitBlob=ao, bytes=len(aa), sha256=sha(aa)),
        C=dict(commit=C, gitBlob=co, bytes=len(cc), sha256=sha(cc)), sameGitBlob=ao == co, sameBytes=aa == cc)
renewal_path = "scripts/reader-experience/renewal-probe-tools.py"
renewal = {k: blob(k, renewal_path)[0].decode() for k in (A, C)}
def source_inputs(source):
    nodes = {n.targets[0].id: n for n in ast.parse(source).body
        if isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name)}
    langs = ast.literal_eval(nodes["LANGUAGES"].value); node = nodes["SOURCE_INPUTS"]
    assert isinstance(node.value, ast.BinOp) and isinstance(node.value.op, ast.Add)
    expected = ast.parse('tuple("Resources/" + language + ".lproj/" + table for language in LANGUAGES for table in ("Localizable.strings", "InfoPlist.strings"))', mode="eval").body
    assert ast.dump(node.value.right, include_attributes=False) == ast.dump(expected, include_attributes=False)
    paths = ast.literal_eval(node.value.left) + tuple("Resources/" + lang + ".lproj/" + table
        for lang in langs for table in ("Localizable.strings", "InfoPlist.strings"))
    return paths, ast.get_source_segment(source, node), ast.dump(node.value, include_attributes=False)
inputs = {k: source_inputs(renewal[k]) for k in (A, C)}
assert inputs[A][0] == inputs[C][0]
records = [compare(path) for path in inputs[A][0]]
different = [x["path"] for x in records if not x["sameBytes"]]
assert different == ["scripts/reader-experience/smoke-tools.py"]
smoke = {k: blob(k, different[0])[0].decode() for k in (A, C)}
trees = {k: ast.parse(smoke[k]) for k in (A, C)}
functions = {k: {n.name: n for n in trees[k].body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))} for k in (A, C)}
def raw_function(source, node):
    first = min([node.lineno] + [d.lineno for d in node.decorator_list])
    return "".join(source.splitlines(keepends=True)[first - 1:node.end_lineno]).encode()
comparisons = []
for name in sorted(set(functions[A]) & set(functions[C])):
    one = raw_function(smoke[A], functions[A][name]); two = raw_function(smoke[C], functions[C][name])
    ad = ast.dump(functions[A][name], include_attributes=False); cd = ast.dump(functions[C][name], include_attributes=False)
    comparisons.append(dict(name=name, A=dict(rawSHA256=sha(one), rawBytes=len(one), astSHA256=sha(ad.encode()), line=functions[A][name].lineno),
        C=dict(rawSHA256=sha(two), rawBytes=len(two), astSHA256=sha(cd.encode()), line=functions[C][name].lineno), rawByteEqual=one == two, astEqual=ad == cd))
for k in (A, C):
    folder = out / ("smoke-functions-" + k[:7]); folder.mkdir()
    for name, node in functions[k].items():
        (folder / (name + ".py")).write_bytes(raw_function(smoke[k], node))
        (folder / (name + ".ast.txt")).write_bytes((ast.dump(node, include_attributes=False) + "\n").encode())
def global_references(table):
    result = {s.get_name() for s in table.get_symbols() if s.is_global() and s.is_referenced()}
    for child in table.get_children(): result.update(global_references(child))
    return result
symbols = symtable.symtable(smoke[C], "smoke-tools.py", "exec")
tables = {table.get_name(): table for table in symbols.get_children() if table.get_type() == "function"}
rt = ast.parse(renewal[C])
attrs = sorted({n.attr for n in ast.walk(rt) if isinstance(n, ast.Attribute) and isinstance(n.value, ast.Name) and n.value.id == "smoke"})
direct = sorted(set(attrs) & set(functions[C])); closure = set(direct); pending = list(direct)
while pending:
    name = pending.pop()
    for dependency in global_references(tables[name]) & set(functions[C]):
        if dependency not in closure: closure.add(dependency); pending.append(dependency)
reachable = [x for x in comparisons if x["name"] in closure]
assert len(reachable) == 10 and all(x["rawByteEqual"] and x["astEqual"] for x in reachable)
added = sorted(set(functions[C]) - set(functions[A]))
changed = [x["name"] for x in comparisons if not x["rawByteEqual"]]
assert set(changed) == {"main", "result"} and not set(added + changed) & closure
# Preserve import-time common nodes; new nodes may touch only new LOCAL_PRODUCT constants.
def top(source, tree):
    return [(ast.dump(n, include_attributes=False), ast.get_source_segment(source, n))
        for n in tree.body if not isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))]
ta = top(smoke[A], trees[A]); tc = top(smoke[C], trees[C]); assert all(node in tc for node in ta)
new_nodes = [(a, b) for a, b in tc if a not in {x[0] for x in ta}]
new_names = []
for node in trees[C].body:
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) or ast.dump(node, include_attributes=False) in {x[0] for x in ta}: continue
    if isinstance(node, ast.Assign):
        names = [n.id for target in node.targets for n in ast.walk(target) if isinstance(n, ast.Name)]
        assert all(n.startswith("LOCAL_PRODUCT_") for n in names); new_names.extend(names)
    else:
        assert isinstance(node, ast.Expr) and isinstance(node.value, ast.Call)
        call = node.value.func
        assert isinstance(call, ast.Attribute) and isinstance(call.value, ast.Name) and call.value.id == "LOCAL_PRODUCT_EXECUTIONS" and call.attr == "update"
for name in closure: assert not global_references(tables[name]) & set(new_names)
reflection = [ast.unparse(n) for n in ast.walk(rt) if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)
    and n.func.id in ("eval", "exec", "getattr", "globals", "locals")]
assert not reflection
supplement = ["scripts/reader-experience/test-renewal-probe-tools.py", "scripts/reader-experience/test-smoke-tools.py",
    "scripts/check_localizations.rb", "scripts/reader-experience/runtime-packaging.py", "scripts/reader-experience/runtime-notices.py",
    "scripts/legado-ios/verify-runtime.py", "scripts/legado-ios/runtime-lock.json"]
all_paths = git("ls-tree", "-r", "--name-only", C).decode().splitlines()
config_paths = [p for p in all_paths if (p.startswith("Yuedu-Reader.xcodeproj/") or p.endswith(".xcconfig")) and p not in inputs[C][0]]
supp = [compare(p) for p in supplement + config_paths]
config_path = "scripts/reader-experience/stage-config.py"
config_src = blob(C, config_path)[0].decode(); config_tree = ast.parse(config_src)
config_functions = {n.name: n for n in config_tree.body if isinstance(n, ast.FunctionDef)}
config_symbols = {t.get_name(): t for t in symtable.symtable(config_src, config_path, "exec").get_children() if t.get_type() == "function"}
config_attrs = set()
for name in closure:
    for n in ast.walk(functions[C][name]):
        if isinstance(n, ast.Attribute) and isinstance(n.value, ast.Name) and n.value.id == "config": config_attrs.add(n.attr)
for n in ast.walk(rt):
    if isinstance(n, ast.Attribute) and isinstance(n.value, ast.Attribute) and isinstance(n.value.value, ast.Name) and n.value.value.id == "smoke" and n.value.attr == "config": config_attrs.add(n.attr)
config_closure = set(config_attrs) & set(config_functions); pending = list(config_closure)
while pending:
    name = pending.pop()
    for dependency in global_references(config_symbols[name]) & set(config_functions):
        if dependency not in config_closure: config_closure.add(dependency); pending.append(dependency)
assert "verify_jvm_payload" not in config_closure
status = git("diff", "--name-status", "-z", A, C).decode().split("\0"); deltas = []; i = 0
while i < len(status) and status[i]:
    deltas.append(dict(status=status[i], path=status[i + 1])); i += 2
app_deltas = [x for x in deltas if x["path"].endswith(".swift") and x["path"].startswith(("Modules/", "Targets/"))]
app_records = [compare(x["path"]) for x in app_deltas]
test_deltas = [x for x in deltas if x["path"].startswith("Tests/") and x["path"].endswith(".swift")]
diff = git("diff", "--no-ext-diff", A, C, "--", different[0], "scripts/reader-experience/test-smoke-tools.py")
(out / "smoke-and-preflight.diff").write_bytes(diff)
audits = []
for kind in ("core", "extra", "source"):
    path = root / ("build12-actual-" + kind + "-a76d380.json"); data = path.read_bytes(); r = json.loads(data)
    passed = r.get("staticAuditPassed") if kind == "core" else r.get("passed")
    assert passed is True and r.get("sourceCommit") == A and r.get("issues") == []
    audits.append(dict(kind=kind, path=str(path.relative_to(BASE)).replace("\\", "/"), bytes=len(data), sha256=sha(data),
        passed=True, sourceCommit=A, scope=r["scope"], runtimeOrDeviceAcceptance=False))
r = dict(schemaVersion=1, createdAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
    status="static-diagnostic-source-scope-prerequisite-established-no-reuse-acceptance",
    scope="A Release vs C diagnostic narrow source projection only; current main source is not compared.", AReleaseSource=A, CDiagnosticSource=C,
    existingReleaseAudits=audits,
    releaseAuditBoundary="Read existing three actual A audit records and bound hashes/status; no package re-audit or binary execution. Their scopes stay A-bound.",
    sourceInputDeclarations=dict(sameExpressionBytes=inputs[A][1] == inputs[C][1], sameExpressionAST=inputs[A][2] == inputs[C][2],
        AExpression=inputs[A][1], CExpression=inputs[C][1], count=len(records), samePathOrder=True,
        exactByteMatches=sum(x["sameBytes"] for x in records), wholeFileDifferences=different, files=records),
    smokeImportedProjection=dict(modulePath=different[0], renewalSmokeAttributes=attrs, directFunctions=direct,
        transitiveFunctionClosure=sorted(closure), globalFunctionDependencies={name:sorted(global_references(tables[name]) & set(functions[C])) for name in sorted(closure)},
        scopeAnalysis="Python symtable lexical globals, including nested scopes, excludes shadowing local variables such as verify_summary.result; AST Name matching alone would falsely treat it as smoke.result.",
        allReachableRawFunctionsAndASTEqual=True, functionComparisons=comparisons, addedFunctionsNotReachable=added,
        changedFunctionsNotReachable=changed, addedModuleGlobals=new_names, allExistingImportTimeNodesRawAndASTPreserved=True,
        newImportTimeNodes=[dict(raw=b, ast=a, rawSHA256=sha(b.encode())) for a,b in new_nodes],
        newImportTimeEffect="Only new LOCAL_PRODUCT_* in-memory constants are constructed/updated. No I/O, process/network operation, common-helper registration or pre-existing-global mutation is added at import time.",
        noReachableReferencesToNewGlobals=True, renewalDynamicReflectionCalls=reflection,
        importBoundary="renewal loads smoke as renewal_probe_smoke, never __main__. Its unchanged own main/result call the ten imported helpers; smoke.main/result and local-product helpers are not entered.",
        sourceFingerprintBoundary="Whole smoke-tools.py hashes differ. Keep each original commit/tag/sourceInputs fingerprint; never relabel C result as A or transplant a helper digest. This projection is a scoped exception, not whole-file equality."),
    stageConfig=dict(wholeFileByteEqual=next(x for x in records if x["path"] == config_path)["sameBytes"], directAttributes=sorted(config_attrs),
        reachableFunctions=sorted(config_closure), jvmPayloadVerifierReachable=False,
        note="Only source-only staging/overlay/privacy/no-JVM helpers are reachable; supplementary runtime helper/lock bytes were compared anyway."),
    additionalRunnerAndConfigDependencies=dict(files=supp, nonEqualPaths=[x["path"] for x in supp if not x["sameBytes"]],
        preflightException="Workflow directly executes changed test-smoke-tools.py. Its font source/50-method68-execution additions and position13/23-to18/28 guard updates mean the complete workflow preflight dependency closure is not byte-identical. No actual C preflight pass is claimed.",
        xcodeBoundary="Tracked project workspace/scheme/config and .xcconfig paths are compared, but that does not equate SDK/Simulator environments, app Swift sources or binaries."),
    otherAppSourceChanges=app_records, otherTestSwiftChanges=test_deltas,
    fullAppBoundary=dict(appSourceByteEquivalent=False, appBinaryEquivalent=False, fullAppOrGeneralRuntimeAccepted=False,
        explanation="C changes reader/global font settings, font storage/theme import, position value/store and Firestore behavior, plus other test code compiled in the bundle. These broader app/test-compilation dependencies are not equivalent. Narrow probe-source equality cannot transfer full-app/general-runtime acceptance.",
        unrelatedSmokeRunnerChanges=[x for x in deltas if x["path"] in (".github/workflows/reader-smoke.yml", "scripts/reader-experience/smoke.sh")], allChangedPaths=deltas),
    decision=dict(narrowSourcePrerequisiteEstablished=True, allSourceInputFilesByteEqual=False, allWorkflowDependencyFilesByteEqual=False,
        relevantImportedSmokeProjectionEqual=True, reuseAccepted=False, deliveryAccepted=False, C8_13_1PassEstablished=False,
        interpretation="A narrowly documented diagnostic source mapping has the static prerequisite, with helper/preflight exceptions. This is not reuse/distribution approval. A policy requiring complete SOURCE_INPUTS/workflow byte identity is not satisfied."),
    unresolvedGates=[
        "Actual exact-C Debug Simulator result: separate 8 fixed-port/13 discovery/1 UI xcresult, exact complete identities, zero failures/skips and actual built privacy/Bonjour/source stamp checks.",
        "Actual C preflight/localization pass, including changed test-smoke-tools dependencies and successful compilation of the wider selected test bundle. No successful C runtime test evidence was read here.",
        "Keep A Release build12 IPA/manifest/source hashes A-bound. Any later narrow reuse decision needs an explicit A/C exception mapping plus actual C gate evidence; do not rewrite C source/result provenance.",
        "Actual iPhone transport/privacy, service identity/authentication, signing/install/self-renewal, no-companion/computer-off remain unestablished. TCP zero-payload alone is insufficient.",
        "No full-app/general-runtime/font/position/Firestore acceptance is inherited between the two sources."],
    performed=dict(gitReadOnly=True, staticASTAndLexicalSymbolAnalysis=True, toolsImportedOrExecuted=False, SDKBuilds=0, testRuns=0,
        deviceRuns=0, CIQueries=0, CITriggers=0, commits=0, tags=0, pushes=0, trackedFileEdits=0),
    rawEvidence=dict(directory=str(out.relative_to(BASE)).replace("\\", "/"), commands=commands,
        collectorPath=str(Path(__file__).relative_to(BASE)).replace("\\", "/"), collectorSHA256=sha(Path(__file__).read_bytes()),
        functionSourcesAndASTs="smoke-functions-a76d380 and smoke-functions-1a87f6d under rawEvidence.directory",
        diffPath=str((out / "smoke-and-preflight.diff").relative_to(BASE)).replace("\\", "/"), diffSHA256=sha(diff)))
path = root / "build12-A-C-diagnostic-source-scope-review.json"
with path.open("xb") as stream: stream.write((json.dumps(r, ensure_ascii=False, indent=2) + "\n").encode())
print(json.dumps(dict(path=str(path.relative_to(BASE)), bytes=path.stat().st_size, sha256=sha(path.read_bytes()),
    sourceInputs=len(records), equalInputs=sum(x["sameBytes"] for x in records), reachableFunctions=sorted(closure),
    supplementaryChanges=[x["path"] for x in supp if not x["sameBytes"]], appChangedSwift=len(app_records),
    rawEvidence=str(out.relative_to(BASE)), commands=len(commands), reuseAccepted=False), indent=2))
