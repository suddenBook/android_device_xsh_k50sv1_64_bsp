# Old Clang initializer review

Reviewed the four launcher C units at device commit
`2cbfa92e64e2b01461de512e4feb2c5676406125` and the preserved build18 Soong
failure. The actual command uses `clang-r353983c1`, GNU C11, `-Wall`, `-Wextra`
and `-Werror`. The log diagnoses missing nested braces at main.c lines 258,
259 and 386. `firmware.c:111` has the same type and initialization as
`main.c:259`, so it should be corrected and checked in the same change.

The minimal explicit forms are:

| Location | Compatible initializer |
| --- | --- |
| main.c:258, array of records | `records[WMT_CMD2_PATCH_MAX] = {{0}}` |
| main.c:259, firmware result | `firmware = {.patches = {0}}` |
| main.c:386, optional controls | `controls = {.fwlog = {0}}` |
| firmware.c:111, firmware result | `found = {.patches = {0}}` |

These forms explicitly initialize the first aggregate subobject. All omitted
members and array elements remain recursively zero-initialized under C's
aggregate-initialization rules. The existing atomic initialization calls
remain in place. The equivalence claim concerns member values and behavior;
it does not depend on unspecified structure-padding bytes.

The remaining zero-only initializers start with scalar members or initialize
scalar arrays. Existing designated initializers with nonzero values are also
outside this failure pattern. No change is needed to protocol.c, patch.c,
warning flags or source interfaces.

An immediate `memset(&object, 0, sizeof(object))` after declaration is another
target-compatible option, provided it precedes every use and existing
`atomic_init` calls. Explicit initializers provide a smaller diff.

Root owns the corrective edit and complete four-unit check using the actual
old Clang command. This review performed no compilation or production edits.
The old build18 failure and archive 656 remain unchanged. The initial JSON
contains source snapshots/hashes, all initializer sites, and the original
diagnostic/command binding; final diff equivalence will be recorded separately.
