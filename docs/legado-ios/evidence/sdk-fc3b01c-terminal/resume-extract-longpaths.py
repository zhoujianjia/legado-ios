from pathlib import Path
import hashlib, json
S=Path(__file__).parent
original=(S/'download-once.py').read_text(encoding='utf-8')
new=original.replace("destination=S/('artifact-'+str(aid)+'.zip'); assert not destination.exists()", "destination=S/('artifact-'+str(aid)+'.zip')")
new=new.replace("with urllib.request.urlopen(url,timeout=60) as response: body=response.read()", "if destination.exists(): body=destination.read_bytes()\n    else:\n        with urllib.request.urlopen(url,timeout=60) as response: body=response.read()")
new=new.replace("root=(S/('extracted-'+str(aid))).resolve(); assert not root.exists(); root.mkdir(); members=[]", "root=(S/('extracted-'+str(aid))).resolve(); root.mkdir(exist_ok=True); members=[]")
new=new.replace("assert target.is_relative_to(root)", "assert target.is_relative_to(root)\n            target=Path('\\\\\\\\?\\\\'+str(target))")
record=dict(originalScript=dict(bytes=len(original.encode()),sha256=hashlib.sha256(original.encode()).hexdigest()),firstAttempt='Artifact12307712232 downloaded and SHA/CRC/path checks passed; extraction stopped at Windows MAX_PATH. No remote test or artifact refetch. Resume reads existingZIP, supports extended Win32 paths, downloads second artifact only once.',substitutions=4)
(S/'extraction-resume-history.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
compile(new,'download-resume-derived','exec')
(S/'download-resume-derived.py').write_text(new,encoding='utf-8',newline='\n')
exec(compile(new,'download-resume-derived','exec'),{'__file__':str(S/'download-resume-derived.py'),'__name__':'__main__'})
