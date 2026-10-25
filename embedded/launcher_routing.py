"""Singleton launcher, scene-bound handoffs and direct Shortcut/Home Screen routing."""
from pathlib import Path
import shutil


def patch(root, replace, host_scheme):
    shutil.copyfile(Path(__file__).with_name('LauncherRouter.swift'),
                    root / 'LiveContainerSwiftUI/Utilities/SILauncherRouter.swift')
    delegate = root / 'LiveContainerSwiftUI/App/AppDelegate.swift'
    replace(delegate, '        self.window = (scene as? UIWindowScene)?.keyWindow',
            '        self.window = (scene as? UIWindowScene)?.keyWindow\n'
            '        SILaunchWindow.incomingURLs[session.persistentIdentifier] = connectionOptions.urlContexts.map { $0.url }', 1)
    app = root / 'LiveContainerSwiftUI/App/LiveContainerSwiftUIApp.swift'
    replace(app, '                .background(SILauncherWindowMarker())',
            '                .background(SILauncherWindowMarker())\n'
            '                .overlay { SILauncherProgress() }', 1)
    replace(app, '                    MultitaskAppWindow(id: id)',
            '                    MultitaskAppWindow(id: id)\n'
            '                        .handlesExternalEvents(preferring: [], allowing: [])', 1)
    tabs = root / 'LiveContainerSwiftUI/Views/LCTabView.swift'
    text = tabs.read_text()
    start = text.index('    func closeDuplicatedWindow() {')
    end = text.index('    func checkLastLaunchError()', start)
    replace(tabs, text[start:end],
            '    func closeDuplicatedWindow() {\n'
            '        if let scene = sceneDelegate.window?.windowScene { SILaunchWindow.registerLauncher(scene) }\n'
            '    }\n\n', 1)
    replace(tabs, '                    DataManager.shared.model.mainWindowOpened = false',
            '                    SILaunchWindow.disconnect(scene1)', 1)
    replace(tabs, '        sharedModel.deepLink = url',
            '        SILauncherRouter.shared.receive(url)', 1)
    apps = root / 'LiveContainerSwiftUI/Views/AppList/LCAppListView.swift'
    replace(apps, '    @EnvironmentObject private var sharedModel : SharedModel',
            '    @EnvironmentObject private var sceneDelegate: SceneDelegate\n'
            '    @EnvironmentObject private var sharedModel : SharedModel', 1)
    replace(apps, 'guard sharedModel.selectedTab == .apps, let link',
            'guard SILaunchWindow.isLauncher(sceneDelegate.window?.windowScene), sharedModel.selectedTab == .apps, let link', 2)
    signature = '    func launchAppWithBundleId(bundleId : String, container : String?, urlStr: String? = nil, forceJIT: Bool? = nil) async {'
    replace(apps, signature, signature + '\n'
            '        let origin = sceneDelegate.window?.windowScene\n'
            '        var launchSucceeded = false\n'
            '        defer { SILauncherRouter.shared.finish(success: launchSucceeded) }', 1)
    replace(apps, '            try await appFound.runApp(multitask: nil, containerFolderName: container, urlStr: urlStr, forceJIT: forceJIT)',
            '            appFound.delegate = self\n'
            '            let previousLaunch = appFound.appInfo.lastLaunched\n'
            '            let nativeMode = LCUtils.appGroupUserDefault.integer(forKey: "LCMultitaskMode") == 1\n'
            '            try await appFound.runApp(multitask: nativeMode ? true : nil, containerFolderName: container, urlStr: urlStr, forceJIT: forceJIT, launcherScene: origin, closeLauncher: true)\n'
            '            let dataFolder = container ?? appFound.uiSelectedContainer?.folderName\n'
            '            launchSucceeded = appFound.appInfo.lastLaunched != previousLaunch ||\n'
            '                (dataFolder.flatMap { SILaunchWindow.guests[$0] } != nil)', 1)
    model = root / 'LiveContainerSwiftUI/Models/LCAppModel.swift'
    replace(model, '            if await bringExistingMultitaskWindowIfNeeded(dataUUID: currentDataFolder, urlScheme: urlStr) {\n                return',
            '            if await bringExistingMultitaskWindowIfNeeded(dataUUID: currentDataFolder, urlScheme: urlStr) {\n'
            '                if closeLauncher {\n'
            '                    await MainActor.run { launchWindow?.completeExistingGuest() }\n'
            '                    didHandOffLaunchWindow = true\n'
            '                }\n                return', 1)
    window = root / 'MultitaskSupport/MultitaskAppWindow.swift'
    replace(window, '        appDict[dataUUID] = MultitaskAppInfo(displayName: displayName, dataUUID: dataUUID, bundleId: bundleId)',
            '        let windowID = UUID().uuidString\n'
            '        appDict[windowID] = MultitaskAppInfo(displayName: displayName, dataUUID: dataUUID, bundleId: bundleId)', 1)
    replace(window, '        openWindow(id: "appView", value: dataUUID)',
            '        openWindow(id: "appView", value: windowID)', 1)
    replace(window, '        func appSceneVCAppDidExit(_: AppSceneViewController!) {\n            onExit()\n        }',
            '        func appSceneVCAppDidExit(_ vc: AppSceneViewController!) {\n'
            '            Task { @MainActor in\n'
            '                SILaunchWindow.guestExited(container: vc.dataUUID)\n'
            '                MultitaskWindowManager.appDict = MultitaskWindowManager.appDict.filter { $0.value.dataUUID != vc.dataUUID }\n'
            '            }\n'
            '            onExit()\n        }', 1)
    banner = root / 'LiveContainerSwiftUI/Views/AppList/LCAppBanner/LCAppBannerViewController.swift'
    replace(banner, '    private func runApp(multitask: Bool? = nil) async {',
            '    private func runApp(multitask: Bool? = nil) async {\n'
            '        configuration.model.delegate = delegate as? LCAppModelDelegate', 1)
    # Native Shortcut launches must use the same validation/JIT/scene routing
    # path, rather than preselecting a classic-mode bootstrap in shared defaults.
    shortcut = root / 'LaunchAppExtension/LaunchAppExtension.swift'
    replace(shortcut, '"livecontainer"', f'"{host_scheme}"', 5)
    replace(shortcut, '        // resolve private Documents bookmark',
            '        if lcSharedDefaults.integer(forKey: "LCMultitaskMode") == 1 {\n'
            f'            components.scheme = "{host_scheme}"\n'
            '            guard let nativeURL = components.url else { throw LaunchAppExtensionError("Invalid launch URL") }\n'
            '            try await openURL(launchOptions: ["url": nativeURL])\n'
            '            return .result()\n'
            '        }\n\n'
            '        // resolve private Documents bookmark', 1)
    replace(shortcut, 'This action directly launches an app in normal mode in LiveContainer.',
            'Launch an app using its LiveContainer settings, including native windows and JIT.', 1)
    # Encode identifiers correctly and bind generated icons to the selected
    # container instead of silently following a later change of default.
    info = root / 'LiveContainerSwiftUI/Models/LCAppInfo.m'
    text = info.read_text()
    start = text.index('    NSString* appClipUrl;')
    end = text.index('    UIImage* icon =', start)
    replace(info, text[start:end],
            '    NSURLComponents *launch = [NSURLComponents new];\n'
            f'    launch.scheme = @"{host_scheme}";\n'
            '    launch.host = @"livecontainer-launch";\n'
            '    NSMutableArray *items = [NSMutableArray arrayWithObject:[NSURLQueryItem queryItemWithName:@"bundle-name" value:self.bundlePath.lastPathComponent]];\n'
            '    NSString *folder = containerId ?: self.dataUUID;\n'
            '    if (folder) [items addObject:[NSURLQueryItem queryItemWithName:@"container-folder-name" value:folder]];\n'
            '    launch.queryItems = items;\n'
            '    NSString *appClipUrl = launch.URL.absoluteString;\n\n', 1)
    text = banner.read_text()
    start = text.index('        if let folderName = configuration.model.uiSelectedContainer?.folderName {', text.index('    private func copyLaunchUrl()'))
    end = text.index('\n    private func createAppClip()', start)
    replace(banner, text[start:end],
            '        var launch = URLComponents()\n'
            f'        launch.scheme = "{host_scheme}"\n'
            '        launch.host = "livecontainer-launch"\n'
            '        var items = [URLQueryItem(name: "bundle-name", value: relativeBundlePath)]\n'
            '        if let folder = configuration.model.uiSelectedContainer?.folderName {\n'
            '            items.append(URLQueryItem(name: "container-folder-name", value: folder))\n'
            '        }\n'
            '        launch.queryItems = items\n'
            '        UIPasteboard.general.string = launch.url?.absoluteString\n'
            '    }\n', 1)
