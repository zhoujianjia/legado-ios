from pathlib import Path
import json,subprocess,sys,shutil
R=Path('F:/yuedu-reader');S=R/'.build/native-210-reader-repair-step';C=S/'incremental';out=C/'java-retry-v2';out.mkdir(exist_ok=True)
commands=json.loads((C/'retry/commands.json').read_text(encoding='utf-8'));history=[]
for name in ['compile-java.log','ordinary-java.log']:
 command=next(c['argv']for c in commands if c['log']==name)
 history.append({'argv':command,'log':name});(out/'commands.json').write_text(json.dumps(history,indent=2)+'\n',encoding='utf-8')
 p=subprocess.run(command,cwd=R,capture_output=True);(out/name).write_bytes(p.stdout+p.stderr);print(name,'exit',p.returncode,flush=True)
 if p.returncode:
  print((p.stdout+p.stderr).decode('utf-8',errors='replace').encode('ascii','backslashreplace').decode()[-5500:]);sys.exit(p.returncode)
