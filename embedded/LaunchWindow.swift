import SwiftUI
import UIKit

/// Only Main scenes carry this marker. Guest scenes can never be selected as
/// a launcher, even if they become key while signing/JIT is awaiting work.
struct SILauncherWindowMarker: UIViewRepresentable {
    final class Marker: UIView {
        weak var markedScene: UIWindowScene?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let markedScene { SILaunchWindow.launchers.removeValue(forKey: markedScene.session.persistentIdentifier) }
            markedScene = window?.windowScene
            if let markedScene { SILaunchWindow.launchers[markedScene.session.persistentIdentifier] = markedScene }
        }
    }
    func makeUIView(context: Context) -> Marker { Marker() }
    func updateUIView(_ uiView: Marker, context: Context) {}
}

@MainActor
final class SILaunchWindow {
    static var launchers: [String: UIWindowScene] = [:]
    private static var pending: [String: SILaunchWindow] = [:]
    private weak var launcher: UIWindowScene?
    private weak var guest: UIWindowScene?
    private let container: String
    private var succeeded = false

    private init(launcher: UIWindowScene, container: String) {
        self.launcher = launcher
        self.container = container
    }

    /// Capture before the first await. Ambiguous/background launches keep the
    /// launcher open; never guess by taking connectedScenes.first/anyObject.
    static func begin(container: String?, source: UIWindowScene?) -> SILaunchWindow? {
        guard LCUtils.appGroupUserDefault.integer(forKey: "LCMultitaskMode") == 1,
              let container else { return nil }
        let candidates = launchers.values.filter {
            $0.activationState == .foregroundActive && $0.windows.contains(where: { $0.isKeyWindow })
        }
        guard let launcher = source ?? (candidates.count == 1 ? candidates.first : nil),
              launchers[launcher.session.persistentIdentifier] === launcher else { return nil }
        let request = SILaunchWindow(launcher: launcher, container: container)
        pending[container] = request
        return request
    }

    static func guestReady(container: String, scene: UIWindowScene?) {
        guard let request = pending[container], let scene,
              launchers[scene.session.persistentIdentifier] == nil else { return }
        request.guest = scene
        request.closeIfReady()
    }

    func complete() {
        succeeded = true
        closeIfReady()
    }

    func cancel() {
        if Self.pending[container] === self { Self.pending.removeValue(forKey: container) }
    }

    private func closeIfReady() {
        guard Self.pending[container] === self, succeeded,
              let launcher, let guest, guest !== launcher,
              guest.activationState != .unattached,
              Self.launchers[launcher.session.persistentIdentifier] === launcher else { return }
        cancel()
        // Destroy this session only. Never exit the host, terminate guests or
        // enumerate other sessions for destruction. A refusal leaves it open.
        UIApplication.shared.requestSceneSessionDestruction(launcher.session, options: nil) { error in
            NSLog("[LC] Unable to close launcher window: %@", error.localizedDescription)
        }
    }
}
