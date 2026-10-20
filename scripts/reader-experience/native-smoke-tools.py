#!/usr/bin/env python3
"""Bind independent actual native main-app reading groups to source and payload."""
import argparse
import hashlib
import importlib.util
import json
import os
import re
from pathlib import Path
import signal
import subprocess
import sys
import time


HERE = Path(__file__).resolve().parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


smoke = load("native_reader_smoke", HERE / "smoke-tools.py")
packaging = load("native_reader_packaging", HERE / "runtime-packaging.py")

NATIVE_GROUPS = {
    "mainjs": {"stem": "native-product-chain", "summary": "summary.json", "tests": "native-tests.json", "seconds": 2700,
        "methods": ("LegadoNativeMainJSReaderTests/testNativeMainJSProductReadingChain",)},
    "original": {"stem": "original-product-chain", "summary": "original-summary.json", "tests": "original-tests.json", "seconds": 1800,
        "methods": ("LegadoNativeOriginalReaderTests/testNativeOriginalWebBookPreviewTransferAndReopen",
            "LegadoNativeOriginalReaderTests/testNativeOriginalBookNotificationsUseActualStateAndKeepCacheIdentity",
            "LegadoNativeOriginalReaderTests/testNativeOriginalBookNotificationCancellationDrains",
            "LegadoNativeOriginalReaderTests/testNativeOriginalPublicConsumersUseOwnedReaderAndOfflineReopen",
            "LegadoNativeOriginalReaderTests/testNativeOriginalPublicReaderCancellationDrainsWithoutCache",
            "LegadoNativeOriginalReaderTests/testNativeOriginalExplorePauseUsesEveryOpenedSourceAndRealCacheOwner",
            "LegadoNativeOriginalReaderTests/testNativeOriginalBatchUsesRealGrantsArtifactsAndMissingIdentities",
            "LegadoNativeOriginalReaderTests/testNativeOriginalBatchCancellationDrainsAndPreservesSavedPrefix",
            "LegadoNativeOriginalReaderTests/testNativeOriginalShelfRefreshUsesNullEntitiesAndSameSourceOwners",
            "LegadoNativeOriginalReaderTests/testNativeOriginalShelfRefreshCancellationDrainsWithoutBookAuthority",
            "LegadoNativeOriginalLoginInfoTests/testNativeOriginalLoginInfoUsesExistingKeychainAndReopens",
            "LegadoNativeOriginalLoginInfoTests/testNativeOriginalLoginInfoCancellationRetainsAcceptedKeychainEffect",
            "LegadoNativeOriginalLoginInfoTests/testNativeOriginalLoginInfoMapDefaultsUseExistingKeychainAndReopen",
            "LegadoNativeOriginalLoginInfoTests/testNativeOriginalFormSubmissionUsesProductSourceServiceAndExistingOwners",
            'LegadoNativeOriginalLoginInfoTests/testNativeOriginalLoginUIUsesProductSourceServiceAndStoredMap',
            'LegadoNativeOriginalReaderTests/testNativeOriginalCachedExplorePageOpensAndSavesOnLeave',
            'LegadoNativeOriginalLoginInfoTests/testNativeOriginalRowActionUsesProductServiceWithoutImplicitCredentialWrite',
            'LegadoNativeOriginalLoginInfoTests/testNativeOriginalLoginUIEventsReachExistingFormProjectionAfterServiceGateRelease',
            'LegadoNativeOriginalLoginInfoTests/testNativeOriginalDismissPersistenceUsesCheckedOwnerWithoutExecutingLoginJS',
            'LegadoNativeOriginalLoginInfoTests/testNativeOriginalDeltaLoginUIReusesPhysicalControlsThroughProductServiceWithoutCredentialWrite',
            'LegadoNativeOriginalLoginInfoTests/testNativeOriginalLoginV2UsesProductRhinoAndCheckedLoginBeforeClose')},
}
SOURCE_INPUTS = (
    ".github/workflows/legado-native-reader-test.yml", "scripts/reader-experience/native-smoke-tools.py",
    "scripts/reader-experience/test-native-smoke-tools.py", "scripts/reader-experience/smoke-tools.py",
    "scripts/reader-experience/stage-config.py", "scripts/reader-experience/runtime-packaging.py",
    "scripts/reader-experience/runtime-notices.py", "scripts/xctest.sh", "scripts/sim.sh",
    "scripts/legado-ios/runtime-lock.json", "scripts/legado-ios/stage-runtime.py",
    "scripts/legado-ios/verify-native-exports.py", "scripts/legado-ios/verify-runtime.py",
    "Tests/iOS/LegadoNativeMainJSReaderTests.swift", "Tests/iOS/LegadoNativeOriginalReaderTests.swift",
    "Packages/LegadoRuntime/Package.swift", "Packages/LegadoRuntime/Sources/CLegadoJNI/LegadoJNI.m",
    "Packages/LegadoRuntime/Sources/CLegadoJNI/include/LegadoJNI.h",
    "Packages/LegadoRuntime/Sources/LegadoRuntime/NativeLegadoTransport.swift",
    "Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoRuntime.swift",
    "Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoPlatformHost.swift",
    "Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoOriginalModels.swift",
    "Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/LegadoRuntime.kt",
    "Packages/LegadoRuntime/vendor/original-rule/manifest.json",
    "Modules/Services/Online/LegadoMainJSSourceService.swift",
    "Modules/Services/Online/LegadoContentBatchOwner.swift", "Modules/Services/Online/LegadoPersistentStateHost.swift",
    "Modules/Services/Online/LegadoPreviewStateOwner.swift", "Modules/Services/Online/LegadoBookStateOwner.swift",
    "Modules/Services/Online/OnlineReadingPipeline.swift", "Modules/Services/Online/ChapterCacheRepository.swift",
    "Modules/Services/LibraryStore/BookStore.swift", "Modules/Services/LibraryStore/OriginalRuntimeCommitCancellation.swift",
)


# Exact production consumers for public original reading and all-source pause.
ORIGINAL_CONSUMER_SOURCE_INPUTS = ('Modules/Core/BookSource/BookSourceFetcher+Search.swift',
 'Modules/Core/BookSource/BookSourceFetcher+BookInfo.swift',
 'Modules/Core/BookSource/BookSourceFetcher+TOC.swift',
 'Modules/Core/BookSource/BookSourceFetcher+Chapter.swift',
 'Modules/Services/Online/OnlineReadingPipeline.swift',
 'Modules/Services/Online/LegadoMainJSSourceService.swift',
 'Modules/Services/LibraryStore/BookChapterStore.swift',
 'Modules/Services/LibraryStore/BookStore.swift',
 'Modules/Services/Online/LegadoBookStateOwner.swift',
 'Modules/Services/Online/LegadoContentBatchOwner.swift',
 'Modules/Services/Online/LegadoPersistentStateHost.swift',
 'Modules/Core/BookSource/BookSourceFetcher+Discover.swift',
 'Modules/Services/Online/DiscoverQuickActions.swift',
 'Modules/Features/BookDetail/OnlineBookView.swift',
 'Modules/Core/BookSource/BookSourceFetcher+OriginalPreview.swift',
 'Tests/iOS/LegadoNativeOriginalReaderTests.swift',
 'Targets/Yuedu/SharedApp/AppDependencies.swift',
 'Modules/Core/BookSource/BookSourceFetcher.swift',
 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalTraditionalRuntime.kt',
 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/OriginalExploreContexts.kt',
 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/ProductionRulePlatform.kt')
SOURCE_INPUTS += tuple(path for path in ORIGINAL_CONSUMER_SOURCE_INPUTS if path not in SOURCE_INPUTS)
ORIGINAL_CALLBACK_SOURCE_INPUTS = ('Modules/Core/TTS/AudiobookPlayer.swift',
 'Modules/Features/BookDetail/AudiobookDetailView.swift',
 'Modules/Features/BookDetail/OnlineBookView.swift',
 'Modules/Features/Reader/ReaderView+SourceCallBack.swift',
 'Modules/Features/Reader/ReaderView.swift',
 'Modules/Features/Reader/TTS/AudiobookView.swift',
 'Modules/Services/LibraryStore/BookStore.swift',
 'Modules/Services/Online/LegadoBookStateOwner.swift',
 'Modules/Services/Online/LegadoMainJSSourceService.swift',
 'Modules/Services/Online/LegadoPersistentStateHost.swift',
 'Modules/Services/Online/LegadoPreviewStateOwner.swift',
 'Modules/Services/Online/LegadoReviewActionRunner.swift',
 'Modules/Services/Online/SourceCallBackService.swift',
 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/data/entities/RuleModels.kt',
 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalRuleDto.kt',
 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalTraditionalRuntime.kt',
 'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoOriginalModels.swift',
 'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoRuntime.swift',
 'Tests/iOS/LegadoNativeOriginalReaderTests.swift',
 'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalBookCallbackTest.kt')
SOURCE_INPUTS += tuple(path for path in ORIGINAL_CALLBACK_SOURCE_INPUTS if path not in SOURCE_INPUTS)
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 57
ORIGINAL_SOURCE_STATE_INPUTS = ('Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoOriginalModels.swift', 'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoRuntime.swift', 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalTraditionalRuntime.kt', 'Modules/Services/Online/LegadoPreviewStateOwner.swift', 'Modules/Services/Online/LegadoMainJSSourceService.swift', 'Modules/Services/Online/LegadoPersistentStateHost.swift', 'Modules/Services/Online/SourceCallBackService.swift', 'Tests/iOS/yuedu appTests/LegadoPreviewStateOwnerTests.swift', 'Tests/iOS/LegadoNativeOriginalReaderTests.swift', 'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceCallbackTest.kt', 'Packages/LegadoRuntime/vendor/original-rule/manifest.json', 'Modules/Core/RuleEngine/ModernParser/Login/KeychainHelper.swift', 'Modules/Core/RuleEngine/ModernParser/Login/LoginManager.swift', 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/data/entities/RuleModels.kt', 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/ProductionRulePlatform.kt', 'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RulePlatform.kt', 'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginInfoTest.kt', 'Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift', 'Tests/iOS/yuedu appTests/LegadoCookieOwnerTests.swift', 'Tests/iOS/yuedu appTests/LegadoPersistentStateHostTests.swift')
SOURCE_INPUTS += tuple(path for path in ORIGINAL_SOURCE_STATE_INPUTS if path not in SOURCE_INPUTS)
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 66
ORIGINAL_LOGIN_MAP_INPUTS = (
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/data/entities/BaseSource.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/data/entities/rule/FlexChildStyle.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/data/entities/rule/RowUi.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/data/entities/RuleModels.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/OriginalWebBookSession.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/LockedLoginMapReference.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginMapTest.kt',
    'Packages/LegadoRuntime/vendor/original-rule/manifest.json',
    'Packages/LegadoRuntime/vendor/original-rule/sources/data/entities/rule/FlexChildStyle.kt',
    'Packages/LegadoRuntime/vendor/original-rule/sources/data/entities/rule/RowUi.kt',
    'Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift',
)
SOURCE_INPUTS += tuple(path for path in ORIGINAL_LOGIN_MAP_INPUTS if path not in SOURCE_INPUTS)
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 74
# These retained App test files also compile in the required Native host.
NATIVE_CORETEXT_COMPILE_INPUTS = (
    'Tests/iOS/yuedu appTests/ReadingPositionStorePersistenceTests.swift',
    'Tests/iOS/yuedu appTests/ReadingPositionWriteOrderingTests.swift',
    'Tests/iOS/yuedu appTests/CoreTextPagedScrollAppearanceTests.swift',
    'Tests/iOS/yuedu appTests/SelfRenewalAppExecutionTests.swift',
    'Tests/iOS/yuedu appTests/SelfRenewalAppOwnerTests.swift',
    'Tests/iOS/yuedu appTests/SelfRenewalUserDataHandoffTests.swift',
)
SOURCE_INPUTS += NATIVE_CORETEXT_COMPILE_INPUTS
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 80
ORIGINAL_LOGIN_ACTION_MATERIAL_INPUTS = (
    'Modules/Services/SelfRenewal/SelfRenewalAppSession.swift',
    'Modules/Services/SelfRenewal/SelfRenewalAppOwner.swift',
    'Tests/iOS/yuedu appTests/SelfRenewalAccountSessionTests.swift',
    'Tests/iOS/yuedu appTests/SelfRenewalDeveloperAccountClientTests.swift',
    'Modules/Features/BookSource/BookSourceFormLoginView.swift',
    'Modules/Services/Online/LegadoMainJSSourceService.swift',
    'Modules/Services/Online/LegadoPreviewStateOwner.swift',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/data/entities/RuleModels.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/model/analyzeRule/AnalyzeRule.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/model/analyzeRule/AnalyzeUrl.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/LegadoRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/OriginalSourceLoginHost.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/ProductionRulePlatform.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RuleCompat.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RulePlatform.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalTraditionalRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceFormLoginTest.kt',
    'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoOriginalModels.swift',
    'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoRuntime.swift',
    'Packages/LegadoRuntime/vendor/original-rule/manifest.json',
    'Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift',
    'Tests/iOS/yuedu appTests/BookSourceLoginTests.swift',
    'Tests/iOS/yuedu appTests/LegadoPreviewStateOwnerTests.swift',
)
SOURCE_INPUTS += tuple(path for path in ORIGINAL_LOGIN_ACTION_MATERIAL_INPUTS if path not in SOURCE_INPUTS)
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 91
ORIGINAL_LOGIN_UI_EXPLORE_INPUTS = (
    'Modules/Core/RuleEngine/ModernParser/Login/LoginFieldStyle.swift',
    'Modules/Core/RuleEngine/ModernParser/Login/LoginManager.swift',
    'Modules/Features/BookSource/BookSourceFormLoginView.swift',
    'Modules/Services/Online/LegadoMainJSSourceService.swift',
    'Modules/Services/Online/LegadoOriginalLoginUIForm.swift',
    'Modules/Services/Online/LegadoPreviewStateOwner.swift',
    'Modules/SharedUI/Components/LoginFormGrid.swift',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/data/entities/RuleModels.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/LegadoRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalLoginUIRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalTraditionalRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginUITest.kt',
    'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoOriginalModels.swift',
    'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoRuntime.swift',
    'Packages/LegadoRuntime/vendor/original-rule/manifest.json',
    'Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift',
    'Tests/iOS/yuedu appTests/BookSourceLoginTests.swift',
    'Tests/iOS/yuedu appTests/LegadoPreviewStateOwnerTests.swift',
    'Modules/Services/Online/DiscoverViewModel.swift',
    'Modules/Services/Online/DiscoverQuickActions.swift',
    'Modules/Features/Explore/ExploreSourcePage.swift',
    'Tests/iOS/yuedu appTests/DiscoverViewModelReloadTests.swift',
    'Tests/iOS/yuedu appTests/LegadoOriginalExploreLifecycleTests.swift',
    'Tests/iOS/LegadoNativeOriginalReaderTests.swift',
    'Modules/Services/Online/DiscoverKindsCache.swift',
    'Modules/Services/Online/ExploreSettings.swift',
    'Modules/Services/LibraryStore/BackgroundTaskHold.swift',
)
SOURCE_INPUTS += tuple(path for path in ORIGINAL_LOGIN_UI_EXPLORE_INPUTS if path not in SOURCE_INPUTS)
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 103
# These test files actually failed the prior Native target compilation.
NATIVE_F2_TEST_COMPILE_INPUTS = ('Tests/iOS/yuedu appTests/SelfRenewalDeveloperAuthenticationTests.swift', 'Tests/iOS/yuedu appTests/SelfRenewalAutomaticRenewalTests.swift')
SOURCE_INPUTS += tuple(path for path in NATIVE_F2_TEST_COMPILE_INPUTS if path not in SOURCE_INPUTS)
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 105
ORIGINAL_ROW_ACTION_INPUTS = (
    'Modules/Features/BookSource/BookSourceFormLoginView.swift',
    'Modules/Services/Online/LegadoMainJSSourceService.swift',
    'Modules/Services/Online/LegadoPreviewStateOwner.swift',
    'Modules/SharedUI/Components/LoginFormGrid.swift',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/LegadoRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalLoginActionRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalTraditionalRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginActionTest.kt',
    'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoOriginalModels.swift',
    'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoRuntime.swift',
    'Packages/LegadoRuntime/vendor/original-rule/manifest.json',
    'Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift',
    'Tests/iOS/yuedu appTests/LegadoPreviewStateOwnerTests.swift',
)
SOURCE_INPUTS += tuple(path for path in ORIGINAL_ROW_ACTION_INPUTS if path not in SOURCE_INPUTS)
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 107
LOGIN_EVENTS_DISMISS_LIFECYCLE_INPUTS = (
    'Modules/Features/BookSource/BookSourceFormLoginView.swift',
    'Modules/Services/Online/LegadoMainJSSourceService.swift',
    'Modules/Services/Online/LegadoOriginalLoginUIForm.swift',
    'Modules/Services/Online/LegadoPreviewStateOwner.swift',
    'Modules/Services/SelfRenewal/SelfRenewalAppOwner.swift',
    'Modules/Services/SelfRenewal/SelfRenewalBackgroundTaskBridge.swift',
    'Modules/SharedUI/Components/LoginFormGrid.swift',
    'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoOriginalModels.swift',
    'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoRuntime.swift',
    'Packages/LegadoRuntime/Tests/LegadoRuntimeTests/LegadoOriginalAPITests.swift',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/LegadoRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalLoginUIRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalTraditionalRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/OriginalSourceLoginHost.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/ProductionRulePlatform.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RulePlatform.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginActionTest.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginUIEventsTest.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginUITest.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourcePersistLoginInfoTest.kt',
    'Packages/LegadoRuntime/vendor/original-rule/manifest.json',
    'Targets/Yuedu/SharedApp/yuedu_appApp.swift',
    'Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift',
    'Tests/iOS/yuedu appTests/BookSourceLoginTests.swift',
    'Tests/iOS/yuedu appTests/LegadoPreviewStateOwnerTests.swift',
    'Tests/iOS/yuedu appTests/SelfRenewalAppExecutionTests.swift',
    'Tests/iOS/yuedu appTests/SelfRenewalAppOwnerTests.swift',
    'Tests/iOS/yuedu appTests/SelfRenewalAutomaticRenewalTests.swift',
    'Tests/iOS/yuedu appTests/SelfRenewalForegroundMaterialRevalidationTests.swift',
)
SOURCE_INPUTS += tuple(path for path in LOGIN_EVENTS_DISMISS_LIFECYCLE_INPUTS if path not in SOURCE_INPUTS)
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 113
DELTA_REUSE_INPUTS = (
    'Modules/Features/BookSource/BookSourceFormLoginView.swift',
    'Modules/Services/Online/LegadoMainJSSourceService.swift',
    'Modules/Services/Online/LegadoOriginalLoginUIForm.swift',
    'Modules/Services/Online/LegadoPreviewStateOwner.swift',
    'Modules/SharedUI/Components/LoginFormGrid.swift',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalLoginActionRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalLoginUIReuse.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalLoginUIRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/ProductionRulePlatform.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalTraditionalRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginActionTest.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginDeltaTest.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginUIEventsTest.kt',
    'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoOriginalModels.swift',
    'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoRuntime.swift',
    'Packages/LegadoRuntime/Tests/LegadoRuntimeTests/LegadoOriginalAPITests.swift',
    'Packages/LegadoRuntime/vendor/original-rule/manifest.json',
    'Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift',
    'Tests/iOS/yuedu appTests/BookSourceLoginTests.swift',
)
SOURCE_INPUTS += tuple(path for path in DELTA_REUSE_INPUTS if path not in SOURCE_INPUTS)
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 115

# The existing local-product verifier reads seven suites in eight source files.
# Keep those files, including the font transaction extension, in both Native
# command/source ledgers together with the two cache suites checked below.
LOCAL_PRODUCT_CACHE_INPUTS = (
    'Tests/iOS/yuedu appTests/ReaderLocalProductTests.swift',
    'Tests/iOS/yuedu appTests/ReaderFontCatalogTests.swift',
    'Tests/iOS/yuedu appTests/CachedBookTXTExportTests.swift',
    'Tests/iOS/yuedu appTests/UserFontSettingsTests.swift',
    'Tests/iOS/yuedu appTests/UserFontTransactionTests.swift',
    'Tests/iOS/yuedu appTests/SubscriptionPublicationTests.swift',
    'Tests/iOS/yuedu appTests/PublicLibraryAvailabilityTests.swift',
    'Tests/iOS/yuedu appTests/RemoteLibraryHTTPTests.swift',
    'Tests/iOS/yuedu appTests/ChapterCacheMigrationTests.swift',
    'Tests/iOS/yuedu appTests/ChapterCacheRepositoryWriteTests.swift',
)
SOURCE_INPUTS += tuple(path for path in LOCAL_PRODUCT_CACHE_INPUTS if path not in SOURCE_INPUTS)
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 125
LOGIN_V2_NATIVE_REPAIR_INPUTS = (
    'Modules/Features/BookSource/BookSourceFormLoginView.swift',
    'Modules/Services/Online/LegadoMainJSSourceService.swift',
    'Modules/Services/Online/LegadoOriginalLoginUIForm.swift',
    'Modules/Services/Online/LegadoPreviewStateOwner.swift',
    'Modules/SharedUI/Components/LoginFormGrid.swift',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/data/entities/RuleModels.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/legado/app/model/login/LoginUiV2.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/LegadoRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalLoginUIRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalLoginV2Runtime.kt',
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/OriginalTraditionalRuntime.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginUITest.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalSourceLoginV2Test.kt',
    'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoOriginalLoginV2Models.swift',
    'Packages/LegadoRuntime/Sources/LegadoRuntime/LegadoRuntime.swift',
    'Packages/LegadoRuntime/Tests/LegadoRuntimeTests/LegadoOriginalAPITests.swift',
    'Packages/LegadoRuntime/vendor/original-rule/manifest.json',
    'Tests/iOS/LegadoNativeOriginalLoginInfoTests.swift',
    'Tests/iOS/yuedu appTests/BookSourceLoginTests.swift',
    'Tests/iOS/yuedu appTests/LegadoPreviewStateOwnerTests.swift',
    'Modules/Core/RuleEngine/ModernParser/Login/LoginManager.swift',
)
SOURCE_INPUTS += tuple(path for path in LOGIN_V2_NATIVE_REPAIR_INPUTS if path not in SOURCE_INPUTS)
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 129
NATIVE_READER_REPAIR_INPUTS = (
    'Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/originalrule/RuleWebBookState.kt',
    'Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/OriginalWebBookExecutionTest.kt',
    'Packages/LegadoRuntime/vendor/original-rule/manifest.json',
    'Tests/iOS/LegadoNativeOriginalReaderTests.swift',
)
SOURCE_INPUTS += tuple(path for path in NATIVE_READER_REPAIR_INPUTS if path not in SOURCE_INPUTS)
assert len(SOURCE_INPUTS) == len(set(SOURCE_INPUTS)) == 131

CACHE_CASES = {
    'ChapterCacheMigrationTests': ('packageLoaderUpgradesDownloadedLegacyChapter()',
        'corruptLegacyBodyDoesNotRewriteStoredChecksum(hasCachedState:)',
        'legacyBodyWithoutChecksumRemainsUpgradeable(hasCachedState:)'),
    'ChapterCacheRepositoryWriteTests': ('emptyContentRejected()', 'bodyFailurePropagates()', 'writeIsReloadable()'),
}
CACHE_EXECUTIONS = {suite + '/' + method: (2 if 'hasCachedState:' in method else 1)
    for suite, methods in CACHE_CASES.items() for method in methods}


def cache_source_inputs(repo=None):
    """Fail closed on changes to these six declarations and two Bool matrices."""
    repo = smoke.REPO if repo is None else Path(repo)
    pattern = re.compile(r'^[ \t]*@Test(?:\(([^\r\n]*)\))?\s+func (\w+)\(([^)]*)\)', re.MULTILINE)
    records = []
    for suite, expected in CACHE_CASES.items():
        relative = 'Tests/iOS/yuedu appTests/' + suite + '.swift'
        data = (repo / relative).read_bytes(); text = data.decode('utf-8-sig')
        if (re.search(r'\bstruct\s+' + re.escape(suite) + r'\b', text) is None
                or re.search(r'@Suite\([^\r\n]*\.serialized[^\r\n]*\)', text) is None):
            raise ValueError('Selected cache suite is missing or not serialized: ' + suite)
        declarations = pattern.findall(text)
        if len(declarations) != len(re.findall(r'^[ \t]*@Test\b', text, re.MULTILINE)):
            raise ValueError('Unsupported selected cache declaration: ' + relative)
        actual = []
        for attributes, name, parameters in declarations:
            normalized = re.sub(r'\s+', '', parameters)
            if normalized:
                if normalized != 'hasCachedState:Bool' or 'arguments:' not in attributes:
                    raise ValueError('Unexpected cache parameter signature: ' + name)
                arguments = json.loads(attributes.split('arguments:', 1)[1].strip())
                if arguments != [False, True] or any(type(value) is not bool for value in arguments):
                    raise ValueError('Cache Bool arguments differ from false/true: ' + name)
                method = name + '(hasCachedState:)'
            else:
                if 'arguments:' in attributes:
                    raise ValueError('Unexpected cache arguments: ' + name)
                method = name + '()'
            actual.append(method)
        if len(actual) != len(set(actual)) or set(actual) != set(expected):
            raise ValueError('Selected cache source identities differ: ' + suite)
        records.append({'path': relative, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
    return {'methodCount': 6, 'plannedExecutionCount': 8, 'sourceInputs': records}


def verify_cache(summary, tests, repo=None):
    counts = smoke.verify_summary(summary, 6, 8)
    sources = cache_source_inputs(repo)
    if not isinstance(tests, dict) or not isinstance(tests.get('testNodes'), list):
        raise ValueError('Cache gate requires xcresult testNodes')
    found = {}
    def visit(node):
        if not isinstance(node, dict) or not isinstance(node.get('children', []), list):
            raise ValueError('Malformed cache test node')
        kind, children = node.get('nodeType'), node.get('children', [])
        if kind == 'Test Case':
            identifier = node.get('nodeIdentifier')
            if not isinstance(identifier, str): raise ValueError('Cache case lacks source identity')
            identity = identifier.removeprefix('yuedu appTests/')
            expected = CACHE_EXECUTIONS.get(identity)
            if expected is None or identity in found or node.get('result') != 'Passed':
                raise ValueError('Unexpected, duplicate, failed or skipped cache case: ' + identifier)
            if expected == 1:
                if children: raise ValueError('Unexpected cache execution children: ' + identity)
            else:
                names = []
                for child in children:
                    if (not isinstance(child, dict) or child.get('nodeType') != 'Arguments'
                            or child.get('result') != 'Passed' or child.get('children', []) != []
                            or not isinstance(child.get('name'), str)):
                        raise ValueError('Malformed, failed or skipped cache Bool execution: ' + identity)
                    names.append(child['name'])
                if len(names) != 2 or set(names) != {'false', 'true'}:
                    raise ValueError('Missing, duplicate or changed cache Bool execution: ' + identity)
            found[identity] = expected
            return
        if kind not in ('Test Plan', 'Unit test bundle', 'Test Suite') or node.get('result', 'Passed') != 'Passed':
            raise ValueError('Unexpected, failed or skipped cache container')
        for child in children: visit(child)
    for node in tests['testNodes']: visit(node)
    if found != CACHE_EXECUTIONS: raise ValueError('Cache source case selection differs from six methods/eight executions')
    return {**counts, 'passedExecutionsByMethod': dict(sorted(found.items())), 'sourceMethodInventory': sources}


def _fact(path):
    path = smoke.config.checked_path(path)
    if not path.is_file() or path.is_symlink():
        raise ValueError("Native evidence must be a regular owned file")
    return {"bytes": path.stat().st_size, "sha256": smoke.config.digest(path)}


def source_inputs():
    records = []
    for relative in SOURCE_INPUTS:
        path = smoke.config.checked_path(smoke.REPO / relative)
        if path.read_bytes() != smoke.git("show", "HEAD:" + relative, binary=True):
            raise ValueError("Native input differs from tracked HEAD: " + relative)
        records.append({"path": relative, **_fact(path)})
    return records


def _source_state(work):
    if "LEGADO_RUNTIME_SOURCE_ONLY" in os.environ:
        raise ValueError("Actual native groups require LEGADO_RUNTIME_SOURCE_ONLY to be unset")
    source = validate_tag()
    smoke.review_overlays(smoke.read_json(work / "overlays.json"))
    prepared = smoke.read_json(work / "native-source-inputs.json")
    if prepared != {"sourceCommit": source, "sourceInputs": source_inputs()}:
        raise ValueError("Native reading source closure changed after preparation")
    return prepared


def verify_cases(tree, group):
    if group not in NATIVE_GROUPS or not isinstance(tree, dict) or not isinstance(tree.get("testNodes"), list):
        raise ValueError("Expected the selected native group's original xcresult tests tree")
    found = []
    visited = 0
    def visit(node, depth=0):
        nonlocal visited
        visited += 1
        if not isinstance(node, dict) or depth > 64 or visited > 10000:
            raise ValueError("Malformed or oversized native tests tree")
        kind = node.get("nodeType")
        if kind in ("Arguments", "Repetition"):
            raise ValueError("Arguments or retries cannot replace one native method execution")
        if kind in ("Test Case", "Test Case Run") and node.get("result") != "Passed":
            raise ValueError("Skipped, failed or incomplete native method")
        if kind == "Test Case":
            identifier = node.get("nodeIdentifier")
            if not isinstance(identifier, str) or len(identifier) > 4096:
                raise ValueError("Native methods require actual qualified identities")
            parts = identifier.removesuffix("()").split("/")
            if len(parts) not in (2, 3) or (len(parts) == 3 and parts[0] != "yuedu appTests"):
                raise ValueError("Unexpected native method target")
            found.append("/".join(parts[-2:]))
            runs = []; pending = list(node.get("children", []))
            while pending:
                child = pending.pop()
                if not isinstance(child, dict):
                    raise ValueError("Malformed native execution node")
                if child.get("nodeType") == "Test Case Run": runs.append(child)
                pending.extend(child.get("children", []))
            if len(runs) > 1:
                raise ValueError("Duplicate actual native method executions")
        children = node.get("children", [])
        if not isinstance(children, list):
            raise ValueError("Malformed native method children")
        for child in children:
            visit(child, depth + 1)
    for node in tree["testNodes"]:
        visit(node)
    expected = NATIVE_GROUPS[group]["methods"]
    if len(found) != len(expected) or set(found) != set(expected):
        raise ValueError("Missing, duplicate or foreign actual native methods")
    return sorted(found)


def _build_args():
    return ["-configuration", "Debug", "-onlyUsePackageVersionsFromResolvedFile",
        "CODE_SIGNING_ALLOWED=YES", "CODE_SIGNING_REQUIRED=YES", "CODE_SIGN_IDENTITY=-",
        "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=", "CODE_SIGN_ENTITLEMENTS=",
        "GATEWAY_BASE_URL=", "YUEDU_LOCAL_EXPERIENCE=YES", "IPHONEOS_DEPLOYMENT_TARGET=18.0",
        "ENABLE_DEBUG_DYLIB=NO", "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG LEGADO_REQUIRE_NATIVE_MAINJS"]


def group_commands(work, group):
    spec = NATIVE_GROUPS[group]
    bundle = work / (spec["stem"] + ".xcresult")
    return [
        ["bash", str(smoke.REPO / "scripts/xctest.sh"), "-l", str(work / (spec["stem"] + ".log")),
            "-t", str(spec["seconds"]), "--", *_build_args(), "-resultBundlePath", str(bundle),
            *("-only-testing:yuedu appTests/" + method for method in spec["methods"])],
        ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)],
        ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle)],
    ]


def _capture(argv, output, seconds):
    stderr = output.with_name(output.name + ".stderr.log")
    started = time.monotonic()
    timed_out = False
    # Files avoid unbounded pipe buffering and retain partial failure output.
    with output.open("xb") as out, stderr.open("xb") as err:
        process = subprocess.Popen(argv, stdout=out, stderr=err, start_new_session=True)
        try:
            code = process.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            timed_out = True
            if os.name == "posix":
                try: os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError: pass
            else:
                process.kill()
            code = process.wait(timeout=10)
    return {"argv": argv, "exitCode": code, "timedOut": timed_out, "timeoutSeconds": seconds,
        "elapsedSeconds": round(time.monotonic() - started, 6),
        "output": output.name, "stdout": _fact(output), "stderr": stderr.name, "stderrFact": _fact(stderr)}


def _group_outputs(work, group):
    spec = NATIVE_GROUPS[group]
    return [work / (spec["stem"] + "-driver.log"), work / spec["summary"], work / spec["tests"]]


def run_group(work, group):
    source = _source_state(work)
    spec = NATIVE_GROUPS[group]
    path = work / (spec["stem"] + "-execution.json")
    if path.exists() or (work / (spec["stem"] + ".xcresult")).exists():
        raise ValueError("Refusing to overwrite a previous native group execution")
    # Each group is a separate xctest.sh/xcodebuild host invocation. MainJS sets
    # process tracing before its VM starts; suite ordering in one host is unsafe.
    predecessor = None
    if group == "original":
        previous_path = work / (NATIVE_GROUPS["mainjs"]["stem"] + "-execution.json")
        previous = smoke.read_json(previous_path)
        if previous.get("group") != "mainjs" or previous.get("sourceAfter") != source:
            raise ValueError("The original group requires the completed same-source MainJS host first")
        predecessor = {"path": previous_path.name, **_fact(previous_path)}
    commands = []
    try:
        for argv, output, seconds in zip(group_commands(work, group), _group_outputs(work, group), (spec["seconds"] + 60, 60, 60)):
            commands.append(_capture(argv, output, seconds))
        after = _source_state(work)
        failure = None
    except Exception as error:
        after = None
        failure = type(error).__name__ + ": " + str(error)[:2048]
    record = {"schemaVersion": 1, "group": group, "sourceBefore": source, "sourceAfter": after,
        "expectedMethods": list(spec["methods"]), "commands": commands, "error": failure,
        "precedingMainJSExecution": predecessor}
    smoke.config.write_new_json(path, record)
    try:
        verified = verify_group(work, group)
        return {"group": group, "passed": True, **verified}
    except Exception as error:
        return {"group": group, "passed": False, "error": type(error).__name__ + ": " + str(error)[:2048]}


def verify_group(work, group):
    source = _source_state(work)
    spec = NATIVE_GROUPS[group]
    ledger = smoke.read_json(work / (spec["stem"] + "-execution.json"))
    if (ledger.get("schemaVersion") != 1 or ledger.get("group") != group or ledger.get("error") is not None
            or ledger.get("sourceBefore") != source or ledger.get("sourceAfter") != source
            or ledger.get("expectedMethods") != list(spec["methods"])):
        raise ValueError("Missing, failed or changed-source native group execution")
    previous_path = work / (NATIVE_GROUPS["mainjs"]["stem"] + "-execution.json")
    expected_predecessor = {"path": previous_path.name, **_fact(previous_path)} if group == "original" else None
    if ledger.get("precedingMainJSExecution") != expected_predecessor:
        raise ValueError("Native groups lost their independent host execution order")
    commands = ledger.get("commands")
    if not isinstance(commands, list) or len(commands) != 3:
        raise ValueError("Missing native invocation or original summary/tests exports")
    for actual, argv, output, seconds in zip(commands, group_commands(work, group), _group_outputs(work, group), (spec["seconds"] + 60, 60, 60)):
        if (actual.get("argv") != argv or type(actual.get("exitCode")) is not int or actual["exitCode"] != 0
                or actual.get("timedOut") is not False or actual.get("timeoutSeconds") != seconds
                or actual.get("output") != output.name or actual.get("stdout") != _fact(output)
                or actual.get("stderr") != output.name + ".stderr.log"
                or actual.get("stderrFact") != _fact(output.with_name(output.name + ".stderr.log"))):
            raise ValueError("Native command failed, timed out or its original evidence changed")
    for name in (spec["summary"], spec["tests"]):
        if (work / name).stat().st_size > 16_777_216:
            raise ValueError("Native xcresult export exceeds the fixed evidence budget")
    summary = smoke.read_json(work / spec["summary"])
    if summary.get("expectedFailures", 0) != 0:
        raise ValueError("Expected failures cannot replace native passes")
    counts = smoke.verify_summary(summary, len(spec["methods"]))
    methods = verify_cases(smoke.read_json(work / spec["tests"]), group)
    return {"summary": counts, "passedQualifiedMethods": methods,
        "executionLedger": {"path": spec["stem"] + "-execution.json", **_fact(work / (spec["stem"] + "-execution.json"))}}


def validate_tag():
    source = smoke.source_sha()
    if (os.environ.get("GITHUB_SHA") != source
            or os.environ.get("GITHUB_REF_NAME") != "legado-native-reader-test-" + source[:7]):
        raise ValueError("Expected legado-native-reader-test-<current SHA7> and matching checkout")
    return source


def prepare(work):
    source = validate_tag()
    original_overlay = smoke.overlay_info
    original_validate = smoke.validate_tag

    def stamped_info(path, record_path):
        return original_overlay(path, record_path, source_commit=source)

    # This is a private imported module instance. Existing UI/data smoke
    # protocols retain their unstamped default, including old audit records.
    try:
        smoke.validate_tag = validate_tag
        smoke.overlay_info = stamped_info
        audit = smoke.prepare(work)
        smoke.config.write_new_json(work / "native-source-inputs.json", {"sourceCommit": source, "sourceInputs": source_inputs()})
        return audit
    finally:
        smoke.overlay_info = original_overlay
        smoke.validate_tag = original_validate


def result(work):
    source = validate_tag()
    audit = smoke.read_json(work / "overlays.json")
    if audit.get("infoOverlay", {}).get("sourceCommitStamped") != source:
        raise ValueError("Native smoke preparation did not stamp this source checkout")
    smoke.review_overlays(audit)
    settings = smoke.read_json(work / "build-settings.json")
    matches = [item["buildSettings"] for item in settings if item.get("target") == smoke.config.MAIN_TARGET]
    if len(matches) != 1:
        raise ValueError("Expected one main reader test host")
    actual = matches[0]
    for name, expected in {"CONFIGURATION": "Debug", "PLATFORM_NAME": "iphonesimulator",
                           "SWIFT_VERSION": "5.0", "ENABLE_DEBUG_DYLIB": "NO",
                           "PRODUCT_BUNDLE_IDENTIFIER": smoke.config.MAIN_BUNDLE}.items():
        if actual.get(name) != expected:
            raise ValueError("Unexpected native test-host setting: " + name)
    if "LEGADO_REQUIRE_NATIVE_MAINJS" not in actual.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "").split():
        raise ValueError("The native test must fail, rather than skip, when its runtime is unavailable")
    app = smoke.config.checked_path(Path(actual["TARGET_BUILD_DIR"]) / actual["FULL_PRODUCT_NAME"])
    info = smoke.config.read_info(app)
    smoke.require_local_info(info)
    smoke.require_source_stamp(info, source)
    if info.get("CFBundleSupportedPlatforms") != ["iPhoneSimulator"]:
        raise ValueError("Expected the actual Simulator application")
    if smoke.read_json(work / "native-exports.json").get("requiredDynamicExportsPresent") is not True:
        raise ValueError("The final test host must preserve the required native exports")
    if smoke.read_json(work / "native-restore.json").get("sourceCommit") != source:
        raise ValueError("Native restoration source differs from the tested checkout")
    groups = {group: verify_group(work, group) for group in NATIVE_GROUPS}
    return {"schemaVersion": 1, "sourceCommit": source, "status": "passed",
            "sourceCommitStamped": source,
            "executionPlatform": "ios-simulator", "configuration": "Debug",
            "targetedTests": groups["mainjs"]["summary"],
            "originalReaderTests": groups["original"]["summary"], "nativeExecutionGroups": groups,
            "testedApp": str(app), "testedInfoSHA256": smoke.config.digest(app / "Info.plist"),
            "runtime": smoke.config.verify_jvm_payload(app), "sourceOverlays": audit,
            "nativeProductChainExecuted": True,
            "scope": "Independent hosts: retained MainJS chain, then eight original WebBook/preview/public Reader/all-source pause/book notification/real App grant-cache-reopen/cancel-drain chains through the ordinary JAR and JNI. Controlled loopback sources only.",
            "readerUIRendered": False, "realBookSourcesValidated": False,
            "deliveredIPAExecuted": False, "deviceValidationPassed": False,
            "g4ValidationPassed": False, "fullFeatureParityEstablished": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("validate-tag", "restore", "prepare", "run-group", "verify-cache", "result"))
    parser.add_argument("--work", type=Path, default=smoke.config.REPO / ".build/native-reader-test")
    parser.add_argument("--group", choices=tuple(NATIVE_GROUPS))
    parser.add_argument("--summary", type=Path)
    parser.add_argument("--tests", type=Path)
    args = parser.parse_args()
    work = smoke.config.checked_path(args.work)
    if args.phase == "validate-tag":
        record = {"sourceCommit": validate_tag()}
    elif args.phase == "restore":
        # Override only this private module instance; the reader packaging tag
        # contract and all historical probe gates remain unchanged.
        packaging.validate_tag = validate_tag
        record = packaging.restore()
        smoke.config.write_new_json(work / "native-restore.json", record)
    elif args.phase == "prepare":
        record = prepare(work)
    elif args.phase == "verify-cache":
        if args.summary is None or args.tests is None:
            parser.error("verify-cache requires --summary and --tests")
        record = verify_cache(smoke.read_json(args.summary), smoke.read_json(args.tests))
    elif args.phase == "run-group":
        if args.group is None:
            parser.error("run-group requires --group")
        record = run_group(work, args.group)
        print(json.dumps(record, indent=2))
        return 0 if record["passed"] else 1
    else:
        record = result(work)
        smoke.config.write_new_json(work / "result.json", record)
    print(json.dumps(record, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
