
const vm = require('node:vm');
const assert = require('node:assert/strict');
const memory = new Map();
const seen = [];
let closed = false;
const context = vm.createContext({console,Promise,Error});
context.window = context;
context.prompt = (_channel,payload) => {
    if (closed) return null;
    const call = JSON.parse(payload); seen.push(call.method);
    const p = call.params;
    if (call.method === 'cache.getFromMemory') return JSON.stringify({kind:'string',value:memory.get(p[0]) ?? null});
    if (call.method === 'cache.deleteMemory') {memory.delete(p[0]);return JSON.stringify({kind:'void'});}
    if (call.method === 'cache.putMemory') {memory.set(p[0],p[1]);return JSON.stringify({kind:'void'});}
    if (call.method === 'java.getStringList') return JSON.stringify({kind:'stringList',values:['one','two']});
    if (call.method === 'java.get') return JSON.stringify({kind:'string',value:''});
    return JSON.stringify({error:'UNSUPPORTED_CAPABILITY'});
};
context.webkit = {messageHandlers:{yueduOriginalWebJS:{postMessage: async (payload) => {
    const call = JSON.parse(payload);
    assert.equal(call.method,'request'); assert.equal(call.function,'run');
    if (call.params[0] === 'cancel') {closed=true;throw new Error('CANCELLED');}
    const success = call.params[0] !== 'error';
    memory.set(call.requestId, success ? (call.params[0] === 'null' ? 'null' : '42') : 'synthetic-script-error');
    return JSON.stringify({kind:'callback',requestId:call.requestId,success});
}}}};

vm.runInContext("(function() {\n    function params(args) { return Array.from(args, v => v == null ? null : String(v)); }\n    function sync(method, args) {\n        const raw = window.prompt(\"__yuedu_source_java_bridge__\", JSON.stringify({method:method,params:params(args)}));\n        if (raw === null) throw new Error('BROWSER_CANCELLED');\n        const reply = JSON.parse(raw);\n        if (reply.error) throw new Error(reply.error);\n        if (reply.kind === 'void') return undefined;\n        if (reply.kind === 'stringList') return reply.values == null ? null : reply.values;\n        return reply.value == null ? null : reply.value;\n    }\n    const cache = {};\n    ['put','putMemory','get','getFromMemory','delete','deleteMemory'].forEach(function(name) {\n        cache[name] = function() { return sync('cache.' + name, arguments); };\n    });\n    const java = {};\n    ['put','get','ajax','connect','getString','getStringList','upConfig'].forEach(function(name) {\n        java[name] = function() { return sync('java.' + name, arguments); };\n    });\n    java.request = function(fn, values, id) {\n        const requestId = String(id);\n        // Returning from the native reply releases its child before the\n        // original callback synchronously reenters cache prompt methods.\n        void window.webkit.messageHandlers.yueduOriginalWebJS\n            .postMessage(JSON.stringify({method:'request',function:String(fn),params:params(values),requestId:requestId}))\n            .then(function(raw) {\n                const reply = JSON.parse(raw);\n                if (reply.kind !== 'callback' || reply.requestId !== requestId || typeof reply.success !== 'boolean') {\n                    throw new Error('INVALID_RESULT');\n                }\n                const complete = window[\"nativeResult\"];\n                if (typeof complete === 'function') complete(requestId, reply.success);\n            }).catch(function(error) {\n                // The existing cache remains the sole result channel,\n                // including a transport refusal before JVM registration.\n                try {\n                    cache.putMemory(requestId, String(error));\n                    const complete = window[\"nativeResult\"];\n                    if (typeof complete === 'function') complete(requestId, false);\n                } catch (_) {\n                    // Cancellation cannot write a late result cache.\n                    // Reject/remove the original pending callback only;\n                    // no successful result or replacement store exists.\n                    if (typeof JSBridgeCallbacks !== 'undefined') {\n                        const pending = JSBridgeCallbacks[requestId];\n                        if (pending) { pending.reject('CANCELLED'); delete JSBridgeCallbacks[requestId]; }\n                    }\n                }\n            });\n    };\n    function nativeSurface(target, prefix) {\n        return new Proxy(target, { get: function(object, name) {\n            if (typeof name !== 'string' || name === 'then') return undefined;\n            if (Object.prototype.hasOwnProperty.call(object, name)) return object[name];\n            // Unported methods reach the exact typed JVM refusal;\n            // no generic HTTP, JS evaluator or successful stub exists.\n            return function() { return sync(prefix + '.' + name, arguments); };\n        }});\n    }\n    window[\"nativeJava\"] = nativeSurface(java, 'java');\n    window[\"nativeCache\"] = nativeSurface(cache, 'cache');\n})();",context);
vm.runInContext("\nconst requestId = n => 'req_' + n + '_' + Date.now() + '_' + Math.random().toString(36).slice(-3);\nconst JSBridgeCallbacks = {};\nconst java = window.nativeJava;\ndelete window.nativeJava;\nconst cache = window.nativeCache;\ndelete window.nativeCache;\nfunction run(jsCode) {\n    return new Promise((resolve, reject) => {\n        const id = requestId(\"run\");\n        JSBridgeCallbacks[id] = { resolve, reject };\n        java.request(\"run\", [String(jsCode)], id);\n    });\n};\nwindow.nativeResult = function(id, success) {\n    const callBack = JSBridgeCallbacks[id];\n    if (callBack) {\n        const result = cache.getFromMemory(id);\n        cache.deleteMemory(id);\n        if (success) {\n            callBack.resolve(result);\n        } else {\n            callBack.reject(result);\n        }\n        delete JSBridgeCallbacks[id];\n    }\n};",context);

(async function() {
    assert.equal(await vm.runInContext("run('ok')",context),'42');
    assert.equal(await vm.runInContext("run('null')",context),'null');
    const failure = await vm.runInContext("run('error').then(()=>({unexpected:true}),error=>error)",context);
    assert.equal(failure,'synthetic-script-error');
    assert.equal(vm.runInContext("cache.getFromMemory('missing')",context),null);
    assert.equal(vm.runInContext("java.get('missing')",context),'');
    assert.equal(JSON.stringify(vm.runInContext("java.getStringList('rule')",context)),JSON.stringify(['one','two']));
    assert.throws(()=>vm.runInContext("java.post('unsupported')",context), /UNSUPPORTED_CAPABILITY/);
    assert.equal(memory.size,0);
    assert.equal(vm.runInContext('Object.keys(JSBridgeCallbacks).length',context),0);
    const cancelled = await vm.runInContext("run('cancel').then(()=>({unexpected:true}),error=>error)",context);
    assert.equal(cancelled,'CANCELLED');
    assert.equal(memory.size,0);
    assert.equal(vm.runInContext('Object.keys(JSBridgeCallbacks).length',context),0);
    assert.equal(seen.filter(x=>x==='cache.deleteMemory').length,3);
    console.log(JSON.stringify({status:'passed',cases:5,actualOriginalJS2:true,
        completedPromises:4,callbackKeys:0,resultMemoryEntries:0,
        JVM:0,WK:0,SwiftSDK:0,scope:'Node contract fixture only'}));
})().catch(error=>{console.error(error);process.exitCode=1;});
