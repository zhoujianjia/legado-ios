from pathlib import Path
import hashlib,json,zipfile
R=Path('F:/yuedu-reader');S=Path(__file__).parent
def fact(p):
 b=p.read_bytes();return {'path':str(p.relative_to(R)).replace('\\','/'),'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
base=R/'.build/original-local-html-webjs-step/implementation-v1/snapshot-v2/legado-runtime.jar'
assert fact(base)['sha256']=='89f77040ea6a0f4592ca00a059c25da76cece9d1520b541e144588e6b4c5003b'
C=S/'compile-v1/classes';compiled={p.relative_to(C).as_posix():p.read_bytes()for p in C.rglob('*.class')}
families={name.split('$')[0].removesuffix('.class')for name in compiled}
def owned(name):return any(name==f+'.class'or name.startswith(f+'$')for f in families)
out=S/'legado-runtime-base64.jar';retained=[];replaced=[];removed=[]
with zipfile.ZipFile(base)as z,zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED,compresslevel=9)as dst:
 for item in z.infolist():
  name=item.filename
  if name in compiled:
   dst.writestr(item,compiled[name]);replaced.append(name)
  elif owned(name):removed.append(name)
  else:
   data=z.read(name);dst.writestr(item,data);retained.append({'path':name,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()})
 for name,data in compiled.items():
  if name not in replaced:dst.writestr(name,data)
with zipfile.ZipFile(out)as z:
 assert not any(n.startswith('android/util/')for n in z.namelist())
 assert all(z.read(k)==v for k,v in compiled.items())
write=S/'jar-assembly.json';write.write_text(json.dumps({'base':fact(base),'candidate':fact(out),'compiledClasses':len(compiled),'fresh':[{'path':n,'bytes':len(v),'sha256':hashlib.sha256(v).hexdigest()}for n,v in sorted(compiled.items())],'removedStaleSourceFamilyClasses':removed,'retainedExactMembers':retained,'ruleMainClasses':sum(n.startswith(('io/legado/','io/yuedu/legado/'))and n.endswith('.class')for n in z.namelist()),'oracleBundled':False,'notFreshGradle':True},indent=2)+'\n',encoding='utf-8',newline='\n')
oracle=(S/'primary/android/Base64.java').read_text(encoding='utf-8')
lines=[line for line in oracle.splitlines(keepends=True)if not(line.strip().startswith('import android.compat.annotation.UnsupportedAppUsage;')or line.strip()=='@UnsupportedAppUsage'or line.strip()=='@android.ravenwood.annotation.RavenwoodKeepWholeClass')]
assert len(oracle.splitlines())-len(lines)==3
p=S/'oracle-source/android/util/Base64.java';p.parent.mkdir(parents=True,exist_ok=True);p.write_text(''.join(lines),encoding='utf-8',newline='\n')
(S/'oracle-transformation.json').write_text(json.dumps({'primary':fact(S/'primary/android/Base64.java'),'compiledOracle':fact(p),'changes':'Only remove Android platform annotation import and two annotations; the complete original encoder/decoder code remains byte-identical after reinserting those three original lines. Oracle classes are fixture-only and never bundled.','removedLines':[line for line in oracle.splitlines()if 'import android.compat.annotation.UnsupportedAppUsage;'in line or line.strip()in ['@UnsupportedAppUsage','@android.ravenwood.annotation.RavenwoodKeepWholeClass']]},indent=2)+'\n',encoding='utf-8',newline='\n')
print('JAR',fact(out),'COMPILED_CLASSES',len(compiled),'REMOVED',removed)
