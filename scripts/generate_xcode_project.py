#!/usr/bin/env python3
"""Rebuild Form.xcodeproj deterministically without third-party project tools."""
from __future__ import annotations
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / "iOS"
OBJECTS = {}


def identifier(name):
    return hashlib.sha256(("form:" + name).encode()).hexdigest()[:24].upper()


def add(object_label, isa, **values):
    key = identifier(object_label)
    OBJECTS[key] = {"isa": isa, **values}
    return key


def file(name, path, kind, tree="<group>"):
    return add(name, "PBXFileReference", lastKnownFileType=kind, path=path, sourceTree=tree)


def group(object_label, children, **values):
    return add(object_label, "PBXGroup", children=children, sourceTree="<group>", **values)


def build(name, file_ref=None, product_ref=None, **values):
    if file_ref:
        values["fileRef"] = file_ref
    if product_ref:
        values["productRef"] = product_ref
    return add(name, "PBXBuildFile", **values)


def configuration_list(name, settings, base=None):
    references = []
    for configuration in ("Debug", "Release"):
        values = {"buildSettings": dict(settings), "name": configuration}
        if base:
            values["baseConfigurationReference"] = base
        values["buildSettings"].update({
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if configuration == "Debug" else "-O",
            "DEBUG_INFORMATION_FORMAT": "dwarf" if configuration == "Debug" else "dwarf-with-dsym",
            "ONLY_ACTIVE_ARCH": "YES" if configuration == "Debug" else "NO",
        })
        if configuration == "Debug":
            # Embedded extensions are already signed; keep their debug symbols
            # instead of asking the copy phase to strip those signed binaries.
            values["buildSettings"]["COPY_PHASE_STRIP"] = "NO"
            values["buildSettings"]["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "$(inherited) DEBUG"
            values["buildSettings"]["ENABLE_TESTABILITY"] = "YES"
        references.append(add(f"{name}-{configuration}", "XCBuildConfiguration", **values))
    return add(name, "XCConfigurationList", buildConfigurations=references, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")


def render(value, depth=0):
    indent = "\t" * depth
    if isinstance(value, dict):
        lines = ["{"]
        for key, child in value.items():
            lines.append("\t" * (depth + 1) + json.dumps(key) + " = " + render(child, depth + 1) + ";")
        lines.append(indent + "}")
        return "\n".join(lines)
    if isinstance(value, list):
        if not value:
            return "()"
        return "(\n" + "\n".join("\t" * (depth + 1) + render(item, depth + 1) + "," for item in value) + "\n" + indent + ")"
    return str(value) if isinstance(value, int) else json.dumps(value)


def main():
    base = file("base-config", "Base.xcconfig", "text.xcconfig")
    config_group = group("config-group", [base], path="Configuration")
    app_source = file("app-source", "FormApp.swift", "sourcecode.swift")
    app_info = file("app-info", "Info.plist", "text.plist.xml")
    app_entitlements = file("app-entitlements", "Form.entitlements", "text.plist.entitlements")
    assets = file("assets", "Assets.xcassets", "folder.assetcatalog")
    app_group = group("app-group", [app_source, assets, app_info, app_entitlements], path="Form")
    widget_source = file("widget-source", "FormWidgets.swift", "sourcecode.swift")
    snapshot_source = file("snapshot-source", "WidgetSnapshot.swift", "sourcecode.swift")
    widget_info = file("widget-info", "Info.plist", "text.plist.xml")
    widget_entitlements = file("widget-entitlements", "FormWidgets.entitlements", "text.plist.entitlements")
    widget_group = group("widget-group", [widget_source, snapshot_source, widget_info, widget_entitlements], path="FormWidgets")
    app_product = add("app-product", "PBXFileReference", explicitFileType="wrapper.application", includeInIndex=0, path="Form.app", sourceTree="BUILT_PRODUCTS_DIR")
    personal_product = add("personal-product", "PBXFileReference", explicitFileType="wrapper.application", includeInIndex=0, path="FormPersonal.app", sourceTree="BUILT_PRODUCTS_DIR")
    widget_product = add("widget-product", "PBXFileReference", explicitFileType="wrapper.app-extension", includeInIndex=0, path="FormWidgets.appex", sourceTree="BUILT_PRODUCTS_DIR")
    products = group("products", [app_product, personal_product, widget_product], name="Products")
    main_group = group("main-group", [app_group, widget_group, config_group, products])
    package = add("local-package", "XCLocalSwiftPackageReference", relativePath="..")
    package_products = [add("package-" + name, "XCSwiftPackageProductDependency", package=package, productName=name) for name in ("AirUI", "AirSync", "AirAuth", "FitbitMetrics")]
    app_frameworks = add("app-frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[build("link-" + product, product_ref=product) for product in package_products], runOnlyForDeploymentPostprocessing=0)
    widget_frameworks = add("widget-frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
    app_sources = add("app-sources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=[build("compile-app", app_source)], runOnlyForDeploymentPostprocessing=0)
    widget_sources = add("widget-sources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=[build("compile-widget", widget_source), build("compile-snapshot", snapshot_source)], runOnlyForDeploymentPostprocessing=0)
    app_resources = add("app-resources", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=[build("bundle-assets", assets)], runOnlyForDeploymentPostprocessing=0)
    personal_sources = add("personal-sources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=[build("compile-personal", app_source)], runOnlyForDeploymentPostprocessing=0)
    personal_frameworks = add("personal-frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[build("personal-link-" + product, product_ref=product) for product in package_products], runOnlyForDeploymentPostprocessing=0)
    personal_resources = add("personal-resources", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=[build("personal-bundle-assets", assets)], runOnlyForDeploymentPostprocessing=0)
    widget_resources = add("widget-resources", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
    embed_widgets = add("embed-widgets", "PBXCopyFilesBuildPhase", buildActionMask=2147483647, dstPath="", dstSubfolderSpec=13, files=[build("embed-widget", widget_product, settings={"ATTRIBUTES": ["RemoveHeadersOnCopy"]})], name="Embed App Extensions", runOnlyForDeploymentPostprocessing=0)
    common = {
        "CODE_SIGN_STYLE": "Automatic", "CURRENT_PROJECT_VERSION": "7", "MARKETING_VERSION": "1.0",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        "SWIFT_VERSION": "6.0", "TARGETED_DEVICE_FAMILY": "1", "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES", "ENABLE_USER_SCRIPT_SANDBOXING": "YES", "ENABLE_PREVIEWS": "YES",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES", "GCC_C_LANGUAGE_STANDARD": "gnu17", "CLANG_CXX_LANGUAGE_STANDARD": "gnu++20",
        "GCC_WARN_UNDECLARED_SELECTOR": "YES", "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
        "SWIFT_STRICT_CONCURRENCY": "complete", "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
    }
    project_configs = configuration_list("project-configs", common, base)
    app_configs = configuration_list("app-configs", {
        "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": "$(FORM_BUNDLE_ID)",
        "INFOPLIST_FILE": "Form/Info.plist", "GENERATE_INFOPLIST_FILE": "NO",
        "CODE_SIGN_ENTITLEMENTS": "Form/Form.entitlements", "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"], "ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES": "YES",
        "SUPPORTS_MACCATALYST": "NO", "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO", "SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD": "NO",
    })
    # Personal Team build: same app and OAuth bundle identity, without the App
    # Group entitlement or widget dependency. Explicit target-level overrides
    # also disable shared-cache writes when Local.xcconfig defines an App Group.
    personal_configs = configuration_list("personal-configs", {
        "PRODUCT_NAME": "FormPersonal", "PRODUCT_MODULE_NAME": "FormPersonal", "PRODUCT_BUNDLE_IDENTIFIER": "$(FORM_BUNDLE_ID)",
        "INFOPLIST_FILE": "Form/Info.plist", "GENERATE_INFOPLIST_FILE": "NO",
        "CODE_SIGN_ENTITLEMENTS": "", "FORM_APP_GROUP": "", "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"], "ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES": "YES",
        "SUPPORTS_MACCATALYST": "NO", "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO", "SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD": "NO",
    })
    widget_configs = configuration_list("widget-configs", {
        "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": "$(FORM_WIDGET_BUNDLE_ID)",
        "INFOPLIST_FILE": "FormWidgets/Info.plist", "GENERATE_INFOPLIST_FILE": "NO",
        "CODE_SIGN_ENTITLEMENTS": "FormWidgets/FormWidgets.entitlements", "APPLICATION_EXTENSION_API_ONLY": "YES", "SKIP_INSTALL": "YES",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"],
    })
    widget_target = add("widget-target", "PBXNativeTarget", buildConfigurationList=widget_configs, buildPhases=[widget_sources, widget_frameworks, widget_resources], buildRules=[], dependencies=[], name="FormWidgets", productName="FormWidgets", productReference=widget_product, productType="com.apple.product-type.app-extension")
    proxy = add("widget-proxy", "PBXContainerItemProxy", containerPortal=identifier("project"), proxyType=1, remoteGlobalIDString=widget_target, remoteInfo="FormWidgets")
    dependency = add("widget-dependency", "PBXTargetDependency", target=widget_target, targetProxy=proxy)
    app_target = add("app-target", "PBXNativeTarget", buildConfigurationList=app_configs, buildPhases=[app_sources, app_frameworks, app_resources, embed_widgets], buildRules=[], dependencies=[dependency], name="Form", packageProductDependencies=package_products, productName="Form", productReference=app_product, productType="com.apple.product-type.application")
    personal_target = add("personal-target", "PBXNativeTarget", buildConfigurationList=personal_configs, buildPhases=[personal_sources, personal_frameworks, personal_resources], buildRules=[], dependencies=[], name="Form Personal", packageProductDependencies=package_products, productName="FormPersonal", productReference=personal_product, productType="com.apple.product-type.application")
    capabilities = {"com.apple.ApplicationGroups.iOS": {"enabled": 1}}
    project = add("project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastSwiftUpdateCheck": "1600", "LastUpgradeCheck": "1600", "TargetAttributes": {
        app_target: {"CreatedOnToolsVersion": "16.0", "ProvisioningStyle": "Automatic", "SystemCapabilities": {**capabilities, "com.apple.BackgroundModes": {"enabled": 1}}},
        widget_target: {"CreatedOnToolsVersion": "16.0", "ProvisioningStyle": "Automatic", "SystemCapabilities": capabilities},
        personal_target: {"CreatedOnToolsVersion": "16.0", "ProvisioningStyle": "Automatic", "SystemCapabilities": {"com.apple.BackgroundModes": {"enabled": 1}}},
    }}, buildConfigurationList=project_configs, compatibilityVersion="Xcode 14.0", developmentRegion="en", hasScannedForEncodings=0, knownRegions=["en", "Base"], mainGroup=main_group, packageReferences=[package], productRefGroup=products, projectDirPath="", projectRoot="", targets=[app_target, personal_target, widget_target])
    data = {"archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": OBJECTS, "rootObject": project}
    path = IOS / "Form.xcodeproj"
    path.mkdir(parents=True, exist_ok=True)
    (path / "project.pbxproj").write_text("// !$*UTF8*$!\n" + render(data) + "\n")
    schemes = path / "xcshareddata/xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="Form.app" BlueprintName="Form" ReferencedContainer="container:Form.xcodeproj"/>'
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction>
  <LaunchAction buildConfiguration="Release" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
    (schemes / "Form.xcscheme").write_text(scheme)
    # Keep existing selected scheme names, with the same complete widget app.
    (schemes / "Form Personal.xcscheme").write_text(scheme)  # Existing selection now includes widgets.
    print("Generated iOS/Form.xcodeproj and shared Form / Form Personal schemes.")


if __name__ == "__main__":
    main()
