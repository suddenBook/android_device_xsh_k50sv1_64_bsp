# Tier-3 SetupWizard network evidence — 2026-09-07

The owner accepts this as a known compatibility limit of the old SetupWizard
with the network's newer encryption. It is no longer an open device-fix item.

Wi-Fi connected and validated: supplicant `COMPLETED`, framework `CONNECTED`,
HTTP/HTTPS probes returned 204, and both direct-IP and DNS-name pings succeeded.
Google SetupWizard nevertheless kept stale network rows and did not advance
from its Wi-Fi page. Normal **Skip → Continue** proceeded through Google services
and Lineage extras to the desktop. Both provisioning flags became enabled
through that flow; no HOME crash occurred during the normal transition.

The new wrapper omitted no original required dependency. Its APK and JNI match
the source bytes, and the three Google privilege XMLs, hidden-API whitelist and
Google sysconfig match the payload. Privileged installation, ARM64 ABI, optional
HTTP library and inspected network permissions are intact.

SetupWizard version 3507 targets SDK 29 and requests coarse/background location,
but **does not request fine location**. Four configuration broadcasts were
actually dropped for missing fine location. In the frozen source,
`WifiConfigManager.java:823` sends a single-network update requiring fine location;
`ContextImpl.java:1091` supplies no coarse/SDK companion. Other network-state and
scan update paths remain available, so these drops **do not prove the complete
cause of the stale page**. No permission change is justified by this observation.

`DefaultPermissionGrantPolicy.java:1160` only grants requested permissions;
`BasePermission.java:442` likewise rejects an unrequested runtime grant. A default
fine-location grant is therefore inapplicable. No invalid grant replay,
permission workaround or APK re-signing was performed.

The skip/exit flow explicitly disabled Wi-Fi at 18:17:21, re-enabled it at
18:21:24 and removed its own saved network at 18:21:25. The later disconnected
browser attempt follows those recorded app actions. Saving the network again
in normal Settings restored a 5220 MHz connection and HTTPS page rendering.

[Structured results](result.json) bind the captures, source-equal installed files
and exact primary-source paths/revisions. Private network identifiers, phone
numbers and raw UI/log captures are omitted.
