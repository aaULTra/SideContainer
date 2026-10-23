import importlib.util
import json
import plistlib
import struct
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("embedded_package", Path(__file__).with_name("package.py"))
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / "LiveContainer.app"
        self.app.mkdir()
        (self.app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": package.HOST_ID}))
        guest = self.app / "Frameworks/SideInstallerApp.framework"
        guest.mkdir(parents=True)
        (guest / "SideInstaller").write_bytes(struct.pack("<IIII", 0xfeedfacf, 0x100000c, 0, 6))
        process = self.app / "PlugIns/LiveProcess.appex"
        process.mkdir(parents=True)
        (process / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": package.HOST_ID + ".LiveProcess",
            "SIJITMultiplexedService": True, "XPCService": {"_MultipleInstances": True}}))
        for name in ("ShareExtension", "LaunchAppExtension", "SideInstallerLiveActivity"):
            extension = self.app / "PlugIns" / (name + ".appex")
            extension.mkdir()
            (extension / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": package.HOST_ID + (".PairingActivity" if name == "SideInstallerLiveActivity" else "." + name)}))
        helper = self.app / "Frameworks/SIJITSupport.framework"
        helper.mkdir(parents=True)
        (helper / "SIJITSupport").write_bytes(b"framework")
        (helper / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": package.HOST_ID + ".JITSupport",
            "CFBundleExecutable": "SIJITSupport", "CFBundlePackageType": "FMWK"}))
        jit = self.app / "Frameworks/StikJIT.framework"
        jit.mkdir()
        (jit / "StikJIT").write_bytes(b"framework")
        self.jit_info = {
            "CFBundleIdentifier": "com.stik.StikJIT", "CFBundleExecutable": "StikJIT",
            "CFBundleName": "StikJIT", "CFBundlePackageType": "FMWK",
            "CFBundleShortVersionString": "1.9.0", "CFBundleVersion": "10",
            "MinimumOSVersion": "17.4", "CFBundleSupportedPlatforms": ["iPhoneOS"]}
        self.write_jit_info()
        (jit / "universal.js").write_text("// script")
        metadata = self.app / "Metadata.appintents"
        metadata.mkdir()
        self.actions = {"actions": {"RefreshAllAppsIntent": {
            "isDiscoverable": True, "openAppWhenRun": False,
            "fullyQualifiedTypeName": "SideStoreSupport.RefreshAllAppsIntent",
            "systemProtocols": ["com.apple.link.systemProtocol.ForegroundContinuable",
                                "com.apple.link.systemProtocol.ProgressReporting"],
        }}, "autoShortcuts": [{"actionIdentifier": "RefreshAllAppsIntent"}]}
        self.write_actions()

    def write_actions(self):
        (self.app / "Metadata.appintents/extract.actionsdata").write_text(json.dumps(self.actions))

    def write_jit_info(self):
        (self.app / "Frameworks/StikJIT.framework/Info.plist").write_bytes(plistlib.dumps(self.jit_info))

    def test_missing_jit_framework_plist_is_rejected(self):
        (self.app / "Frameworks/StikJIT.framework/Info.plist").unlink()
        with self.assertRaisesRegex(ValueError, "Info.plist is missing"):
            package.verify(self.app)

    def test_jit_framework_metadata_is_validated(self):
        original = dict(self.jit_info)
        for key, value in (("CFBundlePackageType", "APPL"), ("CFBundleExecutable", "Wrong"),
                           ("CFBundleIdentifier", "$(PRODUCT_BUNDLE_IDENTIFIER)"),
                           ("MinimumOSVersion", ""), ("CFBundleSupportedPlatforms", ["iPhoneSimulator"])):
            with self.subTest(key=key):
                self.jit_info = {**original, key: value}
                self.write_jit_info()
                with self.assertRaises(ValueError):
                    package.verify(self.app)

    def test_malformed_jit_framework_plist_is_rejected(self):
        (self.app / "Frameworks/StikJIT.framework/Info.plist").write_bytes(b"not a plist")
        with self.assertRaisesRegex(ValueError, "malformed"):
            package.verify(self.app)

    def test_valid_layout(self):
        report = package.verify(self.app)
        self.assertTrue(report["nativeRefreshIntent"])
        self.assertEqual(report["provisionedBundleCount"], 5)

    def test_stock_identity_is_rejected(self):
        (self.app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.kdt.livecontainer"}))
        with self.assertRaises(AssertionError):
            package.verify(self.app)

    def test_missing_jit_helper_is_rejected(self):
        import shutil
        shutil.rmtree(self.app / "Frameworks/SIJITSupport.framework")
        with self.assertRaises(AssertionError):
            package.verify(self.app)

    def test_all_user_facing_extensions_are_preserved(self):
        import shutil
        for name in ("ShareExtension", "LaunchAppExtension", "SideInstallerLiveActivity"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                clone = Path(tmp) / "LiveContainer.app"
                shutil.copytree(self.app, clone)
                shutil.rmtree(clone / "PlugIns" / (name + ".appex"))
                with self.assertRaises(AssertionError): package.verify(clone)

    def test_old_helper_extension_is_rejected(self):
        (self.app / "PlugIns/SIJITHelper.appex").mkdir()
        with self.assertRaises(AssertionError): package.verify(self.app)

    def test_process_must_support_independent_service_instances(self):
        path = self.app / "PlugIns/LiveProcess.appex/Info.plist"
        info = plistlib.loads(path.read_bytes())
        info["XPCService"]["_MultipleInstances"] = False
        path.write_bytes(plistlib.dumps(info))
        with self.assertRaises(AssertionError): package.verify(self.app)

    def test_missing_universal_script_is_rejected(self):
        (self.app / "Frameworks/StikJIT.framework/universal.js").unlink()
        with self.assertRaises(AssertionError):
            package.verify(self.app)

    def test_side_store_app_must_not_be_shipped(self):
        (self.app / "Frameworks/SideStoreApp.framework").mkdir()
        with self.assertRaises(AssertionError):
            package.verify(self.app)

    def test_guest_executable_must_be_converted(self):
        path = self.app / "Frameworks/SideInstallerApp.framework/SideInstaller"
        path.write_bytes(struct.pack("<IIII", 0xfeedfacf, 0x100000c, 0, 2))
        with self.assertRaises(AssertionError):
            package.verify(self.app)

    def test_native_action_must_remain_discoverable(self):
        self.actions["actions"]["RefreshAllAppsIntent"]["isDiscoverable"] = False
        self.write_actions()
        with self.assertRaises(AssertionError):
            package.verify(self.app)

    def test_nested_extensions_are_rejected(self):
        (self.app / "Frameworks/SideInstallerApp.framework/PlugIns").mkdir()
        with self.assertRaises(AssertionError):
            package.verify(self.app)

    def test_wrong_extension_identity_is_rejected(self):
        (self.app / "PlugIns/LiveProcess.appex/Info.plist").write_bytes(
            plistlib.dumps({"CFBundleIdentifier": "com.kdt.livecontainer.LiveProcess"}))
        with self.assertRaises(AssertionError):
            package.verify(self.app)

    def test_entitlement_templates_resolve_to_isolated_groups(self):
        path = Path(self.temp.name) / "template.plist"
        path.write_bytes(plistlib.dumps({
            "application-identifier": "$(DEVELOPMENT_TEAM).$(PRODUCT_BUNDLE_IDENTIFIER)",
            "com.apple.security.application-groups": ["$(APP_GROUP_SIDESTORE)", "$(APP_GROUP_ALTSTORE)"],
            "keychain-access-groups": ["$(AppIdentifierPrefix)" + package.HOST_ID + ".shared"],
        }))
        result = package.entitlement_template(path, package.HOST_ID)
        self.assertEqual(result["com.apple.security.application-groups"][0], "group." + package.HOST_ID)
        self.assertNotIn("$(", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
