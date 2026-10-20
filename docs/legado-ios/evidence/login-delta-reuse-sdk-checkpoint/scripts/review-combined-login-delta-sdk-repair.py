from pathlib import Path
import hashlib
import json
import subprocess
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path('F:/yuedu-reader')
PROD = ROOT / '.build/original-source-login-delta-reuse-step'
HARNESS = ROOT / '.build/consolidated-sdk-login-delta-reuse-checkpoint'
GIT = 'D:/app/Git/cmd/git.exe'


def read(p): return json.loads(p.read_bytes())
def fact(p):
    raw = p.read_bytes()
    return {'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
def check(p, row): assert fact(p) == {k: row[k] for k in ['bytes', 'sha256']}, str(p)


assert not subprocess.check_output([GIT, 'status', '--porcelain'], cwd=ROOT)
head = subprocess.check_output([GIT, 'rev-parse', 'HEAD'], cwd=ROOT).decode().strip()
assert head == 'bfe619e0ff7e48251ec1970604d7457263f7c6e1'
manifest_path = PROD / 'final-v1.json'; harness_path = HARNESS / 'preparation/final-v1.json'
assert fact(manifest_path) == {'bytes': 23939, 'sha256': '8166369634a9e4b4b71330174ac60a915bb8843c18f502b7718a17e451f72a77'}
assert fact(harness_path) == {'bytes': 17907, 'sha256': 'c0d8638aef739dfc34d5f42aaf7984041e2ec83e0ccf062d62e1938e6307c672'}
prod, harness = read(manifest_path), read(harness_path)
review_path = ROOT / '.build/original-source-login-delta-reuse-independent-review/review.json'
assert fact(review_path) == {'bytes': 36006, 'sha256': '0ccfd5d7709a4c3e6e6e7a938f301ab65bec16a77a06ddf092c38bc5a2750d71'}
assert read(review_path)['findings'] == []
candidates = {}
for stage, rows, expected in [(PROD, prod['files'], 19), (HARNESS, harness['files'], 9)]:
    assert len(rows) == len({r['path'] for r in rows}) == expected
    for row in rows:
        path = row['path']
        if row['baseline'] is None: assert not (ROOT / path).exists(), path
        else: check(ROOT / path, row['baseline'])
        check(stage / 'work' / path, row['candidate'])
        diff = Path(row['diff']['path'])
        check((ROOT / diff) if str(diff).startswith('.build') else (stage / diff), row['diff'])
        assert path not in candidates
        candidates[path] = (stage / 'work' / path).read_bytes()
assert len(candidates) == 28
for row in prod['unchangedInheritedInputs']: check(ROOT / row['path'], row)
for row in prod['references']: check(ROOT / row['path'], row)
for row in prod['evidence']: check(PROD / row['path'], row)
for key in ['wholeProductionManifest', 'wholeProductionIndependentReview', 'rootTypedRegressionManifest', 'rootActualSDKRepairManifest', 'actualSDKTerminalIndependentReview', 'sourceBindingEvidence', 'sourceClosureEvidence', 'invariantEvidence', 'syntax']:
    check(ROOT / harness[key]['path'], harness[key])
closures = read(ROOT / harness['sourceClosureEvidence']['path'])
bound = {}
for kind, count in [('core', 324), ('native', 115), ('package', 22)]:
    rows = closures[kind]['sources']
    assert closures[kind]['count'] == len(rows) == len({r['path'] for r in rows}) == count
    for row in rows:
        path = row['path']; raw = candidates[path] if path in candidates else (ROOT / path).read_bytes()
        assert len(raw) == row['bytes'] and hashlib.sha256(raw).hexdigest() == row['sha256'], path
        assert path not in bound or bound[path] == row
        bound[path] = row
assert len(bound) == 335 and sum(path not in candidates for path in bound) == 307
ported = json.loads(candidates['Packages/LegadoRuntime/vendor/original-rule/manifest.json'])
for row in ported['portedSources']:
    raw = candidates[row['path']] if row['path'] in candidates else (ROOT / row['path']).read_bytes()
    assert len(raw) == row['bytes'] and hashlib.sha256(raw).hexdigest() == row['sha256'], row['path']
assert len(ported['portedSources']) == 56
assert any(r['path'] == 'io/yuedu/legado/OriginalLoginUIReuse.class' for r in ported['requiredRuntimeClasses'])
validation_root = PROD / 'validation-root'
inputs = read(PROD / 'actual-jvm-compilation-inputs.json')['inputs']
assert len(inputs) == len({r['path'] for r in inputs}) == 125
for row in inputs:
    path = row['path']; actual = validation_root / path
    check(actual, row)
    expected = candidates[path] if path in candidates else (ROOT / path).read_bytes()
    if path == 'Packages/LegadoRuntime/jvm/build.gradle.kts':
        expected += b'\ntasks.test {maxHeapSize="128m";minHeapSize="16m";jvmArgs("-XX:+UseSerialGC","-XX:MaxMetaspaceSize=128m")}\n'
    assert actual.read_bytes() == expected, path
tests = read(PROD / 'actual-jvm-tests.json')
assert tests['actualTestsAcrossTwoInvocations'] == 16 and [r['actualTests'] for r in tests['invocations']] == [12, 4]
leaves = set()
for suite in tests['suites']:
    xml = PROD / suite['xml']['path']; check(xml, suite['xml'])
    document = ET.parse(xml).getroot(); cases = document.findall('testcase')
    assert len(cases) == int(document.attrib['tests']) == suite['tests'] == 4
    assert all(int(document.attrib[k]) == 0 for k in ['failures', 'errors', 'skipped'])
    assert not document.findall('.//failure') + document.findall('.//error') + document.findall('.//skipped')
    assert {r.attrib['name'] for r in cases} == set(suite['methods'])
    for case in cases:
        key = (case.attrib['classname'], case.attrib['name'])
        assert key not in leaves; leaves.add(key)
    path = 'Packages/LegadoRuntime/jvm/src/test/kotlin/' + suite['class'].replace('.', '/') + '.kt'
    expected = candidates[path] if path in candidates else (ROOT / path).read_bytes()
    assert (validation_root / path).read_bytes() == expected
assert len(leaves) == 16
jar = PROD / prod['validation']['ordinaryJar']['path']
check(jar, prod['validation']['ordinaryJar'])
classes = read(PROD / 'ordinary-jar-production-class-binding.json')
assert classes['matchedProductionKotlinClasses'] == len(classes['classes']) == 337
with zipfile.ZipFile(jar) as archive:
    assert archive.testzip() is None
    for row in classes['classes']:
        raw = archive.read(row['path'])
        assert len(raw) == row['bytes'] and hashlib.sha256(raw).hexdigest() == row['sha256']
        compiled = validation_root / 'Packages/LegadoRuntime/jvm/build/classes/kotlin/main' / row['path']
        assert compiled.read_bytes() == raw
    assert archive.read('META-INF/legado-provenance/original-rule/manifest.json') == candidates['Packages/LegadoRuntime/vendor/original-rule/manifest.json']
for validation in harness['actualPortableValidation']:
    check(ROOT / validation['record']['path'], validation['record'])
    check(ROOT / validation['log']['path'], validation['log'])
    actual = read(ROOT / validation['record']['path'])
    assert actual['actualTestsRun'] == validation['actualTestsRun']
    assert actual['failures'] == actual['errors'] == actual['skipped'] == 0 and actual['successful'] is True
assert harness['finalDistinctAffectedPortableMethods'] == 21 and harness['actualPortableExecutionCount'] == 50
selection = harness['selection']
assert selection['AppQualifiedDefinitions'] == 463 and selection['AppArgumentLeaves'] == 466
assert [selection[k] for k in ['SwiftTestingNoArguments', 'SwiftTestingParameterized', 'XCTest']] == [442, 3, 18]
assert [selection[k] for k in ['NativeOriginal', 'NativeMainJS', 'PackageSelectedMethods']] == [20, 1, 23]
assert selection['PackageMustExecuteFresh'] is True and selection['PackageHistoricalReusePermitted'] is False
assert selection['coldInvocationSeconds'] == 3600 and selection['invocations'] == selection['xcresultBundles'] == 1
result = {'schemaVersion': 1, 'status': 'root-combined-byte-and-real-JVM-evidence-verified-awaiting-harness-independent-review', 'canonicalParent': head, 'productionManifest': fact(manifest_path), 'productionIndependentReview': fact(review_path), 'harnessManifest': fact(harness_path), 'changedProductionFiles': 19, 'changedHarnessFiles': 9, 'uniqueBoundInputs': 335, 'unchangedCanonicalInputsVerified': 307, 'sourceClosureCounts': {'core': 324, 'native': 115, 'package': 22}, 'actualJVMTests': {'mainInvocation': 12, 'correctedMissedUIInvocation': 4, 'uniqueActualMethods': 16, 'failuresErrorsSkips': 0, 'incorrectOriginalUiSelectorPreserved': True}, 'actualCompilationInputs': 125, 'explicitValidationOnlyBuildDelta': 'One128MiB/SerialGC test-worker stanza; canonical settings unchanged', 'ordinaryJar': fact(jar), 'compiledProductionClassBlobsMatchedToJar': 337, 'portedProductionSourcesVerified': 56, 'portableDistinctFinalAffectedMethodsPassed': 21, 'portableHistoricalAndCurrentExecutionsPreserved': 50, 'actualSwiftCompilerSDKOrJNIExecutionsDuringRootReview': 0, 'newCloudTags': 0, 'laterV2Excluded': True}
out = HARNESS / 'preparation/root-combined-review.json'
assert not out.exists(); out.write_bytes((json.dumps(result, indent=2) + '\n').encode())
print(json.dumps(result))
