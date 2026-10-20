from pathlib import Path
source = Path(__file__).with_name('assemble-ordinary.py').read_text(encoding='utf-8')
source = source.replace("E=S/'ordinary-v2'", "E=S/'ordinary-v3'").replace("compile-attempt3", "compile-attempt5")
exec(compile(source, __file__, 'exec'))
