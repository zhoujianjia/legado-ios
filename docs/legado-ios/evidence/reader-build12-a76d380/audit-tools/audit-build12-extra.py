import argparse,hashlib,io,json,os,plistlib,subprocess,sys,xml.etree.ElementTree as ET,zipfile,importlib.util,re,struct,zlib
from pathlib import Path

def inspect_png_dimensions(data):
    """Read dimensions from bounded PNG chunks, including Apple's CgBI prefix.

    This validates chunk framing and every CRC; it does not decode pixels.
    """
    def check(condition, message):
        if not condition:
            raise ValueError(message)

    check(8 <= len(data) <= 16 * 1024**2 and data[:8] == b'\x89PNG\r\n\x1a\n', 'Invalid or oversized PNG')
    offset = 8
    chunks = []
    width = height = None
    saw_image_data = False
    ended = False
    while offset < len(data):
        check(len(chunks) < 4096 and offset + 12 <= len(data), 'PNG chunk framing is truncated or excessive')
        size = struct.unpack_from('>I', data, offset)[0]
        kind = data[offset + 4:offset + 8]
        check(all(65 <= value <= 90 or 97 <= value <= 122 for value in kind), 'Invalid PNG chunk type')
        check(size <= 8 * 1024**2 and offset + 12 + size <= len(data), 'PNG chunk payload is truncated or oversized')
        payload = data[offset + 8:offset + 8 + size]
        stored_crc = struct.unpack_from('>I', data, offset + 8 + size)[0]
        calculated_crc = zlib.crc32(payload, zlib.crc32(kind)) & 0xffffffff
        check(stored_crc == calculated_crc, 'PNG chunk CRC mismatch: ' + kind.decode('ascii'))
        if kind == b'CgBI':
            check(not chunks and width is None and size == 4, 'Unexpected CgBI placement or size')
        elif kind == b'IHDR':
            check(width is None and size == 13 and all(item['type'] == 'CgBI' for item in chunks), 'Invalid or repeated PNG IHDR')
            width, height = struct.unpack_from('>II', payload)
            check(0 < width < 2**31 and 0 < height < 2**31, 'Invalid PNG dimensions')
        else:
            check(width is not None, 'PNG chunk precedes IHDR')
            if kind == b'IDAT':
                saw_image_data = True
            elif kind == b'IEND':
                check(size == 0 and saw_image_data and offset + 12 == len(data), 'Invalid PNG IEND or trailing bytes')
                ended = True
        chunks.append({'type': kind.decode('ascii'), 'offset': offset, 'payloadBytes': size,
                       'storedCRC32': format(stored_crc, '08x'), 'calculatedCRC32': format(calculated_crc, '08x'),
                       'crcMatches': True})
        offset += size + 12
        if ended:
            break
    check(ended and width is not None and offset == len(data), 'PNG lacks complete IHDR, IDAT or IEND')
    return {'width': width, 'height': height, 'allPNGChunkCRCsMatch': True, 'chunks': chunks}

p=argparse.ArgumentParser();p.add_argument('--ipa',type=Path,required=True);p.add_argument('--manifest',type=Path,required=True);p.add_argument('--evidence',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
base=Path(__file__).resolve().parent;snapshot=base/'source';root='Payload/YueduReader.app/'
if os.path.lexists(a.output): raise ValueError('Audit output already exists')
spec=importlib.util.spec_from_file_location('build12_frozen_core',base/'audit-build12.py')
frozen=importlib.util.module_from_spec(spec);spec.loader.exec_module(frozen)
assert snapshot==frozen.ROOT
sha=lambda d:hashlib.sha256(d).hexdigest()
result={'schemaVersion':1,'sourceCommit':'a76d380fdc108db83be68961905ee49edd209571','scope':'Static packaged resource and raw ordinary-JVM XML audit only; no CoreText/UIKit/device execution claim.','passed':False,'issues':[],'staticOnly':True}
try:
 with zipfile.ZipFile(a.ipa) as z:
  members=frozen.ipa_entries(z)
  names=z.namelist();assert len(names)==len(set(names))
  info=plistlib.loads(frozen.probe.read(z,members,root+'Info.plist',1024*1024));sourceInfo=plistlib.loads((snapshot/'Info.plist').read_bytes())
  assert info.get('NSBonjourServices')==sourceInfo.get('NSBonjourServices')
  metadata_helper=frozen.module('build12_discovery_metadata','scripts/reader-experience/renewal-probe-tools.py')
  assert metadata_helper.smoke.REPO==snapshot
  frozen.collect_source_helpers(metadata_helper,set())
  metadata_directory=a.output.parent/(a.output.stem+'-discovery-metadata')
  assert not os.path.lexists(metadata_directory),'Metadata extraction directory already exists'
  metadata_directory.mkdir(parents=True)
  for language in metadata_helper.LANGUAGES:
   relative=language+'.lproj/InfoPlist.strings'
   packed=frozen.probe.read(z,members,root+relative,64*1024)
   destination=metadata_directory/relative
   destination.parent.mkdir()
   with destination.open('xb') as stream:stream.write(packed)
  result['discoveryMetadata']=metadata_helper.verify_built_discovery_metadata(metadata_directory,info)
  result['discoveryMetadata']['exactBoundSourceBonjourListMatched']=True
  result['discoveryMetadata']['sourceHelperSHA256']=sha((snapshot/'scripts/reader-experience/renewal-probe-tools.py').read_bytes())
  semantic_tables=[]
  for language in metadata_helper.LANGUAGES:
   relative=language+'.lproj/InfoPlist.strings'
   source_path=snapshot/'Resources'/relative
   built_path=metadata_directory/relative
   source_keys=re.findall(r'^\s*"([^"\r\n]+)"\s*=',source_path.read_text(encoding='utf-8'),flags=re.MULTILINE)
   assert source_keys and len(source_keys)==len(set(source_keys))
   raw=built_path.read_bytes()
   if raw.startswith(b'bplist') or raw.lstrip().startswith((b'<?xml',b'<plist')):
    values=plistlib.loads(raw);assert isinstance(values,dict)
    built_keys=list(values)
   else:
    decoded=raw.decode('utf-16' if raw.startswith((b'\xff\xfe',b'\xfe\xff')) else 'utf-8-sig')
    built_keys=re.findall(r'^\s*"([^"\r\n]+)"\s*=',decoded,flags=re.MULTILINE)
   assert len(built_keys)==len(set(built_keys)) and set(built_keys)==set(source_keys)
   for key in source_keys:
    assert metadata_helper.decoded_strings_value(built_path,key)==metadata_helper.decoded_strings_value(source_path,key),(language,key)
   semantic_tables.append({'language':language,'keyCount':len(source_keys),'allSourceKeysAndValuesMatched':True,
                           'sourceSHA256':sha(source_path.read_bytes()),'builtSHA256':sha(raw)})
  result['discoveryMetadata']['completeLocalizedInfoPlistStringsTables']=semantic_tables
  executable_name=info.get('CFBundleExecutable')
  assert isinstance(executable_name,str) and executable_name==Path(executable_name).name
  executable_bytes=frozen.probe.read(z,members,root+executable_name,512*1024**2)
  result['discoveryMainExecutable']=frozen.device_macho(executable_bytes)
  executable_path=metadata_directory/'main-executable.macho'
  with executable_path.open('xb') as stream:stream.write(executable_bytes)
  preferred=frozen.probe.TOOL_ROOT/'Scripts/python.exe'
  python=preferred if preferred.is_file() else Path(sys.executable)
  worker=subprocess.run([str(python),str(base/'audit-discovery-imports.py'),'--executable',str(executable_path)],
                        capture_output=True,text=True,timeout=90)
  assert worker.returncode==0,'LIEF DNS-SD import worker failed: '+(worker.stderr or worker.stdout)[:4096]
  imports=json.loads(worker.stdout)
  assert imports.get('requiredDNSSDImportsPresent') is True and imports.get('executableSHA256')==sha(executable_bytes)
  assert {row.get('name') for row in imports.get('requiredImports',[])}=={'_DNSServiceResolve','_DNSServiceGetAddrInfo','_DNSServiceSetDispatchQueue','_DNSServiceRefDeallocate'}
  result['mainExecutableDNSServiceImports']=imports
  assert info['CFBundleVersion']=='12' and info['YueduExperienceSourceCommit']==result['sourceCommit']
  assert info['YueduLocalExperience'] is True
  assert info['CFBundleDevelopmentRegion']=='zh-Hans' and info['CFBundleLocalizations'][0]=='zh-Hans'
  assert info['UIAppFonts']==sourceInfo['UIAppFonts']
  public_manifest=json.loads(a.manifest.read_bytes())
  assert public_manifest['sourceCommit']==result['sourceCommit'] and public_manifest['build']=='12'
  assert info['CFBundleDisplayName']=='\u672c\u5730\u4e66\u67b6' and public_manifest['displayName']==info['CFBundleDisplayName']
  localized=[]
  for src in sorted((snapshot/'Resources').glob('*.lproj/InfoPlist.strings')):
   compiled=root+src.parent.name+'/InfoPlist.strings'
   assert compiled in names
   source_values=dict(re.findall(r'"([^"\n]+)"\s*=\s*"([^"\n]*)"\s*;',src.read_text(encoding='utf-8')))
   packed=z.read(compiled)
   try:values=plistlib.loads(packed)
   except plistlib.InvalidFileException:
    text=packed.decode('utf-16') if packed[:2] in [b'\xff\xfe',b'\xfe\xff'] else packed.decode('utf-8-sig')
    values=dict(re.findall(r'"([^"\n]+)"\s*=\s*"([^"\n]*)"\s*;',text))
   assert values.get('CFBundleDisplayName')==source_values.get('CFBundleDisplayName'),compiled
   localized.append({'entry':compiled,'displayName':values.get('CFBundleDisplayName'),'sha256':sha(packed),'exactSourceDisplayNameMatched':True})
  result['localizedBrandNames']=localized
  icons=info.get('CFBundleIcons',{}).get('CFBundlePrimaryIcon',{})
  assert icons.get('CFBundleIconName')=='AppIcon'
  iconfiles=icons.get('CFBundleIconFiles',[]);assert iconfiles
  actual_icons=[]
  for name in sorted(names):
   relative=name[len(root):] if name.startswith(root) else ''
   if relative.startswith('AppIcon') and relative.endswith('.png') and '/' not in relative:
    data=z.read(name);assert data.startswith(b'\x89PNG\r\n\x1a\n')
    dimensions=inspect_png_dimensions(data)
    actual_icons.append({'entry':name,'bytes':len(data),'sha256':sha(data),**dimensions})
  assert actual_icons and root+'Assets.car' in names
  assets=z.read(root+'Assets.car')
  result['compiledBrandAssets']={'primaryIconName':icons['CFBundleIconName'],'iconFiles':iconfiles,'actualPNGIcons':actual_icons,
    'assetsCarBytes':len(assets),'assetsCarSHA256':sha(assets),'readerBrandIconNameBytesPresent':b'ReaderBrandIcon' in assets,
    'limitation':'Compiled icon resources are inspected statically; their rendered appearance and CoreUI rendition decoding require separate visual evidence.'}
  catalogs=[]
  for folder in ['AppIcon.appiconset','ReaderBrandIcon.imageset']:
   for src in sorted((snapshot/'Resources/Assets.xcassets'/folder).iterdir()):
    if src.is_file():catalogs.append({'path':str(src.relative_to(snapshot)),'bytes':src.stat().st_size,'sha256':sha(src.read_bytes())})
  result['sourceBrandCatalogs']=catalogs
  raw=z.read(root+'ReaderFonts-provenance.json');assert raw==(snapshot/'Resources/ReaderFonts/ReaderFonts-provenance.json').read_bytes()
  manifest=json.loads(raw);fonts=[]
  assert len(manifest['fonts'])==2
  for item in manifest['fonts']:
   d=z.read(root+item['fileName']);assert d==(snapshot/'Resources/ReaderFonts'/item['fileName']).read_bytes()
   assert sha(d)==item['sha256'] and len(d)==item['bytes'] and item['modified'] is False
   assert item['fileName'] in info['UIAppFonts']
   lic=z.read(root+item['licenseFile']);assert lic==(snapshot/'Resources/ReaderFonts'/item['licenseFile']).read_bytes()
   assert sha(lic)==item['licenseSHA256'] and len(lic)==item['licenseBytes']
   fonts.append({'fileName':item['fileName'],'bytes':len(d),'sha256':sha(d),'licenseFile':item['licenseFile'],'licenseBytes':len(lic),'licenseSHA256':sha(lic),'sourceCommitBytesMatched':True,'InfoPlistRegistrationPathExists':True})
  result['bundledFonts']=fonts;result['uncompressedFontBytes']=sum(f['bytes'] for f in fonts)
  result['fontProvenance']={'bytes':len(raw),'sha256':sha(raw),'matchesExactSourceCommit':True}
  result['simplifiedChineseInfo']={'CFBundleDevelopmentRegion':info['CFBundleDevelopmentRegion'],'CFBundleLocalizations':info['CFBundleLocalizations'],'CFBundleDisplayName':info.get('CFBundleDisplayName')}
  jar=z.read(root+'LegadoRuntime/legado-runtime.jar')
  with zipfile.ZipFile(io.BytesIO(jar)) as j:
   test_classes=['io/legado/app/JsEngineCapabilitiesTest', 'io/legado/app/model/analyzeRule/AnalyzeByJSonPathErrorPolicyTest', 'io/legado/app/model/analyzeRule/AnalyzeByJSoupDomTest', 'io/yuedu/legado/CpuLoopCapabilityProbeTest', 'io/yuedu/legado/DeclarativeScalarSelectorTest', 'io/yuedu/legado/DeclarativeSourceTest', 'io/yuedu/legado/InteropSemanticSuiteTest', 'io/yuedu/legado/LegadoRuntimeTest', 'io/yuedu/legado/MainJsFacadeTest', 'io/yuedu/legado/MainJsResultMarshallerTest', 'io/yuedu/legado/MainJsScopeTest', 'io/yuedu/legado/OkHttpWireCapabilityProbeTest', 'io/yuedu/legado/OriginalAnalyzeRuleTest', 'io/yuedu/legado/OriginalRuleScopesConcurrencyTest', 'io/yuedu/legado/ProductionHttpTransportTest', 'io/yuedu/legado/RuntimeTaskTraceTest', 'io/yuedu/legado/SourceHttpSemanticsTest', 'io/yuedu/legado/StaticRuleReplacementTest', 'io/yuedu/legado/StaticScalarSelectorRuleTest', 'io/yuedu/legado/TlsCapabilityProbeTest']
   assert not any(any(n==c+'.class' or n.startswith(c+'$') for c in test_classes) for n in j.namelist())
   assert set(frozen.packaging.REQUIRED).issubset(j.namelist())
  result['productionCoordinatorAndTestExclusionMatchExactSourcePolicy']=True
  assert not any('BuiltInBookSources' in n or n.lower().endswith('/booksource.json') for n in names)
  result['privateSourceResourceAbsent']=True
 xmls=sorted(a.evidence.glob('**/Packages/LegadoRuntime/jvm/build/test-results/test/TEST-*.xml'))
 cases=[];suites=[]
 for f in xmls:
  t=ET.parse(f).getroot();tests=t.findall('testcase');assert len(tests)==int(t.attrib['tests'])
  assert not any(tst.find('failure') is not None or tst.find('error') is not None or tst.find('skipped') is not None for tst in tests)
  assert int(t.attrib.get('failures','0'))==0 and int(t.attrib.get('errors','0'))==0 and int(t.attrib.get('skipped','0'))==0
  cases.extend((t.attrib['name'],c.attrib['name']) for c in tests)
  suites.append({'name':t.attrib['name'],'testcases':len(tests),'xmlSHA256':sha(f.read_bytes())})
 expected_cases={tuple(row) for row in [['io.legado.app.JsEngineCapabilitiesTest', 'cachedCompilationDoesNotCaptureCallerBindings'], ['io.legado.app.JsEngineCapabilitiesTest', 'constForInAndBlockScopesRemainIndependent'], ['io.legado.app.JsEngineCapabilitiesTest', 'currentRhinoSupportsStableModernSyntax'], ['io.legado.app.JsEngineCapabilitiesTest', 'dynamicCompatibilityParsingPreservesEvalSyntaxErrors'], ['io.legado.app.JsEngineCapabilitiesTest', 'dynamicCompilationNormalizesNestedLegacyWithConst'], ['io.legado.app.JsEngineCapabilitiesTest', 'dynamicEvalRealmKeepsJavaCryptoCallable'], ['io.legado.app.JsEngineCapabilitiesTest', 'e4xDescendantExpressionsRemainSupported'], ['io.legado.app.JsEngineCapabilitiesTest', 'javaInvocationFailuresRemainCatchableByScripts'], ['io.legado.app.JsEngineCapabilitiesTest', 'javaMethodsRemainCallableInsideWithAndEvalScopes'], ['io.legado.app.JsEngineCapabilitiesTest', 'jsoupIsReachableFromJsScope'], ['io.legado.app.JsEngineCapabilitiesTest', 'legacyConstDoesNotShadowRuntimeBindings'], ['io.legado.app.JsEngineCapabilitiesTest', 'legacyConstRewriteSkipsResolvedAndNonValueNames'], ['io.legado.app.JsEngineCapabilitiesTest', 'legacyNestedConstReadAfterBlockRemainsVisible'], ['io.legado.app.JsEngineCapabilitiesTest', 'legacyTopLevelBlockDeclarationsRemainVisibleAfterBlock'], ['io.legado.app.JsEngineCapabilitiesTest', 'logicalAssignmentOperatorsPreserveShortCircuitSemantics'], ['io.legado.app.JsEngineCapabilitiesTest', 'nestedEvalKeepsDynamicallyLoadedFunctionsVisible'], ['io.legado.app.JsEngineCapabilitiesTest', 'nestedJavaClassesKeepWrapperSemantics'], ['io.legado.app.JsEngineCapabilitiesTest', 'optionalCatchBindingCompilesWithLegacyWithConst'], ['io.legado.app.JsEngineCapabilitiesTest', 'readOnlyJavaMethodsKeepTheirDetachedReceiver'], ['io.legado.app.JsEngineCapabilitiesTest', 'restAndSpreadSyntaxRemainSupported'], ['io.legado.app.JsEngineCapabilitiesTest', 'sharedLibraryFunctionUsesCallerBindingsAsDefaultThis'], ['io.legado.app.JsEngineCapabilitiesTest', 'topLevelDeclarationsRemainVisibleToSourceExtraction'], ['io.legado.app.JsEngineCapabilitiesTest', 'typeInfoWrappingUsesRegisteredFactories'], ['io.legado.app.JsEngineCapabilitiesTest', 'withCompatibilityOnlyRewritesDirectDeclarations'], ['io.legado.app.JsEngineCapabilitiesTest', 'withScopedConstRemainsVisibleForLegacySources'], ['io.legado.app.model.analyzeRule.AnalyzeByJSonPathErrorPolicyTest', 'anExplicitHandlerThrowPropagatesTheSameThrowableFromAllThreeHelpers'], ['io.legado.app.model.analyzeRule.AnalyzeByJSonPathErrorPolicyTest', 'explicitCallbacksReceiveRealExceptionsAndBypassControllableFineLogging'], ['io.legado.app.model.analyzeRule.AnalyzeByJSonPathErrorPolicyTest', 'malformedJsonConstructionStillThrowsBeforeAnyErrorCallback'], ['io.legado.app.model.analyzeRule.AnalyzeByJSonPathErrorPolicyTest', 'missingAndInvalidPathsLeaveEmptyResultsInEachHelper'], ['io.legado.app.model.analyzeRule.AnalyzeByJSonPathErrorPolicyTest', 'orFallbackAfterMissingOrInvalidMatchesTheFourApplicableOriginalObservations'], ['io.legado.app.model.analyzeRule.AnalyzeByJSoupDomTest', 'chained element selection preserves the original document and parents'], ['io.legado.app.model.analyzeRule.AnalyzeByJSoupDomTest', 'excluding indexes filters results without removing document nodes'], ['io.legado.app.model.analyzeRule.AnalyzeByJSoupDomTest', 'ordinary nested tags still exclude descendant text from textNodes'], ['io.legado.app.model.analyzeRule.AnalyzeByJSoupDomTest', 'positive and negative indexes keep selection order and node identity'], ['io.legado.app.model.analyzeRule.AnalyzeByJSoupDomTest', 'reading a book name does not replace its link with the author link'], ['io.legado.app.model.analyzeRule.AnalyzeByJSoupDomTest', 'reading a forum title leaves its thread link available'], ['io.legado.app.model.analyzeRule.AnalyzeByJSoupDomTest', 'self closing links preserve legacy direct text nodes'], ['io.yuedu.legado.CpuLoopCapabilityProbeTest', 'hostAndSignalFramesCannotQualifyAsCpuEvidence'], ['io.yuedu.legado.CpuLoopCapabilityProbeTest', 'parentPublicCancellationCancelsAlreadySampledChildAndStopsOwnedWorker'], ['io.yuedu.legado.CpuLoopCapabilityProbeTest', 'publicCancelAndAbsoluteDeadlineInterruptVerifiedCpuLoopsAndRecoverOnSameWorker'], ['io.yuedu.legado.CpuLoopCapabilityProbeTest', 'unregisteredWorkloadAndInsufficientParentBudgetCannotPass'], ['io.yuedu.legado.DeclarativeScalarSelectorTest', 'listTransformsAndCaptureListScalarTransformsRemainUnsupported'], ['io.yuedu.legado.DeclarativeScalarSelectorTest', 'nonUrlScalarTransformsReachAllFourExistingDeclarativeReadingStages'], ['io.yuedu.legado.DeclarativeScalarSelectorTest', 'urlRulesIncludingChapterUrlAndUrlTemplatesNeverUseTheScalarTransform'], ['io.yuedu.legado.DeclarativeSourceTest', 'originalCssAnalyzerCompletesTraditionalReadingChain'], ['io.yuedu.legado.DeclarativeSourceTest', 'unportedTransformsReturnUnsupportedInsteadOfApproximateOutput'], ['io.yuedu.legado.DeclarativeSourceTest', 'upstreamJsonPathXPathAndRegexRemainExecutable'], ['io.yuedu.legado.InteropSemanticSuiteTest', 'equalTextDoesNotHideWrongJsonType'], ['io.yuedu.legado.InteropSemanticSuiteTest', 'everyCaseReportsExceptionsAndAllFailedRejectsRuntime'], ['io.yuedu.legado.InteropSemanticSuiteTest', 'lockedEnginePassesCompleteInteropMatrix'], ['io.yuedu.legado.InteropSemanticSuiteTest', 'nullOverloadAmbiguityMatchesTheLockedEnginesDefaultWrapper'], ['io.yuedu.legado.LegadoRuntimeTest', 'batchRejectsOutOfBatchCacheWritesAndHandlesMissingFunction'], ['io.yuedu.legado.LegadoRuntimeTest', 'byteResponsesUseDeclaredCharsetBeforeLossyHostText'], ['io.yuedu.legado.LegadoRuntimeTest', 'completeMainJsReadingChainPreservesRequestsCookiesVariablesAndCache'], ['io.yuedu.legado.LegadoRuntimeTest', 'deadlineAndCancellationBeforeRegistrationAreBothEffective'], ['io.yuedu.legado.LegadoRuntimeTest', 'hostTimeoutAndBrowserCancellationRemainDistinctErrors'], ['io.yuedu.legado.LegadoRuntimeTest', 'infiniteLoopCanBeCancelledFromAnotherThread'], ['io.yuedu.legado.LegadoRuntimeTest', 'originalJavaInteropPreservesCollectionsBytesRegexAndOverloads'], ['io.yuedu.legado.LegadoRuntimeTest', 'semanticProbeUsesOriginalE4xAndCustomEvalFeatures'], ['io.yuedu.legado.LegadoRuntimeTest', 'sharedPrototypeMatchesUpstreamWhileOtherSessionsAndCallBindingsRemainIsolated'], ['io.yuedu.legado.LegadoRuntimeTest', 'snapshotRequestEvidencePreservesExplicitGetNullAndExactPostBodyBase64'], ['io.yuedu.legado.LegadoRuntimeTest', 'unregisteredHostAndClosedSessionFailExplicitly'], ['io.yuedu.legado.MainJsFacadeTest', 'explicitNullRequiredFieldsFailFacadeWithoutReturningPartialLists'], ['io.yuedu.legado.MainJsFacadeTest', 'invalidShapesAndAliasOnlyChaptersRemainExplicitErrors'], ['io.yuedu.legado.MainJsFacadeTest', 'readingChainNormalizesIdentityTypesRelativeUrlsVolumesAndFilteredIndexes'], ['io.yuedu.legado.MainJsFacadeTest', 'returnlessMutationUsesExplicitFiniteDtoFallbackAndMergeWhitelist'], ['io.yuedu.legado.MainJsFacadeTest', 'serializedLegacyReturnsAreDecodedOnceThroughRealFacade'], ['io.yuedu.legado.MainJsResultMarshallerTest', 'chaptersHaveNoChapterUrlAliasAndSkipMalformedBooleanObjects'], ['io.yuedu.legado.MainJsResultMarshallerTest', 'chaptersResolveRelativeUrlsAndOverwriteBookIdentityAndSequentialIndex'], ['io.yuedu.legado.MainJsResultMarshallerTest', 'chaptersUseNetworkUtilsCommaOptionAndInvalidBaseBehavior'], ['io.yuedu.legado.MainJsResultMarshallerTest', 'detailsDefaultCanRenameIsTrueAndOnlyEmptyAuthorBypassesFalse'], ['io.yuedu.legado.MainJsResultMarshallerTest', 'detailsDoNotSilentlySerializeInvalidStringFieldsAsSuccessfulMetadata'], ['io.yuedu.legado.MainJsResultMarshallerTest', 'detailsDownloadUrlsResolveTrimDeduplicateAndRejectWholeBadArray'], ['io.yuedu.legado.MainJsResultMarshallerTest', 'detailsMergeWhitelistPreservesExistingFieldsAndRenameOptOut'], ['io.yuedu.legado.MainJsResultMarshallerTest', 'detailsNullBlankAndLegacyJsonStringsFollowOriginalReturnProtocol'], ['io.yuedu.legado.MainJsResultMarshallerTest', 'detailsResetBookTypeBeforeScriptAndRespectValidOverride'], ['io.yuedu.legado.MainJsResultMarshallerTest', 'detailsTocFallbackAppliesOnlyWhenBlankAndDoesNotAbsolutizeReturnedToc'], ['io.yuedu.legado.MainJsResultMarshallerTest', 'detailsVariableObjectAndStringReplaceRatherThanMergePreviousMap'], ['io.yuedu.legado.MainJsResultMarshallerTest', 'emptyTocFailsAtJsSourceBookBoundaryInsteadOfReportingSuccess'], ['io.yuedu.legado.MainJsResultMarshallerTest', 'explicitNullChapterIdentityFailsWholeOperationAfterDtoDeserialization'], ['io.yuedu.legado.MainJsResultMarshallerTest', 'explicitNullSearchIdentityFailsWholeOperationAfterDtoDeserialization'], ['io.yuedu.legado.MainJsResultMarshallerTest', 'fileSourceReaddsFileBitsAndRequiresNonemptyDownloads'], ['io.yuedu.legado.MainJsResultMarshallerTest', 'missingIdentityFieldsKeepDefaultsAndBlankFirstFieldShortCircuitsNullSecondField'], ['io.yuedu.legado.MainJsResultMarshallerTest', 'searchAcceptsLegacyJsonStringsButRejectsWrongShapeAndStringifiedNull'], ['io.yuedu.legado.MainJsResultMarshallerTest', 'searchFiltersEntriesAndOverwritesSourceIdentityWithoutUrlAlias'], ['io.yuedu.legado.MainJsResultMarshallerTest', 'searchPreservesOriginalCustomGsonStringCoercionsAndSkipsBadObjects'], ['io.yuedu.legado.MainJsResultMarshallerTest', 'sourceBookTypesAndReturnedBitMaskMatchOriginalConstants'], ['io.yuedu.legado.MainJsResultMarshallerTest', 'unrelatedOperationsKeepTheirJsonProtocol'], ['io.yuedu.legado.MainJsScopeTest', 'differentSourcesWithSameJsLibKeepTheirExplicitGlobalsSeparate'], ['io.yuedu.legado.MainJsScopeTest', 'missingNullEmptyAndBlankJsLibKeepExplicitGlobalsInvocationLocal'], ['io.yuedu.legado.MainJsScopeTest', 'nonblankJsLibPreservesExplicitGlobalsWhileCallBindingsRestart'], ['io.yuedu.legado.MainJsScopeTest', 'sourceVariablesLoginCookiesAndCachePersistWithoutJsLib'], ['io.yuedu.legado.OkHttpWireCapabilityProbeTest', 'absoluteDeadlineBoundsBlockedResponseWithoutResettingTask'], ['io.yuedu.legado.OkHttpWireCapabilityProbeTest', 'alreadyCancelledTaskCannotIssueRequestOrLeaveCallsRegistered'], ['io.yuedu.legado.OkHttpWireCapabilityProbeTest', 'arbitraryHostAndOtherPortAreRejectedBeforeAnyWireRequest'], ['io.yuedu.legado.OkHttpWireCapabilityProbeTest', 'cancellationAfterHeadersUnblocksBodyRead'], ['io.yuedu.legado.OkHttpWireCapabilityProbeTest', 'cancellationWhileWaitingForResponseHeadersClosesRealCall'], ['io.yuedu.legado.OkHttpWireCapabilityProbeTest', 'facadeExecutesSevenRealRequestsAndKeepsOuterSessionUntouched'], ['io.yuedu.legado.OkHttpWireCapabilityProbeTest', 'responseDuplicatesAndEachSetCookieSurviveWithoutCommaJoining'], ['io.yuedu.legado.OkHttpWireCapabilityProbeTest', 'unknownFixtureRouteIsFailureAndOwnedResourcesStillClose'], ['io.yuedu.legado.OriginalAnalyzeRuleTest', 'actualElementListsAndNestedJavaRuleCalls'], ['io.yuedu.legado.OriginalAnalyzeRuleTest', 'bookAndChapterLargeVariableBackingIsDistinctAndRetainsOriginalReturnValues'], ['io.yuedu.legado.OriginalAnalyzeRuleTest', 'cacheStringAndByteArrayBackingsRemainIndependentForTheSameKey'], ['io.yuedu.legado.OriginalAnalyzeRuleTest', 'cachedMakeUpRuleReevaluatesCurrentJavaBook'], ['io.yuedu.legado.OriginalAnalyzeRuleTest', 'closedCoordinatorRejectsHostCallsWhileItsSharedEnvironmentRemainsOpen'], ['io.yuedu.legado.OriginalAnalyzeRuleTest', 'closingEnvironmentReleasesSourceCacheAndPreventsFurtherEvaluation'], ['io.yuedu.legado.OriginalAnalyzeRuleTest', 'falseRuleDataWriteDoesNotFallThroughElvisToSource'], ['io.yuedu.legado.OriginalAnalyzeRuleTest', 'hutoolStringBase64OverloadsKeepWhitespaceUrlSafeAndCharsetBehavior'], ['io.yuedu.legado.OriginalAnalyzeRuleTest', 'inlineBlockLibraryExecutesWhileActualMapLibrariesRemainUnsupported'], ['io.yuedu.legado.OriginalAnalyzeRuleTest', 'noLibraryGlobalsAreInvocationLocalWhileInlineLibrarySharesBySource'], ['io.yuedu.legado.OriginalAnalyzeRuleTest', 'originalClassIdentitiesAreRealAndVisibleThroughPackageLookup'], ['io.yuedu.legado.OriginalAnalyzeRuleTest', 'originalCryptoJsResourceAndSecureRandomRemainAvailable'], ['io.yuedu.legado.OriginalAnalyzeRuleTest', 'platformCapabilitiesAreRejectedAndCancelledJobsRemainCancelled'], ['io.yuedu.legado.OriginalAnalyzeRuleTest', 'retainedPublicJsonPathApisMatchAll36OriginalAndroidObservationsAndTypes'], ['io.yuedu.legado.OriginalAnalyzeRuleTest', 'retainedPublicScalarApiMatchesAll28OriginalAndroidObservations'], ['io.yuedu.legado.OriginalAnalyzeRuleTest', 'scalarListAndUrlNormalizationStayInTheOriginalCoordinator'], ['io.yuedu.legado.OriginalAnalyzeRuleTest', 'sourceNamespaceAndCacheMemoryVsBackingAndSeconds'], ['io.yuedu.legado.OriginalAnalyzeRuleTest', 'statePrecedenceAndLocalValuesSurviveSetContent'], ['io.yuedu.legado.OriginalRuleScopesConcurrencyTest', 'alreadyCancelledJobCannotInitializeAnUncachedLibraryOrConsumeACachedScope'], ['io.yuedu.legado.OriginalRuleScopesConcurrencyTest', 'cancellationAndCloseNotifyAWaiterAlreadyParkedOnItsCreationCondition'], ['io.yuedu.legado.OriginalRuleScopesConcurrencyTest', 'cancelledLibraryInitializationReleasesItsKeyAndDoesNotCachePartialScope'], ['io.yuedu.legado.OriginalRuleScopesConcurrencyTest', 'cancellingSameLibraryWaiterDoesNotWaitForOrCancelItsInitializer'], ['io.yuedu.legado.OriginalRuleScopesConcurrencyTest', 'closingEnvironmentDoesNotWaitForOrPublishAnInFlightLibrary'], ['io.yuedu.legado.OriginalRuleScopesConcurrencyTest', 'closingEnvironmentReleasesSameLibraryWaiterBeforeItsInitializerReturns'], ['io.yuedu.legado.OriginalRuleScopesConcurrencyTest', 'concurrentCallersInitializeTheSameLibraryOnce'], ['io.yuedu.legado.OriginalRuleScopesConcurrencyTest', 'concurrentInvocationBindingsAndSourceGlobalsRemainIsolatedWithinAndAcrossEnvironments'], ['io.yuedu.legado.OriginalRuleScopesConcurrencyTest', 'noLibraryCryptoScopeDoesNotWaitForABlockedLibrary'], ['io.yuedu.legado.OriginalRuleScopesConcurrencyTest', 'sameThreadReentrantLibraryRemovalRetainsTheOriginalMonitorContract'], ['io.yuedu.legado.OriginalRuleScopesConcurrencyTest', 'unrelatedLibraryInitializationDoesNotWaitForABlockedLibrary'], ['io.yuedu.legado.ProductionHttpTransportTest', 'automaticLoginHeaderStaysOnItsSiteAndExplicitOverrideStillWorks'], ['io.yuedu.legado.ProductionHttpTransportTest', 'cancellationAfterHeadersAndCloseSessionUnblockBodyWithoutClearingLiveStateEarly'], ['io.yuedu.legado.ProductionHttpTransportTest', 'connectReturnsRealJvmHeadersAndRawResponseMetadataWithoutLosingDuplicates'], ['io.yuedu.legado.ProductionHttpTransportTest', 'delayedDeadlineSchedulerCannotTurnAnIOExceptionIntoSuccessfulStackText'], ['io.yuedu.legado.ProductionHttpTransportTest', 'expiredAbsoluteDeadlineCannotBecomeSuccessfulNetworkErrorText'], ['io.yuedu.legado.ProductionHttpTransportTest', 'explicitSessionOptionsDoNotPolluteSourceAndUnsupportedHostsOrUrlOptionsFailBeforeNetwork'], ['io.yuedu.legado.ProductionHttpTransportTest', 'legacyConstructorKeepsItsExplicitPlatformInjectionPath'], ['io.yuedu.legado.ProductionHttpTransportTest', 'mainJsFullReadingChainUsesProductionClientAndPreservesOrderedWireHeaders'], ['io.yuedu.legado.ProductionHttpTransportTest', 'redirectCookiesAreSavedAtEachHopAndRespectPathAndDisabledJar'], ['io.yuedu.legado.ProductionHttpTransportTest', 'responseCharsetUsesHeaderThenHtmlMetaThenOriginalDetectorAndRemovesUtf8Bom'], ['io.yuedu.legado.ProductionHttpTransportTest', 'statusRetryAndEarlyCancellationUseOrdinaryFacadeWithoutNativeHost'], ['io.yuedu.legado.ProductionHttpTransportTest', 'transparentGzipDeflateAndBrotliAreDecodedButAuthoredEncodingOptsOut'], ['io.yuedu.legado.RuntimeTaskTraceTest', 'concurrentCancelAndReadEventsKeepWholeOrderedLines'], ['io.yuedu.legado.RuntimeTaskTraceTest', 'eventAndByteLimitsNeverLeavePartialJsonLines'], ['io.yuedu.legado.RuntimeTaskTraceTest', 'redactsArbitraryTaskStringsAndKeepsOnlyFixedSchema'], ['io.yuedu.legado.RuntimeTaskTraceTest', 'refusesExistingFilesAndUnapprovedNamesOrDirectories'], ['io.yuedu.legado.SourceHttpSemanticsTest', 'absentMediaTypeUsesOriginalFormEncodingAndCharsetRules'], ['io.yuedu.legado.SourceHttpSemanticsTest', 'bridgeHostAndGzipDefaultsRespectExplicitOverridesAndRange'], ['io.yuedu.legado.SourceHttpSemanticsTest', 'bridgeReplacesAllCaseVariantsAndTransferEncodingAfterBodySelection'], ['io.yuedu.legado.SourceHttpSemanticsTest', 'declaredMediaCharsetControlsBytesAndRetainsExactContentType'], ['io.yuedu.legado.SourceHttpSemanticsTest', 'formStringBodySelectsUtf8AndReplacesContentTypeInActualHostRequest'], ['io.yuedu.legado.SourceHttpSemanticsTest', 'nullUserAgentSentinelAndHeaderValidationMatchBuilderBoundary'], ['io.yuedu.legado.SourceHttpSemanticsTest', 'originalCommonInterceptorAppendsRatherThanOverwritingAuthoredHeaders'], ['io.yuedu.legado.SourceHttpSemanticsTest', 'structuredOrEmptyPostUsesOriginalBodySelection'], ['io.yuedu.legado.SourceHttpSemanticsTest', 'unsupportedMediaCharsetUsesOkHttpUtf8AppendBehavior'], ['io.yuedu.legado.StaticRuleReplacementTest', 'emptyPatternIsOnlyTheReplacementKernelIdentity'], ['io.yuedu.legado.StaticRuleReplacementTest', 'malformedReplacementDoesNotEscapeAsExceptionButKeepsOriginalLiteralFallback'], ['io.yuedu.legado.StaticRuleReplacementTest', 'parseUsesPlainDelimiterAndOnlyFourthSegmentPresenceForExtractFirst'], ['io.yuedu.legado.StaticRuleReplacementTest', 'sharedFixtureExercisesPinnedReplacementBranchesWithoutAndroidOutputInvented'], ['io.yuedu.legado.StaticRuleReplacementTest', 'staticSliceRejectsSelectorsAndRuntimeExpressionsExplicitly'], ['io.yuedu.legado.StaticScalarSelectorRuleTest', 'bothScalarOverloadsMatchAll28UnmodifiedOriginalAndroidObservations'], ['io.yuedu.legado.StaticScalarSelectorRuleTest', 'dynamicImplicitRegexCaptureAndEmptyRulesAreExplicitlyUnsupported'], ['io.yuedu.legado.StaticScalarSelectorRuleTest', 'explicitCssModeRetainsComplexSelectorsAndAtSignsInsideAttributes'], ['io.yuedu.legado.StaticScalarSelectorRuleTest', 'malformedJsonConstructionDoesNotBecomeAMissingValueReplacement'], ['io.yuedu.legado.StaticScalarSelectorRuleTest', 'nonStringJsonAndNonNodeHtmlContextsDoNotCoerceToStrings'], ['io.yuedu.legado.StaticScalarSelectorRuleTest', 'replacementCaptureReferencesRemainAllowedAndSelectedWhitespaceIsUntouched'], ['io.yuedu.legado.TlsCapabilityProbeTest', 'cancelledTaskCannotStartTLSWork'], ['io.yuedu.legado.TlsCapabilityProbeTest', 'expiredDeadlineCannotStartTLSWork'], ['io.yuedu.legado.TlsCapabilityProbeTest', 'realLoopbackTlsValidatesBothProtocolsTrustAndHostAndStopsWorkers']]}
 expected_suites={row[0] for row in expected_cases}
 assert len(xmls)==len(expected_suites) and len(cases)==len(expected_cases)
 assert len(set(cases))==len(cases) and set(cases)==expected_cases
 assert {row['name'] for row in suites}==expected_suites
 result['ordinaryJVMTests']={'xmlFiles':len(xmls),'uniqueCases':len(cases),'failures':0,'errors':0,'skips':0,'suites':suites,'meaning':'Actual XML records exactly match the declared methods in the bound Git source; not iOS or compatibility acceptance.'}
 result['passed']=True
except Exception as e:result['issues'].append(type(e).__name__+': '+str(e))
a.output.parent.mkdir(parents=True,exist_ok=True)
with a.output.open('x',encoding='utf-8',newline='\n') as stream:
 json.dump(result,stream,indent=2,ensure_ascii=False);stream.write('\n')
print(json.dumps({'passed':result['passed'],'issues':result['issues'],'output':str(a.output)}))
raise SystemExit(0 if result['passed'] else 1)
