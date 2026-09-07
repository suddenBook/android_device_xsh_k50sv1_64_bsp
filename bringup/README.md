# Bring-up tooling and release keyset

Everything here exists so that a fresh `repo sync` of this device is enough to
build and flash it again. Before this directory existed, the build wrapper and
the release keyset lived only in a `work/` tree that had no remote at all, so
deleting the local checkout would have made both unrecoverable.

## Why the directory is nested like this

`k50sv1-bringup/tools/*` resolve the project root themselves:

    TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_ROOT="$(cd "${TOOL_DIR}/../../.." && pwd)"

That is three levels above `tools/`, which is correct only when the tree sits
at `<PROJECT_ROOT>/work/k50sv1-bringup/tools`. Running them from inside the
device repo would resolve `PROJECT_ROOT` to somewhere under `device/xsh/` and
every path they derive from it would be wrong.

So the scripts are stored here **byte-for-byte unmodified** and are meant to be
copied back out, rather than patched to a second layout that then has to be
kept in sync. Restore with:

    cp -r lineage-17.1/device/xsh/k50sv1_64_bsp/bringup/k50sv1-bringup work/

from `<PROJECT_ROOT>`, giving `<PROJECT_ROOT>/work/k50sv1-bringup/tools/...`.

## The keyset

`release-keys/` holds the Tier-3 signing keyset. It is committed here at the
owner's explicit instruction for a personal-use handset.

`prepare-tier3-keyset.sh` will refuse this directory as-is, and that is not a
bug to work around: it checks that the keyset is outside PROJECT_ROOT, is not
tracked by Git, and is mode 0700. Copy it somewhere that satisfies those rules
before building:

    mkdir -p ~/k50sv1-release-keys && chmod 0700 ~/k50sv1-release-keys
    cp bringup/release-keys/* ~/k50sv1-release-keys/
    chmod 0600 ~/k50sv1-release-keys/*
    export K50SV1_RELEASE_KEYS_DIR=~/k50sv1-release-keys

Losing this keyset means no later build can be signed such that an already
installed image accepts it, and every platform-signed APK stops matching.

## What was deliberately left behind

`k50sv1-bringup/evidence/` (~123 MB of capture logs) and `experiments/` are not
here. They are records of past investigations, not build inputs; nothing under
`tools/` reads them. They remain in the original `work/` tree.

## Building after a fresh clone

    cp -r lineage-17.1/device/xsh/k50sv1_64_bsp/bringup/k50sv1-bringup work/
    export K50SV1_RELEASE_KEYS_DIR=~/k50sv1-release-keys
    work/k50sv1-bringup/tools/import-mindthegapps.sh     # vendor/gapps, else the product errors out
    K50SV1_BUILD_TIER=3 work/k50sv1-bringup/tools/run-lineage-build.sh
