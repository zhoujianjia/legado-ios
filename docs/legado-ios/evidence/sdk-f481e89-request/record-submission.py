from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess

R = Path('F:/yuedu-reader')
S = R / '.build/current-reviewed-sdk-native-submission'
G = 'D:/app/Git/cmd/git.exe'
SHA = 'f481e89717b96df1d15d5c3f9a72c359d1fcef55'
FLAGS = ['allNonDeviceWorkComplete', 'automaticSelfRenewalImplemented', 'fullLegadoCompatibilityEstablished', 'legalRedistributionClearanceEstablished']

def read(p):
    return json.loads(p.read_bytes())

def fact(p):
    raw = p.read_bytes()
    return {'path': p.relative_to(R).as_posix(), 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}

def write(p, obj):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes((json.dumps(obj, ensure_ascii=False, indent=2) + '\n').encode())

assert subprocess.check_output([G, 'rev-parse', 'HEAD'], cwd=R).decode().strip() == SHA
assert all(line == '?? debug.log' for line in subprocess.check_output([G, 'status', '--porcelain'], cwd=R).decode().splitlines())
submission = read(S / 'submission.json')
assert submission['sourceCommit'] == SHA and submission['pushExitCode'] == 0
assert submission['phase'] == 'both-source-bound-tags-pushed-awaiting-initial-run-admission'
assert submission['sourceInputsBoundToWorkingTreeAndGit'] == 380
runs = read(S / 'initial-runs.json')
expected = {
    'SDK': (39533277187, 119003957104, '.github/workflows/reader-renewal-probe.yml', 'reader-renewal-f481e89'),
    'Native': (39533277157, 119003957102, '.github/workflows/legado-native-reader-test.yml', 'legado-native-reader-test-f481e89'),
}
selected = {}
for name, (run_id, job_id, workflow, tag) in expected.items():
    matches = [run for run in runs['workflow_runs'] if run['id'] == run_id]
    assert len(matches) == 1
    run = matches[0]
    assert run['head_sha'] == SHA and run['path'] == workflow and run['head_branch'] == tag and run['event'] == 'push'
    assert run['status'] == 'in_progress' and run['conclusion'] is None
    jobs = read(S / ('initial-jobs-' + str(run_id) + '.json'))['jobs']
    assert len(jobs) == 1 and jobs[0]['id'] == job_id
    job = jobs[0]
    assert job['status'] == 'in_progress' and job['conclusion'] is None
    selected[name] = {
        'runID': run_id, 'jobID': job_id, 'sourceCommit': SHA, 'sourceTag': tag,
        'workflow': workflow, 'url': run['html_url'],
        'initialStatus': 'in_progress', 'initialConclusion': None,
        'initialJob': job,
        'initialJobsTool': 'github.fetch_workflow_run_jobs(repo_full_name=zhoujianjia/legado-ios,run_id=' + str(run_id) + ')',
        'actualNewAcceptedTestsAtObservation': 0,
    }
assert any(s['name'] == 'Execute471 current-core definitions with474 exact native argument leaves' for s in selected['SDK']['initialJob']['steps'])
assert any(s['name'] == 'Execute1 MainJS and32 original methods in separate required hosts' for s in selected['Native']['initialJob']['steps'])

base = R / 'docs/legado-ios/evidence/sdk-f481e89-request'
record_path = R / 'docs/legado-ios/core-sdk-f481e89-request.json'
assert not base.exists() and not record_path.exists()
paths = []
evidence = []
for name, origin in [
    ('submission.json', S / 'submission.json'),
    ('tag-push.log', S / 'tag-push.log'),
    ('initial-runs.json', S / 'initial-runs.json'),
    ('initial-jobs-native.json', S / 'initial-jobs-39533277157.json'),
    ('initial-jobs-sdk.json', S / 'initial-jobs-39533277187.json'),
    ('submit-reviewed-pair.py', R / '.build/submit-reviewed-sdk-native-pair.py'),
    ('record-submission.py', Path(__file__)),
]:
    target = base / name
    target.parent.mkdir(parents=True, exist_ok=True)
    raw = origin.read_bytes()
    assert b'\0' not in raw
    normalized = ('\n'.join(line.rstrip(' \t') for line in raw.decode('utf-8-sig').splitlines()).rstrip('\n') + '\n').encode()
    target.write_bytes(normalized)
    paths.append(target)
    evidence.append({**fact(target), 'original': fact(origin), 'normalization': 'UTF8/LF and trailing whitespace only; original facts preserved'})

record = {
    'schemaVersion': 1, 'recordedUTC': datetime.now(timezone.utc).isoformat(),
    'status': 'one-coherent-source-bound-pair-actually-pushed-and-initially-observed-running',
    'sourceCommit': SHA,
    'checkpoint': 'docs/legado-ios/core-sdk-s2-preupdate-native-result-checkpoint.json',
    'sourceInputsComparedToWorkingTreeAndCommittedGitBytes': 380,
    'tags': submission['tags'], 'actualPushedTags': 2,
    'runs': selected,
    'intendedSelection': submission['intendedSelection'],
    'actualNewAppExecutedOrAccepted': 0, 'actualNewNativeExecutedOrAccepted': 0,
    'actualNewPackageMethodsAccepted': 0,
    'initialRunCollectionCalls': 1, 'initialJobsCalls': 2,
    'oldTerminalRunQueries': 0, 'IPARebuiltOrSubmitted': False,
    'includedProduction': [
        'proxy and source-scoped remote jsLib',
        'same-key certificate reuse and strict later profile expirations',
        'original reGetBook/refreshTocUrl and actual App identity handoff',
        'exact two f233 Native/App test call compiler repairs',
        'separate native WK result information characterization test only',
    ],
    'excludedUnfinishedWork': [
        'first Apple device/AppID/AppGroup registration draft',
        'unactivated resource sniff production candidate',
        'complete object-result conversion compatibility',
        'real Apple authorization and complete actual JVM IPA signing',
        'actual paired same-physical-device installation route, no-VPN/computer independence and unattended renewal',
    ],
    'preservedEvidence': evidence,
    'limits': [
        'Initial in-progress statuses and visible selection labels prove admission of this source pair, not compilation or test success.',
        'Counts are intended distinct definitions and exact leaves. Native product and platform characterization methods remain separate.',
        'The independent Package selection has24 methods and23 facts; the workflow fact changed and this run must produce its own current evidence.',
        'The two f233 runs remain closed archived failures and are not queried again.',
        'Continue ready production work; do not spend a development turn polling this pair or submit per-item/IPA tags.',
    ], **{key: False for key in FLAGS},
}
write(record_path, record)
paths.append(record_path)
plan_path = R / 'docs/legado-ios/completion-plan.json'
plan = read(plan_path)
assert all(plan[key] is False for key in FLAGS)
policy = plan['execution']['cloudTriggerPolicy']
assert policy['onlyLiveSDKHandles'] == [] and policy['terminalArchivesPending'] == []
rel = record_path.relative_to(R).as_posix()
handles = [{k: run[k] for k in ['runID', 'jobID', 'sourceCommit', 'sourceTag', 'workflow', 'url', 'initialStatus']} for run in selected.values()]
policy['onlyLiveSDKHandles'] = handles
policy['alreadyRunningTasks'] = 'Only f481e89 SDK39533277187/job119003957104 and Native39533277157/job119003957102 are live. The f233 pair is fully closed and archived; never query it again.'
policy['nextPlannedCheckpoint'] = 'This exact coherent pair is running. Continue the separate first-registration production draft. Do not submit another pair until current terminal evidence is classified and a necessary reviewed successor is ready; no per-change or IPA tag.'
policy['latestSubmittedCorePair'] = {'sourceCommit': SHA, 'record': rel, 'handles': handles, 'actualNewAcceptedTests': 0}
steps = plan['execution']['stepByStep']
steps['queuedS2PreUpdateNativeResultCheckpoint'].update({'status': 'submitted-awaiting-terminal-artifacts', 'requestRecord': rel, 'sourceCommit': SHA, 'actualPushedTags': 2, 'actualSDKExecutionsAccepted': 0})
for step in steps['steps']:
    step['pendingSDKRequest'] = rel
plan.setdefault('activeDevelopmentBatchRecords', []).append(rel)
write(plan_path, plan)
paths.append(plan_path)
write(S / 'canonical-roster.json', [fact(p) for p in paths])
subprocess.run([G, 'diff', '--check'], cwd=R, check=True)
print(json.dumps({'canonicalPaths': len(paths), 'sourceCommit': SHA, 'liveRuns': 2, 'actualNewAcceptedTests': 0, 'newIPA': False}))
