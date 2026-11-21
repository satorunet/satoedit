#!/usr/bin/env python3
"""SatoruEditor.xcodeproj を作る (XcodeGen などが使えない Mac でも、xcodebuild でビルドできるように)。

使い方: python3 scripts/gen_xcodeproj.py   (ios/ の中で。ファイルを足したら、もう一度実行する)

ターゲットは 2 つ:
  HinokiCore   … Mac 版と共通の中身 (../mac/Sources/HinokiCore/*.swift をそのまま参照してビルドする静的ライブラリ)
  SatoruEditor … iPhone / iPad のアプリ (SatoruEditor/*.swift)
"""
import hashlib, os, glob

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORE_DIR = os.path.normpath(os.path.join(ROOT, "..", "mac", "Sources", "HinokiCore"))
APP_DIR = os.path.join(ROOT, "SatoruEditor")

BUNDLE_ID = "net.satoru.satoruEditor.ios"
TEAM = "99NFJH4MCR"
VERSION = os.environ.get("SATORU_IOS_VERSION", "1.0.1")
# ビルド番号: App Store に上げるたびに増やす (GitHub の自動ビルドでは実行の番号を入れる)
BUILD = os.environ.get("SATORU_IOS_BUILD", "1")

def uid(*parts):
    return hashlib.md5("/".join(parts).encode()).hexdigest()[:24].upper()

core_files = sorted(os.path.basename(p) for p in glob.glob(os.path.join(CORE_DIR, "*.swift")))
app_files = sorted(os.path.basename(p) for p in glob.glob(os.path.join(APP_DIR, "*.swift")))
has_assets = os.path.isdir(os.path.join(APP_DIR, "Assets.xcassets"))

objs = []  # (id, text)
def add(i, body):
    objs.append((i, body))

# --- ファイル
core_refs, core_builds, app_refs, app_builds = [], [], [], []
for f in core_files:
    r, b = uid("coreref", f), uid("corebuild", f)
    add(r, f'{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{f}"; sourceTree = "<group>"; }}')
    add(b, f'{{isa = PBXBuildFile; fileRef = {r}; }}')
    core_refs.append(r); core_builds.append(b)
for f in app_files:
    r, b = uid("appref", f), uid("appbuild", f)
    add(r, f'{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{f}"; sourceTree = "<group>"; }}')
    add(b, f'{{isa = PBXBuildFile; fileRef = {r}; }}')
    app_refs.append(r); app_builds.append(b)
plist_ref = uid("plist")
add(plist_ref, '{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }')
res_builds = []
if has_assets:
    a_ref, a_build = uid("assets"), uid("assetsbuild")
    add(a_ref, '{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }')
    add(a_build, f'{{isa = PBXBuildFile; fileRef = {a_ref}; }}')
    res_builds.append(a_build)
has_privacy = os.path.isfile(os.path.join(APP_DIR, "PrivacyInfo.xcprivacy"))
if has_privacy:   # App Store に要る「プライバシーの説明」
    p_ref, p_build = uid("privacy"), uid("privacybuild")
    add(p_ref, '{isa = PBXFileReference; lastKnownFileType = text.xml; path = PrivacyInfo.xcprivacy; sourceTree = "<group>"; }')
    add(p_build, f'{{isa = PBXBuildFile; fileRef = {p_ref}; }}')
    res_builds.append(p_build)
app_product, lib_product = uid("appproduct"), uid("libproduct")
add(app_product, '{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = SatoruEditor.app; sourceTree = BUILT_PRODUCTS_DIR; }')
add(lib_product, '{isa = PBXFileReference; explicitFileType = archive.ar; includeInIndex = 0; path = libHinokiCore.a; sourceTree = BUILT_PRODUCTS_DIR; }')
lib_link = uid("liblink")
add(lib_link, f'{{isa = PBXBuildFile; fileRef = {lib_product}; }}')

# --- グループ
g_main, g_core, g_app, g_products = uid("gmain"), uid("gcore"), uid("gapp"), uid("gproducts")
def lst(ids): return "(" + "".join(f"{i}, " for i in ids) + ")"
add(g_core, f'{{isa = PBXGroup; children = {lst(core_refs)}; name = HinokiCore; path = ../mac/Sources/HinokiCore; sourceTree = "<group>"; }}')
app_children = app_refs + [plist_ref] + ([uid("assets")] if has_assets else []) + ([uid("privacy")] if has_privacy else [])
add(g_app, f'{{isa = PBXGroup; children = {lst(app_children)}; path = SatoruEditor; sourceTree = "<group>"; }}')
add(g_products, f'{{isa = PBXGroup; children = {lst([app_product, lib_product])}; name = Products; sourceTree = "<group>"; }}')
add(g_main, f'{{isa = PBXGroup; children = {lst([g_app, g_core, g_products])}; sourceTree = "<group>"; }}')

# --- ビルドの段階
core_src, core_fw = uid("coresrcphase"), uid("corefwphase")
app_src, app_fw, app_res = uid("appsrcphase"), uid("appfwphase"), uid("appresphase")
add(core_src, f'{{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {lst(core_builds)}; runOnlyForDeploymentPostprocessing = 0; }}')
add(core_fw, '{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }')
add(app_src, f'{{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {lst(app_builds)}; runOnlyForDeploymentPostprocessing = 0; }}')
add(app_fw, f'{{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = {lst([lib_link])}; runOnlyForDeploymentPostprocessing = 0; }}')
add(app_res, f'{{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {lst(res_builds)}; runOnlyForDeploymentPostprocessing = 0; }}')

# --- 設定
def settings(d):
    out = []
    for k, v in d.items():
        out.append(f'{k} = {v};')
    return "{" + " ".join(out) + "}"

common = {
    "ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_ENABLE_MODULES": "YES", "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "IPHONEOS_DEPLOYMENT_TARGET": "15.0", "SDKROOT": "iphoneos", "SWIFT_VERSION": "5.0",
    "TARGETED_DEVICE_FAMILY": '"1,2"', "MTL_ENABLE_DEBUG_INFO": "NO",
}
proj_debug = dict(common, **{"DEBUG_INFORMATION_FORMAT": "dwarf", "ONLY_ACTIVE_ARCH": "YES", "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"',
                             "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG", "ENABLE_TESTABILITY": "YES", "GCC_OPTIMIZATION_LEVEL": "0"})
proj_release = dict(common, **{"DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"', "SWIFT_OPTIMIZATION_LEVEL": '"-O"',
                               "SWIFT_COMPILATION_MODE": "wholemodule", "VALIDATE_PRODUCT": "YES"})
core_set = {"PRODUCT_NAME": "HinokiCore", "SKIP_INSTALL": "YES", "SWIFT_INSTALL_OBJC_HEADER": "NO",
            "CODE_SIGN_STYLE": "Automatic", "DEFINES_MODULE": "YES"}
app_set = {
    "PRODUCT_NAME": "SatoruEditor", "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID, "INFOPLIST_FILE": "SatoruEditor/Info.plist",
    "MARKETING_VERSION": VERSION, "CURRENT_PROJECT_VERSION": BUILD, "DEVELOPMENT_TEAM": TEAM, "CODE_SIGN_STYLE": "Automatic",
    '"CODE_SIGN_IDENTITY[sdk=iphonesimulator*]"': '"-"', "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/Frameworks"',
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "ENABLE_BITCODE": "NO",
}
cfgs = {}
for scope, base in [("proj", None), ("core", core_set), ("app", app_set)]:
    for name in ["Debug", "Release"]:
        i = uid("cfg", scope, name)
        if scope == "proj":
            s = proj_debug if name == "Debug" else proj_release
        else:
            s = base
        add(i, f'{{isa = XCBuildConfiguration; buildSettings = {settings(s)}; name = {name}; }}')
        cfgs[(scope, name)] = i
lists = {}
for scope in ["proj", "core", "app"]:
    i = uid("cfglist", scope)
    add(i, f'{{isa = XCConfigurationList; buildConfigurations = {lst([cfgs[(scope,"Debug")], cfgs[(scope,"Release")]])}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }}')
    lists[scope] = i

# --- ターゲット
t_core, t_app, proj = uid("tcore"), uid("tapp"), uid("project")
dep, proxy = uid("dep"), uid("proxy")
add(proxy, f'{{isa = PBXContainerItemProxy; containerPortal = {proj}; proxyType = 1; remoteGlobalIDString = {t_core}; remoteInfo = HinokiCore; }}')
add(dep, f'{{isa = PBXTargetDependency; target = {t_core}; targetProxy = {proxy}; }}')
add(t_core, f'{{isa = PBXNativeTarget; buildConfigurationList = {lists["core"]}; buildPhases = {lst([core_src, core_fw])}; buildRules = (); dependencies = (); name = HinokiCore; productName = HinokiCore; productReference = {lib_product}; productType = "com.apple.product-type.library.static"; }}')
add(t_app, f'{{isa = PBXNativeTarget; buildConfigurationList = {lists["app"]}; buildPhases = {lst([app_src, app_fw, app_res])}; buildRules = (); dependencies = {lst([dep])}; name = SatoruEditor; productName = SatoruEditor; productReference = {app_product}; productType = "com.apple.product-type.application"; }}')
add(proj, f'{{isa = PBXProject; attributes = {{LastSwiftUpdateCheck = 1310; LastUpgradeCheck = 1310; TargetAttributes = {{{t_app} = {{CreatedOnToolsVersion = 13.1; }}; {t_core} = {{CreatedOnToolsVersion = 13.1; }}; }}; }}; buildConfigurationList = {lists["proj"]}; compatibilityVersion = "Xcode 13.0"; developmentRegion = ja; hasScannedForEncodings = 0; knownRegions = (ja, en, Base, ); mainGroup = {g_main}; productRefGroup = {g_products}; projectDirPath = ""; projectRoot = ""; targets = {lst([t_app, t_core])}; }}')

text = "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 55;\n\tobjects = {\n"
for i, body in sorted(objs):
    text += f"\t\t{i} = {body};\n"
text += f"\t}};\n\trootObject = {proj};\n}}\n"
out = os.path.join(ROOT, "SatoruEditor.xcodeproj")
os.makedirs(out, exist_ok=True)
open(os.path.join(out, "project.pbxproj"), "w").write(text)
# 共有スキーム (xcodebuild -scheme で使えるように)
sd = os.path.join(out, "xcshareddata", "xcschemes")
os.makedirs(sd, exist_ok=True)
open(os.path.join(sd, "SatoruEditor.xcscheme"), "w").write(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1310" version = "1.3">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{t_app}" BuildableName = "SatoruEditor.app" BlueprintName = "SatoruEditor" ReferencedContainer = "container:SatoruEditor.xcodeproj"></BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{t_app}" BuildableName = "SatoruEditor.app" BlueprintName = "SatoruEditor" ReferencedContainer = "container:SatoruEditor.xcodeproj"></BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
''')
print(f"wrote {out} ({len(core_files)} core files, {len(app_files)} app files)")
