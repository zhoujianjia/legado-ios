import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import zipfile

root = Path(__file__).resolve().parents[2]
output = Path(__file__).resolve().parent
log = output / 'ordinary-v2.log'
record = output / 'ordinary-v2.json'
jar_copy = output / 'ordinary-v2-legado-runtime.jar'
if any(path.exists() for path in (log, record, jar_copy)):
    raise FileExistsError('Fresh ordinary payload evidence required')
environment = os.environ.copy()
environment['JAVA_HOME'] = str(root / '.tools/jdk21/jdk-21.0.12.1+1')
environment['GRADLE_USER_HOME'] = str(root / '.tools/gradle-user-home')
command = [str(root / '.tools/gradle-8.14.3/bin/gradle.bat'), '-p',
           str(root / 'Packages/LegadoRuntime/jvm'), '--offline', '--no-daemon', '--console=plain',
           'runtimeJar', 'runtimeSmoke']
started = datetime.datetime.now(datetime.timezone.utc).isoformat()
with log.open('xb') as stream:
    result = subprocess.run(command, cwd=root, env=environment, stdout=stream,
                            stderr=subprocess.STDOUT, timeout=300, check=False)
metadata = {'command': command, 'startedAtUTC': started,
            'finishedAtUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'exitCode': result.returncode, 'logBytes': log.stat().st_size,
            'logSHA256': hashlib.sha256(log.read_bytes()).hexdigest(),
            'scope': 'Actual ordinary JVM runtimeJar/runtimeSmoke; no includeEngineTests, iOS, JNI, or App route execution.'}
if result.returncode == 0:
    candidates = list((root / 'Packages/LegadoRuntime/jvm/build/libs').glob('legado-runtime.jar'))
    assert len(candidates) == 1
    shutil.copyfile(candidates[0], jar_copy)
    with zipfile.ZipFile(jar_copy) as archive:
        names = set(archive.namelist())
        required = ['io/yuedu/legado/originalrule/ProductionRulePlatform.class',
                    'io/legado/app/model/analyzeRule/AnalyzeRule.class']
        assert all(name in names for name in required)
        rejected = sorted(name for name in names if name.startswith(('org/junit/', 'junit/', 'fixtures/'))
                          or (name.startswith('io/yuedu/legado/') and name.rsplit('/', 1)[-1].split('$')[0].endswith('Test.class')))
        assert not rejected, rejected
        manifest = archive.read('META-INF/MANIFEST.MF').decode('utf-8')
        assert 'Legado-Engine-Tests: false' in manifest
        vendor = root / 'Packages/LegadoRuntime/vendor'
        mappings = [('manifest.json', 'META-INF/legado-provenance/manifest.json'),
                    ('original-rule/manifest.json', 'META-INF/legado-provenance/original-rule/manifest.json'),
                    ('runtime-http/manifest.json', 'META-INF/legado-provenance/runtime-http/manifest.json'),
                    ('runtime-http/resolved-dependencies.json', 'META-INF/legado-provenance/runtime-http/resolved-dependencies.json'),
                    ('scalar-rules/manifest.json', 'META-INF/legado-provenance/scalar-rules/manifest.json'),
                    ('scalar-rules/resolved-dependencies.json', 'META-INF/legado-provenance/scalar-rules/resolved-dependencies.json')]
        for directory, prefix in [('licenses', 'META-INF/licenses'),
                                  ('original-rule/licenses', 'META-INF/licenses/original-rule'),
                                  ('runtime-http/licenses', 'META-INF/licenses/jvm-http'),
                                  ('scalar-rules/licenses', 'META-INF/licenses/scalar-rules')]:
            for source in (vendor / directory).rglob('*'):
                if source.is_file():
                    mappings.append((source.relative_to(vendor).as_posix(),
                                     prefix + '/' + source.relative_to(vendor / directory).as_posix()))
        notices = []
        for source_name, member in mappings:
            data = (vendor / source_name).read_bytes()
            assert archive.read(member) == data, member
            notices.append({'source': source_name, 'member': member, 'bytes': len(data),
                            'sha256': hashlib.sha256(data).hexdigest()})
    metadata['ordinaryJar'] = {'path': jar_copy.relative_to(root).as_posix(), 'bytes': jar_copy.stat().st_size,
                               'sha256': hashlib.sha256(jar_copy.read_bytes()).hexdigest(),
                               'requiredClasses': required, 'junitOrProjectTestClasses': rejected,
                               'engineTestsFlag': False, 'byteEqualProvenanceAndNotices': notices}
record.write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
print(json.dumps({'exitCode': result.returncode, 'logSHA256': metadata['logSHA256'],
                  'ordinaryJar': metadata.get('ordinaryJar', {}).get('sha256')}))
raise SystemExit(result.returncode)
