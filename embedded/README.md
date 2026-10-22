# LiveContainer + SideInstaller (experimental embedded flavour)

## BCD Wine socket compatibility (experimental)

For the `com.thebcd69.bcd` guest (including signed identifier suffixes), the
bootstrap logs Wine's `.wineserver/server-*/socket` binds. If the original bind
fails with EPERM or EACCES, it retries inside a private, process-owned temporary
directory. Only a successful retry registers a relocation; connect, chmod and
unlink then use the same target, including on a Wine server restart. Other
guests, TCP/UDP, unrelated sockets, successful binds and other errors retain
their original behaviour. Socket-length limits are checked without changing
the process working directory. This adds no identifiers or entitlements.
Guest detection uses LC's captured original identifier, so enabling its
"Use LiveContainer Bundle ID" option does not disable the workaround.

`[LC-WineSocket]` messages go to stderr (which BCD captures in its log during
Wine startup) and `Documents/LC-WineSocket.log` inside BCD's data container. A
retry can still be refused by iPadOS; the log records both errors, and an
on-device test is required before claiming that this fixes a particular build.
Native tests use real sockets and traffic, injecting only the original bind's
permission denial, and run on the macOS build runner.

## Built-in guest JIT (experimental)

Settings → JIT → **Built-in StikJIT (experimental)** enables an invisible
`SIJITHelper.appex` bundled in the actual host. StikJIT is built from pinned
sources at `32287268fa5824f9edce4cb359f5833ce0cf7b00`, with one checked lifetime fix
to hold ScriptRunner alive through its synchronous JavaScript callbacks:
<https://github.com/StikDebug/StikJIT>. The framework is linked only into the
helper and stored in the host's Frameworks directory. Its MPL license and
source reference and modified MPL source travel in EmbeddedSourceNotices.

Import a valid pairing plist in the JIT section, enable Developer Mode, and
connect LocalDevVPN. Keep **all app extensions** when signing the IPA. Mark the
guest as needing JIT using its existing settings. The selected guest's script
is passed unchanged as base64; without one, StikJIT's bundled universal.js is
used. Force configured JIT script is off by default and bypasses TXM detection
only when explicitly enabled. Guests must implement their script's protocol;
this integration does not add a JIT allocator to an incompatible guest.

Before launch, the host prepares the DDI through StikJIT, checks the signed
LiveProcess executable's get-task-allow and validates helper/group availability.
Built-in JIT uses LC's existing LiveProcess PID callback, never the UI PID.
The request pauses that guest until debugger attachment, then leaves its JIT
memory preparation and detach handshake to the guest runtime and chosen script.
Success means StikJIT's session completed, not merely an extension launch or
CS_DEBUGGED. Preparation has a ten-minute deadline; script execution has a
three-minute deadline. The helper removes its temporary pairing file on normal
exit, cancellation watchdog exit, or the next request after abrupt termination.

Built-in JIT forces LiveProcess mode for JIT guests. Classic mode is rejected
with an actionable error. Existing external StikDebug options remain available
and unchanged. It never silently switches methods after failure. Cancellation
ends the debugger helper; because StikJIT has blocking APIs, an attached guest
may need to be closed and relaunched. Status and Cancel JIT are in Settings.
This integration still requires real-device iOS/iPadOS 27 testing, including
Husk startup, region preparation, guest relaunch, cancellation and reboot.

Husk's APK runtime is not embedded by this change. This adds script-capable JIT
for a Husk IPA (or another compatible guest) imported into LiveContainer.

This is a **personal evaluation build**, not an official LiveContainer or
SideInstaller release. SideInstaller by FrizzleM:
<https://github.com/FrizzleM/SideInstaller>. LiveContainer:
<https://github.com/LiveContainer/LiveContainer>. Their licenses and copyright
notices remain in force. Do not publish or commercially redistribute the
combined binary without resolving the upstream licensing requirements.

## Architecture

The build pins LiveContainer to `4dbe0f9a626de801184a42c0be8d2cb105058e3d`.
It adapts the existing embedded-SideStore loader, converts the **locally built**
SideInstaller executable with upstream's `dylibify` tool, and embeds it as
`Frameworks/SideInstallerApp.framework`. It does not include a SideStore app.

Upstream's internal `builtinSideStore` selector, `isSideStore` flag,
`SideStoreSupport` target and some filenames are intentionally retained to
minimize changes to the loader. They denote the **built-in sideloader slot** in
this build. They do not select SideStore's signing or installation code.

The original LiveProcess/XPC transport starts SideInstaller for the host's
native Refresh All Apps action. `SIEmbeddedBridge` invokes the existing
`AppRefreshService` and Engine. Progress, result dialogs and cancellation cross
that transport. Missing listeners, launch timeouts and process interruption
produce errors rather than unresumed continuations. No private App Intent
runner is used for execution. Background 2FA fails with an instruction to sign
in in the visible embedded UI, rather than waiting for an invisible sheet.

`EmbeddedRefreshLease` uses an OS-held file lock in the shared SideInstaller
home, so the UI and LiveProcess cannot install/refresh concurrently. A dead
process automatically releases the lock.

## Isolated identity and data

- Host: `com.aault.livecontainer.sideinstaller` (your sideloader may append its team).
- URL schemes: `livecontainer-sideinstaller`, `sideinstaller-embedded`.
- Embedded home: host `Documents/SideInstaller`.
- Guest IPA library: host `Documents/SideInstaller/Documents`.
- Separate app groups and certificate Keychain service.

This does **not** replace stock LiveContainer or move its existing guest data.
Do not change the bundle ID to overwrite your real installation as a shortcut
to migration. Back up guest data before any future migration experiment.

The custom URL scheme is registered as a **primary** LiveContainer in the
host's mode detection. It must not select LC2: that mode hides primary-host
certificate/signing settings. An older experimental build misclassified this
scheme; update the same app (same signing team/bundle ID) to correct it.

If JIT-less diagnostics report incorrect keychain groups after sideloading,
copy the installed entitlement plist from **LiveContainer Entitlements** and
**LiveProcess Entitlements** before changing signing settings. The unsigned
IPA's templates do not prove which groups the installer actually retained.
Do not revoke certificates or change identities to try to fix that check.

## First device test

1. Download `LiveContainer-SideInstaller-experimental` from the successful
   **Build LiveContainer + SideInstaller** run. Sign its unsigned IPA using your
   own account. **Keep every app extension**, especially LiveProcess.
2. Confirm it installs alongside your current LiveContainer. Open its built-in
   SideInstaller using the sideloader icon at the top left of the Apps page.
3. Accept SideInstaller's terms, add your Apple account, and import/generate the
   device pairing file. Connect LocalDevVPN as with standalone SideInstaller.
4. Start with a disposable test app. Keep its original IPA in the embedded
   library, install it, refresh it, and verify its data and expiry afterwards.
5. Tap **Set up LiveContainer → Check and fix signing**. This signs in, checks
   the actual team's identity against the installed host profile, activates a
   compatible certificate, and runs the signing test on this device. There is
   no separate share/import/test sequence. Apple two-factor prompts appear
   above the setup screen. If repair is needed, choose this installed build's
   original combined IPA in the same screen, then tap **Repair signing**.
6. In Shortcuts use this combined app's **Refresh All Apps** action. Test with
   the combined app closed, missing VPN, cancellation, and a failing test app.

## Certificate mismatch / host repair

**Set up LiveContainer** reads the selected team from the actual signing
session. A different team stops the operation without replacing the active
identity. Certificates not listed in the installed host profile are staged
only for explicit repair; they are not activated in LiveContainer. Manual
certificate import uses the same host-side compatibility checks. Automatic
activation uses the host preference store captured before guest sandbox hooks,
and the signing test loads ZSign from the real host bundle.

The built-in guest bootstrap loads the host's LiveContainerSwiftUI framework
before guest bundle/preference hooks run, checks both signing API selectors,
and does not call the framework's UI entry point. This also applies to
LiveProcess refreshes. Previously the framework loaded only on the host UI
path, leaving the embedded setup screen unable to reach LCUtils. Native macOS
loader tests cover normal startup, the extension path, and missing APIs.

The setup screen shows the result of the on-device signing test. Profile
membership alone is never reported as a passed test. A kernel rejection with
`F_ADDFILESIGS_RETURN` does not by itself prove a certificate mismatch. Repair
is offered for an incompatible/expired profile or a failed test, with the
actual error retained for diagnosis if repair does not help.

The original IPA picker checks both the combined bundle ID and installed
source revision. Repair reuses `prepareRefresh` / `refreshInstalledApp`; it
does not revoke certificates or switch accounts. A confirmation explains that
replacing the running host may close it before completion is reported.

Repair refuses a different source revision, bundle ID, team, missing embedded
app/LiveProcess, a new profile that does not authorise the signing certificate,
or signatures lacking development/app-group/128-keychain-group entitlements.
The signer requests the custom host's isolated keychain groups only for that
marked bundle. Other apps retain their existing signing behaviour.

After replacement, fully close and reopen the host, return to **Set up
LiveContainer**, and tap **Check and fix signing**. Certificate activation is
automatic; a successful test is required before showing ready. Do not uninstall: a successful same-ID update is intended to
preserve data. Back up important guest data before testing this experimental
repair. Host replacement, extension behaviour and data preservation still
need hardware verification. If SideStore later refreshes the host with a
different identity it can reintroduce the mismatch.

Certificate diagnostics now decode the revocation URL using its ASN.1 byte
length and preserve the locally decoded team/expiry on network failures.
Revocation failures stay **Unknown**, never Valid. JIT-less signature errors
include the failing kernel-validation stage, errno and available message.

## Deliberate limits / tests still required

- A successful build and metadata/layout verification are **not a device test**.
  Native guest launch, JIT-less signing, imported app launch, IPC, signing,
  foreground continuation and app-data preservation require real hardware.
- Existing standalone SideInstaller credentials, pairing files, private keys,
  and existing LiveContainer guests are **not automatically migrated**.
- A certificate belonging to another installation can trigger Apple's existing
  certificate-conflict error. No certificate is automatically revoked. Resolve
  identity access deliberately; revocation can break existing apps.
- The certificate export never creates a new certificate: first sign an app
  using the matching team/private key. Refreshing the host with that identity
  may be needed before its profile permits JIT-less guest signatures.
- For a self-refresh test, manually put the original **combined IPA** in the
  embedded library. Replacing the host can terminate its running extension;
  an interrupted response means **unknown**, not proof of install failure.
  Reopen the app and verify the installed profile before retrying.
- The 27-second foreground request does not grant unlimited background time.
  Apple 2FA may require opening the embedded UI and retrying afterwards.
- No unattended scheduling, persistent health-monitoring system, or automatic
  background retries are added by this prototype. The built-in JIT read-only preflight retry is described below.

## Build

The dedicated workflow builds the native SideInstaller target with
`SIDEINSTALLER_EMBEDDED` and `embedded/Runtime.h`, builds the adapted LC host,
then runs `embedded/package.py`. The normal standalone target has no embedded
dependency and remains buildable without that flag/header.

The unsigned IPA carries ad-hoc entitlement templates with upstream's dummy
team placeholder, not a real signing identity. The installer must replace
that placeholder with your team and preserve the requested app/keychain
groups and extensions. The packager verifies these signing requests after
embedding; it does not grant capabilities your profile does not allow.

Run packaging regression checks with:

```sh
python3 -m unittest discover -s embedded -p 'test_*.py' -v
```

`verification.json` is included beside the unsigned IPA and build logs. It
checks isolated bundle identities, extension placement, dylib conversion, no
embedded SideStore app, and the host's discoverable progress-reporting refresh
intent with foreground continuation.

### JIT host-context check

LiveContainer sets `LC_HOME_PATH` for its normal host UI as well as guests. The
coordinator checks the captured host/main bundle URLs, combined-build marker,
and bootstrap guest/LiveProcess/embedded-installer state instead. The actual
guest PID is still required and the coordinator cannot debug itself. Regression
fixtures explicitly run with `LC_HOME_PATH` set and reject guest/extension
contexts. This corrects the erroneous “must be started by the installed
LiveContainer host” rejection in the prior build.


### Built-in JIT setup and connection failures

Select **Built-in StikJIT** once, then open **Built-in JIT setup**. Import the
pairing file once and tap **Prepare device**, or simply run a JIT app after
importing. Preparation readiness lasts only for this host process/boot and is
invalidated by pairing replacement, cache reset, cancellation or session failure.
**Check device again** forces another check; it never opens the pairing picker.
The setup actions occupy separate Form rows with independent button hit targets.

Preparation runs before LiveProcess starts its debugger wait. Enablement uses
StikJIT's same JITSession/script pipeline through a small prepared-device entry
point, avoiding a second DDI preflight after the guest starts. LocalDevVPN is
still required. No debugger or script operation is retried automatically.
One connection-reset retry is allowed only during read-only reachability/DDI
checks, before mounting or starting a guest. Errors retain the preflight/debugger
stage and the failing FFI operation, including its original code and message.
A socket reset alone does not identify its cause or establish that JIT works.

For Husk, configure the official version-matched **husk-jit.js** as its **JIT
Launch Script**, enable **Launch with JIT**, keep Compatibility Mode off, and
turn on **Force configured JIT script** in built-in setup. Use the LC Apps Run
button, rather than Husk's own built-in helper (which cannot coordinate itself
from inside a guest). End-to-end Husk startup and APK execution require a device
test even when all compile/package checks pass.


### Pair once in the combined app

The embedded SideInstaller publishes its current remote-pairing record to a
private, protected file in the host's actual app group. Publication runs after
successful self-pairing/import and when opening an existing installation; it
never generates another pairing. **Tools → Pairing → Use pairing for
LiveContainer JIT** resends the current record manually. File export uses a
file-save dialog in the embedded build, rather than asking ShareLink to share a
guest-container URL. Standalone SideInstaller keeps its existing export UI.

Built-in JIT prefers that shared record automatically. **Use built-in
SideInstaller pairing** restores automatic mode after a manual JIT import.
Manual imports remain available and never overwrite the embedded installer's
record. New shared bytes invalidate prepared state before the next launch;
pairing changes during preparation reject the result and require a new check.
The bridge uses LC's captured app-group path rather than spoofed guest homes or
preference suites. Records are checked for identifier and matching Ed25519
public/private keys before atomic replacement, protected while locked, excluded
from backup, and never sent through URLs, preferences, notifications or logs.
Tests cover replacement, invalid-record rejection without losing the existing
record, and private permissions. Handoff errors do not fail a successful native
pair/install. Pairing the separate SideInstaller again may still replace the
device's trust record: use this combined app's pairing for this workflow.

Cellular connectivity still requires the LocalDevVPN route and a working device
listener. This change does not claim to fix cellular-only tunnel establishment,
DDI transport errors, or the guest's script protocol. The source of the pairing
is shown separately from preparation/JIT readiness.
