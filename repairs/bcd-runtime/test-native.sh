#!/usr/bin/env bash
set -euo pipefail
R="$PWD"
mkdir -p runtime-test
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined repairs/bcd-runtime/PEImports.c repairs/bcd-runtime/PEImportsCLI.c -o runtime-test/pe-imports
python3 repairs/bcd-runtime/test-pe.py runtime-test/pe-imports
clang -fobjc-arc -O0 -g -I repairs/bcd-runtime repairs/bcd-runtime/DiagnosticsTests.m repairs/bcd-runtime/ExceptionJournal.m repairs/bcd-runtime/DiagnosticsCore.m repairs/bcd-runtime/PEImports.c -framework Foundation -o runtime-test/diagnostics
runtime-test/diagnostics
clang -fobjc-arc -O0 -g -I repairs/bcd-runtime repairs/bcd-runtime/JournalTests.m repairs/bcd-runtime/ExceptionJournal.m repairs/bcd-runtime/DiagnosticsCore.m repairs/bcd-runtime/PEImports.c -framework Foundation -o runtime-test/journal
runtime-test/journal
clang -std=c11 -Wall -Wextra -Werror repairs/bcd-runtime/ReadinessTests.c -o runtime-test/readiness
runtime-test/readiness
clang -O0 -g -Wl,-export_dynamic -Wl,-no_fixup_chains -Wl,-headerpad,0x4000 repairs/bcd-runtime/GuardFixture.c -o runtime-test/fixture
python3 repairs/bcd-runtime/macho_guard.py runtime-test/fixture --header runtime-test/GuardImage.h --inject @loader_path/libFixtureGuard.dylib
clang -fobjc-arc -O0 -g -dynamiclib -DBCD_GUARD_FIXTURE=1 -DBCD_GUARD_TIMEOUT=0.1 -I runtime-test \
  -I repairs/bcd-runtime repairs/bcd-runtime/BCDStartupGuard.m repairs/bcd-runtime/ExceptionJournal.m repairs/bcd-runtime/DiagnosticsCore.m repairs/bcd-runtime/DiagnosticsUI.m repairs/bcd-runtime/PEImports.c -framework Foundation \
  -install_name @rpath/libFixtureGuard.dylib -o runtime-test/libFixtureGuard.dylib
codesign --force --sign - runtime-test/libFixtureGuard.dylib runtime-test/fixture
for scenario in ready delayed timeout stopped unrelated config othergame; do
  runtime-test/fixture "$scenario"
done
python3 - <<'PY'
from pathlib import Path
import struct
d=bytearray(Path('runtime-test/fixture').read_bytes());off=32
for i in range(struct.unpack_from('<I',d,16)[0]):
 cmd,size=struct.unpack_from('<II',d,off)
 if cmd==0x1b:
  d[off+8]=(d[off+8]+1)%256
  Path('runtime-test/fixture-lc-uuid').write_bytes(d)
  d[off+10]^=1
  Path('runtime-test/fixture-unmatched').write_bytes(d)
  break
 off+=size
else:raise AssertionError('UUID not found')
PY
chmod +x runtime-test/fixture-lc-uuid runtime-test/fixture-unmatched
codesign --force --sign - runtime-test/fixture-lc-uuid runtime-test/fixture-unmatched
runtime-test/fixture-lc-uuid ready
runtime-test/fixture-unmatched unmatched
