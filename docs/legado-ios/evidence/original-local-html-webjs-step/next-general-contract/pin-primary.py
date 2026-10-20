from pathlib import Path
from zipfile import ZipFile
import hashlib, json
R=Path('F:/yuedu-reader'); S=R/'.build/original-general-webjs-step'
archive=Path('F:/legado-master.zip'); h=hashlib.sha256()
with archive.open('rb') as stream:
    for chunk in iter(lambda:stream.read(1024*1024),b''): h.update(chunk)
assert h.hexdigest()=='724dedcac2427cd1f02ca00af1eab7156146e6d9d3141ca4c92042d04ed7bcdd'
members=[
    'app/src/main/java/io/legado/app/help/JsExtensions.kt',
    'app/src/main/java/io/legado/app/help/http/BackstageWebView.kt',
    'app/src/main/java/io/legado/app/help/webView/WebJsExtensions.kt',
    'app/src/main/java/io/legado/app/help/source/SourceVerificationHelp.kt',
    'app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeRule.kt',
    'app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeUrl.kt',
    'app/src/androidTest/java/io/legado/app/help/http/BackstageWebViewLifecycleTest.kt',
]
rows=[]
with ZipFile(archive) as z:
    for member in members:
        data=z.read('legado-master/'+member); p=S/'primary'/member
        p.parent.mkdir(parents=True,exist_ok=True); p.write_bytes(data)
        rows.append(dict(path=p.relative_to(R).as_posix(),member='legado-master/'+member,
                         bytes=len(data),sha256=hashlib.sha256(data).hexdigest()))
record=dict(status='pinned-primary-members-only-not-implementation-or-runtime-acceptance',
    archive=dict(path=str(archive),bytes=archive.stat().st_size,sha256=h.hexdigest()),files=rows)
(S/'primary-binding-v1.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8',newline='\n')
print(json.dumps(dict(primaryMembers=len(rows),archiveSHA256Matched=True,newProductionSources=0)))
