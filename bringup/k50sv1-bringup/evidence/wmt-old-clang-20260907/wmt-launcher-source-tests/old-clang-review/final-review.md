# Final old-Clang compatibility review

Reviewed the correction against launcher commit
`2cbfa92e64e2b01461de512e4feb2c5676406125`. PASS: no high-confidence issue
remains in this bounded change. Exactly four initializer lines changed in
main.c and firmware.c; protocol.c, patch.c and the reviewed headers are
unchanged.

The record array now explicitly braces its first element. Both firmware
results explicitly initialize `.patches`, and optional controls explicitly
initialize `.fwlog`. All recursively omitted members retain their zero
values. Existing atomic initialization and all later operations are unchanged.

All four candidate compile commands retain the original
`clang-r353983c1` Soong arguments, including GNU C11, VNDK/API29, ARM64 target,
optimization and every warning/error option. Changes are confined to source,
include, dependency-output and object-output paths. The baseline adds only
`-Wno-error=missing-braces` to retain the original diagnostics while generating
comparison objects. Its main.c and firmware.c logs reproduce three and one
warnings respectively; all four candidate logs are empty.

Independent SHA-256 checks bind every source, recorded command, log, raw
object and stripped object. Repeating `llvm-objcopy --strip-debug` on all eight
raw objects in this review's own directory reproduced the retained stripped
files byte-for-byte. Each of the four baseline/candidate stripped-object pairs
is identical. Raw objects differ because of source/debug paths, so raw-byte
identity is not claimed. The generated code and remaining object contents
match for the tested actual toolchain and flags.

The preserved-source replay was also checked without rerunning compilation.
Its 19 baseline files, 19 candidate files, 224 generated headers and 71 external
dependencies match their recorded or source identities. All eight replay
commands differ only in preserved-input and output paths; all eight stripped
objects match the original comparison objects.

The first replay selected the Q-bundled objcopy, whose output layout differs
from the original `/usr/bin/llvm-objcopy` 22.1.8. The preserved provenance
correction changes that tool and adds its hash. Independently stripping the
first replay's original raw main.o with the correct tool reproduces the final
expected hash, confirming a postprocessing mismatch. The original compilation
result and the first replay's partial artifacts remain preserved.

The original build18 failure log retains its initial hash. No production
file, existing validation artifact or archive 656 was edited by this review.
No compiler or functional suite was rerun by the reviewer. Root owns the
reproduction runner, generated-header preservation and subsequent clean
product build; this object-level check does not claim that build has passed.

`final-review.json` records all source and object identities, command checks
and the exact reviewed diff. `final-artifact-sha256.json` covers the review
artifacts and independently stripped objects.
