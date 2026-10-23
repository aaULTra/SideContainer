# BCD 0.1.580 Wine repair v2

This extends the NTDSAPI repair with Wine startup checks and Ghost of Tsushima's
video-helper dependencies. It preserves the original executable instructions,
renderer, Wine libraries, JIT implementation, signing identity and bundle IDs.

The main executable receives one additional library load command and one
same-length log-string correction: the old two-second wait now reports that
the wait ended rather than claiming that Wine's server is ready. Its original
code sections and section layout are checked byte for byte.

`BCDStartupGuard.dylib` changes one data import slot for `socketpair`. It only
guards callers within the original `wine_process_start` function, identified
by the exact pinned image's UUID, instruction fingerprints and function
boundaries. Other socketpairs are forwarded immediately. It requires the
Wine server to be both running and ready before making the client connection,
waits at most ten additional seconds for slow initialization, and refuses a
stopped or timed-out server with a clear log and an iOS alert. It does not
create the client sockets or inject a client on those failures.
During this check it keeps BCD's client-running flag false, so the library
does not mistake a slow server initialization for a game that has started.

For `GhostOfTsushima.exe` only, it checks that NTDSAPI, EVR and DXVA2 are in the
bundle, then merges `evr,dxva2` into the game's effective opt-in DLL setting.
Other settings are preserved; before a config change it makes a one-time
`<game>.cfg.before-wine-repair` backup. Repeated starts do not append duplicate
settings. If no per-game config is supplied, only the session environment is
updated. A matching baked recommended profile is also included.

Import `BCD-0.1.580-Wine-repair-v2.ipa` into LiveContainer and replace the existing
BCD entry. Keep its existing data container. No new Apple App ID is needed.
No reset of the game's other settings is required.

Validation includes pure readiness-state tests, native macOS dyld integration
tests of the actual import-slot hook, success/delay/failure/timeout cases,
unrelated calls, other-game settings, LiveContainer's UUID adjustment, a
mismatched image, config backup/idempotency, and full IPA comparisons. These
tests do not run iOS Metal, JIT, Wine or the game itself. On-device testing is
still required. Look for `[BCD-WineStartup] Readiness guard installed` and
`server VERIFIED ready` in the device log.

The main image is the original BCD 0.1.580, except the two bounded metadata/
log changes described above. Original BCD source and notices:
https://github.com/thebcd69/bcd-games/releases/tag/v0.1.580
The accompanying source archive includes the prior NTDSAPI source and all
new runtime-guard sources, tests and packaging scripts. The new repair code
is provided under GPL-3.0-or-later, compatible with BCD's distribution.
