from pathlib import Path, PurePosixPath
import hashlib, json, stat, urllib.request, zipfile
S=Path(__file__).parent
def find(value):
    if isinstance(value,dict):
        if isinstance(value.get('download_url'),str): return value['download_url']
        for child in value.values():
            found=find(child)
            if found: return found
    if isinstance(value,list):
        for child in value:
            found=find(child)
            if found: return found
    if isinstance(value,str) and value.startswith('{'):
        try: return find(json.loads(value))
        except json.JSONDecodeError: return None
    return None
rows=[]
for meta in json.loads((S/'artifact-metadata.json').read_bytes())['artifacts']:
    aid=meta['id']; assert aid in (12307712232,12307082572) and not meta['expired']
    assert meta['workflow_run']['head_sha']=='fc3b01ce980f6bdcdc8a3b7559dac5b1d57fc64a'
    destination=S/('artifact-'+str(aid)+'.zip')
    url=find(json.loads((S/('private-artifact-download-'+str(aid)+'.json')).read_bytes())); assert url and url.startswith('https://')
    if destination.exists(): body=destination.read_bytes()
    else:
        with urllib.request.urlopen(url,timeout=60) as response: body=response.read()
    digest=hashlib.sha256(body).hexdigest()
    assert len(body)==meta['size_in_bytes'] and 'sha256:'+digest==meta['digest']
    destination.write_bytes(body)
    root=(S/('extracted-'+str(aid))).resolve(); root.mkdir(exist_ok=True); members=[]
    with zipfile.ZipFile(destination) as z:
        assert z.testzip() is None and len(z.namelist())==len(set(z.namelist()))
        assert sum(i.file_size for i in z.infolist())<=128*1024*1024
        for info in z.infolist():
            p=PurePosixPath(info.filename)
            assert not p.is_absolute() and '..' not in p.parts and '\\' not in info.filename and ':' not in info.filename
            assert not stat.S_ISLNK(info.external_attr>>16) and info.file_size<=64*1024*1024
            target=(root/Path(*p.parts)).resolve(); assert target.is_relative_to(root)
            target=Path('\\\\?\\'+str(target))
            if info.is_dir(): target.mkdir(parents=True,exist_ok=True); continue
            data=z.read(info); target.parent.mkdir(parents=True,exist_ok=True); target.write_bytes(data)
            members.append(dict(path=info.filename,bytes=len(data),sha256=hashlib.sha256(data).hexdigest()))
    rows.append(dict(artifactID=aid,bytes=len(body),sha256=digest,CRCValid=True,pathSafe=True,members=members))
log=json.loads((S/'private-job-log-response.json').read_bytes())['content']; assert isinstance(log,str)
(S/'decoded-job.log').write_bytes(log.encode('utf-8'))
record=dict(artifacts=rows,decodedJobLog=dict(bytes=len(log.encode('utf-8')),sha256=hashlib.sha256(log.encode('utf-8')).hexdigest()))
(S/'download-verification.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8',newline='\n')
print(json.dumps(dict(artifacts=[dict(artifactID=r['artifactID'],bytes=r['bytes'],sha256=r['sha256'],members=len(r['members']),important=[m['path'] for m in r['members'] if any(x in m['path'] for x in ['summary','tests.json','result.json','source-input','pipeline'])]) for r in rows])))
