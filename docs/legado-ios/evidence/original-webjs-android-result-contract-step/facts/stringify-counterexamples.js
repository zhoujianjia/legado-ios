"use strict";
const records=[];
function run(id,create){globalThis.counter=0;try{const raw=JSON.stringify(create());records.push({id,raw:raw===undefined?null:raw,rawWasUndefined:raw===undefined,effects:globalThis.counter});}catch(error){records.push({id,error:error.name,effects:globalThis.counter});}}
run('ordinary-key-order',()=>({b:2,a:1}));
run('object-nonfinite-vs-array',()=>({b:NaN,c:Infinity,a:[undefined,NaN,Infinity]}));
run('toJSON-is-observable',()=>({a:1,toJSON(){globalThis.counter++;return 7;}}));
run('throwing-getter',()=>({get a(){globalThis.counter++;throw Error('owned synthetic getter');},b:2}));
run('cycle',()=>{const value={};value.self=value;return value;});
run('outside-int32-integral',()=>2147483648);
process.stdout.write(JSON.stringify({runtime:process.version,scope:'Actual JavaScript JSON.stringify counterexamples only; not Android/V8ValueConverter or Apple execution',records},null,2)+'\n');
