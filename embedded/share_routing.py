"""Adapt the existing share and shortcut extensions to this host's identity."""
from pathlib import Path
import plistlib
import shutil


def patch(root, replace, scheme):
    model = root / 'ShareExtension/ShareExtensionViewModel.swift'
    replace(model, '"livecontainer"', f'"{scheme}"', 4)
    replace(model, 'livecontainer://', scheme + '://', 2)
    replace(model, 'Frameworks/SideStoreApp.framework', 'Frameworks/SideInstallerApp.framework', 1)
    replace(model, 'SideStore/Library/Caches', 'SideInstaller/Library/Caches', 1)
    replace(model, '"SideStore"', '"SideInstaller"', 2)
    launcher = root / 'ShareExtension/main.m'
    replace(launcher, '@"livecontainer"', f'@"{scheme}"', 1)
    replace(launcher, '@"sidestore"', '@"sideinstaller-embedded"', 1)
    shortcut = root / 'LaunchAppExtension/LaunchAppExtension.swift'
    replace(shortcut, '"livecontainer"', f'"{scheme}"', 5)
    replace(shortcut, '"sidestore"', '"sideinstaller-embedded"', 2)
    info_path = root / 'ShareExtension/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    info['CFBundleDisplayName'] = 'LC + SI'
    info_path.write_bytes(plistlib.dumps(info))
    shutil.copyfile(Path(__file__).with_name('SISharePayloadLoader.swift'),
                    root / 'ShareExtension/SISharePayloadLoader.swift')
    payload = root / 'ShareExtension/ShareModels.swift'
    text = payload.read_text()
    start = text.index('        let providers = items.flatMap')
    end = text.index('\n        return .empty', start) + len('\n        return .empty')
    text = text[:start] + '''        let providers = items.flatMap { $0.attachments ?? [] }
        let staging = LCSharedUtils.appGroupPath()?.appendingPathComponent("LiveContainer/ShareInbox", isDirectory: true)
        switch try await SISharePayloadLoader.load(providers: providers, stagingDirectory: staging) {
        case .file(let url): return .file(url)
        case .url(let url): return .url(url)
        case .empty: return .empty
        }''' + text[end:]
    payload.write_text(text)
    views = root / 'ShareExtension/ShareExtensionViews.swift'
    replace(views, '                VStack(alignment: .leading, spacing: 16) {',
            '''                VStack(alignment: .leading, spacing: 16) {
                    switch viewModel.payload.kind {
                    case .loading:
                        ProgressView("Reading shared item…")
                    case .failed(let message):
                        Text(message).foregroundStyle(.red)
                    case .empty:
                        Text("No supported file or link was received. Try sharing the IPA from Files again.")
                            .foregroundStyle(.secondary)
                    default:
                        EmptyView()
                    }''', 1)
    replace(views, 'Text("lc.common.install".loc)', 'Text("Import to LC")', 1)
    importer = root / 'LiveContainerSwiftUI/Views/AppList/LCAppListView.swift'
    replace(importer, '                try await installIpaFile(installUrl)',
            '''                try await installIpaFile(installUrl)
                // Remove only this completed import's staged attachment.
                let stagedDirectory = installUrl.deletingLastPathComponent().standardizedFileURL
                if let stagedRoot = LCSharedUtils.appGroupPath()?.appendingPathComponent("LiveContainer/ShareInbox", isDirectory: true).standardizedFileURL,
                   stagedDirectory.deletingLastPathComponent() == stagedRoot,
                   UUID(uuidString: stagedDirectory.lastPathComponent) != nil {
                    try? fm.removeItem(at: stagedDirectory)
                }''', 1)
