"""Independent Python SRP/CBC/GCM reference. Public fixtures only; never contacts Apple."""
from pathlib import Path
import hashlib, hmac, json, re, struct, plistlib
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives import padding
import cryptography

ROOT = Path(__file__).resolve().parents[1]
RFC = (ROOT / 'primary/rfc5054.txt').read_text(encoding='utf-8')
def group(bits):
    block = RFC[RFC.index(f'{bits}-bit Group'):]
    block = block[block.index('The hexadecimal value for the prime is:'):block.index('The generator is:')]
    return int(''.join(re.findall(r'\b[0-9A-F]{8}\b', block)), 16)
def digest(data, algorithm='sha256'): return hashlib.new(algorithm, data).digest()
def mac(key, data): return hmac.digest(key, data, 'sha256')
def pad(n, width): return n.to_bytes(width, 'big')
def srp(n, user, password_key, salt, a, b, algorithm='sha256', apple=False):
    width=(n.bit_length()+7)//8; g=2
    h=lambda data:digest(data,algorithm)
    k=int.from_bytes(h(pad(n,width)+pad(g,width)),'big')
    x=int.from_bytes(h(salt+h((b'' if apple else user.encode())+b':'+password_key)),'big')
    v=pow(g,x,n); A=pow(g,a,n); B=(k*v+pow(g,b,n))%n
    u=int.from_bytes(h(pad(A,width)+pad(B,width)),'big')
    S=pow((B-k*v)%n,a+u*x,n)
    assert S==pow((A*pow(v,u,n))%n,b,n)
    K=h(pad(S,width))
    M1=h(bytes(l^r for l,r in zip(h(pad(n,width)),h(pad(g,width))))+h(user.encode())+salt+pad(A,width)+pad(B,width)+K)
    M2=h(pad(A,width)+M1+K)
    return dict(n=n,k=k,x=x,v=v,A=A,B=B,u=u,S=S,K=K,M1=M1,M2=M2)

def public_rfc():
    n=group(1024);salt=bytes.fromhex('BEB25379D1A8581EB5A727673A2441EE')
    a=int('60975527035CF2AD1989806F0407210BC81EDC04E2762A56AFD529DDDA2D4393',16)
    b=int('E487CB59D31AC550471E81F00F6928E01DDA08E974A004F49E61F5D105284D20',16)
    actual=srp(n,'alice',b'password123',salt,a,b,'sha1')
    expected={
      'k':'7556AA045AEF2CDD07ABAF0F665C3E818913186F',
      'x':'94B7555AABE9127CC58CCF4993DB6CF84D16C124',
      'u':'CE38B9593487DA98554ED47D70A7AE5F462EF019',
      'A':'61D5E490F6F1B79547B0704C436F523DD0E560F0C64115BB72557EC44352E8903211C04692272D8B2D1A5358A2CF1B6E0BFCF99F921530EC8E39356179EAE45E42BA92AEACED825171E1E8B9AF6D9C03E1327F44BE087EF06530E69F66615261EEF54073CA11CF5858F0EDFDFE15EFEAB349EF5D76988A3672FAC47B0769447B',
      'B':'BD0C61512C692C0CB6D041FA01BB152D4916A1E77AF46AE105393011BAF38964DC46A0670DD125B95A981652236F99D9B681CBF87837EC996C6DA04453728610D0C6DDB58B318885D7D82C7F8DEB75CE7BD4FBAA37089E6F9C6059F388838E7A00030B331EB76840910440B1B27AAEAEEB4012B7D7665238A8E3FB004B117B58',
      'S':'B0DC82BABCF30674AE450C0287745E7990A3381F63B387AAF271A10D233861E359B48220F7C4693C9AE12B0A6F67809F0876E2D013800D6C41BB59B6D5979B5C00A172B4A2A5903A0BDCAF8A709585EB2AFAFA8F3499B200210DCC1F10EB33943CD67FC88A2F39A4BE5BEC4EC0A3212DC346D7E474B29EDE8A469FFECA686E5A'}
    for key,value in expected.items(): assert actual[key]==int(value,16),key
    return dict(source='RFC5054 Appendix B; published SHA1/1024 reference only, not production Apple policy',checkedFields=list(expected),passed=True)

def apple_vector(protocol):
    user='fixture@example.invalid';password='public-fixture-password';salt=bytes(range(16));a=bytes(range(1,33));b=bytes(range(33,65));iterations=1000
    raw=digest(password.encode());password_input=raw if protocol=='s2k' else raw.hex().encode()
    password_key=hashlib.pbkdf2_hmac('sha256',password_input,salt,iterations,32)
    state=srp(group(2048),user,password_key,salt,int.from_bytes(a,'big'),int.from_bytes(b,'big'),apple=True)
    K=state['K'];sk=bytes(range(32));cookie=b'public-opaque-cookie';dsid='123456789';idms='public-fixture-idms'
    spd=plistlib.dumps(dict(adsid=dsid,GsIdmsToken=idms,sk=sk,c=cookie),fmt=plistlib.FMT_XML,sort_keys=True)
    padder=padding.PKCS7(128).padder();plain=padder.update(spd)+padder.finalize()
    encryptor=Cipher(algorithms.AES(mac(K,b'extra data key:')),modes.CBC(mac(K,b'extra data iv:')[:16])).encryptor()
    encrypted_spd=encryptor.update(plain)+encryptor.finalize();sc=b'public-sc'
    transcript=b's2k,s2k_fo||'+protocol.encode()+b'|'+struct.pack('<I',len(encrypted_spd))+encrypted_spd+b'|'+struct.pack('<I',len(sc))+sc+b'|'
    np=mac(mac(K,b'HMAC key:'),digest(transcript))
    app='com.apple.gs.xcode.auth';checksum=mac(sk,b'apptokens'+dsid.encode()+app.encode())
    token='public-fixture-xcode-token';expiry=1792544400000
    token_plain=plistlib.dumps({'t':{app:{'token':token,'expiry':expiry}}},fmt=plistlib.FMT_XML,sort_keys=True)
    iv=bytes(range(16));enc=Cipher(algorithms.AES(sk),modes.GCM(iv)).encryptor();enc.authenticate_additional_data(b'XYZ');cipher=enc.update(token_plain)+enc.finalize()
    et=b'XYZ'+iv+cipher+enc.tag
    dec=Cipher(algorithms.AES(sk),modes.GCM(et[3:19],et[-16:])).decryptor();dec.authenticate_additional_data(et[:3]);assert dec.update(et[19:-16])+dec.finalize()==token_plain
    result=dict(protocol=protocol,username=user,password=password,salt=salt.hex(),privateA=a.hex(),privateB=b.hex(),iterations=iterations,passwordKey=password_key.hex(),groupN=hex(group(2048))[2:])
    result.update({k:(v.hex() if isinstance(v,bytes) else hex(v)[2:]) for k,v in state.items()})
    result.update(spd=encrypted_spd.hex(),sc=sc.hex(),np=np.hex(),sk=sk.hex(),cookie=cookie.hex(),dsid=dsid,idms=idms,checksum=checksum.hex(),encryptedToken=et.hex(),token=token,expiryMilliseconds=expiry)
    return result

if __name__=='__main__':
    rfc=public_rfc();vectors=[apple_vector('s2k'),apple_vector('s2k_fo')]
    result=dict(schemaVersion=1,publicFixturesOnly=True,rfc5054=rfc,appleDerived=vectors,independence='Python hashlib builtin pow plus cryptography; no Swift implementation imported/executed',cryptographyVersion=cryptography.__version__,actualPythonReferenceRuns=4,previousFailuresPreserved=True,previousPassRegenerationReason='Bind token expiry to the existing original identity fixture clock rather than year2100',SwiftSDKExecutions=0,AppleRequests=0)
    out=ROOT/'vectors/vectors.json';out.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(dict(rfc5054PublishedFieldsPassed=len(rfc['checkedFields']),appleDerivedCases=len(vectors),serverClientSecretsMatched=True,tokenGCMRoundTrips=2,SwiftSDKExecutions=0,AppleRequests=0,outputBytes=out.stat().st_size,outputSHA256=hashlib.sha256(out.read_bytes()).hexdigest())))
