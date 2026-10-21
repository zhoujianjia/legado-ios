'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const crypto = require('node:crypto');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const source = path.join(root,'work/Modules/Core/RuleEngine/ModernParser/JS/LegadoHeadlessWebView.swift');
const bytes = fs.readFileSync(source);
const swift = bytes.toString('utf8');
const evaluator = swift.slice(swift.indexOf('private func evaluateOriginal('), swift.indexOf('private func originalNavigation('));
assert(evaluator.includes('view.evaluateJavaScript(script)'));
assert(evaluator.includes('contentWorld: .defaultClient'));
assert(evaluator.includes('try await Self.validateOriginalCompletion'));
const builder = swift.slice(swift.indexOf('nonisolated private static func originalEvaluationScript('), swift.indexOf('nonisolated private static func originalResultScript('));
assert(!builder.includes('(0,eval)') && !builder.includes('JSON.stringify'));
assert(builder.includes('return script'));
const isolated = vm.createContext({});
const encode = value => {
  isolated.value = value;
  return vm.runInContext('JSON.stringify(value)', isolated);
};
const cases = [];
function test(name, body) { body(); cases.push(name); }
test('actual null and undefined retry sentinels remain distinct from quoted strings', () => {
  const page = vm.createContext({});
  assert.equal(encode(vm.runInContext('null',page)), 'null');
  const missing = vm.runInContext('undefined',page);
  assert.equal(encode(missing == null ? null : missing), 'null');
  assert.equal(encode(vm.runInContext("''",page)), '""');
  assert.equal(encode(vm.runInContext("'null'",page)), '"null"');
});
test('native global completion and var state survive retries', () => {
  const page = vm.createContext({});
  const script = "var retries=(typeof retries==='undefined'?0:retries)+1; if(retries<2){null}else{'ready'}";
  assert.equal(encode(vm.runInContext(script,page)), 'null');
  assert.equal(encode(vm.runInContext(script,page)), '"ready"');
  assert.equal(vm.runInContext('retries',page),2);
});
test('page eval and JSON overrides cannot select native execution or isolated encoder', () => {
  const page = vm.createContext({});
  vm.runInContext("eval=function(){throw new Error('page eval was selected')};JSON.stringify=function(){throw new Error('page JSON was selected')}",page);
  const completion = vm.runInContext("var state='original';state+'-completion'",page);
  assert.equal(encode(completion),'"original-completion"');
  assert.throws(() => vm.runInContext("(0,eval)('state')",page),/page eval was selected/);
  assert.throws(() => vm.runInContext("JSON.stringify(state)",page),/page JSON was selected/);
});
test('captured eval is not proof against an external eval restriction', () => {
  // Node's VM code-generation policy is NOT WK CSP. This counterexample only
  // prevents treating captured eval as evidence of native-script equivalence.
  const restricted = vm.createContext({}, {codeGeneration:{strings:false,wasm:false}});
  vm.runInContext('var capturedEval=eval;',restricted);
  assert.throws(() => vm.runInContext("capturedEval(\"'would-work-natively'\")",restricted),/Code generation from strings disallowed/);
  assert.equal(vm.runInContext("'would-work-natively'",restricted),'would-work-natively');
});
test('WebKit style intrinsic JSON contract covers nonfinite and special numbers', () => {
  assert.equal(encode(NaN),'null'); assert.equal(encode(Infinity),'null');
  assert.equal(encode(-Infinity),'null'); assert.equal(encode(-0),'0');
  assert.equal(encode(1e20),'100000000000000000000');
  assert.equal(encode(1e21),'1e+21'); assert.equal(encode(1e-7),'1e-7');
  assert.equal(encode([undefined,null,NaN,1e21,-0,'']), '[null,null,null,1e+21,0,""]');
});
const objectExamples = [];
test('original object key order and nested object arrays remain explicit pending cases', () => {
  const page = vm.createContext({});
  for (const script of ['({b:2,a:1})','({10:"ten",2:"two",z:3,a:4})','[{b:2,a:1}]']) {
    objectExamples.push({script, originalRaw:encode(vm.runInContext(script,page)), candidate:'typed UNSUPPORTED_CAPABILITY; object-order route pending'});
  }
  assert.equal(objectExamples[0].originalRaw,'{"b":2,"a":1}');
  assert.equal(objectExamples[1].originalRaw,'{"2":"two","10":"ten","z":3,"a":4}');
  assert.equal(objectExamples[2].originalRaw,'[{"b":2,"a":1}]');
  assert(swift.includes('Ordered object completion requires an unimplemented original WebKit result route'));
  assert(swift.includes('pending.append(contentsOf: array.map'));
});
test('raw string escapes and array slots are encoded by the intrinsic encoder', () => {
  assert.equal(encode('line\nquote"slash\\'), '"line\\nquote\\"slash\\\\"');
  assert.equal(encode([1,,'',true,false]),'[1,null,"",true,false]');
});
const report = {status:'passed',cases:cases.length,names:cases,
  source:{path:source,bytes:bytes.length,sha256:crypto.createHash('sha256').update(bytes).digest('hex')},
  objectCounterexamples:objectExamples,
  actualNode:true,SwiftSDK:0,WK:0,JNI:0,actualCSP:0,
  scope:'New focused JavaScript completion/isolated intrinsic contract and explicit object-order gaps only. Node VM restrictions are not WK CSP or native serialization acceptance.'};
fs.writeFileSync(path.join(__dirname,'native-completion-contract.json'),JSON.stringify(report,null,2)+'\n');
process.stdout.write(JSON.stringify({status:report.status,cases:report.cases,objectCounterexamples:objectExamples.length,SwiftSDK:0,WK:0,JNI:0,actualCSP:0})+'\n');
