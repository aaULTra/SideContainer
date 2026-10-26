import SwiftUI
import UIKit

/// A new guest launch arms only its container's scene. Once that
/// window is attached, request fullscreen on the actual session to overcome
/// restored geometry. Never resize every connected window or keep enforcing
/// fullscreen after the launch; users may resize their apps afterwards.
@MainActor
enum SIFullscreenWindow {
    final class Request { var didRequest = false }
    static var pending: [String: Request] = [:]
    private static var completed = Set<String>()

    static func request(container: String) {
        completed.remove(container)
        pending[container] = Request()
    }

    static func isReady(container: String) -> Bool { completed.contains(container) }

    final class Probe: UIView {
        let container: String
        private var scheduled = false
        init(container: String) {
            self.container = container
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            NotificationCenter.default.addObserver(self, selector: #selector(sceneActivated(_:)),
                                                   name: UIScene.didActivateNotification, object: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { NotificationCenter.default.removeObserver(self) }

        @objc private func sceneActivated(_ notification: Notification) {
            guard let scene = notification.object as? UIWindowScene,
                  scene === window?.windowScene else { return }
            SILaunchWindow.guestReady(container: container, scene: scene)
            schedule()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene { SILaunchWindow.guestReady(container: container, scene: scene) }
            schedule()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            schedule()
        }

        func schedule() {
            guard !scheduled, SIFullscreenWindow.pending[container] != nil, window?.windowScene != nil else { return }
            scheduled = true
            // Let SwiftUI attach and restore the window before addressing the
            // real session; an activation option alone may precede restoration.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                guard let scene = self.window?.windowScene,
                      scene.activationState == .foregroundActive,
                      let request = SIFullscreenWindow.pending[self.container] else { return }
                let windowSize = scene.coordinateSpace.bounds.size
                let displaySize = scene.screen.coordinateSpace.bounds.size
                // Compare in the display's current coordinate space, including
                // landscape. Safe-area insets do not change fullscreen size.
                if abs(windowSize.width - displaySize.width) <= 1 &&
                   abs(windowSize.height - displaySize.height) <= 1 {
                    SIFullscreenWindow.pending.removeValue(forKey: self.container)
                    SIFullscreenWindow.completed.insert(self.container)
                    SILaunchWindow.fullscreenReady(container: self.container)
                    return
                }
                guard !request.didRequest else { return }
                request.didRequest = true
                let options = UIScene.ActivationRequestOptions()
                options._setRequestFullscreen(true)
                UIApplication.shared.requestSceneSessionActivation(scene.session, userActivity: nil, options: options) { error in
                    NSLog("[LC] Fullscreen activation for %@ failed: %@", self.container, error.localizedDescription)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, SIFullscreenWindow.pending[self.container] === request else { return }
                    SIFullscreenWindow.pending.removeValue(forKey: self.container)
                    // Do not keep forcing the size or close the launcher if
                    // iPadOS refused the fullscreen handoff.
                    NSLog("[LC] Fullscreen placement did not complete for %@; keeping launcher open", self.container)
                }
            }
        }
    }
}

struct SIFullscreenGuestWindow: UIViewRepresentable {
    let container: String
    func makeUIView(context: Context) -> SIFullscreenWindow.Probe { SIFullscreenWindow.Probe(container: container) }
    func updateUIView(_ view: SIFullscreenWindow.Probe, context: Context) {}
}
