"""Root-only draft utilities. Importing this module runs no repository command."""
from pathlib import Path
import hashlib
import json
import subprocess
from urllib.parse import urlparse

ROOT = Path('F:/yuedu-reader')
GIT = 'D:/app/Git/cmd/git.exe'
STAGE = Path(__file__).resolve().parent
CHECKPOINT = 'docs/legado-ios/core-sdk-native-api-characterization-checkpoint.json'
PLAN = 'docs/legado-ios/completion-plan.json'
COHERENT = '.build/sdk-native-api-coherent-checkpoint-composition/final-v1.json'
COHERENT_FACT = {'bytes': 15599, 'sha256': '2e0d6a792052278b600d54fcb732202409efa0e7fbfb0312ad157423a2bd1b4b'}
OLD_SOURCE = '88c61ee4b80889a617d344fda668d077f73fa95b'
FLAGS = ('allNonDeviceWorkComplete', 'automaticSelfRenewalImplemented',
         'fullLegadoCompatibilityEstablished', 'legalRedistributionClearanceEstablished')
EXPECTED_COUNTS = {
    'AppDefinitions': 463, 'AppLeaves': 466, 'BoolParameterPairs': 3,
    'coreInputs': 349, 'nativeInputs': 161, 'uniqueInputUnion': 365,
    'NativeProductDefinitions': 28, 'NativePlatformCharacterizations': 2,
    'NativeOriginalDefinitions': 30, 'NativeLoginInfoDefinitions': 16,
    'NativeMainJSDefinitions': 1, 'NativeIndependentColdHosts': 2,
    'PackageMethods': 24, 'PackageCompilationInputs': 16, 'PackageControls': 7,
    'PackageAllInputs': 23,
}
OLD_TERMINALS = (
    ('latestSDKTerminal', 39520239925, 118962037971,
     'docs/legado-ios/core-sdk-88c61ee-terminal-result.json'),
    ('latestOriginalNativeTerminal', 39520240533, 118962039359,
     'docs/legado-ios/core-native-88c61ee-terminal-result.json'),
)
INITIAL_REQUEST = 'docs/legado-ios/core-sdk-88c61ee-request.json'
WORKFLOWS = {
    'reader-renewal-': 'Local Reader Renewal Probe Tests',
    'legado-native-reader-test-': 'Legado Native Main-App Product Chain',
}


def read(path):
    return json.loads(Path(path).read_text('utf-8'))


def raw_fact(path):
    data = Path(path).read_bytes()
    return {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}


def fact(path):
    path = Path(path).resolve()
    return {'path': path.relative_to(ROOT).as_posix(), **raw_fact(path)}


def owned_path(relative):
    assert isinstance(relative, str) and relative and '\\' not in relative
    path = Path(relative)
    assert not path.is_absolute() and '..' not in path.parts
    actual = ROOT / path
    assert actual.is_file() and not actual.is_symlink(), relative
    assert actual.resolve().is_relative_to(ROOT.resolve()), relative
    return actual


def check(relative, expected):
    path = owned_path(relative)
    assert raw_fact(path) == {k: expected[k] for k in ('bytes', 'sha256')}, relative
    return path


def write_new(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('xb') as stream:
        stream.write((json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8'))


def git(*args):
    return subprocess.check_output([GIT, *args], cwd=ROOT)


def clean_head(expected=None):
    source = git('rev-parse', 'HEAD').decode().strip()
    assert len(source) == 40 and all(c in '0123456789abcdef' for c in source)
    assert expected is None or source == expected, 'HEAD changed since root review'
    assert all(line == '?? debug.log' for line in git('status', '--porcelain').decode().splitlines())
    assert git('symbolic-ref', '--short', 'HEAD').decode().strip() == 'legado-ios-prototype'
    return source


def false_flags(value):
    assert all(value[k] is False for k in FLAGS)


def closed_88(plan):
    false_flags(plan)
    cloud = plan['execution']['cloudTriggerPolicy']
    assert cloud['onlyLiveSDKHandles'] == [], 'Both old handles must be terminal/archived first'
    tracked = set(git('ls-files', '-z').decode().split('\0'))
    history = []
    for key, run_id, job_id, archive in OLD_TERMINALS:
        row = cloud[key]
        assert (row['runID'], row['jobID'], row['status'], row['conclusion']) == (run_id, job_id, 'completed', 'failure')
        assert row['record'] == archive and row['queryAgain'] is False
        assert archive in tracked
        terminal = read(owned_path(archive))
        false_flags(terminal)
        assert terminal['sourceCommit'] == OLD_SOURCE and terminal['queryAgain'] is False
        # Explicitly support the two existing canonical terminal record schemas.
        if 'runID' in terminal:
            assert terminal['runID'] == run_id and terminal['jobID'] == job_id
            assert terminal['workflowStatus'] == 'completed' and terminal['conclusion'] == 'failure'
        else:
            assert terminal['workflowRun'] == run_id and terminal['SDKJob'] == job_id
            assert terminal['status'].startswith('completed-failure')
        history.append(fact(ROOT / archive))
    assert INITIAL_REQUEST in tracked
    history.append(fact(owned_path(INITIAL_REQUEST)))
    return cloud, history


def flat(row):
    value = row.get('candidate', row)
    return {'path': row['path'], **{k: value[k] for k in ('bytes', 'sha256')}}


def checkpoint_state():
    assert raw_fact(ROOT / COHERENT) == COHERENT_FACT
    prepared = read(ROOT / COHERENT)
    record = read(owned_path(CHECKPOINT))
    false_flags(record)
    assert record['changedControls'] == 5 and record['sourceReviewFindings'] == []
    assert record['actualResultAccepted'] is False and record['newIPATag'] is False
    counts = record['countsForNextCheckpoint']
    for key, value in EXPECTED_COUNTS.items():
        assert counts[key] == value, (key, counts.get(key))
    controls, changed = record['sourceFiles'], record['integratedChangedSources']
    assert len(controls) == len({x['path'] for x in controls}) == 5
    assert len(changed) == len({x['path'] for x in changed}) == 8
    assert [flat(x) for x in controls] == [flat(x) for x in prepared['files']]
    expected_changed = read(check(prepared['integratedChangedSources']['path'], prepared['integratedChangedSources']))
    assert [flat(x) for x in changed] == expected_changed
    preserved = record['preservedEvidence']
    for row in preserved:
        check(row['path'], row)
    rosters = [x for x in preserved if Path(x['path']).name == 'source-rosters-v1.json']
    assert len(rosters) == 1, 'Archive exactly the reviewed365-row source-rosters-v1.json'
    roster_fact = rosters[0]
    roster = read(owned_path(roster_fact['path']))
    expected_roster = read(check(prepared['sourceRosters']['path'], prepared['sourceRosters']))
    assert roster == expected_roster
    rows = roster['files']
    assert len(rows) == len({x['path'] for x in rows}) == roster['unionCount'] == 365
    assert sum(x['core'] for x in rows) == roster['coreCount'] == 349
    assert sum(x['native'] for x in rows) == roster['nativeCount'] == 161
    assert sum(x['candidateControl'] for x in rows) == 5
    tracked = set(git('ls-files', '-z').decode().split('\0'))
    assert CHECKPOINT in tracked and PLAN in tracked
    for row in rows:
        assert not row['path'].startswith('.build/') and row['path'] in tracked
        check(row['path'], row)
    for row in controls + changed:
        check(row['path'], row.get('candidate', row))
    for row in preserved:
        assert row['path'] in tracked
    return record, counts, roster_fact


def public_run_url(url, run_id):
    parsed = urlparse(url)
    assert parsed.scheme == 'https' and parsed.netloc == 'github.com'
    assert parsed.path == '/zhoujianjia/legado-ios/actions/runs/' + str(run_id)
    assert not parsed.query and not parsed.fragment
    return url


def normalized_copy(source, destination):
    text = source.read_text('utf-8-sig')
    payload = ('\n'.join(x.rstrip(' \t') for x in text.splitlines()).rstrip('\n') + '\n').encode('utf-8')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open('xb') as stream:
        stream.write(payload)
    return {**fact(destination), 'originalEvidence': fact(source),
            'normalization': 'UTF8/LF and stripped trailing whitespace; exact original facts preserved.'}
