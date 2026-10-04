#!/usr/bin/env python3
"""Deterministic Xcode project generation; Python stdlib only. Commit generated project."""
import hashlib, pathlib, plistlib
root = pathlib.Path(__file__).resolve().parents[1]
objects = {}
def uid(label): return hashlib.sha1(label.encode()).hexdigest()[:24].upper()
def add(label, text):
    key = uid(label); objects[key] = text; return key
def q(value): return '"' + value.replace('"', '\\"') + '"'
def array(values): return '(' + ', '.join(values) + ',)'
package = add('package', 'isa = XCLocalSwiftPackageReference; relativePath = Shared/MusicSyncCore;')
rootgroup = uid('rootgroup'); products = uid('products')
targets=[]; productrefs=[]; groups=[]; projectconfigs=[]
for config in ['Debug','Release']:
    projectconfigs.append(add('project-'+config, 'isa = XCBuildConfiguration; name = '+config+'; buildSettings = { SWIFT_VERSION = 5.0; CLANG_ENABLE_MODULES = YES; };'))
projectlist = add('project-list', 'isa = XCConfigurationList; buildConfigurations = '+array(projectconfigs)+'; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
for platform, folder, app, scheme in [('macOS','macOS/MusicSyncMac','MusicSync-macOS','MusicSyncMac'),('iOS','iOS/MusicSynciOS','MusicSync-iOS','MusicSynciOS')]:
    sources = sorted((root/folder).glob('*.swift')) + sorted((root/'AppShared').glob('*.swift'))
    files=[]; buildfiles=[]
    for source in sources:
        rel=str(source.relative_to(root))
        ref=add(scheme+rel,'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = '+q(rel)+'; sourceTree = SOURCE_ROOT;')
        files.append(ref)
        buildfiles.append(add(scheme+'build'+rel,'isa = PBXBuildFile; fileRef = '+ref+';'))
    groups.append(add(scheme+'group','isa = PBXGroup; name = '+scheme+'; children = '+array(files)+'; sourceTree = "<group>";'))
    product=add(scheme+'product','isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = '+q(app+'.app')+'; sourceTree = BUILT_PRODUCTS_DIR;')
    productrefs.append(product)
    dependency=add(scheme+'dep','isa = XCSwiftPackageProductDependency; productName = MusicSyncCore;')
    frameworkfile=add(scheme+'frameworkfile','isa = PBXBuildFile; productRef = '+dependency+';')
    frameworks=add(scheme+'frameworks','isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = '+array([frameworkfile])+'; runOnlyForDeploymentPostprocessing = 0;')
    sourcephase=add(scheme+'sources','isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = '+array(buildfiles)+'; runOnlyForDeploymentPostprocessing = 0;')
    resourcefiles=[]
    for filename in ['Localizable.strings','InfoPlist.strings']:
        variants=[]
        for language in ['en','ko']:
            variants.append(add(scheme+filename+language,'isa = PBXFileReference; lastKnownFileType = text.plist.strings; name = '+language+'; path = '+q('AppShared/Resources/'+language+'.lproj/'+filename)+'; sourceTree = SOURCE_ROOT;'))
        variant=add(scheme+filename+'variant','isa = PBXVariantGroup; name = '+filename+'; children = '+array(variants)+'; sourceTree = "<group>";')
        groups.append(variant)
        resourcefiles.append(add(scheme+filename+'resource','isa = PBXBuildFile; fileRef = '+variant+';'))
    resourcephase=add(scheme+'resources','isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = '+array(resourcefiles)+'; runOnlyForDeploymentPostprocessing = 0;')
    configs=[]
    for config in ['Debug','Release']:
        settings={'PRODUCT_NAME':app,'PRODUCT_BUNDLE_IDENTIFIER':'dev.acops.MusicSync.'+platform,'INFOPLIST_FILE':folder+'/Info.plist','CODE_SIGN_ENTITLEMENTS':folder+'/MusicSync.entitlements','CODE_SIGN_STYLE':'Automatic','SWIFT_VERSION':'5.0','SWIFT_STRICT_CONCURRENCY':'minimal','GENERATE_INFOPLIST_FILE':'NO','CURRENT_PROJECT_VERSION':'3','MARKETING_VERSION':'0.3.0','ENABLE_USER_SCRIPT_SANDBOXING':'YES','SWIFT_OPTIMIZATION_LEVEL':'-Onone' if config=='Debug' else '-O','SDKROOT':'macosx' if platform=='macOS' else 'iphoneos','SUPPORTED_PLATFORMS':'macosx' if platform=='macOS' else 'iphoneos iphonesimulator','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks' if platform=='iOS' else '$(inherited) @executable_path/../Frameworks','DEBUG_INFORMATION_FORMAT':'dwarf-with-dsym' if config=='Release' else 'dwarf'}
        if platform=='macOS': settings.update(MACOSX_DEPLOYMENT_TARGET='26.0',ENABLE_APP_SANDBOX='NO',ENABLE_HARDENED_RUNTIME='YES')
        else: settings.update(IPHONEOS_DEPLOYMENT_TARGET='26.0',TARGETED_DEVICE_FAMILY='1,2',SUPPORTS_MACCATALYST='NO')
        configs.append(add(scheme+config,'isa = XCBuildConfiguration; name = '+config+'; buildSettings = { '+' '.join(k+' = '+q(v)+';' for k,v in settings.items())+' };'))
    configlist=add(scheme+'list','isa = XCConfigurationList; buildConfigurations = '+array(configs)+'; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    target=add(scheme,'isa = PBXNativeTarget; buildConfigurationList = '+configlist+'; buildPhases = '+array([sourcephase,frameworks,resourcephase])+'; buildRules = (); dependencies = (); name = '+scheme+'; packageProductDependencies = '+array([dependency])+'; productName = '+q(app)+'; productReference = '+product+'; productType = "com.apple.product-type.application";')
    targets.append(target)
    schemefolder=root/'MusicSync.xcodeproj/xcshareddata/xcschemes'; schemefolder.mkdir(parents=True,exist_ok=True)
    ref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{app}.app" BlueprintName="{scheme}" ReferencedContainer="container:MusicSync.xcodeproj"/>'
    (schemefolder/(scheme+'.xcscheme')).write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug"/>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
    info={'CFBundleDevelopmentRegion':'en','CFBundleLocalizations':['en','ko'],'CFBundleExecutable':'$(EXECUTABLE_NAME)','CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)','CFBundleName':'MusicSync','CFBundleDisplayName':'MusicSync','CFBundlePackageType':'APPL','CFBundleShortVersionString':'$(MARKETING_VERSION)','CFBundleVersion':'$(CURRENT_PROJECT_VERSION)','NSLocalNetworkUsageDescription':'MusicSync discovers your Mac and streams audio to nearby devices on your local network.','NSBonjourServices':['_musicsync._tcp']}
    if platform=='macOS': info.update(LSMinimumSystemVersion='$(MACOSX_DEPLOYMENT_TARGET)',NSAudioCaptureUsageDescription='MusicSync captures system audio to replay it in sync on your Mac and iPhone.',NSScreenCaptureUsageDescription='Monitor mode captures system audio with ScreenCaptureKit; screen images are not transmitted.',NSPrincipalClass='NSApplication')
    else: info.update(NSAppleMusicUsageDescription='MusicSync lets you select downloaded DRM-free songs from your music library to stream to your nearby devices.',LSRequiresIPhoneOS=True,UILaunchScreen={},UIBackgroundModes=['audio'],UISupportedInterfaceOrientations=['UIInterfaceOrientationPortrait','UIInterfaceOrientationPortraitUpsideDown','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight'])
    (root/folder/'Info.plist').write_bytes(plistlib.dumps(info))
    (root/folder/'MusicSync.entitlements').write_bytes(plistlib.dumps({}))
add('products','isa = PBXGroup; name = Products; children = '+array(productrefs)+'; sourceTree = "<group>";')
add('rootgroup','isa = PBXGroup; children = '+array(groups+[products])+'; sourceTree = "<group>";')
project=add('project','isa = PBXProject; attributes = { BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2600; }; buildConfigurationList = '+projectlist+'; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, ko, Base); mainGroup = '+rootgroup+'; productRefGroup = '+products+'; projectDirPath = ""; projectRoot = ""; packageReferences = '+array([package])+'; targets = '+array(targets)+';')
(root/'MusicSync.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+''.join(k+' = { '+v+' };\n' for k,v in sorted(objects.items()))+'}; rootObject = '+project+'; }\n')
