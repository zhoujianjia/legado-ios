from pathlib import Path
p=Path(__file__).with_name('assemble.py');s=p.read_text(encoding='utf-8')
s=s.replace("out=S/'legado-runtime-base64.jar'", "out=S/'legado-runtime-base64-final.jar'")
s=s.replace("if name in compiled:","if name == 'META-INF/legado-provenance/original-rule/manifest.json':\n   dst.writestr(item,(S/'work/Packages/LegadoRuntime/vendor/original-rule/manifest.json').read_bytes())\n  elif name in compiled:")
s=s.replace("write=S/'jar-assembly.json'", "write=S/'jar-assembly-final.json'")
exec(compile(s,__file__,'exec'))
