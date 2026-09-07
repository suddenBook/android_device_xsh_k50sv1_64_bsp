# Remaining work

Completed items are removed; IDs are not reused. Full build21 Tier 2 passes
local multimedia, network, policy and storage-boundary checks. Its second
verifier reports 227 PASS, 0 FAIL and only three carrier-IMS UNREAD checks.
Signed Tier 3 has completed local runtime and final ADB-off checks, and the
tested source commits are on main. The owner accepts the old SetupWizard Wi-Fi
compatibility limit and expected Play non-certification.
The [current review](evidence/E-210.md) records verified fixes and their measured
limits. Routine build, flash and wipe choices are delegated.

| ID | Remaining result | Next evidence |
|---|---|---|
| WI-020 | Ordinary-call recovery | One owner-specified ordinary call after a fresh reboot, separately from the airplane test. Capture dialing, connected and teardown states. No emergency or guessed destination. |
| WI-018 / WI-055 / WI-093 | Carrier IMS/WFC result | Ten corrected APNs are live. Current CU/CMCC roaming lacks registered IMS; record that boundary without assuming roaming is categorically unsupported. A home/local SIM and carrier-permitted WFC are needed for an end-to-end pass. |
| WI-022 | Two microphone apertures' electrical roles | MIC and VOICE_COMMUNICATION each supply 48000 nonzero frames with clean lifecycle. Owner-assisted occlusion of each aperture and a controlled call are still needed to identify their roles. |
| WI-046 | Usable battery capacity / donor curves | 3200 mAh is nominal. Use controlled discharge with reset-aware hardware CAR or an external meter; UI charge_counter is not an energy measurement. |
| WI-056 / WI-094 / WI-095 | Standby behavior and Wi-Fi/USB wake cost | Paired undisturbed unplugged Wi-Fi-on/off windows, actual sleep residency and all-CPU IRQ120 deltas. Abort counts cannot establish mA or runtime. |
| WI-072 | Hardware PNO / screen-off reconnect | Unplugged screen-off window away from a saved network, followed by its return. Zero offloaded scans while connected is not a defect. |
| WI-081 | Fuelgauge route-policy lifecycle | Live FD3 is NETLINK_FGD26. Retain the route audit until charge/discharge and longer lifecycle evidence establish whether those grants are unused. |
| WI-080 | Intermittent Volume Up failure | On recurrence capture kpd_hw and kpd/GUARDED logs before reboot; kpd_recover distinguishes controller state from a persistently low GPIO104. Short successful tests do not close it. |
| WI-012 | Remaining source-provider runtime coverage | [Tier-3 AAC capture](evidence/device-review-20260907/peer-a2dp-tier3/README.md) passes the frequency criterion with the late controller guard failure retained. Both T2/T3 P2P peer attempts establish no group or transfer; validate against another known-working peer before assigning the fault. Audible quality and a GNSS position fix still need their fixtures. Actual WMT module unload/reload and radio recovery pass. |
| WI-035 | AppGallery/HMS account flow | Owner's store installation and account sign-in; packaging alone does not establish service usability. |
| WI-073 | Audio and display tuning | Owner-present sustained-content A/B for BesLoudness and six PQ properties; a ringtone is insufficient. Restore each property's prior state. |
| WI-077 | ERM haptic feel | Owner feedback for long-press 60 ms, virtual-key/keyboard 50 ms, clock/calendar 40 ms. Android Q keyboard taps use the virtual-key pattern. |
