from pathlib import Path
import hashlib,json,re,subprocess
R=Path.cwd(); base=R/'docs/legado-ios/evidence/sdk-fc3-runtime-repairs-step'; p=R/'docs/legado-ios/core-sdk-fc3-runtime-repairs-step.json'; report=json.loads(p.read_bytes())
def fact(p):
    b=p.read_bytes(); return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
changed=[]
for row in report['preservedEvidence']:
    target=R/row['path']
    if '/TLS/primary/' not in row['path']: continue
    raw=target.read_bytes(); text=raw.decode('utf-8')
    new=re.sub(r'(?m)^[ \t]+',lambda m:m.group().expandtabs(8),text).encode()
    if new!=raw:
        target.write_bytes(new); row.update(fact(target)); row['normalization']='Documentation-only upstream source: UTF8/LF/trailing whitespace and leading indent tabs expanded to8columns; original raw byte hashes retained. Production sources and frozen raw primary unchanged.'; changed.append(row['path'])
archive=base/'scripts/fix-fc3-runtime-evidence-indentation.py'; archive.write_bytes(Path(__file__).read_bytes())
report['preservedEvidence'].append(dict(path=archive.relative_to(R).as_posix(),**fact(archive),original=dict(path='.build/fix-fc3-runtime-evidence-indentation.py',**fact(Path(__file__))),normalization='Exact UTF8/LF'))
report['archiveHistory']=[dict(failure='First exact staging diff-check rejected13 upstream mixed-indent lines; no commit was made and push was up-to-date.',repair='Only documentation primary indentation normalized. Original frozen raw source/evidence facts preserved; no production or test source changed.',modifiedDocumentationFiles=changed)]
p.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
rosterPath=R/'.build/fc3-runtime-repairs-canonical-roster.json'; rows=json.loads(rosterPath.read_bytes()); paths=[R/r['path'] for r in rows]+[archive]
rosterPath.write_text(json.dumps([dict(path=x.relative_to(R).as_posix(),**fact(x)) for x in paths],indent=2)+'\n',encoding='utf-8',newline='\n')
print(json.dumps(dict(documentationOnlyFiles=len(changed),productionSourceChanges=0,reviewedPaths=len(paths))))
