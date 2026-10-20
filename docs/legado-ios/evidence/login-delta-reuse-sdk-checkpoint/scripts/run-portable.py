from pathlib import Path
import importlib.util,sys,json,time,unittest
sys.dont_write_bytecode=True
s=Path(__file__).resolve().parents[1];kind=sys.argv[1];attempt=sys.argv[2]
files={'core':'test-renewal-probe-tools.py','core-selector':'test-renewal-probe-tools.py','native':'test-native-smoke-tools.py','package':'test-original-api-package-tools.py'}
selected={'core':['DeltaReuseCheckpointSelectionTests'],
'core-selector':[
'RenewalProbeEvidenceTests.test_currentcore_exact_ast_union_source_boundaries_arguments_and_one_new_budget',
'AccountCoreSelectionTests.test_account_preparation_binds_new_sources_and_uses_one_complete_native_command',
'EnrollmentRecoverySelectionTests.test_expired_enrollment_has_four_exact_client_methods_and_preserves_native_gates',
'LiveCoreSelectionTests.test_later_core_cases_and_sources_cannot_be_missing_duplicated_skipped_or_spoofed',
'GlyphCheckpointSelectionTests.test_glyph_case_sources_and_currentcore_only_bool_identity_are_exact',
'SourceLoginCheckpointSelectionTests.test_raw_login_missing_duplicate_skipped_foreign_and_changed_sources_fail_closed',
'MaterialPublicationAndLoginActionSelectionTests.test_material_cases_and_every_actual_combined_source_retain_fail_closed_admission',
'LoginUIExploreCheckpointSelectionTests.test_new_app_cases_and_every_ui_page_owner_fail_closed_with_one_mandatory_sdk_invocation',
'LoginEventsDismissForegroundCheckpointTests.test_new_methods_and_all_three_slice_inputs_reject_tampering_before_single_required_sdk_run',
'RenewalProbeEvidenceTests.test_currentcore_result_rejects_failed_missing_changed_phase_and_required_sdk_fixture',
'GlyphCheckpointSelectionTests.test_currentcore_exports_and_requires_all_three_actual_parameter_details',
'RenewalProbeEvidenceTests.test_cli_verification_rejects_groups_outside_each_exact_mode',
'CurrentCoreSwiftTestingSelectorTests',
'DeltaReuseCheckpointSelectionTests'],
'native':['NativeSmokeProvenanceTests.test_result_requires_exact_built_app_source_stamp',
'NativeSmokeProvenanceTests.test_native_groups_require_exact_qualified_methods_without_skips_or_duplicates',
'NativeSmokeProvenanceTests.test_workflow_keeps_native_groups_in_separate_required_hosts_after_real_staging'],
'package':['DeltaReusePackageSelectionTests']}
p=s/'work/scripts/reader-experience'/files[kind];spec=importlib.util.spec_from_file_location('delta_'+kind,p);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
suite=unittest.TestSuite(unittest.TestLoader().loadTestsFromName(name,m) for name in selected[kind]);start=time.monotonic()
with (s/f'preparation/{kind}-guards-{attempt}.log').open('w',encoding='utf-8') as out:r=unittest.TextTestRunner(stream=out,verbosity=2).run(suite)
record={'scope':kind,'selection':selected[kind],'actualTestsRun':r.testsRun,'failures':len(r.failures),'errors':len(r.errors),'skipped':len(r.skipped),'successful':r.wasSuccessful(),'seconds':round(time.monotonic()-start,3),'SDK':False,'nativeExecution':False,'Git':False,'prior26Rerun':False}
(s/f'preparation/{kind}-guards-{attempt}.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8');print(json.dumps(record));sys.exit(0 if r.wasSuccessful() else 1)
