# Trebuchet HOME-transition crash

**Declined, not applied.** On 2026-09-07 the owner chose to keep the frozen
LineageOS 17.1 upstream unchanged and publish the tested Tier-3 build. The patch
and regression below remain historical analysis, not pending release work.
During the recorded Tier-2 setup bypass, Trebuchet
PID2536 crashes once at 12:30:42 with `Receiver not registered` in
`OverviewComponentObserver.updateOverviewTargets`. Later app/feature checks and
the second boot pass; that does not erase this [first-boot crash](crash-excerpt.txt).

When HOME is disabled and its resolver returns null, the current method removes
the package receiver but retains `mUpdateRegisteredPackage`. A later update can
unregister it twice, or omit re-registration for the same package. The proposed
[one-line patch](0001-clear-unregistered-home-package.patch) clears that field
when the receiver is removed. The own-HOME branch and `onDestroy` clear the field; a different-package
replacement immediately overwrites it. The device stack establishes the failing
unregister call; the specific HOME/null sequence is inferred from this source
path and reproduced by the host harness.
The [current AOSP observer](https://android.googlesource.com/platform/packages/apps/Launcher3/+/master/quickstep/src/com/android/quickstep/OverviewComponentObserver.java)
also clears the recorded package in its common unregister helper.

A host harness executes the complete method extracted from the exact installed
source revision against controlled HOME transitions and a receiver registry.
The unchanged method throws the same exception; the proposed method passes all
nine transitions with four registrations and four removals. [Results](results.json),
[input hashes](inputs.json). This tests the Java state transition, not a complete
Android runtime. The normal final Tier-3 setup transition did not reproduce
the crash. Further patch/build/transition work was declined by the owner.

The owner requires consultation for new Android upstream edits (request item 6).
The patch is stored only in work/; packages/apps/Trebuchet is unchanged.
