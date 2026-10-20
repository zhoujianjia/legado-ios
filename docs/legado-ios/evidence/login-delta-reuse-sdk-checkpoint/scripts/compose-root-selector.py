from pathlib import Path
import hashlib,json,shutil,difflib,ast

s=Path(__file__).resolve().parents[1]
root=s.parents[1]
repair=root/'.build/currentcore-swift-testing-filter-repair'
manifest=repair/'preparation-v1.json'
raw=manifest.read_bytes()
assert len(raw)==2255 and hashlib.sha256(raw).hexdigest()=='9479cf8a28d3b976d6b38df09710e35a973f6e58b1f68ee0176bdd5c93349c6e'
binding=json.loads(raw)
history=s/'preparation/history/before-root-selector'
history.mkdir(parents=True,exist_ok=True)
def once(text,old,new):
 assert text.count(old)==1,(old,text.count(old))
 return text.replace(old,new)
for entry in binding['files']:
 rel=entry['path'];b=s/'rawbaseline'/rel;candidate=repair/'work'/rel;ours=s/'work'/rel
 for path,key in [(b,'baseline'),(candidate,'candidate')]:
  data=path.read_bytes();assert len(data)==entry[key]['bytes'] and hashlib.sha256(data).hexdigest()==entry[key]['sha256'],path
 backup=history/Path(rel).name
 assert not backup.exists()
 shutil.copyfile(ours,backup)
 old=ours.read_text(encoding='utf-8');new=candidate.read_text(encoding='utf-8')
 if Path(rel).name=='renewal-probe-tools.py':
  start=old.index('CURRENTCORE_DELTA_REUSE_INPUTS = (')
  end=old.index('\n\n\ndef selection_mode()',start)
  group=old[start:end]
  marker='assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 322'
  new=once(new,marker,marker+'\n'+group)
  old_scope='The independent explicitly selected currentcore SwiftPM loginui selection is22 methods with15 actual compilation inputs plus7 controls. It must execute freshly for these changed inputs; historical10/default16/publicbatch17/effects18 modes retain their exact sets and are not included in native466.'
  new_scope='The independent explicitly selected currentcore SwiftPM deltareuse selection is23 methods with15 actual compilation inputs plus7 controls. It must execute freshly for these changed inputs; historical10/default16/publicbatch17/effects18/loginui22 modes retain their exact sets and are not included in native466.'
  new=once(new,old_scope,new_scope)
 else:
  extra=old[old.index('class DeltaReuseCheckpointSelectionTests'):old.index('if __name__ == "__main__":')]
  extra=once(extra,"'-only-testing:yuedu appTests/' + probe.SDK_REQUIRED_CASE, command)","'-only-testing:yuedu appTests/' + probe.currentcore_test_selector(probe.SDK_REQUIRED_CASE), command)")
  new=new.replace(',322)',',324)').replace(', 322)',', 324)')
  new=new.replace("&& 'loginui' || ''","&& 'deltareuse' || ''")
  new=new.replace('Package source-only selection is22','Package source-only selection is23').replace('Execute22 independent current-source macOS package XCTest cases','Execute23 independent current-source macOS package XCTest cases')
  new=once(new,'if __name__ == "__main__":',extra+'if __name__ == "__main__":')
 ast.parse(new)
 ours.write_text(new,encoding='utf-8',newline='\n')
 diff=''.join(difflib.unified_diff(b.read_text(encoding='utf-8').splitlines(True),new.splitlines(True),fromfile='baseline/'+rel,tofile='candidate/'+rel))
 target=s/'diffs'/Path(rel+'.diff');target.parent.mkdir(parents=True,exist_ok=True);target.write_text(diff,encoding='utf-8',newline='\n')
print('Composed exact Root selector patch with isolated delta group and guards; saved both prior candidate files.')
