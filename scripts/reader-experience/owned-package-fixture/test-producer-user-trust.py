"""Portable protocol/process tests only: no macOS trust, keys or codesign execution."""
from contextlib import redirect_stdout
import base64
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
from unittest.mock import patch
import unittest

spec=importlib.util.spec_from_file_location('owned_user_trust_producer',Path(__file__).with_name('generate-sdk-owned-package.py'))
producer=importlib.util.module_from_spec(spec);spec.loader.exec_module(producer)

class OwnedTemporaryUserTrustTests(unittest.TestCase):
    def setUp(self):
        producer.RECORDS.clear();producer.PRIVATE_LITERALS.clear();producer.PRODUCER_DEADLINE=None
        self.leaf=b'public-owned-protocol-fixture-not-a-certificate'
        self.request={'path':'owned-test.keychain','keychainPassword':'secret-input-canary','p12Password':'',
                      'p12':'','leafCertificate':base64.b64encode(self.leaf).decode(),
                      'rootCertificate':base64.b64encode(self.leaf).decode()}

    def passed(self,operation,*,absent=False):
        remove=operation=='removeOwnedUserTrust';install=operation=='installOwnedUserTrust'
        return {'schemaVersion':4,'operation':operation,'stage':'complete','status':'passed','osStatus':0,
                'certificateSHA256':producer.fingerprint(self.leaf),'domain':'user','policy':'codeSign',
                'disposableGitHubHostedRunner':True,'authorizationPreflightPassed':not (remove and absent),
                'priorSettingsAbsent':not remove or absent,'settingsEntryCount':1 if install else 0,
                'temporaryUserDomainTrustChanged':install or (remove and not absent),'cleanupVerified':remove,
                'adminSystemTrustOrSearchListChanged':False,'codesignExecutionVerified':False}

    def child(self,status,code=0,action=''):
        return [sys.executable,'-c','import sys,pathlib;sys.stdin.buffer.read();'+action+
                'sys.stdout.write('+repr(json.dumps(status))+');sys.stderr.write("private-child-stderr-canary");sys.exit('+str(code)+')']

    def scope(self):
        with patch.object(producer,'require_owned_hosted_runner'):
            return producer.OwnedUserTrustScope('owned-importer',self.request,Path('owned-test.keychain'))

    def routed_children(self,scope,state,order,fail_install=0,fail_cleanup=0):
        actual_run=producer.run
        sha=producer.hashlib.sha1(self.leaf).hexdigest().upper()
        def route(args,**kwargs):
            if str(args[0])=='owned-importer':
                op=json.loads(kwargs['input'])['operation'];order.append(op)
                if op=='installOwnedUserTrust':
                    action='pathlib.Path('+repr(str(state))+').write_text("owned-effect");'
                    status=self.passed(op);code=fail_install
                elif op=='removeOwnedUserTrust':
                    existed=state.exists();status=self.passed(op,absent=not existed);code=fail_cleanup
                    action='' if code else 'pathlib.Path('+repr(str(state))+').unlink(missing_ok=True);'
                else:status=self.passed(op);code=0;action=''
                # Real subprocess + original strict private-output boundary.
                return actual_run(self.child(status,code,action),**kwargs)
            if str(args[0])=='security':
                order.append('valid:'+str(int(state.exists())))
                text=('  1) '+sha+' "Owned protocol identity"\n     1 valid identities found\n') if state.exists() else '     0 valid identities found\n'
                return actual_run([sys.executable,'-c','import sys;sys.stdout.write('+repr(text)+')'],**kwargs)
            self.fail('Unexpected command route')
        return route

    def test_requires_all_hosted_runner_facts_before_any_mutation_capability(self):
        valid={'GITHUB_ACTIONS':'true','RUNNER_ENVIRONMENT':'github-hosted','RUNNER_OS':'macOS'}
        with patch.object(producer.sys,'platform','darwin'),patch.dict(producer.os.environ,valid,clear=True):
            producer.require_owned_hosted_runner()
        cases=[{},dict(valid,GITHUB_ACTIONS='false'),dict(valid,RUNNER_ENVIRONMENT='self-hosted'),dict(valid,RUNNER_OS='Windows')]
        for value in cases:
            with self.subTest(value=value),patch.object(producer.sys,'platform','darwin'),patch.dict(producer.os.environ,value,clear=True),self.assertRaises(producer.ToolFailure):
                producer.require_owned_hosted_runner()
        self.assertEqual(producer.RECORDS,[])

    def test_schema4_rejects_unknown_missing_scope_and_inconsistent_cleanup_facts(self):
        for op in producer.OWNED_USER_TRUST_OPERATIONS:
            valid=self.passed(op)
            self.assertEqual(producer.owned_user_trust_status(json.dumps(valid).encode(),op),valid)
            bad=dict(valid);bad.pop('priorSettingsAbsent')
            vectors=[bad,dict(valid,privateKey='secret-canary'),dict(valid,schemaVersion=True),dict(valid,settingsEntryCount=True),
                     dict(valid,domain='admin'),dict(valid,policy='basic'),dict(valid,certificateSHA256='1'),
                     dict(valid,adminSystemTrustOrSearchListChanged=True),dict(valid,codesignExecutionVerified=True),
                     dict(valid,temporaryUserDomainTrustChanged=not valid['temporaryUserDomainTrustChanged'])]
            for value in vectors:
                with self.subTest(op=op,value=value),self.assertRaises(ValueError):producer.owned_user_trust_status(json.dumps(value).encode(),op)
        absent=self.passed('removeOwnedUserTrust',absent=True)
        self.assertEqual(producer.owned_user_trust_status(json.dumps(absent).encode(),'removeOwnedUserTrust'),absent)
        duplicate=json.dumps(self.passed('installOwnedUserTrust')).replace('"domain": "user"','"domain": "admin", "domain": "user"')
        with self.assertRaises(ValueError):producer.owned_user_trust_status(duplicate.encode(),'installOwnedUserTrust')
        with self.assertRaises(ValueError):producer.owned_user_trust_status(b' '*4097,'installOwnedUserTrust')

    def test_actual_private_child_declassifies_only_exact_status_and_preserves_nonzero(self):
        op='installOwnedUserTrust';output=io.StringIO()
        with redirect_stdout(output):raw=producer.run(self.child(self.passed(op)),input=b'private-input-canary',private=True,public_status=op)
        self.assertEqual(producer.owned_user_trust_status(raw,op),self.passed(op))
        self.assertNotIn('private-input-canary',output.getvalue());self.assertNotIn('private-child-stderr-canary',output.getvalue())
        self.assertEqual(json.loads(output.getvalue().split(' ',1)[1]),self.passed(op))
        output=io.StringIO()
        with redirect_stdout(output),self.assertRaises(producer.ToolFailure) as failure:
            producer.run(self.child(self.passed(op),7),input=b'private-input-canary',private=True,public_status=op)
        self.assertEqual(failure.exception.code,7)
        output=io.StringIO()
        with redirect_stdout(output),self.assertRaises(producer.ToolFailure):
            producer.run(self.child(dict(self.passed(op),privateKey='secret-report-canary')),input=b'private-input-canary',private=True,public_status=op)
        self.assertNotIn('secret-report-canary',output.getvalue())

    def test_exact_valid_identity_parser_rejects_foreign_duplicates_unknown_and_missing_summary(self):
        sha='A'*40;line='  1) '+sha+' "Owned"\n'
        self.assertEqual(producer.exact_valid_owned_identity(b'  0 valid identities found\n',sha),0)
        self.assertEqual(producer.exact_valid_owned_identity((line+'  1 valid identities found\n').encode(),sha),1)
        cases=[line,line+'  0 valid identities found\n',line+line+'  2 valid identities found\n',
               line.replace(sha,'B'*40)+'  1 valid identities found\n',line+'unknown\n  1 valid identities found\n',
               '  0 valid identities found\n  0 valid identities found\n']
        for text in cases:
            with self.subTest(text=text),self.assertRaises(ValueError):producer.exact_valid_owned_identity(text.encode(),sha)

    def test_actual_child_pipeline_installs_reads_then_cleans_exact_scope_in_order(self):
        scope=self.scope();order=[];output=io.StringIO()
        with tempfile.TemporaryDirectory() as directory:
            state=Path(directory)/'effect'
            with redirect_stdout(output),patch.object(producer,'run',self.routed_children(scope,state,order)):
                scope.install();self.assertTrue(state.exists());self.assertTrue(scope.cleanup_intent)
                scope.cleanup();self.assertFalse(state.exists());self.assertFalse(scope.cleanup_intent)
            self.assertEqual(order,['valid:0','preflightOwnedUserTrust','installOwnedUserTrust','valid:1','removeOwnedUserTrust','valid:0'])
        self.assertTrue(scope.installed);self.assertTrue(scope.cleaned)

    def test_lost_install_ack_retains_cleanup_intent_and_removes_actual_child_effect(self):
        scope=self.scope();order=[];output=io.StringIO()
        with tempfile.TemporaryDirectory() as directory:
            state=Path(directory)/'effect'
            with redirect_stdout(output),patch.object(producer,'run',self.routed_children(scope,state,order,fail_install=7)):
                with self.assertRaises(producer.ToolFailure) as primary:scope.install()
                self.assertEqual(primary.exception.code,7);self.assertTrue(state.exists());self.assertTrue(scope.cleanup_intent)
                self.assertIsNone(producer.finish_owned_user_trust(scope,primary.exception))
                self.assertFalse(state.exists());self.assertTrue(scope.cleaned)
        self.assertNotIn('secret-input-canary',output.getvalue())
        self.assertEqual(order,['valid:0','preflightOwnedUserTrust','installOwnedUserTrust','removeOwnedUserTrust','valid:0'])

    def test_cleanup_failure_retains_original_error_and_reports_unremoved_trust_separately(self):
        scope=self.scope();order=[];output=io.StringIO()
        with tempfile.TemporaryDirectory() as directory:
            state=Path(directory)/'effect'
            with redirect_stdout(output),patch.object(producer,'run',self.routed_children(scope,state,order,fail_cleanup=9)):
                scope.install();primary=producer.ToolFailure('codesign',1)
                cleanup=producer.finish_owned_user_trust(scope,primary)
                self.assertIsInstance(cleanup,producer.ToolFailure);self.assertEqual(cleanup.code,9)
                self.assertEqual(primary.code,1);self.assertTrue(state.exists());self.assertTrue(scope.cleanup_intent)
            facts=json.loads(output.getvalue().split('OWNED_USER_TRUST_CLEANUP_FAILURE ',1)[1])
            self.assertTrue(facts['originalToolFailureRetained']);self.assertTrue(facts['temporaryUserTrustMayRemain'])
            self.assertNotIn('private-child-stderr-canary',output.getvalue())

    def test_preflight_failure_blocks_install_and_does_not_claim_cleanup_authority(self):
        scope=self.scope();order=[];actual_run=producer.run;output=io.StringIO()
        def route(args,**kwargs):
            if str(args[0])=='security':return actual_run([sys.executable,'-c','print("  0 valid identities found")'],**kwargs)
            op=json.loads(kwargs['input'])['operation'];order.append(op)
            status={'schemaVersion':4,'operation':op,'stage':'authorizeUserTrust','status':'failed','osStatus':-60007}
            return actual_run(self.child(status,1),**kwargs)
        with redirect_stdout(output),patch.object(producer,'run',route),self.assertRaises(producer.ToolFailure):scope.install()
        self.assertEqual(order,['preflightOwnedUserTrust']);self.assertFalse(scope.cleanup_intent)
        self.assertIsNone(producer.finish_owned_user_trust(scope,None))

class OwnedTemporaryAdminTrustTests(unittest.TestCase):
    """Portable child markers only; never sudo/root/SecTrustSettings execution."""
    setUp = OwnedTemporaryUserTrustTests.setUp
    child = OwnedTemporaryUserTrustTests.child

    def passed(self,operation,*,absent=False):
        remove=operation=='removeOwnedAdminTrust';install=operation=='installOwnedAdminTrust'
        return {'schemaVersion':5,'operation':operation,'stage':'complete','status':'passed','osStatus':0,
            'certificateSHA256':producer.fingerprint(self.leaf),'domain':'admin','policy':'codeSign',
            'disposableGitHubHostedRunner':True,'effectiveUID':0,'rootSelfDeadlineSeconds':8 if remove else 18,
            'rootMonotonicDeadlineNS':3_000_000_000,
            'authorizationPreflightPassed':False,'priorSettingsAbsent':not remove or absent,
            'settingsEntryCount':1 if install else 0,'temporaryAdminDomainTrustChanged':install or (remove and not absent),
            'cleanupVerified':remove,'userSystemTrustOrSearchListChanged':False,'codesignExecutionVerified':False}

    def scope(self):
        with patch.object(producer,'require_owned_hosted_runner'):
            return producer.OwnedAdminTrustScope('owned-importer',self.request,Path('owned-test.keychain'))

    def route(self,state,order,*,install_code=0,cleanup_code=0,preflight_code=0,bad_preflight=False):
        actual=producer.run;sha=producer.hashlib.sha1(self.leaf).hexdigest().upper()
        def run(args,**kwargs):
            if str(args[0])=='security':
                order.append('valid:'+str(int(state.exists())))
                value=('  1) '+sha+' "Owned admin protocol fixture"\n  1 valid identities found\n') if state.exists() else '  0 valid identities found\n'
                return actual([sys.executable,'-c','import sys;sys.stdout.write('+repr(value)+')'],**kwargs)
            self.assertEqual(args[:4],['/usr/bin/sudo','-n','--','/usr/bin/env'])
            self.assertEqual(args[4:8],['GITHUB_ACTIONS=true','RUNNER_ENVIRONMENT=github-hosted','RUNNER_OS=macOS','owned-importer'])
            request=json.loads(kwargs['input']);op=request['operation'];order.append(op)
            self.assertEqual(set(request),{'operation','leafCertificate','rootCertificate'})
            self.assertNotIn('secret-input-canary',kwargs['input'].decode())
            self.assertEqual(args[8:],['--owned-admin-trust',str(producer.ADMIN_ROOT_DEADLINES[op])])
            self.assertTrue(kwargs['private'])
            self.assertEqual(kwargs['timeout_seconds'],10 if op=='removeOwnedAdminTrust' else 20)
            with patch.object(producer,'require_owned_hosted_runner'):
                if op=='preflightOwnedAdminTrust':
                    code=preflight_code;action='';status=self.passed(op)
                    if bad_preflight:status['effectiveUID']=1
                    if code:status={'schemaVersion':5,'operation':op,'stage':'hostedRunner','status':'failed','osStatus':-60007}
                elif op=='installOwnedAdminTrust':
                    code=install_code;status=self.passed(op)
                    action='pathlib.Path('+repr(str(state))+').write_text("owned admin marker");'
                else:
                    code=cleanup_code;status=self.passed(op,absent=not state.exists())
                    action='' if code else 'pathlib.Path('+repr(str(state))+').unlink(missing_ok=True);'
                return actual(self.child(status,code,action),**kwargs)
        return run

    def test_schema5_requires_admin_root_and_exact_short_self_deadline(self):
        for op in producer.OWNED_ADMIN_TRUST_OPERATIONS:
            value=self.passed(op)
            self.assertEqual(producer.owned_admin_trust_status(json.dumps(value).encode(),op),value)
            for changed in [dict(value,domain='user'),dict(value,effectiveUID=1),dict(value,effectiveUID=False),
                            dict(value,rootSelfDeadlineSeconds=20),dict(value,rootSelfDeadlineSeconds=True),
                            dict(value,rootMonotonicDeadlineNS=0),dict(value,rootMonotonicDeadlineNS=True),
                            dict(value,rootMonotonicDeadlineNS=2**63),dict(value,authorizationPreflightPassed=True),
                            dict(value,userSystemTrustOrSearchListChanged=True),dict(value,privateKey='never public'),
                            dict(value,temporaryAdminDomainTrustChanged=not value['temporaryAdminDomainTrustChanged'])]:
                with self.subTest(op=op),self.assertRaises(ValueError):producer.owned_admin_trust_status(json.dumps(changed).encode(),op)
        duplicate=json.dumps(self.passed('installOwnedAdminTrust')).replace('"domain": "admin"','"domain":"user","domain":"admin"')
        with self.assertRaises(ValueError):producer.owned_admin_trust_status(duplicate.encode(),'installOwnedAdminTrust')

    def test_fixed_sudo_n_private_public_cert_only_preflight_preserves_parent_budgets(self):
        scope=self.scope();order=[]
        with tempfile.TemporaryDirectory() as directory,redirect_stdout(io.StringIO()):
            state=Path(directory)/'effect'
            with patch.object(producer,'require_owned_hosted_runner'),patch.object(producer,'run',self.route(state,order)):
                scope.invoke('preflightOwnedAdminTrust')
            self.assertFalse(state.exists())
        self.assertEqual(order,['preflightOwnedAdminTrust'])
        self.assertEqual(producer.TOOL_TIMEOUT_SECONDS['import-owned-identity'],20)
        self.assertEqual(producer.CLEANUP_TIMEOUT_SECONDS,10)
        self.assertFalse(scope.cleanup_intent)
        # Execute the real private runner with a smaller captured parent budget.
        # Only the child is substituted by a portable JSON process, never sudo.
        status=self.passed('preflightOwnedAdminTrust');status['rootSelfDeadlineSeconds']=2
        actual_child=producer.bounded_child;seen=[]
        def bounded(args,input,env,seconds):
            seen.append((args,seconds))
            self.assertEqual(args[-3:],['--owned-admin-trust','2','3000000000'])
            return actual_child(self.child(status),input,env,seconds)
        command=['/usr/bin/sudo','-n','--','/usr/bin/env','GITHUB_ACTIONS=true',
                 'RUNNER_ENVIRONMENT=github-hosted','RUNNER_OS=macOS','owned-importer','--owned-admin-trust','18']
        clock=type('Clock',(),{'implementation':'mach_absolute_time()','monotonic':True,'adjustable':False})()
        with patch.object(producer.time,'get_clock_info',return_value=clock),patch.object(producer.time,'monotonic_ns',return_value=1_000_000_000):
            with patch.object(producer,'tool_timeout',return_value=4),patch.object(producer,'bounded_child',side_effect=bounded),redirect_stdout(io.StringIO()):
                raw=producer.run(command,input=b'public fixture only',private=True,public_status='preflightOwnedAdminTrust')
            self.assertEqual(producer.owned_admin_trust_status(raw,'preflightOwnedAdminTrust',2,3_000_000_000),status)
            self.assertEqual(seen[0][1],4)
            self.assertEqual(producer.RECORDS[-1]['argv'][-2:],['2','3000000000'])
            # A real portable child's completion must echo this invocation's
            # absolute cutoff exactly. A different clock origin cannot pass.
            status['rootMonotonicDeadlineNS']+=1
            with patch.object(producer,'tool_timeout',return_value=4),patch.object(producer,'bounded_child',side_effect=bounded),redirect_stdout(io.StringIO()):
                with self.assertRaises(producer.ToolFailure):
                    producer.run(command,input=b'public fixture only',private=True,public_status='preflightOwnedAdminTrust')
            with patch.object(producer,'tool_timeout',return_value=2),patch.object(producer,'bounded_child') as no_child:
                with self.assertRaises(producer.ToolTimeout):producer.run(command,input=b'',private=True,public_status='preflightOwnedAdminTrust')
                no_child.assert_not_called()
        bad_clock=type('Clock',(),{'implementation':'clock_gettime(CLOCK_MONOTONIC)','monotonic':True,'adjustable':False})()
        with patch.object(producer.time,'get_clock_info',return_value=bad_clock),patch.object(producer,'bounded_child') as no_child:
            with self.assertRaises(ValueError):producer.run(command,input=b'',private=True,public_status='preflightOwnedAdminTrust')
            no_child.assert_not_called()

    def test_actual_child_admin_marker_install_read_remove_is_zero_one_zero(self):
        scope=self.scope();order=[]
        with tempfile.TemporaryDirectory() as directory,redirect_stdout(io.StringIO()):
            state=Path(directory)/'effect'
            with patch.object(producer,'require_owned_hosted_runner'),patch.object(producer,'run',self.route(state,order)):
                scope.install();self.assertTrue(state.exists());scope.cleanup();self.assertFalse(state.exists())
        self.assertEqual(order,['valid:0','preflightOwnedAdminTrust','installOwnedAdminTrust','valid:1','removeOwnedAdminTrust','valid:0'])
        self.assertTrue(scope.installed and scope.cleaned);self.assertFalse(scope.cleanup_intent)

    def test_lost_root_install_ack_still_removes_real_child_marker(self):
        scope=self.scope();order=[]
        with tempfile.TemporaryDirectory() as directory,redirect_stdout(io.StringIO()):
            state=Path(directory)/'effect'
            with patch.object(producer,'require_owned_hosted_runner'),patch.object(producer,'run',self.route(state,order,install_code=7)):
                with self.assertRaises(producer.ToolFailure) as primary:scope.install()
                self.assertEqual(primary.exception.code,7);self.assertTrue(scope.cleanup_intent and state.exists())
                self.assertIsNone(producer.finish_owned_admin_trust(scope,primary.exception))
                self.assertFalse(state.exists())
        self.assertTrue(scope.cleaned)

    def test_cleanup_failure_keeps_admin_remaining_scope_and_original_error_separate(self):
        scope=self.scope();order=[];output=io.StringIO()
        with tempfile.TemporaryDirectory() as directory,redirect_stdout(output):
            state=Path(directory)/'effect'
            with patch.object(producer,'require_owned_hosted_runner'),patch.object(producer,'run',self.route(state,order,cleanup_code=9)):
                scope.install();primary=producer.ToolFailure('original target',1)
                cleanup=producer.finish_owned_admin_trust(scope,primary)
                self.assertEqual(cleanup.code,9);self.assertEqual(primary.code,1)
                self.assertTrue(state.exists() and scope.cleanup_intent);self.assertFalse(scope.cleaned)
        facts=json.loads(output.getvalue().split('OWNED_ADMIN_TRUST_CLEANUP_FAILURE ',1)[1])
        self.assertTrue(facts['temporaryAdminTrustMayRemain'] and facts['originalToolFailureRetained'])
        self.assertFalse(facts['userSystemTrustOrSearchListChanged'])

    def test_sudo_or_host_refusal_cannot_start_install(self):
        scope=self.scope();order=[]
        with tempfile.TemporaryDirectory() as directory,redirect_stdout(io.StringIO()):
            state=Path(directory)/'effect'
            with patch.object(producer,'require_owned_hosted_runner'),patch.object(producer,'run',self.route(state,order,preflight_code=1)):
                with self.assertRaises(producer.ToolFailure):scope.install()
                self.assertIsNone(producer.finish_owned_admin_trust(scope,None))
            self.assertFalse(state.exists())
        self.assertEqual(order,['valid:0','preflightOwnedAdminTrust']);self.assertFalse(scope.cleanup_intent)

    def test_false_root_completion_and_wrong_deadline_never_grant_install_intent(self):
        scope=self.scope();order=[]
        with tempfile.TemporaryDirectory() as directory,redirect_stdout(io.StringIO()):
            state=Path(directory)/'effect'
            with patch.object(producer,'require_owned_hosted_runner'),patch.object(producer,'run',self.route(state,order,bad_preflight=True)):
                with self.assertRaises(producer.ToolFailure):scope.install()
            self.assertFalse(state.exists())
        self.assertFalse(scope.cleanup_intent)
        with self.assertRaises(ValueError):scope.invoke('installOwnedAdminTrust',cleanup=True)

    def test_foreign_cert_and_unknown_operation_cannot_reach_root_command(self):
        with patch.object(producer,'require_owned_hosted_runner'):
            with self.assertRaises(ValueError):producer.OwnedAdminTrustScope('owned-importer',dict(self.request,rootCertificate='foreign'),Path('owned'))
        scope=self.scope()
        with self.assertRaises(ValueError):scope.invoke('removeOwnedUserTrust')
        self.assertFalse(scope.cleanup_intent)


class OwnedTemporaryUserSearchListTests(unittest.TestCase):
    """Real portable marker children; never security/search-list/codesign execution."""
    setUp = OwnedTemporaryUserTrustTests.setUp
    original=('/Users/private-path-canary/Library/Keychains/login.keychain-db',
              '/Library/Keychains/System.keychain')
    owned='/private/var/owned-fixture/synthetic.keychain-db'

    def scope(self):
        with patch.object(producer,'require_owned_hosted_runner'):
            return producer.OwnedUserSearchListScope(self.owned)

    def route(self,state,commands,*,lost_append=False,lost_restore=False,
              append_observed=None,restore_observed=None,read_fault=None):
        actual=producer.bounded_child
        def child(args,input,env,seconds):
            commands.append(tuple(args))
            self.assertEqual(args[:4],['security','list-keychains','-d','user'])
            self.assertIsNone(input)
            prefix='import json,pathlib,sys;p=pathlib.Path('+repr(str(state))+');'
            if len(args)==4:
                if read_fault is not None:
                    self.assertIn(read_fault,('child','decode'))
                    action='sys.stdout.buffer.write(b"private-readback-path-canary");'
                    code=7 if read_fault=='child' else 0
                else:
                    action='v=json.loads(p.read_text());sys.stdout.buffer.write("".join(\'    "\'+x+\'"\\n\' for x in v).encode());'
                    code=0
            else:
                self.assertEqual(args[4],'-s');values=list(args[5:])
                code=7 if ((lost_append and values==[*self.original,self.owned]) or (lost_restore and values==list(self.original))) else 0
                if append_observed is not None and values==[*self.original,self.owned]:values=list(append_observed)
                if restore_observed is not None and values==list(self.original):values=list(restore_observed)
                action='p.write_text('+repr(json.dumps(values))+');'
            # Execute real process effects through the production run() and
            # its private stream/argv recording boundary; substitute only OS tool.
            command=[sys.executable,'-c',prefix+action+'sys.stderr.write("private-list-stderr-canary");sys.exit('+str(code)+')']
            return actual(command,input,env,seconds)
        return child

    def test_public_cli_path_representation_preserves_order_spaces_backslashes_and_rejects_ambiguity(self):
        values=('/Users/private space/Library/a\\b.keychain-db','/Library/Keychains/System.keychain')
        raw=''.join('    "'+x+'"\n' for x in values).encode()
        self.assertEqual(producer.owned_user_search_list(raw),values)
        self.assertEqual(producer.owned_user_search_list(b''),())
        for invalid in [raw+raw,b' <NULL>\n',b'    "relative"\n',b'    "/a/../b"\n',
                        b'    "/a"b"\n',b'    "/a"\r\n',b'    "//a"\n',b'    "/a/./b"\n',b'\xff']:
            with self.subTest(invalid=invalid),self.assertRaises((ValueError,UnicodeError)):
                producer.owned_user_search_list(invalid)
        with self.assertRaises(ValueError):producer.owned_user_search_list(b'x'*65_537)
        with self.assertRaises(ValueError):producer.owned_user_search_list(''.join('    "/keychain/'+str(i)+'"\n' for i in range(129)).encode())
        scope=self.scope()
        with patch.object(scope,'read',return_value=tuple('/keychain/'+str(i) for i in range(128))),patch.object(scope,'write') as write:
            with self.assertRaises(producer.ToolFailure):scope.install()
            write.assert_not_called();self.assertFalse(scope.cleanup_intent)

    def test_actual_children_append_only_owned_then_restore_exact_private_order_including_empty_list(self):
        for original in [self.original,()]:
            with self.subTest(entries=len(original)),tempfile.TemporaryDirectory() as directory:
                state=Path(directory)/'list.json';state.write_text(json.dumps(original));commands=[];scope=self.scope();out=io.StringIO()
                with patch.object(producer,'bounded_child',self.route(state,commands)),redirect_stdout(out):
                    scope.install();self.assertEqual(json.loads(state.read_text()),[*original,self.owned])
                    scope.cleanup();scope.cleanup()
                self.assertEqual(json.loads(state.read_text()),list(original))
                writes=[a[5:] for a in commands if len(a)>4]
                self.assertEqual(writes,[(*original,self.owned),original])
                self.assertTrue(scope.registered and scope.restored);self.assertFalse(scope.cleanup_intent)
                public=out.getvalue()+json.dumps(producer.RECORDS)
                for secret in [*self.original,self.owned,'private-list-stderr-canary']:
                    self.assertNotIn(secret,public)
                self.assertIn('<preserved-user-search-list-and-owned-keychain>',public)

    def test_lost_append_ack_preserves_original_error_and_restores_real_effect(self):
        with tempfile.TemporaryDirectory() as directory:
            state=Path(directory)/'list.json';state.write_text(json.dumps(self.original));commands=[];scope=self.scope()
            with patch.object(producer,'bounded_child',self.route(state,commands,lost_append=True)),redirect_stdout(io.StringIO()):
                with self.assertRaises(producer.ToolFailure) as failure:scope.install()
                self.assertEqual(failure.exception.code,7);self.assertTrue(scope.cleanup_intent)
                self.assertEqual(json.loads(state.read_text()),[*self.original,self.owned])
                self.assertIsNone(producer.finish_owned_user_search_list(scope,failure.exception))
            self.assertEqual(json.loads(state.read_text()),list(self.original))
            self.assertTrue(scope.restored);self.assertFalse(scope.registered or scope.cleanup_intent)

    def test_observed_before_append_and_cleanup_conflicts_never_overwrite_foreign_state(self):
        scope=self.scope();changed=(*self.original,'/private/another.keychain-db')
        with patch.object(scope,'read',side_effect=[self.original,changed]),patch.object(scope,'write') as write:
            with self.assertRaises(producer.ToolFailure):scope.install()
            write.assert_not_called();self.assertFalse(scope.cleanup_intent)
        with tempfile.TemporaryDirectory() as directory:
            state=Path(directory)/'list.json';state.write_text(json.dumps(self.original));commands=[];scope=self.scope();out=io.StringIO()
            with patch.object(producer,'bounded_child',self.route(state,commands)),redirect_stdout(out):
                scope.install();foreign=[*self.original,self.owned,'/private/another.keychain-db'];state.write_text(json.dumps(foreign))
                primary=producer.ToolFailure('actual target codesign',1)
                failure=producer.finish_owned_user_search_list(scope,primary)
            self.assertIsInstance(failure,producer.ToolFailure);self.assertTrue(scope.cleanup_intent)
            self.assertFalse(scope.restored);self.assertEqual(json.loads(state.read_text()),foreign)
            self.assertEqual(len([a for a in commands if len(a)>4]),1)
            record=json.loads(out.getvalue().split('OWNED_USER_SEARCH_LIST_CLEANUP_FAILURE ',1)[1])
            self.assertTrue(record['originalToolFailureRetained'] and record['temporaryUserSearchListMayRemain'])

    def test_lost_restore_ack_does_not_erase_original_failure_and_finally_confirms_absence(self):
        with tempfile.TemporaryDirectory() as directory:
            state=Path(directory)/'list.json';state.write_text(json.dumps(self.original));commands=[];scope=self.scope()
            with patch.object(producer,'bounded_child',self.route(state,commands,lost_restore=True)),redirect_stdout(io.StringIO()):
                scope.install()
                with self.assertRaises(producer.ToolFailure) as failure:scope.cleanup()
                self.assertEqual(failure.exception.code,7);self.assertTrue(scope.cleanup_intent)
                self.assertEqual(json.loads(state.read_text()),list(self.original))
                self.assertIsNone(producer.finish_owned_user_search_list(scope,failure.exception))
            self.assertTrue(scope.restored);self.assertFalse(scope.cleanup_intent)
            self.assertEqual(len([a for a in commands if len(a)>4]),2)

    def test_failed_append_reports_bounded_relations_without_paths_or_relaxing_exact_order(self):
        foreign='/private/foreign-path-canary.keychain-db'
        for observed,permutation,owned in [((self.owned,*self.original),True,True),
                                          ((*self.original,foreign),False,False)]:
            with self.subTest(permutation=permutation),tempfile.TemporaryDirectory() as directory:
                state=Path(directory)/'list.json';state.write_text(json.dumps(self.original));commands=[];scope=self.scope();out=io.StringIO()
                with patch.object(producer,'bounded_child',self.route(state,commands,append_observed=observed)),redirect_stdout(out):
                    with self.assertRaises(producer.ToolFailure) as primary:scope.install()
                    self.assertEqual(primary.exception.tool,'owned search list append not exact')
                    self.assertEqual(primary.exception.code,-1)
                    failure=producer.finish_owned_user_search_list(scope,primary.exception)
                self.assertIsInstance(failure,producer.ToolFailure)
                self.assertFalse(scope.registered or scope.restored);self.assertTrue(scope.cleanup_intent)
                self.assertEqual(json.loads(state.read_text()),list(observed))
                self.assertEqual(len([a for a in commands if len(a)>4]),1)
                records=[(line.split(' ',1)[0],json.loads(line.split(' ',1)[1])) for line in out.getvalue().splitlines()]
                readback=next(value for label,value in records if label=='OWNED_USER_SEARCH_LIST_READBACK' and value['operation']=='verifyAfterAppend')
                self.assertEqual((readback['originalEntryCount'],readback['expectedEntryCount'],readback['observedEntryCount']),(2,3,3))
                self.assertFalse(readback['observedEqualsExpected'] or readback['observedEqualsOriginal'])
                self.assertEqual(readback['observedIsExpectedPermutation'],permutation)
                self.assertEqual(readback['ownedKeychainPresent'],owned)
                self.assertEqual(readback['readChildExitCode'],0)
                self.assertTrue(readback['strictPathRepresentationParsed'])
                self.assertLess(len(json.dumps(readback).encode()),1024)
                cleanup=next(value for label,value in records if label=='OWNED_USER_SEARCH_LIST_CLEANUP_FAILURE')
                self.assertEqual((cleanup['operation'],cleanup['failureStage']),('readBeforeRestore','conflict'))
                self.assertTrue(cleanup['originalToolFailureRetained'] and cleanup['temporaryUserSearchListMayRemain'])
                public=out.getvalue()+json.dumps(producer.RECORDS)
                for secret in [*self.original,self.owned,foreign,'private-list-stderr-canary']:
                    self.assertNotIn(secret,public)
                    self.assertNotIn(producer.hashlib.sha256(secret.encode()).hexdigest(),public)

    def test_cleanup_failure_records_exact_read_child_decode_restore_child_and_final_comparison(self):
        foreign=(*self.original,'/private/foreign-path-canary.keychain-db')
        cases=[('read-child',{'read_fault':'child'},'readBeforeRestore','child',7),
               ('read-decode',{'read_fault':'decode'},'readBeforeRestore','decode',None),
               ('restore-child',{'lost_restore':True},'restore','child',7),
               ('restore-comparison',{'restore_observed':foreign},'verifyAfterRestore','comparison',-1)]
        for name,options,operation,stage,code in cases:
            with self.subTest(failure=name),tempfile.TemporaryDirectory() as directory:
                state=Path(directory)/'list.json';state.write_text(json.dumps(self.original));commands=[];scope=self.scope();out=io.StringIO()
                with patch.object(producer,'bounded_child',self.route(state,commands)),redirect_stdout(out):scope.install()
                primary=producer.ToolFailure('actual target codesign',1)
                with patch.object(producer,'bounded_child',self.route(state,commands,**options)),redirect_stdout(out):
                    failure=producer.finish_owned_user_search_list(scope,primary)
                self.assertIsNotNone(failure);self.assertEqual(primary.code,1)
                self.assertTrue(scope.cleanup_intent);self.assertFalse(scope.restored)
                records=[(line.split(' ',1)[0],json.loads(line.split(' ',1)[1])) for line in out.getvalue().splitlines()]
                cleanup=next(value for label,value in records if label=='OWNED_USER_SEARCH_LIST_CLEANUP_FAILURE')
                self.assertEqual((cleanup['operation'],cleanup['failureStage'],cleanup['exitCode']),(operation,stage,code))
                self.assertTrue(cleanup['originalToolFailureRetained'] and cleanup['temporaryUserSearchListMayRemain'])
                self.assertFalse(any(label=='OWNED_USER_SEARCH_LIST_RESTORED' for label,value in records))
                public=out.getvalue()+json.dumps(producer.RECORDS)
                for secret in [*self.original,self.owned,*foreign,'private-list-stderr-canary','private-readback-path-canary']:
                    self.assertNotIn(secret,public)


if __name__=='__main__':unittest.main()
