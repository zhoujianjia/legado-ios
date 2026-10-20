from pathlib import Path
import datetime,hashlib,json
S=Path(__file__).parent;p=S/'interface-v4.json';assert not p.exists()
m=json.loads((S/'interface-v3.json').read_text(encoding='utf-8'));m['recordedUTC']=datetime.datetime.now(datetime.timezone.utc).isoformat();m['supersedes']='interface-v3.json retained immutable; only explicit parameter limits/onlyDisk semantics clarified'
m['wire']['webJsRequest']['input']='{pageId:String,method:String,params:[String?],timeoutMs:Int<=30000,function:String?,requestId:String?}; request accepts <=64 wire params and uses first6 per original Array(6); direct finite methods <=6.'
m['wire']['webJsRequest']['directCacheCalls']='Existing cache String/memory operations preserve nullable/void returns. cache.get(key,onlyDisk=false) forwards its actual Boolean to existing RuleCache.get(key,Boolean), distinguishing disk from a memory overlay; no silently ignored second argument.'
m['productionStarted']=True
p.write_text(json.dumps(m,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n');b=p.read_bytes();print(len(b),hashlib.sha256(b).hexdigest())
