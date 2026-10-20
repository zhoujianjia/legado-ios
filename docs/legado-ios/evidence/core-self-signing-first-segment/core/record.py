import datetime
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET
import zipfile

root = Path(__file__).resolve().parents[2]
output = Path(__file__).resolve().parent
destination = output / 'preparation-v1.json'
if destination.exists():
    raise FileExistsError(destination)

def identity(path):
    data = path.read_bytes()
    return {'path': path.relative_to(root).as_posix(), 'bytes': len(data),
            'sha256': hashlib.sha256(data).hexdigest()}

files = [
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/LegadoRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/ProductionRulePlatform.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalRuleHttpPlatformTest.kt',
]
inputs = [
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RulePlatform.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RuleStateStore.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/SourceHosts.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/ProductionHttpTransport.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/LegadoHttpRequestPreprocessor.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/model/analyzeRule/AnalyzeRule.kt',
]
expected = {'io.yuedu.legado.OriginalRuleHttpPlatformTest': 7,
            'io.yuedu.legado.OriginalAnalyzeRuleTest': 18,
            'io.yuedu.legado.ProductionHttpTransportTest': 12}
suites = []
for path in sorted((output / 'focused-v1-xml').glob('TEST-*.xml')):
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
run = json.loads((output / 'focused-v1.json').read_text(encoding='utf-8'))
assert run['exitCode'] == 0
assert identity(output / 'focused-v1.log')['sha256'] == run['logSHA256']
archive = Path('F:/legado-master.zip')
archive_hash = hashlib.sha256(archive.read_bytes()).hexdigest()
assert archive_hash == '724dedcac2427cd1f02ca00af1eab7156146e6d9d3141ca4c92042d04ed7bcdd'
with zipfile.ZipFile(archive) as source:
    names = ['legado-master/app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeUrl.kt',
             'legado-master/app/src/main/java/io/legado/app/help/JsExtensions.kt']
    entries = [{'entry': name, 'bytes': len(source.read(name)),
                'sha256': hashlib.sha256(source.read(name)).hexdigest()} for name in names]
record = {
    'schemaVersion': 1, 'createdAtUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'status': 'desktop-verified-first-task-bound-request-segment-not-app-routed',
    'summaryZh': '保留的原 AnalyzeRule 现在可显式创建当前任务绑定的生产 HTTP 环境，沿唯一 JVM 请求路径执行有限静态请求；默认环境仍拒绝网络。',
    'files': [identity(root / path) for path in files],
    'unchangedReviewedInputs': [identity(root / path) for path in inputs],
    'originalReference': {'localArchive': str(archive), 'sha256': archive_hash, 'entries': entries,
                          'scope': '只读原源码行为依据，未运行或改写原 AnalyzeUrl。'},
    'api': {'factory': 'LegadoRuntime.originalRuleEnvironment(RuntimeTask): RuleEnvironment (internal)',
            'callPath': 'retained AnalyzeRule → RulePlatform.request → SourceJavaHost → existing dispatchHost → ProductionHttpTransport',
            'taskContext': '同一 RuntimeTask、deadline、Job、RuntimeSession 和现有 JVM cookie jar；distinct caller Job 取消仅在该请求期间连接到同一 task。',
            'capabilityFailure': '现有 SourceJavaHost 的 UNSUPPORTED_CAPABILITY 转为原规则的 UnsupportedRuleCapability，不能被 ajax 伪装为成功正文。'},
    'actualVerification': {'environment': 'Windows / existing JDK 21 / existing Gradle / --offline',
                           'compileKotlin': True, 'newMethods': 7, 'newExecutions': 7,
                           'totalMethods': 37, 'totalExecutions': 37,
                           'failures': 0, 'errors': 0, 'skipped': 0,
                           'suites': suites, 'raw': [identity(output / name) for name in ('focused-v1.log', 'focused-v1.json')]},
    'limitsZh': [
        '未改变 App 传统书源的 Swift/JSC 路由；新工厂是供后续原流程显式调用的生产请求接点，没有新增 execute operation。',
        '原 AnalyzeUrl 的完整动态解析、请求编排、WebView/Cronet/媒体、代理、限流、DNS、bodyJs 等未迁移；继续由现有限定适配器明确拒绝未支持输入。',
        'RuleSource 环境缓存的登录头、变量和 Cookie API 尚未与 RuntimeSession 状态统一；测试中的既有 session 请求头不能当作原源状态同步已完成。',
        '普通网络 I/O 错误保留现有 connect 的堆栈响应约定；取消和 deadline 抛取消，未新增重试、存储、缓存或 Swift 回退。',
        '未运行 iOS、Android、真机、云测、真实书源或完整阅读链；未执行普通 fat JAR 打包验收，不宣称完整 AnalyzeRule/AnalyzeUrl 兼容。',
    ],
    'independentReview': '待根独立审查；本记录不是独立审查或兼容性验收。',
}
text = json.dumps(record, ensure_ascii=False, indent=2) + '\n'
assert '\ufffd' not in text
with destination.open('x', encoding='utf-8', newline='\n') as stream:
    stream.write(text)
print(json.dumps(identity(destination)))
