from pathlib import Path
source=Path(__file__).with_name('run-ordinary.py').read_text(encoding='utf-8')
source=source.replace("E=S/'ordinary-v2'","E=S/'ordinary-v4'")
exec(compile(source,__file__,'exec'))
