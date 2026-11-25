#!/usr/bin/env python3
"""Generates KerfKutter.xcodeproj from the Swift files in Sources/ and Tests/.

Run from the repository root after adding or removing Swift files:
    python3 scripts/generate_xcodeproj.py
"""
import hashlib
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def oid(*parts):
    return hashlib.md5("/".join(parts).encode()).hexdigest()[:24].upper()


def q(name):
    """Quotes a value for an old-style plist when it has characters outside the safe set."""
    import re
    return name if re.fullmatch(r"[A-Za-z0-9_$/:.\-]+", name) else '"' + name.replace('"', '\\"') + '"'


def swift_files(rel):
    d = os.path.join(ROOT, rel)
    return sorted(f for f in os.listdir(d) if f.endswith(".swift"))


groups = {
    "KerfKutter": ("Sources/Kerf", swift_files("Sources/Kerf")),
    "KerfCore": ("Sources/KerfCore", swift_files("Sources/KerfCore")),
    "KerfCoreTests": ("Tests/KerfCoreTests", swift_files("Tests/KerfCoreTests")),
}

P = {
    "project": oid("project"),
    "mainGroup": oid("mainGroup"),
    "productsGroup": oid("productsGroup"),
    "app": oid("product", "app"),
    "fw": oid("product", "fw"),
    "tests": oid("product", "tests"),
    "readme": oid("file", "README.md"),
    "package": oid("file", "Package.swift"),
    "assets": oid("file", "Assets.xcassets"),
    "entitlements": oid("file", "KerfKutter.entitlements"),
    "resourcesGroup": oid("group", "Resources"),
}
T = {name: oid("target", name) for name in ["KerfKutter", "KerfCore", "KerfCoreTests"]}

out = []
w = out.append

w("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 56;\n\tobjects = {\n")

# Build files
w("\n/* Begin PBXBuildFile section */\n")
for g, (_, files) in groups.items():
    for f in files:
        w(f"\t\t{oid('bf', g, f)} /* {f} in Sources */ = {{isa = PBXBuildFile; fileRef = {oid('file', g, f)} /* {f} */; }};\n")
w(f"\t\t{oid('bf', 'app-link-fw')} /* KerfCore.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {P['fw']} /* KerfCore.framework */; }};\n")
w(f"\t\t{oid('bf', 'app-embed-fw')} /* KerfCore.framework in Embed Frameworks */ = {{isa = PBXBuildFile; fileRef = {P['fw']} /* KerfCore.framework */; settings = {{ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }}; }};\n")
w(f"\t\t{oid('bf', 'tests-link-fw')} /* KerfCore.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {P['fw']} /* KerfCore.framework */; }};\n")
w(f"\t\t{oid('bf', 'assets')} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {P['assets']} /* Assets.xcassets */; }};\n")
w("/* End PBXBuildFile section */\n")

# Container proxies and dependencies
w("\n/* Begin PBXContainerItemProxy section */\n")
for dep in ["KerfKutter", "KerfCoreTests"]:
    w(f"\t\t{oid('proxy', dep)} /* PBXContainerItemProxy */ = {{\n\t\t\tisa = PBXContainerItemProxy;\n"
      f"\t\t\tcontainerPortal = {P['project']} /* Project object */;\n\t\t\tproxyType = 1;\n"
      f"\t\t\tremoteGlobalIDString = {T['KerfCore']};\n\t\t\tremoteInfo = KerfCore;\n\t\t}};\n")
w("/* End PBXContainerItemProxy section */\n")

w("\n/* Begin PBXCopyFilesBuildPhase section */\n")
w(f"\t\t{oid('phase', 'embed')} /* Embed Frameworks */ = {{\n\t\t\tisa = PBXCopyFilesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
  f"\t\t\tdstPath = \"\";\n\t\t\tdstSubfolderSpec = 10;\n\t\t\tfiles = (\n\t\t\t\t{oid('bf', 'app-embed-fw')} /* KerfCore.framework in Embed Frameworks */,\n"
  f"\t\t\t);\n\t\t\tname = \"Embed Frameworks\";\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
w("/* End PBXCopyFilesBuildPhase section */\n")

# File references
w("\n/* Begin PBXFileReference section */\n")
for g, (_, files) in groups.items():
    for f in files:
        w(f"\t\t{oid('file', g, f)} /* {f} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(f)}; sourceTree = \"<group>\"; }};\n")
w(f"\t\t{P['app']} /* KerfKutter.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = KerfKutter.app; sourceTree = BUILT_PRODUCTS_DIR; }};\n")
w(f"\t\t{P['fw']} /* KerfCore.framework */ = {{isa = PBXFileReference; explicitFileType = wrapper.framework; includeInIndex = 0; path = KerfCore.framework; sourceTree = BUILT_PRODUCTS_DIR; }};\n")
w(f"\t\t{P['tests']} /* KerfCoreTests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = KerfCoreTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};\n")
w(f"\t\t{P['readme']} /* README.md */ = {{isa = PBXFileReference; lastKnownFileType = net.daringfireball.markdown; path = README.md; sourceTree = \"<group>\"; }};\n")
w(f"\t\t{P['package']} /* Package.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Package.swift; sourceTree = \"<group>\"; }};\n")
w(f"\t\t{P['assets']} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = \"<group>\"; }};\n")
w(f"\t\t{P['entitlements']} /* KerfKutter.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = KerfKutter.entitlements; sourceTree = \"<group>\"; }};\n")
w("/* End PBXFileReference section */\n")

# Frameworks phases
w("\n/* Begin PBXFrameworksBuildPhase section */\n")
for name, link in [("KerfKutter", "app-link-fw"), ("KerfCore", None), ("KerfCoreTests", "tests-link-fw")]:
    files = f"\t\t\t\t{oid('bf', link)} /* KerfCore.framework in Frameworks */,\n" if link else ""
    w(f"\t\t{oid('phase', 'fw', name)} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
      f"\t\t\tfiles = (\n{files}\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
w("/* End PBXFrameworksBuildPhase section */\n")

# Groups
w("\n/* Begin PBXGroup section */\n")
w(f"\t\t{P['mainGroup']} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{P['readme']} /* README.md */,\n\t\t\t\t{P['package']} /* Package.swift */,\n")
for g in groups:
    w(f"\t\t\t\t{oid('group', g)} /* {g} */,\n")
w(f"\t\t\t\t{P['resourcesGroup']} /* Resources */,\n")
w(f"\t\t\t\t{P['productsGroup']} /* Products */,\n\t\t\t);\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
w(f"\t\t{P['resourcesGroup']} /* Resources */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{P['assets']} /* Assets.xcassets */,\n"
  f"\t\t\t\t{P['entitlements']} /* KerfKutter.entitlements */,\n\t\t\t);\n\t\t\tpath = Resources;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
for g, (path, files) in groups.items():
    children = "".join(f"\t\t\t\t{oid('file', g, f)} /* {f} */,\n" for f in files)
    w(f"\t\t{oid('group', g)} /* {g} */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{children}\t\t\t);\n"
      f"\t\t\tname = {g};\n\t\t\tpath = {path};\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
w(f"\t\t{P['productsGroup']} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{P['app']} /* KerfKutter.app */,\n"
  f"\t\t\t\t{P['fw']} /* KerfCore.framework */,\n\t\t\t\t{P['tests']} /* KerfCoreTests.xctest */,\n\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
w("/* End PBXGroup section */\n")

# Headers phase for framework (empty, keeps Xcode happy)
w("\n/* Begin PBXHeadersBuildPhase section */\n")
w(f"\t\t{oid('phase', 'headers')} /* Headers */ = {{\n\t\t\tisa = PBXHeadersBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
w("/* End PBXHeadersBuildPhase section */\n")

w("\n/* Begin PBXResourcesBuildPhase section */\n")
w(f"\t\t{oid('phase', 'res', 'KerfKutter')} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
  f"\t\t\tfiles = (\n\t\t\t\t{oid('bf', 'assets')} /* Assets.xcassets in Resources */,\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
w("/* End PBXResourcesBuildPhase section */\n")

# Native targets
specs = {
    "KerfKutter": ("com.apple.product-type.application", P["app"], "KerfKutter.app",
             [oid("phase", "src", "KerfKutter"), oid("phase", "fw", "KerfKutter"), oid("phase", "res", "KerfKutter"), oid("phase", "embed")], ["KerfKutter"]),
    "KerfCore": ("com.apple.product-type.framework", P["fw"], "KerfCore.framework",
                 [oid("phase", "headers"), oid("phase", "src", "KerfCore"), oid("phase", "fw", "KerfCore")], []),
    "KerfCoreTests": ("com.apple.product-type.bundle.unit-test", P["tests"], "KerfCoreTests.xctest",
                      [oid("phase", "src", "KerfCoreTests"), oid("phase", "fw", "KerfCoreTests")], ["KerfCoreTests"]),
}
w("\n/* Begin PBXNativeTarget section */\n")
for name, (ptype, product, pname, phases, deps) in specs.items():
    ph = "".join(f"\t\t\t\t{p},\n" for p in phases)
    dp = "".join(f"\t\t\t\t{oid('dep', d)} /* PBXTargetDependency */,\n" for d in deps)
    w(f"\t\t{T[name]} /* {name} */ = {{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = {oid('cfglist', name)};\n"
      f"\t\t\tbuildPhases = (\n{ph}\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n{dp}\t\t\t);\n"
      f"\t\t\tname = {name};\n\t\t\tproductName = {name};\n\t\t\tproductReference = {product} /* {pname} */;\n\t\t\tproductType = \"{ptype}\";\n\t\t}};\n")
w("/* End PBXNativeTarget section */\n")

# Project
w("\n/* Begin PBXProject section */\n")
w(f"\t\t{P['project']} /* Project object */ = {{\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {{\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n"
  f"\t\t\t\tLastSwiftUpdateCheck = 1500;\n\t\t\t\tLastUpgradeCheck = 1500;\n\t\t\t}};\n"
  f"\t\t\tbuildConfigurationList = {oid('cfglist', 'project')};\n\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n"
  f"\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n"
  f"\t\t\tmainGroup = {P['mainGroup']};\n\t\t\tproductRefGroup = {P['productsGroup']} /* Products */;\n\t\t\tprojectDirPath = \"\";\n\t\t\tprojectRoot = \"\";\n"
  f"\t\t\ttargets = (\n\t\t\t\t{T['KerfKutter']} /* Kerf */,\n\t\t\t\t{T['KerfCore']} /* KerfCore */,\n\t\t\t\t{T['KerfCoreTests']} /* KerfCoreTests */,\n\t\t\t);\n\t\t}};\n")
w("/* End PBXProject section */\n")

# Sources phases
w("\n/* Begin PBXSourcesBuildPhase section */\n")
for g, (_, files) in groups.items():
    fl = "".join(f"\t\t\t\t{oid('bf', g, f)} /* {f} in Sources */,\n" for f in files)
    w(f"\t\t{oid('phase', 'src', g)} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
      f"\t\t\tfiles = (\n{fl}\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
w("/* End PBXSourcesBuildPhase section */\n")

w("\n/* Begin PBXTargetDependency section */\n")
for dep in ["KerfKutter", "KerfCoreTests"]:
    w(f"\t\t{oid('dep', dep)} /* PBXTargetDependency */ = {{\n\t\t\tisa = PBXTargetDependency;\n\t\t\ttarget = {T['KerfCore']} /* KerfCore */;\n"
      f"\t\t\ttargetProxy = {oid('proxy', dep)} /* PBXContainerItemProxy */;\n\t\t}};\n")
w("/* End PBXTargetDependency section */\n")


def settings(d):
    lines = []
    for k in sorted(d):
        v = d[k]
        if isinstance(v, list):
            items = "".join(f"\t\t\t\t\t\"{x}\",\n" for x in v)
            lines.append(f"\t\t\t\t{k} = (\n{items}\t\t\t\t);\n")
        else:
            lines.append(f"\t\t\t\t{k} = \"{v}\";\n")
    return "".join(lines)


BUNDLE_ID = "com.glennbonnetdevelopment.KerfKutter"

# Signing: set your Apple team ID in scripts/team-id.txt (git-ignored) or the KERFKUTTER_TEAM_ID environment
# variable to sign with your team automatically; without one the app is signed to run locally only.
TEAM_ID = os.environ.get("KERFKUTTER_TEAM_ID", "").strip()
_team_file = os.path.join(ROOT, "scripts", "team-id.txt")
if not TEAM_ID and os.path.exists(_team_file):
    TEAM_ID = open(_team_file).read().strip()

common = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ENABLE_MODULES": "YES",
    "CODE_SIGN_IDENTITY": "Apple Development" if TEAM_ID else "-",
    "CODE_SIGN_STYLE": "Automatic" if TEAM_ID else "Manual",
    "DEVELOPMENT_TEAM": TEAM_ID,
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "MACOSX_DEPLOYMENT_TARGET": "14.0",
    "SDKROOT": "macosx",
    "SWIFT_VERSION": "5.0",
}
debug_extra = {"DEBUG_INFORMATION_FORMAT": "dwarf", "ENABLE_TESTABILITY": "YES", "GCC_OPTIMIZATION_LEVEL": "0",
               "ONLY_ACTIVE_ARCH": "YES", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG", "SWIFT_OPTIMIZATION_LEVEL": "-Onone"}
release_extra = {"DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym", "SWIFT_COMPILATION_MODE": "wholemodule", "SWIFT_OPTIMIZATION_LEVEL": "-O"}

target_settings = {
    "KerfKutter": {
        "PRODUCT_NAME": "KerfKutter", "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID, "GENERATE_INFOPLIST_FILE": "YES",
        "INFOPLIST_KEY_CFBundleDisplayName": "KerfKutter", "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.graphics-design",
        "INFOPLIST_KEY_NSHumanReadableCopyright": "", "MARKETING_VERSION": "0.2", "CURRENT_PROJECT_VERSION": "2",
        "ENABLE_HARDENED_RUNTIME": "YES", "ENABLE_APP_SANDBOX": "YES",
        "CODE_SIGN_ENTITLEMENTS": "Resources/KerfKutter.entitlements",
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
        "SWIFT_EMIT_LOC_STRINGS": "YES",
    },
    "KerfCore": {
        "PRODUCT_NAME": "KerfCore", "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID + ".core", "GENERATE_INFOPLIST_FILE": "YES",
        "DEFINES_MODULE": "YES", "DYLIB_COMPATIBILITY_VERSION": "1", "DYLIB_CURRENT_VERSION": "1",
        "DYLIB_INSTALL_NAME_BASE": "@rpath", "INSTALL_PATH": "$(LOCAL_LIBRARY_DIR)/Frameworks", "SKIP_INSTALL": "YES",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks", "@loader_path/Frameworks"],
        "MARKETING_VERSION": "0.2", "CURRENT_PROJECT_VERSION": "2",
    },
    "KerfCoreTests": {
        "PRODUCT_NAME": "KerfCoreTests", "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID + ".core.tests", "GENERATE_INFOPLIST_FILE": "YES",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks", "@loader_path/../Frameworks"],
    },
}

w("\n/* Begin XCBuildConfiguration section */\n")
for owner in ["project"] + list(T):
    for cfg, extra in [("Debug", debug_extra), ("Release", release_extra)]:
        s = dict(common) if owner == "project" else dict(target_settings[owner])
        if owner == "project":
            s.update(extra)
        w(f"\t\t{oid('cfg', owner, cfg)} /* {cfg} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{settings(s)}\t\t\t}};\n\t\t\tname = {cfg};\n\t\t}};\n")
w("/* End XCBuildConfiguration section */\n")

w("\n/* Begin XCConfigurationList section */\n")
for owner in ["project"] + list(T):
    w(f"\t\t{oid('cfglist', owner)} /* Build configuration list */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n"
      f"\t\t\t\t{oid('cfg', owner, 'Debug')} /* Debug */,\n\t\t\t\t{oid('cfg', owner, 'Release')} /* Release */,\n\t\t\t);\n"
      f"\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n")
w("/* End XCConfigurationList section */\n")

w(f"\t}};\n\trootObject = {P['project']} /* Project object */;\n}}\n")

proj = os.path.join(ROOT, "KerfKutter.xcodeproj")
os.makedirs(os.path.join(proj, "xcshareddata", "xcschemes"), exist_ok=True)
with open(os.path.join(proj, "project.pbxproj"), "w") as f:
    f.write("".join(out))

scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1500" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{T['KerfKutter']}" BuildableName = "KerfKutter.app" BlueprintName = "KerfKutter" ReferencedContainer = "container:KerfKutter.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{T['KerfCoreTests']}" BuildableName = "KerfCoreTests.xctest" BlueprintName = "KerfCoreTests" ReferencedContainer = "container:KerfKutter.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{T['KerfKutter']}" BuildableName = "KerfKutter.app" BlueprintName = "KerfKutter" ReferencedContainer = "container:KerfKutter.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
with open(os.path.join(proj, "xcshareddata", "xcschemes", "KerfKutter.xcscheme"), "w") as f:
    f.write(scheme)
print("Wrote", proj)
