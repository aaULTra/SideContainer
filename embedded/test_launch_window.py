"""Run the actual handoff logic against scene/session doubles on macOS CI.

UIKit rendering and OS scene destruction still require an iPad device test.
"""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


@unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required (available on macOS CI)')
class LaunchWindowTests(unittest.TestCase):
    def test_scene_isolation_and_handoff_order(self):
        source = Path(__file__).with_name('LaunchWindow.swift').read_text()
        # Compile the production coordinator, replacing only the UIKit surface.
        coordinator = source[source.index('@MainActor\nfinal class SILaunchWindow'):]
        harness = '''import Foundation
class Session { let persistentIdentifier: String; init(_ id: String) { persistentIdentifier = id } }
enum Activation { case foregroundActive, background, unattached }
class Window { var isKeyWindow = true }
class UIWindowScene {
    let session: Session
    var activationState = Activation.foregroundActive
    var windows = [Window()]
    init(_ id: String) { session = Session(id) }
}
class Defaults {
    var mode = 1
    func integer(forKey: String) -> Int { mode }
}
class LCUtils { static let appGroupUserDefault = Defaults() }
class SIFullscreenWindow {
    static var ready = true
    static func isReady(container: String) -> Bool { ready }
}
class UIApplication {
    static let shared = UIApplication()
    var destroyed: [String] = []
    func requestSceneSessionDestruction(_ session: Session, options: Any?, errorHandler: (NSError) -> Void) {
        destroyed.append(session.persistentIdentifier)
    }
}
'''
        checks = '''
@main struct Tests {
    @MainActor static func main() {
        let launcher = UIWindowScene("launcher")
        let guest = UIWindowScene("new-app")
        let other = UIWindowScene("other-app")
        SILaunchWindow.launchers = ["launcher": launcher]
        let first = SILaunchWindow.begin(container: "one", source: launcher)!
        SILaunchWindow.guestReady(container: "unrelated", scene: other)
        first.complete()
        assert(UIApplication.shared.destroyed.isEmpty)
        SIFullscreenWindow.ready = false
        SILaunchWindow.guestReady(container: "one", scene: guest)
        assert(UIApplication.shared.destroyed.isEmpty)
        SIFullscreenWindow.ready = true
        SILaunchWindow.fullscreenReady(container: "one")
        assert(UIApplication.shared.destroyed == ["launcher"])
        SILaunchWindow.guestReady(container: "one", scene: guest)
        assert(UIApplication.shared.destroyed.count == 1)

        UIApplication.shared.destroyed = []
        let second = SILaunchWindow.begin(container: "two", source: launcher)!
        SILaunchWindow.guestReady(container: "two", scene: guest)
        assert(UIApplication.shared.destroyed.isEmpty)
        second.complete()
        assert(UIApplication.shared.destroyed == ["launcher"])

        UIApplication.shared.destroyed = []
        let cancelled = SILaunchWindow.begin(container: "cancel", source: launcher)!
        cancelled.cancel()
        cancelled.complete()
        SILaunchWindow.guestReady(container: "cancel", scene: guest)
        assert(UIApplication.shared.destroyed.isEmpty)

        let old = SILaunchWindow.begin(container: "replace", source: launcher)!
        let current = SILaunchWindow.begin(container: "replace", source: launcher)!
        old.cancel()
        old.complete()
        SILaunchWindow.guestReady(container: "replace", scene: guest)
        assert(UIApplication.shared.destroyed.isEmpty)
        current.complete()
        assert(UIApplication.shared.destroyed == ["launcher"])

        UIApplication.shared.destroyed = []
        let same = SILaunchWindow.begin(container: "same", source: launcher)!
        SILaunchWindow.guestReady(container: "same", scene: launcher)
        same.complete()
        assert(UIApplication.shared.destroyed.isEmpty)
        same.cancel()
        assert(SILaunchWindow.begin(container: "guest-source", source: guest) == nil)

        let anotherLauncher = UIWindowScene("another-launcher")
        SILaunchWindow.launchers["another-launcher"] = anotherLauncher
        assert(SILaunchWindow.begin(container: "ambiguous", source: nil) == nil)
        let explicit = SILaunchWindow.begin(container: "explicit", source: launcher)!
        SILaunchWindow.guestReady(container: "explicit", scene: guest)
        explicit.complete()
        assert(UIApplication.shared.destroyed == ["launcher"])

        UIApplication.shared.destroyed = []
        let detached = SILaunchWindow.begin(container: "detached", source: launcher)!
        SILaunchWindow.launchers.removeValue(forKey: "launcher")
        SILaunchWindow.guestReady(container: "detached", scene: guest)
        detached.complete()
        assert(UIApplication.shared.destroyed.isEmpty)
        detached.cancel()
        LCUtils.appGroupUserDefault.mode = 0
        assert(SILaunchWindow.begin(container: "virtual", source: anotherLauncher) == nil)
        print("Scene isolation and handoff checks passed")
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            swift = root / 'Tests.swift'
            swift.write_text(harness + coordinator + checks)
            subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', str(swift),
                            '-o', str(root / 'tests')], check=True, capture_output=True, text=True)
            subprocess.run([str(root / 'tests')], check=True, capture_output=True, text=True)
