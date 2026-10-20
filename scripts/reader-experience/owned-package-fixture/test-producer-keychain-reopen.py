"""Real portable child/report boundaries only; no macOS Keychain/codesign execution."""
from contextlib import redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
from unittest.mock import patch
import unittest

spec = importlib.util.spec_from_file_location('owned_reopen_producer', Path(__file__).with_name('generate-sdk-owned-package.py'))
producer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(producer)


class OwnedKeychainReopenReportTests(unittest.TestCase):
    def setUp(self):
        producer.RECORDS.clear()
        producer.PRIVATE_LITERALS.clear()
        producer.PRODUCER_DEADLINE = None

    def passed(self):
        # Synthetic reporter data test strict forwarding only. This cannot
        # stand in for actual Swift lookup, signing or a real codesign result.
        return {'schemaVersion': 2, 'operation': 'reopenIdentity', 'stage': 'complete', 'status': 'passed', 'osStatus': 0,
                'storedIdentityCount': 1, 'legacySigningIdentityCount': 1,
                'leafSHA256': '1' * 64, 'rootSHA256': '2' * 64,
                'privateKeySignatureVerified': True, 'codesignACLExecutionVerified': False,
                'keychainUnlockedBeforeRequest': False, 'keychainUnlocked': True, 'keychainReadable': True, 'keychainWritable': True}

    def child(self, status, code=0):
        return [sys.executable, '-c', 'import sys;sys.stdin.buffer.read();sys.stdout.write(' + repr(json.dumps(status)) + ');sys.exit(' + str(code) + ')']

    def test_actual_private_reporter_has_separate_reopen_schema_and_no_codesign_claim(self):
        output = io.StringIO()
        with redirect_stdout(output):
            result = producer.run(self.child(self.passed()), input=b'owned-private-password-canary', private=True, public_status='reopen')
        label, raw = output.getvalue().strip().split(' ', 1)
        self.assertEqual(label, 'OWNED_KEYCHAIN_REOPEN_STATUS')
        self.assertEqual(json.loads(raw), self.passed())
        self.assertEqual(producer.reopened_identity_status(result), self.passed())
        self.assertNotIn('owned-private-password-canary', output.getvalue())
        self.assertFalse(producer.RECORDS[-1]['privateInputBytesRetained'])

    def test_reopen_success_rejects_missing_extra_ambiguous_and_false_proof_fields(self):
        valid = self.passed()
        missing = dict(valid); missing.pop('legacySigningIdentityCount')
        cases = [missing, dict(valid, privateData='secret-canary'), dict(valid, operation='importIdentity'),
                 dict(valid, schemaVersion=True), dict(valid, storedIdentityCount=True),
                 dict(valid, legacySigningIdentityCount=0), dict(valid, legacySigningIdentityCount=2),
                 dict(valid, osStatus=True), dict(valid, leafSHA256='bad-fingerprint'),
                 dict(valid, privateKeySignatureVerified=1), dict(valid, keychainUnlocked=False),
                 dict(valid, keychainUnlockedBeforeRequest=1),
                 dict(valid, keychainReadable=False), dict(valid, keychainWritable=False),
                 dict(valid, codesignACLExecutionVerified=True)]
        for value in cases:
            with self.subTest(value=value), self.assertRaises(ValueError):
                producer.reopened_identity_status(json.dumps(value).encode())
        with self.assertRaises(ValueError):
            producer.identity_status(json.dumps(valid).encode())
        with self.assertRaises(ValueError):
            producer.reopened_identity_status(b' ' * 4097)

    def test_actual_malformed_private_report_suppresses_all_unknown_data(self):
        output = io.StringIO()
        status = dict(self.passed(), privateData='owned-secret-status-canary')
        with redirect_stdout(output), self.assertRaises(producer.ToolFailure):
            producer.run(self.child(status), input=b'owned-p12-canary', private=True, public_status='reopen')
        self.assertNotIn('owned-secret', output.getvalue())
        self.assertNotIn('owned-p12', output.getvalue())
        self.assertEqual(json.loads(output.getvalue().split(' ', 1)[1]),
                         {'schemaVersion': 2, 'operation': 'reopenIdentity', 'stage': 'readInput', 'status': 'failed', 'osStatus': -1})

    def test_actual_child_failure_cannot_be_accepted_from_a_passed_report(self):
        output = io.StringIO()
        with redirect_stdout(output), self.assertRaises(producer.ToolFailure) as failed:
            producer.run(self.child(self.passed(), 7), input=b'owned-private-canary', private=True, public_status='reopen')
        self.assertEqual(failed.exception.code, 7)
        self.assertEqual(producer.RECORDS[-1]['exitCode'], 7)
        self.assertFalse(json.loads(output.getvalue().split(' ', 1)[1])['codesignACLExecutionVerified'])

    def test_actual_unlock_failure_retains_only_the_typed_osstatus(self):
        status = {'schemaVersion': 2, 'operation': 'reopenIdentity', 'stage': 'unlockKeychain', 'status': 'failed', 'osStatus': -25293}
        output = io.StringIO()
        with redirect_stdout(output), self.assertRaises(producer.ToolFailure) as failed:
            producer.run(self.child(status, 1), input=b'owned-password-canary', private=True, public_status='reopen')
        self.assertEqual(failed.exception.code, 1)
        self.assertEqual(json.loads(output.getvalue().split(' ', 1)[1]), status)
        for changed in [dict(status, osStatus=0), dict(status, errorDescription='private-canary'), dict(status, stage='unknown')]:
            with self.assertRaises(ValueError):
                producer.reopened_identity_status(json.dumps(changed).encode())


    def compile_fixture(self, c_exit=0, swift_exit=0):
        # Actual Python children check command ordering/failure/public logs.
        # This is not a C compiler, Swift typecheck, Keychain or codesign proof.
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name); owned = root/'owned'; public = root/'public'
        owned.mkdir(); public.mkdir()
        tool = root/'public-compiler.py'
        tool.write_text("""
import pathlib,sys
args=sys.argv[1:]
kind=args[2]
print('owned '+kind+' public compiler boundary')
if kind=='clang':
    if int(sys.argv[-1]):sys.exit(int(sys.argv[-1]))
    pathlib.Path(args[args.index('-o')+1]).write_bytes(b'owned-object-marker')
else:
    if not pathlib.Path(args[args.index('-import-objc-header')+1]).is_file():sys.exit(66)
    if b'owned-object-marker'!=pathlib.Path(args[args.index('-o')-1]).read_bytes():sys.exit(67)
    if int(sys.argv[-1]):sys.exit(int(sys.argv[-1]))
    pathlib.Path(args[args.index('-o')+1]).write_bytes(b'owned-tool-marker')
""",encoding='utf8')
        original = producer.run
        commands = []
        def actual_child(argv, **kwargs):
            commands.append([str(item) for item in argv])
            code = c_exit if argv[3]=='clang' else swift_exit
            return original([sys.executable, tool, *argv[1:], str(code)], **kwargs)
        return owned, public, commands, actual_child

    def test_actual_compile_children_require_public_c_then_formal_header_and_object_link(self):
        owned, public, commands, child = self.compile_fixture()
        with patch.object(producer,'run',side_effect=child):
            result = producer.compile_owned_importer(owned,public)
        self.assertEqual(result.read_bytes(),b'owned-tool-marker')
        self.assertEqual(len(commands),2)
        self.assertEqual(commands[0][:4],['xcrun','--sdk','macosx','clang'])
        self.assertIn('-Werror=implicit-function-declaration',commands[0])
        self.assertEqual(commands[0][commands[0].index('-c')+1],str(producer.HERE/'OwnedIdentitySearch.c'))
        self.assertEqual(commands[1][:4],['xcrun','--sdk','macosx','swiftc'])
        self.assertEqual(commands[1][commands[1].index('-import-objc-header')+1],str(producer.HERE/'OwnedIdentitySearch.h'))
        self.assertEqual(commands[1][commands[1].index('-o')-1],str(owned/'OwnedIdentitySearch.o'))
        log = (public/'import-tool-compile.log').read_text()
        self.assertIn('owned clang public compiler boundary',log)
        self.assertIn('owned swiftc public compiler boundary',log)
        self.assertEqual({path.name for path in public.iterdir()},{'import-tool-compile.log'})

    def test_actual_c_compile_failure_remains_nonzero_and_never_starts_swift(self):
        owned, public, commands, child = self.compile_fixture(c_exit=7)
        output = io.StringIO()
        with redirect_stdout(output), patch.object(producer,'run',side_effect=child), self.assertRaises(producer.ToolFailure) as failed:
            producer.compile_owned_importer(owned,public)
        self.assertEqual(failed.exception.code,7)
        self.assertEqual(len(commands),1)
        self.assertFalse((owned/'import-owned-identity').exists())
        self.assertIn('OWNED_PUBLIC_TOOL_FAILURE',output.getvalue())
        self.assertIn('owned clang public compiler boundary',output.getvalue())

    def test_actual_swift_compile_failure_preserves_its_exit_and_public_diagnostic(self):
        owned, public, commands, child = self.compile_fixture(swift_exit=9)
        output = io.StringIO()
        with redirect_stdout(output), patch.object(producer,'run',side_effect=child), self.assertRaises(producer.ToolFailure) as failed:
            producer.compile_owned_importer(owned,public)
        self.assertEqual(failed.exception.code,9)
        self.assertEqual(len(commands),2)
        self.assertFalse((owned/'import-owned-identity').exists())
        self.assertIn('owned swiftc public compiler boundary',output.getvalue())
        self.assertIn('owned swiftc public compiler boundary',(public/'import-tool-compile.log').read_text())

    def signing_identity_fixture(self, certificate_exit=0):
        # Actual portable child processes exercise the private data/command
        # boundary only. Their markers are not certificates, C or codesign.
        directory=tempfile.TemporaryDirectory(); self.addCleanup(directory.cleanup)
        tool=Path(directory.name)/'identity-boundary.py'
        tool.write_text('''
import os,sys
args=sys.argv[1:]; operation=args[0]
if operation=='genpkey':sys.stdout.buffer.write(b'owned-private-identity-key-canary')
elif operation=='req':
    if sys.stdin.buffer.read()!=b'owned-private-identity-key-canary':sys.exit(79)
    if int(args[-1]):
        sys.stdout.buffer.write(b'owned-private-identity-key-canary')
        sys.stderr.buffer.write(b'owned-private-identity-key-canary');sys.exit(int(args[-1]))
    sys.stdout.buffer.write(b'owned-public-self-signed-certificate-marker')
elif operation=='pkcs12':
    if sys.stdin.buffer.read()!=b'owned-private-identity-key-canary':sys.exit(80)
    if os.environ.get('OWNED_SYNTHETIC_P12_PASSWORD')!='owned-p12-password-canary':sys.exit(81)
    if '-certfile' in args:sys.exit(82)
    sys.stdout.buffer.write(b'owned-private-p12-marker')
else:sys.exit(83)
''',encoding='utf-8')
        original=producer.run; commands=[]
        def child(argv,**kwargs):
            commands.append(([str(v) for v in argv],dict(kwargs)))
            return original([sys.executable,tool,*argv[1:],str(certificate_exit)],**kwargs)
        return commands,child,Path(directory.name)

    def test_actual_owned_identity_children_use_one_key_and_self_signed_code_signing_constraints(self):
        commands,child,owned=self.signing_identity_fixture(); output=io.StringIO()
        with redirect_stdout(output),patch.object(producer,'run',side_effect=child):
            key,certificate=producer.create_owned_signing_identity(owned)
        self.assertEqual(key,b'owned-private-identity-key-canary')
        self.assertEqual(certificate,b'owned-public-self-signed-certificate-marker')
        self.assertEqual(output.getvalue(),'')
        self.assertEqual([argv[1] for argv,_ in commands],['genpkey','req'])
        argv,options=commands[1]
        for argument in ('-x509','-sha256','-config','-extensions','owned_code_signing'):
            self.assertIn(argument,argv)
        configuration=Path(argv[argv.index('-config')+1]).read_bytes()
        for declaration in (b'basicConstraints=critical,CA:FALSE',b'keyUsage=critical,digitalSignature',b'extendedKeyUsage=codeSigning'):
            self.assertEqual(configuration.count(declaration),1)
        self.assertNotIn(b'CA:TRUE',configuration)
        self.assertNotIn('-addext',argv)
        self.assertNotIn('-CAkey',argv)
        self.assertEqual(options['input'],key)
        self.assertTrue(all(kwargs.get('private') is True for _,kwargs in commands))

    def test_actual_self_signed_identity_failure_stays_nonzero_without_an_alternative_shape(self):
        commands,child,owned=self.signing_identity_fixture(certificate_exit=8); output=io.StringIO()
        with redirect_stdout(output),patch.object(producer,'run',side_effect=child),self.assertRaises(producer.ToolFailure) as failed:
            producer.create_owned_signing_identity(owned)
        self.assertEqual(failed.exception.code,8)
        self.assertEqual(len(commands),2)
        self.assertEqual(output.getvalue(),'')
        self.assertFalse(producer.RECORDS[-1]['privateInputBytesRetained'])

    def test_actual_self_signed_pkcs12_child_binds_the_same_key_and_only_one_certificate(self):
        commands,child,_=self.signing_identity_fixture(); output=io.StringIO()
        with redirect_stdout(output),patch.object(producer,'run',side_effect=child):
            result=producer.export_owned_signing_identity(b'owned-private-identity-key-canary',
                Path('owned-public-certificate.pem'),'owned-p12-password-canary')
        self.assertEqual(result,b'owned-private-p12-marker')
        self.assertEqual(output.getvalue(),'')
        self.assertEqual(len(commands),1)
        argv,options=commands[0]
        self.assertIn('owned-public-certificate.pem',argv)
        self.assertNotIn('-certfile',argv)
        self.assertNotIn('owned-p12-password-canary',argv)
        self.assertTrue(options['private'])
        self.assertEqual(options['input'],b'owned-private-identity-key-canary')


class OwnedKeyACLReportTests(unittest.TestCase):
    # Reuse reporter helpers without executing the unchanged eleven methods
    # twice. These still do not execute macOS C/Swift or keychain ACL code.
    setUp=OwnedKeychainReopenReportTests.setUp
    passed=OwnedKeychainReopenReportTests.passed
    child=OwnedKeychainReopenReportTests.child
    def summary(self):
        return dict(privateKeyCount=1,sameOwnedKeychain=True,aclCount=4,signACLCount=1,signAppListACLCount=1,
                    signAllowAnyACLCount=0,signEmptyACLCount=0,signTrustedApplicationCount=2,codesignPathEntryCount=1,
                    partitionACLCount=1,partitionIDCount=1,applePartitionCount=0,appleToolPartitionCount=0,
                    codesignPartitionCount=0,otherPartitionCount=1,opaqueACLCount=0,unknownAuthorizationCount=0,
                    ownerACLCount=1,ownerAllowAnyACLCount=0,ownerTrustedApplicationCount=1,creatorOwnerPathEntryCount=1)

    def access(self,prepare=True):
        value=self.passed(); before=self.summary(); after=dict(before)
        if prepare:
            after['signTrustedApplicationCount']+=1; after['codesignPathEntryCount']+=1
        else:
            before.update(signTrustedApplicationCount=3,codesignPathEntryCount=2,partitionIDCount=3,
                          applePartitionCount=1,appleToolPartitionCount=1,codesignPartitionCount=1,otherPartitionCount=0)
            after=dict(before)
        value.update(schemaVersion=3,operation='prepareCodesignAccess' if prepare else 'inspectCodesignAccess',
                     aclBefore=before,aclAfter=after,classicACLChanged=prepare,fixtureOwnerPolicy='current-importer-subject-before-import')
        return value

    def test_actual_acl_reporter_declassifies_only_schema3_counts_and_preserves_no_codesign_claim(self):
        for prepare in (True,False):
            value=self.access(prepare); output=io.StringIO()
            with redirect_stdout(output):
                raw=producer.run(self.child(value),input=b'private-owned-acl-canary',private=True,
                                 public_status='aclPrepare' if prepare else 'aclInspect')
            self.assertEqual(producer.key_access_status(raw),value)
            label,text=output.getvalue().strip().split(' ',1)
            self.assertEqual(label,'OWNED_KEY_ACCESS_STATUS'); self.assertEqual(json.loads(text),value)
            self.assertNotIn('private-owned-acl-canary',output.getvalue())
            with self.assertRaises(ValueError):producer.reopened_identity_status(raw)
            with self.assertRaises(ValueError):producer.identity_status(raw)

    def test_acl_schema_rejects_unknown_payloads_counts_and_inconsistent_append(self):
        valid=self.access(); cases=[]
        for name,changed in [('privateKeyCount',True),('sameOwnedKeychain',1),('aclCount',33),
                             ('signAllowAnyACLCount',1),('signTrustedApplicationCount',17),
                             ('partitionIDCount',17),('otherPartitionCount',False),('ownerACLCount',0),
                             ('ownerAllowAnyACLCount',1),('creatorOwnerPathEntryCount',0)]:
            item=json.loads(json.dumps(valid)); item['aclBefore'][name]=changed; cases.append(item)
        item=json.loads(json.dumps(valid)); item['aclBefore']['rawACL']='secret-canary'; cases.append(item)
        item=json.loads(json.dumps(valid)); item['aclAfter']['codesignPathEntryCount']-=1; cases.append(item)
        cases.extend([dict(valid,classicACLChanged=False),dict(valid,classicACLChanged=1),
                      dict(valid,operation='reopenIdentity'),dict(valid,rawPrivateKey='canary'),dict(valid,schemaVersion=True),
                      dict(valid,fixtureOwnerPolicy='all-applications')])
        for item in cases:
            with self.subTest(item=item),self.assertRaises(ValueError):producer.key_access_status(json.dumps(item).encode())
        with self.assertRaises(ValueError):producer.key_access_status(b' '*8193)

    def test_actual_acl_malformed_or_cross_operation_private_output_stays_suppressed(self):
        for value in (dict(self.access(),rawACL='owned-acl-secret-canary'),self.access(False)):
            output=io.StringIO()
            with redirect_stdout(output),self.assertRaises(producer.ToolFailure):
                producer.run(self.child(value),input=b'owned-password-canary',private=True,public_status='aclPrepare')
            self.assertNotIn('secret-canary',output.getvalue()); self.assertNotIn('password-canary',output.getvalue())
            self.assertEqual(json.loads(output.getvalue().split(' ',1)[1]),
                             dict(schemaVersion=3,operation='prepareCodesignAccess',stage='readInput',status='failed',osStatus=-1))
        failure=dict(schemaVersion=3,operation='prepareCodesignAccess',stage='prepareKeyACL',status='failed',osStatus=-25308)
        output=io.StringIO()
        with redirect_stdout(output),self.assertRaises(producer.ToolFailure) as failed:
            producer.run(self.child(failure,7),input=b'owned-password-canary',private=True,public_status='aclPrepare')
        self.assertEqual(failed.exception.code,7); self.assertEqual(json.loads(output.getvalue().split(' ',1)[1]),failure)

    def pipeline(self,partition_exit=0,invalid_inspect=None):
        import base64
        request=dict(path='owned-fixture.keychain-db',keychainPassword='owned-password-canary',p12Password='private-p12-canary',
                     p12='cHJpdmF0ZQ==',leafCertificate=base64.b64encode(b'owned-public-leaf').decode(),
                     rootCertificate=base64.b64encode(b'owned-public-root').decode())
        original=producer.run; commands=[]
        def actual(argv,**kwargs):
            commands.append(([str(v) for v in argv],dict(kwargs)))
            if argv[0]=='security':
                return original([sys.executable,'-c','import sys;sys.stdout.write("owned-private-ACL-noise");sys.exit('+str(partition_exit)+')'],**kwargs)
            private=json.loads(kwargs['input']); preparing=private['operation']=='prepareCodesignAccess'
            self.assertEqual(private['p12'],''); self.assertEqual(private['p12Password'],'')
            value=self.access(preparing)
            value['leafSHA256']=producer.fingerprint(b'owned-public-leaf'); value['rootSHA256']=producer.fingerprint(b'owned-public-root')
            if not preparing and invalid_inspect is not None:invalid_inspect(value)
            return original(self.child(value),**kwargs)
        return request,commands,actual

    def test_actual_pipeline_checks_unique_owned_key_before_private_only_partition_then_fresh_inspection(self):
        request,commands,actual=self.pipeline(); output=io.StringIO()
        with redirect_stdout(output),patch.object(producer,'run',side_effect=actual):
            producer.prepare_owned_codesign_access('owned-importer',request,request['path'],request['keychainPassword'])
        self.assertEqual(len(commands),3)
        self.assertEqual(json.loads(commands[0][1]['input'])['operation'],'prepareCodesignAccess')
        self.assertEqual(commands[1][0],['security','set-key-partition-list','-S','apple-tool:,apple:,codesign:',
                                       '-t','private','-s','-k','owned-password-canary','owned-fixture.keychain-db'])
        self.assertEqual(json.loads(commands[2][1]['input'])['operation'],'inspectCodesignAccess')
        self.assertTrue(all(options['private'] for _,options in commands))
        for canary in ('owned-password-canary','private-p12-canary','owned-private-ACL-noise'):
            self.assertNotIn(canary,output.getvalue())
        self.assertNotIn('codesignExecutionVerified": true',output.getvalue())

    def test_actual_partition_failure_remains_nonzero_and_blocks_fresh_read(self):
        request,commands,actual=self.pipeline(partition_exit=9)
        with redirect_stdout(io.StringIO()),patch.object(producer,'run',side_effect=actual),self.assertRaises(producer.ToolFailure) as failed:
            producer.prepare_owned_codesign_access('owned-importer',request,request['path'],request['keychainPassword'])
        self.assertEqual(failed.exception.code,9); self.assertEqual(len(commands),2)

    def test_actual_fresh_inspection_rejects_unapplied_partition_or_changed_classic_facts(self):
        def missing_partition(value):
            for key in ('aclBefore','aclAfter'):
                value[key].update(partitionIDCount=1,applePartitionCount=0,appleToolPartitionCount=0,codesignPartitionCount=0,otherPartitionCount=1)
        def changed_classic(value):
            for key in ('aclBefore','aclAfter'):value[key]['unknownAuthorizationCount']=1
        for change in (missing_partition,changed_classic):
            request,commands,actual=self.pipeline(invalid_inspect=change)
            with redirect_stdout(io.StringIO()),patch.object(producer,'run',side_effect=actual),self.assertRaises(producer.ToolFailure):
                producer.prepare_owned_codesign_access('owned-importer',request,request['path'],request['keychainPassword'])
            self.assertEqual(len(commands),3)


if __name__ == '__main__':
    unittest.main(verbosity=2)
