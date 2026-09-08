# Personal-use release keyset

The owner explicitly keeps the Tier-3 keyset under `release-keys/` in this
repository for this handset. Preserve it. These published keys are personal
build inputs; their publication means they do not provide signing-key secrecy.
The previous session's mandatory rotation/external-key instructions are not the
current owner's policy.

Tier 1/2 use development signing. Tier 3 (enforcing `user`, normal non-root ADB
off by default, release signing) requires future explicit authorization; this
bring-up session does not run it or rotate keys. The historical release wrapper
still encodes an external-key policy and needs review before future use with
the owner's current keyset.

Keep matching certificate/private-key pairs for `releasekey`, `platform`,
`shared`, `media`, `networkstack` and `bootsignature`. The legacy BootSignature
is part of boot-image compatibility; it does not enable AVB or change LK's
unlocked state.
