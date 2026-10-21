from datetime import datetime, timezone
import difflib
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import time
import xml.etree.ElementTree as ET

R = Path('F:/yuedu-reader')
S = R / '.build/native-f481e89-proxy-fixture-repair-step'
P = 'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalRuleHttpPlatformTest.kt'
OLD = R / '.build/original-preupdate-refresh-step/test-execution-v4'
BASE = R / '.build/original-preupdate-refresh-step'
JAR = BASE / 'ordinary-jar-v3/legado-runtime-preupdate-refresh.jar'

def fact(p):
    raw = p.read_bytes()
    return {'path': p.relative_to(R).as_posix(), 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}

def write(p, obj):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes((json.dumps(obj, ensure_ascii=False, indent=2) + '\n').encode())

assert not (S / 'final-v1.json').exists()
assert fact(JAR)['bytes'] == 10961412 and fact(JAR)['sha256'] == '2963249f7f2fdace332e76f4fd16982ebc3afe60e6b0f897999e97dc036841c1'
inputs = json.loads((BASE / 'actual-jvm-compilation-inputs-final.json').read_bytes())['inputs']
assert len(inputs) == 133
for row in inputs:
    current = fact(R / row['path'])
    assert all(current[key] == row[key] for key in ['bytes', 'sha256']), row['path']
before = (R / P).read_bytes()
old = b'''                        assertThrows(UnsupportedRuleCapability::class.java) {
                            rule.connect(peer.origin, "{\\"proxy\\":\\"http://owned.invalid\\"}")
                        }
'''
new = b'''                        // Proxy is supported by the original HTTP path. Its real owned
                        // transport/credential/cancellation cases live in OriginalProxyExecutionTest.
'''
assert before.count(old) == 1
after = before.replace(old, new, 1)
assert after.count(b'@Test(') == before.count(b'@Test(')
baseline = S / 'baseline' / P
candidate = S / 'snapshot-v1/work' / P
baseline.parent.mkdir(parents=True, exist_ok=True)
candidate.parent.mkdir(parents=True, exist_ok=True)
baseline.write_bytes(before)
candidate.write_bytes(after)
diff = S / 'test-only.diff'
diff.write_bytes(''.join(difflib.unified_diff(before.decode().splitlines(True), after.decode().splitlines(True), fromfile='a/' + P, tofile='b/' + P)).encode())
prior = json.loads((OLD / 'commands.json').read_bytes())
compiler = prior['commands'][0]['argv']
compiler = compiler[:compiler.index('-d') + 2]
compiler[compiler.index('-d') + 1] = str(S / 'classes')
compiler[compiler.index('-module-name') + 1] = 'native-f481-proxy-contract-repair-tests'
compiler.append(str(candidate))
selected = 'io.yuedu.legado.OriginalRuleHttpPlatformTest/unsupportedRulesStayTypedAndNeverReachTransport'
runner = S / 'runner-classes'
runner.mkdir(parents=True, exist_ok=True)
reused = []
for path in sorted((OLD / 'classes').glob('SelectedUnionTests*.class')):
    target = runner / path.name
    shutil.copyfile(path, target)
    assert target.read_bytes() == path.read_bytes()
    reused.append({'input': fact(path), 'exactCopy': fact(target)})
assert reused
run = prior['commands'][2]['argv']
run[run.index('-cp') + 1] = str(S / 'classes') + ';' + str(runner) + ';' + prior['commands'][0]['argv'][prior['commands'][0]['argv'].index('-classpath') + 1]
run[-3:] = [str(S / 'actual-tests.xml'), '1', selected]
commands = []
def execute(argv, name):
    started = time.monotonic()
    result = subprocess.run(argv, cwd=R, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60, check=False)
    log = S / name
    log.write_bytes(result.stdout)
    commands.append({'argv': argv, 'exitCode': result.returncode, 'seconds': round(time.monotonic() - started, 3), 'log': fact(log)})
    write(S / 'commands.json', {'jar': fact(JAR), 'sources': [fact(candidate)], 'reusedRunner': reused, 'commands': commands})
    assert result.returncode == 0, name

execute(compiler, 'compile-test.log')
execute(run, 'junit-selected.log')
tree = ET.parse(S / 'actual-tests.xml').getroot()
cases = tree.findall('.//testcase')
assert len(cases) == 1 and not tree.findall('.//failure') and not tree.findall('.//error') and not tree.findall('.//skipped')
assert cases[0].attrib['name'] == selected.split('/')[1]
final = {
    'schemaVersion': 1, 'frozenUTC': datetime.now(timezone.utc).isoformat(),
    'status': 'test-only-stale-proxy-unsupported-expectation-repaired-one-actual-relevant-JVM-method-passed',
    'sourceRoot': '.build/native-f481e89-proxy-fixture-repair-step/snapshot-v1/work',
    'files': [{'path': P, 'baseline': fact(baseline), 'candidate': fact(candidate), 'diff': fact(diff)}],
    'productionChanges': 0, 'newDefinitions': 0,
    'reason': 'Proxy support was implemented and already tested through owned real HTTP/SOCKS public paths. The obsolete rejection sent a reserved .invalid proxy into the actual supported path and expected UnsupportedRuleCapability; original connect returns a stack response for ordinary proxy IO failures.',
    'retainedAssertions': 'All three still-unsupported webView/binary/serverID connect+ajax checks and both no-transport assertions remain byte-identical. All other methods and helpers are byte-identical.',
    'reusedProductionJar': fact(JAR), 'productionInputsCheckedExactCanonical': 133,
    'commands': fact(S / 'commands.json'), 'actualXML': fact(S / 'actual-tests.xml'),
    'actualDistinctJVMMethodsPassed': 1, 'actualJVMExecutions': 1,
    'mainK2Compiles': 0, 'testK2Compiles': 1, 'freshJavacCompiles': 0,
    'SDKExecutions': 0, 'NativeJNIExecutions': 0, 'cloudActions': 0,
    'limits': ['No fresh full378-method run; the failed cloud run remains a failure.', 'The unchanged proxy-success regressions and all unchanged cloud377 passes are retained as separate source-specific evidence.'],
    'allNonDeviceWorkComplete': False, 'automaticSelfRenewalImplemented': False,
    'fullLegadoCompatibilityEstablished': False, 'legalRedistributionClearanceEstablished': False,
}
write(S / 'final-v1.json', final)
print(json.dumps({'final': fact(S / 'final-v1.json'), 'candidate': fact(candidate), 'actualMethodsPassed': 1, 'productionChanges': 0}))
