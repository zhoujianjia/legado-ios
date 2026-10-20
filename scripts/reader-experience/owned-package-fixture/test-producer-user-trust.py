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

if __name__=='__main__':unittest.main()
