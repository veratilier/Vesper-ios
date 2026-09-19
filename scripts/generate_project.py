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
for path,kind in [('Vesper/Resources/Assets.xcassets','folder.assetcatalog'),('Vesper/Resources/Ballet.ttf','file'),('Vesper/Resources/Ballet-OFL.txt','text')]:
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
tests_phase=phase('tests-phase','PBXSourcesBuildPhase',testbuild)
def configs(name,base):
 refs=[]
 for mode in ['Debug','Release']:
  settings=dict(base)
  settings['SWIFT_OPTIMIZATION_LEVEL']='-Onone' if mode=='Debug' else '-O'
  if mode=='Debug':settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='DEBUG $(inherited)';settings['ENABLE_TESTABILITY']='YES'
  refs.append(put(name+mode,isa='XCBuildConfiguration',buildSettings=settings,name=mode))
 return put(name+'configs',isa='XCConfigurationList',buildConfigurations=refs,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
common={'IPHONEOS_DEPLOYMENT_TARGET':'17.0','SDKROOT':'iphoneos','SWIFT_VERSION':'5.0','CLANG_ENABLE_MODULES':'YES','CLANG_ENABLE_OBJC_ARC':'YES','TARGETED_DEVICE_FAMILY':'1,2'}
project_config=configs('project',common)
app_config=configs('app',{'PRODUCT_BUNDLE_IDENTIFIER':'com.vera.vesper.native','PRODUCT_NAME':'$(TARGET_NAME)','CODE_SIGN_STYLE':'Automatic','INFOPLIST_FILE':'Vesper/Info.plist','CODE_SIGN_ENTITLEMENTS':'Vesper/Vesper.entitlements','ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES':['AppIconWhite','AppIconBlack'],'ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS':'YES','CURRENT_PROJECT_VERSION':'1','MARKETING_VERSION':'0.1.0','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','SUPPORTS_MACCATALYST':'NO','LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/Frameworks']})
icon_phase=put('prepare-icons',isa='PBXShellScriptBuildPhase',buildActionMask=2147483647,files=[],
 inputPaths=['$(SRCROOT)/scripts/prepare_icons.sh']+['$(SRCROOT)/Vesper/Resources/Assets.xcassets/'+c+'Emblem.imageset/image.jpeg' for c in ['White','Black']],
 outputPaths=['$(SRCROOT)/Vesper/Resources/Assets.xcassets/AppIcon'+c+'.appiconset/icon.png' for c in ['White','Black']],
 shellPath='/bin/bash',shellScript='bash "$SRCROOT/scripts/prepare_icons.sh"',runOnlyForDeploymentPostprocessing=0)
app_target=put('app-target',isa='PBXNativeTarget',buildConfigurationList=app_config,buildPhases=[icon_phase,sources_phase,frameworks_phase,resources_phase],buildRules=[],dependencies=[],name='Vesper',productName='Vesper',productReference=app,productType='com.apple.product-type.application')
proxy=put('test-proxy',isa='PBXContainerItemProxy',containerPortal=uid('project'),proxyType=1,remoteGlobalIDString=app_target,remoteInfo='Vesper')
dep=put('test-dep',isa='PBXTargetDependency',target=app_target,targetProxy=proxy)
test_config=configs('test',{'PRODUCT_BUNDLE_IDENTIFIER':'com.vera.vesper.native.tests','PRODUCT_NAME':'$(TARGET_NAME)','GENERATE_INFOPLIST_FILE':'YES','TEST_HOST':'$(BUILT_PRODUCTS_DIR)/Vesper.app/Vesper','BUNDLE_LOADER':'$(TEST_HOST)','CODE_SIGN_STYLE':'Automatic'})
test_target=put('test-target',isa='PBXNativeTarget',buildConfigurationList=test_config,buildPhases=[tests_phase],buildRules=[],dependencies=[dep],name='VesperTests',productName='VesperTests',productReference=test_product,productType='com.apple.product-type.bundle.unit-test')
# Widget extension reads app snapshots through an App Group; no server token is shared.
widget_ref=ref('VesperWidgets/VesperWidgets.swift','sourcecode.swift')
widget_assets=ref('VesperWidgets/Assets.xcassets','folder.assetcatalog')
widget_info=ref('VesperWidgets/Info.plist','text.plist.xml')
widget_product=put('widget-product',isa='PBXFileReference',explicitFileType='wrapper.app-extension',path='VesperWidgets.appex',sourceTree='BUILT_PRODUCTS_DIR',includeInIndex=0)
widget_group=put('widget-group',isa='PBXGroup',children=[widget_ref,widget_assets,widget_info],name='Widgets',sourceTree='<group>')
objects[main]['children'].append(widget_group)
objects[products]['children'].append(widget_product)
widget_sources=phase('widget-sources','PBXSourcesBuildPhase',[put('widget-source-build',isa='PBXBuildFile',fileRef=widget_ref),put('shared-widget-build',isa='PBXBuildFile',fileRef=shared_ref)])
widget_resources=phase('widget-resources','PBXResourcesBuildPhase',[put('widget-assets-build',isa='PBXBuildFile',fileRef=widget_assets)])
widget_config=configs('widget',{'PRODUCT_BUNDLE_IDENTIFIER':'com.vera.vesper.native.widgets','PRODUCT_NAME':'$(TARGET_NAME)','CODE_SIGN_STYLE':'Automatic','INFOPLIST_FILE':'VesperWidgets/Info.plist','CODE_SIGN_ENTITLEMENTS':'VesperWidgets/VesperWidgets.entitlements','CURRENT_PROJECT_VERSION':'1','MARKETING_VERSION':'0.1.0','SKIP_INSTALL':'YES','APPLICATION_EXTENSION_API_ONLY':'YES','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/Frameworks','@executable_path/../../Frameworks']})
widget_target=put('widget-target',isa='PBXNativeTarget',buildConfigurationList=widget_config,buildPhases=[widget_sources,widget_resources],buildRules=[],dependencies=[],name='VesperWidgets',productName='VesperWidgets',productReference=widget_product,productType='com.apple.product-type.app-extension')
widget_proxy=put('widget-proxy',isa='PBXContainerItemProxy',containerPortal=uid('project'),proxyType=1,remoteGlobalIDString=widget_target,remoteInfo='VesperWidgets')
widget_dep=put('widget-dependency',isa='PBXTargetDependency',target=widget_target,targetProxy=widget_proxy)
embed_file=put('widget-embed-file',isa='PBXBuildFile',fileRef=widget_product,settings={'ATTRIBUTES':['RemoveHeadersOnCopy']})
embed=put('widget-embed',isa='PBXCopyFilesBuildPhase',buildActionMask=2147483647,dstPath='',dstSubfolderSpec=13,files=[embed_file],name='Embed App Extensions',runOnlyForDeploymentPostprocessing=0)
objects[app_target]['buildPhases'].append(embed)
objects[app_target]['dependencies'].append(widget_dep)
# ReplayKit cross-app upload extension.
broadcast_source=ref('VesperBroadcast/SampleHandler.swift','sourcecode.swift')
broadcast_info=ref('VesperBroadcast/Info.plist','text.plist.xml')
broadcast_product=put('broadcast-product',isa='PBXFileReference',explicitFileType='wrapper.app-extension',path='VesperBroadcast.appex',sourceTree='BUILT_PRODUCTS_DIR',includeInIndex=0)
objects[main]['children'].append(put('broadcast-group',isa='PBXGroup',children=[broadcast_source,broadcast_info],name='Broadcast',sourceTree='<group>'))
objects[products]['children'].append(broadcast_product)
broadcast_sources=phase('broadcast-sources','PBXSourcesBuildPhase',[put('broadcast-source-build',isa='PBXBuildFile',fileRef=broadcast_source),put('broadcast-access-build',isa='PBXBuildFile',fileRef=broadcast_access)])
broadcast_config=configs('broadcast',{'PRODUCT_BUNDLE_IDENTIFIER':'com.vera.vesper.native.broadcast','PRODUCT_NAME':'$(TARGET_NAME)','CODE_SIGN_STYLE':'Automatic','INFOPLIST_FILE':'VesperBroadcast/Info.plist','CODE_SIGN_ENTITLEMENTS':'VesperBroadcast/VesperBroadcast.entitlements','CURRENT_PROJECT_VERSION':'1','MARKETING_VERSION':'0.1.0','SKIP_INSTALL':'YES','APPLICATION_EXTENSION_API_ONLY':'YES','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/Frameworks','@executable_path/../../Frameworks']})
broadcast_target=put('broadcast-target',isa='PBXNativeTarget',buildConfigurationList=broadcast_config,buildPhases=[broadcast_sources],buildRules=[],dependencies=[],name='VesperBroadcast',productName='VesperBroadcast',productReference=broadcast_product,productType='com.apple.product-type.app-extension')
broadcast_proxy=put('broadcast-proxy',isa='PBXContainerItemProxy',containerPortal=uid('project'),proxyType=1,remoteGlobalIDString=broadcast_target,remoteInfo='VesperBroadcast')
objects[app_target]['dependencies'].append(put('broadcast-dep',isa='PBXTargetDependency',target=broadcast_target,targetProxy=broadcast_proxy))
objects[embed]['files'].append(put('broadcast-embed-file',isa='PBXBuildFile',fileRef=broadcast_product,settings={'ATTRIBUTES':['RemoveHeadersOnCopy']}))
project=put('project',isa='PBXProject',attributes={'BuildIndependentTargetsInParallel':'YES','LastUpgradeCheck':'1600','TargetAttributes':{app_target:{'CreatedOnToolsVersion':'16.0'},test_target:{'CreatedOnToolsVersion':'16.0','TestTargetID':app_target}}},buildConfigurationList=project_config,compatibilityVersion='Xcode 14.0',developmentRegion='en',hasScannedForEncodings=0,knownRegions=['en','Base'],mainGroup=main,productRefGroup=products,projectDirPath='',projectRoot='',targets=[app_target,test_target,widget_target,broadcast_target])
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
