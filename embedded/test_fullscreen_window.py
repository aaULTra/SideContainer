"""Run the real launch probe with scene doubles; no iOS rendering simulated."""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


@unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required (available on macOS CI)')
class FullscreenWindowTests(unittest.TestCase):
    def test_only_new_target_is_fullscreen_once_before_launcher_close(self):
        source = Path(__file__).with_name('FullscreenWindow.swift').read_text()
        coordinator = source[source.index('@MainActor'):source.index('struct SIFullscreenGuestWindow')]
        harness = '''import Foundation
import CoreGraphics
class Coordinates { var bounds: CGRect; init(_ bounds: CGRect) { self.bounds = bounds } }
class Display { var coordinateSpace = Coordinates(CGRect(x: 0, y: 0, width: 1024, height: 768)) }
enum Activation { case foregroundActive, background }
class Session {}
class UIScene: NSObject {
    static let didActivateNotification = Notification.Name("scene-active")
    class ActivationRequestOptions {
        var fullscreen = false
        func _setRequestFullscreen(_ value: Bool) { fullscreen = value }
    }
}
class UIWindowScene: UIScene {
    let session = Session()
    var activationState = Activation.foregroundActive
    var coordinateSpace = Coordinates(CGRect(x: 0, y: 0, width: 600, height: 400))
    let screen = Display()
}
class Window { let windowScene: UIWindowScene; init(_ scene: UIWindowScene) { windowScene = scene } }
@MainActor class UIView: NSObject {
    var window: Window?
    var isUserInteractionEnabled = true
    init(frame: CGRect) { super.init() }
    required init?(coder: NSCoder) { fatalError() }
    func didMoveToWindow() {}
    func layoutSubviews() {}
}
@MainActor class UIApplication {
    static let shared = UIApplication()
    var sessions: [Session] = []
    func requestSceneSessionActivation(_ session: Session, userActivity: Any?, options: UIScene.ActivationRequestOptions,
                                       errorHandler: (NSError) -> Void) {
        assert(options.fullscreen)
        sessions.append(session)
    }
}
@MainActor class SILaunchWindow {
    static var ready: [String] = []
    static func guestReady(container: String, scene: UIWindowScene?) {}
    static func fullscreenReady(container: String) { ready.append(container) }
}
'''
        checks = '''
@main struct Tests {
    @MainActor static func tick() async { try! await Task.sleep(nanoseconds: 30_000_000) }
    @MainActor static func main() async {
        let target = UIWindowScene()
        let other = UIWindowScene()
        let targetProbe = SIFullscreenWindow.Probe(container: "target")
        let otherProbe = SIFullscreenWindow.Probe(container: "other")
        targetProbe.window = Window(target)
        otherProbe.window = Window(other)
        SIFullscreenWindow.request(container: "target")
        targetProbe.didMoveToWindow()
        otherProbe.didMoveToWindow()
        await tick()
        assert(UIApplication.shared.sessions.count == 1)
        assert(UIApplication.shared.sessions[0] === target.session)
        assert(SILaunchWindow.ready.isEmpty) // activation alone must not close the launcher
        targetProbe.layoutSubviews()
        await tick()
        assert(UIApplication.shared.sessions.count == 1) // no repeated size enforcement
        target.coordinateSpace.bounds = target.screen.coordinateSpace.bounds
        targetProbe.layoutSubviews()
        await tick()
        assert(SILaunchWindow.ready == ["target"])
        assert(SIFullscreenWindow.isReady(container: "target"))
        target.coordinateSpace.bounds.size = CGSize(width: 500, height: 400) // user resizes afterwards
        targetProbe.layoutSubviews()
        targetProbe.didMoveToWindow() // focus/reattach does not rearm fullscreen
        await tick()
        assert(UIApplication.shared.sessions.count == 1)
        assert(other.coordinateSpace.bounds.width == 600)

        let background = UIWindowScene()
        background.activationState = .background
        let backgroundProbe = SIFullscreenWindow.Probe(container: "background")
        backgroundProbe.window = Window(background)
        SIFullscreenWindow.request(container: "background")
        backgroundProbe.didMoveToWindow()
        await tick()
        assert(UIApplication.shared.sessions.count == 1)
        background.activationState = .foregroundActive
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: background)
        await tick()
        assert(UIApplication.shared.sessions.count == 2)
        assert(UIApplication.shared.sessions[1] === background.session)
        try! await Task.sleep(nanoseconds: 2_100_000_000)
        assert(!SIFullscreenWindow.isReady(container: "background"))
        assert(SIFullscreenWindow.pending["background"] == nil) // rejected placement expires
        background.coordinateSpace.bounds = background.screen.coordinateSpace.bounds
        backgroundProbe.layoutSubviews()
        await tick()
        assert(SILaunchWindow.ready == ["target"]) // no delayed close after expiry
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            swift = root / 'Tests.swift'
            swift.write_text(harness + coordinator + checks)
            result = subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library',
                                     str(swift), '-o', str(root / 'tests')], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(root / 'tests')], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
