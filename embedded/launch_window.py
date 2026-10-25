"""Scene-scoped launcher handoff for the pinned LiveContainer host."""
from pathlib import Path
import shutil


def patch(root, replace):
    shutil.copyfile(Path(__file__).with_name('LaunchWindow.swift'),
                    root / 'LiveContainerSwiftUI/Utilities/SILaunchWindow.swift')
    scene_delegate = root / 'LiveContainerSwiftUI/App/AppDelegate.swift'
    replace(scene_delegate, '    var window: UIWindow?',
            '    var window: UIWindow?\n\n'
            '    func sceneDidDisconnect(_ scene: UIScene) {\n'
            '        SILaunchWindow.launchers.removeValue(forKey: scene.session.persistentIdentifier)\n'
            '    }', 1)
    app = root / 'LiveContainerSwiftUI/App/LiveContainerSwiftUIApp.swift'
    replace(app, '            LCTabView()',
            '            LCTabView()\n                .background(SILauncherWindowMarker())', 1)
    model = root / 'LiveContainerSwiftUI/Models/LCAppModel.swift'
    replace(model, 'forceJIT: Bool? = nil) async throws{',
            'forceJIT: Bool? = nil, launcherScene: UIWindowScene? = nil) async throws{', 1)
    replace(model, '        let classicMode = appInfo.defaultClassicMode',
            '        let launchWindow = await MainActor.run {\n'
            '            SILaunchWindow.begin(container: currentDataFolder, source: launcherScene)\n'
            '        }\n'
            '        var didHandOffLaunchWindow = false\n'
            '        defer { if !didHandOffLaunchWindow { Task { @MainActor in launchWindow?.cancel() } } }\n'
            '        let classicMode = appInfo.defaultClassicMode', 1)
    replace(model, '        // Record the launch time',
            '        if jitNeeded && multitask {\n'
            '            await MainActor.run { launchWindow?.complete() }\n'
            '            didHandOffLaunchWindow = true\n'
            '        }\n\n'
            '        // Record the launch time', 1)
    banner = root / 'LiveContainerSwiftUI/Views/AppList/LCAppBanner/LCAppBannerViewController.swift'
    replace(banner, 'try await configuration.model.runApp(multitask: multitask)',
            'try await configuration.model.runApp(multitask: multitask, launcherScene: view.window?.windowScene)', 1)
    window = root / 'MultitaskSupport/MultitaskAppWindow.swift'
    replace(window, '            // fix live resize',
            '            Task { @MainActor in\n'
            '                SILaunchWindow.guestReady(container: vc.dataUUID, scene: vc.view.window?.windowScene)\n'
            '            }\n'
            '            // fix live resize', 1)
    replace(window, '            settings.interruptionPolicy = 0',
            '            Task { @MainActor in\n'
            '                SILaunchWindow.guestReady(container: vc.dataUUID, scene: vc.view.window?.windowScene)\n'
            '            }\n'
            '            settings.interruptionPolicy = 0', 1)
