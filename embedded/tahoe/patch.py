"""Opt-in desktop adaptation, applied only after the existing embedded adaptation."""
import shutil
from pathlib import Path


def patch(root, replace):
    here = Path(__file__).resolve().parent
    destination = root / "LiveContainerSwiftUI/TahoeDesktop"
    destination.mkdir(exist_ok=False)
    for source in here.glob("*.swift"):
        if source.name.endswith("Tests.swift"):
            continue
        shutil.copyfile(source, destination / source.name)
    shutil.copytree(here / "Notices", destination / "Notices")

    # Preserve all startup checks, deep links, model/delegate wiring and original
    # management UI. The desktop stays mounted while management is in front.
    tabs = root / "LiveContainerSwiftUI/Views/LCTabView.swift"
    replace(tabs, "struct LCTabView: View {", "struct LCTabView: View {\n    @ObservedObject private var tahoeWorkspace = TahoeWorkspace.shared", 1)
    replace(tabs, "        .downloadAlert(helper: downloadHelper)",
            "        .opacity(tahoeWorkspace.showManagement ? 1 : 0)\n"
            "        .allowsHitTesting(tahoeWorkspace.showManagement)\n"
            "        .accessibilityHidden(!tahoeWorkspace.showManagement)\n"
            "        .overlay {\n"
            "            TahoeDesktopView()\n"
            "                .opacity(tahoeWorkspace.showManagement ? 0 : 1)\n"
            "                .allowsHitTesting(!tahoeWorkspace.showManagement)\n"
            "                .accessibilityHidden(tahoeWorkspace.showManagement)\n"
            "        }\n"
            "        .safeAreaInset(edge: .top, spacing: 0) {\n"
            "            if tahoeWorkspace.showManagement {\n"
            "                Button { tahoeWorkspace.showManagement = false } label: {\n"
            "                    Label(\"Return to Desktop\", systemImage: \"desktopcomputer\")\n"
            "                        .frame(maxWidth: .infinity).padding(8)\n"
            "                }.background(.regularMaterial)\n"
            "            }\n"
            "        }\n"
            "        .alert(\"Desktop\", isPresented: Binding(get: { tahoeWorkspace.error != nil }, set: { if !$0 { tahoeWorkspace.error = nil } })) {\n"
            "            Button(\"OK\") { tahoeWorkspace.error = nil }\n"
            "        } message: { Text(tahoeWorkspace.error ?? \"\") }\n"
            "        .downloadAlert(helper: downloadHelper)", 1)
    replace(tabs, "            dispatchURL(url: url)",
            "            tahoeWorkspace.showManagement = true\n            dispatchURL(url: url)", 1)

    utils = root / "LiveContainerSwiftUI/Utilities/LCUtils.m"
    replace(utils, "    dispatch_async(dispatch_get_main_queue(), ^{\n        if (@available(iOS 16.1, *)) {",
            "    dispatch_async(dispatch_get_main_queue(), ^{\n"
            "        if ([TahoeGuestRouter openWithDisplayName:displayName bundleID:bundleId dataUUID:dataUUID completion:completionHandler]) return;\n"
            "        if (@available(iOS 16.1, *)) {", 1)
    model = root / "LiveContainerSwiftUI/Models/LCAppModel.swift"
    replace(model,
            "    private func bringExistingMultitaskWindowIfNeeded(dataUUID: String, urlScheme: String?) async -> Bool {",
            "    private func bringExistingMultitaskWindowIfNeeded(dataUUID: String, urlScheme: String?) async -> Bool {\n"
            "        if await MainActor.run(body: { TahoeWorkspace.shared.focusGuest(dataUUID: dataUUID, url: urlScheme) }) { return true }", 1)

    # A close during beginExtensionRequest must kill the eventual child before
    # scene creation, even if no PID existed at the time of the close request.
    scene = root / "MultitaskSupport/AppSceneViewController.m"
    replace(scene, "@property int resizeDebounceToken;",
            "@property int resizeDebounceToken;\n@property(atomic) BOOL tahoeTerminationRequested;", 1)
    replace(scene, "- (void)terminate {\n    if(self.isAppRunning) {",
            "- (void)terminate {\n    self.tahoeTerminationRequested = YES;\n    if(self.isAppRunning) {", 1)
    replace(scene, "            self.pid = [self.extension pidForRequestIdentifier:self.identifier];",
            "            self.pid = [self.extension pidForRequestIdentifier:self.identifier];\n"
            "            if (self.tahoeTerminationRequested) {\n"
            "                [self terminate];\n"
            "                [self appTerminationCleanUp];\n"
            "                return;\n"
            "            }", 1)
    replace(scene, "                [self setUpAppPresenter];",
            "                if (!self.tahoeTerminationRequested) [self setUpAppPresenter];", 1)
    (root / ".tahoe-adapted").write_text("desktop-v1\n")
