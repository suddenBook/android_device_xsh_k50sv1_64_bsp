# SELinux verification and current boundaries

Tier 1 records denials in permissive mode; successful features there do not
establish Enforcing readiness. Use the selected AOSP Q policy, actual source
consumers, process credentials, node labels and current AVCs together. Stock
compiled policy is supporting evidence from a multi-SKU product, not a list
of grants to copy. [HANDOFF](HANDOFF.md) owns installed results and
[workitems](../workitems.md) owns unresolved acceptance.

| Tier | Build variant / SELinux | Required boundary |
| --- | --- | --- |
| 1 | userdebug / permissive | Diagnostic capture with every unexplained denial retained. |
| 2 | userdebug / Enforcing | Affected features work with actual installed policy; no domain is made permissive to pass. |
| 3 | user / Enforcing | Clean signed release pipeline, external private keys, actual APK/APEX/BootSignature and release-property checks; legacy ePDG closure absent. |

The existing [build wrapper](../tools/run-lineage-build.sh) requires an explicit
tier and selects its variant. Direct user builds do not substitute for the
Tier-3 release pipeline. Keys/certificates already published in the repository
are not release keys. Package/BootSignature verification does not establish
AVB or a locked verified-boot chain on this device.

In an Android shell already configured for the intended product/variant,
`K50SV1_BUILD_TIER=1 m -j32 selinux_policy` provides the focused Tier-1 compile
check. Use the corresponding tier/variant for its other builds. The target
includes neverallow, Treble policy and context checks; a full user build must
also validate its actual generated policy, permissive-domain result and
user-only behavior. Do not mix generated CIL from different variants or
hand-reconstruct a different directory/attribute order.

For a proposed grant, identify the exact caller and target path, read the
consumer, inspect UID/groups/capabilities and confirm the label before deciding
whether policy or Unix ownership is wrong. Check ioctl values independently
of ordinary file permissions. Preserve the original AVC and collect a fresh
feature interval after installing the corresponding image. A clean boot-only
window cannot cover camera, audio, WebView, networking or suspend paths.
[AOSP device-policy guidance](https://source.android.com/docs/security/features/selinux/device-policy).

Current reviewed source contracts are:

| Path | Required implementation |
| --- | --- |
| WLAN/P2P attributes | Label the real `/devices/soc/180f0000.wifi/net` subtree `sysfs_net`; existing platform client rules then apply. A generic sysfs allow is unnecessary. |
| wfca wake locks | Its process needs GID 3010 (`wakelock`) for the existing 0660 radio:wakelock files. Root UID alone does not satisfy those DAC bits; no `dac_override` grant is needed. |
| Power HAL process-owner check | GID 3009 (`readproc`) permits the intended `/proc/<pid>` lookup under hidepid=2; only camera-domain directory `getattr` is added. A failed stat otherwise makes the HAL discard a live camera owner's performance request. |
| Audio capture scheduling | The audio HAL's actual scheduling call needs `sys_nice`, matching the capability already supplied by init. |
| GED ioctl authorization | Native and compat entry points must validate the GED magic and require the complete payload command to equal the outer ioctl before dispatch. SELinux checks the outer command; an independently selected payload can bypass an otherwise narrow allowxperm. |
| Modem version property | The vendor modem publishes `vendor.ril.impl`; the framework proxy owns `gsm.version.ril-impl`. Existing vendor property policy suffices. |

These source contracts are not a claim that a candidate image has been
installed. Build and post-flash results belong to the current review record.
For GED, require valid direct/library queries to work and mismatched-command
and wrong-magic queries to return EINVAL on both ABIs, followed by graphics
and video checks. Host dispatch fixtures do not establish handler safety.

Retain these narrower policy boundaries:

- Ordinary graphic-buffer users reach GED through the in-process mapper,
  gralloc_extra and libged. DT_NEEDED alone is not a call trace. Apps retain the
  reviewed GE command range; system/HAL DVFS commands are separate. Matching
  the outer ioctl is required before that separation has meaning.
- `/dev/wmtWifi` belongs to the Wi-Fi HAL/calibration loader path, not the
  Power HAL. Debugfs access stays at measured leaves, such as GPU memory and
  the ION client summary, rather than their parent trees.
- `wfo` and IMS have dedicated binder service labels. `system_app` discovery
  and Java method authorization are different controls. WFO and mtkIms check
  standard privileged read/modify phone permissions before their 12/24
  transactions; ordinary UID denial and phone UID success pass for both under
  Enforcing. Controller-returning getters require MODIFY_PHONE_STATE. System
  UID and authorized Shell remain trusted. This does not audit all subsequently
  returned Binder interfaces.
- Keep `/dev/block/zram0` as `swap_block_device` and `para` as the device's
  `mtk_para_block_device`; their real init/modem consumers and user-variant
  neverallows must be preserved. Use the Q fstab `notrim` flag to exclude all three calibration
  stores from ordinary maintenance in every tier. Check installed flags and
  actual maintenance targets; retain the denied access as a separate
  Enforcing boundary. A permissive success cannot prove that refusal.
- The observed fuel-gauge socket is NETLINK_FGD protocol 26. A Full/100%,
  USB-connected idle window does not cover charge/discharge transitions;
  retain the route-grant audit until that lifecycle evidence exists.

Actual video reproduced camera→GPU/configstore denials; the measured GPU access
and standard HAL-client relationship now pass temporary Enforcing video/JPEG
tests. Full Tier-2 boot and WebView coverage remain in WI-023. The Power HAL's
remaining camera comm-file refusals affect diagnostic names; live hint ownership
and release still work. They stay logged without a new allow or dontaudit.
Do not classify a refusal as expected without tracing the failed operation and
verifying its effect. WFO/ePDG component
scope is defined in [the IMS tier contract](vowifi-feasibility.md).
