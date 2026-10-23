"""Check actual adapted extension sources against the containing app's routes."""
from pathlib import Path
import plistlib
import re
import sys
from urllib.parse import urlsplit


def check(root):
    host = plistlib.loads((root / 'LiveContainer/Info.plist').read_bytes())
    schemes = {scheme for item in host['CFBundleURLTypes'] for scheme in item['CFBundleURLSchemes']}
    model = (root / 'ShareExtension/ShareExtensionViewModel.swift').read_text()
    routes = re.findall(r'"([a-z][a-z0-9+.-]*://[^"\s]*)"', model)
    for route in routes:
        assert urlsplit(route).scheme in schemes, f'Share destination not registered by its host: {route}'
    assert {urlsplit(route).netloc for route in routes} >= {'install', 'livecontainer-launch'}
    assert 'Frameworks/SideInstallerApp.framework' in model
    assert 'Frameworks/SideStoreApp.framework' not in model
    for relative in ('ShareExtension/main.m', 'ShareExtension/ShareExtensionViewModel.swift',
                     'LaunchAppExtension/LaunchAppExtension.swift'):
        text = (root / relative).read_text()
        assert '"livecontainer"' not in text, f'Stock host fallback in {relative}'
        assert '"livecontainer-sideinstaller"' in text, f'Missing own-host route in {relative}'
    original = Path(__file__).with_name('SISharePayloadLoader.swift').read_bytes()
    assert (root / 'ShareExtension/SISharePayloadLoader.swift').read_bytes() == original
    assert 'SISharePayloadLoader.load(' in (root / 'ShareExtension/ShareModels.swift').read_text()
    print('Adapted share and shortcut destinations match the containing host')


if __name__ == '__main__':
    check(Path(sys.argv[1]))
