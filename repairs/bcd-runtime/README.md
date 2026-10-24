BCD ChatGPT logs v5

Update your existing BCD guest inside LiveContainer, preserving its data.
Fully restart LC. Reproduce the problem once.

Use "Copy report for ChatGPT" on BCD's native crash alert when available, or
Settings > Logs > Export BCD log > Copy report for ChatGPT.
The same export sheet offers "Share report for ChatGPT (.txt)" to attach one
named BCD-ChatGPT-report.txt file. No ChatGPT API, login or automatic upload.

The report contains a failure summary, version/session identity, device/OS,
launch-time power and thermal state, allowlisted effective environment/config,
Wine readiness, SDK fingerprint and imports, exception parameters/checked MSVC
RTTI and messages when available, process/thread identifiers, terminal stack,
address-space/JIT events and DLL failures. It streams original logs and uses
the separate v4 failure journal. A stable session marker survives noisy logs.
Common private details are redacted; review the report before sharing.

A missing record is marked as not captured, not success. Handled C++ exceptions
are not automatically treated as failures. No logger guarantees certainty or
an automatic fix. Renderer, game code, bundle ID and previous repairs remain.

Tests: readiness/native import fixtures; PE import parser; session isolation,
privacy/size bounds, 2 MB noise survival, failure-summary retention, checked
RTTI/message reads and inaccessible pointers. CI compiles the real iOS UI and
verifies archive preservation. Device UI/gameplay remain untested here.
