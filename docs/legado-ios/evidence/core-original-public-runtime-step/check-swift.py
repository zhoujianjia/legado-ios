import datetime, hashlib, json, sys
from pathlib import Path
root=Path(__file__).resolve().parents[2]; out=Path(__file__).resolve().parent
sys.path.insert(0,str(root/'.tools/swift-syntax-python'))
from tree_sitter import Language, Parser
import tree_sitter_swift
parser=Parser(Language(tree_sitter_swift.language()))
files=['Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoRuntime.swift',
       'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoOriginalModels.swift',
       'Packages/LegadoRuntime/Tests/LegadoRuntimeTests/LegadoOriginalAPITests.swift']
record=dict(checkedAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),scope='Swift grammar only on Windows. No Swift compiler/SDK/JNI/native tests executed.',files=[])
for name in files:
 raw=(root/name).read_bytes(); tree=parser.parse(raw); pending=[tree.root_node]; errors=[]
 while pending:
  node=pending.pop()
  if node.type=='ERROR' or node.is_missing: errors.append(dict(type=node.type,start=list(node.start_point),end=list(node.end_point)))
  pending.extend(node.children)
 snapshot=out/'swift-sources'/name;snapshot.parent.mkdir(parents=True,exist_ok=True);snapshot.write_bytes(raw)
 record['files'].append(dict(path=name,bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest(),grammarErrors=errors))
(out/'swift-grammar.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
print(json.dumps(record));assert not any(item['grammarErrors'] for item in record['files'])
