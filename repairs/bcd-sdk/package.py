"""Verify the PE module and add just that module to the original BCD IPA."""
import hashlib
import json
import pathlib
import plistlib
import struct
import sys
import zipfile

import pefile

original, module, out = map(pathlib.Path, sys.argv[1:])
d = module.read_bytes()
pe = pefile.PE(data=d)
assert pe.FILE_HEADER.Machine == 0xA641, 'Expected ARM64EC, matching BCD system32'
assert pe.FILE_HEADER.Characteristics & 0x2000, 'Expected a DLL'
exports = {e.name.decode() for e in pe.DIRECTORY_ENTRY_EXPORT.symbols if e.name}
assert {'DsBindA', 'DsBindW', 'DsMakeSpnW', 'DsCrackNamesW'} <= exports
# BCD pads its PE modules for the JIT mapping. Follow its extra-DLL build.
target = pe.OPTIONAL_HEADER.SizeOfImage + 0x10000
if len(d) < target:
    d += bytes(target - len(d))
module.write_bytes(d)

with zipfile.ZipFile(original) as src:
    infos = [n for n in src.namelist() if n.startswith('Payload/') and n.count('/') == 2 and n.endswith('/Info.plist')]
    assert len(infos) == 1
    info = plistlib.loads(src.read(infos[0]))
    assert info['CFBundleIdentifier'] == 'com.thebcd69.bcd'
    assert str(info['CFBundleVersion']) == '580', info
    root = infos[0].removesuffix('Info.plist')
    farm = root + 'arm64ec-windows/'
    names = {pathlib.PurePosixPath(n).name.lower() for n in src.namelist() if n.startswith(farm)}
    assert 'ntdsapi.dll' not in names
    imports = [i.dll.decode() for i in pe.DIRECTORY_ENTRY_IMPORT]
    forwards = [e.forwarder.decode().rsplit('.', 1)[0] + '.dll' for e in pe.DIRECTORY_ENTRY_EXPORT.symbols if e.forwarder]
    missing = sorted({n for n in imports + forwards if n.lower() not in names})
    assert not missing, f'New DLL dependencies absent from BCD: {missing}'
    destination = out / 'BCD-0.1.580-NTDSAPI-repair.ipa'
    entry = farm + 'ntdsapi.dll'
    with zipfile.ZipFile(destination, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as dst:
        for item in src.infolist():
            dst.writestr(item, src.read(item.filename))
        dst.writestr(entry, d)
    # Every existing bundle byte and identifier must be unchanged.
    with zipfile.ZipFile(destination) as check:
        assert check.testzip() is None
        assert set(check.namelist()) - set(src.namelist()) == {entry}
        assert all(check.read(i.filename) == src.read(i.filename) for i in src.infolist())
    report = {'base_version': '0.1.580', 'bundle_id': info['CFBundleIdentifier'],
              'wine_revision': 'a1049ce9cf37f6cf3c771dead31dcbe3b4e4a0c6',
              'machine': hex(pe.FILE_HEADER.Machine), 'imports': imports,
              'forwarded_dlls': sorted(set(forwards)), 'export_count': len(exports),
              'added_entry': entry, 'existing_entries_unchanged': True,
              'module_sha256': hashlib.sha256(d).hexdigest()}
    (out / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
