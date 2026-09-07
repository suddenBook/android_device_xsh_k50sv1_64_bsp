# IMS and VoWiFi tier contract

All tiers retain the WFO/IMSA/VoLTE/RDS pieces proven necessary for cellular
IMS. Only diagnostic tiers 1/2 retain the legacy ePDG tunnel. Tier 3 removes
its exact 29-file vendor closure and both init definitions and resolves
`config_device_wfc_ims_available=false`; it provides no Wi-Fi calling.
The release still needs separate cellular IMS acceptance.
[Product selection](../../../lineage-17.1/device/xsh/k50sv1_64_bsp/device.mk),
[tier-contract checks](../tools/test-tier-vowifi-contract.sh),
[release-contract checks](../tools/test-tier3-release-contract.sh).

The extracted tunnel includes strongSwan 5.1.2. Upstream's
[CVE-2026-47895 advisory](https://www.strongswan.org/blog/2026/06/08/strongswan-vulnerability-(cve-2026-47895).html)
covers versions since 4.3.3 and describes unauthenticated identity handling on
EAP/XAuth server paths. The affected version is established; remote triggerability
through this phone's ePDG client configuration is not. The standing Tier-3
exclusion remains, without treating a version match as proof of a demonstrated
phone-client exploit. Replacement requires the real WOD/plugin/crypto contract
and its own runtime evidence.

The diagnostic path is WFO → mtkmal → epdg_wod → strongSwan → kernel XFRM/IPsec
→ carrier ePDG. Source-built connectivity drivers do not replace that userspace
tunnel. Shared MAL/supplicant control uses `/data/vendor/wifi/sock` directly,
with vendor data labels; the old bind-mount bridge is absent.

The current APN fragment has **ten** IMS rows for Vodafone NL, its specified
China-Telecom MVNO identity and the CU/CMCC MNCs advertised by CarrierConfig.
Every row uses `IPV4V6` for both protocol fields and network-type mask
`1|2|3|8|9|10|13|15|16|17|18|19` (**512903**). This includes IWLAN while
excluding CDMA types. An all-types mask creates a 3GPP2 profile rejected by
this RIL. Untyped base APNs must not acquire `ims` through database type merging.
[Device APNs](../../../lineage-17.1/device/xsh/k50sv1_64_bsp/configs/apns-conf.xml),
[base-APN patch](../upstream/apns-conf.xml.patch),
[validator](../../../lineage-17.1/device/xsh/k50sv1_64_bsp/tools/validate-custom-apns.py).

WFO's feature receiver refreshes its existing flags, then applies the broadcast's
`phone_id/item/value` to the changed feature before notifying MAL. The intent
must win because the modem property can still contain the preceding value.
The private-method/synthetic-accessor invocation remains DEX-verifier correct.
Do not restore the invalid MtkImsManager cast or an inert receiver. The extractor
also removes empty Android RSSI callbacks while preserving MAL's independent
`SIGNAL_POLL`/quality path; this is not proof of a measured energy improvement.
[Actual receiver transformation](../../../lineage-17.1/device/xsh/k50sv1_64_bsp/extract-files.sh).

The two WFC-named RIL support flags remain enabled because the cellular IMS
path also uses them. CU, CMCC and Vodafone carrier availability overrides do
not establish entitlement; on Tier 3 the false device-wide WFC capability wins.
All three persistent AOSP WFC debug overrides stay zero, and init must not
force the user's `persist.vendor.mtk.wfc.enable` preference back to zero.

Several other radio names are easy to misinterpret:

| Component / setting | Current contract |
| --- | --- |
| `ro.vendor.mtk_eccci_c2k=1` | The two libcustom_nvram ABIs read it to select the 52-byte backup-file header. It is a persistent-data ABI selector; the absent MD3 property does not disable this reader. Retain it. |
| Optional radio_op / WWOP | Ordinary dial and USSI use ImsRILAdapter. The shipped fallback and base DIGITS implementation do not require WWOP. Keep the extension absent unless a required extension feature or actual trace reaches it. |
| `ipsec_mon` | This daemon actively changes routes, iptables and nested policy; it is not a passive SIP-IPsec monitor. The shipped VoLTE caller uses ordinary `setkey_SP`; retain the current exclusion and do not set its version property without its matching implementation. |
| SAP and legacy RIL sockets | `msap_uim_socket1/2` are actual listeners with clients. `mrild3` and `rild-vsim3` have native consumers despite no listener in the reviewed window. Their names alone do not justify deletion. |

The installed Chinese subscriptions in the reviewed baseline are roaming.
Correct installed APNs and an idle retry path do not prove IMS registration.
Require an actual successful IMS PDN, registration technology and MMTEL
capabilities for a registration result, followed by an ordinary call for call
acceptance. The previous Vodafone HOME-SIM pass does not prove Chinese HOME
service. Current SIM conditions cannot provide the owner's requested meaningful
VoWiFi acceptance test; no DNS failure establishes that the stack is impossible.

Validate product/resource/ELF contracts before a build, then inspect installed
APN rows, services, credentials and focused radio events after installation.
Use reset, attach, data-call errors and process health rather than total radio
line count; routine RILMUXD traffic is verbose. Keep the ordinary-call test
separate from an airplane/reset cycle, and do not use emergency numbers.
Tier-3 acceptance additionally proves tunnel/WFC absence and cellular IMS
behavior under its actual Enforcing release policy.
