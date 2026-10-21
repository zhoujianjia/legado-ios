from pathlib import Path
import ast
import datetime
import difflib
import hashlib
import importlib.util
import json
import re

ROOT = Path('F:/yuedu-reader')
STAGE = Path(__file__).resolve().parent
BASE = STAGE / 'rawbaseline'
WORK = STAGE / 'work'
P = STAGE / 'preparation'

def load(path):
    return json.loads(path.read_text('utf-8'))

def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')

def fact(path):
    data = path.read_bytes()
    return {'path': path.relative_to(ROOT).as_posix(), 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}

def module(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

def replace_once(text, old, new):
    assert text.count(old) == 1, old
    return text.replace(old, new, 1)

parents = [
    '.build/original-general-webjs-base64-union-step/final-v1.json',
    '.build/original-general-webjs-coherent-swift-step/final-v1.json',
    'docs/legado-ios/core-sdk-fc3-runtime-repairs-step.json',
    'docs/legado-ios/core-original-cookie-response-repair-step.json',
]
roster = []
for relative in parents:
    manifest = load(ROOT / relative)
    roster.extend(row['path'] for row in manifest.get('files', manifest.get('sourceFiles', [])))
roster = list(dict.fromkeys(roster))
assert len(roster) == 30
core_path = 'scripts/reader-experience/renewal-probe-tools.py'
native_path = 'scripts/reader-experience/native-smoke-tools.py'
core_test = 'scripts/reader-experience/test-renewal-probe-tools.py'
native_test = 'scripts/reader-experience/test-native-smoke-tools.py'
workflow = '.github/workflows/legado-native-reader-test.yml'
controls = [workflow, native_path, core_path, native_test, core_test]
for relative in controls:
    assert (BASE / relative).read_bytes() == (ROOT / relative).read_bytes(), relative

core = module('general_controls_old_core', core_path)
native = module('general_controls_old_native', native_path)
new_core = [path for path in roster if path not in core.SOURCE_INPUTS]
new_native = [path for path in roster if path not in native.SOURCE_INPUTS]
core_count = len(set(core.SOURCE_INPUTS) | set(roster))
native_count = len(set(native.SOURCE_INPUTS) | set(roster))
union_count = len(set(core.SOURCE_INPUTS) | set(native.SOURCE_INPUTS) | set(roster))
selector = 'LegadoNativeOriginalReaderTests/testNativeOriginalGeneralWebJSUsesPreviewBatchAndBookCallbackOwners'
assert selector not in native.NATIVE_GROUPS['original']['methods']
original_count = len(native.NATIVE_GROUPS['original']['methods']) + 1

def group(name):
    return name + ' = (\n' + ''.join('    ' + repr(path) + ',\n' for path in roster) + ')\n'

text = (BASE / core_path).read_text('utf-8')
anchor = 'assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 343'
text = replace_once(text, anchor, anchor + '\n\n' + group('CURRENTCORE_GENERAL_WEBJS_RUNTIME_REPAIR_INPUTS') +
    'SOURCE_INPUTS += tuple(path for path in CURRENTCORE_GENERAL_WEBJS_RUNTIME_REPAIR_INPUTS if path not in SOURCE_INPUTS)\n' +
    f'assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == {core_count}')
new_texts = {core_path: text}
text = (BASE / native_path).read_text('utf-8')
anchor = "            'LegadoNativeOriginalLoginInfoTests/testNativeOriginalLocalHTMLWebJSKeepsSameSessionAfterProducerAndDrainsAwaitCancellation')},"
text = replace_once(text, anchor, anchor[:-3] + ',\n            ' + repr(selector) + ')},')
anchor = 'assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 148'
text = replace_once(text, anchor, anchor + '\n\n' + group('ORIGINAL_GENERAL_WEBJS_RUNTIME_REPAIR_INPUTS') +
    'SOURCE_INPUTS += tuple(path for path in ORIGINAL_GENERAL_WEBJS_RUNTIME_REPAIR_INPUTS if path not in SOURCE_INPUTS)\n' +
    f'assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == {native_count}')
new_texts[native_path] = text
old_label = 'Execute1 MainJS and27 original methods in separate required hosts'
new_label = f'Execute1 MainJS and{original_count} original methods in separate required hosts'
new_texts[workflow] = replace_once((BASE / workflow).read_text('utf-8'), old_label, new_label)

text = (BASE / core_test).read_text('utf-8')
text = re.sub(r'\b343\b', str(core_count), text)
anchor = "        self.assertTrue(set(probe.CURRENTCORE_SPD_WEBJS_COLD_INPUTS) <= set(probe.SOURCE_INPUTS))"
addition = "\n        self.assertEqual(len(probe.CURRENTCORE_GENERAL_WEBJS_RUNTIME_REPAIR_INPUTS), 30)\n        self.assertTrue(set(probe.CURRENTCORE_GENERAL_WEBJS_RUNTIME_REPAIR_INPUTS) <= set(probe.SOURCE_INPUTS))\n"
for path in new_core:
    addition += '        self.assertIn(' + repr(path) + ', probe.CURRENTCORE_GENERAL_WEBJS_RUNTIME_REPAIR_INPUTS)\n'
text = replace_once(text, anchor, anchor + addition.rstrip('\n'))
anchor = '*probe.CURRENTCORE_SPD_WEBJS_COLD_INPUTS)):'
text = replace_once(text, anchor, '*probe.CURRENTCORE_SPD_WEBJS_COLD_INPUTS, *probe.CURRENTCORE_GENERAL_WEBJS_RUNTIME_REPAIR_INPUTS)):')
new_texts[core_test] = text

text = (BASE / native_test).read_text('utf-8')
text = replace_once(text, 'result["originalReaderTests"]["expectedTests"], 27', f'result["originalReaderTests"]["expectedTests"], {original_count}')
text = replace_once(text, 'self.assertEqual(len(native.SOURCE_INPUTS), 148)', f'self.assertEqual(len(native.SOURCE_INPUTS), {native_count})')
text = replace_once(text, old_label, new_label)
text = replace_once(text, 'len(native.NATIVE_GROUPS["original"]["methods"]), 27', f'len(native.NATIVE_GROUPS["original"]["methods"]), {original_count}')
anchor = '        self.assertTrue(set(native.ORIGINAL_SPD_WEBJS_COLD_INPUTS) <= set(native.SOURCE_INPUTS))'
text = replace_once(text, anchor, anchor + '\n        self.assertEqual(len(native.ORIGINAL_GENERAL_WEBJS_RUNTIME_REPAIR_INPUTS), 30)\n        self.assertTrue(set(native.ORIGINAL_GENERAL_WEBJS_RUNTIME_REPAIR_INPUTS) <= set(native.SOURCE_INPUTS))\n        self.assertIn(' + repr(selector) + ', native.NATIVE_GROUPS["original"]["methods"])')
new_texts[native_test] = text

rows = []
for relative, text in new_texts.items():
    path = WORK / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(text.encode('utf-8'))
    if path.suffix == '.py':
        ast.parse(text)
    before = (BASE / relative).read_text('utf-8')
    diff = STAGE / 'diffs' / (relative + '.diff')
    diff.parent.mkdir(parents=True, exist_ok=True)
    diff.write_text(''.join(difflib.unified_diff(before.splitlines(True), text.splitlines(True), fromfile='a/' + relative, tofile='b/' + relative)), encoding='utf-8')
    rows.append({'path': relative, 'baseline': fact(BASE / relative), 'candidate': fact(path), 'diff': fact(diff)})
save(P / 'controls-draft-v1.json', {
    'status': 'Actual control candidate prepared. Waiting the known blank-regex production successor before source stamp and the single four-method portable run.',
    'preparedUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'files': rows, 'sourceParents': [fact(ROOT / x) for x in parents], 'productionRoster': roster,
    'newBoundCorePaths': new_core, 'newBoundNativePaths': new_native,
    'counts': {'core': core_count, 'native': native_count, 'uniqueUnion': union_count, 'AppDefinitions': 463, 'AppExecutions': 466, 'BoolPairs': 3, 'ordinaryOriginalNative': original_count, 'MainJS': 1, 'independentColdHosts': 2, 'PackageMethods': 24, 'PackageInputs': 23},
    'newSelector': selector, 'testsRun': 0,
})
print(json.dumps({'manifest': fact(P / 'controls-draft-v1.json'), 'counts': {'core': core_count, 'native': native_count, 'union': union_count, 'original': original_count}}))
