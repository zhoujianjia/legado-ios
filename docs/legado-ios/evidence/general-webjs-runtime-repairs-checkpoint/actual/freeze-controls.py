from pathlib import Path
import argparse
import datetime
import hashlib
import json
import re

ROOT = Path('F:/yuedu-reader')
STAGE = Path(__file__).resolve().parent

def load(path):
    return json.loads(path.read_text('utf-8'))

def rf(data):
    return {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}

def fact(path):
    return {'path': path.relative_to(ROOT).as_posix(), **rf(path.read_bytes())}

def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')

parser = argparse.ArgumentParser()
parser.add_argument('--canonical-source', required=True)
args = parser.parse_args()
assert re.fullmatch('[0-9a-f]{7,40}', args.canonical_source)
out = STAGE / 'preparation/final-v1.json'
assert not out.exists(), 'Final is immutable.'
draft = load(STAGE / 'preparation/controls-draft-v1.json')
validation = load(STAGE / 'validation-facts-v1.json')
controls = {row['path'] for row in draft['files']}
rows = []
for row in draft['files']:
    relative = row['path']
    baseline = (STAGE / 'rawbaseline' / relative).read_bytes()
    candidate = (STAGE / 'work' / relative).read_bytes()
    assert baseline == (ROOT / relative).read_bytes(), relative
    assert rf(candidate) == {k: row['candidate'][k] for k in ('bytes', 'sha256')}
    rows.append({'path': relative, 'baseline': rf(baseline), 'candidate': rf(candidate), 'diff': row['diff']})
production = load(STAGE / 'production-source-bindings-v1.json')
for row in production:
    assert rf((ROOT / row['path']).read_bytes()) == {k: row[k] for k in ('bytes', 'sha256')}, row['path']
allinputs = load(STAGE / 'union-source-inputs-v1.json')
for row in allinputs:
    relative = row['path']
    expected = {k: row[k] for k in ('bytes', 'sha256')}
    actual = (STAGE / 'work' / relative).read_bytes() if relative in controls else (ROOT / relative).read_bytes()
    assert rf(actual) == expected, relative
assert len(allinputs) == 362 and len(production) == 30 and len(rows) == 5

reader = 'Tests/iOS/LegadoNativeOriginalReaderTests.swift'
login = 'Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift'
readermethods = re.findall(r'(?m)^\s+func\s+(test\w+)\s*\(', (ROOT / reader).read_text('utf-8'))
loginmethods = re.findall(r'(?m)^\s+func\s+(test\w+)\s*\(', (ROOT / login).read_text('utf-8'))
assert len(readermethods) == len(set(readermethods)) == 14
assert len(loginmethods) == len(set(loginmethods)) == 16
assert draft['newSelector'].split('/', 1)[1] in readermethods
counts = dict(draft['counts'], ReaderMethodsIncludingCold=14, LoginInfoMethods=16,
    unchangedCanonicalNoncandidateInputs=len(allinputs) - len(rows))
evidence = [fact(STAGE / name) for name in (
    'prepare-controls.py', 'validate-controls.py', 'freeze-controls.py',
    'preparation/baseline-route-inventory-v1.json', 'preparation/baseline-source-paths-v1.json',
    'preparation/baseline-invariants-v1.json', 'preparation/controls-draft-v1.json',
    'validation-facts-v1.json', 'actual-portable-commands-v1.json',
    'affected-core-v1.log', 'affected-native-v1.log',
    'core-source-inputs-v1.json', 'Native-source-inputs-v1.json', 'Package-source-inputs-v1.json',
    'union-source-inputs-v1.json', 'production-source-bindings-v1.json',
    'production-function-ast-facts-v1.json')]
final = {
    'schemaVersion': 1, 'frozenUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'status': 'Five affected controls frozen; four actual portable methods passed once. Ready for independent control review and root integration; no SDK/JNI/WK execution claimed.',
    'baselineControls': 'Canonical pre-General-control selection: core343/native148/union359, original27; five raw baseline files remain exact current canonical.',
    'canonicalSource': args.canonical_source,
    'candidateRoot': '.build/consolidated-sdk-general-webjs-runtime-repairs-checkpoint/work',
    'baselineRoot': '.build/consolidated-sdk-general-webjs-runtime-repairs-checkpoint/rawbaseline',
    'files': rows, 'productionSources': production, 'sourceParents': validation['sourceParents'],
    'blankRegexSuccessor': validation['blankRegexSuccessor'],
    'counts': counts, 'sourceRosters': validation['sourceRosters'], 'unionRoster': validation['unionRoster'],
    'newBoundCorePaths': draft['newBoundCorePaths'], 'newBoundNativePaths': draft['newBoundNativePaths'],
    'newNativeSelector': draft['newSelector'],
    'actualPortableGuards': validation['actualPortableGuards'], 'invariants': validation['invariants'],
    'sourceBinding': {'uniqueInputs': 362, 'candidateControls': 5, 'noncandidateBytesEqualCanonical': 357,
        'productionSourceBindings': 30, 'allProductionBytesEqualCanonical': True,
        'RuleBase64WasExistingButPreviouslyUnbound': True,
        'NativeAddsPreviouslyUnboundActualCompileOwners': True,
        'allOldSourcePathsPreserved': True},
    'proofLimits': [
        'Four portable methods are inventory, mutation-refusal, workflow and source-stamp checks. They do not execute Swift, actual WebKit, JNI, Apple signing, installation or iPhone automatic renewal.',
        'The General JVM/Base64 joint public vector total is 78 public calls including the 39 AnalyzeRule subset. The subset is not 39 extra calls or 117 total.',
        'Both prior fc3 workflows are terminal and closed. No result from their older source snapshot is promoted to acceptance of this checkpoint.',
        'General object/object-array completion and complete resource sourceRegex matching remain explicit compatibility gaps; finite existing WK trust behavior remains distinct from Android invalid-certificate proceed.',
        'The cold producer and consumer remain independent test hosts with their original nonce, source, PID, container and actual process-exit receipt checks. Ordinary Native counts do not absorb those two methods.',
        'Package24/23 gates remain a separate workflow step/result. These four portable checks provide no new Package24 acceptance.',
    ],
    'evidence': evidence,
    'operations': {'canonicalWrites': False, 'GitMutations': False, 'cloudQueries': False, 'newTags': False,
        'privateBookSources': False, 'credentials': False, 'unrelatedSuitesRepeated': False},
}
save(out, final)
print(json.dumps({'manifest': fact(out), 'counts': counts, 'actualPortableMethods': 4}))
