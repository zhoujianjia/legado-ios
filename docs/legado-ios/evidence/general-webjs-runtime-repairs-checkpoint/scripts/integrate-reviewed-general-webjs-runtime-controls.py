from pathlib import Path
import datetime, hashlib, json, re, subprocess, sys

R = Path.cwd()
S = R / '.build/consolidated-sdk-general-webjs-runtime-repairs-checkpoint'
V = Path(sys.argv[1]).resolve()
G = 'D:/app/Git/cmd/git.exe'
FLAGS = ['allNonDeviceWorkComplete', 'automaticSelfRenewalImplemented',
         'fullLegadoCompatibilityEstablished', 'legalRedistributionClearanceEstablished']
def read(p): return json.loads(p.read_bytes())
def fact(p):
    b = p.read_bytes()
    return dict(bytes=len(b), sha256=hashlib.sha256(b).hexdigest())
def save(p, value):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')
def check(p, row): assert fact(p) == {k: row[k] for k in ('bytes', 'sha256')}, str(p)

f = read(S / 'preparation/final-v1.json')
v = read(V)
assert fact(S / 'preparation/final-v1.json') == dict(bytes=22325, sha256='37213734806c8a49cb469de7771ff531677bfd4e639021a2496b3b94d1264ef3')
assert v['approved'] and v['failedChecks'] == 0 and v['remainingConfirmedFindings'] == []
assert v['final'] == dict(path=(S / 'preparation/final-v1.json').relative_to(R).as_posix(), **fact(S / 'preparation/final-v1.json'))
assert all(x == '?? debug.log' for x in subprocess.check_output([G, 'status', '--porcelain'], cwd=R).decode().splitlines())
assert subprocess.check_output([G, 'rev-parse', 'HEAD'], cwd=R).decode().strip() == f['canonicalSource']
assert f['counts']['core'] == 346 and f['counts']['native'] == 158 and f['counts']['uniqueUnion'] == 362
for row in f['files']:
    assert fact(R / row['path']) == row['baseline']
    assert fact(R / f['candidateRoot'] / row['path']) == row['candidate']
for row in f['productionSources']: check(R / row['path'], row)

rp = R / 'docs/legado-ios/core-general-webjs-runtime-repairs-checkpoint.json'
base = R / 'docs/legado-ios/evidence/general-webjs-runtime-repairs-checkpoint'
assert not rp.exists() and not base.exists()
items = {'preparation.json': S / 'preparation/final-v1.json', 'independent-review.json': V,
         'scripts/integrate-reviewed-general-webjs-runtime-controls.py': Path(__file__)}
for p in V.parent.glob('*.py'): items['scripts/review/' + p.name] = p
for row in f['evidence']:
    p = R / row['path']; check(p, row)
    items['actual/' + p.relative_to(S).as_posix()] = p
for row in f['files']:
    p = R / row['diff']['path']; check(p, row['diff'])
    items['diffs/' + p.relative_to(S / 'diffs').as_posix() + '.patch'] = p
normalized = {}
for name, p in items.items():
    raw = p.read_bytes()
    assert b'\0' not in raw and not re.search(rb'[?&]X-Amz-Signature=', raw)
    text = raw.decode('utf-8-sig')
    normalized[name] = ('\n'.join(x.rstrip(' \t') for x in text.splitlines()).rstrip('\n') + '\n').encode() if text else b''
pp = R / 'docs/legado-ios/completion-plan.json'
plan = read(pp)
assert all(plan[k] is False for k in FLAGS)
cloud = plan['execution']['cloudTriggerPolicy']
assert cloud['onlyLiveSDKHandles'] == []
assert cloud['latestSDKTerminal']['runID'] == 39507170170 and cloud['latestSDKTerminal']['queryAgain'] is False
assert cloud['latestOriginalNativeTerminal']['runID'] == 39507170384 and cloud['latestOriginalNativeTerminal']['queryAgain'] is False
paths, preserved = [], []
for name, p in items.items():
    dst = base / name; dst.parent.mkdir(parents=True, exist_ok=True); dst.write_bytes(normalized[name]); paths.append(dst)
    preserved.append(dict(path=dst.relative_to(R).as_posix(), **fact(dst),
                          original=dict(path=p.relative_to(R).as_posix(), **fact(p)),
                          normalization='UTF8/LF/trailing whitespace only; frozen raw facts retained'))
for row in f['files']:
    dst = R / row['path']; dst.write_bytes((R / f['candidateRoot'] / row['path']).read_bytes()); paths.append(dst)
union = read(R / f['unionRoster']['path'])
assert len(union) == 362
for row in union: check(R / row['path'], row)
counts = dict(AppDefinitions=463, AppLeaves=466, BoolParameterPairs=3, coreInputs=346,
    NativeOriginalDefinitions=28, NativeLoginInfoDefinitions=16, NativeMainJSDefinitions=1,
    NativeIndependentColdHosts=2, nativeInputs=158, PackageMethods=24, PackageCompilationInputs=16,
    PackageControls=7, PackageAllInputs=23, uniqueInputUnion=362, unchangedCanonicalNoncandidateInputs=357)
clarification = dict(GeneralPublicCalls=64, GeneralSyntheticBrowserHostCalls=17, GeneralHTTP=7,
    Base64PublicCalls=78, Base64AnalyzeRuleSubset=39,
    explanation='Frozen preparation proofLimits[1] uses ambiguous joint-total wording. 78 belongs only to Base64; General64 is a separate consumer. Analyze39 is already within Base6478. Raw preparation preserved.')
record = dict(schemaVersion=1, recordedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
    status='reviewed-unified-General-WebJS-Base64-runtime-repair-controls-integrated-SDK-Native-pending',
    reviewedCanonicalParent=f['canonicalSource'], sourceFiles=f['files'], changedControls=5,
    productionSourceBindings=f['productionSources'], countsForNextCheckpoint=counts,
    sourceReviewFindings=[], metadataCountClarification=clarification,
    actualPortableValidation=f['actualPortableGuards'], preservedEvidence=preserved,
    invariantPreservation=f['invariants'], actualSDK_JNI_WKExecuted=0, actualResultAccepted=False,
    sourceRecords=['docs/legado-ios/core-installation-lookup-complete-step.json',
        'docs/legado-ios/core-original-reader-cold-process-step.json',
        'docs/legado-ios/core-renewal-authenticated-spd-challenge-step.json',
        'docs/legado-ios/core-original-local-html-webjs-step.json',
        'docs/legado-ios/core-original-base64-flags-step.json',
        'docs/legado-ios/core-sdk-fc3-runtime-repairs-step.json',
        'docs/legado-ios/core-original-cookie-response-repair-step.json',
        'docs/legado-ios/core-original-general-webjs-step.json',
        'docs/legado-ios/core-original-general-webjs-blank-regex-step.json'],
    limits=[x for i, x in enumerate(f['proofLimits']) if i != 1] + [clarification['explanation']],
    newIPATag=False, newCloudTags=0, **{k: False for k in FLAGS})
save(rp, record); paths.append(rp)
steps = plan['execution']['stepByStep']
for key in ['queuedColdProcessLookupNextCheckpoint', 'queuedSPDWebJSColdNextCheckpoint']:
    steps[key]['supersededBy'] = rp.relative_to(R).as_posix()
steps['queuedGeneralWebJSRuntimeRepairsNextCheckpoint'] = dict(record=rp.relative_to(R).as_posix(),
    **counts, actualAcceptancePending=True, priorPairTerminalAndArchived=True, noAdditionalTagCreated=True)
for key in ['installationLookupTerminalSlice', 'originalReaderColdProcessSlice', 'authenticatedSPDChallengeSlice',
            'originalLocalHTMLWebJSSlice', 'base64FlagsSlice', 'fc3RuntimeRepairs',
            'cookieResponseConversionRepair', 'generalWebJSSlice', 'generalWebJSBlankRegexRepair']:
    steps[key]['queuedUnifiedCheckpoint'] = rp.relative_to(R).as_posix()
for step in steps['steps']:
    if step['id'] in ['C4', 'C5']:
        step.setdefault('implementationEvidence', []).append(dict(record=rp.relative_to(R).as_posix(),
            scope='Five unified controls bind actual reviewed General/Base64/Cookie/TLS/CMS repairs and earlier SPD/Lookup/cold-host changes. Four affected portable methods passed once; actual SDK/JNI/WK/cold-process acceptance pending.'))
        step['nextActionZh'] = ('最终统一源码清单为core346、Native158、去重362；App463定义466叶，Native普通28加独立MainJS1，另两个冷进程宿主。'
            '旧fc3两任务已终态归档；已集成确认失败的源码修复，接下来只启动这一份源码的一组SDK/Native验证。实际SDK、签名、JNI/WK和冷进程结果未取得，不能标完成。')
cloud['nextPlannedCheckpoint'] = 'Run one reviewed coherent346/158/362 SDK/Native pair after control integration. Prior fc3 terminal evidence is archived and never queried again. No per-item or IPA tag.'
plan.setdefault('activeDevelopmentBatchRecords', []).append(rp.relative_to(R).as_posix())
save(pp, plan); paths.append(pp)
save(S / 'canonical-roster.json', [dict(path=p.relative_to(R).as_posix(), **fact(p)) for p in paths])
subprocess.run([G, 'diff', '--check'], cwd=R, check=True)
print(json.dumps(dict(reviewedPaths=len(paths), changedControls=5, counts=counts, actualPortablePassed=4, SDK=0, newTags=0)))
