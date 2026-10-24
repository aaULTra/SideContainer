# BCD 0.1.580 NTDSAPI dependency repair

The device log reports that `PsPcSdk.dll` cannot load because `NTDSAPI.dll` is
missing. This builds Wine's unmodified NTDSAPI module from BCD 0.1.580's exact
Wine commit, a1049ce9cf37f6cf3c771dead31dcbe3b4e4a0c6. It does not alter or
replace the PlayStation SDK, the game, LC, signing, or the built-in JIT helper.

In LiveContainer, import `BCD-0.1.580-NTDSAPI-repair.ipa` as an update to the
existing BCD guest, keeping its existing data container. Do not delete BCD.
No new iOS installation or Apple App ID is required. Keep the previously
repaired combined LC host installed.

The IPA adds only `arm64ec-windows/ntdsapi.dll`; every existing archive entry
is checked byte for byte. The module's architecture, key exports, imports and
forwarded DLL dependencies are verified against BCD's bundled 64-bit set.
`verification.json` records the checks. These are build and package checks;
they do not establish that Ghost of Tsushima or every SDK function works.

The same log also reports EVR.dll missing for `crs-video.exe`. BCD ships EVR
as an opt-in module; this repair does not enable it globally. Treat any later
missing dependency separately, using the next device log.

Rebuild on Ubuntu 24.04 with git, curl, xz-utils, build-essential, bison,
flex and Python pefile: run `bash repairs/bcd-sdk/build.sh` from this repo.
The pinned llvm-mingw toolchain is downloaded automatically. Source and
configure-only changes are included in the separate source artifact.

Wine is LGPL-2.1-or-later; see the source archive's COPYING.LIB and AUTHORS.
Source: https://github.com/thebcd69/bcd-wine/tree/a1049ce9cf37f6cf3c771dead31dcbe3b4e4a0c6
BCD original: https://github.com/thebcd69/bcd-games/releases/tag/v0.1.580
