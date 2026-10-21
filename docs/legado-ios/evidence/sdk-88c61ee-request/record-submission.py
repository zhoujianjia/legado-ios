"""ROOT ONLY. Consumes root's real initial-cloud-observation; never queries cloud."""
import datetime
import json
from common import (ROOT, STAGE, CHECKPOINT, PLAN, FLAGS, WORKFLOWS, OLD_TERMINALS,
                    clean_head, read, closed_fc3, checkpoint_state, public_run_url,
                    fact, write_new, normalized_copy)

def main():
    submission = read(STAGE / 'submission-v1.json')
    source = submission['sourceCommit']
    assert clean_head() == source
    plan = read(ROOT / PLAN)
    cloud = closed_fc3(plan)
    record, counts, union = checkpoint_state()
    assert submission['sourceCheckpoint'] == CHECKPOINT and submission['counts'] == counts
    assert submission['checkpointFact'] == fact(ROOT / CHECKPOINT)
    assert submission['newIPATag'] is False and submission['actualCloudHandlesObservedYet'] is False
    observed = read(STAGE / 'initial-cloud-observation.json')
    assert isinstance(observed['observedUTC'], str) and observed['observedUTC']
    expected_tags = {prefix + source[:7]: name for prefix, name in WORKFLOWS.items()}
    assert set(submission['tags']) == set(expected_tags)
    assert len(observed['runs']) == 2 and {run['tag'] for run in observed['runs']} == set(expected_tags)
    handles = []
    public_runs = []
    old_run_ids = {row[1] for row in OLD_TERMINALS}
    for run in observed['runs']:
        assert run['sourceCommit'] == source and run['name'] == expected_tags[run['tag']]
        assert run['status'] in ('queued', 'in_progress') and run['conclusion'] is None
        assert isinstance(run['runID'], int) and run['runID'] > 0 and run['runID'] not in old_run_ids
        assert len(run['jobs']) == 1
        job = run['jobs'][0]
        assert isinstance(job['jobID'], int) and job['jobID'] > 0
        assert job['status'] in ('queued', 'in_progress') and job['conclusion'] is None
        url = public_run_url(run['url'], run['runID'])
        handles.append({'workflow': run['name'], 'runID': run['runID'], 'jobID': job['jobID'],
            'tag': run['tag'], 'sourceCommit': source, 'statusAtObservation': job['status'], 'url': url})
        # Archive only public selected facts, never arbitrary connector response
        # fields such as signed download URLs or credentials.
        public_runs.append({'name': run['name'], 'runID': run['runID'], 'tag': run['tag'],
            'sourceCommit': source, 'status': run['status'], 'conclusion': None, 'url': url,
            'jobs': [{'jobID': job['jobID'], 'status': job['status'], 'conclusion': None}]})
    assert len({h['runID'] for h in handles}) == len({h['jobID'] for h in handles}) == 2
    checkpoint_rows = [(key, row) for key, row in plan['execution']['stepByStep'].items()
                       if isinstance(row, dict) and row.get('record') == CHECKPOINT]
    assert len(checkpoint_rows) == 1, 'The canonical plan must identify this checkpoint exactly once.'
    checkpoint_key, checkpoint_row = checkpoint_rows[0]
    assert not checkpoint_row.get('submittedRequest')
    request_relative = 'docs/legado-ios/core-sdk-' + source[:7] + '-request.json'
    request_path = ROOT / request_relative
    base = ROOT / ('docs/legado-ios/evidence/sdk-' + source[:7] + '-request')
    assert not request_path.exists() and not base.exists()
    assert not (STAGE / 'submission-canonical-roster.json').exists()
    preserved = []
    for filename, archived in (
        ('submission-v1.json', 'submission.json'),
        ('common.py', 'root-helper-common.py'),
        ('submit-reviewed-general-webjs-runtime-repairs-checkpoint.py', 'submit-source.py'),
        ('record-general-webjs-runtime-repairs-checkpoint-submission.py', 'record-submission.py')):
        preserved.append(normalized_copy(STAGE / filename, base / archived))
    public_observation = base / 'initial-cloud-observation.json'
    write_new(public_observation, {'observedUTC': observed['observedUTC'], 'runs': public_runs})
    preserved.append({**fact(public_observation),
        'originalEvidence': fact(STAGE / 'initial-cloud-observation.json'),
        'projection': 'Only actual public workflow/run/job/tag/source/status facts; arbitrary connector response fields excluded.'})
    request = {
        'schemaVersion': 1, 'recordedUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'status': 'actual-general-webjs-runtime-repairs-SDK-Native-pair-submitted-no-terminal-acceptance',
        'sourceCommit': source, 'sourceCheckpoint': CHECKPOINT, 'observedUTC': observed['observedUTC'],
        'handles': handles, 'counts': counts, 'newIPATag': False, 'actualResultAccepted': False,
        'GeneralWebJSBase64CookieAndRuntimeRepairsIncluded': True, 'blankRegexSuccessorIncluded': True,
        'noOldTerminalJobsRepolled': True, 'previousClosedRunIDs': sorted(old_run_ids),
        'independentColdHosts': 2, 'preservedEvidence': preserved,
        'limits': 'Workflow admission only. The new exact source snapshot has no terminal SDK/JNI/WK/device/renewal acceptance yet. Prior fc3 terminal evidence remains immutable; neither its older Native pass nor Package24 promotes the new App/runtime selection.',
        **{key: False for key in FLAGS},
    }
    cloud['onlyLiveSDKHandles'] = handles
    cloud['currentUnifiedCheckpoint'] = {'sourceCommit': source, 'requestRecord': request_relative,
        'observedUTC': observed['observedUTC'], 'counts': counts, 'actualResultAccepted': False}
    cloud['alreadyRunningTasks'] = ('Exactly the ' + source[:7] + ' SDK/Native pair below; no IPA/device tag. '
        'Both fc3 workflows and all earlier closed handles are terminal/archived and must not be queried again.')
    cloud['nextPlannedCheckpoint'] = ('Preserve actual terminal logs/artifacts for these two new handles only. '
        'Repair actual failures before another coherent pair; do not restart for elapsed time or repeat unchanged successful suites. '
        'Continue remaining finite compatibility work independently without mutating this running source snapshot.')
    checkpoint_row['submittedRequest'] = request_relative
    checkpoint_row['submittedSourceCommit'] = source
    checkpoint_row['pendingUnifiedSDK'] = True
    for key in FLAGS:
        assert plan[key] is False
    write_new(request_path, request)
    # Root executes this only after reviewing the full proposed record. Do not
    # commit or push here: return an exact roster for root's canonical commit.
    (ROOT / PLAN).write_text(json.dumps(plan, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    paths = [request_path, ROOT / PLAN] + [ROOT / row['path'] for row in preserved]
    write_new(STAGE / 'submission-canonical-roster.json', [fact(path) for path in paths])
    print(json.dumps({'reviewedPaths': len(paths), 'handles': handles,
        'planCheckpointKey': checkpoint_key, 'newIPATag': False}))

if __name__ == '__main__':
    main()
