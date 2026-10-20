from pathlib import Path
import hashlib,json
S=Path(__file__).parent; p=S/'review.py'; raw=p.read_bytes()
(S/'initial-review-shape-failure.json').write_text(json.dumps(dict(scriptBytes=len(raw),scriptSHA256=hashlib.sha256(raw).hexdigest(),failedCheck='old Hutool implementation exact',reason='Compared changed explanatory file comment as though it were decoder body. Prior all evidence/JAR/class/license checks passed. Resume compares internal object body unchanged through old final method; no runtime tests rerun.'),indent=2)+'\n',encoding='utf-8')
text=raw.decode('utf-8').replace("source.startswith(base[:base.rfind('}')])","source[source.index('internal object RuleBase64 {'):].startswith(base[base.index('internal object RuleBase64 {'):base.rfind('}')])")
(S/'review-resume.py').write_text(text,encoding='utf-8',newline='\n')
exec(compile(text,str(S/'review-resume.py'),'exec'),{'__file__':str(S/'review-resume.py'),'__name__':'__main__'})
