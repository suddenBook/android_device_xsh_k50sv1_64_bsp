# Upstream changes this device needs

Two files in `vendor/lineage/prebuilt/common/etc/` are patched. `repo sync`
reverts both; `tools/apply-upstream-patches.sh` puts them back, and `--check`
proves the exact outcome before every build.

| File | Change | Held here as |
|---|---|---|
| `fonts_customization.xml` | adds the `harmonyos` family and its two aliases. Additive; lato and rubik are untouched. | `fonts_customization.xml.patch` |
| `apns-conf.xml` | adds `type="default,supl"` to seven China Mobile / China Unicom WAP rows that carried no `type` at all. Seven lines; the other 3822 rows are untouched. | `apns-conf.xml.patch` |

The `.ttf` files and the Styles overlay are NOT here — they are ordinary device
tree modules (`device/xsh/k50sv1_64_bsp/fonts/`, `.../rro/HarmonyOSSansFont/`)
with unique install paths, so they collide with nothing.

## Why the APN rows cannot be fixed from the device tree

The device's ten IMS APNs live in `device/xsh/k50sv1_64_bsp/configs/apns-conf.xml`
and reach the image through Lineage's `CUSTOM_APNS_FILE` hook. That hook is
**additive**: `vendor/lineage/tools/custom_apns.py` replaces a default row only
when the row's `carrier` name appears in it, and otherwise appends before
`</apns>`.

Neither half of that helps here:

* An `<apn>` with no `type=` attribute becomes `TYPE_ALL`, which **includes
  `ims`**, and TelephonyProvider *unions* the type columns of rows that share an
  APN identity (`mergeFieldsAndUpdateDb`, "Merge the 2 types"). Seven untyped
  WAP rows therefore made `cmwap`, `3gwap` and `uniwap` claim the `ims` type.
* Those rows have LOWER `_id`s than an appended row, and
  `DcTracker.buildWaitingApns()` preserves database order, so the IMS PDN was
  always handed a WAP APN with an HTTP proxy at 10.0.0.172 and never the
  device's own `ims` APN. Measured on the handset: every setup went out as
  `APN='3gwap'` and returned `mFailCause=31`, forever (E-181).
* Replacing them by name is impossible: rows 3091/3092 (and 3121/3122) share
  one `carrier` string, so a name match can only ever reach the first of each
  pair.
* A second module writing `/product/etc/apns-conf.xml` is a ckati "overriding
  commands" hard error, and filtering `PRODUCT_PACKAGES` does not help — the
  install rule is emitted at parse time, before the install set is computed.
  (This is the same wall `fonts_customization.xml` hit; see the script header.)

So the seven attributes are patched in the base file, and everything else about
APNs stays additive. Do not restore the historical one-megabyte APN replacement
to this directory.

The change is worth sending to LineageOS: it is a data bug, not a device
workaround. It is invisible upstream only because LineageOS ships no MCC-460
`ims` APN for it to collide with.


## Source Tinycompress header dependency

The source-replacement device also needs the one-line
`tinycompress-kernel-headers.patch` against external/tinycompress
`848ec3ad67cc414294d18776a2b4d644be95fd64`. Local source commit `5f2b0e5` selects
the device's audio-only generated header library. The two implementation C
files, SONAME, installed names and function ABI remain unchanged.

An actual ARM32 compile otherwise includes ARM64 asm/sigcontext.h through
Bionic signal.h. A separate same-output provider was also tested: Android Q
emits both installation rules before evaluating module overrides and rejects
them. The device therefore supplies only the scoped header generator and uses
the existing upstream library module.

This is a clean local source commit. The standard revision-pinned Android repo
manifest records it; there is no additional dirty-tree exception. The owner's
source-replacement and autonomous-execution request is the basis for this
bounded build integration. No remote push is performed.

To recreate it after restoring the original project revision, check out that
base, apply the recorded patch, and commit the one-line change on a local
branch. `apply-upstream-patches.sh --check` validates the entire base-to-HEAD
diff and rejects any dirty or unrelated change when the device header module
is selected. The ordinary font/APN reapply mode also requires this source
branch to have been prepared first.

## HOME role selection

PermissionController uses the unmodified Android Q source tree at
`d90ff6d3d7d15775edfc853dd59bf1e7f3e06f25`. The local revert
`494e742ae919032755e7f9cac086d42c884de061` restores that exact tree.
`tools/check-home-role-source.py` requires a clean, equivalent tree and no
device-specific HOME fallback overlay.

The former configured-HOME patch, overlay and preferred-app XML existed for
competition between two preinstalled launchers. Removing Niagara also removes
that workaround. Android now selects SetupWizard while setup is pending and
Trebuchet as the only ordinary preinstalled HOME after setup. Later installed
launchers use Android's standard selection behavior. The retired fallback is
not part of the active patch set.
