from pathlib import Path
import ast
import hashlib
import json
import subprocess
import sys
import types

ROOT = Path('F:/yuedu-reader')
STAGE = ROOT / '.build/consolidated-sdk-login-events-dismiss-lifecycle-delta'
GIT = 'D:/app/Git/cmd/git.exe'
sys.dont_write_bytecode = True


def read(path):
    return json.loads(path.read_bytes())


def fact(path):
    raw = path.read_bytes()
    return {'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}


def verify(path, row):
    assert fact(path) == {k: row[k] for k in ('bytes', 'sha256')}, str(path)


def load(name, baseline=False):
    folder = 'rawbaseline' if baseline else 'work'
    path = STAGE / folder / 'scripts/reader-experience' / name
    # __file__ resolves adjacent already-bound helper modules in the same isolated tree.
    module = types.ModuleType(('before_' if baseline else 'after_') + name.replace('-', '_'))
    module.__file__ = str(STAGE / 'work/scripts/reader-experience' / name)
    exec(compile(path.read_bytes(), str(path), 'exec'), module.__dict__)
    return module


assert not subprocess.check_output([GIT, 'status', '--porcelain'], cwd=ROOT)
head = subprocess.check_output([GIT, 'rev-parse', 'HEAD'], cwd=ROOT).decode().strip()
assert head == 'af865bf538936d0cd76e0983fda6814ba9855b56', head
manifest_path = STAGE / 'preparation/final-v1.json'
assert fact(manifest_path) == {'bytes': 16993, 'sha256': 'e2ba858eb63276d9f9d4b5100e57e179212f8f273aa05c37e053257fc9079945'}
m = read(manifest_path)
assert len(m['files']) == len({row['path'] for row in m['files']}) == 9
candidates = {}
for row in m['files']:
    path = row['path']
    verify(ROOT / path, row['baseline'])
    verify(STAGE / 'rawbaseline' / path, row['baseline'])
    verify(STAGE / 'work' / path, row['candidate'])
    verify(ROOT / row['diff']['path'], row['diff'])
    candidates[path] = (STAGE / 'work' / path).read_bytes()

for row in m['productionManifests'] + [m['rootDismissIntegrationRecord'], m['sourceBindingEvidence'], m['sourceClosureEvidence'], m['invariantEvidence'], m['syntax']]:
    verify(ROOT / row['path'], row)
binding = read(ROOT / m['sourceBindingEvidence']['path'])
assert binding['uniqueSourceInputs'] == len(binding['sources']) == 29
for row in binding['sources']:
    verify(ROOT / row['path'], row)
closures = read(ROOT / m['sourceClosureEvidence']['path'])
unique = {}
for kind, count in [('core', 322), ('native', 113), ('package', 22)]:
    rows = closures[kind]['sources']
    assert closures[kind]['count'] == len(rows) == len({r['path'] for r in rows}) == count
    for row in rows:
        path = row['path']
        raw = candidates[path] if path in candidates else (ROOT / path).read_bytes()
        assert len(raw) == row['bytes'] and hashlib.sha256(raw).hexdigest() == row['sha256'], path
        assert path not in unique or unique[path] == row, path
        unique[path] = row
assert sum(p not in candidates for p in unique) == 324

oldcore, core = load('renewal-probe-tools.py', True), load('renewal-probe-tools.py')
oldnative, native = load('native-smoke-tools.py', True), load('native-smoke-tools.py')
oldpackage, package = load('original-api-package-tools.py', True), load('original-api-package-tools.py')
assert {k: v for k, v in oldcore.EXPECTED_CASES.items() if k != 'currentcore'} == {k: v for k, v in core.EXPECTED_CASES.items() if k != 'currentcore'}
assert oldcore.EXPECTED_CASES['currentcore'] <= core.EXPECTED_CASES['currentcore']
assert len(core.EXPECTED_CASES['currentcore']) == 463 and core.expected_leaf_count('currentcore') == 466
assert core.EXPECTED_CASES['currentcore'] - oldcore.EXPECTED_CASES['currentcore'] == core.CURRENTCORE_FOREGROUND_LIFECYCLE_QUALIFIED_CASES
assert oldcore.PARAMETER_CASES == core.PARAMETER_CASES
assert oldcore.CURRENTCORE_GLYPH_PARAMETER_CASES == core.CURRENTCORE_GLYPH_PARAMETER_CASES
assert oldcore.SDK_REQUIRED_CASE == core.SDK_REQUIRED_CASE
assert oldcore.CURRENTCORE_PHASES == core.CURRENTCORE_PHASES and len(core.CURRENTCORE_PHASES) == 10
old_methods = oldnative.NATIVE_GROUPS['original']['methods']
new_methods = native.NATIVE_GROUPS['original']['methods']
assert len(old_methods) == 17 and new_methods[:17] == old_methods and len(new_methods) == len(set(new_methods)) == 19
assert oldnative.NATIVE_GROUPS['mainjs'] == native.NATIVE_GROUPS['mainjs']
for name, expected in [('EXPECTED', 10), ('CURRENTCORE_EXPECTED', 16), ('PUBLICBATCH_EXPECTED', 17), ('EFFECTS_EXPECTED', 18)]:
    assert getattr(oldpackage, name) == getattr(package, name) and len(getattr(package, name)) == expected
assert len(package.LOGINUI_EXPECTED) == 22 and package.EFFECTS_EXPECTED <= package.LOGINUI_EXPECTED
for name in ('PACKAGE_INPUTS', 'CONTROL_INPUTS', 'SOURCE_INPUTS'):
    assert getattr(oldpackage, name) == getattr(package, name)
assert len(package.PACKAGE_INPUTS) == 15 and len(package.CONTROL_INPUTS) == 7
assert set(core.SOURCE_INPUTS) == {row['path'] for row in closures['core']['sources']}
assert set(native.SOURCE_INPUTS) == {row['path'] for row in closures['native']['sources']}
assert set(package.SOURCE_INPUTS) == {row['path'] for row in closures['package']['sources']}

def functions(raw):
    return {n.name: ast.dump(n, include_attributes=False) for n in ast.parse(raw).body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))}

assert functions((STAGE / 'rawbaseline/scripts/reader-experience/native-smoke-tools.py').read_bytes()) == functions(candidates['scripts/reader-experience/native-smoke-tools.py'])
manifest = read(ROOT / 'Packages/LegadoRuntime/vendor/original-rule/manifest.json')
for row in manifest['portedSources']:
    verify(ROOT / row['path'], row)
assert len(manifest['portedSources']) == 55
for validation in m['actualPortableValidation']:
    verify(ROOT / validation['record']['path'], validation['record'])
    verify(ROOT / validation['log']['path'], validation['log'])
assert [v['actualTestsRun'] for v in m['actualPortableValidation']] == [11, 8, 7]
for prior in m['preservedAttemptHistory']:
    verify(ROOT / prior['record']['path'], prior['record'])
    if 'log' in prior:
        verify(ROOT / prior['log']['path'], prior['log'])
assert m['selection']['PackageMustExecuteFresh'] is True and m['selection']['PackageHistoricalReusePermitted'] is False
assert m['selection']['coldInvocationSeconds'] == 3600 and m['selection']['invocations'] == m['selection']['xcresultBundles'] == 1
record = {
    'schemaVersion': 1,
    'reviewedCanonicalCommit': head,
    'preparation': fact(manifest_path),
    'reviewedCandidateFiles': 9,
    'composedProductionInputsVerified': 29,
    'uniqueBoundInputsVerified': len(unique),
    'noncandidateBoundInputsEqualCurrentGitWorktree': 324,
    'sourceClosureCounts': {'core': 322, 'native': 113, 'package': 22},
    'oldCoreModesUnchanged': True,
    'threeBoolArgumentPairsUnchanged': True,
    'oldNative17OrderAndSeparateMainjsGroupUnchanged': True,
    'nativeProductionFunctionsASTUnchanged': True,
    'oldPackage10Default16Publicbatch17Effects18Unchanged': True,
    'newRequiredPackageSelection': 'loginui22; fresh actual execution mandatory',
    'requiredSameJobSDKFixtureAndTenPhaseIdentityUnchanged': True,
    'originalPortedSourceFactsVerified': 55,
    'authorAffectedPortableResultsVerified': [11, 8, 7],
    'priorActualPortableFailuresPreserved': True,
    'actualSDKJNIOrSwiftPMExecutionsInThisReview': 0,
    'limits': ['Static byte, identity and invariant review does not execute Apple SDK, JNI or SwiftPM.', 'Current210fb05 live workflows bind an older immutable source; no result is transferred to this candidate.', 'Later true-delta control reuse stays outside this checkpoint.'],
    'mutations': {'canonical': False, 'Git': False, 'cloud': False, 'tags': False},
}
out = STAGE / 'preparation/root-review.json'
assert not out.exists()
out.write_bytes((json.dumps(record, ensure_ascii=False, indent=2) + '\n').encode())
print(json.dumps(record, ensure_ascii=False))
