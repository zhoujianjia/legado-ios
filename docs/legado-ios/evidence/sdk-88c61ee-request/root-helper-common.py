"""Shared read/verify helpers. Importing this file performs no repository actions."""
from pathlib import Path
import hashlib
import json
import subprocess
from urllib.parse import urlparse

ROOT = Path('F:/yuedu-reader')
GIT = 'D:/app/Git/cmd/git.exe'
STAGE = Path(__file__).resolve().parent
CHECKPOINT = 'docs/legado-ios/core-general-webjs-runtime-repairs-checkpoint.json'
PLAN = 'docs/legado-ios/completion-plan.json'
FLAGS = ('allNonDeviceWorkComplete', 'automaticSelfRenewalImplemented',
         'fullLegadoCompatibilityEstablished', 'legalRedistributionClearanceEstablished')
EXPECTED_COUNTS = {
    'AppDefinitions': 463, 'AppLeaves': 466, 'BoolParameterPairs': 3,
    'coreInputs': 346, 'nativeInputs': 158, 'uniqueInputUnion': 362,
    'NativeOriginalDefinitions': 28, 'NativeLoginInfoDefinitions': 16,
    'NativeMainJSDefinitions': 1, 'NativeIndependentColdHosts': 2,
    'PackageMethods': 24, 'PackageCompilationInputs': 16, 'PackageControls': 7,
    'PackageAllInputs': 23,
}
OLD_TERMINALS = (
    ('latestSDKTerminal', 39507170170, 118918888695, 'failure'),
    ('latestOriginalNativeTerminal', 39507170384, 118918886521, 'success'),
)
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
    path = Path(path)
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
    actual = owned_path(relative)
    assert raw_fact(actual) == {key: expected[key] for key in ('bytes', 'sha256')}, relative
    return actual

def write_new(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('xb') as stream:
        stream.write((json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8'))

def git(*args):
    return subprocess.check_output([GIT, *args], cwd=ROOT)

def clean_head():
    source = git('rev-parse', 'HEAD').decode().strip()
    assert len(source) == 40 and all(x in '0123456789abcdef' for x in source)
    assert all(line == '?? debug.log' for line in git('status', '--porcelain').decode().splitlines())
    return source

def false_flags(value):
    for key in FLAGS:
        assert value[key] is False, key

def closed_fc3(plan):
    false_flags(plan)
    cloud = plan['execution']['cloudTriggerPolicy']
    assert cloud['onlyLiveSDKHandles'] == []
    for key, run_id, job_id, conclusion in OLD_TERMINALS:
        row = cloud[key]
        assert row['runID'] == run_id and row['jobID'] == job_id
        assert row['status'] == 'completed' and row['conclusion'] == conclusion
        assert row['queryAgain'] is False
    return cloud

def checkpoint_state():
    record = read(ROOT / CHECKPOINT)
    false_flags(record)
    assert record['changedControls'] == 5 and record['sourceReviewFindings'] == []
    counts = record['countsForNextCheckpoint']
    for key, expected in EXPECTED_COUNTS.items():
        assert counts[key] == expected, (key, counts.get(key))
    controls = record['sourceFiles']
    production = record['productionSourceBindings']
    assert len(controls) == 5 and len({row['path'] for row in controls}) == 5
    assert len(production) == 30 and len({row['path'] for row in production}) == 30
    for row in controls:
        check(row['path'], row['candidate'])
    for row in production:
        check(row['path'], row.get('candidate', row))
    preserved = record['preservedEvidence']
    for row in preserved:
        check(row['path'], row)
    union_rows = [row for row in preserved
                  if Path(row['path']).name in ('union-source-inputs-v1.json', 'union-source-inputs.json')]
    assert len(union_rows) == 1, 'Need exactly one canonical reviewed union-source-inputs roster.'
    union_evidence = union_rows[0]
    union = read(ROOT / union_evidence['path'])
    assert isinstance(union, list) and len(union) == 362
    assert len({row['path'] for row in union}) == 362
    assert {row['path'] for row in controls + production} <= {row['path'] for row in union}
    for row in union:
        assert not row['path'].startswith('.build/'), 'The input roster must bind tracked production/control files.'
        check(row['path'], row)
    # Status clean does not detect ignored files. Independently require every
    # canonical evidence input to be tracked in this same source checkout.
    tracked = set(git('ls-files', '-z').decode().split('\0'))
    assert all(row['path'] in tracked for row in union)
    return record, counts, union_evidence

def public_run_url(url, run_id):
    parsed = urlparse(url)
    assert parsed.scheme == 'https' and parsed.netloc == 'github.com'
    assert not parsed.query and not parsed.fragment
    assert parsed.path.endswith('/actions/runs/' + str(run_id))
    return url

def normalized_copy(source, destination):
    """Archive inspectable UTF8 only; preserve exact original facts separately."""
    text = source.read_text('utf-8-sig')
    payload = ('\n'.join(line.rstrip(' \t') for line in text.splitlines()).rstrip('\n') + '\n').encode('utf-8')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open('xb') as stream:
        stream.write(payload)
    return {**fact(destination), 'originalEvidence': fact(source),
            'normalization': 'UTF8/LF, trailing horizontal and empty EOF whitespace removed; exact original facts retained.'}
