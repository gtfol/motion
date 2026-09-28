#!/usr/bin/env python3
"""Regenerate the checked-in Xcode project using only Python's standard library.

Adapted from capsule's generator (gtfol/capsule apps/ios/scripts/generate-project.py). The output is
deterministic; CI regenerates it and fails if the committed project differs.
"""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]

# Adjustable identity. The bundle identifier is a project setting, not a settled App Store identifier.
BUNDLE_IDENTIFIER = 'dev.gtfol.vitals'
MARKETING_VERSION = '0.1'
CURRENT_PROJECT_VERSION = '1'

objects = {}
def uid(name): return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def add(name, value):
    key = uid(name); objects[key] = value; return key

def serialize(value, indent=0):
    if isinstance(value, dict):
        return '{\n' + ''.join('\t'*(indent+1) + k + ' = ' + serialize(v, indent+1) + ';\n' for k, v in value.items()) + '\t'*indent + '}'
    if isinstance(value, list): return '(' + ', '.join(serialize(v, indent) for v in value) + (',' if value else '') + ')'
    return json.dumps(str(value))

def reference(rel, kind):
    return add(rel, {'isa': 'PBXFileReference', 'lastKnownFileType': kind, 'name': Path(rel).name, 'path': rel, 'sourceTree': '<group>'})

files = {}
for path in sorted(root.glob('Vitals/**/*.swift')):
    rel = str(path.relative_to(root)); files[rel] = reference(rel, 'sourcecode.swift')
for path in sorted(root.glob('VitalsTests/*.swift')):
    rel = str(path.relative_to(root)); files[rel] = reference(rel, 'sourcecode.swift')
for path in sorted(root.glob('VitalsUITests/*.swift')):
    rel = str(path.relative_to(root)); files[rel] = reference(rel, 'sourcecode.swift')
assets = reference('Vitals/Assets.xcassets', 'folder.assetcatalog')
info = reference('Vitals/Info.plist', 'text.plist.xml')
entitlements = reference('Vitals/Vitals.entitlements', 'text.plist.entitlements')
bundled = [reference(str(path.relative_to(root)), 'file') for path in sorted(root.glob('Vitals/Resources/*'))]
app = add('app-product', {'isa': 'PBXFileReference', 'explicitFileType': 'wrapper.application', 'path': 'Vitals.app', 'sourceTree': 'BUILT_PRODUCTS_DIR'})
tests = add('test-product', {'isa': 'PBXFileReference', 'explicitFileType': 'wrapper.cfbundle', 'path': 'VitalsTests.xctest', 'sourceTree': 'BUILT_PRODUCTS_DIR'})
uitests = add('uitest-product', {'isa': 'PBXFileReference', 'explicitFileType': 'wrapper.cfbundle', 'path': 'VitalsUITests.xctest', 'sourceTree': 'BUILT_PRODUCTS_DIR'})
products = add('products', {'isa': 'PBXGroup', 'children': [app, tests, uitests], 'name': 'Products', 'sourceTree': '<group>'})

def group(name, prefix):
    children = [v for k, v in files.items() if k.startswith(prefix) and '/' not in k[len(prefix):]]
    return children

app_sources = [v for k, v in files.items() if k.startswith('Vitals/')]
test_sources = [v for k, v in files.items() if k.startswith('VitalsTests/')]
uitest_sources = [v for k, v in files.items() if k.startswith('VitalsUITests/')]
subgroups = []
for folder in sorted({str(Path(k).parent) for k in files if k.startswith('Vitals/') and str(Path(k).parent) != 'Vitals'}):
    subgroups.append(add('group-' + folder, {'isa': 'PBXGroup', 'children': group(folder, folder + '/'), 'name': Path(folder).name, 'sourceTree': '<group>'}))
resource_group = add('group-resources', {'isa': 'PBXGroup', 'children': bundled, 'name': 'Resources', 'sourceTree': '<group>'})
appgroup = add('app-group', {'isa': 'PBXGroup', 'children': group('Vitals', 'Vitals/') + subgroups + [resource_group, assets, info, entitlements],
                             'name': 'Vitals', 'sourceTree': '<group>'})
testgroup = add('test-group', {'isa': 'PBXGroup', 'children': test_sources, 'name': 'VitalsTests', 'sourceTree': '<group>'})
uitestgroup = add('uitest-group', {'isa': 'PBXGroup', 'children': uitest_sources, 'name': 'VitalsUITests', 'sourceTree': '<group>'})
main = add('main-group', {'isa': 'PBXGroup', 'children': [appgroup, testgroup, uitestgroup, products], 'sourceTree': '<group>'})

def phase(name, isa, refs):
    builds = [add(name + ref, {'isa': 'PBXBuildFile', 'fileRef': ref}) for ref in refs]
    return add(name, {'isa': isa, 'buildActionMask': '2147483647', 'files': builds, 'runOnlyForDeploymentPostprocessing': '0'})

appSources = phase('app-sources', 'PBXSourcesBuildPhase', app_sources)
testSources = phase('test-sources', 'PBXSourcesBuildPhase', test_sources)
uitestSources = phase('uitest-sources', 'PBXSourcesBuildPhase', uitest_sources)
resources = phase('resources', 'PBXResourcesBuildPhase', [assets] + bundled)
appFrameworks = phase('app-frameworks', 'PBXFrameworksBuildPhase', [])
testFrameworks = phase('test-frameworks', 'PBXFrameworksBuildPhase', [])
uitestFrameworks = phase('uitest-frameworks', 'PBXFrameworksBuildPhase', [])

common = {'COPY_PHASE_STRIP': 'NO', 'LM_SKIP_METADATA_EXTRACTION': 'YES', 'CLANG_ENABLE_MODULES': 'YES', 'CLANG_ENABLE_OBJC_ARC': 'YES',
          'GCC_C_LANGUAGE_STANDARD': 'gnu17', 'CLANG_CXX_LANGUAGE_STANDARD': 'gnu++20', 'IPHONEOS_DEPLOYMENT_TARGET': '17.0',
          'SDKROOT': 'iphoneos', 'SWIFT_VERSION': '6.0', 'SWIFT_STRICT_CONCURRENCY': 'complete', 'ENABLE_USER_SCRIPT_SANDBOXING': 'YES',
          'GCC_WARN_ABOUT_RETURN_TYPE': 'YES_ERROR', 'GCC_WARN_UNINITIALIZED_AUTOS': 'YES_AGGRESSIVE',
          'CLANG_WARN_DOCUMENTATION_COMMENTS': 'YES', 'CLANG_WARN_UNREACHABLE_CODE': 'YES', 'SWIFT_TREAT_WARNINGS_AS_ERRORS': 'YES',
          'VITALS_BUNDLE_IDENTIFIER': BUNDLE_IDENTIFIER}
appSettings = {'PRODUCT_NAME': '$(TARGET_NAME)', 'PRODUCT_BUNDLE_IDENTIFIER': '$(VITALS_BUNDLE_IDENTIFIER)', 'TARGETED_DEVICE_FAMILY': '1',
               'SUPPORTED_PLATFORMS': 'iphoneos iphonesimulator', 'SUPPORTS_MACCATALYST': 'NO', 'SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD': 'NO',
               'SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD': 'NO', 'CODE_SIGN_STYLE': 'Automatic', 'CODE_SIGN_ENTITLEMENTS': 'Vitals/Vitals.entitlements',
               'INFOPLIST_FILE': 'Vitals/Info.plist', 'GENERATE_INFOPLIST_FILE': 'NO', 'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon',
               'MARKETING_VERSION': MARKETING_VERSION, 'CURRENT_PROJECT_VERSION': CURRENT_PROJECT_VERSION,
               'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/Frameworks']}
testSettings = {'PRODUCT_NAME': '$(TARGET_NAME)', 'PRODUCT_BUNDLE_IDENTIFIER': '$(VITALS_BUNDLE_IDENTIFIER).tests', 'TARGETED_DEVICE_FAMILY': '1',
                'SUPPORTED_PLATFORMS': 'iphoneos iphonesimulator', 'CODE_SIGN_STYLE': 'Automatic', 'GENERATE_INFOPLIST_FILE': 'YES',
                'TEST_HOST': '$(BUILT_PRODUCTS_DIR)/Vitals.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Vitals', 'BUNDLE_LOADER': '$(TEST_HOST)',
                'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks']}
uitestSettings = {'PRODUCT_NAME': '$(TARGET_NAME)', 'PRODUCT_BUNDLE_IDENTIFIER': '$(VITALS_BUNDLE_IDENTIFIER).uitests', 'TARGETED_DEVICE_FAMILY': '1',
                  'SUPPORTED_PLATFORMS': 'iphoneos iphonesimulator', 'CODE_SIGN_STYLE': 'Automatic', 'GENERATE_INFOPLIST_FILE': 'YES',
                  'TEST_TARGET_NAME': 'Vitals', 'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks']}

def configs(name, settings):
    refs = []
    for config in ['Debug', 'Release']:
        values = dict(settings)
        if name == 'project':
            values.update({'DEBUG_INFORMATION_FORMAT': 'dwarf' if config == 'Debug' else 'dwarf-with-dsym',
                           'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if config == 'Debug' else '-O',
                           'ONLY_ACTIVE_ARCH': 'YES' if config == 'Debug' else 'NO', 'ENABLE_TESTABILITY': 'YES' if config == 'Debug' else 'NO'})
            if config == 'Debug': values['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG $(inherited)'
            else: values['SWIFT_COMPILATION_MODE'] = 'wholemodule'
        refs.append(add(name + config, {'isa': 'XCBuildConfiguration', 'buildSettings': values, 'name': config}))
    return add(name + 'configs', {'isa': 'XCConfigurationList', 'buildConfigurations': refs, 'defaultConfigurationIsVisible': '0',
                                  'defaultConfigurationName': 'Release'})

projectConfigs = configs('project', common)
appConfigs = configs('app', appSettings)
testConfigs = configs('tests', testSettings)
uitestConfigs = configs('uitests', uitestSettings)
appTarget = add('app-target', {'isa': 'PBXNativeTarget', 'buildConfigurationList': appConfigs, 'buildPhases': [appSources, appFrameworks, resources],
                               'buildRules': [], 'dependencies': [], 'name': 'Vitals', 'productName': 'Vitals', 'productReference': app,
                               'productType': 'com.apple.product-type.application'})
proxy = add('test-proxy', {'isa': 'PBXContainerItemProxy', 'containerPortal': uid('project'), 'proxyType': '1', 'remoteGlobalIDString': appTarget,
                           'remoteInfo': 'Vitals'})
dep = add('test-dependency', {'isa': 'PBXTargetDependency', 'target': appTarget, 'targetProxy': proxy})
testTarget = add('test-target', {'isa': 'PBXNativeTarget', 'buildConfigurationList': testConfigs, 'buildPhases': [testSources, testFrameworks],
                                 'buildRules': [], 'dependencies': [dep], 'name': 'VitalsTests', 'productName': 'VitalsTests',
                                 'productReference': tests, 'productType': 'com.apple.product-type.bundle.unit-test'})
uiproxy = add('uitest-proxy', {'isa': 'PBXContainerItemProxy', 'containerPortal': uid('project'), 'proxyType': '1', 'remoteGlobalIDString': appTarget,
                               'remoteInfo': 'Vitals'})
uidep = add('uitest-dependency', {'isa': 'PBXTargetDependency', 'target': appTarget, 'targetProxy': uiproxy})
uitestTarget = add('uitest-target', {'isa': 'PBXNativeTarget', 'buildConfigurationList': uitestConfigs, 'buildPhases': [uitestSources, uitestFrameworks],
                                     'buildRules': [], 'dependencies': [uidep], 'name': 'VitalsUITests', 'productName': 'VitalsUITests',
                                     'productReference': uitests, 'productType': 'com.apple.product-type.bundle.ui-testing'})
project = add('project', {'isa': 'PBXProject',
                          'attributes': {'BuildIndependentTargetsInParallel': 'YES', 'LastUpgradeCheck': '2660',
                                         'TargetAttributes': {appTarget: {'CreatedOnToolsVersion': '26.6'},
                                                              testTarget: {'CreatedOnToolsVersion': '26.6', 'TestTargetID': appTarget},
                                                              uitestTarget: {'CreatedOnToolsVersion': '26.6', 'TestTargetID': appTarget}}},
                          'buildConfigurationList': projectConfigs, 'compatibilityVersion': 'Xcode 14.0', 'developmentRegion': 'en',
                          'hasScannedForEncodings': '0', 'knownRegions': ['en', 'Base'], 'mainGroup': main, 'productRefGroup': products,
                          'projectDirPath': '', 'projectRoot': '', 'targets': [appTarget, testTarget, uitestTarget]})
output = '// !$*UTF8*$!\n' + serialize({'archiveVersion': '1', 'classes': {}, 'objectVersion': '56', 'objects': objects, 'rootObject': project}) + '\n'
(root / 'Vitals.xcodeproj').mkdir(exist_ok=True)
(root / 'Vitals.xcodeproj/project.pbxproj').write_text(output)

def buildable(identifier, name, product):
    return (f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{identifier}" BuildableName="{product}" '
            f'BlueprintName="{name}" ReferencedContainer="container:Vitals.xcodeproj"/>')
a = buildable(appTarget, 'Vitals', 'Vitals.app'); t = buildable(testTarget, 'VitalsTests', 'VitalsTests.xctest')
u = buildable(uitestTarget, 'VitalsUITests', 'VitalsUITests.xctest')
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2660" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{a}</BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO" parallelizable="NO">{t}</TestableReference><TestableReference skipped="NO" parallelizable="NO">{u}</TestableReference></Testables></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="NO"><BuildableProductRunnable runnableDebuggingMode="0">{a}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{a}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
(root / 'Vitals.xcodeproj/xcshareddata/xcschemes').mkdir(parents=True, exist_ok=True)
(root / 'Vitals.xcodeproj/xcshareddata/xcschemes/Vitals.xcscheme').write_text(scheme)
