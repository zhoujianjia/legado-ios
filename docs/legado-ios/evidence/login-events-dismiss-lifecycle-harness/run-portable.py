from pathlib import Path
import importlib.util,sys,json,time,unittest
sys.dont_write_bytecode=True
stage=Path(__file__).resolve().parents[1]
kind=sys.argv[1];attempt=sys.argv[2]
tools=stage/'work/scripts/reader-experience'
files={'core':'test-renewal-probe-tools.py','native':'test-native-smoke-tools.py','package':'test-original-api-package-tools.py'}
selected={
'core':[
'RenewalProbeEvidenceTests.test_currentcore_exact_ast_union_source_boundaries_arguments_and_one_new_budget',
'RenewalProbeEvidenceTests.test_currentcore_pipeline_preserves_real_first_failure_and_still_runs_full_native_once',
'RenewalProbeEvidenceTests.test_currentcore_result_rejects_failed_missing_changed_phase_and_required_sdk_fixture',
'LiveCoreSelectionTests.test_later_core_union_matches_real_suite_owners_without_widening_old_modes',
'LiveCoreSelectionTests.test_later_core_cases_and_sources_cannot_be_missing_duplicated_skipped_or_spoofed',
'GlyphCheckpointSelectionTests.test_glyph_case_sources_and_currentcore_only_bool_identity_are_exact',
'GlyphCheckpointSelectionTests.test_currentcore_exports_and_requires_all_three_actual_parameter_details',
'LoginUIExploreCheckpointSelectionTests.test_reviewed_app_methods_and_ui_fixture_keep_exact_scope_and_parameter_identities',
'LoginUIExploreCheckpointSelectionTests.test_new_app_cases_and_every_ui_page_owner_fail_closed_with_one_mandatory_sdk_invocation',
'LoginEventsDismissForegroundCheckpointTests.test_foreground_four_definitions_are_exact_and_preserve_old_modes_and_three_pairs',
'LoginEventsDismissForegroundCheckpointTests.test_new_methods_and_all_three_slice_inputs_reject_tampering_before_single_required_sdk_run'],
'package':[
'OriginalAPIPackageEvidenceTests.test_workflow_keeps_package_evidence_separate_and_has_no_binary_upload',
'OriginalAPIPackageEvidenceTests.test_currentcore_requires_six_new_methods_and_all_fifteen_compilation_sources',
'OriginalAPIPackageEvidenceTests.test_new_unbound_compiled_files_missing_files_and_links_cannot_enter_the_closure',
'PublicBatchPackageSelectionTests.test_public_batch_is_one_explicit_extra_case_with_same_complete_package_source_boundary',
'EffectsPackageSelectionTests.test_effect_receipts_select_one_exact_extra_case_and_refuse_missing_duplicate_skip_or_alias',
'LoginUIPackageSelectionTests.test_loginui_four_actual_definitions_keep_all_historical_sets_filters_and_mode_boundaries',
'LoginUIPackageSelectionTests.test_loginui_fresh22_requires_every_xml_verbose_leaf_and_current_source_and_selection']}
spec=importlib.util.spec_from_file_location('portable_'+kind,tools/files[kind]);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
loader=unittest.TestLoader()
suite=loader.loadTestsFromModule(module) if kind=='native' else unittest.TestSuite(loader.loadTestsFromName(name,module) for name in selected[kind])
start=time.monotonic();log=stage/'preparation'/f'{kind}-guards-{attempt}.log'
with log.open('w',encoding='utf-8') as stream:result=unittest.TextTestRunner(stream=stream,verbosity=2).run(suite)
record={'scope':kind,'selection':selected.get(kind,'all8NativeProvenanceGuards'),'actualTestsRun':result.testsRun,'failures':len(result.failures),'errors':len(result.errors),'skipped':len(result.skipped),'successful':result.wasSuccessful(),'seconds':round(time.monotonic()-start,3),'SDK':False,'nativeExecution':False,'Git':False}
(stage/'preparation'/f'{kind}-guards-{attempt}.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
print(json.dumps(record));sys.exit(0 if result.wasSuccessful() else 1)
