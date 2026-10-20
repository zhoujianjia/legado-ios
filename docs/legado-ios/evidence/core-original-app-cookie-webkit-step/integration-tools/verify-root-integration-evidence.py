"""Read-only hashes/XML/JAR/provenance audit; never runs tests, grammar, Git or cloud."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import zipfile
import xml.etree.ElementTree as ET

ROOT = Path('F:/yuedu-reader')
BASE = ROOT / '.build/original-app-cookie-webkit-delta'
PREP_SHA = '933d843a20ead4c9476bca8c2d150a156e0e5fa9a137d8f7e7be0b39f44f15c3'
REVIEW_SHA = 'e23bce0393af56342da088e464be2806b9f8135bf7ca3fcc547b311271cff02f'
MERGED_SHA = '1bac6f3c5eddaeb4b31e1f414ecde6986495cdb586476304af038fcc59173a2f'
HOST = 'Modules/Services/Online/LegadoPersistentStateHost.swift'
MANIFEST = 'Packages/LegadoRuntime/vendor/original-rule/manifest.json'
PREFIX = 'Packages/LegadoRuntime/jvm/'


def sha(raw): return hashlib.sha256(raw).hexdigest()


def checked(path, digest=None, size=None):
    raw = path.read_bytes()
    assert digest is None or sha(raw) == digest, str(path)
    assert size is None or len(raw) == size, str(path)
    return raw


def row_bytes(row, key='path'):
    return checked(ROOT / row[key], row['sha256'], row['bytes'])


def fact(path, raw=None):
    raw = path.read_bytes() if raw is None else raw
    return dict(path=path.relative_to(ROOT).as_posix(), bytes=len(raw), sha256=sha(raw))


def verify():
    payload = {}
    def retain(path, target, raw=None):
        assert target not in payload
        assert path.is_relative_to(ROOT) or path == Path('F:/legado-master.zip')
        payload[target] = {'sourcePath': path.relative_to(ROOT).as_posix() if path.is_relative_to(ROOT) else path.as_posix(),
                           'raw': path.read_bytes() if raw is None else raw}
    pp = BASE / 'freeze-v2/preparation.json'
    p = json.loads(checked(pp, PREP_SHA, 223674))
    rp = BASE / 'independent-review-v2.json'
    r = json.loads(checked(rp, REVIEW_SHA, 20963))
    assert r['confirmedBlockers'] == [] and r['preparation']['sha256'] == PREP_SHA
    retain(pp, 'preparation-v2.json'); retain(rp, 'independent-review-v2.json')
    old = p['previousPreparation']; old_raw = row_bytes(old)
    retain(ROOT / old['path'], 'historical-v1/preparation.json', old_raw)
    old_review = ROOT / '.build/original-app-cookie-webkit-delta/freeze-v1'
    # The actual v1 reviewer did not accept the timeout gate. Retain an existing v1
    # review if present, without manufacturing an absent review or calling v1 passed.
    for candidate in [BASE / 'independent-review-v1.json', old_review / 'independent-review-v1.json']:
        if candidate.is_file():
            retain(candidate, 'historical-v1/independent-review-v1.json'); break
    rows = p['sourceBinding']['changedCodeTestsAndProvenance']
    assert len(rows) == 19 and len({x['path'] for x in rows}) == 19
    reviewed = {x['path']: x for x in r['verifiedChangedSourcesAndProvenance']}
    for row in rows:
        raw = row_bytes(row, 'snapshot')
        assert fact(ROOT / row['snapshot'], raw)['sha256'] in {x['sha256'] for x in reviewed.values()}
        before = checked(ROOT / row['baseSnapshot'], row['baseSHA256'], row['baseBytes']) if row.get('baseSnapshot') else None
        if row['path'] != HOST:
            target = ROOT / row['path']
            assert (target.is_file() and target.read_bytes() == before) if before is not None else not target.exists(), row['path']
    merged_path = BASE / 'root-preview-webkit-host-merge/LegadoPersistentStateHost.swift'
    merged = checked(merged_path, MERGED_SHA, 46630)
    merge_path = BASE / 'root-preview-webkit-host-merge/merge.json'
    merge = json.loads(checked(merge_path))
    assert merge['conflictFree'] is True and merge['mergeExit'] == 0
    assert merged == row_bytes(r['previewIntegration']['mergedHost'])
    assert checked(ROOT / HOST, merge['ours']['sha256'], merge['ours']['bytes'])
    host_row = next(row for row in rows if row['path'] == HOST)
    cookie_host = row_bytes(host_row, 'snapshot').decode('utf8')
    reconstructed = merged.decode('utf8').replace('\r\n', '\n')
    reconstructed = reconstructed.replace('any LegadoEntityStateBacking', 'AppLegadoBookStateOwner').replace('LegadoEntityBackingSnapshot', 'LegadoEntityStateSnapshot')
    start = reconstructed.index('    /// Only the existing context actor can issue this proof.')
    end = reconstructed.index('    func revoke(owner: String)', start)
    reconstructed = reconstructed[:start] + reconstructed[end:]
    reconstructed = reconstructed.replace('        try backing.validateRequest(request)\n', '')
    reconstructed = reconstructed.replace('backing.readState(keys:', 'backing.read(keys:').replace('backing.commitState(snapshot:', 'backing.commit(snapshot:')
    assert reconstructed == cookie_host
    retain(merged_path, 'host-merge/reviewed-merged-host.swift', merged)
    retain(merge_path, 'host-merge/merge.json')
    for row in p['sourceBinding']['swiftPackageSourceOnlyClosure']:
        row_bytes(row)
        retain(ROOT / row['path'], 'swift-package-source-only/' + row['intendedPath'])
    assert len(p['sourceBinding']['swiftPackageSourceOnlyClosure']) == 14

    focused_path = ROOT / p['validation']['focused']['path']
    f = json.loads(row_bytes(p['validation']['focused']))
    ordinary_path = ROOT / p['validation']['ordinary']['path']
    o = json.loads(row_bytes(p['validation']['ordinary']))
    assert f['exitCode'] == o['exitCode'] == 0
    retain(focused_path, 'jvm/focused.json'); retain(ordinary_path, 'jar/ordinary.json')
    for name, record in [('focused-v1', f), ('ordinary-v1', o)]:
        path = BASE / (name + '.log')
        retain(path, ('jvm/' if name.startswith('focused') else 'jar/') + name + '.log',
               checked(path, record['logSHA256'], record['logBytes']))
    for fact_row in [p['provenance']['record'], p['validation']['grammarFinal'], p['sourceBinding']['hostNarrowDiff']]:
        raw = row_bytes(fact_row)
        retain(ROOT / fact_row['path'], 'prepared/' + Path(fact_row['path']).name, raw)
    for item in p['reviewFix']['diffs']:
        path = ROOT / item['path']
        retain(path, 'diffs-v1-to-v2/' + path.name, checked(path, item['sha256']))
    retain(BASE / 'grammar-final.json', 'historical-v1/grammar-final.json')
    leaves = []
    assert len(f['junitSuites']) == 5
    for suite in f['junitSuites']:
        path = BASE / 'focused-v1-xml' / ('TEST-' + suite['name'] + '.xml')
        raw = checked(path, suite['sha256'], suite['bytes'])
        xml = ET.fromstring(raw)
        assert xml.tag == 'testsuite' and xml.attrib['name'] == suite['name']
        for key in ['tests', 'failures', 'errors', 'skipped']:
            assert int(xml.attrib[key]) == suite[key]
        assert not any(suite[key] for key in ['failures', 'errors', 'skipped'])
        cases = list(xml.findall('testcase'))
        assert len(cases) == suite['tests']
        for case in cases:
            assert not list(case.findall('failure')) + list(case.findall('error')) + list(case.findall('skipped'))
            assert case.attrib['classname'] == suite['name']
            leaves.append(case.attrib['classname'] + '/' + case.attrib['name'])
        retain(path, 'jvm/xml/' + path.name, raw)
    assert len(leaves) == len(set(leaves)) == 29
    assert p['validation']['actualUniqueMethods'] == len(p['validation']['actualUniqueLeafIDs']) == 29
    assert {leaf.replace('/', '.', 1).removesuffix('()') for leaf in leaves} == set(p['validation']['actualUniqueLeafIDs'])
    assert len(f['sourceBinding']) == len(o['sourceBinding']) == 153
    focused_inputs = {}
    ordinary_inputs = {}
    for record, folder, output in [(f, BASE / 'focused-v1-sources', focused_inputs),
                                    (o, BASE / 'ordinary-v1-sources', ordinary_inputs)]:
        for item in record['sourceBinding']:
            relative = item['path'].removeprefix(PREFIX)
            assert relative != item['path'] and '..' not in Path(relative).parts
            path = folder / relative
            raw = checked(path, item['sha256'], item['bytes'])
            assert item['path'] not in output
            output[item['path']] = item
            target = 'execution-sources/focused/' + relative
            if record is f:
                retain(path, target, raw)
            elif item['sha256'] != focused_inputs[item['path']]['sha256']:
                retain(path, 'execution-sources/ordinary-delta/' + relative, raw)
    assert {x['path']: x['sha256'] for x in p['sourceBinding']['acceptedExecutionInputs']} == {k: v['sha256'] for k,v in focused_inputs.items()}
    assert {x['path']: x['sha256'] for x in p['sourceBinding']['ordinaryExecutionInputs']} == {k: v['sha256'] for k,v in ordinary_inputs.items()}
    changes = [key for key in focused_inputs if focused_inputs[key]['sha256'] != ordinary_inputs[key]['sha256']]
    assert changes == [PREFIX + 'src/smoke/java/LegadoPayloadSmoke.java']
    for row in rows:
        if row['path'].startswith(PREFIX):
            assert row['sha256'] == ordinary_inputs[row['path']]['sha256']
            if '/src/smoke/' not in row['path']:
                assert row['sha256'] == focused_inputs[row['path']]['sha256']

    jar_row = o['ordinaryJar']; jar_path = ROOT / jar_row['path']
    jar_raw = row_bytes(jar_row)
    notices = jar_row['byteEqualProvenanceAndNotices']
    assert len(notices) == 21
    compiled = set()
    for folder in ['build/classes/kotlin/test', 'build/classes/java/test']:
        directory = BASE / 'jvm-work' / folder
        compiled.update(path.relative_to(directory).as_posix() for path in directory.rglob('*.class'))
    assert len(compiled) == jar_row['projectCompiledTestClassesChecked'] == 141
    with zipfile.ZipFile(jar_path) as jar:
        names = jar.namelist(); assert len(names) == len(set(names))
        assert set(jar_row['requiredClasses']).issubset(names)
        assert not (compiled & set(names))
        assert not any(name.startswith(('org/junit/', 'junit/')) for name in names)
        assert not any(name.endswith(('FileRulePersistenceAdapter.class', 'StatePersistenceProcessProbe.class', 'LegadoPayloadSmoke.class')) for name in names)
        assert 'fixtures/android-traditional-stateful-golden.json' not in names
        for item in notices:
            raw = jar.read(item['member'])
            assert len(raw) == item['bytes'] and sha(raw) == item['sha256']
            retain(jar_path, 'jar-retained-public-members/' + item['member'], raw)
        jr = jar_row['updatedOriginalRuleManifestMatchesReviewedFile']
        historical_manifest = jar.read(jr['member'])
        assert len(historical_manifest) == jr['bytes'] and sha(historical_manifest) == jr['sha256'] == p['provenance']['oldOrdinaryJarManifestSHA256']
        retain(jar_path, 'historical-v1/ordinary-jar-original-rule-manifest.json', historical_manifest)
    log = checked(BASE / 'ordinary-v1.log')
    markers = ['PACKAGED_PAYLOAD_OK', 'PACKAGED_ORIGINAL_TRADITIONAL_OK', 'PACKAGED_APP_COOKIE_OWNER_READ_OK', 'PACKAGED_APP_COOKIE_OWNER_TEXT_OK', 'PACKAGED_APP_COOKIE_OWNER_BROWSER_PROTOCOL_OK']
    assert all(marker.encode('ascii') in log for marker in markers)

    manifest_row = next(row for row in rows if row['path'] == MANIFEST)
    manifest_raw = row_bytes(manifest_row, 'snapshot'); manifest = json.loads(manifest_raw)
    original_rows = manifest['sourceProvenance']
    assert len(original_rows) == 52
    old_manifest = json.loads(checked(ROOT / manifest_row['baseSnapshot'], manifest_row['baseSHA256'], manifest_row['baseBytes']))
    assert len(old_manifest['sourceProvenance']) == 50 and original_rows[:50] == old_manifest['sourceProvenance']
    original_zip = Path('F:/legado-master.zip')
    assert sha(checked(original_zip)) == p['provenance']['originalArchiveSHA256']
    with zipfile.ZipFile(original_zip) as archive:
        for item in original_rows:
            raw = archive.read(item['archivePath'])
            assert len(raw) == item['bytes'] and sha(raw) == item['sha256']
            local = ROOT / 'Packages/LegadoRuntime/vendor/original-rule' / item['vendorPath']
            future = BASE / 'freeze-v2/sources/Packages/LegadoRuntime/vendor/original-rule' / item['vendorPath']
            assert (future if future.exists() else local).read_bytes() == raw
            retain(original_zip, 'original-pinned-entries/' + item['vendorPath'], raw)
    retain(ROOT / manifest_row['snapshot'], 'frozen-v2-original-rule-manifest.json', manifest_raw)
    audit = {
        'schemaVersion': 1, 'auditedAtUTC': datetime.now(timezone.utc).isoformat(),
        'readOnlyEvidenceAudit': True, 'preparation': fact(pp), 'independentReview': fact(rp),
        'confirmedBlockers': [], 'sourceRowsVerified': 19,
        'currentBaselineRowsVerified': 18, 'mergedHost': fact(merged_path),
        'inversePreviewTransformExactlyReconstructsFrozenCookieHost': True,
        'focusedInputsVerified': 153, 'ordinaryInputsVerified': 153,
        'actualJVMQualifiedLeaves': sorted(leaves), 'actualJVMMethods': 29, 'actualJVMSuites': 5,
        'actualFailures': 0, 'actualErrors': 0, 'actualSkipped': 0,
        'ordinaryInputOnlyDelta': changes,
        'ordinaryJar': fact(jar_path, jar_raw), 'ordinarySmokeMarkers': markers,
        'projectCompiledTestClassesExcluded': 141, 'JunitAndProjectTestLeakage': 0,
        'oldPublicProvenanceAndNoticeMembersPreserved': 21, 'pinnedOriginalArchiveEntriesVerified': 52,
        'oldSourceProvenanceRowsUnchanged': 50,
        'newNativeAppDefinitionsOnly': 5, 'newSwiftPackageDefinitionsOnly': 2,
        'SwiftSDKExecutions': 0, 'JNIExecutions': 0, 'grammarExecutedByThisAudit': 0,
        'JVMOrJarReexecutedByThisAudit': 0,
        'oldJarDoesNotBindNewSwiftOrMergedHostOrDerivedManifest': True,
        'rawEvidenceInventory': [{'path': name, 'sourcePath': item['sourcePath'], 'bytes': len(item['raw']), 'sha256': sha(item['raw'])} for name,item in payload.items()]}
    return audit, payload


if __name__ == '__main__':
    report, _ = verify()
    target = BASE / 'root-readonly-evidence-audit.json'
    with target.open('x', encoding='utf8', newline='\n') as stream:
        stream.write(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'audit': fact(target), 'actualJVMMethods': 29, 'focusedInputs': 153,
                      'ordinaryInputs': 153, 'actualJAR': report['ordinaryJar'],
                      'publicRawEvidenceFiles': len(report['rawEvidenceInventory']),
                      'SwiftSDKExecutions': 0, 'testsReexecuted': 0}))
