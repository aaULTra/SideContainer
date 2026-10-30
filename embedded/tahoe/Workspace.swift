import SwiftUI

@MainActor
final class TahoeWorkspace: ObservableObject {
    static let shared = TahoeWorkspace()
    @Published var state = TahoeWindowState()
    @Published var showManagement = false
    @Published var search = ""
    @Published var showSpotlight = false
    @Published var showOverview = false
    @Published var error: String?
    @Published private(set) var launching = false
    private(set) var browsers: [UUID: TahoeBrowserSession] = [:]
    private(set) var guests: [UUID: TahoeGuestSession] = [:]
    private var hasOpenedInitialWindow = false

    func start() {
        guard !hasOpenedInitialWindow else { return }
        hasOpenedInitialWindow = true
        open(.applications)
    }

    func open(_ kind: TahoeWindowKind) {
        if kind != .browser, let window = state.windows.first(where: { $0.kind == kind }) {
            state.focus(window.id)
            return
        }
        if kind == .browser { openBrowser(); return }
        state.open(kind, title: kind == .applications ? "Applications" : kind == .files ? "Finder" : "Desktop Settings")
    }

    func openBrowser(url: URL = URL(string: "https://www.apple.com")!) {
        let session = TahoeBrowserSession(url: url)
        let id = state.open(.browser, title: "Browser")
        browsers[id] = session
    }

    func close(_ id: UUID) {
        guests.removeValue(forKey: id)?.close()
        browsers.removeValue(forKey: id)?.hibernate()
        state.close(id)
    }

    func receiveGuest(name: String, bundleID: String, dataUUID: String, completion: ((NSNumber?, Error?) -> Void)?) {
        if let existing = state.windows.first(where: { $0.kind == .guest && $0.resourceID == dataUUID }) {
            if guests[existing.id]?.terminated == true { close(existing.id) }
            else {
                state.focus(existing.id)
                guests[existing.id]?.addCompletion(completion)
                showManagement = false
                return
            }
        }
        let session = TahoeGuestSession(bundleID: bundleID, dataUUID: dataUUID, completion: completion)
        let id = state.open(.guest, title: name, resourceID: dataUUID)
        guests[id] = session
        showManagement = false
    }

    func focusGuest(dataUUID: String, url: String?) -> Bool {
        guard let window = state.windows.first(where: { $0.kind == .guest && $0.resourceID == dataUUID }),
              let session = guests[window.id], !session.terminated else { return false }
        state.focus(window.id)
        showManagement = false
        if let url { session.controller?.openURLScheme(url) }
        return true
    }

    func launch(_ app: LCAppModel) async {
        guard !launching else { return }
        launching = true
        defer { launching = false }
        do {
            if app.uiIsLocked, !(try await LCUtils.authenticateUser()) { return }
            guard app.appInfo.defaultClassicMode == 0, !app.uiIs32bit else {
                showManagement = true
                error = "This guest needs the original LiveContainer launch path. Open it from the management Apps page."
                return
            }
            // First integration milestone deliberately excludes JIT guests; their setup stays in the original UI.
            guard !app.uiIsJITNeeded else {
                showManagement = true
                error = "For this first desktop build, launch JIT guests from the management Apps page after configuring JIT."
                return
            }
            try await app.runApp(multitask: true)
        } catch { self.error = error.localizedDescription }
    }

    func performanceFullscreen(_ id: UUID) {
        for (windowID, browser) in browsers where windowID != id { browser.hibernate() }
        if state.fullscreenID != id { state.toggleFullscreen(id) }
    }
}

/// Called at LCUtils' presentation boundary, after LCAppModel has prepared the guest.
/// No signing or JIT logic is duplicated here. All PID callbacks belong to a session.
@objc(TahoeGuestRouter)
@MainActor final class TahoeGuestRouter: NSObject {
    @objc(openWithDisplayName:bundleID:dataUUID:completion:)
    static func open(displayName: String, bundleID: String?, dataUUID: String?, completion: ((NSNumber?, Error?) -> Void)?) -> Bool {
        guard let bundleID, let dataUUID, !bundleID.isEmpty, !dataUUID.isEmpty else { return false }
        TahoeWorkspace.shared.receiveGuest(name: displayName, bundleID: bundleID, dataUUID: dataUUID, completion: completion)
        return true
    }
}
