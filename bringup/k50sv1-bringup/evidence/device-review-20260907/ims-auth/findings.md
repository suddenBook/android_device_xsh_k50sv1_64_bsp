# mtkIms authorization boundary

Device `0eb4d70` and vendor `65d7211` add permission checks to the concrete
MtkImsService before the inherited dispatcher decodes any of its 24 requests.
The previous APK and actual mediatek-ims-base Stub lacked a uniform check;
only code 1 had an inner MODIFY_PHONE_STATE check, which remains intact.

READ means READ_PRIVILEGED_PHONE_STATE; MODIFY means MODIFY_PHONE_STATE.

| Code | Method | Permission | Reason |
|---:|---|---|---|
| 1 | setCallIndication | MODIFY | Call control; existing delegated check already requires it |
| 2 | createMtkCallSession | MODIFY | Returns/removes a pending controller from the session map |
| 3 | getPendingMtkCallSession | MODIFY | Returns a call controller and consumes pending state |
| 4 | getImsState | READ | Cached IMS state |
| 5 | getImsRegUriType | READ | Registration URI type |
| 6 | hangupAllCall | MODIFY | RIL call control |
| 7 | deregisterIms | MODIFY | RIL registration control |
| 8 | updateRadioState | MODIFY | Updates IMS/WFO state |
| 9 | UpdateImsState | MODIFY | Requests a global registration/capability/URI notification refresh |
| 10 | getConfigInterfaceEx | MODIFY | Returns a configuration-control Binder, and binds WFO |
| 11 | getMtkUtInterface | MODIFY | Returns a supplementary-service control Binder |
| 12 | runGbaAuthentication | MODIFY | Runs modem/SIM authentication and returns its key result |
| 13 | getModemMultiImsCount | READ | Reads modem capability property |
| 14 | getCurrentCallCount | READ | Counts tracked calls |
| 15 | getImsNetworkState | READ | Returns cached PDN state |
| 16 | addImsSmsListener | MODIFY | Replaces the SMS listener set, clearing the previous listener |
| 17 | sendSms | MODIFY | RIL SMS operation |
| 18 | registerProprietaryImsListener | READ | Subscribes to privileged registration/URI state |
| 19 | isCameraAvailable | READ | Queries video-call camera availability |
| 20 | setMTRedirect | MODIFY | Changes incoming-call routing state |
| 21 | fallBackAospMTFlow | MODIFY | Replays/clears pending incoming-call redirection |
| 22 | setSipHeader | MODIFY | Programs SIP headers through RIL |
| 23 | changeEnabledCapabilities | MODIFY | Changes enabled IMS capabilities |
| 24 | setImsPreCallInfo | MODIFY | Programs pre-call parameters |

The concrete class retains the Context already supplied to its constructor.
No caller-identity clearing, UID whitelist, upstream Stub, manifest or direct
ImsService call path is changed. Controller-returning getters and authoritative
SMS-listener replacement require MODIFY. State observation requires READ.
Phone/system callers and explicitly authorized Shell retain their privileges;
the presence of an MTK client library alone does not authorize an application.

Two Stock rebuilds produce identical bytes. All 2751 disassembled classes were
compared: only the Context field, one constructor store and onTransact differ.
Existing instructions and 38 non-DEX entries remain unchanged. Known-output
idempotence and previous/unknown/corrupt input rejection pass. Normal platform
signing is applied after this unsigned extraction result.

Live Enforcing checks use read code 4 getImsState(0) and control code 9
UpdateImsState(-1); the latter returns before notifications or modem work.
Ordinary UID10133 succeeds before repair and is denied afterwards; phone
UID1001 succeeds, and INTERFACE_TRANSACTION still returns the descriptor.
The process uses the su SELinux domain to isolate real Binder-UID permission
checks from service discovery policy. Both SIMs recover through an airplane
cycle after installation; no call or SMS test was made.

The receipt covers the two named root dispatchers, WFO and mtkIms. It does not
assert that every returned Binder interface or the entire IMS APK was audited.
