"""Portable import-parser tests. Synthetic DLL only; no third-party binaries."""
import pathlib, struct, subprocess, tempfile

def fixture(wide=True):
    d=bytearray(4096);d[:2]=b'MZ';struct.pack_into('<I',d,60,128);d[128:132]=b'PE\0\0'
    optional=240 if wide else 224
    struct.pack_into('<HH',d,132,0x8664 if wide else 0x14c,1);struct.pack_into('<H',d,148,optional)
    o=152;struct.pack_into('<H',d,o,0x20b if wide else 0x10b)
    struct.pack_into('<Q' if wide else '<I',d,o+(24 if wide else 28),0x180000000 if wide else 0x400000)
    struct.pack_into('<I',d,o+(108 if wide else 92),16)
    directories=o+(112 if wide else 96)
    struct.pack_into('<II',d,directories+8,0x1100,40)
    struct.pack_into('<II',d,directories+13*8,0x1200,64)
    s=o+optional;struct.pack_into('<IIII',d,s+8,3072,0x1000,3072,1024)
    at=lambda r:1024+r-0x1000
    struct.pack_into('<IIIII',d,at(0x1100),0x1300,0,0,0x1400,0x1300)
    struct.pack_into('<IIIIIIII',d,at(0x1200),1,0x1440,0,0x1340,0x1340,0,0,0)
    def put(r,b): d[at(r):at(r)+len(b)]=b
    put(0x1400,b'NTDSAPI.dll\0');put(0x1440,b'OPTIONAL.dll\0')
    struct.pack_into('<QQQ' if wide else '<III',d,at(0x1300),0x1500,(1<<(63 if wide else 31))|7,0)
    struct.pack_into('<QQ' if wide else '<II',d,at(0x1340),0x1540,0)
    put(0x1500,b'\0\0DsGetSpnA\0');put(0x1540,b'\0\0DelayedFunction\0')
    return d

if __name__=='__main__':
    import sys
    cli=sys.argv[1]
    with tempfile.TemporaryDirectory() as folder:
        p=pathlib.Path(folder)/'synthetic.dll'
        for wide in (True,False):
            data=fixture(wide);p.write_bytes(data)
            result=subprocess.run([cli,str(p)],capture_output=True,text=True,check=True)
            assert result.stdout.splitlines()==['NTDSAPI.dll|DsGetSpnA|0','NTDSAPI.dll|#7|0','OPTIONAL.dll|DelayedFunction|1'],result
            for end in [0,1,63,64,128,151,152,153,375,511,1024,1400,2300]:
                p.write_bytes(data[:end]);r=subprocess.run([cli,str(p)],capture_output=True)
                assert r.returncode==2,(end,r)
            data[148:150]=b'\0\0';p.write_bytes(data[:152]);assert subprocess.run([cli,str(p)],capture_output=True).returncode==2
        pathlib.Path('runtime-test/synthetic-sdk.dll').write_bytes(fixture())
    print('PE32/PE32+ normal, delay, ordinal and truncated import tests passed')
