from pathlib import Path
import json,subprocess,xml.etree.ElementTree as E
R=Path('F:/yuedu-reader');S=R/'.build/native-210-reader-repair-step';C=S/'incremental';out=C/'baseline-counterfactual';out.mkdir(exist_ok=True)
c=json.loads((C/'retry/commands.json').read_text(encoding='utf-8'));args=next(x['argv']for x in c if x['log']=='junit-selected.log')
base=R/'.build/original-source-login-delta-reuse-step/validation-root/Packages/LegadoRuntime/jvm/build/libs/legado-runtime.jar'
args[args.index('-cp')+1]=args[args.index('-cp')+1].replace(str(C/'legado-runtime-incremental.jar'),str(base));args[-2]=str(out/'actual-tests.xml')
(out/'command.json').write_text(json.dumps(args,indent=2)+'\n',encoding='utf-8');p=subprocess.run(args,cwd=R,capture_output=True);(out/'execute.log').write_bytes(p.stdout+p.stderr)
xml=E.parse(out/'actual-tests.xml').getroot();assert p.returncode==1 and xml.attrib['tests']=='1'and xml.attrib['failures']=='1'
failure=xml.find('testcase/failure').text;assert 'Only the explicitly requested chapter has a variable grant'in failure and 'RuleWebBookState' in failure
print('BASELINE_COUNTERFACTUAL_CONFIRMED actual1failure=foreignChapterVariableRead')
