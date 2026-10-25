import SwiftUI
import UIKit

/// Only Main scenes carry this marker. Guest scenes can never be selected as
/// a launcher, even if they become key while signing/JIT is awaiting work.
struct SILauncherWindowMarker: UIViewRepresentable {
    final class Marker: UIView {
        weak var markedScene: UIWindowScene?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            markedScene = window?.windowScene
            if let markedScene {
                (markedScene.delegate as? SceneDelegate)?.window = window
                SILaunchWindow.registerLauncher(markedScene)
            }
        }
    }
    func makeUIView(context: Context) -> Marker { Marker() }
    func updateUIView(_ uiView: Marker, context: Context) {}
}

@MainActor
final class SILaunchWindow {
    static var launchers: [String: UIWindowScene] = [:]
    static var guests: [String: UIWindowScene] = [:]
    static var incomingURLs: [String: [URL]] = [:]
    private static var closing = Set<String>()
    private static var pending: [String: SILaunchWindow] = [:]
    private weak var launcher: UIWindowScene?
    private weak var guest: UIWindowScene?
    private let container: String
    private var succeeded = false
    private var existingGuest = false

    static var canonicalLauncher: UIWindowScene? {
        launchers.values.first { $0.activationState != .unattached && !closing.contains($0.session.persistentIdentifier) }
    }

    static func isLauncher(_ scene: UIWindowScene?) -> Bool {
        guard let scene else { return false }
        return launchers[scene.session.persistentIdentifier] === scene
    }

    static func registerLauncher(_ scene: UIWindowScene) {
        let id = scene.session.persistentIdentifier
        guard scene.session.userInfo?["SIWindowKind"] as? String != "guest" else { return }
        var info = scene.session.userInfo ?? [:]
        info["SIWindowKind"] = "launcher"
        scene.session.userInfo = info
        if let canonical = canonicalLauncher, canonical !== scene {
            // Only this positively identified duplicate launcher is destroyed.
            // Forward its cold-start URL before discarding its session.
            for url in incomingURLs.removeValue(forKey: id) ?? [] { SILauncherRouter.shared.receive(url) }
            UIApplication.shared.requestSceneSessionActivation(canonical.session, userActivity: nil, options: nil) { error in
                NSLog("[LC] Unable to focus launcher: %@", error.localizedDescription)
            }
            destroyLauncher(scene)
            return
        }
        launchers[id] = scene
        DataManager.shared.model.mainWindowOpened = true
        incomingURLs.removeValue(forKey: id)
        SILauncherRouter.shared.pump()
    }

    static func registerGuest(_ scene: UIWindowScene, container: String) {
        guard !isLauncher(scene), scene.session.userInfo?["SIWindowKind"] as? String != "launcher" else { return }
        var info = scene.session.userInfo ?? [:]
        info["SIWindowKind"] = "guest"
        info["SIContainer"] = container
        scene.session.userInfo = info
        guests[container] = scene
    }

    static func guestExited(container: String) {
        guests.removeValue(forKey: container)
        pending.removeValue(forKey: container)
    }

    static func disconnect(_ scene: UIScene) {
        let id = scene.session.persistentIdentifier
        launchers.removeValue(forKey: id)
        guests = guests.filter { $0.value.session.persistentIdentifier != id }
        incomingURLs.removeValue(forKey: id)
        closing.remove(id)
        DataManager.shared.model.mainWindowOpened = canonicalLauncher != nil
    }

    static func resumeReadyClosures() {
        for request in Array(pending.values) { request.closeIfReady() }
    }

    static func cancelAutomaticCloses() { pending.removeAll() }

    private static func destroyLauncher(_ scene: UIWindowScene) {
        let id = scene.session.persistentIdentifier
        guard scene.session.userInfo?["SIWindowKind"] as? String == "launcher",
              !guests.values.contains(where: { $0 === scene }), closing.insert(id).inserted else { return }
        UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil) { error in
            closing.remove(id)
            NSLog("[LC] Unable to close launcher window: %@", error.localizedDescription)
        }
    }

    private init(launcher: UIWindowScene, container: String) {
        self.launcher = launcher
        self.container = container
    }

    /// Capture before the first await. Ambiguous/background launches keep the
    /// launcher open; never guess by taking connectedScenes.first/anyObject.
    static func begin(container: String?, source: UIWindowScene?) -> SILaunchWindow? {
        guard LCUtils.appGroupUserDefault.integer(forKey: "LCMultitaskMode") == 1,
              let container else { return nil }
        let candidates = launchers.values.filter { $0.activationState != .unattached && !closing.contains($0.session.persistentIdentifier) }
        guard let launcher = source ?? (candidates.count == 1 ? candidates.first : nil),
              launchers[launcher.session.persistentIdentifier] === launcher else { return nil }
        let request = SILaunchWindow(launcher: launcher, container: container)
        pending[container] = request
        return request
    }

    static func guestReady(container: String, scene: UIWindowScene?) {
        guard let scene,
              launchers[scene.session.persistentIdentifier] == nil else { return }
        registerGuest(scene, container: container)
        guard let request = pending[container] else { return }
        request.guest = scene
        request.closeIfReady()
    }

    static func fullscreenReady(container: String) {
        pending[container]?.closeIfReady()
    }

    func complete() {
        succeeded = true
        closeIfReady()
    }

    func completeExistingGuest() {
        guard let scene = Self.guests[container], !Self.isLauncher(scene) else { return }
        existingGuest = true
        guest = scene
        complete()
    }

    func cancel() {
        if Self.pending[container] === self { Self.pending.removeValue(forKey: container) }
    }

    private func closeIfReady() {
        guard Self.pending[container] === self, succeeded,
              SILauncherRouter.shared.canCloseLauncher,
              (existingGuest || SIFullscreenWindow.isReady(container: container)),
              let launcher, let guest, guest !== launcher,
              guest.activationState != .unattached,
              (!existingGuest || guest.activationState == .foregroundActive),
              Self.launchers[launcher.session.persistentIdentifier] === launcher else { return }
        cancel()
        // Destroy this session only. Never exit the host, terminate guests or
        // enumerate other sessions for destruction. A refusal leaves it open.
        Self.destroyLauncher(launcher)
    }
}
