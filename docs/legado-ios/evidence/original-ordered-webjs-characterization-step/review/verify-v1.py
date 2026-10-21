from pathlib import Path
from collections import Counter
import datetime
import hashlib
import json
import re
import sys

R = Path('F:/yuedu-reader')
S = R / '.build/original-general-webjs-ordered-result-independent-review'
P = R / '.build/original-general-webjs-ordered-result-step'
S.mkdir(parents=True, exist_ok=True)
checks = []

def sha(b): return hashlib.sha256(b).hexdigest()
def fact(p):
    b = p.read_bytes()
    return dict(path=p.relative_to(R).as_posix(), bytes=len(b), sha256=sha(b))
def check(name, ok, actual=None):
    checks.append(dict(name=name, passed=bool(ok), actual=actual))
def bind(entry, base=R):
    p = base / entry['path']
    f = fact(p)
    check('binding:' + f['path'], f['bytes'] == entry['bytes'] and f['sha256'] == entry['sha256'], f)
    return f
def bind_nested(value):
    if isinstance(value, dict):
        if {'path', 'bytes', 'sha256'} <= value.keys():
            bind(value)
        for v in value.values(): bind_nested(v)
    elif isinstance(value, list):
        for v in value: bind_nested(v)

final_path = P / 'final-v1.json'
final_fact = fact(final_path)
check('exact frozen final', final_fact['bytes'] == 4727 and final_fact['sha256'] == '97cbf80b3502e7d0b12b869c6b6b3dfa28723646e52ebdfb2c6fda0aa6885a72', final_fact)
final = json.loads(final_path.read_text(encoding='utf-8'))
check('exactly one source', len(final['files']) == 1)
for f in final['files']:
    baseline_path = R / final['baselineRoot'] / f['path']
    candidate_path = R / final['sourceRoot'] / f['path']
    baseline = baseline_path.read_bytes()
    candidate = candidate_path.read_bytes()
    check('baseline source exact', len(baseline) == f['baseline']['bytes'] and sha(baseline) == f['baseline']['sha256'], fact(baseline_path))
    check('candidate source exact', len(candidate) == f['candidate']['bytes'] and sha(candidate) == f['candidate']['sha256'], fact(candidate_path))
    check('current canonical baseline exact', (R / f['path']).read_bytes() == baseline, fact(R / f['path']))
    bind(f['diff'])
for e in final['evidence']: bind(e)
bind(final['primaryBinding'])
inputs = json.loads((P / 'snapshot-v1/evidence/inputs-v1.json').read_text(encoding='utf-8'))
contract = json.loads((P / 'snapshot-v1/evidence/contract-v1.json').read_text(encoding='utf-8'))
primary = json.loads((P / 'snapshot-v1/evidence/primary-binding-v2.json').read_text(encoding='utf-8'))
syntax = json.loads((P / 'snapshot-v1/evidence/syntax-and-identity-v1.json').read_text(encoding='utf-8'))
bind_nested(inputs)
bind_nested(contract)
bind_nested(syntax)
check('ten official pinned primary files', len(primary['files']) == 10 and primary['commit'] == '0cdff65f65d6846840d6ac43fb3a035bd4bcb957')
for p in primary['files']:
    bind(p, P / 'primary')
    check('official primary URL:' + p['path'], p['url'].startswith(('https://raw.githubusercontent.com/WebKit/WebKit/0cdff65f65d6846840d6ac43fb3a035bd4bcb957/', 'https://developer.apple.com/documentation/')))

method = (P / 'new-method.swift.txt').read_text(encoding='utf-8')
helper = (P / 'new-helper.swift.txt').read_text(encoding='utf-8')
anchor = 'final class LegadoNativeOriginalReaderTests: XCTestCase {\n'
composed = baseline.decode('utf-8').replace('import XCTest\n', 'import WebKit\nimport XCTest\n', 1)
composed = composed.replace(anchor, anchor + method + '\n', 1)
composed = composed.rstrip('\r\n') + '\n' + helper.rstrip('\r\n') + '\n'
check('whole file exact import plus new method plus helper', composed.encode('utf-8') == candidate)

def bound_functions(data):
    # Independently match the recorded raw function bytes directly. The whole
    # composition check above additionally proves no old bytes were rewritten.
    found = []
    for recorded in syntax['oldMethodFacts']:
        for expected in recorded['overloads']:
            matches = []
            for token in re.finditer(rb'\bfunc\s+' + re.escape(recorded['name'].encode()) + rb'\b', data):
                for start in range(max(0, token.start()-512), token.start()+1):
                    raw = data[start:start+expected['bytes']]
                    if len(raw) == expected['bytes'] and sha(raw) == expected['sha256']:
                        matches.append(start)
            check('raw function binding:' + recorded['name'] + ':' + sha(data), len(matches) == 1)
            if matches:
                found.append(dict(name=recorded['name'], **expected, line=data[:matches[0]].count(b'\n')+1))
    return found

old = bound_functions(baseline)
new = bound_functions(candidate)
old_counter = Counter((f['name'], f['bytes'], f['sha256']) for f in old)
new_counter = Counter((f['name'], f['bytes'], f['sha256']) for f in new)
check('all old function bytes preserved including same-name overloads', not (old_counter-new_counter), dict(oldFunctions=len(old), retainedFunctions=len(new)))
for f in old:
    check('old function:' + f['name'] + ':' + f['sha256'], new_counter[(f['name'], f['bytes'], f['sha256'])] >= old_counter[(f['name'], f['bytes'], f['sha256'])])
old_tests = re.findall(rb'\bfunc\s+(testNative\w+)\s*\(',baseline)
new_tests = re.findall(rb'\bfunc\s+(testNative\w+)\s*\(',candidate)
added_tests = [t.decode() for t in new_tests if t not in old_tests]
check('exact 14 retained plus one new Native method', len(old_tests) == 14 and len(new_tests) == 15 and added_tests == ['testNativeOriginalOrderedWebJSCharacterizesCSPAndOriginalJSONInSamePageWorld'], added_tests)
for f in syntax['oldMethodFacts']:
    actual = sorted((g['bytes'],g['sha256']) for g in old if g['name'] == f['name'])
    recorded = sorted((g['bytes'],g['sha256']) for g in f['overloads'])
    check('author old function fact exact:' + f['name'], actual == recorded)

static_checks = [
    ('one test-owned WK instance', helper.count('view = WKWebView(') == 1 and method.count('OriginalOrderedWebJSCharacterization()') == 1),
    ('same instance two CSP document modes', 'for allowsEval in [true, false]' in method and 'probe.load(allowsEval: allowsEval' in method),
    ('page-world document-start intrinsic capture', 'const \\(capturedJSONName)=JSON.stringify; const \\(capturedEvalName)=eval;' in helper and 'injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page' in helper),
    ('captured lexical bindings are not window properties', 'hasOwnProperty.call(window' in helper and 'function|function|false|false' in method),
    ('owned HTML and nonpersistent WK store', 'configuration.websiteDataStore = .nonPersistent()' in helper and 'view.loadHTMLString(html' in helper and "default-src 'none'; script-src 'nonce-owned'" in helper),
    ('real navigation callback identity and terminal guard', 'completed === navigation, !navigationTerminal' in helper and 'expectation?.fulfill()' in helper),
    ('native Program values only projection', 'probe.dictionary("var orderedNativeVar=40; let orderedNativeLexical=2;' in method and 'result.mapValues(\\.intValue)' in helper),
    ('known-expression route does not call eval', 'try await string("\\(jsonName)((\\(expression)))")' in helper),
    ('actual JSON bytes compare Unicode sequences', 'XCTAssertEqual(Data(actual.utf8), Data(vector.expectedJSON.utf8))' in method),
    ('side effect once assertion', 'window.orderedEffects=(window.orderedEffects||0)+1' in method and 'XCTAssertEqual(effectCount, "1")' in method),
    ('array object and nested object vectors', '[{b:2,a:1},{d:4,c:3}]' in method and '({z:{b:2,a:1},a:[3,2,1]})' in method),
    ('integer-key ordering and undefined nonfinite vectors', "o['10']=10;o['2']=2" in method and '({b:undefined,a:[undefined,NaN,Infinity]})' in method),
    ('strict and lexical eval lifetimes explicitly differentiated', 'typeof orderedEvalStrict' in method and 'typeof orderedEvalVar,typeof orderedEvalLexical' in method and 'orderedNativeStrict' in method),
    ('captured eval CSP error counterexample is asserted', 'EvalError' in method and 'probe.capturedEval(' in method),
    ('actual evaluate callbacks drain before teardown', helper.count('view.evaluateJavaScript(script)') == 2 and 'if evaluationsInFlight != 0' in helper and 'drain = continuation' in helper and 'completion?.resume()' in helper),
    ('both success and failure close owned probe', method.count('await probe.close()') == 2),
    ('no sleep polling or production runtime fallback', not any(t in method+helper for t in ['Task.sleep', 'asyncAfter', 'JSContext(', 'LegadoPersistentStateHost(', 'MainJSService(', 'URLRequest('])),
]
for name,ok in static_checks: check(name,ok)

pri_root = P / 'primary'
jsc = (pri_root / 'Source/JavaScriptCore/runtime/JSGlobalObjectFunctions.cpp').read_text(encoding='utf-8')
sc = (pri_root / 'Source/WebCore/bindings/js/ScriptController.cpp').read_text(encoding='utf-8')
csp = (pri_root / 'Source/WebCore/page/csp/ContentSecurityPolicy.cpp').read_text(encoding='utf-8')
wk = (pri_root / 'Source/WebKit/UIProcess/API/Cocoa/WKWebView.mm').read_text(encoding='utf-8')
check('pinned eval dynamically checks permission', 'if (!globalObject->evalEnabled()' in jsc and 'createEvalError(globalObject, globalObject->evalDisabledErrorMessage())' in jsc)
check('pinned native Program bypasses page eval function', 'case RunAsAsyncFunction::No:' in sc and 'JSC::SourceProviderSourceType::Program' in sc)
check('pinned CSP disables current context eval', 'scriptExecutionContext->disableEval(m_lastPolicyEvalDisabledErrorMessage)' in csp)
check('public native evaluation uses Program page world', 'asAsyncFunction:NO withSourceURL:nil withArguments:nil forceUserGesture:YES inFrame:nil inWorld:WKContentWorld.pageWorld' in wk)
check('author runtime counts consistently zero', all(final['actual'][k] == 0 for k in ['SwiftCompiler','SDK','WK','Node','JVM','Java']))
check('author grammar inputs only two', final['actual']['treeSitterGrammarInputs'] == 2 and final['actual']['syntaxErrors'] == 0)

details = dict(checks=checks, oldFunctions=old, newFunctions=new, final=final_fact,
               candidate=fact(candidate_path), baseline=fact(baseline_path))
details_path = S / 'verification-v1.json'
details_path.write_text(json.dumps(details,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
failed = [c for c in checks if not c['passed']]
review = dict(
    schemaVersion=1,
    frozenUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
    reviewer='/root/login_info_v2_review',
    status='Approved as a test-only source characterization candidate; actual Apple compilation and WK assertions remain unexecuted.' if not failed else 'Not approved: independent source checks failed.',
    final=final_fact,
    verification=fact(details_path),
    verifier=fact(Path(__file__).resolve()),
    independentToolHistory=fact(S / 'native-parser-history-v1.json'),
    authorEvidence=final['evidence'],
    checkedSourceRoot=final['sourceRoot'],
    files=[dict(path=final['files'][0]['path'],baseline=fact(baseline_path),candidate=fact(candidate_path),diff=final['files'][0]['diff'])],
    totalChecks=len(checks), failedChecks=len(failed), failedCheckDetails=failed,
    remainingConfirmedFindings=[],
    sourceFindings=[
        dict(result='No confirmed P1/P2 in this bounded source candidate.',evidence='One test-only source. Exact composition is import WebKit plus one method plus one private MainActor helper; all 14 old tests and all old function bytes preserved.'),
        dict(result='No new production execution path or engine.',evidence='One test-owned nonpersistent WKWebView, two owned documents, native public callbacks. No production service/HTTP/JVM/owner changes and no current selector/control changes.'),
        dict(result='Ordered-expression assertions use page JSON encoding before Foundation object projection.',evidence='Captured original JSON.stringify in randomized page lexical const; evaluateJavaScript executes the known expression once. Exact UTF8 output checks insertion order, integer keys, nested arrays/objects, Unicode-distinct keys, undefined/nonfinite JSON behavior and one side effect. Native dictionary check deliberately only compares values.'),
        dict(result='Captured eval is a counterexample, not a compatibility fallback.',evidence='Two CSP modes assert actual native Program versus captured indirect eval behavior and global var/lexical/strict declaration differences. Pinned WebKit source supports the design inference but cannot establish the behavior of a shipped Apple SDK.'),
        dict(result='Callback lifecycle is finite and owned.',evidence='Actual identity-matched navigation terminals, one checked continuation per evaluation, close seals further evaluations and drains actual evaluation callbacks; success and throwing paths close. No settle sleeps or fake UIKit ACK.'),
    ],
    primaryEvidence=[
        dict(path='Source/JavaScriptCore/runtime/JSGlobalObjectFunctions.cpp',lines=[483,498],fact='Indirect eval checks the current evalEnabled state and throws EvalError; an earlier captured reference does not bypass this check.'),
        dict(path='Source/WebCore/bindings/js/ScriptController.cpp',lines=[665,695],fact='Native Program source is evaluated directly in the specified world, independently of the page window.eval property.'),
        dict(path='Source/WebCore/page/csp/ContentSecurityPolicy.cpp',lines=[325,342],fact='Policy processing disables eval on the current script context.'),
        dict(path='Source/WebKit/UIProcess/API/Cocoa/WKWebView.mm',lines=[1299,1314],fact='Public evaluateJavaScript chooses native Program in page world; callAsyncJavaScript is a distinct function path.'),
    ],
    reviewedPrimaryFileCount=10,
    actual=dict(authorTreeSitterGrammarInputs=2,authorSyntaxErrors=0,independentCompletedGrammarInputs=0,independentNativeParserTraversalFailed=True,SwiftCompiler=0,SDK=0,WK=0,Node=0,JVM=0,Java=0),
    counts=dict(oldNativeReaderMethods=14,newNativeReaderMethods=15,newTestDefinitions=1,oldRawFunctionsMatched=len(old),productionChanges=0,currentControlsChanged=0),
    retainedHistory='Both author preparation failures and two upstream 404 lookups are retained and distinguished from test/runtime failures. Independent optional native tree-sitter traversal exited 1 (three attempts, last faulthandler observed access violation); this tool failure was replaced by exact byte composition and direct raw-function SHA matching, not called a candidate compiler/test failure or a completed independent grammar pass. No successful suite was rerun.',
    limits=[
        'Approval covers the frozen test source, input identity and reviewable assertion design. None of the behavioral assertions or Swift APIs have been validated by an Apple compiler or WK runtime here.',
        'The pinned open-source WebKit commit is explanatory source evidence, not the implementation identity of a future SDK/device.',
        'This owned single-expression prototype does not support arbitrary scripts or establish product general WebJS compatibility. The production ordered-object result branch remains typed unsupported.',
        'No equivalence is claimed for arbitrary completion records, eval/with/dynamic parsing, exceptions, proxies/getters/toJSON, hostile intrinsic mutation or source bridge combinations.',
        'Finite inline scripts only. Navigation timeout is a failure; stopLoading is not a WebContent process termination guarantee. Infinite scripts or forced-cancel interruption remain outside these assertions.',
        'Standalone public WK characterization does not prove the existing product-service/JVM/Cookie/HTTP owner paths. Current App463/466, Package selections, controls and SDK execution are unchanged.',
    ],
    mutations=dict(ownIgnoredReviewOnly=True,peerSources=False,canonical=False,Git=False,cloud=False,tags=False),
)
out = S / 'review-v1.json'
out.write_text(json.dumps(review,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
print(json.dumps(dict(review=fact(out),totalChecks=len(checks),failedChecks=len(failed),failedCheckNames=[c['name'] for c in failed]),ensure_ascii=False))
if failed: sys.exit(1)
