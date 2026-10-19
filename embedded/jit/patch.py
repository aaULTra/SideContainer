"""Checked integration into the pinned host's existing compilation units."""
from pathlib import Path


def patch(root, replace):
    here = Path(__file__).resolve().parent
    settings = root / "LiveContainerSwiftUI/Views/Settings/LCSettingsView.swift"
    replace(settings, "    case StosDebugLC = 6", "    case StosDebugLC = 6\n    case BuiltInStikJIT = 7", 1)
    replace(settings, '        case .StikJIT: "StikDebug"',
            '        case .BuiltInStikJIT: "Built-in StikJIT (experimental)"\n        case .StikJIT: "StikDebug"', 1)
    replace(settings, '                    if JITEnabler == .SideJITServer ||',
            '                    if JITEnabler == .BuiltInStikJIT { SIBuiltInJITSettings() }\n'
            '                    if JITEnabler == .SideJITServer ||', 1)
    utilities = root / "LiveContainerSwiftUI/Utilities/LCUtilsExtensions.swift"
    # Already an explicit PBXSourcesBuildPhase member, unlike a newly dropped file.
    with utilities.open("a") as stream:
        stream.write("\n" + (here / "Messages.swift").read_text() + "\n" + (here / "Coordinator.swift").read_text())

    model = root / "LiveContainerSwiftUI/Models/LCAppModel.swift"
    replace(model,
            '        let multitask = classicMode == 0 ? (multitask ?? shouldLaunchInMultitaskMode) : false',
            '        let builtInJIT = SIBuiltInJIT.selected && (forceJIT ?? (appInfo.isJITNeeded || appInfo.is32bit))\n'
            '        if builtInJIT && classicMode != 0 {\n'
            '            throw SIBuiltInJIT.error("Built-in JIT requires LiveProcess. Disable classic mode for this guest, or select external StikDebug.")\n'
            '        }\n'
            '        let multitask = builtInJIT || (classicMode == 0 ? (multitask ?? shouldLaunchInMultitaskMode) : false)', 1)
    replace(model, '        if jitNeeded {\n            if multitask,',
            '        if jitNeeded {\n'
            '            if builtInJIT {\n'
            '                try await SIBuiltInJIT.shared.prepare()\n'
            '                UserDefaults.standard.set(currentDataFolder, forKey: "SIBuiltInJITContainer")\n'
            '            }\n'
            '            defer { if builtInJIT { UserDefaults.standard.removeObject(forKey: "SIBuiltInJITContainer") } }\n'
            '            if multitask,', 1)
    replace(model, '                        Task {\n                            if let scriptData = self.jitLaunchScriptJs,',
            '                        Task { @MainActor in\n'
            '                            if builtInJIT {\n'
            '                                do {\n'
            '                                    try await SIBuiltInJIT.shared.enable(pid: pidNumber.intValue, script: self.jitLaunchScriptJs)\n'
            '                                    continuation.resume()\n'
            '                                } catch { continuation.resume(throwing: error) }\n'
            '                                return\n'
            '                            }\n'
            '                            if let scriptData = self.jitLaunchScriptJs,', 1)

    # The app's exact launch request carries the wait flag. Do not pause every
    # guest just because a global JIT method is selected.
    scene = root / "MultitaskSupport/AppSceneViewController.m"
    replace(scene, '    item.userInfo = userInfo;',
            '    userInfo[@"siBuiltInJIT"] = @([NSUserDefaults.lcSharedDefaults integerForKey:@"LCJITEnablerType"] == 7 &&\n'
            '        [[NSUserDefaults.standardUserDefaults stringForKey:@"SIBuiltInJITContainer"] isEqualToString:dataUUID]);\n'
            '    item.userInfo = userInfo;', 1)
    process = root / "LiveProcess/main.m"
    replace(process, '    // Check if we received a request to execute a custom payload',
            '    // Only the debugger flag gates loading here. It is NOT reported as\n'
            '    // completed JIT: the guest runtime must still execute its script protocol.\n'
            '    if ([appInfo[@"siBuiltInJIT"] boolValue]) {\n'
            '        uint32_t flags = 0;\n'
            '        if (csops(getpid(), 0, &flags, sizeof(flags)) != 0 || !(flags & 0x4)) _exit(71);\n'
            '        BOOL attached = NO;\n'
            '        for (int attempt = 0; attempt < 450; attempt++) {\n'
            '            flags = 0;\n'
            '            if (csops(getpid(), 0, &flags, sizeof(flags)) == 0 && (flags & CS_DEBUGGED)) { attached = YES; break; }\n'
            '            usleep(100000);\n'
            '        }\n'
            '        if (!attached) _exit(72);\n'
            '    }\n\n'
            '    // Check if we received a request to execute a custom payload', 1)
    # Refuse unsupported classic calls instead of falling through to a server.
    replace(utilities, '        if(jitEnabler == .SideJITServer){',
            '        if jitEnabler == .BuiltInStikJIT {\n'
            '            onServerMessage?("Built-in JIT requires a guest LiveProcess PID. Launch the guest in LiveProcess mode.")\n'
            '            return false\n'
            '        }\n'
            '        if(jitEnabler == .SideJITServer){', 1)
