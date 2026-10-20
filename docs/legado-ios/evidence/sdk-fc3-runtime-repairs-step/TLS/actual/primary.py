from pathlib import Path
import hashlib,json,urllib.request,urllib.error
S=Path(__file__).parent;P=S/'primary';P.mkdir(parents=True,exist_ok=True)
def get(u):
 return urllib.request.urlopen(urllib.request.Request(u,headers={'User-Agent':'yuedu-source-review'}),timeout=30).read()
commit=json.loads(get('https://api.github.com/repos/apple-oss-distributions/Security/commits/main'))['sha']
paths=['OSX/libsecurity_ssl/lib/sslContext.c','OSX/libsecurity_ssl/lib/sslContext.cpp','OSX/libsecurity_ssl/lib/SecureTransport.h','OSX/libsecurity_ssl/lib/sslHandshake.c']
facts=[];failed=[]
for path in paths:
 url='https://raw.githubusercontent.com/apple-oss-distributions/Security/'+commit+'/'+path
 try:b=get(url)
 except urllib.error.HTTPError as e:failed.append({'path':path,'status':e.code});continue
 p=P/path;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(b);facts.append({'url':url,'path':str(p.relative_to(S)).replace('\\','/'),'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()})
obj={'repository':'https://github.com/apple-oss-distributions/Security','commit':commit,'files':facts,'unavailablePaths':failed}
(S/'primary-binding.json').write_text(json.dumps(obj,indent=2)+'\n',encoding='utf-8',newline='\n');print(json.dumps(obj,indent=2))
