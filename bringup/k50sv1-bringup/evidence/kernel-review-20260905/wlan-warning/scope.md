# Read-only followup scope

Requested by the parent task: explain the first WLAN-enable `vsnprintf` warning using the shipped module, kernel, log, and same-platform primary source. Owned output is this directory only. Modules, shared kernel source, Android, handset state, and builds are outside write scope.

Completed workflow evidence:

- Triage: ELF identity, SHA-256, undefined formatter imports, global function anchors, and module metadata saved.
- Static: exact append loop, callback registration, format strings, and built-kernel guard/return instructions saved.
- Runtime cross-check: existing supplied log PCs match the binary call sites; no new device access used.
- Synthesis: high-confidence arithmetic fault and bounded no-write conclusion map to both runtime and static evidence. The public MT6755 source is explicitly treated as a different diagnostic revision.
- Residual limit: the report is not a general WLAN memory-safety audit. Arithmetic replay is not native execution.

Hypothesis result: oversized size after truncation is confirmed; an out-of-bounds destination write on the observed path is contradicted by the formatter guard and prior bounded writes. No source-kernel regression is shown. Stop this investigation at the report's recommendation.
