"""macOS/Xcode-only producer. All generated credentials are synthetic.
Private keys and encrypted PKCS12 stay in process memory or one temporary
Keychain; published outputs contain public code/certificates/profiles only.
The JSON output is an XCTest resource, not a source file mutation.
"""
from pathlib import Path
from datetime import datetime,timezone,timedelta
import argparse, base64, hashlib, io, json, os, plistlib, re, secrets, shutil, struct, subprocess, sys, tempfile, zipfile, math, signal, time
HERE=Path(__file__).resolve().parent
RECORDS=[]
OPENSSL='openssl'
PUBLIC_DIAGNOSTIC_BYTES=65_536
PRIVATE_LITERALS=[]
# Independent of the native xcodebuild/job timeout. Cleanup always gets its own
# short allowance even if this producer's deadline was exhausted.
PRODUCER_TIMEOUT_SECONDS=300
PRODUCER_DEADLINE=None
TOOL_TIMEOUT_SECONDS={'openssl':30,'xcodebuild':20,'xcrun':120,'security':15,
                      'codesign':45,'import-owned-identity':20}
CLEANUP_TIMEOUT_SECONDS=10
KILL_DRAIN_SECONDS=1

class ToolFailure(RuntimeError):
    def __init__(self, tool, code):
        self.tool=tool;self.code=code
        super().__init__(tool+' failed: '+str(code))
class ToolTimeout(ToolFailure):
    def __init__(self, tool, seconds, returncode, started):
        super().__init__(tool,124)
        self.seconds=seconds;self.returncode=returncode;self.started=started
class ToolProcessFailure(ToolFailure):
    def __init__(self, tool, timed_out, returncode, started, issues):
        super().__init__(tool,125)
        self.timed_out=timed_out;self.returncode=returncode;self.started=started;self.issues=issues

def process_issue(stage, error):
    # Never format an OS/subprocess exception: TimeoutExpired.cmd and an OSError
    # message/filename may contain a private command or input-derived data.
    name=type(error).__name__
    if name not in ('PermissionError','ProcessLookupError','TimeoutExpired','OSError',
                    'FileNotFoundError','BrokenPipeError','ValueError'):
        name='Exception'
    number=getattr(error,'errno',None)
    return {'stage':stage,'errorType':name,'errno':number if type(number) is int else None}

def tool_timeout(args, override=None, cleanup=False):
    name=Path(str(args[0])).name
    seconds=TOOL_TIMEOUT_SECONDS.get(name,30) if override is None else override
    if isinstance(seconds,bool) or not isinstance(seconds,(int,float)) or not math.isfinite(seconds) or seconds<=0:
        raise ValueError('Positive finite owned-tool timeout required')
    seconds=min(seconds,TOOL_TIMEOUT_SECONDS.get(name,30))
    if not cleanup and PRODUCER_DEADLINE is not None:
        seconds=min(seconds,max(0,PRODUCER_DEADLINE-time.monotonic()))
    return seconds

def terminate_owned_group(process):
    # A fresh group belongs to this one started tool. Never signal a global
    # securityd/trustd, a login session, or a process group supplied by a caller.
    try:
        if os.name=='posix':os.killpg(process.pid,signal.SIGKILL)
        else:process.kill()
    except ProcessLookupError:pass

def bounded_child(args, input, env, seconds):
    if seconds<=0:raise ToolTimeout(Path(str(args[0])).name,0,None,False)
    options={'start_new_session':True} if os.name=='posix' else {}
    process=None;stdout=b'';stderr=b'';timed_out=False;interrupt=None;issues=[]
    cleanup={'hardKillAttempted':False,'drained':False,'childReaped':False,'pipesClosed':True,'issues':issues}
    try:
        try:
            process=subprocess.Popen(list(map(str,args)),stdin=subprocess.PIPE if input is not None else subprocess.DEVNULL,
                stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,bufsize=0,**options)
            stdout,stderr=process.communicate(input=input,timeout=seconds)
            cleanup['drained']=True
        except subprocess.TimeoutExpired as error:
            timed_out=True;stdout=error.output or b'';stderr=error.stderr or b''
        except Exception as error:
            issues.append(process_issue('communicate' if process is not None else 'spawn',error))
        except BaseException as error:
            interrupt=error
        if process is not None and (timed_out or issues or interrupt is not None):
            # One hard signal at the already-expired deadline, before reaping.
            # TERM followed immediately by KILL races Darwin's zombie exclusion.
            # Never signal a possibly reused group after its leader was reaped.
            if process.returncode is None:
                cleanup['hardKillAttempted']=True
                try:terminate_owned_group(process)
                except Exception as error:
                    issues.append(process_issue('groupKill',error))
                    # A group permission failure remains failure. Killing only
                    # this same unreaped leader does not prove group termination.
                    try:
                        if os.name=='posix':os.kill(process.pid,signal.SIGKILL)
                        else:process.kill()
                    except ProcessLookupError:pass
                    except Exception as fallback:issues.append(process_issue('leaderKill',fallback))
            try:
                stdout,stderr=process.communicate(timeout=KILL_DRAIN_SECONDS)
                cleanup['drained']=True
            except subprocess.TimeoutExpired as error:
                stdout=error.output or stdout;stderr=error.stderr or stderr
                issues.append(process_issue('drain',error))
            except Exception as error:issues.append(process_issue('drain',error))
    finally:
        if process is not None:
            for stream in (process.stdin,process.stdout,process.stderr):
                if stream is not None:
                    try:stream.close()
                    except OSError as error:issues.append(process_issue('closePipe',error))
            try:process.wait(timeout=0.5)
            except Exception as error:issues.append(process_issue('reap',error))
            cleanup['childReaped']=process.returncode is not None
            cleanup['pipesClosed']=all(stream is None or stream.closed for stream in (process.stdin,process.stdout,process.stderr))
    if interrupt is not None:raise interrupt from None
    result=subprocess.CompletedProcess(args,process.returncode if process is not None else None,stdout,stderr)
    result.processStarted=process is not None;result.processCleanup=cleanup
    return result,timed_out


def compile_owned_importer(owned, out):
    # The two deprecated public IdentitySearch functions are unavailable to
    # Swift, but remain declared in the macOS C SDK. A normal C object and
    # imported header expose only OSStatus/count, never an identity/private key.
    bridge = owned/'OwnedIdentitySearch.o'
    bridge_log = owned/'owned-identity-search-compile.log'
    importer = owned/'import-owned-identity'
    run(['xcrun','--sdk','macosx','clang','-std=c11','-Wall','-Wextra',
         '-Werror=implicit-function-declaration','-c',HERE/'OwnedIdentitySearch.c','-o',bridge],
        public_log=bridge_log)
    run(['xcrun','--sdk','macosx','swiftc','-import-objc-header',HERE/'OwnedIdentitySearch.h',
         HERE/'ImportOwnedIdentity.swift',bridge,'-o',importer],
        public_log=out/'import-tool-compile.log')
    # Successful public compiler logs share the existing allowlisted filename.
    # Either compile failure raises first and retains its real bounded stderr in
    # the existing producer log; no fake object/tool fallback is accepted.
    log = out/'import-tool-compile.log'
    log.write_bytes(b'OWNED_C_BRIDGE\n'+bridge_log.read_bytes()+b'\nOWNED_SWIFT_IMPORTER\n'+log.read_bytes())
    return importer

def public_text(raw):
    for literal in PRIVATE_LITERALS:
        raw=raw.replace(literal.encode(),b'<redacted-owned-password>')
    text=raw[:PUBLIC_DIAGNOSTIC_BYTES].decode('utf-8','replace')
    text=re.sub(r'-----BEGIN [^-\r\n]*PRIVATE KEY-----[\s\S]*', '<private-material-suppressed>', text)
    return text
def public_record(label, value):
    # Existing wrapper redirects this stdout to the always-uploaded producer
    # log, including when generation fails before stage-sdk-fixture is reached.
    print(label+' '+json.dumps(value,sort_keys=True),flush=True)
def identity_status(raw):
    # Never forward arbitrary output of a process receiving private stdin.
    # The importer reports only these typed, public fields; no paths/userInfo.
    if len(raw)>4_096:raise ValueError('Owned importer status byte budget')
    value=json.loads(raw)
    stages={'readInput','createKeychain','createTrustedApplications','createACL','importPKCS12',
            'findImportedIdentity','findStoredIdentity','matchLeaf','findRoot','privateKey','signChallenge','verifyChallenge','complete'}
    allowed={'schemaVersion','stage','status','osStatus','importedItemCount','storedIdentityCount',
             'leafSHA256','rootSHA256','privateKeySignatureVerified','codesignACLExecutionVerified'}
    if (not isinstance(value,dict) or set(value)-allowed or type(value.get('schemaVersion')) is not int or value.get('schemaVersion')!=1
            or value.get('stage') not in stages or value.get('status') not in ('passed','failed')
            or type(value.get('osStatus')) is not int or not -(2**31)<=value['osStatus']<2**31):
        raise ValueError('Invalid owned importer public status')
    for name in ('leafSHA256','rootSHA256'):
        if name in value and (not isinstance(value[name],str) or re.fullmatch('[0-9a-f]{64}',value[name]) is None):
            raise ValueError('Invalid owned importer public fingerprint')
    for name in ('importedItemCount','storedIdentityCount'):
        if name in value and (type(value[name]) is not int or not 0<=value[name]<=16):
            raise ValueError('Invalid owned importer public count')
    for name in ('privateKeySignatureVerified','codesignACLExecutionVerified'):
        if name in value and type(value[name]) is not bool:raise ValueError('Invalid owned importer public fact')
    if value['status']=='passed':
        if (set(value)!=allowed or value['stage']!='complete' or value['osStatus']!=0
                or not 1<=value['importedItemCount']<=16 or value['storedIdentityCount']!=1
                or value['privateKeySignatureVerified'] is not True or value['codesignACLExecutionVerified'] is not False):
            raise ValueError('Incomplete owned importer completion facts')
    elif set(value)!={'schemaVersion','stage','status','osStatus'} or value['osStatus']==0:
        raise ValueError('Invalid owned importer failure facts')
    return value
def reopened_identity_status(raw):
    # A second strict schema for a fresh process with no PKCS12 input. Never
    # promote its own sign challenge into proof that codesign ran successfully.
    if len(raw)>4_096:raise ValueError('Owned reopen status byte budget')
    value=json.loads(raw)
    common={'schemaVersion','operation','stage','status','osStatus'}
    facts={'storedIdentityCount','legacySigningIdentityCount','leafSHA256','rootSHA256',
           'privateKeySignatureVerified','codesignACLExecutionVerified',
           'keychainUnlockedBeforeRequest','keychainUnlocked','keychainReadable','keychainWritable'}
    stages={'readInput','openKeychain','unlockKeychain','keychainStatus','legacyIdentitySearch',
            'findStoredIdentity','matchLeaf','findRoot','privateKey','signChallenge','verifyChallenge','complete'}
    if (not isinstance(value,dict) or type(value.get('schemaVersion')) is not int or value.get('schemaVersion')!=2
            or value.get('operation')!='reopenIdentity' or value.get('stage') not in stages
            or value.get('status') not in ('passed','failed') or type(value.get('osStatus')) is not int
            or not -(2**31)<=value['osStatus']<2**31):
        raise ValueError('Invalid owned reopen public status')
    if value['status']=='failed':
        if set(value)!=common or value['osStatus']==0:raise ValueError('Invalid owned reopen failure')
        return value
    if set(value)!=common|facts or value['stage']!='complete' or value['osStatus']!=0:
        raise ValueError('Incomplete owned reopen completion')
    for name in ('storedIdentityCount','legacySigningIdentityCount'):
        if type(value[name]) is not int or value[name]!=1:raise ValueError('Ambiguous owned reopen identity')
    for name in ('leafSHA256','rootSHA256'):
        if not isinstance(value[name],str) or re.fullmatch('[0-9a-f]{64}',value[name]) is None:
            raise ValueError('Invalid owned reopen public fingerprint')
    for name in ('privateKeySignatureVerified','keychainUnlocked','keychainReadable','keychainWritable'):
        if value[name] is not True:raise ValueError('Unproven owned reopen fact')
    if type(value['keychainUnlockedBeforeRequest']) is not bool:raise ValueError('Invalid initial owned Keychain status')
    if value['codesignACLExecutionVerified'] is not False:raise ValueError('Unexecuted codesign is not proven')
    return value
ACL_COUNTS={'privateKeyCount','aclCount','signACLCount','signAppListACLCount','signAllowAnyACLCount','signEmptyACLCount',
            'signTrustedApplicationCount','codesignPathEntryCount','partitionACLCount','partitionIDCount',
            'applePartitionCount','appleToolPartitionCount','codesignPartitionCount','otherPartitionCount',
            'opaqueACLCount','unknownAuthorizationCount','ownerACLCount','ownerAllowAnyACLCount',
            'ownerTrustedApplicationCount','creatorOwnerPathEntryCount'}
ACL_PARTITIONS={'partitionACLCount','partitionIDCount','applePartitionCount','appleToolPartitionCount',
                'codesignPartitionCount','otherPartitionCount'}

def key_acl_summary(value):
    if not isinstance(value,dict) or set(value)!=ACL_COUNTS|{'sameOwnedKeychain'}:
        raise ValueError('Invalid owned ACL summary fields')
    for name in ACL_COUNTS:
        if type(value[name]) is not int or not 0<=value[name]<=2048:raise ValueError('Invalid owned ACL count')
    if (value['privateKeyCount']!=1 or value['sameOwnedKeychain'] is not True or not 1<=value['aclCount']<=32
            or value['signACLCount']!=1 or value['signAppListACLCount']!=1 or value['signAllowAnyACLCount']!=0
            or value['signEmptyACLCount']!=0 or not 1<=value['signTrustedApplicationCount']<=16
            or value['ownerACLCount']!=1 or value['ownerAllowAnyACLCount']!=0
            or not 1<=value['ownerTrustedApplicationCount']<=16 or value['creatorOwnerPathEntryCount']!=1
            or value['codesignPathEntryCount']>value['signTrustedApplicationCount']
            or value['partitionACLCount']>value['aclCount'] or value['opaqueACLCount']>value['aclCount']
            or value['partitionIDCount']>16*value['partitionACLCount']
            or sum(value[name] for name in ('applePartitionCount','appleToolPartitionCount','codesignPartitionCount','otherPartitionCount'))!=value['partitionIDCount']):
        raise ValueError('Inconsistent owned ACL summary')
    return value

def key_access_status(raw):
    # Schema 1 and 2 remain exact and cannot admit ACL extensions. Schema 3
    # permits only known bounded facts, never ACL strings/paths/labels/hex.
    if len(raw)>8192:raise ValueError('Owned ACL status byte budget')
    value=json.loads(raw)
    common={'schemaVersion','operation','stage','status','osStatus'}
    if (not isinstance(value,dict) or type(value.get('schemaVersion')) is not int or value.get('schemaVersion')!=3
            or value.get('operation') not in ('prepareCodesignAccess','inspectCodesignAccess')
            or type(value.get('osStatus')) is not int or not -(2**31)<=value['osStatus']<2**31):
        raise ValueError('Invalid owned ACL public status')
    if value.get('status')=='failed':
        allowed={'readInput','openKeychain','unlockKeychain','keychainStatus','legacyIdentitySearch',
                 'findStoredIdentity','matchLeaf','findRoot','privateKey','signChallenge','verifyChallenge','inspectKeyACL','prepareKeyACL'}
        if set(value)!=common or value['osStatus']==0 or value.get('stage') not in allowed:raise ValueError('Invalid owned ACL failure')
        return value
    extended={'aclBefore','aclAfter','classicACLChanged','fixtureOwnerPolicy'}
    if not extended<=set(value):raise ValueError('Missing owned ACL facts')
    if value['fixtureOwnerPolicy']!='current-importer-subject-before-import':raise ValueError('Unexpected owned owner policy')
    base={key:item for key,item in value.items() if key not in extended}
    base.update({'schemaVersion':2,'operation':'reopenIdentity'})
    reopened_identity_status(json.dumps(base).encode())
    before=key_acl_summary(value['aclBefore']); after=key_acl_summary(value['aclAfter'])
    preparing=value['operation']=='prepareCodesignAccess'
    if type(value['classicACLChanged']) is not bool or value['classicACLChanged'] is not preparing:
        raise ValueError('Invalid owned ACL publication fact')
    expected=dict(before)
    if preparing:
        expected['signTrustedApplicationCount']+=1; expected['codesignPathEntryCount']+=1
    if after!=expected:raise ValueError('Unexpected owned ACL change')
    return value

def prepare_owned_codesign_access(importer,request,keychain,password):
    common=dict(request, p12='',p12Password='')
    prepared=key_access_status(run([importer],input=json.dumps(dict(common,operation='prepareCodesignAccess')).encode(),
                                  private=True,public_status='aclPrepare'))
    # The existing partition command is retained, now scoped to private keys
    # only after the actual one private signing key and owner have been checked.
    run(['security','set-key-partition-list','-S','apple-tool:,apple:,codesign:','-t','private','-s','-k',password,keychain],private=True)
    inspected=key_access_status(run([importer],input=json.dumps(dict(common,operation='inspectCodesignAccess')).encode(),
                                   private=True,public_status='aclInspect'))
    for name in ('leafSHA256','rootSHA256'):
        expected=fingerprint(base64.b64decode(request['leafCertificate' if name=='leafSHA256' else 'rootCertificate'],validate=True))
        if prepared[name]!=expected or inspected[name]!=expected:raise ToolFailure('owned ACL identity mismatch',-1)
    before=prepared['aclAfter']; after=inspected['aclAfter']
    if any(before[name]!=after[name] for name in set(before)-ACL_PARTITIONS):
        raise ToolFailure('owned partition write changed classic ACL facts',-1)
    if (after['partitionACLCount']!=1 or after['partitionIDCount']!=3 or after['applePartitionCount']!=1
            or after['appleToolPartitionCount']!=1 or after['codesignPartitionCount']!=1 or after['otherPartitionCount']!=0
            or after['codesignPathEntryCount']<1):
        raise ToolFailure('owned partition write lacks actual required entries',-1)

def run(args,*,input=None,env=None,private=False,public_log=None,public_status=False,public_output_label=None,timeout_seconds=None,cleanup=False):
    if private and (public_log is not None or public_output_label is not None):
        raise ValueError('Private tool streams cannot become public logs')
    if public_status and not private:raise ValueError('Typed importer status is a separate private-input boundary')
    if str(args[0])=='openssl':args=[OPENSSL,*args[1:]]
    redacted=list(map(str,args))
    redacted=[public_text(value.encode()) for value in redacted]
    if redacted[0]=='security' and 'set-key-partition-list' in redacted:
        redacted[redacted.index('-k')+1]='<random-owned-password>'
    seconds=tool_timeout(args,timeout_seconds,cleanup)
    started=time.monotonic()
    try:result,timed_out=bounded_child(args,input,env,seconds)
    except ToolTimeout:
        result=subprocess.CompletedProcess(args,None,b'',b'');timed_out=True
        result.processStarted=False
        result.processCleanup={'hardKillAttempted':False,'drained':False,'childReaped':False,'pipesClosed':True,'issues':[]}
    elapsed=time.monotonic()-started
    RECORDS.append({'argv':redacted,'exitCode':result.returncode,'privateInputBytesRetained':False,
                    'timeoutSeconds':seconds,'timedOut':timed_out,'elapsedSeconds':elapsed,
                    'processCleanup':result.processCleanup})
    if timed_out or result.processCleanup['issues']:
        # Private stdin tools never forward argv or arbitrary stdout/stderr, even
        # when their partial stdout happens to resemble an importer success object.
        value={'schemaVersion':1,'status':'timeout' if timed_out else 'processFailure','timedOut':timed_out,
               'exitCode':124 if timed_out else 125,'processReturnCode':result.returncode,
               'processCleanup':result.processCleanup,
               'timeoutSeconds':seconds,'elapsedSeconds':elapsed,'processStarted':result.processStarted,
               'failedToolSucceeded':False,'codesignSuccessEstablishedByThisFailureRecord':False,'nativeTestsExecuted':0}
        if private:
            value.update({'tool':'private-owned-tool','privateCommandPublished':False,'privateStreamsPublished':False})
        else:
            value.update({'argv':redacted,'publicLog':Path(public_log).name if public_log else None,
                          'stdout':public_text(result.stdout),'stderr':public_text(result.stderr),
                          'truncated':len(result.stdout)>PUBLIC_DIAGNOSTIC_BYTES or len(result.stderr)>PUBLIC_DIAGNOSTIC_BYTES})
            if public_log:Path(public_log).write_text(public_text(result.stdout+result.stderr),encoding='utf-8')
        public_record('OWNED_TOOL_TIMEOUT' if timed_out else 'OWNED_TOOL_PROCESS_FAILURE',value)
        if result.processCleanup['issues']:
            raise ToolProcessFailure('private tool' if private else redacted[0],timed_out,result.returncode,result.processStarted,result.processCleanup['issues']) from None
        raise ToolTimeout('private tool' if private else redacted[0],seconds,result.returncode,result.processStarted) from None
    if public_log:Path(public_log).write_text(public_text(result.stdout+result.stderr),encoding='utf-8')
    if public_status:
        # A malformed/private stdout must remain suppressed even on failure.
        reopen=public_status=='reopen'
        acl=public_status in ('aclPrepare','aclInspect')
        try:
            status=(key_access_status if acl else (reopened_identity_status if reopen else identity_status))(result.stdout)
            if acl and status['operation']!=('prepareCodesignAccess' if public_status=='aclPrepare' else 'inspectCodesignAccess'):
                raise ValueError('Unexpected owned ACL operation')
        except (ValueError,UnicodeError,TypeError,RecursionError):
            status={'schemaVersion':3 if acl else (2 if reopen else 1),'stage':'readInput','status':'failed','osStatus':-1}
            if acl:status['operation']='prepareCodesignAccess' if public_status=='aclPrepare' else 'inspectCodesignAccess'
            elif reopen:status['operation']='reopenIdentity'
        public_record('OWNED_KEY_ACCESS_STATUS' if acl else ('OWNED_KEYCHAIN_REOPEN_STATUS' if reopen else 'OWNED_IDENTITY_STATUS'),status)
        if result.returncode==0 and (status.get('stage')!='complete' or status.get('status')!='passed'
                or status.get('privateKeySignatureVerified') is not True
                or status.get('codesignACLExecutionVerified') is not False):
            raise ToolFailure('owned importer public proof',-1)
    if public_output_label:
        public_record(public_output_label,{'argv':redacted,'exitCode':result.returncode,
            'stdout':public_text(result.stdout),'stderr':public_text(result.stderr),
            'truncated':len(result.stdout)>PUBLIC_DIAGNOSTIC_BYTES or len(result.stderr)>PUBLIC_DIAGNOSTIC_BYTES})
    if result.returncode:
        if not private:
            public_record('OWNED_PUBLIC_TOOL_FAILURE',{'schemaVersion':1,'status':'failed','argv':redacted,
                'exitCode':result.returncode,'publicLog':Path(public_log).name if public_log else None,
                'stdout':public_text(result.stdout),'stderr':public_text(result.stderr),
                'truncated':len(result.stdout)>PUBLIC_DIAGNOSTIC_BYTES or len(result.stderr)>PUBLIC_DIAGNOSTIC_BYTES,
                'failedToolSucceeded':False,'codesignSuccessEstablishedByThisFailureRecord':False,'nativeTestsExecuted':0})
        raise ToolFailure('private tool' if private else redacted[0],result.returncode)
    return result.stdout

def tlv(t,b):
    n=len(b);c=(n.bit_length()+7)//8
    return bytes([t])+(bytes([n]) if n<128 else bytes([128|c])+n.to_bytes(c,'big'))+b

def integer(n):
    v=n.to_bytes(max(1,(n.bit_length()+7)//8),'big');return tlv(2,(b'\0' if v[0]&128 else b'')+v)
def seq(*v):return tlv(0x30,b''.join(v))
def der(v):
    if isinstance(v,dict):return tlv(0x31,b''.join(sorted(seq(tlv(12,k.encode()),der(x)) for k,x in v.items())))
    if isinstance(v,list):return seq(*(der(x) for x in v))
    if isinstance(v,str):return tlv(12,v.encode())
    if isinstance(v,bytes):return tlv(4,v)
    if isinstance(v,datetime):return tlv(0x17,v.strftime('%y%m%d%H%M%SZ').encode())
    if isinstance(v,bool):return tlv(1,b'\xff' if v else b'\0')
    if isinstance(v,int):return integer(v)
    raise TypeError(type(v))
def fingerprint(raw):return hashlib.sha256(raw).hexdigest()

def create_owned_signing_identity(owned):
    # This one controlled fixture uses the public self-signed Code Signing
    # identity form documented by TN2206. It is the sole input shape, never a
    # fallback after codesign fails. It installs no root or trust preferences.
    # The same public certificate is the explicit code/profile test anchor;
    # none of these synthetic signatures assert Apple or device authorization.
    # Do not inherit a host openssl.cnf's v3_ca extensions: combining them with
    # -addext can emit duplicate critical OIDs. This fixed file is public only.
    configuration=owned/'public-self-signed-code-signing.cnf'
    configuration.write_bytes(b'[req]\ndistinguished_name=owned_dn\nprompt=no\n'
        b'[owned_dn]\nCN=Owned SDK Fixture Code\nOU=FIXTURE123\n'
        b'[owned_code_signing]\nbasicConstraints=critical,CA:FALSE\n'
        b'keyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning\n'
        b'subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always\n')
    key=run(['openssl','genpkey','-algorithm','RSA','-pkeyopt','rsa_keygen_bits:2048'],private=True)
    certificate=run(['openssl','req','-new','-x509','-sha256','-config',configuration,
        '-extensions','owned_code_signing','-key','/dev/stdin','-days','30',
        '-subj','/CN=Owned SDK Fixture Code/OU=FIXTURE123','-outform','DER'],input=key,private=True)
    return key,certificate

def export_owned_signing_identity(key, certificate_pem, password):
    # The self-signed certificate is the full chain. Adding it as -certfile
    # would duplicate the same certificate in the PKCS12 bag.
    env={'PATH':os.defpath,'OWNED_SYNTHETIC_P12_PASSWORD':password}
    return run(['openssl','pkcs12','-export','-inkey','/dev/stdin','-in',certificate_pem,
        '-passout','env:OWNED_SYNTHETIC_P12_PASSWORD','-keypbe','PBE-SHA1-3DES',
        '-certpbe','PBE-SHA1-3DES','-macalg','SHA1','-iter','2048'],input=key,env=env,private=True)

def main():
    a=argparse.ArgumentParser();a.add_argument('--output',type=Path,required=True);args=a.parse_args()
    if sys.platform!='darwin':raise SystemExit('Requires macOS/Xcode; no SDK execution was attempted.')
    # An outer producer deadline may request graceful termination. Let finally
    # clean only this producer's own Keychain; SIGKILL remains uncatchable.
    def terminate_producer(signum, frame):raise SystemExit(128+signum)
    signal.signal(signal.SIGTERM,terminate_producer)
    global OPENSSL,PRODUCER_DEADLINE
    PRODUCER_DEADLINE=time.monotonic()+PRODUCER_TIMEOUT_SECONDS
    candidates=[os.environ.get('YUEDU_FIXTURE_OPENSSL'),'/opt/homebrew/opt/openssl@3/bin/openssl','/usr/local/opt/openssl@3/bin/openssl',shutil.which('openssl')]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            # Selection probes are also bounded; a stalled candidate cannot consume
            # the native stage's allocation before the generator has even started.
            try:version=subprocess.run([candidate,'version'],capture_output=True,timeout=min(5,max(0.01,PRODUCER_DEADLINE-time.monotonic()))).stdout
            except subprocess.TimeoutExpired:continue
            if version.startswith(b'OpenSSL 3.'):
                OPENSSL=candidate;break
    else:raise RuntimeError('Existing OpenSSL 3 required; no package installation attempted')
    out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
    if any(out.iterdir()):raise RuntimeError('Output must be an empty controlled directory')
    records=[]
    source_files=['generate-sdk-owned-package.py','ImportOwnedIdentity.swift','OwnedIdentitySearch.h','OwnedIdentitySearch.c','main.c','extension.c','framework.c']
    for name in source_files:
        raw=(HERE/name).read_bytes();records.append({'path':name,'bytes':len(raw),'sha256':fingerprint(raw)})
    run(['openssl','version'],public_log=out/'openssl-version.log')
    run(['xcodebuild','-version'],public_log=out/'xcode-version.log')
    sdk=run(['xcrun','--sdk','iphoneos','--show-sdk-path']).decode().strip()
    run(['xcrun','--sdk','iphoneos','clang','--version'],public_log=out/'clang-version.log')
    with tempfile.TemporaryDirectory(prefix='owned-sdk-package-') as temporary:
        owned=Path(temporary);os.chmod(owned,0o700)
        keychain=owned/'synthetic.keychain-db'
        keychain_password=secrets.token_hex(24);p12_password=secrets.token_hex(24)
        PRIVATE_LITERALS.extend([keychain_password,p12_password])
        primary_error=None
        try:
            # Every key PEM is captured from stdout and only fed to a child's
            # stdin. No private_bytes file, P12 file or account credential.
            signing_key,root=create_owned_signing_identity(owned)
            # Root/leaf names are the existing public output contract. Their
            # DER is deliberately identical for this self-signed identity;
            # the previous CA-issued-leaf failure remains a separate record.
            leaf=root
            root_der=out/'root.cert.der';root_der.write_bytes(root)
            root_pem=out/'root.cert.pem';root_pem.write_bytes(run(['openssl','x509','-inform','DER','-outform','PEM'],input=root))
            (out/'leaf.cert.der').write_bytes(leaf)
            leaf_pem=out/'leaf.cert.pem';leaf_pem.write_bytes(run(['openssl','x509','-inform','DER','-outform','PEM'],input=leaf))
            at=datetime.now(timezone.utc).replace(microsecond=0)
            run(['openssl','verify','-purpose','any','-attime',str(int(at.timestamp())),'-CAfile',root_pem,leaf_pem],public_log=out/'owned-certificate-chain.log')
            public_record('OWNED_SIGNING_IDENTITY_SHAPE',{'schemaVersion':1,
                'shape':'self-signed-code-signing-identity','leafSHA256':fingerprint(leaf),
                'explicitCodeAndProfileAnchorSHA256':fingerprint(root),
                'globalTrustOrSearchListChanged':False,'codesignExecutionVerified':False})
            # No duplicate -certfile copy: the self-signed leaf is already the
            # complete one-certificate identity. PKCS12 and keys stay in memory.
            p12=export_owned_signing_identity(signing_key,leaf_pem,p12_password)
            importer=compile_owned_importer(owned,out)
            request={'path':str(keychain),'keychainPassword':keychain_password,'p12Password':p12_password,
                'p12':base64.b64encode(p12).decode(),'leafCertificate':base64.b64encode(leaf).decode(),
                'rootCertificate':base64.b64encode(root).decode()}
            run([importer],input=json.dumps(request).encode(),private=True,public_status=True)
            prepare_owned_codesign_access(importer,request,keychain,keychain_password)
            # Explicitly unlock only this existing owned Keychain in a fresh
            # process, then compare SecItem and legacy sign-use searches and
            # actually sign/verify with its persisted key. This is additional
            # diagnostics and bounded unlock, not a claim codesign will work.
            reopen_request={'operation':'reopenIdentity','path':str(keychain),'keychainPassword':keychain_password,
                'p12Password':'','p12':'','leafCertificate':base64.b64encode(leaf).decode(),
                'rootCertificate':base64.b64encode(root).decode()}
            reopened=reopened_identity_status(run([importer],input=json.dumps(reopen_request).encode(),private=True,public_status='reopen'))
            if reopened['leafSHA256']!=fingerprint(leaf) or reopened['rootSHA256']!=fingerprint(root):
                raise ToolFailure('owned reopen identity fingerprint mismatch',-1)
            del reopen_request,reopened
            run(['security','find-identity','-p','codesigning',keychain],public_output_label='OWNED_CODESIGN_IDENTITY_SEARCH')
            # Scoped diagnostics only: explicit public owned anchor, no Keychain
            # search, no network and no trust-settings installation. This proves
            # this certificate's actual code-sign policy, not codesign's later
            # cross-process identity lookup or system/global trust.
            run(['security','verify-cert','-c',out/'leaf.cert.der','-c',root_der,'-r',root_der,
                 '-p','codeSign','-L','-N','-q'],public_output_label='OWNED_EXPLICIT_ANCHOR_CODE_SIGN_POLICY')
            del request,p12
            root_key_memory=signing_key
            del signing_key
            app=owned/'Payload/Owned.app';app.mkdir(parents=True)
            framework=app/'Frameworks/OwnedFramework.framework';framework.mkdir(parents=True)
            common=['xcrun','--sdk','iphoneos','clang','-target','arm64-apple-ios17.0','-isysroot',sdk,'-O0','-g0']
            run(common+['-dynamiclib',HERE/'framework.c','-Wl,-install_name,@rpath/OwnedFramework.framework/OwnedFramework','-o',framework/'OwnedFramework'],public_log=out/'framework-clang.log')
            info={'CFBundleIdentifier':'test.owned.reader.framework','CFBundleExecutable':'OwnedFramework','CFBundlePackageType':'FMWK','CFBundleShortVersionString':'1.0','CFBundleVersion':'12'}
            (framework/'Info.plist').write_bytes(plistlib.dumps(info));(framework/'chapter.txt').write_bytes(b'abc')
            entries=[('.', 'test.owned.reader', None),('PlugIns/OwnedShare.appex','test.owned.reader.share','com.apple.share-services'),('PlugIns/OwnedWidget.appex','test.owned.reader.widget','com.apple.widgetkit-extension')]
            def cms(content,label):
                raw=owned/(label+'.public.content');raw.write_bytes(content)
                result=run(['openssl','cms','-sign','-binary','-nodetach','-noattr','-md','sha256','-signer',root_pem,'-inkey','/dev/stdin','-in',raw,'-outform','DER'],input=root_key_memory,private=True)
                return result
            identity=hashlib.sha1(leaf).hexdigest().upper()
            def codesign(bundle,identifier,entitlements=None):
                cmd=['codesign','--verbose=4','--force','--sign',identity,'--keychain',keychain,'--timestamp=none','--identifier',identifier,'--requirements','=designated => identifier "'+identifier+'"']
                if entitlements:cmd+=['--generate-entitlement-der','--entitlements',entitlements]
                cmd += [bundle]
                run(cmd,public_log=out/(identifier+'.codesign.log'))
            codesign(framework,'test.owned.reader.framework')
            for i,(path,identifier,point) in reversed(list(enumerate(entries))):
                bundle=app if path=='.' else app/path;bundle.mkdir(parents=True,exist_ok=True)
                flags=[] if path=='.' else ['-fapplication-extension']
                rpath='@executable_path/Frameworks' if path=='.' else '@executable_path/../../Frameworks'
                run(common+flags+[HERE/('main.c' if path=='.' else 'extension.c'),'-F',app/'Frameworks','-framework','OwnedFramework','-Wl,-rpath,'+rpath,'-o',bundle/'Owned'],public_log=out/(identifier+'.clang.log'))
                info={'CFBundleIdentifier':identifier,'CFBundleExecutable':'Owned','CFBundlePackageType':'APPL' if path=='.' else 'XPC!','CFBundleShortVersionString':'1.0','CFBundleVersion':'12'}
                if point:info['NSExtension']={'NSExtensionPointIdentifier':point}
                (bundle/'Info.plist').write_bytes(plistlib.dumps(info));(bundle/'chapter.txt').write_bytes(b'abc')
                claims={'application-identifier':'OLDPREFIX.'+identifier,'com.apple.developer.team-identifier':'FIXTURE123','com.apple.security.application-groups':['group.test.owned.reader'],'keychain-access-groups':['OLDPREFIX.'+identifier,'OLDPREFIX.shared'],'get-task-allow':True}
                props={'UUID':f'99999999-2222-3333-4444-{i:012d}','CreationDate':at-timedelta(minutes=5),'ExpirationDate':at+timedelta(days=2),'Platform':['iOS'],'TeamIdentifier':['FIXTURE123'],'ApplicationIdentifierPrefix':['OLDPREFIX'],'DeveloperCertificates':[hashlib.sha256(leaf).digest()],'Entitlements':claims}
                profile=cms(plistlib.dumps({'DER-Encoded-Profile':cms(der(props),str(i)+'-inner')}),str(i)+'-outer')
                (bundle/'embedded.mobileprovision').write_bytes(profile)
                ent=owned/(str(i)+'.public-entitlements.plist');ent.write_bytes(plistlib.dumps(claims))
                codesign(bundle,identifier,ent)
            # Existing CMS gate is exercised on actual codesign-produced CMS,
            # with its exact detached primary CD and explicit owned root.
            parsed=[]
            for label,binary in [('main',app/'Owned'),('share',app/'PlugIns/OwnedShare.appex/Owned'),('widget',app/'PlugIns/OwnedWidget.appex/Owned'),('framework',framework/'OwnedFramework')]:
                raw=binary.read_bytes();assert len(raw)<=67_108_864
                magic,cpu,sub,filetype,count,size=struct.unpack_from('<6I',raw)
                assert (magic,cpu,sub)==(0xfeedfacf,0x100000c,0) and filetype in (2,6)
                cursor=32;commands=[];signature=None
                for _ in range(count):
                    cmd,n=struct.unpack_from('<II',raw,cursor);assert n>=8 and cursor+n<=32+size;commands.append(cmd)
                    if cmd==0x1d:signature=struct.unpack_from('<II',raw,cursor+8)
                    cursor+=n
                assert cursor==32+size and 0xb in commands and signature
                offset,length=signature;assert offset+length==len(raw)
                magic,n,count=struct.unpack_from('>III',raw,offset);assert magic==0xfade0cc0
                blobs={}
                for index in range(count):
                    slot,pos=struct.unpack_from('>II',raw,offset+12+8*index);length=struct.unpack_from('>I',raw,offset+pos+4)[0];blobs[slot]=raw[offset+pos:offset+pos+length]
                cd=blobs[0];cms_bytes=blobs[0x10000][8:]
                cd_path=out/(label+'.primary.cd');cd_path.write_bytes(cd)
                cms_path=out/(label+'.detached.cms');cms_path.write_bytes(cms_bytes)
                verified=out/(label+'.verified.cd')
                run(['openssl','cms','-verify','-binary','-inform','DER','-in',cms_path,'-content',cd_path,'-CAfile',root_pem,'-purpose','any','-attime',str(int(at.timestamp())),'-out',verified],public_log=out/(label+'.original-cms.log'))
                assert verified.read_bytes()==cd
                (out/(label+'.macho')).write_bytes(raw)
                run(['xcrun','otool','-l',binary],public_log=out/(label+'.otool.log'))
                parsed.append({'role':label,'bytes':len(raw),'sha256':fingerprint(raw),'fileType':filetype,'loadCommands':commands,'originalDetachedCMSActuallyVerified':True})
            stream=io.BytesIO()
            with zipfile.ZipFile(stream,'w',compression=zipfile.ZIP_STORED) as z:
                for path in sorted(app.rglob('*')):
                    if path.is_symlink():raise RuntimeError('Unexpected generated symlink')
                    if path.is_file():
                        item=zipfile.ZipInfo('Payload/Owned.app/'+path.relative_to(app).as_posix(),(2026,10,21,0,0,0));item.create_system=3;item.external_attr=(0o100755 if path.name in ["Owned", "OwnedFramework"] else 0o100644)<<16;z.writestr(item,path.read_bytes())
            raw=stream.getvalue();assert len(raw)<=67_108_864
            with zipfile.ZipFile(io.BytesIO(raw)) as z:assert z.testzip() is None
            (out/'owned-sdk-package.ipa').write_bytes(raw)
            resource={'schema':1,'archive':base64.b64encode(raw).decode(),'anchor':base64.b64encode(root).decode(),'verificationEpochSeconds':int(at.timestamp()),'archiveSHA256':fingerprint(raw),'actualSDKProducedMachOs':parsed}
            (out/'owned-sdk-package.json').write_text(json.dumps(resource,separators=(',',':'))+'\n')
            run(['security','delete-keychain',keychain],private=True,timeout_seconds=CLEANUP_TIMEOUT_SECONDS,cleanup=True)
            keychain=None
            record={'schema':1,'sourceInputs':records,'commands':RECORDS,'actualSDKProducedMachOs':parsed,'generatedAt':at.isoformat(),'archiveSHA256':fingerprint(raw),'archiveBytes':len(raw),'privateKeyFilesOutsideKeychain':0,'temporaryOwnedKeychainDeleted':True,'privateMaterialArtifacts':0,'realAppleAccountUsed':False,'SwiftPackageCoordinatorExecuted':False,'producerToolBudgetSeconds':PRODUCER_TIMEOUT_SECONDS,'ownedToolBudgetsSeconds':TOOL_TIMEOUT_SECONDS,'cleanupToolBudgetSeconds':CLEANUP_TIMEOUT_SECONDS}
            record['publicOutputs']=[{'path':p.name,'bytes':p.stat().st_size,'sha256':fingerprint(p.read_bytes())} for p in sorted(out.iterdir()) if p.is_file()]
            (out/'sdk-produced-fixture-manifest.json').write_text(json.dumps(record,indent=2)+'\n')
        except BaseException as error:
            primary_error=error
            raise
        finally:
            if keychain is not None and keychain.exists():
                try:
                    run(['security','delete-keychain',keychain],private=True,timeout_seconds=CLEANUP_TIMEOUT_SECONDS,cleanup=True)
                    public_record('OWNED_KEYCHAIN_CLEANUP',{'status':'passed','exitCode':0,'privateCommandPublished':False})
                except Exception as cleanup_error:
                    public_record('OWNED_KEYCHAIN_CLEANUP',{'status':'failed','exitCode':cleanup_error.code if isinstance(cleanup_error,ToolFailure) else None,
                        'originalToolFailureRetained':primary_error is not None,'privateCommandPublished':False})
                    if primary_error is None:raise
    print('Owned SDK main/extensions/framework generated and original CMS verified; no private material published.')
if __name__=='__main__':main()
