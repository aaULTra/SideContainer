import SwiftUI

@MainActor
final class TahoeGuestSession: ObservableObject {
    let bundleID: String
    let dataUUID: String
    @Published private(set) var message: String?
    @Published private(set) var pid: Int32 = 0
    @Published private(set) var terminated = false
    private(set) var controller: AppSceneViewController?
    private var callbacks: [(NSNumber?, Error?) -> Void] = []
    private var result: Result<Int32, Error>?
    private var watchdog: DispatchWorkItem?
    private let proxy = TahoeGuestDelegate()

    init(bundleID: String, dataUUID: String, completion: ((NSNumber?, Error?) -> Void)?) {
        self.bundleID = bundleID
        self.dataUUID = dataUUID
        if let completion { callbacks.append(completion) }
        proxy.session = self
    }

    func makeController() -> UIViewController {
        if let controller { return controller }
        guard !terminated else { return UIViewController() }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.result == nil else { return }
            self.fail("The guest did not return a PID within 45 seconds.")
            self.controller?.terminate()
        }
        watchdog = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: timeout)
        controller = AppSceneViewController(bundleId: bundleID, dataUUID: dataUUID, delegate: proxy)
        if let controller { return controller }
        fail("Unable to create the guest presentation. Check LiveProcess and the installed entitlements.")
        return UIViewController()
    }

    func addCompletion(_ completion: ((NSNumber?, Error?) -> Void)?) {
        guard let completion else { return }
        if let result { deliver(result, to: completion) }
        else { callbacks.append(completion) }
    }

    fileprivate func initialized(_ vc: AppSceneViewController?, error: Error?) {
        guard !terminated else { vc?.terminate(); return }
        if let error { fail(error.localizedDescription); vc?.terminate(); return }
        guard let vc, vc.pid > 0 else { fail("LiveProcess returned no valid guest PID."); return }
        pid = vc.pid
        settle(.success(pid))
    }

    fileprivate func exited() {
        terminated = true
        if message == nil { message = "This application has exited. Close this window and launch it again." }
        settle(.failure(Self.error("The guest exited before launch completed.")))
    }

    private func fail(_ message: String) {
        self.message = message
        terminated = true
        settle(.failure(Self.error(message)))
    }

    func close() {
        terminated = true
        settle(.failure(Self.error("Guest launch cancelled because its desktop window was closed.")))
        controller?.terminate()
        controller?.delegate = nil
        controller = nil
    }

    private func settle(_ result: Result<Int32, Error>) {
        guard self.result == nil else { return }
        self.result = result
        watchdog?.cancel()
        watchdog = nil
        let callbacks = self.callbacks
        self.callbacks.removeAll()
        for callback in callbacks { deliver(result, to: callback) }
    }
    private func deliver(_ result: Result<Int32, Error>, to callback: (NSNumber?, Error?) -> Void) {
        switch result {
        case .success(let pid): callback(NSNumber(value: pid), nil)
        case .failure(let error): callback(nil, error)
        }
    }
    private static func error(_ message: String) -> NSError {
        NSError(domain: "TahoeDesktop.Guest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// The Objective-C controller retains its delegate. A weak back-reference avoids a session cycle.
@MainActor
private final class TahoeGuestDelegate: NSObject, AppSceneViewControllerDelegate {
    weak var session: TahoeGuestSession?
    func appSceneVCAppDidExit(_ vc: AppSceneViewController!) {
        DispatchQueue.main.async { [weak self] in self?.session?.exited() }
    }
    func appSceneVC(_ vc: AppSceneViewController!, didInitializeWithError error: Error!) {
        DispatchQueue.main.async { [weak self] in self?.session?.initialized(vc, error: error) }
    }
    func appSceneVCWillActivateScene(_ vc: AppSceneViewController!) {
        vc.updateSettings { settings in
            guard let settings else { return }
            // Insets belong to our content rectangle, not the entire iPad screen.
            settings.peripheryInsets = .zero
            settings.safeAreaInsetsPortrait = .zero
        }
        vc.view.setNeedsLayout()
    }
    func appSceneVC(_ vc: AppSceneViewController!, didUpdateFrom settings: UIMutableApplicationSceneSettings!,
                    transitionContext context: Any!, lifecycleActionType actionType: UInt32) {
        guard let settings else { return }
        settings.interruptionPolicy = 0
        vc.presenter?.scene.updateSettings(settings, withTransitionContext: context, completion: nil)
    }
}

struct TahoeGuestView: View {
    @ObservedObject var session: TahoeGuestSession
    var body: some View {
        ZStack {
            TahoeGuestSurface(session: session)
            if let message = session.message {
                Text(message).font(.callout).textSelection(.enabled).padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial)
            }
        }
    }
}

private struct TahoeGuestSurface: UIViewControllerRepresentable {
    let session: TahoeGuestSession
    func makeUIViewController(context: Context) -> UIViewController { session.makeController() }
    func updateUIViewController(_ vc: UIViewController, context: Context) { }
    // Minimise/fullscreen only change modifiers; no termination in dismantle.
}
