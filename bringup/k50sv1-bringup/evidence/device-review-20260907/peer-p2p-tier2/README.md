# Tier-2 Wi-Fi Direct peer evidence — 2026-09-07

Phone-side discovery of the owned Linux host **passes**. No P2P group was
established during this peer fixture and no file transfer ran; peer transfer
remains **UNVERIFIED**. These observations do not isolate a phone-firmware fault.

The phone used a temporary unique device name. Two 30-second NetworkManager
`StartFind` rounds returned zero host-side peers, while the phone displayed the
host's exact current P2P-device address. An in-memory push-button configuration
(PBC) profile targeted the owned phone's actual `p2p0` address, corroborated by
its local saved-group record. Activation returned exit 4, “peer could not be
found.”

During a third discovery round the phone saw the owned host again. Selecting
that exact peer entered provision discovery; `mSavedPeerConfig` matched the
host's address. A PIN invitation appeared with a blank sender and no matching
host PIN. The invitation was rejected. Concurrent host PBC activation returned
exit 3 after a 45-second timeout. The phone reported no group and returned to
`InactiveState`. Earlier group-creation entries in its history predate this
peer fixture.

All eight cleanup checks passed: host active connections, default route and
IPv4 forwarding were unchanged; the temporary profile was removed; the phone
had no active group; its visible name and originally absent global name setting
were restored; its preexisting saved group was preserved.

[Structured results](result.json) retain outcomes and private-capture hashes.
Raw addresses, device names, connection identifiers, SSIDs and UI captures are
omitted from this public evidence.
