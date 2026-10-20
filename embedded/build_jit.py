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
    # Expose the existing session implementation without running preparation a
    # second time after LiveProcess has started its debugger wait deadline.
    api = vendor / "Sources/StikJIT.swift"
    api_text = api.read_text()
    anchor = "    public static var isTXMPresent: Bool? {"
    method = """    // SideInstaller: caller must successfully prepareDevice in this host
    // launch before creating the guest. No attach/script retry is performed.
    public static func enableJITForPreparedDevice(targetPID: Int32,
                                                pairingFile: URL,
                                                configuration: Configuration = .default,
                                                script: Script = .universal,
                                                forceScript: Bool = false,
                                                progress: @escaping (String) -> Void = { _ in }) throws {
        let session = JITSession(pairingFilePath: pairingFile.path, configuration: configuration)
        try session.enableJIT(targetPID: targetPID, script: script,
                              forceScript: forceScript,
                              txmPresence: ProcessInfo.processInfo.txmPresence,
                              progress: progress)
    }

"""
    if api_text.count(anchor) != 1:
        raise ValueError("Pinned StikJIT prepared-device API anchor changed")
    api.write_text(api_text.replace(anchor, method + anchor))
    session_text = session.read_text()
    for before, after in (
        ("        let tunnel = try makeTunnel()", '        progress("Opening device tunnel…")\n        let tunnel = try makeTunnel()'),
        ("        let session = try connectDebugSession(over: tunnel)", '        progress("Connecting debug server…")\n        let session = try connectDebugSession(over: tunnel)'),
        ("        debug_proxy_send_ack(debugProxy)", '        progress("Negotiating debugger…")\n        debug_proxy_send_ack(debugProxy)')
    ):
        if session_text.count(before) != 1:
            raise ValueError("Pinned StikJIT stage anchor changed")
        session_text = session_text.replace(before, after)
    session.write_text(session_text)
    ffi = vendor / "Sources/IdeviceFFI.swift"
    ffi_text = ffi.read_text()
    before = '            message: pointer.pointee.message.map { String(cString: $0) } ?? fallback)'
    after = '            message: fallback + ": " + (pointer.pointee.message.map { String(cString: $0) } ?? "Unknown device error"))'
    if ffi_text.count(before) != 1:
        raise ValueError("Pinned StikJIT FFI diagnostic anchor changed")
    ffi.write_text(ffi_text.replace(before, after))
    # Publish the exact modified MPL source with the resulting IPA.
    (vendor / "SI-ScriptRunner-lifetime.patch").write_text(
        "SideInstaller modifications: hold ScriptRunner strongly; add a prepared-device session entry point; retain FFI operation names and report debugger stages.\n"
        "Original: StikDebug/StikJIT 32287268fa5824f9edce4cb359f5833ce0cf7b00\n")
    # No broad guest entitlements are needed by the debugger process itself.
    (vendor / "SIJITHelper.entitlements").write_bytes(plistlib.dumps({
        "get-task-allow": True,
        "com.apple.security.application-groups": ["$(APP_GROUP_SIDESTORE)", "$(APP_GROUP_ALTSTORE)"]}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("vendor", type=Path)
    generate(parser.parse_args().vendor.resolve())
