"""Portable source/report/staging guards; never actual macOS producer acceptance."""
from contextlib import ExitStack, redirect_stdout
import copy
import importlib.util
import io
import posixpath
import json
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
ROOT = next(path for path in HERE.parents if (path/'scripts/reader-experience/renewal-probe-tools.py').is_file())
spec = importlib.util.spec_from_file_location('finite_owned_producer',HERE/'owned-sdk-producer-check.py')
check = importlib.util.module_from_spec(spec); spec.loader.exec_module(check)
spec = importlib.util.spec_from_file_location('existing_owned_producer_guards',ROOT/'scripts/reader-experience/test-renewal-probe-tools.py')
legacy = importlib.util.module_from_spec(spec); spec.loader.exec_module(legacy)


class OwnedSDKProducerCheckTests(unittest.TestCase):
    def setUp(self):
        self.fixture = legacy.RenewalProbeEvidenceTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.root = self.fixture.root
        self.work = self.root/'.build/finite-owned-check'
        self.work.mkdir(parents=True)
        self.produced = self.root/'.build/finite-owned-raw'
        self.probe = legacy.probe
        for name in check.SOURCE_INPUTS:
            if name not in self.fixture.originals:
                raw = ('portable source fixture: '+name+'\n').encode()
                self.fixture.originals[name] = raw
                self.fixture.write(self.root/name,raw)

    def context(self):
        stack = ExitStack()
        stack.enter_context(self.fixture.context())
        original = self.fixture.git
        def git(*args,**kwargs):
            if args[0]=='rev-parse': return legacy.SOURCE
            return original(*args,**kwargs)
        stack.enter_context(patch.object(self.probe.smoke,'git',side_effect=git))
        stack.enter_context(patch.dict(os.environ,{'GITHUB_REF_NAME':'reader-owned-sdk-aaaaaaa',
            'GITHUB_REF':'refs/tags/reader-owned-sdk-aaaaaaa'}))
        return stack

    def inputs(self):
        return check.source_state(self.probe)

    def test_requires_exact_isolated_tag_sha_checkout_and_source_only(self):
        with self.context():
            source = self.inputs()
            self.assertEqual(len(source['sourceInputs']),17)
            self.assertEqual(source['sourceTag'],'reader-owned-sdk-aaaaaaa')
            for changes in [{'GITHUB_SHA':'b'*40},{'GITHUB_REF_NAME':'reader-renewal-aaaaaaa'},
                            {'GITHUB_REF':'refs/heads/main'},{'LEGADO_RUNTIME_SOURCE_ONLY':'0'}]:
                with patch.dict(os.environ,changes), self.assertRaises(ValueError): self.inputs()
            with patch.object(self.probe.smoke,'git',return_value='b'*40), self.assertRaises(ValueError): self.inputs()

    def test_all_necessary_producer_runner_guard_and_fixture_sources_are_bound(self):
        with self.context():
            source = self.inputs()
            for entry in source['sourceInputs']:
                path = self.root/entry['path']; raw = path.read_bytes()
                path.write_bytes(raw+b'changed')
                try:
                    with self.assertRaises(ValueError): self.inputs()
                finally: path.write_bytes(raw)
            self.assertEqual(self.inputs(),source)

    def test_stages_only_existing_allowlist_without_writing_an_xctest_resource(self):
        with self.context():
            source = self.inputs(); produced = self.fixture.sdk_public_fixture()
            staged = check.stage_public(self.probe,self.work,produced,source['sourceInputs'])
            self.assertEqual(staged['nativeMethodsExecuted'],0)
            self.assertFalse(staged['swiftCMSVerifierExecuted'])
            self.assertFalse(staged['xctestResourceWritten'])
            self.assertFalse((self.root/self.probe.SDK_RESOURCE).exists())
            self.assertEqual({path.name for path in (self.work/'sdk-produced-public').iterdir()},
                self.probe._sdk_output_names()|{'sdk-produced-fixture-manifest.json'})
            self.assertEqual(self.probe._verify_sdk_public(produced,source['sourceInputs']),staged['publicValidation'])

    def test_staging_rejects_extra_private_changed_public_and_wrong_source_inputs(self):
        with self.context():
            source = self.inputs(); produced = self.fixture.sdk_public_fixture()
            extra = produced/'private.p12';extra.write_bytes(b'owned synthetic not-a-P12')
            with self.assertRaises(ValueError): check.stage_public(self.probe,self.work,produced,source['sourceInputs'])
            extra.unlink()
            leaf = produced/'leaf.cert.der';raw=leaf.read_bytes();leaf.write_bytes(raw+b'changed')
            with self.assertRaises(ValueError): check.stage_public(self.probe,self.work,produced,source['sourceInputs'])
            leaf.write_bytes(raw)
            changed = copy.deepcopy(source['sourceInputs'])
            entry = next(x for x in changed if x['path'].endswith('/ImportOwnedIdentity.swift'))
            entry['sha256']='b'*64
            with self.assertRaises(ValueError): check.stage_public(self.probe,self.work,produced,changed)
            self.assertFalse((self.work/'sdk-produced-public').exists())
            original = self.probe._verify_sdk_public
            def reject_copied_bytes(directory, inputs):
                if directory.name.endswith('-public.pending'):
                    raise ValueError('portable post-copy verification rejection')
                return original(directory,inputs)
            with patch.object(self.probe,'_verify_sdk_public',side_effect=reject_copied_bytes), self.assertRaises(ValueError):
                check.stage_public(self.probe,self.work,produced,source['sourceInputs'])
            self.assertFalse((self.work/'sdk-produced-public').exists())
            self.assertTrue((self.work.parent/(self.work.name+'-public.pending')).is_dir())

    def test_actual_public_child_nonzero_and_logs_remain_failure(self):
        with self.context():
            source = self.inputs()
            argv = [sys.executable,'-c','import sys;print("portable-public-child");sys.stderr.write("portable-failure");sys.exit(7)']
            row = check.capture_phase(self.probe,self.work,'producer',argv,5,source)
            self.assertEqual(row['state'],'failed')
            self.assertEqual(check.command_exit(row['command']),7)
            self.assertIn(b'portable-public-child',(self.work/'phase-producer.log').read_bytes())
            self.assertIn(b'portable-failure',(self.work/'phase-producer.log.stderr.log').read_bytes())
            self.assertEqual(self.probe.smoke.read_json(self.work/'phase-producer.json'),row)
            self.assertFalse((self.work/'result.json').exists())

    def test_timeout_and_changed_phase_inputs_are_never_accepted(self):
        self.assertEqual(check.command_exit({'exitCode':0,'timedOut':True}),124)
        self.assertEqual(check.command_exit({'exitCode':0,'oversized':True}),125)
        self.assertEqual(check.command_exit({'exitCode':None}),1)
        with self.context():
            source = self.inputs()
            with self.assertRaises(ValueError): check.verify_pass(self.probe,self.work,self.produced,source,[],'success')
            with self.assertRaises(ValueError): check.verify_pass(self.probe,self.work,self.produced,source,[],'failure')
            bad = dict(source,sourceCommit='b'*40)
            with self.assertRaises(ValueError): check.verify_pass(self.probe,self.work,self.produced,bad,[],'success')

    def test_commands_are_fixed_real_generator_and_finite_budgets(self):
        commands = check.intended_commands(self.root,self.produced)
        self.assertEqual(tuple(commands),check.PHASES[:-1])
        self.assertEqual(commands['producer'],([sys.executable,str(self.root/(check.TOOL_ROOT+'generate-sdk-owned-package.py')),
                                                '--output',str(self.produced)],600))
        self.assertEqual(commands['toolchain'][1],20)
        self.assertEqual(commands['toolchain'][0],['bash',str(self.root/'scripts/sim.sh'),'device-xcode'])
        self.assertNotIn('xctest',str(commands).lower())
        self.assertNotIn('swift test',str(commands))
        unavailable = self.root/'.build/must-not-run-off-macOS'
        with patch.object(check.sys,'platform','win32'), self.assertRaises(ValueError):
            check.run_check(self.probe,unavailable,self.produced)
        self.assertFalse(unavailable.exists())

    def test_successful_child_source_mutation_is_a_nonzero_whole_check_failure(self):
        with self.context():
            target = self.root/check.SOURCE_INPUTS[0]
            commands = check.intended_commands(self.root,self.produced)
            code = 'from pathlib import Path; Path(' + repr(str(target)) + ').write_bytes(b"changed source"); print("portable-source-mutation")'
            commands['toolchain'] = ([sys.executable,'-c',code],5)
            work = self.root/'.build/source-mutation-check'
            with patch.object(check.sys,'platform','darwin'), patch.object(check,'intended_commands',return_value=commands), \
                    patch.dict(os.environ,{'YUEDU_OWNED_PRODUCER_GUARDS_OUTCOME':'success'}):
                result = check.run_check(self.probe,work,self.produced)
            completion = self.probe.smoke.read_json(work/'completion.json')
            self.assertEqual(completion['phases'][0]['command']['exitCode'],0)
            self.assertEqual(completion['phases'][0]['state'],'failed')
            self.assertFalse(completion['passed'])
            self.assertFalse((work/'result.json').exists())
            self.assertTrue(all(row['state']=='blocked' for row in completion['phases'][1:]))
            self.assertNotEqual(result,0)
            self.assertNotEqual(completion['firstFailure']['exitCode'],0)

    def run_device_selector(self, inventory, active=None):
        # Execute the exact embedded Python used by sim.sh, with a hermetic
        # installed-SDK inventory. This is portable control-flow coverage;
        # actual macOS discovery and SDK signing still require the finite job.
        local = HERE/'sim.sh'
        selector = local if local.exists() else ROOT/'scripts/sim.sh'
        raw = selector.read_text(encoding='utf8')
        program = raw.split("python3 - <<'PY'\n",1)[1].split('\nPY\n',1)[0]
        apps = ['/Applications/' + name + '.app' for name in inventory]
        def list_sdk(path):
            for name, versions in inventory.items():
                if path == '/Applications/' + name + '.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs':
                    return ['iPhoneOS'+v+'.sdk' for v in versions]
            raise FileNotFoundError(path)
        calls = []
        def command(argv, **kwargs):
            calls.append(argv)
            if argv == ('xcode-select','-p'):
                return type('Selected',(),{'returncode':0,'stdout':'/Applications/Xcode.app/Contents/Developer\n'})()
            raise AssertionError('Device-only mode must not query Simulator or other commands: ' + repr(argv))
        env = {'MODE':'device-xcode','FILTER':''}
        if active is not None: env['DEVELOPER_DIR'] = active
        output = io.StringIO()
        with patch.dict(os.environ,env,clear=True), patch('glob.glob',return_value=apps), \
                patch('os.listdir',side_effect=list_sdk), patch('os.path.join',side_effect=posixpath.join), \
                patch('subprocess.run',side_effect=command), redirect_stdout(output):
            with self.assertRaises(SystemExit) as stopped:
                exec(compile(program,str(selector)+':embedded','exec'),{'__name__':'__main__'})
        return stopped.exception.code, output.getvalue(), calls

    def test_device_toolchain_uses_active_sdk_without_querying_simulators(self):
        active = '/Applications/Xcode.app/Contents/Developer'
        status, output, calls = self.run_device_selector({'Xcode':['26.0'],'Xcode-beta':['27.0']},active)
        self.assertEqual(status,0)
        self.assertEqual(output,active+'\n')
        self.assertEqual(calls,[])

    def test_device_toolchain_chooses_installed_sdk_when_active_has_none(self):
        status, output, calls = self.run_device_selector({'Xcode':[],'Xcode-beta':['26.0','27.0'],'Xcode-old':['18.0']})
        self.assertEqual(status,0)
        self.assertEqual(output,'/Applications/Xcode-beta.app/Contents/Developer\n')
        self.assertEqual(calls,[('xcode-select','-p')])

    def test_device_toolchain_missing_sdk_fails_without_querying_simulators(self):
        status, output, calls = self.run_device_selector({'Xcode':[]})
        self.assertEqual(status,'No Xcode with an iPhoneOS SDK found under /Applications.')
        self.assertEqual(output,'')
        self.assertEqual(calls,[('xcode-select','-p')])

    def test_workflow_is_isolated_and_never_uploads_raw_producer_directory(self):
        local = HERE/'reader-owned-sdk-producer.yml'
        path = local if local.exists() else ROOT/'.github/workflows/reader-owned-sdk-producer.yml'
        workflow = path.read_text(encoding='utf-8')
        self.assertIn("- 'reader-owned-sdk-*'",workflow)
        self.assertNotIn("- 'reader-renewal-*'",workflow)
        self.assertIn('timeout-minutes: 20',workflow)
        self.assertIn("LEGADO_RUNTIME_SOURCE_ONLY: '1'",workflow)
        self.assertIn('steps.guards.outcome',workflow)
        self.assertIn('if: always()',workflow)
        self.assertIn('.build/owned-sdk-producer-check/',workflow)
        self.assertNotIn('.build/owned-sdk-producer-raw/',workflow)
        self.assertNotIn('renewal-probe-tests.sh',workflow)
        self.assertNotIn('original-api-package-tests.sh',workflow)


if __name__=='__main__': unittest.main(verbosity=2)
