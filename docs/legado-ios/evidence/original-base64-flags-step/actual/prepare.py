from pathlib import Path
import base64,hashlib,json,urllib.request,zipfile
R=Path('F:/yuedu-reader');S=Path(__file__).parent
def fact(p):
 b=p.read_bytes();return {'path':str(p.relative_to(R)).replace('\\','/'),'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def write(p,b):
 p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(b)
def save(p,o):write(p,(json.dumps(o,ensure_ascii=False,indent=2)+'\n').encode())
parents=[R/'.build/original-local-html-webjs-step/implementation-v1/backend-final-v2.json',R/'.build/original-local-html-webjs-step/implementation-v1/snapshot-v2/legado-runtime.jar']
assert fact(parents[0])['sha256']=='3ce8c092ce65acf3e38e136cf6b81070a7e1df96ebc8184a4d1266fd4e816854'
assert fact(parents[1])['sha256']=='89f77040ea6a0f4592ca00a059c25da76cece9d1520b541e144588e6b4c5003b'
paths=['Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RulePlatform.kt','Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RuleBase64.kt','Packages/LegadoRuntime/vendor/original-rule/manifest.json']
for p in paths:
 b=(R/p).read_bytes();write(S/'rawbaseline'/p,b);write(S/'work'/p,b)
 if p.endswith('RulePlatform.kt') or p.endswith('manifest.json'):
  assert b==(R/'.build/original-local-html-webjs-step/implementation-v1/snapshot-v2/work'/p).read_bytes()
archive=Path('F:/legado-master.zip');assert hashlib.sha256(archive.read_bytes()).hexdigest()=='724dedcac2427cd1f02ca00af1eab7156146e6d9d3141ca4c92042d04ed7bcdd'
members=['app/src/main/java/io/legado/app/help/JsExtensions.kt','app/src/main/java/io/legado/app/utils/EncoderUtils.kt']
with zipfile.ZipFile(archive) as z:
 for p in members:write(S/'primary'/'legado'/p,z.read('legado-master/'+p))
url='https://android.googlesource.com/platform/frameworks/base/+/HEAD/core/java/android/util/Base64.java?format=TEXT'
response=urllib.request.urlopen(url,timeout=40);encoded=response.read();raw=base64.b64decode(encoded)
blob=hashlib.sha1(b'blob '+str(len(raw)).encode()+b'\x00'+raw).hexdigest()
assert blob=='99151c27e415da4039ba2636ea828edb7439a305',blob
write(S/'primary/android/Base64.java',raw)
license_url='https://www.apache.org/licenses/LICENSE-2.0.txt'
license_bytes=urllib.request.urlopen(license_url,timeout=40).read();write(S/'primary/android/LICENSE-2.0.txt',license_bytes)
save(S/'primary-binding.json',{'baselineCanonical':'08d18881583b8da310ac1eb423fa6b1fcb552e68','parents':list(map(fact,parents)),'sourceBaselines':[fact(S/'rawbaseline'/p)for p in paths],'lockedArchive':{'path':str(archive),'sha256':hashlib.sha256(archive.read_bytes()).hexdigest()},'lockedOriginal':[fact(S/'primary'/'legado'/p)for p in members],'androidPrimary':{'url':url,'gitBlobSHA1':blob,'source':fact(S/'primary/android/Base64.java'),'licenseURL':license_url,'license':fact(S/'primary/android/LICENSE-2.0.txt')},'scope':'Only existing Base64 signatures; no new source owner/parser/Java exposure. Ordinary incremental JVM evidence, never Swift SDK/JNI/full compatibility.'})
print('PRIMARY_AND_BASELINE_BOUND',blob)
