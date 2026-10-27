#!/usr/bin/env python3
"""Generate a deterministic, dependency-free Xcode project (run after adding sources)."""
from pathlib import Path
import hashlib, json, plistlib
root = Path(__file__).resolve().parents[1]
objects = {}
def uid(s): return hashlib.sha256(s.encode()).hexdigest()[:24].upper()
def put(identity, **v):
 key=uid(identity);objects[key]=v;return key
def ref(path, kind): return put('file:'+path, isa='PBXFileReference', lastKnownFileType=kind, path=path, sourceTree='<group>')
source_refs=[];source_build=[];resource_refs=[];resource_build=[]
for p in sorted((root/'Vesper').rglob('*.swift')):
 path=str(p.relative_to(root));f=ref(path,'sourcecode.swift');source_refs.append(f);source_build.append(put('build:'+path,isa='PBXBuildFile',fileRef=f))
broadcast_access=ref('Shared/BroadcastAccess.swift','sourcecode.swift')
source_refs.append(broadcast_access);source_build.append(put('broadcast-access-app-build',isa='PBXBuildFile',fileRef=broadcast_access))
shared_ref=ref('Shared/WidgetSnapshot.swift','sourcecode.swift')
source_refs.append(shared_ref);source_build.append(put('shared-app-build',isa='PBXBuildFile',fileRef=shared_ref))
call_activity_ref=ref('Shared/CallActivityAttributes.swift','sourcecode.swift')
source_refs.append(call_activity_ref);source_build.append(put('call-activity-app-build',isa='PBXBuildFile',fileRef=call_activity_ref))
for path,kind in [('Vesper/Resources/Assets.xcassets','folder.assetcatalog'),('Vesper/Resources/Ballet.ttf','file'),('Vesper/Resources/Ballet-OFL.txt','text'),('Vesper/Resources/PhotoStack','folder')]:
 if (root/path).exists():
  f=ref(path,kind);resource_refs.append(f);resource_build.append(put('build:'+path,isa='PBXBuildFile',fileRef=f))
info=ref('Vesper/Info.plist','text.plist.xml')
app=put('app',isa='PBXFileReference',explicitFileType='wrapper.application',path='Vesper.app',sourceTree='BUILT_PRODUCTS_DIR',includeInIndex=0)
test_product=put('test-product',isa='PBXFileReference',explicitFileType='wrapper.cfbundle',path='VesperTests.xctest',sourceTree='BUILT_PRODUCTS_DIR',includeInIndex=0)
testrefs=[];testbuild=[]
for p in sorted((root/'VesperTests').glob('*.swift')):
 path=str(p.relative_to(root));f=ref(path,'sourcecode.swift');testrefs.append(f);testbuild.append(put('build:'+path,isa='PBXBuildFile',fileRef=f))
products=put('products',isa='PBXGroup',children=[app,test_product],name='Products',sourceTree='<group>')
sources=put('sources',isa='PBXGroup',children=source_refs,name='Sources',sourceTree='<group>')
resources=put('resources',isa='PBXGroup',children=resource_refs+[info],name='Resources',sourceTree='<group>')
tests=put('tests-group',isa='PBXGroup',children=testrefs,name='Tests',sourceTree='<group>')
main=put('main',isa='PBXGroup',children=[sources,resources,tests,products],sourceTree='<group>')
def phase(name,isa,files):return put(name,isa=isa,buildActionMask=2147483647,files=files,runOnlyForDeploymentPostprocessing=0)
sources_phase=phase('sources-phase','PBXSourcesBuildPhase',source_build)
resources_phase=phase('resources-phase','PBXResourcesBuildPhase',resource_build)
frameworks_phase=phase('frameworks-phase','PBXFrameworksBuildPhase',[])
# Stable upstream sources with the watchOS manifest fix; see ThirdParty/ZIPFoundation/VESPER.md.
zip_package=put('zipfoundation-package',isa='XCLocalSwiftPackageReference',relativePath='ThirdParty/ZIPFoundation')
zip_product=put('zipfoundation-product',isa='XCSwiftPackageProductDependency',package=zip_package,productName='ZIPFoundation')
objects[frameworks_phase]['files'].append(put('zipfoundation-build',isa='PBXBuildFile',productRef=zip_product))
tests_phase=phase('tests-phase','PBXSourcesBuildPhase',testbuild)
test_frameworks=phase('test-frameworks','PBXFrameworksBuildPhase',[put('zipfoundation-test-build',isa='PBXBuildFile',productRef=zip_product)])
def configs(name,base):
 refs=[]
 for mode in ['Debug','Release']:
  settings=dict(base)
  settings['SWIFT_OPTIMIZATION_LEVEL']='-Onone' if mode=='Debug' else '-O'
  if mode=='Debug':settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='DEBUG $(inherited)';settings['ENABLE_TESTABILITY']='YES';settings['COPY_PHASE_STRIP']='NO';settings['ONLY_ACTIVE_ARCH']='YES'
  refs.append(put(name+mode,isa='XCBuildConfiguration',buildSettings=settings,name=mode))
 return put(name+'configs',isa='XCConfigurationList',buildConfigurations=refs,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
common={'IPHONEOS_DEPLOYMENT_TARGET':'17.0','SDKROOT':'iphoneos','SWIFT_VERSION':'5.0','CLANG_ENABLE_MODULES':'YES','CLANG_ENABLE_OBJC_ARC':'YES','TARGETED_DEVICE_FAMILY':'1,2','DEVELOPMENT_TEAM':'5AYW37S3Z5'}
common.update({'CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING': 'YES', 'CLANG_WARN_BOOL_CONVERSION': 'YES', 'CLANG_WARN_COMMA': 'YES', 'CLANG_WARN_CONSTANT_CONVERSION': 'YES', 'CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS': 'YES', 'CLANG_WARN_EMPTY_BODY': 'YES', 'CLANG_WARN_ENUM_CONVERSION': 'YES', 'CLANG_WARN_INFINITE_RECURSION': 'YES', 'CLANG_WARN_INT_CONVERSION': 'YES', 'CLANG_WARN_NON_LITERAL_NULL_CONVERSION': 'YES', 'CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF': 'YES', 'CLANG_WARN_OBJC_LITERAL_CONVERSION': 'YES', 'CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER': 'YES', 'CLANG_WARN_RANGE_LOOP_ANALYSIS': 'YES', 'CLANG_WARN_STRICT_PROTOTYPES': 'YES', 'CLANG_WARN_SUSPICIOUS_MOVE': 'YES', 'CLANG_WARN_UNREACHABLE_CODE': 'YES', 'CLANG_WARN__DUPLICATE_METHOD_MATCH': 'YES', 'ENABLE_STRICT_OBJC_MSGSEND': 'YES', 'GCC_NO_COMMON_BLOCKS': 'YES', 'GCC_WARN_64_TO_32_BIT_CONVERSION': 'YES', 'GCC_WARN_ABOUT_RETURN_TYPE': 'YES', 'GCC_WARN_UNDECLARED_SELECTOR': 'YES', 'GCC_WARN_UNINITIALIZED_AUTOS': 'YES', 'GCC_WARN_UNUSED_FUNCTION': 'YES', 'GCC_WARN_UNUSED_VARIABLE': 'YES', 'STRING_CATALOG_GENERATE_SYMBOLS': 'YES'})
common['ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS']='YES'
project_config=configs('project',common)
objects[uid('projectRelease')]['buildSettings']['SWIFT_COMPILATION_MODE']='wholemodule'
app_config=configs('app',{'PRODUCT_BUNDLE_IDENTIFIER':'com.vera.vesper.native','PRODUCT_NAME':'$(TARGET_NAME)','CODE_SIGN_STYLE':'Automatic','INFOPLIST_FILE':'Vesper/Info.plist','CODE_SIGN_ENTITLEMENTS':'Vesper/Vesper.entitlements','ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES':['AppIconWhite','AppIconBlack'],'ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS':'YES','CURRENT_PROJECT_VERSION':'7','MARKETING_VERSION':'0.1.0','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','SUPPORTS_MACCATALYST':'NO','LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/Frameworks']})
icon_phase=put('prepare-icons',isa='PBXShellScriptBuildPhase',buildActionMask=2147483647,files=[],
 inputPaths=['$(SRCROOT)/scripts/prepare_icons.sh']+['$(SRCROOT)/Vesper/Resources/Assets.xcassets/'+c+'Emblem.imageset/image.jpeg' for c in ['White','Black']],
 outputPaths=['$(SRCROOT)/Vesper/Resources/Assets.xcassets/AppIcon'+c+'.appiconset/icon.png' for c in ['White','Black']],
 shellPath='/bin/bash',shellScript='bash "$SRCROOT/scripts/prepare_icons.sh"',runOnlyForDeploymentPostprocessing=0)
app_target=put('app-target',isa='PBXNativeTarget',buildConfigurationList=app_config,buildPhases=[icon_phase,sources_phase,frameworks_phase,resources_phase],buildRules=[],dependencies=[],packageProductDependencies=[zip_product],name='Vesper',productName='Vesper',productReference=app,productType='com.apple.product-type.application')
proxy=put('test-proxy',isa='PBXContainerItemProxy',containerPortal=uid('project'),proxyType=1,remoteGlobalIDString=app_target,remoteInfo='Vesper')
dep=put('test-dep',isa='PBXTargetDependency',target=app_target,targetProxy=proxy)
test_config=configs('test',{'PRODUCT_BUNDLE_IDENTIFIER':'com.vera.vesper.native.tests','PRODUCT_NAME':'$(TARGET_NAME)','GENERATE_INFOPLIST_FILE':'YES','TEST_HOST':'$(BUILT_PRODUCTS_DIR)/Vesper.app/Vesper','BUNDLE_LOADER':'$(TEST_HOST)','CODE_SIGN_STYLE':'Automatic'})
test_target=put('test-target',isa='PBXNativeTarget',buildConfigurationList=test_config,buildPhases=[tests_phase,test_frameworks],buildRules=[],dependencies=[dep],packageProductDependencies=[zip_product],name='VesperTests',productName='VesperTests',productReference=test_product,productType='com.apple.product-type.bundle.unit-test')
# Widget extension reads app snapshots through an App Group; no server token is shared.
widget_ref=ref('VesperWidgets/VesperWidgets.swift','sourcecode.swift')
widget_assets=ref('VesperWidgets/Assets.xcassets','folder.assetcatalog')
widget_info=ref('VesperWidgets/Info.plist','text.plist.xml')
widget_product=put('widget-product',isa='PBXFileReference',explicitFileType='wrapper.app-extension',path='VesperWidgets.appex',sourceTree='BUILT_PRODUCTS_DIR',includeInIndex=0)
widget_group=put('widget-group',isa='PBXGroup',children=[widget_ref,widget_assets,widget_info],name='Widgets',sourceTree='<group>')
objects[main]['children'].append(widget_group)
objects[products]['children'].append(widget_product)
widget_sources=phase('widget-sources','PBXSourcesBuildPhase',[put('widget-source-build',isa='PBXBuildFile',fileRef=widget_ref),put('shared-widget-build',isa='PBXBuildFile',fileRef=shared_ref),put('call-activity-widget-build',isa='PBXBuildFile',fileRef=call_activity_ref)])
widget_resources=phase('widget-resources','PBXResourcesBuildPhase',[put('widget-assets-build',isa='PBXBuildFile',fileRef=widget_assets)])
widget_config=configs('widget',{'PRODUCT_BUNDLE_IDENTIFIER':'com.vera.vesper.native.widgets','PRODUCT_NAME':'$(TARGET_NAME)','CODE_SIGN_STYLE':'Automatic','INFOPLIST_FILE':'VesperWidgets/Info.plist','CODE_SIGN_ENTITLEMENTS':'VesperWidgets/VesperWidgets.entitlements','CURRENT_PROJECT_VERSION':'7','MARKETING_VERSION':'0.1.0','SKIP_INSTALL':'YES','APPLICATION_EXTENSION_API_ONLY':'YES','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/Frameworks','@executable_path/../../Frameworks']})
widget_target=put('widget-target',isa='PBXNativeTarget',buildConfigurationList=widget_config,buildPhases=[widget_sources,widget_resources],buildRules=[],dependencies=[],name='VesperWidgets',productName='VesperWidgets',productReference=widget_product,productType='com.apple.product-type.app-extension')
widget_proxy=put('widget-proxy',isa='PBXContainerItemProxy',containerPortal=uid('project'),proxyType=1,remoteGlobalIDString=widget_target,remoteInfo='VesperWidgets')
widget_dep=put('widget-dependency',isa='PBXTargetDependency',target=widget_target,targetProxy=widget_proxy)
embed_file=put('widget-embed-file',isa='PBXBuildFile',fileRef=widget_product,settings={'ATTRIBUTES':['RemoveHeadersOnCopy']})
embed=put('widget-embed',isa='PBXCopyFilesBuildPhase',buildActionMask=2147483647,dstPath='',dstSubfolderSpec=13,files=[embed_file],name='Embed Foundation Extensions',runOnlyForDeploymentPostprocessing=0)
objects[app_target]['buildPhases'].append(embed)
objects[app_target]['dependencies'].append(widget_dep)
# ReplayKit cross-app upload extension.
broadcast_source=ref('VesperBroadcast/SampleHandler.swift','sourcecode.swift')
broadcast_info=ref('VesperBroadcast/Info.plist','text.plist.xml')
broadcast_product=put('broadcast-product',isa='PBXFileReference',explicitFileType='wrapper.app-extension',path='VesperBroadcast.appex',sourceTree='BUILT_PRODUCTS_DIR',includeInIndex=0)
objects[main]['children'].append(put('broadcast-group',isa='PBXGroup',children=[broadcast_source,broadcast_info],name='Broadcast',sourceTree='<group>'))
objects[products]['children'].append(broadcast_product)
broadcast_sources=phase('broadcast-sources','PBXSourcesBuildPhase',[put('broadcast-source-build',isa='PBXBuildFile',fileRef=broadcast_source),put('broadcast-access-build',isa='PBXBuildFile',fileRef=broadcast_access)])
broadcast_config=configs('broadcast',{'PRODUCT_BUNDLE_IDENTIFIER':'com.vera.vesper.native.broadcast','PRODUCT_NAME':'$(TARGET_NAME)','CODE_SIGN_STYLE':'Automatic','INFOPLIST_FILE':'VesperBroadcast/Info.plist','CODE_SIGN_ENTITLEMENTS':'VesperBroadcast/VesperBroadcast.entitlements','CURRENT_PROJECT_VERSION':'7','MARKETING_VERSION':'0.1.0','SKIP_INSTALL':'YES','APPLICATION_EXTENSION_API_ONLY':'YES','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/Frameworks','@executable_path/../../Frameworks']})
broadcast_target=put('broadcast-target',isa='PBXNativeTarget',buildConfigurationList=broadcast_config,buildPhases=[broadcast_sources],buildRules=[],dependencies=[],name='VesperBroadcast',productName='VesperBroadcast',productReference=broadcast_product,productType='com.apple.product-type.app-extension')
broadcast_proxy=put('broadcast-proxy',isa='PBXContainerItemProxy',containerPortal=uid('project'),proxyType=1,remoteGlobalIDString=broadcast_target,remoteInfo='VesperBroadcast')
objects[app_target]['dependencies'].append(put('broadcast-dep',isa='PBXTargetDependency',target=broadcast_target,targetProxy=broadcast_proxy))
objects[embed]['files'].append(put('broadcast-embed-file',isa='PBXBuildFile',fileRef=broadcast_product,settings={'ATTRIBUTES':['RemoveHeadersOnCopy']}))
# Derive desktop privacy strings without changing the iPhone plist.
mac_info=plistlib.loads((root/'Vesper/Info.plist').read_bytes())
for key in ['BroadcastKeychainGroup','NSHealthShareUsageDescription','NSAlarmKitUsageDescription','NSSupportsLiveActivities']:
 mac_info.pop(key,None)
mac_info['CFBundleDisplayName']='Vesper Mac'
mac_info['NSLocationUsageDescription']='Show local weather and share location from this Mac only when you request it.'
mac_info['NSScreenCaptureUsageDescription']='Share the Mac display you choose with your Vesper chat companion.'
(root/'Vesper/Mac-Info.plist').write_bytes(plistlib.dumps(mac_info))
# Mac Catalyst has its own product and entitlements; iOS extensions stay on iOS.
mac_product=put('mac-product',isa='PBXFileReference',explicitFileType='wrapper.application',path='Vesper Mac.app',sourceTree='BUILT_PRODUCTS_DIR',includeInIndex=0)
objects[products]['children'].append(mac_product)
mac_config=configs('mac',{'IPHONEOS_DEPLOYMENT_TARGET':'26.0','PRODUCT_BUNDLE_IDENTIFIER':'com.vera.vesper.mac','PRODUCT_NAME':'Vesper Mac','ENABLE_USER_SCRIPT_SANDBOXING':'NO','CODE_SIGN_STYLE':'Automatic','CODE_SIGN_IDENTITY':'Apple Development','DEVELOPMENT_TEAM':'5AYW37S3Z5','INFOPLIST_FILE':'Vesper/Mac-Info.plist','CODE_SIGN_ENTITLEMENTS':'Vesper/Mac.entitlements','ASSETCATALOG_COMPILER_APPICON_NAME':'AppIconWhite','CURRENT_PROJECT_VERSION':'7','MARKETING_VERSION':'0.1.0','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator macosx','SUPPORTS_MACCATALYST':'YES','DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER':'NO','SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD':'NO','TARGETED_DEVICE_FAMILY':'2','ENABLE_HARDENED_RUNTIME':'YES','LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/../Frameworks']})
mac_credentials=put('mac-credentials',isa='PBXShellScriptBuildPhase',buildActionMask=2147483647,files=[],
 name='Build Mac credential helper',inputPaths=['$(SRCROOT)/MacCredentials/main.swift','$(SRCROOT)/MacCredentials/Helper.entitlements','$(SRCROOT)/scripts/build_mac_credentials.sh'],
 outputPaths=['$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/VesperCredentials'],
 shellPath='/bin/bash',shellScript='bash "$SRCROOT/scripts/build_mac_credentials.sh"',runOnlyForDeploymentPostprocessing=0)
mac_frameworks=phase('mac-frameworks','PBXFrameworksBuildPhase',[put('zipfoundation-mac-build',isa='PBXBuildFile',productRef=zip_product)])
mac_target=put('mac-target',isa='PBXNativeTarget',buildConfigurationList=mac_config,buildPhases=[phase('mac-sources','PBXSourcesBuildPhase',source_build),mac_frameworks,phase('mac-resources','PBXResourcesBuildPhase',resource_build),mac_credentials],buildRules=[],dependencies=[],packageProductDependencies=[zip_product],name='VesperMac',productName='Vesper Mac',productReference=mac_product,productType='com.apple.product-type.application')
project=put('project',isa='PBXProject',attributes={'BuildIndependentTargetsInParallel':'YES','LastUpgradeCheck':'2700','TargetAttributes':{app_target:{'CreatedOnToolsVersion':'16.0'},test_target:{'CreatedOnToolsVersion':'16.0','TestTargetID':app_target}}},buildConfigurationList=project_config,compatibilityVersion='Xcode 14.0',developmentRegion='en',hasScannedForEncodings=0,knownRegions=['en','Base'],mainGroup=main,packageReferences=[zip_package],productRefGroup=products,projectDirPath='',projectRoot='',targets=[app_target,test_target,widget_target,broadcast_target,mac_target])
# Keep the watch app and its complications in generated projects too.
watch_sources = [ref('VesperWatch/' + name, 'sourcecode.swift') for name in ['VesperWatchApp.swift', 'WatchWidgetSettings.swift', 'WatchWidgets.swift']]
watch_assets = ref('VesperWatch/Assets.xcassets', 'folder.assetcatalog')
watch_product = put('watch-product', isa='PBXFileReference', explicitFileType='wrapper.application', path='Vesper Watch.app', sourceTree='BUILT_PRODUCTS_DIR', includeInIndex=0)
watch_widget_product = put('watch-widget-product', isa='PBXFileReference', explicitFileType='wrapper.app-extension', path='VesperWatchWidgets.appex', sourceTree='BUILT_PRODUCTS_DIR', includeInIndex=0)
objects[products]['children'] += [watch_product, watch_widget_product]
objects[main]['children'].append(put('watch-group', isa='PBXGroup', children=watch_sources + [watch_assets, ref('VesperWatch/Info.plist', 'text.plist.xml'), ref('VesperWatch/WidgetInfo.plist', 'text.plist.xml')], name='Watch', sourceTree='<group>'))
watch_common = {'SDKROOT':'watchos', 'SUPPORTED_PLATFORMS':'watchos watchsimulator', 'WATCHOS_DEPLOYMENT_TARGET':'10.0', 'TARGETED_DEVICE_FAMILY':'4', 'PRODUCT_NAME':'$(TARGET_NAME)', 'CODE_SIGN_STYLE':'Automatic', 'DEVELOPMENT_TEAM':'5AYW37S3Z5', 'CURRENT_PROJECT_VERSION':'7', 'MARKETING_VERSION':'0.1.0', 'SKIP_INSTALL':'YES', 'LD_RUNPATH_SEARCH_PATHS':['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']}
watch_config = configs('watch', dict(watch_common, PRODUCT_BUNDLE_IDENTIFIER='com.vera.vesper.native.watchkitapp', INFOPLIST_FILE='VesperWatch/Info.plist', CODE_SIGN_ENTITLEMENTS='VesperWatch/VesperWatch.entitlements', ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon'))
watch_widget_config = configs('watch-widget', dict(watch_common, PRODUCT_BUNDLE_IDENTIFIER='com.vera.vesper.native.watchkitapp.widgets', INFOPLIST_FILE='VesperWatch/WidgetInfo.plist', CODE_SIGN_ENTITLEMENTS='VesperWatch/WatchWidgets.entitlements', APPLICATION_EXTENSION_API_ONLY='YES'))
# Preserve the target IDs used by the user's existing shared schemes.
watch_target = 'A90100000000000000000007'
watch_widget_target = 'A9010000000000000000001C'
objects[watch_widget_target] = dict(isa='PBXNativeTarget', buildConfigurationList=watch_widget_config, buildPhases=[phase('watch-widget-sources', 'PBXSourcesBuildPhase', [put('watch-widget-source-'+str(i), isa='PBXBuildFile', fileRef=watch_sources[i]) for i in [1,2]])], buildRules=[], dependencies=[], name='VesperWatchWidgets', productName='VesperWatchWidgets', productReference=watch_widget_product, productType='com.apple.product-type.app-extension')
watch_widget_proxy = put('watch-widget-proxy', isa='PBXContainerItemProxy', containerPortal=uid('project'), proxyType=1, remoteGlobalIDString=watch_widget_target, remoteInfo='VesperWatchWidgets')
watch_widget_dep = put('watch-widget-dep', isa='PBXTargetDependency', target=watch_widget_target, targetProxy=watch_widget_proxy)
watch_widget_embed = put('watch-widget-embed', isa='PBXCopyFilesBuildPhase', buildActionMask=2147483647, dstPath='', dstSubfolderSpec=13, files=[put('watch-widget-embed-file', isa='PBXBuildFile', fileRef=watch_widget_product, settings={'ATTRIBUTES':['RemoveHeadersOnCopy']})], name='Embed Watch Widgets', runOnlyForDeploymentPostprocessing=0)
objects[watch_target] = dict(isa='PBXNativeTarget', buildConfigurationList=watch_config, buildPhases=[phase('watch-sources','PBXSourcesBuildPhase',[put('watch-source-'+str(i), isa='PBXBuildFile', fileRef=watch_sources[i]) for i in [0,1]]), phase('watch-resources','PBXResourcesBuildPhase',[put('watch-assets-build',isa='PBXBuildFile',fileRef=watch_assets)]), watch_widget_embed], buildRules=[], dependencies=[watch_widget_dep], name='Vesper Watch', productName='Vesper Watch', productReference=watch_product, productType='com.apple.product-type.application')
watch_proxy=put('watch-proxy',isa='PBXContainerItemProxy',containerPortal=uid('project'),proxyType=1,remoteGlobalIDString=watch_target,remoteInfo='Vesper Watch')
# Embed the companion so iOS registers the WatchConnectivity association.
watch_dep=put('watch-dep',isa='PBXTargetDependency',target=watch_target,targetProxy=watch_proxy)
watch_embed=put('watch-embed',isa='PBXCopyFilesBuildPhase',buildActionMask=2147483647,dstPath='$(CONTENTS_FOLDER_PATH)/Watch',dstSubfolderSpec=16,files=[put('watch-embed-file',isa='PBXBuildFile',fileRef=watch_product,settings={'ATTRIBUTES':['RemoveHeadersOnCopy']})],name='Embed Watch Content',runOnlyForDeploymentPostprocessing=0)
objects[app_target]['dependencies'].append(watch_dep)
objects[app_target]['buildPhases'].append(watch_embed)
objects[project]['targets'] += [watch_target,watch_widget_target]

def serialize(v,level=0):
 if isinstance(v,dict):return '{\n'+''.join('\t'*(level+1)+json.dumps(str(k))+' = '+serialize(x,level+1)+';\n' for k,x in v.items())+'\t'*level+'}'
 if isinstance(v,list):return '( '+', '.join(serialize(x,level) for x in v)+', )' if v else '()'
 return str(v) if isinstance(v,int) else json.dumps(v)
folder=root/'Vesper.xcodeproj';folder.mkdir(exist_ok=True)
(folder/'project.pbxproj').write_text('// !$*UTF8*$!\n'+serialize({'archiveVersion':1,'classes':{},'objectVersion':56,'objects':objects,'rootObject':project})+'\n')
shared=folder/'xcshareddata/xcschemes';shared.mkdir(parents=True,exist_ok=True)
def buildref(target,name):return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:Vesper.xcodeproj"/>'
(shared/'Vesper.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildref(app_target,'Vesper.app')}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{buildref(test_target,'VesperTests.xctest')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildref(app_target,'Vesper.app')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildref(app_target,'Vesper.app')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(f'Generated project with {len(source_refs)} Swift sources and {len(testrefs)} test files')

macref=buildref(mac_target,'Vesper Mac.app').replace('BlueprintName="Vesper Mac"','BlueprintName="VesperMac"')
(shared/'VesperMac.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="NO" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{macref}</BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{macref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{macref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
