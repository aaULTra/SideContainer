# BCD 580 diagnostics v3 and Wine startup repair

Import `BCD-0.1.580-Diagnostics-v3.ipa` into the existing BCD entry in LiveContainer as an update. The BCD bundle identifier is unchanged; this is a guest IPA, with no new host app or App ID required. Preserve the existing LC installation and guest data.

Reproduce the SDK error, then open BCD Settings → Logs → Export BCD's log. In the share sheet, select **Copy diagnostic report** (scroll the actions list if needed) and paste the report into the conversation. A Wine startup failure alert also offers the copy action. Log export's original sharing actions remain available. No report is uploaded automatically.

The bounded report records the last guarded launch, actual loader/SDK/fatal log evidence, recent log context, bundled module presence, and the game-local PsPcSdk.dll SHA256 and normal/delayed imports. A matching persisted session marker isolates that launch; fallback log evidence is explicitly marked unverified. The report redacts common email, IP, host-container/user paths, URLs and credential-labelled lines. This is a best-effort filter: review copied text before sharing. It reads logs and the game-local SDK only, not pairing records or Keychain. No per-frame diagnostic polling is installed.

The existing readiness guard still prevents a Wine client launch if the server stopped or never became ready. Ghost's effective opt-in list now includes `evr,dxva2,tbs`, preserving existing opt-ins and making a one-time configuration backup. This enables the TBS module already bundled by BCD. It does not implement a TPM: several Sony SDK imports in Wine remain stubs or return an unsupported error. The report distinguishes imported functions from logged calls. Neither DLL presence nor module mapping proves successful SDK initialization or full game compatibility.

Packaging validates the immutable NTDSAPI-repaired base, preserves native instruction sections, bundle ID, graphics libraries and every unrelated archive entry, and updates only Ghost's recommendation and the injected diagnostic guard. The proprietary Sony SDK and user logs are not included in this source bundle.

Validation: portable PE32/PE32+ parser cases (normal/delay/ordinal/truncated), native macOS diagnostic/session/redaction/size/path tests, readiness tests and actual dyld import-hook fixtures. CI also compiles for iOS arm64 and verifies archive preservation. These tests do not execute iPadOS, Wine, the Sony SDK or Ghost of Tsushima; device testing remains necessary.
