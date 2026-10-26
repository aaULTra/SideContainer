"""Run the actual URL router and scene-close coordinator together on macOS."""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


@unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required (available on macOS CI)')
class URLLauncherHandoffTests(unittest.TestCase):
    def test_cold_web_clip_duplicate_callbacks_preserve_the_launcher_handoff(self):
        folder = Path(__file__).parent
        source = (folder / 'LaunchWindow.swift').read_text()
        windows = source[source.index('@MainActor\nfinal class SILaunchWindow'):]
        source = (folder / 'LauncherRouter.swift').read_text()
        router = source[source.index('@MainActor'):source.index('struct SILauncherProgress')]
        harness = '''import Foundation
import Combine
class Session { let persistentIdentifier: String; var userInfo: [String: Any]?; init(_ id: String) { persistentIdentifier = id } }
enum Activation { case foregroundActive, background, unattached }
class UIScene { let session: Session; init(_ id: String) { session = Session(id) } }
class UIWindowScene: UIScene { var activationState = Activation.foregroundActive }
enum Tab { case apps, settings, sources }
class Model { var mainWindowOpened = false; var selectedTab = Tab.apps; var deepLink: URL? }
class DataManager { static let shared = DataManager(); let model = Model() }
class Defaults { func integer(forKey: String) -> Int { 1 } }
class LCUtils { static let appGroupUserDefault = Defaults() }
class SIFullscreenWindow {
    static var ready = false
    static func isReady(container: String) -> Bool { ready }
}
class UIApplication {
    static let shared = UIApplication()
    var destroyed: [String] = []
    func requestSceneSessionActivation(_ session: Session, userActivity: Any?, options: Any?, errorHandler: (NSError) -> Void) {}
    func requestSceneSessionDestruction(_ session: Session, options: Any?, errorHandler: (NSError) -> Void) {
        destroyed.append(session.persistentIdentifier)
    }
}
'''
        checks = '''
@main struct Tests {
    @MainActor static func main() {
        let url = URL(string: "livecontainer-sideinstaller://livecontainer-launch?bundle-name=Guest.app&container-folder-name=data&jit=true")!
        let router = SILauncherRouter.shared
        let launcher = UIWindowScene("launcher")
        let guest = UIWindowScene("guest")
        let unrelatedGuest = UIWindowScene("other-live-app")
        SILaunchWindow.registerGuest(unrelatedGuest, container: "other-data")
        router.receive(url) // cold-start URL arrives before Main attaches
        assert(router.activeURL == nil)
        SILaunchWindow.registerLauncher(launcher)
        let id = router.claim(url)! // first SwiftUI callback starts the task
        DataManager.shared.model.deepLink = nil
        assert(router.claim(url) == nil) // second callback cannot start a failing duplicate task
        assert(router.launcher(for: id) === launcher) // independent of which window is now key
        let handoff = SILaunchWindow.begin(container: "data", source: router.launcher(for: id))!
        SILaunchWindow.guestReady(container: "data", scene: guest)
        handoff.complete() // real JIT session completes
        router.finish(id: UUID(), success: false) // unknown/duplicate completion cannot cancel it
        assert(UIApplication.shared.destroyed.isEmpty)
        SIFullscreenWindow.ready = true
        SILaunchWindow.fullscreenReady(container: "data")
        assert(UIApplication.shared.destroyed == ["launcher"])
        router.finish(id: id, success: true)
        assert(router.activeURL == nil)
        assert(SILaunchWindow.guests["other-data"] === unrelatedGuest)

        SILaunchWindow.disconnect(launcher)
        SILaunchWindow.registerLauncher(launcher)
        UIApplication.shared.destroyed = []
        router.receive(url) // same Web Clip tapped again with guest already running
        let nextID = router.claim(url)!
        assert(nextID != id)
        let reuse = SILaunchWindow.begin(container: "data", source: router.launcher(for: nextID))!
        router.finish(id: id, success: false) // late failure from older task must not erase new handoff
        assert(router.activeURL == url)
        SIFullscreenWindow.ready = false // existing app's user-resized window is preserved
        reuse.completeExistingGuest()
        assert(UIApplication.shared.destroyed == ["launcher"])
        router.finish(id: nextID, success: true)

        SILaunchWindow.disconnect(launcher)
        SILaunchWindow.registerLauncher(launcher)
        UIApplication.shared.destroyed = []
        router.receive(url)
        let failureID = router.claim(url)!
        let failed = SILaunchWindow.begin(container: "failed-data", source: router.launcher(for: failureID))!
        failed.cancel()
        router.finish(id: failureID, success: false)
        SIFullscreenWindow.ready = true
        SILaunchWindow.guestReady(container: "failed-data", scene: guest)
        failed.complete()
        assert(UIApplication.shared.destroyed.isEmpty) // real failure still retains launcher
        assert(SILaunchWindow.guests["other-data"] === unrelatedGuest)
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            swift = root / 'Tests.swift'
            swift.write_text(harness + windows + router + checks)
            result = subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library',
                                     str(swift), '-o', str(root / 'tests')], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(root / 'tests')], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
