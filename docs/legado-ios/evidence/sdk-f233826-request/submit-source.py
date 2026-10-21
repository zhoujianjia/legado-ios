"""ROOT ONLY. Draft for root review; only branch plus exact SDK/Native tag pair."""
import argparse
import datetime
import json
import subprocess
from common import (ROOT, STAGE, GIT, CHECKPOINT, PLAN, WORKFLOWS, read,
                    clean_head, closed_88, checkpoint_state, fact, write_new)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--expected-head', required=True)
    args = parser.parse_args()
    assert len(args.expected_head) == 40 and all(x in '0123456789abcdef' for x in args.expected_head)
    output = STAGE / 'submission-v1.json'
    assert not output.exists() and not (STAGE / 'submission-attempt-v1.json').exists()
    source = clean_head(args.expected_head)
    _, history = closed_88(read(ROOT / PLAN))
    _, counts, roster = checkpoint_state()
    tags = [prefix + source[:7] for prefix in WORKFLOWS]
    assert len(tags) == 2 and all('ipa' not in tag.lower() for tag in tags)
    for tag in tags:
        absent = subprocess.run([GIT, 'show-ref', '--verify', '--quiet', 'refs/tags/' + tag], cwd=ROOT)
        assert absent.returncode == 1, (tag, absent.returncode)
        assert not git_remote_tag(tag).strip(), tag
    write_new(STAGE / 'submission-attempt-v1.json', {
        'sourceCommit': source, 'tags': tags, 'oldTerminalAndInitialRequestFacts': history,
        'atomicPushSucceeded': False, 'scope': 'Pre-mutation receipt only, not a cloud observation or execution pass.'})
    try:
        for tag in tags:
            subprocess.run([GIT, 'tag', tag, source], cwd=ROOT, check=True)
        # A non-fast-forward branch or rejected tag rejects the complete push.
        subprocess.run([GIT, 'push', '--atomic', 'origin',
                        source + ':refs/heads/legado-ios-prototype',
                        *['refs/tags/' + tag for tag in tags]], cwd=ROOT, check=True)
    except subprocess.CalledProcessError as error:
        write_new(STAGE / 'submission-failure-v1.json', {
            'sourceCommit': source, 'tags': tags, 'exitCode': error.returncode,
            'scope': 'No cloud admission inferred; local tags/attempt remain for explicit root inspection. No automatic delete/retry.'})
        raise
    write_new(output, {
        'schemaVersion': 1, 'submittedUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'sourceCommit': source, 'tags': tags, 'counts': counts, 'sourceCheckpoint': CHECKPOINT,
        'checkpointFact': fact(ROOT / CHECKPOINT), 'canonicalSourceRoster': roster,
        'controls': 5, 'integratedChangedSources': 8, 'exactBoundInputs': 365,
        'NativeProductCases': 28, 'NativePlatformCharacterizations': 2,
        'atomicBranchAndTwoTagPushSucceeded': True, 'oldEvidencePreserved': history,
        'newIPATag': False, 'actualResultAccepted': False,
        'actualCloudHandlesObservedYet': False, 'oldTerminalJobsRepolled': False})
    print(json.dumps({'sourceCommit': source, 'tags': tags, 'newIPATag': False}))


def git_remote_tag(tag):
    return subprocess.check_output([GIT, 'ls-remote', '--tags', 'origin', 'refs/tags/' + tag], cwd=ROOT)


if __name__ == '__main__':
    main()
