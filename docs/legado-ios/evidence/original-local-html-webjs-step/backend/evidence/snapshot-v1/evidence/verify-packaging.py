from pathlib import Path
import hashlib,importlib.util,json,shutil,unittest,zipfile
R=Path('F:/yuedu-reader');S=Path(__file__).parent;W=S/'work';V=S/'validation-root';A=R/'.build/consolidated-header-v2-browser-source-step/validation-root'
assert V.resolve().is_relative_to(S.resolve())and not V.exists()
shutil.copytree(A,V)
for p in W.rglob('*'):
 if p.is_file():target=V/p.relative_to(W);target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,target)
def fact(p):b=p.read_bytes();return dict(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
def load(name,path):
 spec=importlib.util.spec_from_file_location(name,path);mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod);return mod
def write(p,v):p.write_text(json.dumps(v,indent=2)+'\n',encoding='utf-8',newline='\n')
m=json.loads((W/'Packages/LegadoRuntime/vendor/original-rule/manifest.json').read_text())
for row in m['portedSources']:assert fact(V/row['path'])=={k:row[k]for k in ('bytes','sha256')},row['path']
tool=load('webjs_packaging',R/'scripts/reader-experience/runtime-packaging.py');tool.REPO=V
jar=S/'ordinary-v2/legado-runtime-local-webjs.jar';inspection=tool.inspect_jar(jar)
with zipfile.ZipFile(jar)as z:
 assert z.testzip()is None
 assert not any(n.startswith(('org/junit/','org/hamcrest/'))or'OrdinaryLocalWebJs'in n for n in z.namelist())
 binding=json.loads((S/'ordinary-v2/production-binding.json').read_text())
 rows=binding['retainedClasses']+binding['recompiledClasses']
 for row in rows:assert dict(bytes=len(z.read(row['path'])),sha256=hashlib.sha256(z.read(row['path'])).hexdigest())=={k:row[k]for k in ('bytes','sha256')}
write(S/'ordinary-jar-inspected.json',dict(jar=fact(jar),inspection=inspection,classes=[{k:row[k]for k in ('path','bytes','sha256')}for row in rows],productionClassCount=len(rows),recompiledClassCount=len(binding['recompiledClasses']),retainedClassCount=len(binding['retainedClasses']),portedSources=len(m['portedSources'])))
tests=load('webjs_packaging_tests',R/'scripts/reader-experience/test-runtime-packaging.py');tests.packaging.REPO=V
with(S/'packaging-tests.log').open('w',encoding='utf-8')as out:result=unittest.TextTestRunner(stream=out,verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(tests.OrdinaryJarGuardTests))
assert result.wasSuccessful()and result.testsRun==6
print(json.dumps(dict(packagingGuards=6,portedSources=59,productionClasses=len(rows),JVMJUnit=0,SwiftSDK=0,JNI=0,UIKit=0)))
