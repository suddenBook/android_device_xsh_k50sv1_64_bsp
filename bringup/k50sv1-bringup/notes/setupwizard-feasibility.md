# SetupWizard and HOME contract

The product ships the Q-era MindTheGapps SetupWizard together with
LineageSetupWizard. Keep both: Lineage's higher-priority HOME activity detects
the installed Google wizard, disables its own HOME component and finishes.
Its package remains available to contribute Lineage pages to Google's flow.

LineageSetupWizard is the partner package for
`com.android.setupwizard.action.PARTNER_CUSTOMIZATION`. Google looks up its
`wizard_script_uri` and `wizard_script_user_uri` resources by name; the scripts
include Lineage settings, restore and completion pages. A second partner
package would make that selection ambiguous. MindTheGapps' SetupWizard module
overrides `Provision`, while the Lineage package stays installed.
[Lineage activity source](../../../lineage-17.1/packages/apps/SetupWizard/src/org/lineageos/setupwizard/SetupWizardActivity.java),
[partner resources](../../../lineage-17.1/packages/apps/SetupWizard/res/raw/).

The selected MindTheGapps payload contains SetupWizard 3507
(`229.285543768`, SDK 29), AndroidMigratePrebuilt, GooglePartnerSetup and its
own hidden-API/privileged-permission declarations. It does not include
GoogleOneTimeInitializer or GoogleRestore. The complete Q-era flow was
previously exercised to provisioning complete, Trebuchet, the AOSP dialer and
LatinIME. Cloud-restore acceptance is not established by package inventory.

Niagara and its dedicated HOME fallback/grants are removed. Standard Q selects
SetupWizard while setup is pending and Trebuchet after setup; no manual HOME
setter is needed. The build19 fresh-data check confirms this after the
explicit test bypass, rather than claiming that bypass exercised the wizard UI.
[Product/runtime removal evidence](../evidence/niagara-removal-20260906/build15-normal-runtime.json),
[fresh HOME](../evidence/wmt-paired-runtime-20260907/runtime/build19-initial-home/result.json).

For later tests, distinguish a real wizard completion from preparation that
sets provisioning flags or grants Calendar permissions. Neither changes the
product's ordinary permission/default-choice contract. Latest installed state
and active app issues are in [HANDOFF](HANDOFF.md) and [workitems](../workitems.md).
