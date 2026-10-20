from pathlib import Path
from datetime import datetime, timezone, timedelta
import base64
import hashlib
import json
import plistlib
import subprocess
import textwrap

ROOT = Path('F:/yuedu-reader')
WORK = ROOT / '.build/renewal-discovery/cms-profile-step'
OWNED = WORK / 'owned'
OPENSSL = 'D:/app/Git/usr/bin/openssl.exe'
OUTPUT = ROOT / 'Tests/iOS/yuedu appTests/SelfRenewalCMSFixture.swift'
commands = []


def run(*args, expected=0):
    result = subprocess.run([OPENSSL, *map(str, args)], capture_output=True)
    commands.append({'arguments': list(map(str, args)), 'exitCode': result.returncode,
        'stdout': result.stdout.decode('utf-8', errors='replace'),
        'stderr': result.stderr.decode('utf-8', errors='replace')})
    assert (result.returncode == 0) if expected == 0 else (result.returncode != 0), commands[-1]
    return result


def main():
    OWNED.mkdir()
    assert not OUTPUT.exists()
    config = OWNED / 'certificate.cnf'
    config.write_text('[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nCN=Yuedu Owned Fixture Root\n[root]\nbasicConstraints=critical,CA:true,pathlen:1\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n[leaf]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n', encoding='ascii')
    root_key, root_pem = OWNED / 'root.key', OWNED / 'root.pem'
    run('req', '-new', '-newkey', 'rsa:2048', '-nodes', '-x509', '-sha256', '-days', '3650',
        '-config', config, '-extensions', 'root', '-keyout', root_key, '-out', root_pem)
    for name, algorithm in [('leaf','rsa'), ('second','rsa'), ('ec','ec')]:
        key, csr, cert = (OWNED / (name + suffix) for suffix in ('.key','.csr','.pem'))
        if algorithm == 'rsa': run('genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048', '-out', key)
        else: run('genpkey', '-algorithm', 'EC', '-pkeyopt', 'ec_paramgen_curve:P-384', '-out', key)
        run('req', '-new', '-key', key, '-config', config, '-subj', '/CN=Yuedu Owned Fixture ' + name, '-out', csr)
        run('x509', '-req', '-in', csr, '-CA', root_pem, '-CAkey', root_key, '-set_serial', str({'leaf':2,'second':3,'ec':4}[name]),
            '-days', '3650', '-sha256', '-extfile', config, '-extensions', 'leaf', '-out', cert)
    for name in ('root','leaf'):
        run('x509', '-in', OWNED / (name + '.pem'), '-outform', 'DER', '-out', OWNED / (name + '.der'))
    now = datetime.now(timezone.utc).replace(microsecond=0)
    verify_at = int((now + timedelta(seconds=60)).timestamp())
    leaf_der = (OWNED / 'leaf.der').read_bytes()
    payload = plistlib.dumps({'UUID':'11111111-2222-3333-4444-555555555555',
        'CreationDate': datetime(2026,10,19), 'ExpirationDate': datetime(2031,1,1),
        'TeamIdentifier':['FIXTURE123'], 'ApplicationIdentifierPrefix':['FIXTURE123'],
        'DeveloperCertificates':[leaf_der],
        'Entitlements': {'application-identifier':'FIXTURE123.test.owned.reader', 'com.apple.developer.team-identifier':'FIXTURE123'},
        'DER-Encoded-Profile':b'\x30\x00'},fmt=plistlib.FMT_XML,sort_keys=True)
    content = OWNED / 'profile.plist'
    content.write_bytes(payload)
    cases = [('embedded', []),('detached',['-detached']),('noAttributes',['-noattr']),
        ('subjectKeyIdentifier',['-keyid']),('ecdsaSHA384',['-signer',OWNED/'ec.pem','-inkey',OWNED/'ec.key','-md','sha384']),
        ('multipleSigners',['-signer',OWNED/'second.pem','-inkey',OWNED/'second.key'])]
    fixture_names = {'rootCertificate':'root.der','leafCertificate':'leaf.der','profilePayload':'profile.plist'}
    for name, extra in cases:
        destination = OWNED / (name + '.cms')
        args = ['cms','-sign','-binary','-in',content,'-signer',OWNED/'leaf.pem','-inkey',OWNED/'leaf.key',
            '-certfile',root_pem,'-md','sha256','-outform','DER','-out',destination]
        if name != 'detached': args += ['-nodetach']
        # ECDSA is one signer; the multipleSigners case intentionally adds a second.
        if name == 'ecdsaSHA384':
            args = ['cms','-sign','-binary','-in',content,'-certfile',root_pem,'-outform','DER','-out',destination,'-nodetach'] + extra
        else:
            args += [x for x in extra if x != '-detached']
        run(*args)
        verify = ['cms','-verify','-binary','-inform','DER','-in',destination,'-CAfile',root_pem,
            '-purpose','any','-attime',str(verify_at),'-out',OWNED/(name+'.verified.plist')]
        if name == 'detached': verify += ['-content',content]
        run(*verify)
        assert (OWNED/(name+'.verified.plist')).read_bytes() == payload
        fixture_names[name] = name + '.cms'
    tampered = bytearray((OWNED/'embedded.cms').read_bytes())
    at = tampered.index(payload) + payload.index(b'FIXTURE123')
    tampered[at] ^= 1
    (OWNED/'tampered.cms').write_bytes(tampered)
    run('cms','-verify','-binary','-inform','DER','-in',OWNED/'tampered.cms','-CAfile',root_pem,
        '-purpose','any','-attime',str(verify_at),'-out',OWNED/'tampered.rejected.plist', expected=1)
    lines = ['import Foundation', '', '// Generated owned CMS vectors; public certificates only. No private key is shipped.',
        '// Independently verified with OpenSSL; generic fixture anchors do not assert Apple authority.',
        'enum SelfRenewalCMSFixture {', '    static let validationDate = Date(timeIntervalSince1970: ' + str(verify_at) + ')']
    files = []
    for name, filename in fixture_names.items():
        raw = (OWNED / filename).read_bytes()
        lines += ['    static let ' + name + ': Data = {', '        let encoded = """']
        lines += ['        ' + line for line in textwrap.wrap(base64.b64encode(raw).decode(), 100)]
        lines += ['        """', '        return Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)!', '    }()']
        files.append({'name':name,'file':filename,'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()})
    lines += ['}', '']
    OUTPUT.write_text('\n'.join(lines),encoding='utf-8',newline='\n')
    record = {'status':'owned-fixtures-generated-and-independently-verified-not-Swift-executed',
        'createdAtUTC':now.isoformat(),'validationDateUnix':verify_at,'CMSPositiveCasesVerified':6,
        'CMSTamperRejected':1,'commands':commands,'fixtures':files,
        'fixtureSource':{'path':OUTPUT.relative_to(ROOT).as_posix(),'bytes':OUTPUT.stat().st_size,
            'sha256':hashlib.sha256(OUTPUT.read_bytes()).hexdigest()},
        'privateKeysIgnoredOnly':True,'actualSwiftSDKBuilds':0,'actualSwiftTestExecutions':0}
    (WORK/'fixture-generation.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:record[k] for k in ['status','CMSPositiveCasesVerified','CMSTamperRejected','fixtureSource']}))


if __name__ == '__main__': main()
