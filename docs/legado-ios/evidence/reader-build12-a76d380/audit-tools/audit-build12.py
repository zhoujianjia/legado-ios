#!/usr/bin/env python3
"""Ignored, independent static audit of the ordinary-JVM main reader IPA.

This does not execute the JVM, a book source, or the installed reader.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import struct
import subprocess
import sys
import zipfile

PREFLIGHT_ROOT = Path(__file__).resolve().parent
ROOT = PREFLIGHT_ROOT / "source"
HOST_ROOT = Path('F:\\yuedu-reader')
SOURCE_SHA = "a76d380fdc108db83be68961905ee49edd209571"
TRUSTED_WORKER = HOST_ROOT / ".build/audit-legado-ipa.py"
TRUSTED_WORKER_SHA256 = "29644a0daf9a88336c2c90f1b855c1984e47168e4f05fdf8598af4714e2564ed"
SNAPSHOT_RECORD_SHA256 = "8687680613095f3355da0d5ea3c084b4e7cf50074b5ace4cd9bc71f628c9c234"
sys.dont_write_bytecode = True

snapshot_bytes = (PREFLIGHT_ROOT / "snapshot-record.json").read_bytes()
if hashlib.sha256(snapshot_bytes).hexdigest() != SNAPSHOT_RECORD_SHA256:
    raise ValueError("The frozen snapshot record changed")
SNAPSHOT_RECORD = json.loads(snapshot_bytes)
if SNAPSHOT_RECORD["sourceCommit"] != SOURCE_SHA:
    raise ValueError("The source snapshot has the wrong commit")
for frozen in SNAPSHOT_RECORD["files"]:
    frozen_path = (ROOT / frozen["path"]).resolve()
    if not frozen_path.is_relative_to(ROOT.resolve()):
        raise ValueError("Unsafe source snapshot path")
    frozen_bytes = frozen_path.read_bytes()
    if len(frozen_bytes) != frozen["bytes"] or hashlib.sha256(frozen_bytes).hexdigest() != frozen["sha256"]:
        raise ValueError("Frozen source bytes changed: " + frozen["path"])

SOURCE_HELPER_ORIGINS = []
def module(name, relative):
    path = (ROOT / relative).resolve()
    if path == TRUSTED_WORKER.resolve():
        if hashlib.sha256(path.read_bytes()).hexdigest() != TRUSTED_WORKER_SHA256:
            raise ValueError("The pinned host Mach-O helper changed")
    elif not path.is_relative_to(ROOT.resolve()):
        raise ValueError("A reader helper escaped the clean source snapshot")
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value

probe = module("reader_binary_helpers", TRUSTED_WORKER)
config = module("reader_configuration_helpers", "scripts/reader-experience/stage-config.py")
packaging = module("reader_payload_helpers", "scripts/reader-experience/runtime-packaging.py")

def collect_source_helpers(value, seen):
    import types
    if id(value) in seen:
        return
    seen.add(id(value))
    location = getattr(value, "__file__", None)
    if location is None:
        return
    location = Path(location).resolve()
    if location.is_relative_to((HOST_ROOT / "scripts").resolve()) or location.is_relative_to((HOST_ROOT / "Packages").resolve()):
        raise ValueError("A frozen worktree helper was imported: " + str(location))
    if location.is_relative_to(ROOT.resolve()):
        SOURCE_HELPER_ORIGINS.append(str(location))
        for child in vars(value).values():
            if isinstance(child, types.ModuleType):
                collect_source_helpers(child, seen)
for helper in (config, packaging):
    collect_source_helpers(helper, set())
SOURCE_HELPER_ORIGINS = sorted(set(SOURCE_HELPER_ORIGINS))

def require(condition, message):
    if not condition:
        raise ValueError(message)

def sha(data):
    return hashlib.sha256(data).hexdigest()

def hash_file(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def ipa_entries(archive):
    # The existing reader executable already exceeds 128 MiB before adding Zero.
    # Keep finite limits appropriate to the main app rather than Probe's smaller cap.
    infos = archive.infolist()
    require(len(infos) <= 100_000 and sum(info.file_size for info in infos) <= 2 * 1024**3,
            'Main reader IPA exceeds the bounded audit size')
    result = {}
    for info in infos:
        name = info.filename
        parts = name.rstrip('/').split('/')
        require(info.orig_filename == name and '\x00' not in name and '\\' not in name
                and not name.startswith('/') and not any(part in {'', '.', '..'} or ':' in part for part in parts),
                'Unsafe IPA member path')
        require(name not in result and not info.flag_bits & 1, 'Duplicate or encrypted IPA member')
        require(stat.S_IFMT(info.external_attr >> 16) in {0, stat.S_IFREG, stat.S_IFDIR}, 'Non-regular IPA member')
        require(0 <= info.file_size <= 512 * 1024**2, 'IPA member exceeds the bounded audit size')
        result[name] = info
    return result

def device_macho(data):
    require(len(data) >= 32, 'Truncated Mach-O executable')
    magic, cpu, subtype, kind, count, command_bytes, flags, reserved = struct.unpack_from('<8I', data)
    require(magic == 0xfeedfacf and cpu == 0x0100000c and kind == 2, 'Expected a thin ARM64 executable')
    require(32 + command_bytes <= len(data), 'Truncated Mach-O load commands')
    offset, builds, signed = 32, [], False
    for _ in range(count):
        command, size = struct.unpack_from('<II', data, offset)
        require(size >= 8 and offset + size <= 32 + command_bytes, 'Malformed Mach-O command')
        if command == 0x32:
            platform, minimum, sdk, tools = struct.unpack_from('<4I', data, offset + 8)
            builds.append((platform, minimum))
        if command == 0x1d:
            signed = True
        offset += size
    require(offset == 32 + command_bytes and builds == [(2, 18 << 16)], 'Executable is not iPhoneOS 18.0')
    require(not signed, 'Expected an unsigned device executable')
    return {'architecture': 'arm64', 'platform': 'iPhoneOS', 'minimumIOS': '18.0',
            'bytes': len(data), 'sha256': sha(data), 'codeSignatureLoadCommand': signed}

def audit(args, report):
    require(args.source == SOURCE_SHA, 'This one-time audit is bound to the full Build12 source SHA')
    manifest_bytes = args.manifest.read_bytes()
    manifest = json.loads(manifest_bytes)
    digest = hash_file(args.ipa)
    report.update({'sourceCommit': args.source, 'ipaSHA256': digest, 'ipaBytes': args.ipa.stat().st_size,
                   'buildManifestSHA256': sha(manifest_bytes)})
    require(manifest.get('artifactKind') == 'legado-mainjs-reader-prototype', 'Wrong artifact kind')
    require(manifest.get('sourceCommit') == args.source, 'Manifest source mismatch')
    require(manifest.get('ipaSHA256') == digest and manifest.get('ipaBytes') == args.ipa.stat().st_size,
            'Manifest does not identify these exact IPA bytes')
    for key in ('deviceCompilationPassed', 'jvmIntegratedIntoReading', 'nativeJVMCompiled'):
        require(manifest.get(key) is True, 'Missing manifest flag: ' + key)
    for key in ('signed', 'deviceValidationPassed', 'mainJsRouteExecutionValidated', 'backendServicesConfigured'):
        require(manifest.get(key) is False, 'Unexpected manifest validation claim: ' + key)
    require(manifest.get('minimumIOS') == '18.0' and manifest.get('architecture') == 'arm64'
            and manifest.get('platform') == 'iPhoneOS' and manifest.get('configuration') == 'Release', 'Wrong build target')
    require(manifest.get("build") == "12", "Expected Build12")
    require(manifest.get("expectedTrackedOverlay") is False and manifest.get("trackedChanges") == [],
            "Independent-ID source must need no tracked project overlay")
    unchanged_project, expected_overlay = config.project_overlay((ROOT / "Yuedu-Reader.xcodeproj/project.pbxproj").read_bytes())
    require(expected_overlay["replacementCount"] == 0 and expected_overlay["identifiersAlreadyIndependent"] is True
            and expected_overlay["expectedTrackedOverlay"] is False
            and expected_overlay["originalSHA256"] == expected_overlay["overlaySHA256"],
            "The exact source no longer describes the independent-ID zero-replacement project")
    require(manifest.get("projectOverlay") == expected_overlay,
            "Manifest project overlay differs from the complete exact-source calculation")
    report["auditBindings"] = {"sourceCommit": SOURCE_SHA, "sourceSnapshot": str(ROOT),
            "snapshotRecordSHA256": SNAPSHOT_RECORD_SHA256,
            "allSnapshotFileBytesVerified": True, "importedSourceHelpers": SOURCE_HELPER_ORIGINS,
            "trustedHostMachOHelper": str(TRUSTED_WORKER), "trustedHostMachOHelperSHA256": TRUSTED_WORKER_SHA256,
            "worktreeManifestLicenseOrPinReads": False, "expectedBuild": "12", "expectedProjectReplacements": 0}
    require(manifest.get('bundledBookSources') == {'included': False}, 'Cloud IPA must not contain the private source pack')
    require(manifest.get('functionalAcceptance') == 'not_run', 'Compilation must not imply reading acceptance')
    artifact_dir = args.output.parent / (args.output.stem + '-artifacts')
    require(not os.path.lexists(artifact_dir), 'Audit extraction directory exists')
    artifact_dir.mkdir(parents=True)
    with zipfile.ZipFile(args.ipa) as archive:
        members = ipa_entries(archive)
        names = set(members)
        require(all(name.startswith('Payload/') for name in names), 'Unexpected IPA top-level path')
        require(not any(name.endswith('embedded.mobileprovision') or '/_CodeSignature/' in name for name in names),
                'Unexpected signing profile or signature directory')
        root = 'Payload/YueduReader.app/'
        roots = {PurePosixPath(name).parts[1] for name in names if len(PurePosixPath(name).parts) >= 3}
        require(roots == {'YueduReader.app'}, 'Expected only the main reader app')
        bundles = {root: config.MAIN_BUNDLE}
        bundles.update({root + 'PlugIns/' + name + '/': identity[0] for name, identity in config.EXTENSIONS.items()})
        embedded = {PurePosixPath(name).parts[3] for name in names
                    if name.startswith(root + 'PlugIns/') and len(PurePosixPath(name).parts) > 3}
        require(embedded == set(config.EXTENSIONS), 'Missing or unexpected app extensions')
        bundle_records = []
        for bundle, identity in bundles.items():
            info_bytes = probe.read(archive, members, bundle + 'Info.plist', 1024 * 1024)
            info = plistlib.loads(info_bytes)
            require(info.get('CFBundleIdentifier') == identity, 'Bundle identity differs: ' + bundle)
            require(info.get('YueduExperienceSourceCommit') == args.source, 'Bundle source stamp differs')
            require(info.get('GatewayBaseURL') == '', 'Unexpected gateway configuration')
            require((info.get('CFBundleShortVersionString'), info.get('CFBundleVersion')) ==
                    (manifest['version'], manifest['build']), 'Bundle version/build mismatch')
            require(info.get('CFBundleSupportedPlatforms') == ['iPhoneOS'] and info.get('MinimumOSVersion') == '18.0',
                    'Bundle is not the iOS 18 device build')
            for key, value in config.LOCAL_FLAGS.items():
                require(info.get(key) is value, 'Missing local policy flag: ' + key)
            require(plistlib.loads(probe.read(archive, members, bundle + 'GoogleService-Info.plist')) ==
                    config.synthetic_config(), 'Unexpected backend config')
            executable = info.get('CFBundleExecutable')
            require(isinstance(executable, str) and executable == PurePosixPath(executable).name, 'Invalid executable path')
            executable_data = probe.read(archive, members, bundle + executable, 512 * 1024**2)
            record = device_macho(executable_data)
            record.update({'bundleIdentifier': identity, 'executable': executable, 'infoPlistSHA256': sha(info_bytes)})
            bundle_records.append(record)
            if bundle == root:
                require(set(info.get('UIDeviceFamily', [])) == {1, 2}, 'Expected iPhone and iPad support')
                schemes = {s for entry in info.get('CFBundleURLTypes', []) for s in entry.get('CFBundleURLSchemes', [])}
                require({'yuedu', 'legado', config.GOOGLE_REVERSED} <= schemes, 'Missing import URL scheme')
                require(info.get('GIDClientID') == config.GOOGLE_CLIENT, 'Unexpected Google client identity')
                executable_path = artifact_dir / executable
                executable_path.write_bytes(executable_data)
        report['bundles'] = bundle_records
        require(not any(name.startswith(root + 'LegadoRuntime/java-home/') for name in names), 'Nested legacy Java home remains')
        require(not any(name.endswith('/BuiltInBookSources.json') or name.endswith('/BuiltInBookSources.manifest.json')
                        for name in names), 'Private source resource unexpectedly packaged')
        home = args.native_root / '.build/legado-ios/device-static/java-home'
        require(home.is_dir() and not home.is_symlink(), 'Pinned native device Java home is missing')
        expected_files = {}
        for path in home.rglob('*'):
            require(not path.is_symlink(), 'Native baseline contains a link')
            if path.is_file():
                expected_files[path.relative_to(home).as_posix()] = path
        packaged_files = {name[len(root + 'lib/'):] for name in names if name.startswith(root + 'lib/') and not members[name].is_dir()}
        owner = '.legado-runtime-home-owner.json'
        require(packaged_files == set(expected_files) | {owner}, 'Packaged Java home file inventory differs from pinned native12')
        aggregate = hashlib.sha256()
        total_bytes = 0
        for relative, baseline in sorted(expected_files.items()):
            data = probe.read(archive, members, root + 'lib/' + relative)
            require(data == baseline.read_bytes(), 'Native Java home bytes differ: ' + relative)
            total_bytes += len(data)
            aggregate.update(relative.encode('utf-8') + b'\0' + hashlib.sha256(data).digest())
        owner_data = json.loads(probe.read(archive, members, root + 'lib/' + owner))
        require(owner_data == {'schemaVersion': 1, 'owner': 'legado-ios-prototype', 'layout': 'app-lib-java-home'}, 'Invalid Java home ownership marker')
        modules = {name[len(root + 'lib/modules/'):].split('/')[0] for name in names
                   if name.startswith(root + 'lib/modules/') and name != root + 'lib/modules/'}
        require(modules == set(probe.REQUIRED_MODULES), 'Module set must be exactly the pinned 13')
        report['nativeJavaHome'] = {'matchesPinnedNative12Bytes': True, 'fileCount': len(expected_files),
                                   'totalBytes': total_bytes, 'pathAndFileHashDigest': aggregate.hexdigest(),
                                   'modules': sorted(modules), 'extraOwnedMarker': owner}
        payload = json.loads(probe.read(archive, members, root + 'LegadoRuntime/runtime-manifest.json'))
        require(payload.get('sourcePins') == json.loads((ROOT / 'scripts/legado-ios/runtime-lock.json').read_bytes()), 'Runtime pin mismatch')
        require(payload.get('modules') == list(probe.REQUIRED_MODULES), 'Runtime staging module list mismatch')
        jar_data = probe.read(archive, members, root + 'LegadoRuntime/legado-runtime.jar')
        jar_hash = sha(jar_data)
        require(jar_hash == payload.get('jarSHA256') == manifest['bundleValidation']['runtimePayload']['jar']['sha256'], 'JAR hash does not bind the payload and build manifests')
        jar_path = artifact_dir / 'legado-runtime.jar'
        jar_path.write_bytes(jar_data)
        inspected = packaging.inspect_jar(jar_path)
        with zipfile.ZipFile(io.BytesIO(jar_data)) as jar:
            jar_names = jar.namelist()
            # NodeTest is a production XPath AST class. Match the closed app test
            # names (including nested classes), rather than a dependency suffix.
            require(not any(name.startswith(('org/junit/', 'org/hamcrest/', 'fixtures/', 'io/yuedu/legado/tls-fixture-v1/')) or
                            any(name == test + '.class' or name.startswith(test + '$')
                                for test in packaging.PROJECT_TEST_CLASSES) for name in jar_names),
                    'Test fixture or test class in ordinary JAR')
            license_records = []
            vendor = ROOT / 'Packages/LegadoRuntime/vendor'
            require(jar.read('META-INF/licenses/legado/LICENSE') == (vendor / 'LICENSE').read_bytes(), 'Original source license mismatch')
            for directory, prefix in ((vendor / 'licenses', 'META-INF/licenses/'),
                                      (vendor / 'probe/licenses', 'META-INF/licenses/jvm-http/'),
                                      (vendor / 'runtime-http/licenses', 'META-INF/licenses/jvm-http/')):
                for path in sorted(directory.rglob('*')):
                    if path.is_file():
                        entry = prefix + path.relative_to(directory).as_posix()
                        data = jar.read(entry)
                        require(data == path.read_bytes(), 'License bytes differ: ' + entry)
                        license_records.append({'entry': entry, 'bytes': len(data), 'sha256': sha(data)})
        report['ordinaryJar'] = {**inspected, 'licenses': license_records, 'fixtureAndJUnitExclusionPassed': True}
    preferred = probe.TOOL_ROOT / 'Scripts/python.exe'
    python = preferred if preferred.is_file() else Path(sys.executable)
    worker = subprocess.run([str(python), str(TRUSTED_WORKER), '--macho-worker', str(executable_path)],
                            capture_output=True, text=True, timeout=90)
    require(worker.returncode == 0, 'Independent Mach-O worker failed: ' + (worker.stderr or worker.stdout)[:4096])
    result = json.loads(worker.stdout)
    require(result.get('requiredDynamicExportsPresent') is True and len(result.get('requiredDynamicExports', [])) == 39,
            'The exact required 39 exports are not all present')
    report['mainExecutableDynamicExports'] = result
    report['staticAuditPassed'] = True

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ipa', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--source', required=True)
    parser.add_argument('--native-root', type=Path, default=HOST_ROOT / '.build/cloud-evidence/run-39083752761/native')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    require(not os.path.lexists(args.output), 'Report already exists')
    report = {'schemaVersion': 1, 'staticAuditPassed': False, 'runtimeExecuted': False,
              'deviceValidationPassed': False, 'issues': [],
              'scope': 'Independent static inspection of this ordinary-JVM main reader IPA; no reading or device execution claim.'}
    try:
        audit(args, report)
    except Exception as error:
        report['issues'].append(type(error).__name__ + ': ' + str(error))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x', encoding='utf-8', newline='\n') as output:
        json.dump(report, output, ensure_ascii=False, indent=2)
        output.write('\n')
    print(json.dumps({'staticAuditPassed': report['staticAuditPassed'], 'issues': report['issues'], 'output': str(args.output)}, indent=2))
    if not report['staticAuditPassed']:
        raise SystemExit(1)

if __name__ == '__main__':
    main()
