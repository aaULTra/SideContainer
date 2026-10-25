import SwiftUI
import UIKit

/// All direct launches pass through the single launcher so app locks, signing
/// and JIT retain LC's normal validation. Queue distinct requests; tapping the
/// same Home Screen icon repeatedly must not start parallel JIT sessions.
@MainActor
final class SILauncherRouter: ObservableObject {
    static let shared = SILauncherRouter()
    @Published private(set) var activeURL: URL?
    private var queue: [URL] = []

    var canCloseLauncher: Bool { queue.isEmpty }

    static func isAppLaunch(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "livecontainer-sideinstaller",
              url.host?.lowercased() == "livecontainer-launch",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let bundle = items.first(where: { $0.name == "bundle-name" })?.value else { return false }
        return !bundle.isEmpty && bundle != "ui"
    }

    func receive(_ url: URL) {
        guard Self.isAppLaunch(url) else {
            switch url.host?.lowercased() {
            case "install", "open-web-page", "open-url": DataManager.shared.model.selectedTab = .apps
            case "certificate": DataManager.shared.model.selectedTab = .settings
            case "source": DataManager.shared.model.selectedTab = .sources
            default: break
            }
            DataManager.shared.model.deepLink = url
            return
        }
        guard activeURL != url, !queue.contains(url) else { return }
        queue.append(url)
        pump()
    }

    func pump() {
        guard activeURL == nil, !queue.isEmpty, SILaunchWindow.canonicalLauncher != nil else { return }
        activeURL = queue.removeFirst()
        DataManager.shared.model.selectedTab = .apps
        DataManager.shared.model.deepLink = activeURL
    }

    func finish(success: Bool) {
        guard activeURL != nil else { return }
        activeURL = nil
        if !success {
            // Leave errors/authentication cancellation visible in the launcher.
            queue.removeAll()
            SILaunchWindow.cancelAutomaticCloses()
        }
        pump()
        if activeURL == nil { SILaunchWindow.resumeReadyClosures() }
    }
}

struct SILauncherProgress: View {
    @ObservedObject private var router = SILauncherRouter.shared
    var body: some View {
        if router.activeURL != nil {
            ZStack {
                Color(uiColor: .systemBackground).ignoresSafeArea()
                VStack(spacing: 16) {
                    Image(systemName: "app.fill").font(.system(size: 44)).foregroundStyle(.secondary)
                    ProgressView()
                    Text("Opening app…").font(.headline)
                }
            }
        }
    }
}
