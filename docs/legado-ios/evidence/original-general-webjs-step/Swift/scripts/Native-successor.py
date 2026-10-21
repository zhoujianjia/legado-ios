from pathlib import Path
import hashlib,json
R=Path.cwd(); S=Path(__file__).parent; P=R/'.build/original-general-webjs-swift-implementation-step'; f=json.loads((P/'final-v1.json').read_bytes())
path='Tests/iOS/LegadoNativeOriginalReaderTests.swift'; row=next(r for r in f['files'] if r['path']==path)
p=R/f['candidateRoot']/path; raw=p.read_bytes(); assert dict(bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest())==row['candidate']
old='preview.ruleSearch.name = "@webjs:if(typeof cache!==\'object\')throw new Error(\'missing original cache\');document.querySelector(\'a\').textContent"'
new='preview.ruleSearch.name = "tag.a@text@webjs:if(typeof cache!==\'object\')throw new Error(\'missing original cache\');document.body.textContent"'
text=raw.decode(); assert text.count(old)==1; body=text.replace(old,new).encode()
target=S/'work'/path; target.parent.mkdir(parents=True,exist_ok=True); assert not target.exists(); target.write_bytes(body)
report=dict(version=1,parent=dict(path=str(P/'final-v1.json'),bytes=(P/'final-v1.json').stat().st_size,sha256=hashlib.sha256((P/'final-v1.json').read_bytes()).hexdigest()),scope='Single newly authored Native fixture line correction before any SDK execution. Original13 methods unchanged; selected definition count unchanged.',path=path,baseline=row['candidate'],candidate=dict(bytes=len(body),sha256=hashlib.sha256(body).hexdigest()),reason='AnalyzeRule prior item is a parent-linked Jsoup Element. Actual ordinary JVM found GSON cyclic serialization unsupported before WK; select original tag.a@text first to supply an original String result/HTML. The actual browser body text remains pending Native SDK execution.',old=old,new=new,testsRerun=0,SDK=0)
(S/'candidate-v1.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n'); print(json.dumps(report['candidate']))
