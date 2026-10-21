from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess

R = Path('F:/yuedu-reader')
G = 'D:/app/Git/cmd/git.exe'
S = R / '.build/current-reviewed-sdk-native-submission'
RECORD = R / 'docs/legado-ios/core-sdk-s2-preupdate-native-result-checkpoint.json'

def git(*args):
    return subprocess.check_output([G, *args], cwd=R)

def digest(raw):
    return hashlib.sha256(raw).hexdigest()

def fact(p):
    raw = p.read_bytes()
    return {'path': p.relative_to(R).as_posix(), 'bytes': len(raw), 'sha256': digest(raw)}

def write(p, obj):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes((json.dumps(obj, ensure_ascii=False, indent=2) + '\n').encode())

assert not (S / 'submission.json').exists(), 'Do not resubmit a recorded pair'
assert all(line == '?? debug.log' for line in git('status', '--porcelain').decode().splitlines())
record = json.loads(RECORD.read_bytes())
assert record['independentSourceReviewApproved'] is True
assert record['sourceCounts']['currentcoreDefinitions'] == 471
assert record['sourceCounts']['currentcoreLeaves'] == 474
assert record['sourceCounts']['originalMethods'] == 32
assert record['resourceProductionActivated'] is False
assert record['firstRegistrationDraftIncluded'] is False
assert record['sourceByteBinding']['uniqueInputs'] == 380
source = git('rev-parse', 'HEAD').decode().strip()
assert len(source) == 40
closure_path = R / 'docs/legado-ios/evidence/sdk-s2-preupdate-native-result-checkpoint/source-closures.json'
closures = json.loads(closure_path.read_bytes())
assert len(closures['union']) == 380
for row in closures['union']:
    raw = (R / row['path']).read_bytes()
    assert len(raw) == row['bytes'] and digest(raw) == row['sha256'], row['path']
    assert git('show', source + ':' + row['path']) == raw, row['path']
policy = json.loads((R / 'docs/legado-ios/completion-plan.json').read_bytes())['execution']['cloudTriggerPolicy']
assert policy['onlyLiveSDKHandles'] == []
assert policy['terminalArchivesPending'] == []
tags = ['reader-renewal-' + source[:7], 'legado-native-reader-test-' + source[:7]]
assert git('tag', '--list', *tags).strip() == b''
remote = git('ls-remote', '--tags', 'origin', *['refs/tags/' + tag for tag in tags])
assert remote.strip() == b'', 'Exact remote tag already exists; never recreate it'
submission = {
    'schemaVersion': 1, 'phase': 'reviewed-no-tags-created-yet',
    'preparedUTC': datetime.now(timezone.utc).isoformat(),
    'sourceCommit': source, 'tags': tags,
    'checkpoint': fact(RECORD), 'sourceClosure': fact(closure_path),
    'sourceInputsBoundToWorkingTreeAndGit': 380,
    'intendedSelection': record['sourceCounts'],
    'exactTargetTagsPreviouslyAbsent': True,
    'latestClosedPair': policy['latestClosedCorePair'],
    'actualNewSDKTests': 0, 'actualNewNativeTests': 0,
    'actualNewCloudRunsObserved': 0,
    'IPARebuiltOrTagSubmitted': False,
    'automaticSelfRenewalImplemented': False,
    'fullLegadoCompatibilityEstablished': False,
}
write(S / 'submission.json', submission)
for tag in tags:
    subprocess.run([G, 'tag', tag, source], cwd=R, check=True)
submission['phase'] = 'two-local-tags-created-push-pending'
write(S / 'submission.json', submission)
push = subprocess.run([G, 'push', '--atomic', 'origin', *['refs/tags/' + tag + ':refs/tags/' + tag for tag in tags]], cwd=R, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
(S / 'tag-push.log').write_bytes(push.stdout)
submission['pushExitCode'] = push.returncode
submission['pushLog'] = fact(S / 'tag-push.log')
if push.returncode == 0:
    submission['phase'] = 'both-source-bound-tags-pushed-awaiting-initial-run-admission'
    submission['pushedUTC'] = datetime.now(timezone.utc).isoformat()
write(S / 'submission.json', submission)
assert push.returncode == 0, 'Push failed; use the recorded phase rather than recreating tags'
print(json.dumps({'sourceCommit': source, 'tags': tags, 'pushExitCode': push.returncode, 'actualCloudRunsObserved': 0, 'newIPA': False}))
