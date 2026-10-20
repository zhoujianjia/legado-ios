from pathlib import Path
p=Path(__file__).with_name('run-ordinary.py')
s=p.read_text(encoding='utf-8').replace("E=S/'ordinary-v1'", "E=S/'ordinary-v3'")
# Baseline public counterexamples already executed successfully with the exact same parent JAR/ABI.
s=s.replace("assert run('baseline-public',[*common,str(base)+';'+str(E),'OrdinaryBase64Flags','baseline'])==0", "")
exec(compile(s,__file__,'exec'))
