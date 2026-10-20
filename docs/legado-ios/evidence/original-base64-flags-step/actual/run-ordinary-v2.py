from pathlib import Path
p=Path(__file__).with_name('run-ordinary.py')
s=p.read_text(encoding='utf-8').replace("E=S/'ordinary-v1'", "E=S/'ordinary-v2'")
exec(compile(s,__file__,'exec'))
