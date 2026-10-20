from pathlib import Path
import shutil,json,hashlib
r=Path('F:/yuedu-reader');s=r/'.build/native-210-reader-repair-step';w=s/'work';v=s/'validation-root';target=v/'Packages/LegadoRuntime'
manifest=w/'Packages/LegadoRuntime/vendor/original-rule/manifest.json';m=json.loads(manifest.read_text(encoding='utf-8'))
path='Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RuleWebBookState.kt'
row=next(x for x in m['portedSources'] if x['path']==path);data=(w/path).read_bytes();row.update(bytes=len(data),sha256=hashlib.sha256(data).hexdigest())
manifest.write_text(json.dumps(m,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
if not target.exists():shutil.copytree(r/'Packages/LegadoRuntime',target,ignore=shutil.ignore_patterns('build','.gradle','.build'))
for p in (w/'Packages/LegadoRuntime').rglob('*'):
 if p.is_file():
  dest=target/p.relative_to(w/'Packages/LegadoRuntime');dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,dest)
build=target/'jvm/build.gradle.kts';raw=build.read_text(encoding='utf-8')
if '// Native210 bounded validation worker only.' not in raw:
 raw+='\n// Native210 bounded validation worker only.\ntasks.withType<Test>().configureEach {\n    maxHeapSize = "128m"\n    jvmArgs("-XX:+UseSerialGC")\n}\n';build.write_text(raw,encoding='utf-8',newline='\n')
for row in m['portedSources']:
 p=v/row['path'];raw=p.read_bytes();assert len(raw)==row['bytes'] and hashlib.sha256(raw).hexdigest()==row['sha256'],row['path']
print(json.dumps({'portedSources':len(m['portedSources']),'updatedOnly':path,'validationRoot':str(v)}))
