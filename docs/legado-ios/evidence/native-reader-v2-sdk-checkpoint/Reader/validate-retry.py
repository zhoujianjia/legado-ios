from pathlib import Path
import json,subprocess,sys
R=Path('F:/yuedu-reader');S=R/'.build/native-210-reader-repair-step';C=S/'incremental';out=C/'retry';out.mkdir(exist_ok=True)
commands=json.loads((C/'commands.json').read_text(encoding='utf-8'));history=[]
def run(command,name):
 history.append({'argv':command,'log':name});(out/'commands.json').write_text(json.dumps(history,indent=2)+'\n',encoding='utf-8')
 p=subprocess.run(command,cwd=R,capture_output=True);(out/name).write_bytes(p.stdout+p.stderr);print(name,'exit',p.returncode,flush=True)
 if p.returncode:
  print((p.stdout+p.stderr).decode('utf-8',errors='replace').encode('ascii','backslashreplace').decode()[-5500:]);sys.exit(p.returncode)
for name in ['compile-tests.log','compile-java.log']:
 run(next(c['argv']for c in commands if c['log']==name),name)
selected=next(c['argv']for c in commands if c['log']=='junit-selected.log')
selected[-1]=str(out/'actual-tests.xml');selected.append('lastChapterDirectoryLookupKeepsSingleChapterVariableGrantAndCurrentRestore')
run(selected,'junit-selected.log')
java=selected[:selected.index('-cp')+1]+[selected[selected.index('-cp')+1],'OrdinaryReaderRepairSmoke']
run(java,'ordinary-java.log')
