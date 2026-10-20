from pathlib import Path
import hashlib,json,shutil
S=Path(__file__).parent;H=S/'history-v1';H.mkdir(exist_ok=False);shutil.copyfile(S/'review.py',H/'review.py')
P=Path('F:/yuedu-reader/.build/sdk-fc3b01c-fixture-repairs');m=json.loads((P/'candidate-v1.json').read_bytes())
obj={'attemptExit':1,'stoppedAt':'actual failure excerpt matcher after all3 exactsource/testidentity/grammar validations passed','cause':'friendly test descriptions do not equal method names in raw log; authorv1 also misstated one storage method; v2 corrects metadata only','sourceChecksCompleted':[{'path':row['path'],'candidateSHA256':row['candidate']['sha256'],'grammarErrors':0}for row in m['files']],'testsExecuted':0,'SwiftSDKExecuted':0,'next':'Reuse unchanged source3 grammar/source findings; correct actuallog excerpt matching and bind v2metadata without rerunning grammar or tests.'}
(S/'prior-source-validation.json').write_text(json.dumps(obj,indent=2)+'\n',encoding='utf-8',newline='\n')
