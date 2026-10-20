from pathlib import Path
import hashlib,json,subprocess,time
S=Path(__file__).parent;argv=['C:/Python312/python.exe','-B',str(S/'validate.py')];t=time.monotonic();p=subprocess.run(argv,capture_output=True);log=S/'validation.log';log.write_bytes(p.stdout+p.stderr)
(S/'validation-command.json').write_text(json.dumps({'argv':argv,'exitCode':p.returncode,'seconds':round(time.monotonic()-t,3),'log':{'bytes':log.stat().st_size,'sha256':hashlib.sha256(log.read_bytes()).hexdigest()}},indent=2)+'\n',encoding='utf-8',newline='\n');print(p.stdout.decode('utf-8')[-2500:]);print(p.stderr.decode('utf-8')[-2500:]);raise SystemExit(p.returncode)
