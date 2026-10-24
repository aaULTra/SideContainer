BCD diagnostics v4

Import this IPA over the existing BCD guest in LiveContainer, preserving data.
Fully restart LC. Reproduce once, then use Settings > Logs > Export BCD log >
Copy diagnostic report.

Changes: synchronous native stderr observation into a bounded separate journal;
Wine +seh exception parameter traces; checked MSVC RTTI and std::exception message
reads without calling guest functions; full-log streaming extraction instead of
2 MB tail-only sampling; crash stack, process IDs, exit status and cage evidence.
A previous journal is preserved on the following launch. No automatic uploads.

Limits: the hook observes this build's native write import and stderr path. Other
logging paths may not be observed; the report also scans the original log. RTTI
and message capture depends on Wine emitting the parameters while memory remains
readable. Unknown types and inaccessible pointers are marked unavailable. A
handled exception is not itself a failure, and no logger guarantees a diagnosis
or fix. This build changes diagnostics, not the renderer or game instructions.
