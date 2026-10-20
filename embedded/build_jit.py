"""Generate the helper target alongside pinned StikJIT's own framework target."""
import argparse
from pathlib import Path
import plistlib
import yaml


def generate(vendor):
    sources = Path(__file__).resolve().parent / "jit"
    project_path = vendor / "project.yml"
    project = yaml.safe_load(project_path.read_text())
    # The upstream framework spec builds a binary without generating its
    # bundle metadata. installd requires this even when compilation succeeds.
    framework = project["targets"]["StikJIT"]
    framework["info"] = {"path": "StikJIT-Info.plist", "properties": {
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleName": "$(PRODUCT_NAME)",
        "CFBundlePackageType": "FMWK",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)"}}
    framework["settings"]["base"]["GENERATE_INFOPLIST_FILE"] = "NO"
    project["targets"]["SIJITHelper"] = {
        "type": "app-extension", "platform": "iOS", "deploymentTarget": "17.4",
        "sources": [str(sources / "Messages.swift"), str(sources / "Helper.swift")],
        "info": {"path": "SIJITHelper-Info.plist", "properties": {
            "CFBundleDisplayName": "LiveContainer JIT Helper",
            "NSExtension": {
                "NSExtensionPointIdentifier": "com.apple.ar.viewer",
                "NSExtensionPrincipalClass": "SIJITHelperHandler",
                "NSExtensionContextClass": "NSExtensionContext",
                "NSExtensionContextHostClass": "NSExtensionContext",
                "NSExtensionAttributes": {"NSExtensionActivationRule": "FALSEPREDICATE"}},
            "XPCService": {"ServiceType": "Application", "_MultipleInstances": True, "_ProcessType": "App"},
            "NSLocalNetworkUsageDescription": "Connect to this device through LocalDevVPN to enable guest JIT.",
            "NSAppTransportSecurity": {"NSAllowsArbitraryLoads": True}}},
        "settings": {"base": {
            "PRODUCT_BUNDLE_IDENTIFIER": "com.aault.livecontainer.sideinstaller.JITHelper",
            "TARGETED_DEVICE_FAMILY": "1,2", "APPLICATION_EXTENSION_API_ONLY": "YES",
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../../Frameworks"]}},
        "dependencies": [{"target": "StikJIT", "embed": False}],
    }
    project["schemes"]["SIJITHelper"] = {"build": {"targets": {"SIJITHelper": "all"}}}
    project_path.write_text(yaml.safe_dump(project, sort_keys=False))
    # Release WMO diagnoses weak callbacks on the temporary ScriptRunner.
    # Keep the owner alive for the entire synchronous JavaScript evaluation.
    session = vendor / "Sources/JITSession.swift"
    old = "            try ScriptRunner(targetPID: targetPID, debugProxy: debugProxy, script: script, progress: progress).run()"
    new = ("            let runner = ScriptRunner(targetPID: targetPID, debugProxy: debugProxy, script: script, progress: progress)\n"
           "            try withExtendedLifetime(runner) { try runner.run() }")
    text = session.read_text()
    if text.count(old) != 1:
        raise ValueError("Pinned StikJIT ScriptRunner lifetime anchor changed")
    session.write_text(text.replace(old, new))
    # Publish the exact modified MPL source with the resulting IPA.
    (vendor / "SI-ScriptRunner-lifetime.patch").write_text(
        "SideInstaller modification to pinned StikJIT: hold ScriptRunner strongly while its weak JavaScript callbacks run.\n"
        "Original: StikDebug/StikJIT 32287268fa5824f9edce4cb359f5833ce0cf7b00\n")
    # No broad guest entitlements are needed by the debugger process itself.
    (vendor / "SIJITHelper.entitlements").write_bytes(plistlib.dumps({
        "get-task-allow": True,
        "com.apple.security.application-groups": ["$(APP_GROUP_SIDESTORE)", "$(APP_GROUP_ALTSTORE)"]}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("vendor", type=Path)
    generate(parser.parse_args().vendor.resolve())
