import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
output = Path(__file__).resolve().parent
phase = sys.argv[1]
if not phase.replace('-', '').isalnum():
    raise ValueError('Invalid phase')
log = output / (phase + '.log')
record = output / (phase + '.json')
xml = output / (phase + '-xml')
if log.exists() or record.exists() or xml.exists():
    raise FileExistsError('Fresh evidence required')
environment = os.environ.copy()
environment['JAVA_HOME'] = str(root / '.tools/jdk21/jdk-21.0.12.1+1')
environment['GRADLE_USER_HOME'] = str(root / '.tools/gradle-user-home')
command = [str(root / '.tools/gradle-8.14.3/bin/gradle.bat'), '-p',
           str(root / 'Packages/LegadoRuntime/jvm'), '--offline', '--no-daemon', '--console=plain',
           'test', '--tests', 'io.yuedu.legado.OriginalRuleHttpPlatformTest',
           '--tests', 'io.yuedu.legado.OriginalAnalyzeRuleTest',
           '--tests', 'io.yuedu.legado.ProductionHttpTransportTest']
started = datetime.datetime.now(datetime.timezone.utc).isoformat()
with log.open('xb') as stream:
    result = subprocess.run(command, cwd=root, env=environment, stdout=stream,
                            stderr=subprocess.STDOUT, timeout=300, check=False)
xml.mkdir()
for source in (root / 'Packages/LegadoRuntime/jvm/build/test-results/test').glob('TEST-*.xml'):
    shutil.copyfile(source, xml / source.name)
metadata = {'command': command, 'startedAtUTC': started,
            'finishedAtUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'exitCode': result.returncode, 'logBytes': log.stat().st_size,
            'logSHA256': hashlib.sha256(log.read_bytes()).hexdigest(),
            'scope': 'Actual Windows JDK21 JVM loopback verification; no Android/iOS/App routing or full AnalyzeUrl acceptance.'}
record.write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
print(json.dumps(metadata))
sys.exit(result.returncode)
