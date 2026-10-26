"""Exercise the production URL queue and failure recovery on the macOS runner."""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


@unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required (available on macOS CI)')
class LauncherRouterTests(unittest.TestCase):
    def test_url_queue_deduplication_and_failure_recovery(self):
        source = Path(__file__).with_name('LauncherRouter.swift').read_text()
        coordinator = source[source.index('@MainActor'):source.index('struct SILauncherProgress')]
        harness = '''import Foundation
import Combine
class UIWindowScene: NSObject {}
enum Tab { case apps, settings, sources }
class Model { var selectedTab = Tab.sources; var deepLink: URL? }
class DataManager { static let shared = DataManager(); let model = Model() }
@MainActor class SILaunchWindow {
    static var canonicalLauncher: UIWindowScene?
    static func isLauncher(_ scene: UIWindowScene?) -> Bool { scene != nil && scene === canonicalLauncher }
    static var cancellations = 0
    static var resumes = 0
    static func cancelAutomaticCloses() { cancellations += 1 }
    static func resumeReadyClosures() { resumes += 1 }
}
'''
        checks = '''
@main struct Tests {
    @MainActor static func main() {
        let router = SILauncherRouter.shared
        let a = URL(string: "livecontainer-sideinstaller://livecontainer-launch?bundle-name=A%26%20B.app&container-folder-name=one&jit=true")!
        let b = URL(string: "livecontainer-sideinstaller://livecontainer-launch?bundle-name=Other.app&jit=false")!
        assert(SILauncherRouter.isAppLaunch(a))
        assert(!SILauncherRouter.isAppLaunch(URL(string: "livecontainer-sideinstaller://livecontainer-launch?bundle-name=ui")!))
        assert(!SILauncherRouter.isAppLaunch(URL(string: "https://livecontainer-launch?bundle-name=wrong.app")!))
        router.receive(a) // cold start waits for the launcher to attach
        assert(router.activeURL == nil && DataManager.shared.model.deepLink == nil)
        let launcher = UIWindowScene()
        SILaunchWindow.canonicalLauncher = launcher
        router.pump()
        assert(router.activeURL == a && DataManager.shared.model.deepLink == a)
        assert(DataManager.shared.model.selectedTab == .apps)
        let firstID = router.claim(a)!
        assert(router.claim(a) == nil) // onAppear and onChange cannot both launch
        assert(router.launcher(for: firstID) === launcher)
        router.receive(a) // repeated Home Screen taps do not duplicate JIT
        router.receive(b)
        router.receive(b)
        assert(!router.canCloseLauncher)
        router.finish(id: firstID, success: true)
        router.finish(id: firstID, success: false) // stale failure must not cancel b
        assert(SILaunchWindow.cancellations == 0)
        assert(router.activeURL == b && DataManager.shared.model.deepLink == b)
        assert(router.canCloseLauncher)
        let secondID = router.claim(b)!
        assert(secondID != firstID)
        router.finish(id: secondID, success: true)
        assert(router.activeURL == nil && SILaunchWindow.resumes == 1)
        router.receive(a)
        router.receive(b)
        let cancelledID = router.claim(a)!
        router.finish(id: cancelledID, success: false) // locks/auth/JIT failure leaves library available
        assert(router.activeURL == nil && router.canCloseLauncher)
        assert(SILaunchWindow.cancellations == 1)
        router.receive(a) // same icon works again after cancellation
        assert(router.activeURL == a)
        let retryID = router.claim(a)!
        assert(retryID != cancelledID)
        router.finish(id: cancelledID, success: false)
        assert(router.activeURL == a)
        router.finish(id: retryID, success: true)
        let settings = URL(string: "livecontainer-sideinstaller://certificate")!
        router.receive(settings)
        assert(router.activeURL == nil && DataManager.shared.model.deepLink == settings)
        assert(DataManager.shared.model.selectedTab == .settings)
        let items = URLComponents(url: a, resolvingAgainstBaseURL: false)!.queryItems!
        assert(items.first { $0.name == "bundle-name" }!.value == "A& B.app")
        assert(items.first { $0.name == "container-folder-name" }!.value == "one")
        assert(items.first { $0.name == "jit" }!.value == "true")
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
