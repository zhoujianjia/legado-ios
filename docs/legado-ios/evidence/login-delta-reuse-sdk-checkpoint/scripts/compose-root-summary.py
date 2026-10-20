from pathlib import Path
import hashlib,json,sys,shutil,ast
s=Path(__file__).resolve().parents[1];r=s.parents[1]
assert len(sys.argv)==3,'Frozen Root v2 manifest path and sha256 required'
manifest=r/sys.argv[1];data=manifest.read_bytes()
assert hashlib.sha256(data).hexdigest()==sys.argv[2]
binding=json.loads(data);repair=manifest.parent
previous=json.loads((r/binding['previousVersion']['path']).read_text(encoding='utf-8'))
assert len(binding['files'])==2
history=s/'preparation/history/before-root-summary';history.mkdir(parents=True,exist_ok=True)
def once(text,old,new):
 assert text.count(old)==1,(old,text.count(old))
 return text.replace(old,new)
for entry in binding['files']:
 rel=entry['path'];b=s/'rawbaseline'/rel;candidate=repair/'work'/rel;ours=s/'work'/rel
 original=next(row for row in previous['files'] if row['path']==rel)
 for path,expected in [(b,original['baseline']),(repair.parent/'work'/rel,entry['baselineSelectorV1']),(candidate,entry['candidate'])]:
  raw=path.read_bytes();assert len(raw)==expected['bytes'] and hashlib.sha256(raw).hexdigest()==expected['sha256'],path
 backup=history/Path(rel).name;assert not backup.exists();shutil.copyfile(ours,backup)
 old=ours.read_text(encoding='utf-8');new=candidate.read_text(encoding='utf-8')
 if Path(rel).name=='renewal-probe-tools.py':
  start=old.index('CURRENTCORE_DELTA_REUSE_INPUTS = (');end=old.index('\n\n\ndef selection_mode()',start)
  marker='assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 322'
  new=once(new,marker,marker+'\n'+old[start:end])
  new=once(new,'The independent explicitly selected currentcore SwiftPM loginui selection is22 methods with15 actual compilation inputs plus7 controls. It must execute freshly for these changed inputs; historical10/default16/publicbatch17/effects18 modes retain their exact sets and are not included in native466.',
   'The independent explicitly selected currentcore SwiftPM deltareuse selection is23 methods with15 actual compilation inputs plus7 controls. It must execute freshly for these changed inputs; historical10/default16/publicbatch17/effects18/loginui22 modes retain their exact sets and are not included in native466.')
 else:
  extra=old[old.index('class DeltaReuseCheckpointSelectionTests'):old.index('if __name__ == "__main__":')]
  new=new.replace(',322)',',324)').replace(', 322)',', 324)')
  new=new.replace("&& 'loginui' || ''","&& 'deltareuse' || ''")
  new=new.replace('Package source-only selection is22','Package source-only selection is23').replace('Execute22 independent current-source macOS package XCTest cases','Execute23 independent current-source macOS package XCTest cases')
  new=once(new,'if __name__ == "__main__":',extra+'if __name__ == "__main__":')
 ast.parse(new);ours.write_text(new,encoding='utf-8',newline='\n')
print('Composed exact Root v2 selector+summary repair, retaining delta-source binding/mode/new guards; prior selector-only candidate saved.')
