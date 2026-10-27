#!/usr/bin/env python3
"""Dependency-free, deterministic Xcode project generation. Run after adding Swift files."""
import hashlib, pathlib
root = pathlib.Path(__file__).resolve().parents[1]
ios = root / 'ios'
def uid(s): return hashlib.sha1(s.encode()).hexdigest()[:24].upper()
def q(s): return '"' + str(s).replace('\\', '\\\\').replace('"', '\\"') + '"'
objects = {}
def obj(key, value): objects[uid(key)] = value; return uid(key)
def array(values): return '(' + ', '.join(values) + (',)' if values else ')')
def fields(**kwargs): return '{ ' + ' '.join(k + ' = ' + str(v) + ';' for k, v in kwargs.items()) + ' }'
products = []
targets = []
refs = []
configRefs = {}
for name in ['Debug', 'Release']:
    ref = obj('configfile'+name, fields(isa='PBXFileReference', lastKnownFileType='text.xcconfig', path=q('Config/'+name+'.xcconfig'), sourceTree=q('<group>')))
    configRefs[name] = ref; refs.append(ref)
for name, folder, kind in [('BabyCryMonitor', 'BabyCryMonitor', 'application'), ('BabyCryMonitorTests', 'BabyCryMonitorTests', 'bundle.unit-test'), ('BabyCryMonitorUITests', 'BabyCryMonitorUITests', 'bundle.ui-testing')]:
    sourceRefs = []; sourceBuilds = []; resourceBuilds = []
    files = sorted((ios/folder).rglob('*.swift'))
    if kind == 'application': files += [ios/folder/'Assets.xcassets', ios/folder/'PrivacyInfo.xcprivacy', ios/folder/'Info.plist', ios/folder/'BabyCryMonitor.entitlements'] + sorted((ios/folder/'Resources').glob('*.caf'))
    for path in files:
        rel = path.relative_to(ios).as_posix()
        filetype = {'swift':'sourcecode.swift', 'xcassets':'folder.assetcatalog', 'xcprivacy':'text.xml', 'plist':'text.plist.xml', 'entitlements':'text.plist.entitlements', 'caf':'file'}[path.suffix[1:]]
        ref = obj('file'+rel, fields(isa='PBXFileReference', lastKnownFileType=filetype, path=q(rel), sourceTree=q('<group>'))); sourceRefs.append(ref)
        if path.suffix == '.swift': sourceBuilds.append(obj('build'+rel, fields(isa='PBXBuildFile', fileRef=ref)))
        elif path.suffix in ['.xcassets', '.xcprivacy', '.caf']: resourceBuilds.append(obj('build'+rel, fields(isa='PBXBuildFile', fileRef=ref)))
    refs.append(obj('group'+name, fields(isa='PBXGroup', name=q(name), children=array(sourceRefs), sourceTree=q('<group>'))))
    product = obj('product'+name, fields(isa='PBXFileReference', explicitFileType='wrapper.application' if kind == 'application' else 'wrapper.cfbundle', includeInIndex='0', path=q(name+('.app' if kind == 'application' else '.xctest')), sourceTree='BUILT_PRODUCTS_DIR'))
    products.append(product)
    phases = [obj('sources'+name, fields(isa='PBXSourcesBuildPhase', buildActionMask='2147483647', files=array(sourceBuilds), runOnlyForDeploymentPostprocessing='0')), obj('frameworks'+name, fields(isa='PBXFrameworksBuildPhase', buildActionMask='2147483647', files='()', runOnlyForDeploymentPostprocessing='0')), obj('resources'+name, fields(isa='PBXResourcesBuildPhase', buildActionMask='2147483647', files=array(resourceBuilds), runOnlyForDeploymentPostprocessing='0'))]
    configs = []
    for mode in ['Debug', 'Release']:
        settings = dict(PRODUCT_NAME=q('$(TARGET_NAME)'), PRODUCT_BUNDLE_IDENTIFIER=q('com.jordanerenrich.cribservice'+('' if kind == 'application' else '.'+name)), SWIFT_VERSION='6.0', IPHONEOS_DEPLOYMENT_TARGET='17.0', TARGETED_DEVICE_FAMILY='1', CODE_SIGN_STYLE='Automatic', GENERATE_INFOPLIST_FILE='YES', CURRENT_PROJECT_VERSION='1', MARKETING_VERSION='1.0', SWIFT_STRICT_CONCURRENCY='complete')
        settings['LD_RUNPATH_SEARCH_PATHS'] = q('$(inherited) @executable_path/Frameworks @loader_path/Frameworks')
        if kind == 'application': settings.update(GENERATE_INFOPLIST_FILE='NO', INFOPLIST_FILE=q('BabyCryMonitor/Info.plist'), CODE_SIGN_ENTITLEMENTS=q('BabyCryMonitor/BabyCryMonitor.entitlements'), ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon', ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME='AccentColor')
        elif kind == 'bundle.unit-test': settings.update(TEST_HOST=q('$(BUILT_PRODUCTS_DIR)/BabyCryMonitor.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/BabyCryMonitor'), BUNDLE_LOADER=q('$(TEST_HOST)'))
        else: settings.update(TEST_TARGET_NAME='BabyCryMonitor')
        settings['SWIFT_OPTIMIZATION_LEVEL'] = q('-Onone' if mode == 'Debug' else '-O')
        settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = q('DEBUG $(inherited)' if mode == 'Debug' else '$(inherited)')
        configs.append(obj('targetconfig'+name+mode, fields(isa='XCBuildConfiguration', baseConfigurationReference=configRefs[mode], buildSettings=fields(**settings), name=mode)))
    configList = obj('targetconfigs'+name, fields(isa='XCConfigurationList', buildConfigurations=array(configs), defaultConfigurationIsVisible='0', defaultConfigurationName='Release'))
    dependencies = []
    if kind != 'application':
        proxy = obj('proxy'+name, fields(isa='PBXContainerItemProxy', containerPortal=uid('project'), proxyType='1', remoteGlobalIDString=uid('targetBabyCryMonitor'), remoteInfo='BabyCryMonitor'))
        dependencies = [obj('dep'+name, fields(isa='PBXTargetDependency', target=uid('targetBabyCryMonitor'), targetProxy=proxy))]
    targets.append(obj('target'+name, fields(isa='PBXNativeTarget', buildConfigurationList=configList, buildPhases=array(phases), buildRules='()', dependencies=array(dependencies) if dependencies else '()', name=name, productName=name, productReference=product, productType=q('com.apple.product-type.'+kind))))
# Modern, single-target watchOS companion; shared messages stay Foundation-only.
watchName = 'BabyCryWatch'
watchFiles = sorted((ios/watchName).rglob('*.swift')) + [ios/'BabyCryMonitor/Utilities/DiagnosticLog.swift', ios/'BabyCryMonitor/Utilities/ConnectionWarningNotification.swift', ios/'BabyCryMonitor/Utilities/NotificationCleanup.swift', ios/'BabyCryMonitor/Models/NotificationRelevance.swift', ios/'BabyCryMonitor/Models/Models.swift', ios/'BabyCryMonitor/Models/BatteryDrainLog.swift', ios/'BabyCryMonitor/Models/BackgroundBenchmark.swift', ios/'BabyCryMonitor/Models/Timeline.swift', ios/'BabyCryMonitor/Models/WatchMessages.swift', ios/'BabyCryMonitor/Models/WatchAlertTrace.swift', ios/'BabyCryMonitor/Models/WatchNotificationPresentation.swift', ios/'BabyCryMonitor/Models/NotificationCallbackJournal.swift', ios/'BabyCryMonitor/Models/DiagnosticTiming.swift', ios/'BabyCryMonitor/Models/WatchAlertState.swift', ios/'BabyCryMonitor/Models/WatchAlertSetup.swift', ios/watchName/'Info.plist', ios/watchName/'BabyCryWatch.entitlements', ios/watchName/'Assets.xcassets', ios/'BabyCryMonitor/PrivacyInfo.xcprivacy']
watchFiles += sorted((ios/'BabyCryMonitor/Resources').glob('*.caf'))
watchRefs = []; watchSources = []; watchResources = []
for path in watchFiles:
    rel = path.relative_to(ios).as_posix()
    filetype = {'swift':'sourcecode.swift', 'xcassets':'folder.assetcatalog', 'xcprivacy':'text.xml', 'plist':'text.plist.xml', 'entitlements':'text.plist.entitlements', 'caf':'file'}[path.suffix[1:]]
    ref = obj('file'+rel, fields(isa='PBXFileReference', lastKnownFileType=filetype, path=q(rel), sourceTree=q('<group>')))
    if rel.startswith(watchName+'/'): watchRefs.append(ref)
    if path.suffix == '.swift': watchSources.append(obj('watchbuild'+rel, fields(isa='PBXBuildFile', fileRef=ref)))
    elif path.suffix in ['.xcassets', '.xcprivacy', '.caf']: watchResources.append(obj('watchbuild'+rel, fields(isa='PBXBuildFile', fileRef=ref)))
refs.append(obj('group'+watchName, fields(isa='PBXGroup', name=watchName, children=array(watchRefs), sourceTree=q('<group>'))))
watchProduct = obj('product'+watchName, fields(isa='PBXFileReference', explicitFileType='wrapper.application', includeInIndex='0', path=q(watchName+'.app'), sourceTree='BUILT_PRODUCTS_DIR'))
products.append(watchProduct)
watchPhases = [obj('sources'+watchName, fields(isa='PBXSourcesBuildPhase', buildActionMask='2147483647', files=array(watchSources), runOnlyForDeploymentPostprocessing='0')), obj('frameworks'+watchName, fields(isa='PBXFrameworksBuildPhase', buildActionMask='2147483647', files='()', runOnlyForDeploymentPostprocessing='0')), obj('resources'+watchName, fields(isa='PBXResourcesBuildPhase', buildActionMask='2147483647', files=array(watchResources), runOnlyForDeploymentPostprocessing='0'))]
watchConfigs = []
for mode in ['Debug', 'Release']:
    settings = dict(PRODUCT_NAME=q('$(TARGET_NAME)'), PRODUCT_BUNDLE_IDENTIFIER=q('com.jordanerenrich.cribservice.watchkitapp'), SWIFT_VERSION='6.0', SWIFT_STRICT_CONCURRENCY='complete', SDKROOT='watchos', SUPPORTED_PLATFORMS=q('watchos watchsimulator'), WATCHOS_DEPLOYMENT_TARGET='10.0', TARGETED_DEVICE_FAMILY='4', CODE_SIGN_STYLE='Automatic', GENERATE_INFOPLIST_FILE='NO', INFOPLIST_FILE=q('BabyCryWatch/Info.plist'), CODE_SIGN_ENTITLEMENTS=q('BabyCryWatch/BabyCryWatch.entitlements'), CURRENT_PROJECT_VERSION='1', MARKETING_VERSION='1.0', SKIP_INSTALL='YES', ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon', SWIFT_OPTIMIZATION_LEVEL=q('-Onone' if mode=='Debug' else '-O'), SWIFT_ACTIVE_COMPILATION_CONDITIONS=q('DEBUG $(inherited)' if mode=='Debug' else '$(inherited)'), LD_RUNPATH_SEARCH_PATHS=q('$(inherited) @executable_path/Frameworks'))
    watchConfigs.append(obj('targetconfig'+watchName+mode, fields(isa='XCBuildConfiguration', baseConfigurationReference=configRefs[mode], buildSettings=fields(**settings), name=mode)))
watchConfigList = obj('targetconfigs'+watchName, fields(isa='XCConfigurationList', buildConfigurations=array(watchConfigs), defaultConfigurationIsVisible='0', defaultConfigurationName='Release'))
targets.append(obj('target'+watchName, fields(isa='PBXNativeTarget', buildConfigurationList=watchConfigList, buildPhases=array(watchPhases), buildRules='()', dependencies='()', name=watchName, productName=watchName, productReference=watchProduct, productType=q('com.apple.product-type.application'))))
watchProxy = obj('proxy'+watchName, fields(isa='PBXContainerItemProxy', containerPortal=uid('project'), proxyType='1', remoteGlobalIDString=uid('target'+watchName), remoteInfo=watchName))
watchDependency = obj('dep'+watchName, fields(isa='PBXTargetDependency', target=uid('target'+watchName), targetProxy=watchProxy))
watchEmbed = obj('embedWatchProduct', fields(isa='PBXBuildFile', fileRef=watchProduct, settings='{ ATTRIBUTES = (RemoveHeadersOnCopy,); }'))
watchEmbedPhase = obj('embedWatch', fields(isa='PBXCopyFilesBuildPhase', buildActionMask='2147483647', dstPath=q('$(CONTENTS_FOLDER_PATH)/Watch'), dstSubfolderSpec='16', files=array([watchEmbed]), name=q('Embed Watch Content'), runOnlyForDeploymentPostprocessing='0'))
phoneTarget = objects[uid('targetBabyCryMonitor')]
phonePhases = array([uid('sourcesBabyCryMonitor'), uid('frameworksBabyCryMonitor'), uid('resourcesBabyCryMonitor')])
objects[uid('targetBabyCryMonitor')] = phoneTarget.replace('buildPhases = '+phonePhases, 'buildPhases = '+array([uid('sourcesBabyCryMonitor'), uid('frameworksBabyCryMonitor'), uid('resourcesBabyCryMonitor'), watchEmbedPhase])).replace('dependencies = ()', 'dependencies = '+array([watchDependency]))
# Isolated watch-only latency probe. Never embed it in the iOS application or
# declare an iOS companion: removing that relationship is the experimental variable.
probeName = 'WatchLatencyProbe'
probeFiles = sorted((ios/probeName).glob('*.swift')) + [ios/probeName/'Info.plist', ios/probeName/'WatchLatencyProbe.entitlements', ios/'BabyCryWatch/Assets.xcassets', ios/'BabyCryMonitor/PrivacyInfo.xcprivacy']
probeRefs = []; probeSources = []; probeResources = []
for path in probeFiles:
    rel = path.relative_to(ios).as_posix()
    filetype = {'swift':'sourcecode.swift', 'xcassets':'folder.assetcatalog', 'xcprivacy':'text.xml', 'plist':'text.plist.xml', 'entitlements':'text.plist.entitlements'}[path.suffix[1:]]
    ref = obj('file'+rel, fields(isa='PBXFileReference', lastKnownFileType=filetype, path=q(rel), sourceTree=q('<group>')))
    if rel.startswith(probeName+'/'): probeRefs.append(ref)
    if path.suffix == '.swift': probeSources.append(obj('probebuild'+rel, fields(isa='PBXBuildFile', fileRef=ref)))
    elif path.suffix in ['.xcassets', '.xcprivacy']: probeResources.append(obj('probebuild'+rel, fields(isa='PBXBuildFile', fileRef=ref)))
refs.append(obj('group'+probeName, fields(isa='PBXGroup', name=probeName, children=array(probeRefs), sourceTree=q('<group>'))))
probeProduct = obj('product'+probeName, fields(isa='PBXFileReference', explicitFileType='wrapper.application', includeInIndex='0', path=q(probeName+'.app'), sourceTree='BUILT_PRODUCTS_DIR'))
products.append(probeProduct)
probePhases = [obj('sources'+probeName, fields(isa='PBXSourcesBuildPhase', buildActionMask='2147483647', files=array(probeSources), runOnlyForDeploymentPostprocessing='0')), obj('frameworks'+probeName, fields(isa='PBXFrameworksBuildPhase', buildActionMask='2147483647', files='()', runOnlyForDeploymentPostprocessing='0')), obj('resources'+probeName, fields(isa='PBXResourcesBuildPhase', buildActionMask='2147483647', files=array(probeResources), runOnlyForDeploymentPostprocessing='0'))]
probeConfigs = []
for mode in ['Debug', 'Release']:
    settings = dict(PRODUCT_NAME=q('$(TARGET_NAME)'), PRODUCT_BUNDLE_IDENTIFIER=q('com.jordanerenrich.cribservice.latencyprobe'), SWIFT_VERSION='6.0', SWIFT_STRICT_CONCURRENCY='complete', SDKROOT='watchos', SUPPORTED_PLATFORMS=q('watchos watchsimulator'), WATCHOS_DEPLOYMENT_TARGET='10.0', TARGETED_DEVICE_FAMILY='4', CODE_SIGN_STYLE='Automatic', GENERATE_INFOPLIST_FILE='NO', INFOPLIST_FILE=q('WatchLatencyProbe/Info.plist'), CODE_SIGN_ENTITLEMENTS=q('WatchLatencyProbe/WatchLatencyProbe.entitlements'), CURRENT_PROJECT_VERSION='1', MARKETING_VERSION='1.0', SKIP_INSTALL='NO', ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon', SWIFT_OPTIMIZATION_LEVEL=q('-Onone' if mode=='Debug' else '-O'), SWIFT_ACTIVE_COMPILATION_CONDITIONS=q('DEBUG $(inherited)' if mode=='Debug' else '$(inherited)'), LD_RUNPATH_SEARCH_PATHS=q('$(inherited) @executable_path/Frameworks'))
    probeConfigs.append(obj('targetconfig'+probeName+mode, fields(isa='XCBuildConfiguration', baseConfigurationReference=configRefs[mode], buildSettings=fields(**settings), name=mode)))
probeConfigList = obj('targetconfigs'+probeName, fields(isa='XCConfigurationList', buildConfigurations=array(probeConfigs), defaultConfigurationIsVisible='0', defaultConfigurationName='Release'))
targets.append(obj('target'+probeName, fields(isa='PBXNativeTarget', buildConfigurationList=probeConfigList, buildPhases=array(probePhases), buildRules='()', dependencies='()', name=probeName, productName=probeName, productReference=probeProduct, productType=q('com.apple.product-type.application'))))
prodGroup = obj('products', fields(isa='PBXGroup', name='Products', children=array(products), sourceTree=q('<group>')))
mainGroup = obj('main', fields(isa='PBXGroup', children=array(refs+[prodGroup]), sourceTree=q('<group>')))
configs=[]
for mode in ['Debug','Release']:
    settings=dict(SDKROOT='iphoneos', CLANG_ENABLE_MODULES='YES', CLANG_ENABLE_OBJC_ARC='YES', ENABLE_TESTABILITY='YES' if mode=='Debug' else 'NO', DEBUG_INFORMATION_FORMAT=q('dwarf' if mode=='Debug' else 'dwarf-with-dsym'), SWIFT_COMPILATION_MODE='singlefile' if mode=='Debug' else 'wholemodule')
    configs.append(obj('projectconfig'+mode, fields(isa='XCBuildConfiguration', buildSettings=fields(**settings), name=mode)))
configList=obj('projectconfigs', fields(isa='XCConfigurationList', buildConfigurations=array(configs), defaultConfigurationIsVisible='0', defaultConfigurationName='Release'))
obj('project', fields(isa='PBXProject', attributes='{ LastUpgradeCheck = 2700; TargetAttributes = { '+uid('targetBabyCryMonitor')+' = { SystemCapabilities = { com.apple.BackgroundModes = { enabled = 1; }; com.apple.Push = { enabled = 1; }; }; }; }; }', buildConfigurationList=configList, compatibilityVersion=q('Xcode 14.0'), developmentRegion='en', hasScannedForEncodings='0', knownRegions='(en, Base,)', mainGroup=mainGroup, productRefGroup=prodGroup, projectDirPath=q(''), projectRoot=q(''), targets=array(targets)))
project=ios/'BabyCryMonitor.xcodeproj'; project.mkdir(exist_ok=True)
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(k+' = '+v+';' for k,v in objects.items())+'\n}; rootObject = '+uid('project')+'; }\n')
scheme=project/'xcshareddata'/'xcschemes'; scheme.mkdir(parents=True, exist_ok=True)
def reference(name): return '<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="'+uid('target'+name)+'" BuildableName="'+name+('.app' if name in ['BabyCryMonitor', 'BabyCryWatch', 'WatchLatencyProbe'] else '.xctest')+'" BlueprintName="'+name+'" ReferencedContainer="container:BabyCryMonitor.xcodeproj"/>'
(scheme/'BabyCryMonitor.xcscheme').write_text('<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="2700" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">'+reference('BabyCryMonitor')+'</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables>'+''.join('<TestableReference skipped="NO">'+reference(n)+'</TestableReference>' for n in ['BabyCryMonitorTests','BabyCryMonitorUITests'])+'</Testables></TestAction><LaunchAction buildConfiguration="Debug" useCustomWorkingDirectory="NO" launchStyle="0"><BuildableProductRunnable runnableDebuggingMode="0">'+reference('BabyCryMonitor')+'</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release"><BuildableProductRunnable runnableDebuggingMode="0">'+reference('BabyCryMonitor')+'</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>')
(scheme/'BabyCryWatch.xcscheme').write_text('<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="2700" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">'+reference('BabyCryWatch')+'</BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" launchStyle="0"><BuildableProductRunnable runnableDebuggingMode="0">'+reference('BabyCryWatch')+'</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release"><BuildableProductRunnable runnableDebuggingMode="0">'+reference('BabyCryWatch')+'</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>')
print(project)
probeScheme = (scheme/'BabyCryWatch.xcscheme').read_text().replace(reference('BabyCryWatch'), reference(probeName))
(scheme/'WatchLatencyProbe.xcscheme').write_text(probeScheme)
