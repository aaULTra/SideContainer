"""Package the Wine-only repair while preserving original instruction sections."""
import argparse
import copy
import hashlib
import json
import pathlib
import plistlib
import zipfile
from macho_guard import MachO

BASE_SHA='044991815fd5712ad49bc5e8c433d3a4a829a6ea61c994b2536ecf39fcdacb27'

def prepare(ipa, work):
    assert hashlib.sha256(ipa.read_bytes()).hexdigest()==BASE_SHA,'Unexpected base IPA: rebuild against its own metadata'
    work.mkdir(exist_ok=True,parents=True)
    with zipfile.ZipFile(ipa) as z:
        (work/'Madeira').write_bytes(z.read('Payload/Madeira.app/Madeira'))

def package(ipa,dylib,out):
    assert hashlib.sha256(ipa.read_bytes()).hexdigest()==BASE_SHA
    out.mkdir(exist_ok=True,parents=True)
    root='Payload/Madeira.app/'
    binary=root+'Madeira';config=root+'recommendations.json';lib=root+'Frameworks/BCDStartupGuard.dylib'
    assert MachO(dylib.read_bytes()).cpu==0x100000c,'The guard must target arm64 iOS'
    with zipfile.ZipFile(ipa) as src:
        assert lib not in src.namelist()
        info=plistlib.loads(src.read(root+'Info.plist'))
        assert info['CFBundleIdentifier']=='com.thebcd69.bcd' and str(info['CFBundleVersion'])=='580'
        before=src.read(binary);m=MachO(before)
        after=m.inject('@loader_path/Frameworks/BCDStartupGuard.dylib')
        assert MachO(after).startup_metadata()==m.startup_metadata()
        recs=json.loads(src.read(config));old_recs=copy.deepcopy(recs)
        ghost=next(r for r in recs['rules'] if r['id']=='ghost-of-tsushima')
        assert ghost['version']==3
        assert not any(x.lstrip().startswith('env.MADEIRA_OPTIN_DLLS') for x in ghost['config'])
        ghost['config'].append('env.MADEIRA_OPTIN_DLLS = evr,dxva2')
        ghost['version']=4
        ghost['notes'].append('Wine compatibility repair: enable EVR and its DXVA2 dependency for crs-video.exe. Other game settings are unchanged.')
        recs['version']+=1
        assert [r for r in recs['rules'] if r['id']!='ghost-of-tsushima']==[r for r in old_recs['rules'] if r['id']!='ghost-of-tsushima']
        updated_recs=(json.dumps(recs,ensure_ascii=False,indent=2)+'\n').encode()
        changed={binary:after,config:updated_recs}
        target=out/'BCD-0.1.580-Wine-repair-v2.ipa'
        with zipfile.ZipFile(target,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as dst:
            for item in src.infolist():dst.writestr(copy.copy(item),changed.get(item.filename,src.read(item.filename)))
            dst.writestr(lib,dylib.read_bytes())
        with zipfile.ZipFile(target) as check:
            assert check.testzip() is None
            assert set(check.namelist())-set(src.namelist())=={lib}
            assert all(check.read(n)==src.read(n) for n in src.namelist() if n not in changed)
            assert check.read(root+'arm64ec-windows/ntdsapi.dll')==src.read(root+'arm64ec-windows/ntdsapi.dll')
        report={'base_sha256':BASE_SHA,'ipa_sha256':hashlib.sha256(target.read_bytes()).hexdigest(),
                'bundle_id':info['CFBundleIdentifier'],'modified_entries':list(changed),'added_entry':lib,
                'all_other_entries_unchanged':True,'original_executable_instructions_unchanged':True,
                'ghost_recommendation_version':ghost['version'],'guard_timeout_seconds':10,
                'guard_metadata':m.startup_metadata(),'device_test_pending':True}
        (out/'RuntimeRepair.json').write_text(json.dumps(report,indent=2)+'\n')
        print(json.dumps(report,indent=2))

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('mode',choices=['prepare','package']);parser.add_argument('ipa',type=pathlib.Path)
    parser.add_argument('--work',type=pathlib.Path);parser.add_argument('--dylib',type=pathlib.Path);parser.add_argument('--out',type=pathlib.Path)
    args=parser.parse_args()
    if args.mode=='prepare':prepare(args.ipa,args.work)
    else:package(args.ipa,args.dylib,args.out)
