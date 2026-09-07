# Tier-2 startup refusals

Boot `f338f55b-067e-4204-948f-0c2b8d953968` runs the complete build21 in
Enforcing. Its first verifier reports 218 passes, three unexpected AVC groups,
five unread checks and zero evidence failures. The three groups were then
reviewed against the installed binaries, init inventory and their actual
continuations. No allow or dontaudit rule is added.

| Refused operation | Verified consequence |
| --- | --- |
| `ccci_mdinit` starts `emdlogger1` | The logger service and executable are absent. The caller ignores the result and continues to the installed muxd and modem-ready path. Its zero wait budget still permits one status read and 10 ms sleep. |
| `gsm0710muxd` stops bare `ril-daemon` | No such service exists. The caller ignores the result, then sets `vendor.ril.mux.start=1` and `vendor.ril.mtk=1`, starting `vendor.ril-daemon-mtk`. Its unconditional “stopped” message is not proof of a successful stop. |
| `mtk_agpsd` traverses `/mnt/vendor` | `agps2_mgr_init` probes `/nvcfg`, `/vendor/nvcfg`, then `/mnt/vendor/nvcfg` for optional `agps_nvram.txt` overrides. All three directories are absent. The `stat` helper maps EACCES and ENOENT to the same result; the caller continues GNSS initialization and returns success. This is not the nvdata calibration path. |

Both radio control refusals occur once in the startup log. Modem/RIL services
retain their initial PIDs and both SIMs reach roaming registration. AGPS loads
`/vendor/etc/agps_profiles_conf2.xml` and retains its startup PID; the permissive
Tier-1 boot has the same missing-override fallback. These observations do not
establish a phone call, IMS registration, GNSS fix or network assistance.

The installed/reviewed SHA-256 identities are:

- ccci_mdinit: `c7fc55d0b4929465d702a539864732f6992e06870f228dd6c2dcfeeb81c985a9`
- gsm0710muxd: `365d91e5ecc7427f9fd82c63033305f86780fa9b387722cbe8011079b8e6bf57`
- mtk_agpsd: `176b475dbc97701c368e0d0ff99f378d6fc4c98571b427a8674acb45b7b6059a`

The expected-evidence table now names each observed property or directory
qualifier and `permissive=0`. Raw denials remain available. Revisit the AGPS
classification if the blob, call site or nvcfg layout changes; a matching type
tuple alone does not prove the same cause. [Review input hashes](startup-review-inputs.json)
locate the detailed disassembly, path metadata and startup records in private
staging. A comment-only source edit corrects the incomplete modem-target list;
all effective policy statements remain unchanged.
