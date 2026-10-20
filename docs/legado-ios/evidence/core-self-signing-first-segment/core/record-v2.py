import datetime
import difflib
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[2]
output = Path(__file__).resolve().parent
destination = output / 'preparation-v2.json'
diff_path = output / 'v1-to-v2.patch'
if destination.exists() or diff_path.exists():
    raise FileExistsError('Fresh v2 record required')

def identity(path):
    data = path.read_bytes()
    return {'path': path.relative_to(root).as_posix(), 'bytes': len(data),
            'sha256': hashlib.sha256(data).hexdigest()}

v1_path = output / 'preparation-v1.json'
v1 = json.loads(v1_path.read_text(encoding='utf-8'))
diff = []
snapshots = []
for item in v1['files']:
    original = output / 'v1-sources' / item['path']
    assert identity(original)['sha256'] == item['sha256']
    snapshots.append(identity(original))
    diff += list(difflib.unified_diff(original.read_text(encoding='utf-8').splitlines(keepends=True),
                                    (root / item['path']).read_text(encoding='utf-8').splitlines(keepends=True),
                                    fromfile='a/' + item['path'], tofile='b/' + item['path']))
with diff_path.open('x', encoding='utf-8', newline='\n') as stream:
    stream.write(''.join(diff))
for item in v1['unchangedReviewedInputs']:
    assert identity(root / item['path']) == item

expected = {'io.yuedu.legado.OriginalRuleHttpPlatformTest': 8,
            'io.yuedu.legado.OriginalAnalyzeRuleTest': 18,
            'io.yuedu.legado.ProductionHttpTransportTest': 12}
suites = []
for path in sorted((output / 'focused-v2-xml').glob('TEST-*.xml')):
    suite = ET.parse(path).getroot()
    name = suite.attrib['name']
    assert name in expected
    assert int(suite.attrib['tests']) == expected[name]
    assert all(int(suite.attrib[key]) == 0 for key in ('failures', 'errors', 'skipped'))
    cases = [case.attrib['name'] for case in suite.findall('testcase')]
    assert len(cases) == len(set(cases)) == expected[name]
    suites.append({'suite': name, 'tests': len(cases), 'failures': 0, 'errors': 0, 'skipped': 0,
                   'cases': cases, 'raw': identity(path)})
assert {item['suite'] for item in suites} == set(expected)
focused = json.loads((output / 'focused-v2.json').read_text(encoding='utf-8'))
ordinary = json.loads((output / 'ordinary-v2.json').read_text(encoding='utf-8'))
assert focused['exitCode'] == ordinary['exitCode'] == 0
assert identity(output / 'focused-v2.log')['sha256'] == focused['logSHA256']
assert identity(output / 'ordinary-v2.log')['sha256'] == ordinary['logSHA256']
assert identity(output / 'ordinary-v2-legado-runtime.jar')['sha256'] == ordinary['ordinaryJar']['sha256']
record = {
    'schemaVersion': 1, 'createdAtUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'status': 'desktop-verified-first-task-bound-request-segment-not-app-routed',
    'summaryZh': '保留的原 AnalyzeRule 可显式创建 task-bound 生产 HTTP 环境，沿现有唯一 JVM 请求路径执行有限静态请求；关闭环境拒绝晚结果。',
    'files': [identity(root / item['path']) for item in v1['files']],
    'unchangedReviewedInputs': v1['unchangedReviewedInputs'],
    'originalReference': v1['originalReference'], 'api': v1['api'],
    'v1EvidencePreserved': {'record': identity(v1_path), 'sourceSnapshots': snapshots,
                            'focusedRaw': [identity(output / name) for name in ('focused-v1.log', 'focused-v1.json')],
                            'methods': 37, 'executions': 37, 'failures': 0,
                            'meaning': '原首轮真实 37 通过不覆盖；v2 仅补 owner 生命周期检查及第 8 项回归。'},
    'lifecycleFix': {'diff': identity(diff_path),
                    'behaviorZh': 'factory 在环境构造后绑定 ensureOpen；adapter 在入口、HTTP dispatch 前及正常返回前检查，关闭转 CancellationException，防 ajax 吞成正文。',
                    'closeBoundaryZh': 'close 不承诺即时终止已运行 host，不取消共享 task/session；已运行 HTTP 继续受现有 task deadline/transport timeout 约束，但不发布关闭后的晚正文。',
                    'lateCancellationZh': '成功后 finally 解除 caller Job 回调，随后 caller.cancel 不会波及同 task 的后续请求。'},
    'actualVerification': {'environment': 'Windows / existing JDK21 / Gradle / --offline',
                           'newMethods': 8, 'newExecutions': 8, 'totalMethods': 38, 'totalExecutions': 38,
                           'failures': 0, 'errors': 0, 'skipped': 0, 'suites': suites,
                           'raw': [identity(output / name) for name in ('focused-v2.log', 'focused-v2.json')]},
    'ordinaryPayload': {'record': identity(output / 'ordinary-v2.json'), 'log': identity(output / 'ordinary-v2.log'),
                        'jar': identity(output / 'ordinary-v2-legado-runtime.jar'),
                        'engineTestsFlag': False, 'requiredClasses': ordinary['ordinaryJar']['requiredClasses'],
                        'junitOrProjectTestClasses': ordinary['ordinaryJar']['junitOrProjectTestClasses'],
                        'byteEqualProvenanceAndNoticesCount': len(ordinary['ordinaryJar']['byteEqualProvenanceAndNotices']),
                        'scopeZh': '普通 runtimeJar 与 runtimeSmoke 实际通过，没有 includeEngineTests，没有重跑全套；逐项原件 hash 在 ordinary-v2.json，不是 iOS/JNI 执行。'},
    'limitsZh': v1['limitsZh'][:-1] + [
        '本批只改 3 个列明源码路径；未编辑 JVM build.gradle/依赖锁/vendor manifest 或 notices。普通 JAR 对应 provenance/notices 与当前冻结原件逐字节相同；不把打包验收当 iOS/JNI 执行。',
        '未运行 iOS、Android、真机、云测、真实书源或完整阅读链；未切 App 路由，不宣称完整 AnalyzeRule/AnalyzeUrl 兼容。',
    ],
    'independentReview': '根与 UI agent 已参与静态复核，最终独立结论由根另行确认；此记录不代替独审。',
}
text = json.dumps(record, ensure_ascii=False, indent=2) + '\n'
assert '\ufffd' not in text
with destination.open('x', encoding='utf-8', newline='\n') as stream:
    stream.write(text)
print(json.dumps(identity(destination)))
print(json.dumps(record['files']))
