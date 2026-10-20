from pathlib import Path
source=Path(__file__).with_name('verify-packaging.py').read_text(encoding='utf-8')
source=source.replace("S/'validation-root'","S/'validation-root-v2'").replace("ordinary-v2/","ordinary-v3/").replace("'ordinary-jar-inspected.json'","'ordinary-jar-inspected-v2.json'").replace("'packaging-tests.log'","'packaging-tests-v2.log'")
exec(compile(source,__file__,'exec'))
