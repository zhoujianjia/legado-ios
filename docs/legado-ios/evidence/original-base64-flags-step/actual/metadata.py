from pathlib import Path
import json,hashlib
R=Path('F:/yuedu-reader');S=Path(__file__).parent
def f(p):b=p.read_bytes();return {'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
mp=S/'work/Packages/LegadoRuntime/vendor/original-rule/manifest.json';m=json.loads(mp.read_text(encoding='utf-8'))
old='Android Base64 flags/byte-array overloads explicitly unsupported; default String/charset overload follows Hutool 5.8.22 decoding, default encoding is Android NO_WRAP-equivalent UTF-8'
assert m['platformSeams'].count(old)==1
m['platformSeams'][m['platformSeams'].index(old)]='Existing Base64 flags overloads follow Android DEFAULT/NO_PADDING/NO_WRAP/CRLF/URL_SAFE semantics, including ignored NO_CLOSE/unknown bits, optional but strict present padding, and nullable blank byte arrays; no-flags String/charset decoding retains Hutool 5.8.22 and default encoding retains Android NO_WRAP UTF-8.'
m['androidBase64FlagsPort']={
 'source':'https://android.googlesource.com/platform/frameworks/base/+/HEAD/core/java/android/util/Base64.java',
 'gitBlobSHA1':'99151c27e415da4039ba2636ea828edb7439a305',**f(S/'primary/android/Base64.java'),
 'sourceIsFromOriginalArchive':False,
 'copyright':'Copyright (C) 2010 The Android Open Source Project',
 'license':'Apache-2.0',
 'existingLicenseFile':'Packages/LegadoRuntime/vendor/licenses/htmlunit-core-js/5.3.0-legado.4/LICENSE-APACHE-2.0.txt',
 'packagedLicenseEntry':'META-INF/licenses/htmlunit-core-js/5.3.0-legado.4/LICENSE-APACHE-2.0.txt',
 'existingLicense':f(R/'Packages/LegadoRuntime/vendor/licenses/htmlunit-core-js/5.3.0-legado.4/LICENSE-APACHE-2.0.txt'),
 'scope':'One-shot Kotlin decoder port; JDK standard/URL-safe alphabet encoder with Android 76-column/final-line behavior. No Android class or new runtime dependency is exposed. Existing Hutool no-flags String decoder remains unchanged.',
 'lockedSignatures':[
 {'archivePath':'legado-master/app/src/main/java/io/legado/app/help/JsExtensions.kt',**f(S/'primary/legado/app/src/main/java/io/legado/app/help/JsExtensions.kt')},
 {'archivePath':'legado-master/app/src/main/java/io/legado/app/utils/EncoderUtils.kt',**f(S/'primary/legado/app/src/main/java/io/legado/app/utils/EncoderUtils.kt')}]
}
mp.write_text(json.dumps(m,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
print('METADATA_FINAL',f(mp))
