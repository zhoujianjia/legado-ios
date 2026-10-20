from pathlib import Path
import hashlib,json
S=Path(__file__).parent; raw=(S/'factual-review.py').read_bytes()
(S/'factual-review-history-v1.json').write_text(json.dumps(dict(scriptBytes=len(raw),scriptSHA256=hashlib.sha256(raw).hexdigest(),reason='Package actual result exports passed/verbosePassed IDs, not verboseStarted IDs. Git bindings, source stamps, phase output hashes and24 XML IDs already checked. Remove nonexistent field assumption; no remote/local suites rerun.'),indent=2)+'\n',encoding='utf-8')
new=raw.decode().replace("==set(pkg['verboseStartedCaseIdentifiers'])",'')
(S/'factual-review-resume.py').write_text(new,encoding='utf-8',newline='\n')
exec(compile(new,str(S/'factual-review-resume.py'),'exec'),{'__file__':str(S/'factual-review-resume.py'),'__name__':'__main__'})
