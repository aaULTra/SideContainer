"""Exercise the real bootstrap fragment with a dynamically loaded ObjC bridge.

Runs on the macOS build runner; no iOS device or signing identity is needed.
"""
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


@unittest.skipUnless(sys.platform == "darwin", "requires Objective-C Foundation on macOS")
class SigningBootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.host = self.root / "LiveContainer.app"
        self.host.mkdir()
        (self.host / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "test.host"}))
        harness = self.root / "bootstrap.m"
        harness.write_text('''#import <Foundation/Foundation.h>
#import <dlfcn.h>
static BOOL isSideStore = YES;
static BOOL isLiveProcess;
static NSBundle *lcMainBundle;
static NSString *check(void) {
#include "SigningBridgeBootstrap.m.inc"
    return nil;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        lcMainBundle = [NSBundle bundleWithPath:@(argv[1])];
        isLiveProcess = atoi(argv[2]);
        NSCAssert(!NSClassFromString(@"LCUtils"), @"Bridge must initially be unloaded");
        NSString *error = check();
        if (error) { puts(error.UTF8String); return 1; }
        NSCAssert(NSClassFromString(@"LCUtils"), @"Bridge did not load");
        puts("Signing bridge loaded before guest entry");
        return 0;
    }
}
''')
        self.runner = self.root / "bootstrap"
        self.compile(harness, self.runner, "-I", str(Path(__file__).parent.resolve()))

    def compile(self, source, output, *extra):
        subprocess.run(["clang", "-fobjc-arc", "-framework", "Foundation",
                        *extra, str(source), "-o", str(output)], check=True, capture_output=True)

    def make_bridge(self, complete=True):
        framework = self.host / "Frameworks/LiveContainerSwiftUI.framework"
        framework.mkdir(parents=True)
        source = self.root / "bridge.m"
        methods = "+ (void)embeddedActivateCertificate:(id)a password:(id)b hostBundle:(id)c {}\n"
        if complete:
            methods += "+ (void)embeddedValidateJITLessWithHostBundle:(id)a completion:(id)b {}\n"
        source.write_text("#import <Foundation/Foundation.h>\n@interface LCUtils : NSObject\n@end\n"
                          + "@implementation LCUtils\n" + methods + "@end\n")
        self.compile(source, framework / "LiveContainerSwiftUI", "-dynamiclib")

    def run_bootstrap(self, bundle=None, live_process=False):
        return subprocess.run([str(self.runner), str(bundle or self.host), str(int(live_process))],
                              capture_output=True, text=True)

    def test_bridge_is_loaded_before_guest_entry(self):
        self.make_bridge()
        result = self.run_bootstrap()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_live_process_resolves_enclosing_host(self):
        self.make_bridge()
        extension = self.host / "PlugIns/LiveProcess.appex"
        extension.mkdir(parents=True)
        (extension / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "test.host.process"}))
        result = self.run_bootstrap(extension, True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_framework_reports_loader_failure(self):
        result = self.run_bootstrap()
        self.assertEqual(result.returncode, 1)
        self.assertIn("host signing framework could not load", result.stdout)

    def test_old_framework_reports_missing_method(self):
        self.make_bridge(complete=False)
        result = self.run_bootstrap()
        self.assertEqual(result.returncode, 1)
        self.assertIn("embeddedValidateJITLessWithHostBundle:completion:", result.stdout)


if __name__ == "__main__":
    unittest.main()
