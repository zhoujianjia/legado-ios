from pathlib import Path
source = Path(__file__).with_name('compile-production-v2.py').read_text(encoding='utf-8')
source = source.replace("E=S/'compile-attempt2'", "E=S/'compile-attempt3'")
exec(compile(source, __file__, 'exec'))
