from pathlib import Path
import difflib
import hashlib
import importlib.util
import json
import re

R = Path(__file__).resolve().parents[2]
S = Path(__file__).resolve().parent
CONFIG = json.loads((S / 'preparation/draft-case-config-v1.json').read_bytes())
CONTRACT = json.loads((S / 'preparation/baseline-contract-v1.json').read_bytes())
CONTROLS = CONTRACT['controlPaths']
NEW = {suite: tuple(methods) for suite, methods in CONFIG['newCases'].items()}
NEW_PATHS = CONFIG['caseSourcePaths']
ADDED = {suite + '/' + name for suite, names in NEW.items() for name in names}
DEFINITIONS = CONTRACT['counts']['definitions'] + len(ADDED)
LEAVES = CONTRACT['counts']['leaves'] + len(ADDED)


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def fact(path):
    raw = path.read_bytes()
    return {'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}


def replace_one(text, old, new):
    assert text.count(old) == 1, (old, text.count(old))
    return text.replace(old, new)


def update(path, operation):
    old = (S / 'rawbaseline' / path).read_text(encoding='utf-8')
    new = operation(old)
    (S / 'work' / path).write_bytes(new.encode())


for path in CONTROLS:
    assert (R / path).read_bytes() == (S / 'rawbaseline' / path).read_bytes(), path
base_core = load('readiness_original_core', R / CONTROLS[0])
base_native = load('readiness_original_native', R / CONTROLS[2])
assert len(ADDED) == sum(map(len, NEW.values()))
assert not (ADDED & base_core.EXPECTED_CASES['currentcore'])
assert all(path in base_core.SOURCE_INPUTS for path in NEW_PATHS.values())
native_extra = tuple(path for path in NEW_PATHS.values() if path not in base_native.SOURCE_INPUTS)
native_count = len(base_native.SOURCE_INPUTS) + len(native_extra)


def core_change(text):
    anchor = 'PARAMETER_MODES = ("transactionrenewal", "handoffrenewal", "currentcore")'
    block = '# Later observed-installation and resumed-ready tests extend currentcore only.\n'
    block += 'CURRENTCORE_S5_READINESS_CASES = ' + repr(NEW) + '\n'
    block += 'CURRENTCORE_S5_READINESS_SOURCE_PATHS = ' + repr(NEW_PATHS) + '\n'
    block += 'CURRENTCORE_S5_READINESS_QUALIFIED_CASES = {suite + "/" + method\n'
    block += '    for suite, methods in CURRENTCORE_S5_READINESS_CASES.items() for method in methods}\n'
    block += 'assert len(CURRENTCORE_S5_READINESS_QUALIFIED_CASES) == ' + str(len(ADDED)) + '\n'
    block += 'assert not (EXPECTED_CASES["currentcore"] & CURRENTCORE_S5_READINESS_QUALIFIED_CASES)\n'
    block += 'EXPECTED_CASES["currentcore"] |= CURRENTCORE_S5_READINESS_QUALIFIED_CASES\n'
    block += 'assert len(EXPECTED_CASES["currentcore"]) == ' + str(DEFINITIONS) + '\n\n'
    text = replace_one(text, anchor, block + anchor)
    # Keep the historical 475-boundary assertion before the new group. Only
    # active phase/result contracts below it receive the new current count.
    for old, new in [
        ('prepared.get("intendedQualifiedMethodDefinitions") != 475',
         'prepared.get("intendedQualifiedMethodDefinitions") != ' + str(DEFINITIONS)),
        ('prepared.get("intendedArgumentLeafCount") != 478',
         'prepared.get("intendedArgumentLeafCount") != ' + str(LEAVES)),
        ('"qualifiedMethodDefinitions": 475, "argumentLeaves": 478',
         '"qualifiedMethodDefinitions": ' + str(DEFINITIONS) + ', "argumentLeaves": ' + str(LEAVES)),
        ('ledger.get("qualifiedMethodDefinitions") != 475',
         'ledger.get("qualifiedMethodDefinitions") != ' + str(DEFINITIONS)),
        ('ledger.get("argumentLeaves") != 478',
         'ledger.get("argumentLeaves") != ' + str(LEAVES)),
    ]:
        text = replace_one(text, old, new)
    return text


update(CONTROLS[0], core_change)


def guard_change(text):
    # These exact integers are currentcore expectations; all older group
    # counts stay unchanged. Word boundaries leave artifact action SHA intact.
    text = re.sub(r'\b475\b', str(DEFINITIONS), text)
    text = re.sub(r'\b478\b', str(LEAVES), text)
    text = text.replace('Execute475 current-core definitions with478 exact native argument leaves',
                        f'Execute{DEFINITIONS} current-core definitions with{LEAVES} exact native argument leaves')
    text = text.replace('475 definitions,478 argument leaves', f'{DEFINITIONS} definitions,{LEAVES} argument leaves')
    # Actual old owners may now declare current-only methods. Keep strict
    # whole-suite inventories; no old mode gets the added methods.
    text = text.replace('set(probe.CURRENTCORE_FIRST_REGISTRATION_CASES.get(suite, ()))',
                        '(set(probe.CURRENTCORE_FIRST_REGISTRATION_CASES.get(suite, ())) | set(probe.CURRENTCORE_S5_READINESS_CASES.get(suite, ())))')
    text = replace_one(text,
        '|probe.CURRENTCORE_CERTIFICATE_PREUPDATE_QUALIFIED_CASES|probe.CURRENTCORE_FIRST_REGISTRATION_QUALIFIED_CASES)\n',
        '|probe.CURRENTCORE_CERTIFICATE_PREUPDATE_QUALIFIED_CASES|probe.CURRENTCORE_FIRST_REGISTRATION_QUALIFIED_CASES|probe.CURRENTCORE_S5_READINESS_QUALIFIED_CASES)\n')
    text = replace_one(text,
        "set(probe.CURRENTCORE_EXPLORE_LIFECYCLE_CASES.get(suite, ())) | set(probe.CURRENTCORE_FOREGROUND_LIFECYCLE_CASES.get(suite, ())), suite)",
        "set(probe.CURRENTCORE_EXPLORE_LIFECYCLE_CASES.get(suite, ())) | set(probe.CURRENTCORE_FOREGROUND_LIFECYCLE_CASES.get(suite, ())) | set(probe.CURRENTCORE_S5_READINESS_CASES.get(suite, ())), suite)")
    anchor = "        self.assertEqual(len(probe.CURRENTCORE_FIRST_REGISTRATION_QUALIFIED_CASES), 4)\n"
    assert text.count(anchor) == 1
    proof = '''        readiness = probe.CURRENTCORE_S5_READINESS_QUALIFIED_CASES
        self.assertEqual(len(readiness), READINESS_COUNT)
        self.assertTrue(readiness <= probe.EXPECTED_CASES['currentcore'])
        for suite, methods in probe.CURRENTCORE_S5_READINESS_CASES.items():
            relative = probe.CURRENTCORE_S5_READINESS_SOURCE_PATHS[suite]
            self.assertIn(relative, probe.SOURCE_INPUTS)
            text = (HERE.parents[1] / relative).read_text(encoding='utf8')
            self.assertRegex(text, r'(?:struct|extension) ' + re.escape(suite) + r'\\s*\\{')
            for method in methods:
                self.assertEqual(len(re.findall(r'(?m)^\\s*@Test[^\\n]*\\n(?:\\s*@[^\\n]*\\n)*\\s*func\\s+' + re.escape(method) + r'\\s*\\(\\)', text)), 1)
                self.assertEqual(probe.currentcore_test_selector(suite + '/' + method), suite + '/' + method + '()')
            for group, selected in probe.EXPECTED_CASES.items():
                if group != 'currentcore': self.assertTrue(readiness.isdisjoint(selected), group)
'''.replace('READINESS_COUNT', str(len(ADDED)))
    return replace_one(text, anchor, proof + anchor)


update(CONTROLS[1], guard_change)


def native_change(text):
    if not native_extra:
        return text
    anchor = '\n\ndef source_inputs():'
    block = '\n\nNATIVE_S5_RETIREMENT_COMPILE_INPUTS = ' + repr(native_extra) + '\n'
    block += 'SOURCE_INPUTS += tuple(path for path in NATIVE_S5_RETIREMENT_COMPILE_INPUTS if path not in SOURCE_INPUTS)\n'
    block += 'assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == ' + str(native_count) + '\n'
    return replace_one(text, anchor, block + anchor)


update(CONTROLS[2], native_change)


def native_guard_change(text):
    if not native_extra:
        return text
    text = replace_one(text, 'self.assertEqual(len(native.SOURCE_INPUTS), 262)',
                       'self.assertEqual(len(native.SOURCE_INPUTS), ' + str(native_count) + ')')
    anchor = '        self.assertTrue(set(native.ORIGINAL_FIRST_REGISTRATION_FULL_APPLICATION_INPUTS) <= set(native.SOURCE_INPUTS))\n'
    return replace_one(text, anchor, anchor + '        self.assertTrue(set(native.NATIVE_S5_RETIREMENT_COMPILE_INPUTS) <= set(native.SOURCE_INPUTS))\n')


update(CONTROLS[3], native_guard_change)


def workflow_change(text):
    text = replace_one(text, 'Execute475 current-core definitions with478 exact native argument leaves',
                       f'Execute{DEFINITIONS} current-core definitions with{LEAVES} exact native argument leaves')
    text = replace_one(text, 'requires475 unique qualified native definitions and478 exact execution leaves',
                       f'requires{DEFINITIONS} unique qualified native definitions and{LEAVES} exact execution leaves')
    text = replace_one(text, 'outside native478', 'outside native' + str(LEAVES))
    anchor = 'The independent cold-process pair remains separate, and the unactivated resource sniffer remains excluded.'
    return replace_one(text, anchor,
        'Four resumed-ready and observed-installation regression definitions extend currentcore only. ' + anchor)


update(CONTROLS[4], workflow_change)
update(CONTROLS[6], lambda text: replace_one(text, '475 definitions,478 argument leaves',
                                            f'{DEFINITIONS} definitions,{LEAVES} argument leaves'))
# Native workflow is unchanged: no new Native/MainJS/cold/S3 selector.

VR = S / 'validation-root'
overlays = CONFIG.get('sourceOverlays', {})
for path in sorted(set(base_core.SOURCE_INPUTS) | set(base_native.SOURCE_INPUTS) | set(native_extra)):
    source = S / 'work' / path if path in CONTROLS else R / overlays.get(path, path)
    target = VR / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(source.read_bytes())
# Existing packaging imports these helpers. They are auxiliary validation
# dependencies, not additions to the declared compilation/source inventories.
for path in ('scripts/legado-ios/verify-native-reuse.py', 'scripts/legado-ios/verify-runtime-reuse.py'):
    target = VR / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes((R / path).read_bytes())
candidate_core = load('readiness_candidate_core', VR / CONTROLS[0])
candidate_native = load('readiness_candidate_native', VR / CONTROLS[2])
assert len(candidate_core.EXPECTED_CASES['currentcore']) == DEFINITIONS
assert candidate_core.expected_leaf_count('currentcore') == LEAVES
assert candidate_core.EXPECTED_CASES['currentcore'] - base_core.EXPECTED_CASES['currentcore'] == ADDED
for group in base_core.EXPECTED_CASES:
    if group != 'currentcore':
        assert candidate_core.EXPECTED_CASES[group] == base_core.EXPECTED_CASES[group]
assert candidate_core.PARAMETER_CASES == base_core.PARAMETER_CASES
assert candidate_core.CURRENTCORE_GLYPH_PARAMETER_CASES == base_core.CURRENTCORE_GLYPH_PARAMETER_CASES
assert candidate_native.NATIVE_GROUPS == base_native.NATIVE_GROUPS
assert tuple(candidate_native.SOURCE_INPUTS[:len(base_native.SOURCE_INPUTS)]) == tuple(base_native.SOURCE_INPUTS)
assert tuple(candidate_native.SOURCE_INPUTS[len(base_native.SOURCE_INPUTS):]) == native_extra

rows = []
for path in CONTROLS:
    before = (S / 'rawbaseline' / path).read_bytes()
    after = (S / 'work' / path).read_bytes()
    output = S / 'diffs' / (path + '.diff')
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(''.join(difflib.unified_diff(before.decode().splitlines(keepends=True),
        after.decode().splitlines(keepends=True), fromfile='a/' + path, tofile='b/' + path)).encode())
    rows.append({'path': path, 'baseline': fact(S / 'rawbaseline' / path),
                 'candidate': fact(S / 'work' / path), 'changed': before != after,
                 'diff': fact(output)})

counts = {'core': len(candidate_core.SOURCE_INPUTS), 'native': len(candidate_native.SOURCE_INPUTS),
    'union': len(set(candidate_core.SOURCE_INPUTS) | set(candidate_native.SOURCE_INPUTS)),
    'currentcoreDefinitions': DEFINITIONS, 'currentcoreLeaves': LEAVES,
    'originalMethods': len(candidate_native.NATIVE_GROUPS['original']['methods']),
    'MainJS': 1, 'coldIndependent': 2, 'S3Definitions': 1, 'S3Leaves': 1,
    'PackageDefinitions': 24, 'PackageInputs': 23, 'boolPairs': 3}
draft = {'status': 'candidate-controls-not-final-source-bound', 'files': rows,
    'counts': counts, 'addedSelectors': sorted(ADDED), 'nativeAddedCompileInputs': native_extra,
    'pending': CONFIG['pending'], 'actualTestExecutions': 0,
    'scope': 'Source construction and literal invariant checks only. No SDK, tests, parser, Git mutation or cloud execution.'}
(S / 'preparation/draft-controls-v1.json').write_bytes((json.dumps(draft, indent=2) + '\n').encode())
print(json.dumps(counts))
