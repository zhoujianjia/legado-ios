import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import zipfile
import sys

version = sys.argv[1] if len(sys.argv) > 1 else "v1"

out = Path(__file__).resolve().parent
root = out.parents[1]
jvm = out / 'jvm-work'
assert not (out / f'ordinary-{version}.json').exists()
focused_record = sys.argv[2] if len(sys.argv) > 2 else 'focused-final.json'
focused = json.loads((out / focused_record).read_bytes())
assert focused['exitCode'] == 0
integration = json.loads((out / 'ordinary-integration-input-delta.json').read_bytes())
allowed = {item['path']: item['finalSHA256'] for item in integration['changesFromFocusedV3']}
for item in focused['sourceBinding']:
    data = Path(item['actualExecutionPath']).read_bytes()
    assert hashlib.sha256(data).hexdigest() == allowed.get(item['path'], item['sha256'])
inputs = []
for path in sorted(list((jvm / 'src').rglob('*.kt')) + list((jvm / 'src').rglob('*.java')) + [jvm / 'build.gradle.kts']):
    relative = path.relative_to(jvm); data = path.read_bytes()
    origin = out / 'work/Packages/LegadoRuntime/jvm' / relative
    if not origin.exists(): origin = root / 'Packages/LegadoRuntime/jvm' / relative
    assert origin.read_bytes() == data
    snapshot = out / f'ordinary-{version}-sources' / relative
    snapshot.parent.mkdir(parents=True, exist_ok=True); snapshot.write_bytes(data)
    inputs.append(dict(path='Packages/LegadoRuntime/jvm/' + relative.as_posix(), actualExecutionPath=path.as_posix(), sourcePath=origin.as_posix(), bytes=len(data), sha256=hashlib.sha256(data).hexdigest(), snapshot=snapshot.relative_to(root).as_posix()))
command = [str(root / '.tools/gradle-8.14.3/bin/gradle.bat'), '-p', str(jvm), '--offline', '--no-daemon', '--console=plain', 'runtimeJar', 'runtimeSmoke']
environment = os.environ.copy()
environment['JAVA_HOME'] = str(root / '.tools/jdk21/jdk-21.0.12.1+1')
environment['GRADLE_USER_HOME'] = str(root / '.tools/gradle-user-home')
started = datetime.datetime.now(datetime.timezone.utc).isoformat()
result = subprocess.run(command, cwd=root, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
finished = datetime.datetime.now(datetime.timezone.utc).isoformat()
(out / f'ordinary-{version}.log').write_bytes(result.stdout)
record = {'command': command, 'startedAtUTC': started, 'finishedAtUTC': finished, 'exitCode': result.returncode,
          'logBytes': len(result.stdout), 'logSHA256': hashlib.sha256(result.stdout).hexdigest(),
          'scope': 'Actual isolated Windows JDK21 ordinary runtimeJar/runtimeSmoke after rebasing onto reviewed mainline9ff2592 subContent sources. Default semantic + original four-stage + app-owner-read + app-owner-text actual redirect/response/write four-stage smoke. Cookie63 selected methods remain their prior exact input boundary; parent subContent tests separate. No test/JUnit payload or Swift/native/JNI/product-route acceptance.', 'sourceBinding': inputs, 'integrationDelta': integration}
if result.returncode == 0:
    assert b'PACKAGED_PAYLOAD_OK' in result.stdout
    assert b'PACKAGED_ORIGINAL_TRADITIONAL_OK' in result.stdout
    assert b'PACKAGED_APP_COOKIE_OWNER_READ_OK' in result.stdout
    assert b'PACKAGED_APP_COOKIE_OWNER_TEXT_OK' in result.stdout
    target = out / f'ordinary-{version}-legado-runtime.jar'
    target.write_bytes((jvm / 'build/libs/legado-runtime.jar').read_bytes())
    with zipfile.ZipFile(target) as archive:
        names = set(archive.namelist())
        required = ['io/legado/app/model/analyzeRule/AnalyzeUrl.class', 'io/legado/app/model/analyzeRule/AnalyzeRule.class',
                    'io/yuedu/legado/originalrule/ProductionRulePlatform.class', 'com/script/rhino/ScriptExecutionGuard.class',
                    'io/legado/app/model/analyzeRule/AnalyzeUrlNetworkOptionsKt.class', 'io/yuedu/legado/RuntimeHttpRequestExecutor.class',
                    'io/yuedu/legado/originalrule/OriginalIpValidator.class', 'io/yuedu/legado/originalrule/OriginalQueryEncoder.class', 'io/yuedu/legado/originalrule/AppCookieOwnerClient.class', 'io/yuedu/legado/originalrule/OriginalCookieText.class']
        required += [item['path'] for item in json.loads((out / 'vendor/original-rule/manifest.json').read_bytes())['requiredRuntimeClasses']]
        assert all(name in names for name in required)
        compiled_tests = set()
        for parent in ['build/classes/kotlin/test', 'build/classes/java/test']:
            folder = jvm / parent
            compiled_tests.update(path.relative_to(folder).as_posix() for path in folder.rglob('*.class'))
        leaked = sorted(names & compiled_tests)
        assert not leaked
        assert not any(name.endswith('FileRulePersistenceAdapter.class') or name.endswith('StatePersistenceProcessProbe.class') for name in names)
        assert 'fixtures/android-traditional-stateful-golden.json' not in names
        assert 'LegadoPayloadSmoke.class' not in names
        assert not any(name.startswith('org/junit/') or name.startswith('junit/') for name in names)
        prior = json.loads((root / '.build/original-rule-cookie-first-segment/ordinary-v1.json').read_bytes())
        notices = []
        new_manifest = 'META-INF/legado-provenance/original-rule/manifest.json'
        manifest_source = out / 'vendor/original-rule/manifest.json'
        for item in prior['ordinaryJar']['byteEqualProvenanceAndNotices']:
            data = archive.read(item['member'])
            if item['member'] == new_manifest:
                assert data == manifest_source.read_bytes()
            else:
                assert len(data) == item['bytes'] and hashlib.sha256(data).hexdigest() == item['sha256']
                notices.append(item)
        assert len(notices) == len(prior['ordinaryJar']['byteEqualProvenanceAndNotices']) - 1
        current_manifest = archive.read(new_manifest)
        record['ordinaryJar'] = {'path': target.relative_to(root).as_posix(), 'bytes': target.stat().st_size,
            'sha256': hashlib.sha256(target.read_bytes()).hexdigest(), 'requiredClasses': required,
            'junitOrProjectTestClasses': leaked, 'projectCompiledTestClassesChecked': len(compiled_tests),
            'engineTestsFlag': False, 'byteEqualProvenanceAndNotices': notices,
            'updatedOriginalRuleManifestMatchesReviewedFile': {'member': new_manifest, 'bytes': len(current_manifest), 'sha256': hashlib.sha256(current_manifest).hexdigest()},
            'binaryLocalOnly': True}
record['executionSourcesUnchanged'] = all(Path(item['actualExecutionPath']).read_bytes() == (root / item['snapshot']).read_bytes() for item in inputs)
assert record['executionSourcesUnchanged']
(out / f'ordinary-{version}.json').write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
print(json.dumps({key: value for key, value in record.items() if key not in ('ordinaryJar', 'sourceBinding', 'integrationDelta')}))
if 'ordinaryJar' in record:
    print(json.dumps({key: value for key, value in record['ordinaryJar'].items() if key != 'byteEqualProvenanceAndNotices'}))
print(result.stdout.decode('utf-8', errors='replace')[-2800:])
raise SystemExit(result.returncode)
