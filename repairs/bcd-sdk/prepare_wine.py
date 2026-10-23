"""Apply BCD's existing configure workarounds; the DLL source stays untouched."""
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
placeholder = root / 'dlls/ntdll/arm64ec_x64_export_iat.c'
if not placeholder.exists():
    placeholder.write_text('/* Configure-only placeholder; not used by ntdsapi. */\n')
p = root / 'tools/makedep.c'
s = p.read_text()
old = 'fatal_error( "%s must be included before other headers\\n", file->name );'
new = 'fprintf( stderr, "%s: warning: header ordering\\n", file->name );'
assert s.count(old) == 1, 'Wine header-order workaround needs review'
s = s.replace(old, new)
old = '    if (make->external) return NULL; /* ignore missing files in external libs */\n'
assert s.count(old) == 1, 'Wine shim workaround needs review'
s = s.replace(old, old + '    if (!strncmp( source->name, "ios_", 4 )) return NULL; /* external iOS shims */\n')
p.write_text(s)
