import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import zipfile

root = Path(__file__).resolve().parents[3]
out = Path(__file__).resolve().parent
assert not (out / 'ordinary-v1.json').exists()
focused = json.loads((out.parent / 'focused-search-boundary.json').read_bytes())
assert focused['exitCode'] == 0
for item in focused['sourceBinding']:
    data = (root / item['path']).read_bytes()
    assert len(data) == item['bytes'] and hashlib.sha256(data).hexdigest() == item['sha256']
command = [str(root / '.tools/gradle-8.14.3/bin/gradle.bat'), '-p', str(root / 'Packages/LegadoRuntime/jvm'), '--offline', '--no-daemon', '--console=plain', 'runtimeJar', 'runtimeSmoke']
environment = os.environ.copy()
environment['JAVA_HOME'] = str(root / '.tools/jdk21/jdk-21.0.12.1+1')
environment['GRADLE_USER_HOME'] = str(root / '.tools/gradle-user-home')
started = datetime.datetime.now(datetime.timezone.utc).isoformat()
result = subprocess.run(command, cwd=root, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
finished = datetime.datetime.now(datetime.timezone.utc).isoformat()
(out / 'ordinary-v1.log').write_bytes(result.stdout)
record = {'command': command, 'startedAtUTC': started, 'finishedAtUTC': finished, 'exitCode': result.returncode,
          'logBytes': len(result.stdout), 'logSHA256': hashlib.sha256(result.stdout).hexdigest(),
          'scope': 'Independent search-owner correction checkpoint. Actual ordinary Windows JVM runtimeJar/runtimeSmoke: existing semantic smoke plus public original four-stage business execution with loopback/state host fixture. No includeEngineTests/iOS/Android/JNI/App route execution. The accepted affected JUnit run contains 31 unique methods; historical 171 evidence is unchanged.'}
if result.returncode == 0:
    assert b'PACKAGED_PAYLOAD_OK' in result.stdout
    assert b'PACKAGED_ORIGINAL_TRADITIONAL_OK' in result.stdout
    target = out / 'ordinary-v1-legado-runtime.jar'
    target.write_bytes((root / 'Packages/LegadoRuntime/jvm/build/libs/legado-runtime.jar').read_bytes())
    with zipfile.ZipFile(target) as archive:
        names = set(archive.namelist())
        required = ['io/legado/app/model/analyzeRule/AnalyzeUrl.class', 'io/legado/app/model/analyzeRule/AnalyzeRule.class',
                    'io/yuedu/legado/originalrule/ProductionRulePlatform.class', 'com/script/rhino/ScriptExecutionGuard.class',
                    'io/legado/app/model/analyzeRule/AnalyzeUrlNetworkOptionsKt.class', 'io/yuedu/legado/RuntimeHttpRequestExecutor.class',
                    'io/yuedu/legado/originalrule/OriginalIpValidator.class', 'io/yuedu/legado/originalrule/OriginalQueryEncoder.class']
        required += [item['path'] for item in json.loads((root / 'Packages/LegadoRuntime/vendor/original-rule/manifest.json').read_bytes())['requiredRuntimeClasses']]
        assert all(name in names for name in required)
        compiled_tests = set()
        for parent in ['Packages/LegadoRuntime/jvm/build/classes/kotlin/test', 'Packages/LegadoRuntime/jvm/build/classes/java/test']:
            folder = root / parent
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
        manifest_source = root / 'Packages/LegadoRuntime/vendor/original-rule/manifest.json'
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
(out / 'ordinary-v1.json').write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
print(json.dumps({key: value for key, value in record.items() if key != 'ordinaryJar'}))
if 'ordinaryJar' in record:
    print(json.dumps({key: value for key, value in record['ordinaryJar'].items() if key != 'byteEqualProvenanceAndNotices'}))
print(result.stdout.decode('utf-8', errors='replace')[-2800:])
raise SystemExit(result.returncode)
