#!/usr/bin/env python3
"""Derive both permission allowlists a prebuilt privileged APK needs.

Two different mechanisms, two different files, and they are not
interchangeable:

  privapp-permissions  Under `ro.control_privapp_permissions=enforce` -- which
                       LineageOS sets and tiers 2 and 3 keep -- an app in
                       priv-app holding a `signature|privileged` permission
                       that is not named here makes PermissionManagerService
                       throw. That happens inside PackageManagerService's
                       constructor, so the failure mode is a system_server boot
                       loop, not a denial. The list has to be exact.
                       The file must live on the SAME partition as the APK:
                       PermissionManagerService.java:1818-1830 picks a
                       different SystemConfig map per partition.

  default-permissions  Grants DANGEROUS (runtime) permissions without a user
                       prompt. Purely an install-time convenience;
                       DefaultPermissionGrantPolicy reads
                       <partition>/etc/default-permissions/ (:1390-1414).
                       `fixed="false"` leaves the user able to revoke.

Both are derived from two facts and no guessing:

  * what the APK asks for            -- aapt dump permissions
  * what the platform grades each as -- protectionLevel in
                                        frameworks/base/core/res/AndroidManifest.xml

Permissions the platform does not declare are dropped: PMS never sees them, so
listing them would only rot. Signature-only permissions are dropped too -- an
allowlist entry cannot grant one, only a matching signature can.

Usage:
  gen-privapp-permissions.py --mode privapp  [-o OUT] <platform-manifest> <apk>...
  gen-privapp-permissions.py --mode default  [-o OUT] <platform-manifest> <apk>...

With no -o the finished XML goes to stdout in a single write. Prefer -o when
the destination is a real file: see write_atomically() for why a shell
redirection is not good enough for this particular artifact.
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ANDROID = "{http://schemas.android.com/apk/res/android}"

# The tokens in a protectionLevel that mean "a privileged app on a system
# image is allowed to hold this, and a privapp-permissions entry can grant
# it". Three spellings, all still live in AOSP manifests, all equivalent here:
#
#   privileged         core/res/res/values/attrs_manifest.xml:238
#                      <flag name="privileged" value="0x10" />
#   system             core/res/res/values/attrs_manifest.xml:240
#                      <flag name="system" value="0x10" /> -- the comment right
#                      above it reads "Old synonym for 'privileged'. Deprecated
#                      in API level 23." Same bit, so PMS cannot tell them apart.
#   signatureOrSystem  core/res/res/values/attrs_manifest.xml:228
#                      <flag name="signatureOrSystem" value="3" /> -- the
#                      pre-API-23 spelling of `signature|privileged`. Still used
#                      in this tree, e.g. frameworks/base/packages/
#                      WAPPushManager/AndroidManifest.xml:23-24 declares
#                      com.android.smspush.WAPPUSH_MANAGER_BIND with it.
#
# Compared lowercase because the token set below is lowercase; see
# _level_tokens() for why the comparison is by whole token and not substring.
PRIVILEGED_TOKENS = frozenset(("privileged", "system", "signatureorsystem"))


def _level_tokens(level):
    """protectionLevel -> set of lowercase tokens.

    DEFECT FIXED HERE (T8-3). protectionLevel is a *flag* attribute: the
    platform manifest spells it as tokens joined by '|', e.g.
    "signature|privileged|development" or the legacy single token
    "signatureOrSystem". classify() used to test it with case-sensitive
    substring matching -- `"system" in level` -- and that was wrong twice
    over:

      * It never fired for "signatureOrSystem". The capital S in "...OrSystem"
        means the lowercase needle "system" is not a substring, so that arm
        was dead code on every manifest in this tree (grep confirms: zero
        protectionLevels in core/res/AndroidManifest.xml contain a lowercase
        "system"). "signatureOrSystem" instead fell through to the
        `"signature" in level` arm -- "signature" IS a lowercase prefix of it
        -- and got filed as signature-only, i.e. DROPPED from the allowlist.
        That is exactly backwards: signatureOrSystem == signature|privileged,
        the one shape an allowlist entry is for. Under `enforce` a dropped
        entry for a permission the app actually holds is a boot loop.

      * Substring matching has no way to distinguish a token from a token that
        merely contains another. "vendorPrivileged" (attrs_manifest.xml:279)
        is a distinct 0x8000 flag, not the 0x10 "privileged" bit; it only
        happens not to collide today because of its capital P.

    Splitting on '|', stripping, and lowercasing makes every test below an
    exact whole-token comparison, which is what a flag attribute deserves.
    Empty tokens (a stray "signature|" or "  ") are discarded so they cannot
    match anything.
    """
    return {token.strip().lower() for token in level.split("|") if token.strip()}


def write_atomically(path, text):
    """Write `text` to `path` such that `path` is never observed half-written.

    DEFECT FIXED HERE (T8-1). This script used to print the XML incrementally,
    element by element, as it walked the APK list. Any failure partway --
    aapt missing, an unreadable APK, a KeyboardInterrupt -- left a
    syntactically truncated allowlist behind. For this particular artifact
    that is strictly worse than producing nothing: an absent
    privapp-permissions file under `ro.control_privapp_permissions=enforce`
    just means no app is allowlisted, whereas a truncated one is parsed by
    SystemConfig inside PackageManagerService's constructor and takes
    system_server into a boot loop (see the module docstring).

    Buffering in memory is only half the fix. `gen-... > /product/etc/
    permissions/privapp-permissions-foo.xml` has the SHELL truncate the
    destination to zero bytes before python is even exec'd, so an interpreter
    that dies early still leaves a zero-byte file on the partition. That is
    why -o exists and why it lands the bytes through a rename:

      * the temp file is created with tempfile.mkstemp(dir=...) in the
        DESTINATION's own directory, not in /tmp, because os.replace() is
        only atomic within one filesystem -- across filesystems it degrades
        to a copy, which is the truncation window all over again;
      * fsync before the rename so the rename cannot be ordered ahead of the
        data on a crash;
      * on any failure the temp file is unlinked, so a failed run leaves the
        previous good allowlist in place and no debris beside it.
    """
    directory = os.path.dirname(os.path.abspath(path)) or "."
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".privapp-permissions-",
                               suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        # mkstemp creates 0600 and os.replace carries that mode to the
        # destination. A privapp-permissions XML at 0600 is unreadable by
        # system_server, and SystemConfig's readPermissions treats a file it
        # cannot parse as one that grants nothing -- which is the boot loop this
        # module's docstring exists to describe, reached by the very write that
        # was supposed to prevent it.
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def platform_permissions(manifest_path):
    """name -> protectionLevel, for every <permission> the platform declares."""
    root = ET.parse(manifest_path).getroot()
    return {p.get(ANDROID + "name"): (p.get(ANDROID + "protectionLevel") or "normal")
            for p in root.iter("permission") if p.get(ANDROID + "name")}


def apk_requests(apk):
    """Permission names the APK asks for, manifest order, de-duplicated."""
    txt = subprocess.run(["aapt", "dump", "permissions", apk],
                         capture_output=True, text=True, check=True).stdout
    seen, order = set(), []
    for line in txt.splitlines():
        m = re.match(r"\s*uses-permission(?:-sdk-\d+)?: name='([^']+)'", line)
        if m and m.group(1) not in seen:
            seen.add(m.group(1))
            order.append(m.group(1))
    return order


def apk_package(apk):
    txt = subprocess.run(["aapt", "dump", "badging", apk],
                         capture_output=True, text=True, check=True).stdout
    return re.search(r"package: name='([^']+)'", txt).group(1)


def classify(platform, names):
    """Split requested names by what this platform can do with them.

    Returns five buckets, and every requested name lands in exactly one of
    them. The arms are ordered most-privileged-first because protectionLevel
    is a flag set: "signature|privileged" is BOTH signature and privileged,
    and it is the privileged bit that an allowlist entry acts on, so the
    privileged test has to win.

    DEFECT FIXED HERE (T8-2). This used to be four arms with no `else`, so
    any protectionLevel matching none of them fell off the end of the loop
    and vanished -- not listed, not counted, not mentioned in the summary.
    On this tree's frameworks/base/core/res/AndroidManifest.xml that hole
    swallows 63 of the 536 declared permissions: the 58 graded plain
    "normal" and the 5 graded "normal|instant". Harmless to omit from the
    output (a normal permission is granted at install with no allowlist and
    no prompt) but NOT harmless to omit from the accounting: the per-APK
    summary line was the only check that the four buckets accounted for
    everything the APK asked for, and with a silent drain the numbers never
    had to add up, so a genuinely misgraded permission could hide in the
    same gap. The `else` makes the arithmetic total again.
    """
    privileged, dangerous, sig_only, unknown, unclassified = [], [], [], [], []
    for name in names:
        level = platform.get(name)
        if level is None:
            unknown.append(name)
            continue
        tokens = _level_tokens(level)
        if tokens & PRIVILEGED_TOKENS:
            privileged.append(name)
        elif "dangerous" in tokens:
            dangerous.append(name)
        elif "signature" in tokens:
            sig_only.append(name)
        else:
            # Reached by "normal" and "normal|instant" today. Anything else
            # arriving here is a protectionLevel this script has never been
            # taught, which is worth seeing rather than losing.
            unclassified.append(name)
    return privileged, dangerous, sig_only, unknown, unclassified


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=("privapp", "default"), required=True)
    ap.add_argument("-o", "--out", metavar="PATH",
                    help="write the XML here via a same-directory temp file "
                         "and an atomic rename, instead of to stdout")
    ap.add_argument("manifest")
    ap.add_argument("apks", nargs="+")
    args = ap.parse_args()

    platform = platform_permissions(args.manifest)

    # T8-1: accumulate the whole document, emit it once at the very end, after
    # every APK has been read successfully. Nothing reaches stdout or -o until
    # the loop has run to completion, so a mid-run failure produces no output
    # at all rather than a prefix of one.
    out = []
    out.append('<?xml version="1.0" encoding="utf-8"?>')
    out.append("<permissions>" if args.mode == "privapp" else "<exceptions>")
    for apk in args.apks:
        pkg = apk_package(apk)
        privileged, dangerous, sig_only, unknown, unclassified = classify(
            platform, apk_requests(apk))
        if args.mode == "privapp":
            out.append('    <privapp-permissions package="%s">' % pkg)
            for name in sorted(privileged):
                out.append('        <permission name="%s"/>' % name)
            out.append("    </privapp-permissions>")
        else:
            out.append('    <exception package="%s">' % pkg)
            for name in sorted(dangerous):
                out.append('        <permission name="%s" fixed="false"/>' % name)
            out.append("    </exception>")
        # The summary stays streaming: it is diagnostic, it goes to stderr, and
        # it is not the artifact anything boots off, so showing how far a
        # failed run got is worth more than batching it.
        sys.stderr.write(
            "%s: %d privileged, %d dangerous, %d signature-only "
            "(not grantable by an allowlist), %d not declared by this platform, "
            "%d unclassified protectionLevel (normal and friends; declared but "
            "needs no allowlist entry)\n"
            % (pkg, len(privileged), len(dangerous), len(sig_only),
               len(unknown), len(unclassified)))
    out.append("</permissions>" if args.mode == "privapp" else "</exceptions>")

    document = "".join(line + "\n" for line in out)
    if args.out:
        write_atomically(args.out, document)
    else:
        sys.stdout.write(document)


if __name__ == "__main__":
    main()
