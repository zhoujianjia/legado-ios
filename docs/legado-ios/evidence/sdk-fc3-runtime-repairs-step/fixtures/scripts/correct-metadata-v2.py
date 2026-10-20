from pathlib import Path
import hashlib,json
S=Path(__file__).parent; data=(S/'candidate-v1.json').read_bytes(); v=json.loads(data)
v['version']=2
v['supersedes']=dict(path='candidate-v1.json',bytes=len(data),sha256=hashlib.sha256(data).hexdigest(),sourceChanges=False,reason='Correct one evidence method name and distinguish current S2 baseline from historical fc3 source.')
v['evidence']['storageCases'][2]='appSessionCancelsSecondaryChallengeAndRejectsOldTicket'
v['baselineScope']='DeveloperAuthentication94894B/5a66a0ec9b30099edae1ac7d877c373e967b1feab0127edec6f573f74c70c28f includes already integrated S2 SPD source. Its fc3 version was53471B. Only same appInputs basename hunk changes; later S2 behavior preserved. Other two baseline files are byte-exact fc3. sourceCommit refers to failure evidence only.'
(S/'candidate-v2.json').write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
raw=(S/'candidate-v2.json').read_bytes(); print(json.dumps(dict(bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest(),sourceChanges=0)))
