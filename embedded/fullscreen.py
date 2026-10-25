"""Cover modern scene activation and fullscreen handoff to a concrete guest."""
from pathlib import Path
import shutil


def patch(root, replace):
    here = Path(__file__).resolve().parent
    shutil.copyfile(here / 'FullscreenActivation.m.inc',
                    root / 'LiveContainerSwiftUI/Utilities/SIFullscreenActivation.inc')
    shutil.copyfile(here / 'FullscreenWindow.swift',
                    root / 'LiveContainerSwiftUI/Utilities/SIFullscreenWindow.swift')
    replace(root / 'LiveContainerSwiftUI/Utilities/LCUtils.h',
            '@interface LCUtils : NSObject',
            '@interface SIFullscreenActivationHooks : NSObject\n+ (void)install;\n@end\n\n'
            '@interface LCUtils : NSObject', 1)
    utils = root / 'LiveContainerSwiftUI/Utilities/LCUtils.m'
    replace(utils, '@implementation LCUtils',
            '#include "SIFullscreenActivation.inc"\n\n@implementation LCUtils', 1)
    delegate = root / 'LiveContainerSwiftUI/App/AppDelegate.swift'
    replace(delegate, '        // remove symbol caches if user upgraded iOS',
            '        SIFullscreenActivationHooks.install()\n\n'
            '        // remove symbol caches if user upgraded iOS', 1)
    window = root / 'MultitaskSupport/MultitaskAppWindow.swift'
    replace(window, '        openWindow(id: "appView", value: dataUUID)',
            '        SIFullscreenWindow.request(container: dataUUID)\n'
            '        openWindow(id: "appView", value: dataUUID)', 1)
    replace(window, '            .navigationTitle(Text("\\(appInfo.displayName) - \\(String(pid))"))',
            '            .background(SIFullscreenGuestWindow(container: appInfo.dataUUID))\n'
            '            .navigationTitle(Text("\\(appInfo.displayName) - \\(String(pid))"))', 1)
