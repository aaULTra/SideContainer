"""Generate the helper target alongside pinned StikJIT's own framework target."""
import argparse
from pathlib import Path
import plistlib
import yaml


def generate(vendor):
    sources = Path(__file__).resolve().parent / "jit"
    project_path = vendor / "project.yml"
    project = yaml.safe_load(project_path.read_text())
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
    # No broad guest entitlements are needed by the debugger process itself.
    (vendor / "SIJITHelper.entitlements").write_bytes(plistlib.dumps({
        "get-task-allow": True,
        "com.apple.security.application-groups": ["$(APP_GROUP_SIDESTORE)", "$(APP_GROUP_ALTSTORE)"]}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("vendor", type=Path)
    generate(parser.parse_args().vendor.resolve())
