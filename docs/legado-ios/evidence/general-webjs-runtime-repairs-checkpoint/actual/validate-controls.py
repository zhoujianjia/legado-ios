from pathlib import Path
import ast
import datetime
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
import time

sys.dont_write_bytecode = True
ROOT = Path('F:/yuedu-reader')
STAGE = Path(__file__).resolve().parent
V = STAGE / 'validation-root'
assert not V.exists(), 'Preserve prior validation; use a successor directory if changed.'

def load(path):
    return json.loads(path.read_text('utf-8'))

def rf(data):
    return {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}

def fact(path):
    return {'path': path.relative_to(ROOT).as_posix(), **rf(path.read_bytes())}

def save(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')

def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)

def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value

draft = load(STAGE / 'preparation/controls-draft-v1.json')
controls = [row['path'] for row in draft['files']]
roster = draft['productionRoster']
blank_path = ROOT / '.build/original-general-webjs-blank-regex-step/final-v1.json'
blank_fact = fact(blank_path)
assert {k: blank_fact[k] for k in ('bytes', 'sha256')} == {
    'bytes': 10457, 'sha256': '7e725827274861758270ca4a8f64908df3b1d968482e9e594b6f98f8a47ee9ba'}
blank = load(blank_path)
overlay = {}
for row in blank['files']:
    relative = row['path']
    value = (ROOT / blank['candidateRoot'] / relative).read_bytes()
    assert rf(value) == row['candidate']
    assert rf((ROOT / relative).read_bytes()) in (row['baseline'], row['candidate']), relative
    assert relative in roster
    overlay[relative] = value
assert len(overlay) == 3

cp = 'scripts/reader-experience/renewal-probe-tools.py'
np = 'scripts/reader-experience/native-smoke-tools.py'
pp = 'scripts/reader-experience/original-api-package-tools.py'
coldp = 'scripts/reader-experience/original-cold-process-tools.py'
oldc = module('genrepair_oldcore', ROOT / cp)
oldn = module('genrepair_oldnative', ROOT / np)
oldp = module('genrepair_oldpackage', ROOT / pp)
oldcold = module('genrepair_oldcold', ROOT / coldp)
allpaths = list(dict.fromkeys((*oldc.SOURCE_INPUTS, *oldn.SOURCE_INPUTS,
    *oldp.SOURCE_INPUTS, *roster, *controls,
    'scripts/legado-ios/verify-native-reuse.py', 'scripts/legado-ios/verify-runtime-reuse.py')))
for relative in allpaths:
    data = (STAGE / 'work' / relative).read_bytes() if relative in controls else overlay.get(relative, (ROOT / relative).read_bytes())
    write(V / relative, data)

newc = module('genrepair_newcore', V / cp)
newn = module('genrepair_newnative', V / np)
newp = module('genrepair_newpackage', V / pp)
newcold = module('genrepair_newcold', V / coldp)
assert set(newc.SOURCE_INPUTS) == set(oldc.SOURCE_INPUTS) | set(roster)
assert set(newn.SOURCE_INPUTS) == set(oldn.SOURCE_INPUTS) | set(roster)
assert len(newc.SOURCE_INPUTS) == len(set(newc.SOURCE_INPUTS)) == 346
assert len(newn.SOURCE_INPUTS) == len(set(newn.SOURCE_INPUTS)) == 158
assert newc.EXPECTED_CASES == oldc.EXPECTED_CASES
assert newc.PARAMETER_CASES == oldc.PARAMETER_CASES
assert newc.parameter_cases('currentcore') == oldc.parameter_cases('currentcore')
assert len(newc.parameter_cases('currentcore')) == 3
assert len(newc.EXPECTED_CASES['currentcore']) == 463 and newc.expected_leaf_count('currentcore') == 466
assert newc.CURRENTCORE_PHASES == oldc.CURRENTCORE_PHASES and newc.CURRENTCORE_TIMEOUTS == oldc.CURRENTCORE_TIMEOUTS
assert newn.NATIVE_GROUPS['original']['methods'] == (*oldn.NATIVE_GROUPS['original']['methods'], draft['newSelector'])
assert len(newn.NATIVE_GROUPS['original']['methods']) == 28 and newn.NATIVE_GROUPS['original']['seconds'] == 1800
assert newn.NATIVE_GROUPS['mainjs'] == oldn.NATIVE_GROUPS['mainjs']
assert newcold.METHODS == oldcold.METHODS and len(newcold.METHODS) == 2
assert set(newcold.METHODS.values()).isdisjoint(newn.NATIVE_GROUPS['original']['methods'])
assert newp.SOURCE_INPUTS == oldp.SOURCE_INPUTS and len(newp.SOURCE_INPUTS) == 23
assert newp.PACKAGE_INPUTS == oldp.PACKAGE_INPUTS and len(newp.PACKAGE_INPUTS) == 16
assert newp.LOGINV2_EXPECTED == oldp.LOGINV2_EXPECTED and len(newp.LOGINV2_EXPECTED) == 24
for relative in newp.SOURCE_INPUTS:
    assert (V / relative).read_bytes() == (ROOT / relative).read_bytes()

def functions(path):
    return {x.name: ast.dump(x, include_attributes=False) for x in ast.parse(path.read_text('utf-8')).body
            if isinstance(x, (ast.FunctionDef, ast.AsyncFunctionDef))}

ast_facts = {}
for relative in (cp, np):
    old = functions(STAGE / 'rawbaseline' / relative)
    new = functions(STAGE / 'work' / relative)
    assert old == new, relative
    ast_facts[relative] = {'functions': len(old), 'allFunctionASTsUnchanged': True}
for relative in controls:
    if relative.endswith('.py'):
        ast.parse((STAGE / 'work' / relative).read_bytes())
wf = '.github/workflows/legado-native-reader-test.yml'
assert (STAGE / 'work' / wf).read_text('utf-8').replace('Execute1 MainJS and28 original methods in separate required hosts',
    'Execute1 MainJS and27 original methods in separate required hosts') == (STAGE / 'rawbaseline' / wf).read_text('utf-8')

commands = []

def run(name, argv, expected_methods):
    started = time.monotonic()
    result = subprocess.run(argv, cwd=V, capture_output=True, timeout=60,
        env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1', 'LEGADO_RUNTIME_SOURCE_ONLY': '1', 'YUEDU_RENEWAL_SELECTION': 'currentcore'})
    log = STAGE / (name + '.log')
    log.write_bytes(result.stdout + result.stderr)
    actual = len(re.findall(rb'^test_[^\r\n]+ \.\.\. (?:ok|FAIL|ERROR)', result.stdout + result.stderr, re.MULTILINE))
    commands.append({'argv': argv, 'cwd': V.relative_to(ROOT).as_posix(), 'methods': expected_methods,
        'observedMethods': actual, 'exitCode': result.returncode, 'seconds': round(time.monotonic() - started, 3), 'log': fact(log)})
    save(STAGE / 'actual-portable-commands-v1.json', commands)
    assert result.returncode == 0 and actual == expected_methods, (name, (result.stdout + result.stderr).decode('utf-8', errors='replace')[-6000:])

py = 'C:/Python312/python.exe'
run('affected-core-v1', [py, '-B', 'scripts/reader-experience/test-renewal-probe-tools.py', 'DeltaReuseCheckpointSelectionTests', '-v'], 2)
run('affected-native-v1', [py, '-B', 'scripts/reader-experience/test-native-smoke-tools.py',
    'NativeSmokeProvenanceTests.test_workflow_keeps_native_groups_in_separate_required_hosts_after_real_staging',
    'NativeSmokeProvenanceTests.test_result_requires_exact_built_app_source_stamp', '-v'], 2)

rosters = {}
union = {}
for name, paths in [('core', newc.SOURCE_INPUTS), ('Native', newn.SOURCE_INPUTS), ('Package', newp.SOURCE_INPUTS)]:
    rows = [{'path': relative, **rf((V / relative).read_bytes())} for relative in paths]
    union.update({row['path']: row for row in rows})
    out = STAGE / (name + '-source-inputs-v1.json')
    save(out, rows)
    rosters[name] = fact(out)
assert len(union) == 362
save(STAGE / 'union-source-inputs-v1.json', list(union.values()))
for relative in roster:
    write(STAGE / 'source-snapshot' / relative, (V / relative).read_bytes())
save(STAGE / 'production-source-bindings-v1.json', [{'path': relative, **rf((V / relative).read_bytes())} for relative in roster])
save(STAGE / 'production-function-ast-facts-v1.json', ast_facts)
facts = {'schemaVersion': 1, 'validatedUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'status': 'Four actual affected portable methods passed on the 30-source final composition with blank-regex successor; canonical final source equality remains to be bound at freeze.',
    'sourceParents': draft['sourceParents'], 'blankRegexSuccessor': blank_fact, 'counts': draft['counts'],
    'sourceRosters': rosters, 'productionRoster': fact(STAGE / 'production-source-bindings-v1.json'),
    'unionRoster': fact(STAGE / 'union-source-inputs-v1.json'), 'functionASTs': fact(STAGE / 'production-function-ast-facts-v1.json'),
    'actualPortableGuards': {'distinctMethods': 4, 'executions': 4, 'passed': 4, 'failed': 0, 'commands': commands,
        'oldUnrelatedSuitesRepeated': False, 'SwiftSDK': 0, 'JNI': 0, 'WK': 0, 'JVM': 0},
    'invariants': {'allOldModesAndThreeBoolPairsUnchanged': True, 'allCoreAndNativeFunctionsASTUnchanged': True,
        'old27NativeOrderedSelectorsPreserved': True, 'oneNewNativeMethod': draft['newSelector'],
        'requiredSameJobSignedSDKFixture': True, 'oneCurrentcoreInvocation': True, 'currentcoreWrapperSeconds': 3600,
        'currentcoreParentSeconds': 3720, 'originalNativeSeconds': 1800, 'mainjsNativeSeconds': 2700,
        'independentColdTwoHostProtocolUnchanged': True, 'phaseArgvSourceRawExitExportGatesUnchanged': True,
        'Package24MethodsAnd23InputsUnchanged': True}}
save(STAGE / 'validation-facts-v1.json', facts)
print(json.dumps({'manifest': fact(STAGE / 'validation-facts-v1.json'), 'counts': draft['counts'], 'passed': 4}))
