from pathlib import Path
import json,shutil,hashlib
S=Path(__file__).parent;W=S/'work';target=S/'combined-classes-v2';assert not target.exists()
shutil.copytree(S/'compile-attempt5/classes',target)
added=list((S/'compile-attempt6/classes').rglob('*.class'));assert added
assert all(p.name.startswith('OriginalWebJsPages')for p in added)
for p in target.rglob('OriginalWebJsPages*.class'):p.unlink()
for p in added:
 out=target/p.relative_to(S/'compile-attempt6/classes');out.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,out)
first=json.loads((S/'compile-attempt5/commands.json').read_text());second=json.loads((S/'compile-attempt6/commands.json').read_text())
assert first['exitCode']==0 and second['exitCode']==0
combined=dict(exitCode=0,compiler=second['compiler'],sources=[r for r in first['sources']if not r['path'].endswith('OriginalWebJsPageRuntime.kt')]+second['sources'])
assert len(combined['sources'])==7
source=(S/'assemble-ordinary.py').read_text(encoding='utf-8')
source=source.replace("E=S/'ordinary-v2'","E=S/'ordinary-v4'").replace("classes=S/'compile-attempt3/classes'","classes=S/'combined-classes-v2'").replace("compiled=json.loads((S/'compile-attempt3/commands.json').read_text());assert compiled['exitCode']==0","compiled=combined;assert compiled['exitCode']==0")
exec(compile(source,__file__,'exec'))
bindingPath=S/'ordinary-v4/production-binding.json';binding=json.loads(bindingPath.read_text())
binding['kind']='Precise combined seven-source K2 overlay: six main source outputs retained exact attempt5; only review-P2 Page source recompiled attempt6 against bound072f JAR. NOT full Gradle.'
binding['actualCompilationSteps']=[dict(path=f'compile-attempt{i}/commands.json',bytes=len((S/f'compile-attempt{i}/commands.json').read_bytes()),sha256=hashlib.sha256((S/f'compile-attempt{i}/commands.json').read_bytes()).hexdigest())for i in (5,6)]
bindingPath.write_text(json.dumps(binding,indent=2)+'\n',encoding='utf-8',newline='\n')
