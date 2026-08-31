/*
 * k50sv1 RIL shim
 * ===============
 *
 * WHAT THIS DOES
 *
 * It is loaded by /vendor/bin/hw/rilproxy in place of mtk-rilproxy.so, forwards
 * every RIL entry point to the real blob, and changes exactly two things.
 *
 *   1. It publishes the two physical protocol stacks' fixed, truthful radio
 *      capabilities and completes Android's attempted capability swap as a
 *      hardware no-op, so the broken MTK SIM switch never runs. See "PART 1".
 *
 *   2. It re-sends the initial-attach APN when the vendor RIL asks for it,
 *      which is the thing AOSP's framework does not do and MediaTek's own
 *      framework add-on would have. See "PART 2" below.
 *
 * ============================================================================
 * PART 1 - truthful fixed radio capabilities without the MTK SIM switch
 * ============================================================================
 *
 * WHY
 *
 * This handset is an MTK DSDS with a single LTE-capable protocol stack:
 *
 *   ro.vendor.mtk_ps1_rat            = Lf/Lt/W/T/G      (slot 0, has LTE)
 *   persist.vendor.radio.mtk_ps2_rat = W/G              (slot 1, no LTE)
 *
 * so the two phones report different RAFs (measured: 36869 vs 32772), and
 * SubscriptionController.setDefaultDataSubId() therefore hands ProxyController
 * a pair of RAFs that differ from the current pair every time the user selects
 * the slot-1 subscription for mobile data. ProxyController then runs a real
 * START/APPLY/FINISH radio-capability transaction
 * (frameworks/opt/telephony/.../ProxyController.java:210-247).
 *
 * The vendor RIL's APPLY handler calls doSimSwitchWithoutMdReset()
 * (vendor/lib64/mtk-ril.so, exported symbol at 0xbba20). Its FIRST action is
 *
 *     for (i = 0; i < getSimCount(); i++) setRadioState(RADIO_STATE_UNAVAILABLE, i);
 *
 * followed by AT+EBOOT=1 and closeChannel() on all 12 AT channels. Only at the
 * very end does it send the APPLY response and RIL_UNSOL_RADIO_CAPABILITY. On
 * this handset it never gets there: at 0xbbc94 it busy-spins on
 *
 *     while (getSignalCounter() != getSupportChannels());   // getSupportChannels() is a hard-coded 12
 *
 * and that counter is only incremented by the SIGUSR1 handler of a live AT
 * reader thread. A reader that already exited through its own EOF path
 * (readerLoop 0xc1c74, "%s Closed, trigger TRM!") never increments it, so the
 * loop cannot terminate. Measured result (E-080, and reproduced live in this
 * session when a SIM was hot-swapped): both radios stay UNAVAILABLE, both
 * sockets report CARDSTATE_ERROR/RADIO_NOT_AVAILABLE, and the fault survives
 * reboot because the framework has already persisted the slot-1 default.
 *
 * The transaction is also POINTLESS on this modem even when it completes.
 * mtk-ril.so's applyRadioCapability sets its switch target with
 *
 *     0xbbfd8  ldrb w8, [x21, 0xc]      ; low byte of RIL_RadioCapability.rat
 *     0xbbfdc  tbz  w8, #1, 0xbbfe4     ; only if HAL RadioAccessFamily.GPRS (1<<1)
 *     0xbbfe0  str  w22, [x24]          ; targetSimRid = rilId
 *
 * but RIL.java:4035 sends `halRc.raf = rc.getRadioAccessFamily()` WITHOUT
 * converting to the HAL encoding (it converts on the way up, in
 * convertHalRadioCapability, but not on the way down). In the framework
 * encoding bit 1 is NETWORK_TYPE_BITMASK_EDGE, which neither 36869 nor 32772
 * sets, so targetSimRid stays 0 and the RIL always emits AT+ESIMMAP=1 and
 * setSimSwitchProp(1) - i.e. it re-selects the slot that is already selected.
 * That is why persist.vendor.radio.simswitch never left 1 across every
 * observed attempt. The switch destroys the radio state and changes nothing.
 *
 * HOW THE FIX WORKS
 *
 * GET_RADIO_CAPABILITY is answered from the last native values measured before
 * this shim existed. They describe protocol stacks, not the network a SIM is
 * currently attached to:
 *
 *   socket 0  0x1400a = GSM|GPRS|UMTS|LTE  modem_sys1_ps1
 *   socket 1  0x10008 = GSM|UMTS           modem_sys1_ps2
 *
 * These are ril.h's native 1<<RADIO_TECH_* masks. In particular 0x2 is GPRS,
 * not EDGE. RIL.java converts them to framework masks 36869 and 32772.
 *
 * Truthful unequal RAFs make generic AOSP try to move the maximum RAF to the
 * default-data phone. There is no resource switch for that assumption. The shim
 * therefore owns SET_RADIO_CAPABILITY too: it returns successful START, APPLY
 * and FINISH responses without forwarding request 131, and emits exactly one
 * session-matched success UNSOL_RSP per APPLY. Every response reports the
 * physical socket's unchanged RAF and UUID. ProxyController completes cleanly,
 * Phone keeps truthful state, and no modem or AT channel is touched.
 *
 * Switching the default data subscription still works, through the path
 * Android 10 actually uses for it: PhoneSwitcher selects HAL_COMMAND_PREFERRED_DATA
 * because IRadioConfig 1.1 is declared in this device's VINTF manifest, and
 * moves the data path with RadioConfig.setPreferredDataModem(). Measured on
 * this handset:
 *
 *     RadioConfig: [0301]> SET_PREFERRED_DATA_MODEM
 *     RadioConfig_service: radioConfig::setPreferredDataModem serial=301
 *     RfxRoot: ... RIL_REQUEST_SET_PREFERRED_DATA_MODEM(150) ... RpDataController
 *     RadioConfigResponse: [0301]< SET_PREFERRED_DATA_MODEM        (no error)
 *
 * COST, STATED PLAINLY
 *
 * Data on slot 1 runs on protocol stack 2, which is W/G, so it is never LTE.
 * Do not promise 3G either: E-084 measured EDGE on both SIMs tried there. That
 * is what this hardware can do without a working modem SIM switch, and the
 * switch is broken in the vendor blob (see above), not in this port. Selecting
 * slot 1 now runs a short synthetic transaction and briefly holds AOSP's
 * ProxyController wakelock. Failing SET would be wrong: ProxyController retries
 * the old RAFs after a failed transaction. Completing it as an explicit no-op
 * is what terminates the state machine while preserving physical truth.
 *
 * ============================================================================
 * PART 2 - re-send the initial-attach APN when the vendor RIL asks
 * ============================================================================
 *
 * THE DEFECT (E-092). Any airplane-mode cycle permanently removes LTE from the
 * LTE-capable slot until the next reboot. Data, VoLTE and IMS go with it.
 *
 * On RIL_REQUEST_RADIO_POWER off, mtk-ril.so's defineAttachApnIfIACacheExisted
 * tries to re-define the attach APN from its own cache. MediaTek deliberately
 * does not persist the PASSWORD, so when the APN had one the cache is useless:
 *
 *     IA: defineAttachApnIfIACacheExisted empty IA due to password
 *     IA: defineAttachApnIfIACacheExisted clear IA cache and IA ICCID
 *     AT> AT+CGDCONT=0,"IP","this_is_an_invalid_apn",,0,0,0,0,0,0
 *
 * It then asks the framework to re-send, 740 times in the measured run:
 *
 *     onAttachApnReset: invalid IA, clean cache and send RIL_UNSOL_RESET_ATTACH_APN
 *
 * and rilproxy drops every one of them, because the only route it has for that
 * URC is MediaTek's EXTENDED IRadioIndication, which only MediaTek's framework
 * add-on registers:
 *
 *     RILC-RP: resetAttachApnInd: mtkRadioExService[0]->mRadioIndicationMtk == NULL
 *
 * AOSP would have re-sent if it had heard. DcTracker calls setInitialAttachApn()
 * from exactly three places - onApnChanged(), onRecordsLoadedOrSubIdChanged()
 * and onDataRoamingOff() - and none fires on a radio power cycle. That is
 * deliberate, and AOSP says why at DcTracker.java:2673-2676:
 *
 *     // TODO: Remove this once all old vendor RILs are gone. We don't need to
 *     // set initial apn attach and send the data profile again as the modem
 *     // should have both roaming and non-roaming protocol in place.
 *
 * So AOSP's contract is that the modem RETAINS it; MediaTek's RIL discards it
 * and relies on an add-on that is not here. Neither half is wrong alone.
 * This shim is the "old vendor RIL" workaround AOSP's own comment anticipates.
 *
 * HOW. Cache the last RIL_REQUEST_SET_INITIAL_ATTACH_APN payload per socket,
 * and on RIL_UNSOL_RESET_ATTACH_APN re-issue it verbatim with a token this
 * shim owns.
 *
 * THE STRUCT. Verified against four binaries - the two producers
 * (librilproxy.so RadioImpl::setInitialAttachApn and ::setInitialAttachApn_1_4)
 * and two consumers (mtk-rilproxy.so's parcel encoder for request 111, and
 * mtk-ril.so requestSetInitialAttachApn). It is AOSP's RIL_InitialAttachApn_v15
 * with ONE extra int appended:
 *
 *   0x00 char *apn            0x20 char *username      0x40 char *mvnoType
 *   0x08 char *protocol       0x28 char *password      0x48 char *mvnoMatchData
 *   0x10 char *roamingProtocol 0x30 int supportedTypesBitmask
 *   0x18 int authtype          0x34 int bearerBitmask
 *   0x1c (pad)                 0x38 int modemCognitive
 *                              0x3c int mtu
 *   0x50 int canHandleIms   <- MediaTek's, one past the end of AOSP's v15
 *   0x54 (pad)                 sizeof = 0x58 = 88
 *
 * Every one of AOSP's twelve offsets matches byte for byte. Both producers pass
 * datalen 88 (`mov w2, #0x58`) and mtk-rilproxy's encoder reads exactly through
 * +0x50 and stops. HANDOFF trap 21 is about the RIL_RadioFunctions table, which
 * IS longer than AOSP's - librilproxy's RIL_register copies 56 bytes, seven
 * members, one past AOSP's six. That is a different struct in the other
 * direction, and it is why RIL_Init still patches in place below.
 *
 * TWO THINGS THE COPY MUST GET RIGHT, both measured:
 *
 *   * Members are legitimately NULL. copyHidlStringToRil writes NULL rather
 *     than "" for an empty hidl_string unless allowEmpty is set, and only `apn`
 *     is called with allowEmpty=1. Turning NULL into "" would change the parcel
 *     from a null string to an empty one.
 *   * The strings are freed the instant onRequest returns - librilproxy calls
 *     memsetAndFreeStrings(6, ...) on the next instruction. Caching the
 *     POINTERS gives dangling, already-zeroed memory. The copy happens inside
 *     onRequestShim, before it returns.
 *
 * WHY A GOT HOOK AND NOT THE RIL_Env. E-092 proposed patching
 * env->OnUnsolicitedResponse in place. That patch would never have fired.
 * mtk-rilproxy.so does not use the RIL_Env for this: it imports
 * RIL_onUnsolicitedResponse and RIL_onRequestComplete directly from
 * librilproxy.so and calls them through its own PLT -
 * RfxRilAdapter::responseToRilj tail-calls RIL_onUnsolicitedResponse@plt. An
 * exhaustive scan of the three users of its saved env pointer finds only
 * RIL_Init (the store), setRadioState (URCs 1000/1019) and
 * sendBtSapResponseComplete. URC 3020 is not among them.
 *
 * So the two hooks go in mtk-rilproxy.so's own .got.plt, found at runtime by
 * walking DT_JMPREL/DT_SYMTAB/DT_STRTAB rather than by hardcoding an offset.
 * PT_GNU_RELRO covers .got.plt, so the slots are read-only and need the same
 * mprotect dance patchOnRequest already does.
 *
 * WHY THE SECOND HOOK. The re-issued request is completed by mtk-ril.so with
 * the token it was given, and librilproxy's RIL_onRequestComplete DEREFERENCES
 * the token (`ldr w8, [x0, #0x1c]`) before validating it. A token this shim
 * invented must therefore never reach it, so RIL_onRequestComplete is hooked
 * too and swallows exactly that one pointer.
 *
 * WHY A WORKER THREAD. The URC arrives on mtk-rilproxy's reader thread. Calling
 * back into its onRequest from inside its own URC dispatch risks re-entering a
 * lock it holds. Handing the work to a dedicated thread makes the call look
 * like every other request dispatch, and gives somewhere to rate-limit: the
 * vendor RIL emits this URC continuously (740 times in four minutes) until the
 * APN is valid again, and one re-issue per second is enough.
 *
 * IF THIS PART FAILS it logs and disables itself. Telephony then behaves
 * exactly as it did before this part existed - E-092 is back, nothing else
 * changes. The mechanism only becomes active after both hooks and the worker
 * are verified. If a failed rollback physically leaves a hook in one GOT slot,
 * it remains a safe forwarding thunk; its published original is never cleared.
 *
 * THAT PROMISE IS ABOUT PART 2 ONLY, and the distinction is load-bearing.
 * RIL_Init deliberately does NOT fail open: if patchOnRequest fails, it
 * returns NULL, and by then realInit() has already brought the vendor RIL all
 * the way up. The result is a half-initialised telephony stack, which is worse
 * than either alternative -- but the alternative is handing back an unpatched
 * table, and that silently restores MediaTek's destructive radio-capability
 * switch behind an ordinary Settings tap (PART 1). Fail closed is the
 * deliberate choice; do not "fix" it into fail open without reading PART 1.
 */

#define LOG_TAG "k50sv1-ril-shim"

#include <dlfcn.h>
#include <elf.h>
#include <errno.h>
#include <link.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#ifdef K50SV1_RIL_SHIM_HOST_TEST
#define RLOGI(...) do { fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } while (0)
#define RLOGE(...) do { fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } while (0)
#else
#include <log/log.h>
#endif
#include <telephony/ril.h>

/*
 * Resolved through the vendor linker namespace, exactly as rilproxy would have
 * resolved it from its own -l argument. Keep the bare SONAME: an absolute path
 * is rejected by the Treble vendor namespace for a permitted-path lookup.
 */
#ifndef REAL_RIL_SONAME
#define REAL_RIL_SONAME "mtk-rilproxy.so"
#endif

typedef const RIL_RadioFunctions *(*ril_init_fn)(const struct RIL_Env *env,
                                                 int argc, char **argv);

static const RIL_RadioFunctions *sRealFuncs;
/*
 * The blob's own onRequest, captured BEFORE its table is patched. Calling
 * sRealFuncs->onRequest here instead would re-enter this shim: the patch
 * points that slot at onRequestShim, clang tail-calls it, and rilproxy's
 * dispatch thread spins forever with no crash and no dispatched request.
 * That was the second bug in this file; the symptom was a completely silent
 * telephony stack that came back the moment rilproxy.rc loaded the blob
 * directly.
 */
static RIL_RequestFunc sRealOnRequest;
static const struct RIL_Env *sEnv;
static void *sRealHandle;

/* ------------------------------------------------------------------------- *
 * Fixed radio-capability contract. See PART 1 of the file header.
 * ------------------------------------------------------------------------- */

#define SLOT0_NATIVE_RAF (RAF_GSM | RAF_GPRS | RAF_UMTS | RAF_LTE)
#define SLOT1_NATIVE_RAF (RAF_GSM | RAF_UMTS)
#define SLOT0_MODEM_UUID "modem_sys1_ps1"
#define SLOT1_MODEM_UUID "modem_sys1_ps2"

_Static_assert(sizeof(RIL_RadioCapability) == 84,
               "RIL_RadioCapability must be exactly 84 bytes");
_Static_assert(offsetof(RIL_RadioCapability, logicalModemUuid) == 16,
               "logicalModemUuid must start at +0x10");
_Static_assert(offsetof(RIL_RadioCapability, status) == 80,
               "status must sit at +0x50");
_Static_assert(SLOT0_NATIVE_RAF == 0x1400a,
               "slot 0 native RAF must match the measured modem response");
_Static_assert(SLOT1_NATIVE_RAF == 0x10008,
               "slot 1 native RAF must match the measured modem response");

/* A duplicate APPLY indication decrements ProxyController's per-phone counter
 * twice and may complete the transaction before the other phone answers. HIDL
 * does not normally retry a request, but suppress a repeated session anyway. */
static pthread_mutex_t sRcLock = PTHREAD_MUTEX_INITIALIZER;
static int sLastApplySession[SIM_COUNT];
static bool sLastApplySessionValid[SIM_COUNT];

static bool fillFixedRadioCapability(RIL_SOCKET_ID socketId, int session,
                                     int phase, int status,
                                     RIL_RadioCapability *out)
{
    const char *uuid;

    if (out == NULL) {
        return false;
    }

    memset(out, 0, sizeof(*out));
    switch (socketId) {
    case RIL_SOCKET_1:
        out->rat = SLOT0_NATIVE_RAF;
        uuid = SLOT0_MODEM_UUID;
        break;
    case RIL_SOCKET_2:
        out->rat = SLOT1_NATIVE_RAF;
        uuid = SLOT1_MODEM_UUID;
        break;
    default:
        return false;
    }

    out->version = RIL_RADIO_CAPABILITY_VERSION;
    out->session = session;
    out->phase = phase;
    out->status = status;
    /* The struct was zeroed, and both literals are far shorter than 64 bytes. */
    memcpy(out->logicalModemUuid, uuid, strlen(uuid));
    return true;
}

/*
 * ProxyController always issues START before APPLY, so START is where the
 * per-socket dedupe is cleared. Without this the dedupe never expires and a
 * session id can collide across a system_server restart: the session counter is
 * `new AtomicInteger(0)` inside system_server while rilproxy outlives it, so the
 * first APPLY after a restart carries session 0 again. If session 0 had already
 * been seen on that socket, the solicited response would go out with NO
 * RIL_UNSOL_RADIO_CAPABILITY behind it, ProxyController's per-phone counter
 * would never decrement, and the transaction would time out after 30 s and
 * revert both RAFs -- i.e. selecting the slot-1 data subscription silently
 * stops working until the next reboot.
 */
static void resetApplyDedupe(RIL_SOCKET_ID socketId)
{
    int index = (int)socketId;

    if (index < 0 || index >= SIM_COUNT) {
        return;
    }
    pthread_mutex_lock(&sRcLock);
    sLastApplySessionValid[index] = false;
    pthread_mutex_unlock(&sRcLock);
}

static bool shouldSendApplyUnsol(RIL_SOCKET_ID socketId, int session)
{
    int index = (int)socketId;
    bool send;

    if (index < 0 || index >= SIM_COUNT) {
        return false;
    }

    pthread_mutex_lock(&sRcLock);
    send = !sLastApplySessionValid[index] ||
           sLastApplySession[index] != session;
    if (send) {
        sLastApplySession[index] = session;
        sLastApplySessionValid[index] = true;
    }
    pthread_mutex_unlock(&sRcLock);
    return send;
}

static void rejectRadioCapabilityRequest(RIL_Token t, int request,
                                         RIL_SOCKET_ID socketId,
                                         const void *data, size_t datalen)
{
    RLOGE("rejecting radio-capability request=%d socket=%d has_data=%d len=%zu",
          request, (int)socketId, data != NULL, datalen);
    sEnv->OnRequestComplete(t, RIL_E_INVALID_ARGUMENTS, NULL, 0);
}

static void getRadioCapability(RIL_Token t, RIL_SOCKET_ID socketId)
{
    RIL_RadioCapability response;

    if (!fillFixedRadioCapability(socketId, 0, RC_PHASE_CONFIGURED,
                                  RC_STATUS_NONE, &response)) {
        rejectRadioCapabilityRequest(t, RIL_REQUEST_GET_RADIO_CAPABILITY,
                                     socketId, NULL, 0);
        return;
    }

    RLOGI("GET_RADIO_CAPABILITY socket=%d -> raf=0x%x uuid=%s",
          (int)socketId, response.rat, response.logicalModemUuid);
    sEnv->OnRequestComplete(t, RIL_E_SUCCESS, &response, sizeof(response));
}

static void setRadioCapability(const void *data, size_t datalen, RIL_Token t,
                               RIL_SOCKET_ID socketId)
{
    const RIL_RadioCapability *request = data;
    RIL_RadioCapability response;
    RIL_RadioCapability unsol;

    if (request == NULL || datalen != sizeof(*request) ||
        (request->phase != RC_PHASE_START &&
         request->phase != RC_PHASE_APPLY &&
         request->phase != RC_PHASE_FINISH) ||
        !fillFixedRadioCapability(socketId, request->session, request->phase,
                                  RC_STATUS_SUCCESS, &response)) {
        rejectRadioCapabilityRequest(t, RIL_REQUEST_SET_RADIO_CAPABILITY,
                                     socketId, data, datalen);
        return;
    }

    if (request->phase == RC_PHASE_START) {
        resetApplyDedupe(socketId);
    }

    /* FINISH carries the transaction result as an input. Preserve it; START and
     * APPLY use the successful-response convention measured from this RIL. */
    response.status = request->phase == RC_PHASE_FINISH
            ? request->status : RC_STATUS_SUCCESS;

    RLOGI("SET_RADIO_CAPABILITY no-op socket=%d session=%d phase=%d "
          "-> raf=0x%x uuid=%s",
          (int)socketId, request->session, request->phase, response.rat,
          response.logicalModemUuid);
    sEnv->OnRequestComplete(t, RIL_E_SUCCESS, &response, sizeof(response));

    if (request->phase != RC_PHASE_APPLY ||
        !shouldSendApplyUnsol(socketId, request->session)) {
        return;
    }

    if (!fillFixedRadioCapability(socketId, request->session,
                                  RC_PHASE_UNSOL_RSP, RC_STATUS_SUCCESS,
                                  &unsol)) {
        /* Socket validity was established above; this is unreachable unless
         * the fixed-capability helper itself changes underneath this path. */
        RLOGE("could not construct APPLY indication for socket=%d session=%d",
              (int)socketId, request->session);
        return;
    }
    sEnv->OnUnsolicitedResponse(RIL_UNSOL_RADIO_CAPABILITY, &unsol,
                                sizeof(unsol), socketId);
}

/*
 * Original protection of the mapping that contains `addr`, from
 * /proc/self/maps, as a PROT_* mask. Returns -1 if the address is not found.
 */
static int mappingProt(uintptr_t addr)
{
    FILE *maps = fopen("/proc/self/maps", "re");
    char line[512];
    int prot = -1;

    if (maps == NULL) {
        return -1;
    }
    while (fgets(line, sizeof(line), maps) != NULL) {
        unsigned long long start, end;
        char perms[8];

        if (sscanf(line, "%llx-%llx %7s", &start, &end, perms) != 3) {
            continue;
        }
        if (addr < start || addr >= end) {
            continue;
        }
        prot = PROT_NONE;
        if (perms[0] == 'r') prot |= PROT_READ;
        if (perms[1] == 'w') prot |= PROT_WRITE;
        if (perms[2] == 'x') prot |= PROT_EXEC;
        break;
    }
    fclose(maps);
    return prot;
}

/* ------------------------------------------------------------------------- *
 * Initial-attach APN re-send (E-092). See PART 2 of the file header.
 * ------------------------------------------------------------------------- */

/*
 * MediaTek's payload for RIL_REQUEST_SET_INITIAL_ATTACH_APN: AOSP's
 * RIL_InitialAttachApn_v15 with one int appended. Spelled out here rather than
 * reused from ril.h so that the one MTK field is impossible to miss, and so the
 * static assert below compares against a layout this file can see.
 */
typedef struct {
    char *apn;
    char *protocol;
    char *roamingProtocol;
    int   authtype;
    char *username;
    char *password;
    int   supportedTypesBitmask;
    int   bearerBitmask;
    int   modemCognitive;
    int   mtu;
    char *mvnoType;
    char *mvnoMatchData;
    /*
     * (supportedTypesBitmask != 0xffff) && (supportedTypesBitmask & 0x40).
     * Copied verbatim, never recomputed: 0xffff is a MediaTek sentinel whose
     * meaning is not established.
     */
    int   canHandleIms;
} MtkInitialAttachApn;

_Static_assert(offsetof(MtkInitialAttachApn, canHandleIms) == 0x50,
               "canHandleIms must sit at +0x50");
_Static_assert(sizeof(MtkInitialAttachApn) == 0x58,
               "MTK's initial-attach APN payload is 88 bytes");

/*
 * The design rests on this struct being AOSP's RIL_InitialAttachApn_v15 plus
 * exactly one trailing int, and on all twelve AOSP offsets being unchanged.
 * Two absolute constants cannot express that: they would still hold if two
 * AOSP fields swapped places. Compare against the header instead, so a change
 * on either side is a compile error rather than a wrong pointer written into
 * the vendor RIL's parcel.
 */
_Static_assert(sizeof(RIL_InitialAttachApn_v15) ==
                   offsetof(MtkInitialAttachApn, canHandleIms),
               "MTK's extra int must begin exactly where AOSP's v15 ends");
#define IA_PIN_OFFSET(member) \
    _Static_assert(offsetof(MtkInitialAttachApn, member) == \
                       offsetof(RIL_InitialAttachApn_v15, member), \
                   #member " moved relative to RIL_InitialAttachApn_v15")
IA_PIN_OFFSET(apn);
IA_PIN_OFFSET(protocol);
IA_PIN_OFFSET(roamingProtocol);
IA_PIN_OFFSET(authtype);
IA_PIN_OFFSET(username);
IA_PIN_OFFSET(password);
IA_PIN_OFFSET(supportedTypesBitmask);
IA_PIN_OFFSET(bearerBitmask);
IA_PIN_OFFSET(modemCognitive);
IA_PIN_OFFSET(mtu);
IA_PIN_OFFSET(mvnoType);
IA_PIN_OFFSET(mvnoMatchData);
#undef IA_PIN_OFFSET

/* MediaTek extension; not in ril.h. Confirmed as the immediate `mov w0, #0xbcc`
 * in mtk-ril.so's onAttachApnReset, and as requestNumber 3020 in
 * librilproxy.so's s_unsolResponses entry whose handler is resetAttachApnInd. */
#define RIL_UNSOL_RESET_ATTACH_APN 3020

/* One re-issue per second is plenty; the vendor RIL repeats the URC ~3 times a
 * second until the APN is valid again. Keep one global limit because the shim
 * owns one synthetic token, and therefore deliberately permits only one
 * request in flight across the DSDS pair. Host tests shorten this interval. */
#ifndef REISSUE_MIN_INTERVAL_NS
#define REISSUE_MIN_INTERVAL_NS (1000L * 1000L * 1000L)
#endif

/*
 * How long a re-issued request may stay in flight before the worker takes its
 * single-flight slot back. The vendor RIL completes these in milliseconds; ten
 * seconds is far outside the normal distribution and is a fault, not a slow
 * path. Recovering is strictly better than the alternative, because the slot
 * is never handed back by anything else: completeHook is the only writer that
 * clears it, so one uncompleted request used to stop every later re-send for
 * the rest of the boot -- silently, with IA_HOOKS_ACTIVE still published and
 * not one line logged.
 */
#ifndef REISSUE_INFLIGHT_TIMEOUT_NS
#define REISSUE_INFLIGHT_TIMEOUT_NS (10L * 1000L * 1000L * 1000L)
#endif

typedef void (*ril_unsol_fn)(int unsolResponse, const void *data, size_t datalen,
                             RIL_SOCKET_ID socketId);
typedef void (*ril_complete_fn)(RIL_Token t, RIL_Errno e, void *response,
                                size_t responselen);

/*
 * A hook can become reachable the instant its GOT word changes. The originals
 * are therefore C11-atomic publications: installAttachApnHooks() resolves both
 * and stores both with release ordering before changing either slot, and each
 * hook acquires its target before calling it. These pointers are intentionally
 * never cleared. If rollback cannot remove a hook, that residual hook remains
 * a safe forwarding thunk for the lifetime of the process.
 */
static _Atomic(ril_unsol_fn) sRealOnUnsol;
static _Atomic(ril_complete_fn) sRealOnComplete;

typedef enum {
    IA_HOOKS_DISABLED = 0,
    IA_HOOKS_INSTALLING,
    IA_HOOKS_ACTIVE,
    IA_HOOKS_FAILED,
} IaHookState;

/* Also owns worker single-flight publication. ACTIVE is released only after a
 * detached worker exists and both GOT slots have been verified. */
static _Atomic int sIaHookState = IA_HOOKS_DISABLED;

/*
 * The tokens the re-issued requests carry. Their VALUE is never interpreted -
 * only their identity, by completeHook. They must not be NULL and must not
 * collide with a real RequestInfo *, and the address of a file-static object
 * cannot.
 *
 * A RING, not one object, because the in-flight slot is released on a timeout
 * as well as on a completion (iaWorker below). With a single token that
 * recovery broke its own invariant: the worker released the slot at 10 s
 * WITHOUT cancelling request A, issued B under the same token, and then A's
 * late completion cleared the flag while B was still outstanding - so a third
 * request went out and two or more were live in the vendor RIL under one
 * identical token. Each token now identifies exactly one issue, so a stale
 * completion is still swallowed but no longer releases anyone else's slot.
 *
 * The ring must be long enough that it cannot wrap back onto a token that the
 * timeout has not yet given up on; the static assert below pins that.
 *
 * Each element is a whole cache line rather than an int, and that is not
 * padding for its own sake: librilproxy's RIL_onRequestComplete is known to
 * read the token at +0x1c before validating it (which is why completeHook
 * swallows ours), so any layer that indexes into a token must land inside the
 * object rather than on unrelated shim statics.
 */
#define REISSUE_TOKEN_SLOTS 16
_Static_assert((long)REISSUE_TOKEN_SLOTS * REISSUE_MIN_INTERVAL_NS >
                       REISSUE_INFLIGHT_TIMEOUT_NS,
               "the token ring can wrap onto a request the in-flight timeout "
               "has not yet released");

typedef struct {
    char opaque[64];
} ReissueToken;

static ReissueToken sReissueTokens[REISSUE_TOKEN_SLOTS] __attribute__((aligned(16)));
/* Index of the most recently issued token. Written and read under sIaLock. */
static unsigned sIaTokenSeq;

#define REISSUE_TOKEN_AT(i) ((RIL_Token)&sReissueTokens[(i) % REISSUE_TOKEN_SLOTS])

/* Identity test only - no dereference, and no assumption about ordering
 * between the array elements beyond what C guarantees for one object. */
static bool isReissueToken(RIL_Token t)
{
    unsigned i;

    for (i = 0; i < REISSUE_TOKEN_SLOTS; ++i) {
        if (t == (RIL_Token)&sReissueTokens[i]) {
            return true;
        }
    }
    return false;
}

static pthread_mutex_t sIaLock = PTHREAD_MUTEX_INITIALIZER;
/*
 * Initialised against CLOCK_MONOTONIC by initIaWake(), because the worker
 * waits on it with a deadline and this is a handset: NITZ moves CLOCK_REALTIME
 * backwards on the first network registration, which is exactly when the
 * attach-APN URC storm happens. PTHREAD_COND_INITIALIZER would give the
 * default realtime clock.
 */
static pthread_cond_t sIaWake = PTHREAD_COND_INITIALIZER;
static MtkInitialAttachApn sIaCache[SIM_COUNT];
static bool sIaCached[SIM_COUNT];
static bool sIaPending[SIM_COUNT];
static bool sIaRequestInFlight;
/*
 * The in-flight deadline is LATCHED WHEN THE REQUEST IS ISSUED, not recomputed
 * inside the wait. Recomputing it made the timeout dead in exactly the storm it
 * exists for: unsolHook signals sIaWake on EVERY URC 3020 that finds a cache,
 * the vendor RIL emits that URC roughly three times a second (740 in four
 * minutes, see the header), and each signal restarted a fresh 10 s wait. A
 * re-issued request that the vendor RIL accepted and never completed therefore
 * held the slot for the rest of the boot with nothing logged, while
 * IA_HOOKS_ACTIVE still read 1. Measured on the host harness with the timeout
 * shortened to 400 ms and the request deliberately never completed: 1 re-issue
 * at a 40/100/300 ms URC period, 5 at 600 ms -- i.e. it only worked when the
 * storm was slower than the timeout, which is never.
 * 0 means "not in flight"; only ever read while sIaRequestInFlight is true.
 */
static int64_t sIaInFlightDeadlineNs;
static bool sIaLastIssueValid;
static struct timespec sIaLastIssue;
static int sIaNextSocket;

static bool attachApnHooksActive(void)
{
    return atomic_load_explicit(&sIaHookState, memory_order_acquire) ==
            IA_HOOKS_ACTIVE;
}

/*
 * Overwrite before releasing. The APN password is the reason this whole cache
 * exists (the vendor RIL refuses to restore an APN whose cache carried one),
 * so it is present in every cached copy, and librilproxy's own
 * memsetAndFreeStrings zeroes before free for the same reason. free() alone
 * leaves the plaintext in a heap chunk any later allocation in this process
 * can read back.
 */
/*
 * Not explicit_bzero: this bionic does not declare it at all (it arrives in
 * API 30), and the host test build only compiled against it because glibc
 * does. A volatile store cannot be elided, which is the whole requirement.
 */
static void secureZero(void *buffer, size_t length)
{
    volatile unsigned char *p = (volatile unsigned char *)buffer;

    while (length-- > 0) {
        *p++ = 0;
    }
}

static void freeSecret(char **field)
{
    if (*field != NULL) {
        secureZero(*field, strlen(*field));
        free(*field);
        *field = NULL;
    }
}

static void freeIaStrings(MtkInitialAttachApn *ia)
{
    free(ia->apn);
    free(ia->protocol);
    free(ia->roamingProtocol);
    freeSecret(&ia->username);
    freeSecret(&ia->password);
    free(ia->mvnoType);
    free(ia->mvnoMatchData);
    memset(ia, 0, sizeof(*ia));
}

/* NULL in, NULL out. See the header: an empty hidl_string reaches the vendor
 * RIL as NULL for every member except `apn`, and "" is a different parcel. */
static char *dupOrNull(const char *src, bool *ok)
{
    char *copy;

    if (src == NULL) {
        return NULL;
    }
    copy = strdup(src);
    if (copy == NULL) {
        *ok = false;
    }
    return copy;
}

static bool copyIa(MtkInitialAttachApn *dst, const MtkInitialAttachApn *src)
{
    bool ok = true;

    memcpy(dst, src, sizeof(*dst));
    dst->apn = dupOrNull(src->apn, &ok);
    dst->protocol = dupOrNull(src->protocol, &ok);
    dst->roamingProtocol = dupOrNull(src->roamingProtocol, &ok);
    dst->username = dupOrNull(src->username, &ok);
    dst->password = dupOrNull(src->password, &ok);
    dst->mvnoType = dupOrNull(src->mvnoType, &ok);
    dst->mvnoMatchData = dupOrNull(src->mvnoMatchData, &ok);
    if (!ok) {
        freeIaStrings(dst);
    }
    return ok;
}

static void cacheInitialAttachApn(RIL_SOCKET_ID socketId, const void *data,
                                  size_t datalen)
{
    MtkInitialAttachApn fresh;

    if ((int)socketId < 0 || (int)socketId >= SIM_COUNT) {
        return;
    }
    /*
     * The free tripwire against a future blob. Both producers pass 88; if that
     * ever changes, the layout above is no longer the one in flight, and
     * caching it would be worse than not fixing E-092 at all.
     */
    if (data == NULL || datalen != sizeof(MtkInitialAttachApn)) {
        RLOGE("SET_INITIAL_ATTACH_APN datalen %zu != %zu; not caching, E-092 "
              "stays open", datalen, sizeof(MtkInitialAttachApn));
        return;
    }
    if (!copyIa(&fresh, (const MtkInitialAttachApn *)data)) {
        RLOGE("out of memory caching the initial-attach APN");
        return;
    }

    /* Log BEFORE publishing. Once `fresh` is in the cache another caller can
     * take the lock and freeIaStrings() it, and this would then read freed
     * memory -- a narrow window, but a real one. */
    RLOGI("cached initial-attach APN for socket %d (apn=%s, auth=%d)",
          (int)socketId, fresh.apn != NULL ? fresh.apn : "(null)",
          fresh.authtype);

    pthread_mutex_lock(&sIaLock);
    if (sIaCached[socketId]) {
        freeIaStrings(&sIaCache[socketId]);
    }
    sIaCache[socketId] = fresh;
    sIaCached[socketId] = true;
    pthread_mutex_unlock(&sIaLock);
}

static void completeHook(RIL_Token t, RIL_Errno e, void *response,
                         size_t responselen)
{
    ril_complete_fn realComplete;

    if (isReissueToken(t)) {
        bool current;

        /*
         * Ours. Swallow it: librilproxy's RIL_onRequestComplete dereferences
         * the token at +0x1c before it validates it, so this pointer must never
         * reach it. That is unconditional, and remains true even for a residual
         * hook after failed rollback.
         *
         * Releasing the single-flight slot is NOT unconditional. Only the token
         * the worker most recently issued hands the slot on; a completion that
         * arrives after the 10 s timeout already released its own slot belongs
         * to a request the worker has stopped waiting for, and letting it
         * signal would release whatever went out in its place.
         */
        pthread_mutex_lock(&sIaLock);
        current = (t == REISSUE_TOKEN_AT(sIaTokenSeq));
        if (current) {
            sIaRequestInFlight = false;
            sIaInFlightDeadlineNs = 0;
            pthread_cond_signal(&sIaWake);
        }
        pthread_mutex_unlock(&sIaLock);
        if (current) {
            RLOGI("re-issued SET_INITIAL_ATTACH_APN completed, e=%d", (int)e);
        } else {
            RLOGI("late completion of a timed-out re-issued "
                  "SET_INITIAL_ATTACH_APN, e=%d; slot not released", (int)e);
        }
        return;
    }

    realComplete = atomic_load_explicit(&sRealOnComplete,
                                        memory_order_acquire);
    if (realComplete == NULL) {
        /* Unreachable by construction: both originals are published before a
         * GOT slot can name this function. Do not turn a violated invariant
         * into a NULL indirect call. */
        RLOGE("request-complete hook reached before original publication");
        return;
    }
    realComplete(t, e, response, responselen);
}

static void unsolHook(int unsolResponse, const void *data, size_t datalen,
                      RIL_SOCKET_ID socketId)
{
    ril_unsol_fn realUnsol;

    if (attachApnHooksActive() &&
        unsolResponse == RIL_UNSOL_RESET_ATTACH_APN &&
        (int)socketId >= 0 && (int)socketId < SIM_COUNT) {
        pthread_mutex_lock(&sIaLock);
        if (sIaCached[socketId]) {
            sIaPending[socketId] = true;
            pthread_cond_signal(&sIaWake);
        } else {
            /*
             * Nothing to re-send yet. That is the EXPECTED state at every cold
             * boot -- the IA cache is non-persistent (vendor.ril.radio.ia)
             * while the password flag is persistent, so the vendor RIL writes
             * its sentinel APN before the framework has sent a real one. Say so
             * anyway: a cold-boot ordering inversion, where the URC storm
             * outlives the framework's first SET_INITIAL_ATTACH_APN, would
             * otherwise be indistinguishable from this and leave no record.
             */
            RLOGI("RIL_UNSOL_RESET_ATTACH_APN on socket %d with nothing cached "
                  "yet; not re-sending", socketId);
        }
        pthread_mutex_unlock(&sIaLock);
    }
    /*
     * Always forward, including 3020. Swallowing it would cut the log line that
     * says the vendor RIL is still asking, which is the only signal that the
     * re-issue did not take.
     */
    realUnsol = atomic_load_explicit(&sRealOnUnsol, memory_order_acquire);
    if (realUnsol == NULL) {
        RLOGE("unsolicited hook reached before original publication");
        return;
    }
    realUnsol(unsolResponse, data, datalen, socketId);
}

static int64_t timespecToNs(const struct timespec *time)
{
    return (int64_t)time->tv_sec * 1000000000LL + time->tv_nsec;
}

static void nsToTimespec(int64_t ns, struct timespec *out)
{
    out->tv_sec = (time_t)(ns / 1000000000LL);
    out->tv_nsec = (long)(ns % 1000000000LL);
}

static void sleepUntilMonotonic(int64_t deadlineNs)
{
    struct timespec deadline = {
        .tv_sec = (time_t)(deadlineNs / 1000000000LL),
        .tv_nsec = (long)(deadlineNs % 1000000000LL),
    };
    int rc;

    do {
        rc = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &deadline, NULL);
    } while (rc == EINTR);
    if (rc != 0) {
        RLOGE("attach-APN rate-limit sleep failed: %s", strerror(rc));
    }
}

static void *iaWorker(void *unused)
{
    (void)unused;

    for (;;) {
        MtkInitialAttachApn outgoing;
        RIL_Token token;
        int socketId = -1;
        int offset;
        int64_t waitUntilNs = 0;
        bool relativeSleep = false;

        pthread_mutex_lock(&sIaLock);
        for (;;) {
            if (!sIaRequestInFlight) {
                for (offset = 0; offset < SIM_COUNT; offset++) {
                    int i = (sIaNextSocket + offset) % SIM_COUNT;

                    if (sIaPending[i] && sIaCached[i]) {
                        socketId = i;
                        break;
                    }
                }
            }
            if (socketId >= 0) {
                struct timespec now;

                if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
                    RLOGE("clock_gettime(CLOCK_MONOTONIC) failed: %s",
                          strerror(errno));
                    /* A failed clock must not turn the recovery path into a
                     * busy loop. Fall back to one full interval. */
                    relativeSleep = true;
                } else if (sIaLastIssueValid) {
                    int64_t earliest = timespecToNs(&sIaLastIssue) +
                            REISSUE_MIN_INTERVAL_NS;
                    int64_t nowNs = timespecToNs(&now);

                    if (earliest > nowNs) {
                        waitUntilNs = earliest;
                    }
                }
                break;
            }
            if (sIaRequestInFlight) {
                /*
                 * Bounded, because nothing else can free the slot. An
                 * unbounded wait here is indistinguishable from a healthy idle
                 * worker and was the one path in this file that could fail
                 * without logging.
                 *
                 * The deadline comes from sIaInFlightDeadlineNs, latched when
                 * the request was issued. Do NOT recompute it here -- see the
                 * comment on that variable for the measurement that shows why.
                 * The expiry test is on the CLOCK, not on cond_timedwait's
                 * return value, because the URC storm delivers a real signal
                 * every ~333 ms and each one returns 0 rather than ETIMEDOUT.
                 */
                struct timespec deadline;
                struct timespec afterWait;

                if (sIaInFlightDeadlineNs == 0) {
                    RLOGE("in-flight slot held with no deadline; releasing it");
                    sIaRequestInFlight = false;
                    continue;
                }
                nsToTimespec(sIaInFlightDeadlineNs, &deadline);
                (void)pthread_cond_timedwait(&sIaWake, &sIaLock, &deadline);
                if (!sIaRequestInFlight) {
                    continue;
                }
                if (clock_gettime(CLOCK_MONOTONIC, &afterWait) != 0) {
                    RLOGE("clock_gettime(CLOCK_MONOTONIC) failed: %s; "
                          "releasing the in-flight slot", strerror(errno));
                    sIaRequestInFlight = false;
                    sIaInFlightDeadlineNs = 0;
                    continue;
                }
                if (timespecToNs(&afterWait) >= sIaInFlightDeadlineNs) {
                    RLOGE("re-issued SET_INITIAL_ATTACH_APN never completed "
                          "within %ld ms; releasing the in-flight slot",
                          (long)(REISSUE_INFLIGHT_TIMEOUT_NS / 1000000L));
                    sIaRequestInFlight = false;
                    sIaInFlightDeadlineNs = 0;
                }
                continue;
            }
            pthread_cond_wait(&sIaWake, &sIaLock);
        }

        if (relativeSleep || waitUntilNs != 0) {
            pthread_mutex_unlock(&sIaLock);
            if (relativeSleep) {
                struct timespec pause = {
                    .tv_sec = REISSUE_MIN_INTERVAL_NS / 1000000000L,
                    .tv_nsec = REISSUE_MIN_INTERVAL_NS % 1000000000L,
                };
                while (nanosleep(&pause, &pause) != 0 && errno == EINTR) {}
            } else {
                sleepUntilMonotonic(waitUntilNs);
            }
            continue;
        }

        if (!copyIa(&outgoing, &sIaCache[socketId])) {
            /*
             * Charge the failed attempt to the rate limiter before releasing
             * the lock. Without this, sIaPending[socketId] is still set and
             * sIaLastIssue is unchanged, so the next iteration recomputes
             * waitUntilNs == 0 and retries immediately -- measured at 49.4 M
             * iterations and a full core in one second, each one emitting an
             * RLOGE, under exactly the memory pressure that caused it.
             */
            if (clock_gettime(CLOCK_MONOTONIC, &sIaLastIssue) == 0) {
                sIaLastIssueValid = true;
            } else {
                sIaLastIssueValid = false;
            }
            pthread_mutex_unlock(&sIaLock);
            RLOGE("out of memory re-issuing the initial-attach APN; "
                  "retrying after the rate-limit interval");
            continue;
        }
        sIaPending[socketId] = false;
        sIaRequestInFlight = true;
        sIaTokenSeq++;
        {
            struct timespec issuedAt;

            if (clock_gettime(CLOCK_MONOTONIC, &issuedAt) == 0) {
                sIaInFlightDeadlineNs = timespecToNs(&issuedAt) +
                        REISSUE_INFLIGHT_TIMEOUT_NS;
            } else {
                /*
                 * No usable clock: leave the deadline unset and let the wait
                 * branch release the slot on its next pass rather than hold it
                 * forever.
                 */
                sIaInFlightDeadlineNs = 0;
            }
        }
        token = REISSUE_TOKEN_AT(sIaTokenSeq);
        sIaNextSocket = (socketId + 1) % SIM_COUNT;
        if (clock_gettime(CLOCK_MONOTONIC, &sIaLastIssue) == 0) {
            sIaLastIssueValid = true;
        } else {
            sIaLastIssueValid = false;
        }
        pthread_mutex_unlock(&sIaLock);

        RLOGI("RIL_UNSOL_RESET_ATTACH_APN on socket %d -> re-sending "
              "SET_INITIAL_ATTACH_APN (apn=%s)", socketId,
              outgoing.apn != NULL ? outgoing.apn : "(null)");

        /*
         * The blob's own onRequest, not onRequestShim: nothing in PART 1 has
         * anything to say about this request, and going through the shim would
         * only add a branch that can never be taken.
         *
         * It is synchronous as far as the payload is concerned -- mtk-rilproxy
         * encodes the strings into a socket parcel before returning, which is
         * why librilproxy frees them on the very next instruction. Freeing here
         * follows the same contract.
         */
        sRealOnRequest(RIL_REQUEST_SET_INITIAL_ATTACH_APN, &outgoing,
                       sizeof(outgoing), token,
                       (RIL_SOCKET_ID)socketId);
        freeIaStrings(&outgoing);
    }
    return NULL;
}

/*
 * Everything needed to rewrite one PLT GOT slot of a loaded library, gathered
 * by dl_iterate_phdr. Nothing here is hardcoded: the slot addresses move with
 * any change to the blob, and a wrong constant would corrupt an unrelated
 * pointer.
 */
typedef struct {
    const char *soname;                 /* in:  basename to match */
    ElfW(Addr) base;                    /* out: load bias */
    const ElfW(Phdr) *phdr;             /* out: for the range check below */
    ElfW(Half) phnum;
    const ElfW(Rela) *jmprel;
    size_t jmprelCount;
    const ElfW(Sym) *symtab;
    const char *strtab;
    bool found;
} GotScan;

/*
 * Is [addr, addr+len) inside one of this module's PT_LOAD segments?
 *
 * This exists because the next function has one genuinely dangerous decision to
 * make. DT_SYMTAB, DT_STRTAB and DT_JMPREL hold LINK-TIME virtual addresses;
 * the runtime address is load_bias + d_ptr, and bionic's own reader does
 * exactly that (`symtab_ = reinterpret_cast<ElfW(Sym)*>(load_bias +
 * d->d_un.d_ptr)` in soinfo::prelink_image). It does NOT rewrite the dynamic
 * section, so the raw value is never the answer here.
 *
 * Getting that backwards would not fail loudly: it would produce a plausible
 * pointer into some other mapping, and the code below would strcmp() against it
 * and then WRITE to whatever it decided was a GOT slot, inside rild. So every
 * derived pointer is range-checked against the module's own segments before it
 * is dereferenced, and the biased and raw forms are both tried rather than
 * assumed.
 */
static bool inModule(const GotScan *scan, ElfW(Addr) addr, size_t len)
{
    ElfW(Half) i;

    for (i = 0; i < scan->phnum; i++) {
        const ElfW(Phdr) *ph = &scan->phdr[i];
        ElfW(Addr) start, end;

        if (ph->p_type != PT_LOAD) {
            continue;
        }
        if (ph->p_vaddr > UINTPTR_MAX - scan->base) {
            continue;
        }
        start = scan->base + ph->p_vaddr;
        if (ph->p_memsz > UINTPTR_MAX - start) {
            continue;
        }
        end = start + ph->p_memsz;
        if (addr >= start && addr <= end && len <= (size_t)(end - addr)) {
            return true;
        }
    }
    return false;
}

/* Resolve one DT_* pointer entry to a runtime address, or 0. */
static ElfW(Addr) resolveDynPtr(const GotScan *scan, ElfW(Addr) value, size_t len)
{
    if (value <= UINTPTR_MAX - scan->base &&
        inModule(scan, scan->base + value, len)) {
        return scan->base + value;
    }
    if (inModule(scan, value, len)) {
        return value;
    }
    return 0;
}

static int gotScanCallback(struct dl_phdr_info *info, size_t size, void *arg)
{
    GotScan *scan = (GotScan *)arg;
    const ElfW(Dyn) *dyn = NULL;
    ElfW(Addr) jmprel = 0, symtab = 0, strtab = 0;
    size_t pltrelsz = 0;
    const char *name;
    size_t i;

    (void)size;
    if (info->dlpi_name == NULL) {
        return 0;
    }
    name = strrchr(info->dlpi_name, '/');
    name = name != NULL ? name + 1 : info->dlpi_name;
    if (strcmp(name, scan->soname) != 0) {
        return 0;
    }

    scan->base = info->dlpi_addr;
    scan->phdr = info->dlpi_phdr;
    scan->phnum = info->dlpi_phnum;

    for (i = 0; i < info->dlpi_phnum; i++) {
        if (info->dlpi_phdr[i].p_type == PT_DYNAMIC) {
            dyn = (const ElfW(Dyn) *)(info->dlpi_addr +
                                      info->dlpi_phdr[i].p_vaddr);
            break;
        }
    }
    if (dyn == NULL) {
        RLOGE("%s has no PT_DYNAMIC", scan->soname);
        return 1;
    }

    for (; dyn->d_tag != DT_NULL; dyn++) {
        switch (dyn->d_tag) {
        case DT_JMPREL:
            jmprel = (ElfW(Addr))dyn->d_un.d_ptr;
            break;
        case DT_PLTRELSZ:
            pltrelsz = (size_t)dyn->d_un.d_val;
            break;
        case DT_SYMTAB:
            symtab = (ElfW(Addr))dyn->d_un.d_ptr;
            break;
        case DT_STRTAB:
            strtab = (ElfW(Addr))dyn->d_un.d_ptr;
            break;
        case DT_PLTREL:
            /* RELA only. A REL-based PLT would mean the entry layout below is
             * wrong, and reading it as RELA would walk off the section. */
            if (dyn->d_un.d_val != DT_RELA) {
                RLOGE("%s PLT is not RELA", scan->soname);
                return 1;
            }
            break;
        default:
            break;
        }
    }

    if (pltrelsz == 0 || pltrelsz % sizeof(ElfW(Rela)) != 0) {
        RLOGE("%s DT_PLTRELSZ %zu is not a whole number of RELA entries",
              scan->soname, pltrelsz);
        return 1;
    }
    scan->jmprel = (const ElfW(Rela) *)resolveDynPtr(scan, jmprel, pltrelsz);
    /* One ElfW(Sym) is the least that has to be readable; the table's extent is
     * not in the dynamic section, and each entry is checked as it is used. */
    scan->symtab = (const ElfW(Sym) *)resolveDynPtr(scan, symtab,
                                                    sizeof(ElfW(Sym)));
    scan->strtab = (const char *)resolveDynPtr(scan, strtab, 1);
    scan->jmprelCount = pltrelsz / sizeof(ElfW(Rela));
    scan->found = (scan->jmprel != NULL && scan->symtab != NULL &&
                   scan->strtab != NULL);
    if (!scan->found) {
        RLOGE("%s dynamic pointers do not resolve inside its own segments "
              "(jmprel=%p symtab=%p strtab=%p)", scan->soname,
              (const void *)scan->jmprel, (const void *)scan->symtab,
              (const void *)scan->strtab);
    }
    return 1;
}

#if defined(__aarch64__)
#define K50SV1_JUMP_SLOT R_AARCH64_JUMP_SLOT
#elif defined(__x86_64__)
/* Host regression tests patch a real x86-64 relocatable shared object. */
#define K50SV1_JUMP_SLOT R_X86_64_JUMP_SLOT
#else
#error "unsupported architecture for the RIL GOT hook"
#endif

typedef enum {
    GOT_WRITE_INSTALL_UNSOL = 0,
    GOT_WRITE_INSTALL_COMPLETE,
    GOT_WRITE_ROLLBACK_COMPLETE,
    GOT_WRITE_ROLLBACK_UNSOL,
    GOT_WRITE_STEP_COUNT,
} GotWriteStep;

typedef struct {
    const char *symbol;
    void **slot;
    void *original;
    void *replacement;
    uintptr_t page;
    size_t pageSize;
    int protection;
} GotEntry;

#ifdef K50SV1_RIL_SHIM_HOST_TEST
/* Deterministic transition faults and an after-publication callback seam. The
 * production object contains none of this state. */
typedef struct {
    unsigned failMakeWritableMask;
    unsigned failBeforeWriteMask;
    unsigned failAfterWriteMask;
    unsigned failRestoreMask;
    unsigned afterWriteDelayUs;
    bool failWorkerCreate;
    const char *failResolveSymbol;
    void (*afterWrite)(GotWriteStep step);
} GotTestControl;

static GotTestControl sGotTestControl;
#endif

static void *loadGotValue(const GotEntry *entry)
{
    return __atomic_load_n(entry->slot, __ATOMIC_ACQUIRE);
}

/* Resolve without writing. This is load-bearing: both entries and both
 * originals must be known before either hook is made reachable. */
static bool findGotEntry(const GotScan *scan, const char *symbol,
                         void *replacement, GotEntry *out)
{
    size_t symbolLen = strlen(symbol) + 1;
    size_t i;
    bool found = false;

    memset(out, 0, sizeof(*out));
#ifdef K50SV1_RIL_SHIM_HOST_TEST
    if (sGotTestControl.failResolveSymbol != NULL &&
        strcmp(sGotTestControl.failResolveSymbol, symbol) == 0) {
        return false;
    }
#endif
    for (i = 0; i < scan->jmprelCount; i++) {
        const ElfW(Rela) *rela = &scan->jmprel[i];
        uint32_t symIndex = (uint32_t)ELF64_R_SYM(rela->r_info);
        const char *name;
        ElfW(Addr) slotAddr;
        long pageSize;

        if (ELF64_R_TYPE(rela->r_info) != K50SV1_JUMP_SLOT) {
            continue;
        }
        if (!inModule(scan, (ElfW(Addr))&scan->symtab[symIndex],
                      sizeof(ElfW(Sym)))) {
            continue;
        }
        if (scan->symtab[symIndex].st_name >
            UINTPTR_MAX - (uintptr_t)scan->strtab) {
            continue;
        }
        name = scan->strtab + scan->symtab[symIndex].st_name;
        if (!inModule(scan, (ElfW(Addr))name, symbolLen) ||
            memcmp(name, symbol, symbolLen) != 0) {
            continue;
        }
        if (rela->r_offset > UINTPTR_MAX - scan->base) {
            RLOGE("GOT slot address for %s overflows", symbol);
            return false;
        }
        slotAddr = scan->base + rela->r_offset;
        if (!inModule(scan, slotAddr, sizeof(void *))) {
            RLOGE("GOT slot for %s is outside %s", symbol, scan->soname);
            return false;
        }
        pageSize = sysconf(_SC_PAGESIZE);
        if (pageSize <= 0) {
            RLOGE("could not read page size for GOT slot %s", symbol);
            return false;
        }

        out->symbol = symbol;
        out->slot = (void **)slotAddr;
        out->replacement = replacement;
        out->pageSize = (size_t)pageSize;
        out->page = (uintptr_t)out->slot % out->pageSize;
        out->page = (uintptr_t)out->slot - out->page;
        out->protection = mappingProt((uintptr_t)out->slot);
        if (out->protection < 0) {
            RLOGE("GOT slot for %s at %p is in no mapping", symbol,
                  (void *)out->slot);
            return false;
        }
        out->original = loadGotValue(out);
        if (out->original == NULL || out->original == replacement) {
            RLOGE("GOT slot for %s has unsafe original %p", symbol,
                  out->original);
            return false;
        }
        /*
         * Keep scanning. Returning on the first match would leave a second
         * slot for the same symbol unhooked, and the resulting behaviour --
         * some calls intercepted and some not -- is worse than not hooking at
         * all and would show up only as an intermittent missing re-send.
         * One slot per symbol is what this blob has; anything else is a
         * different binary and must stop the install.
         */
        if (found) {
            RLOGE("%s has more than one PLT GOT entry for %s; refusing to hook",
                  scan->soname, symbol);
            return false;
        }
        found = true;
    }
    if (found) {
        return true;
    }
    RLOGE("%s has no PLT GOT entry for %s", scan->soname, symbol);
    return false;
}

static bool verifyGotValue(const GotEntry *entry, void *expected)
{
    void *actual = loadGotValue(entry);
    int actualProt = mappingProt((uintptr_t)entry->slot);

    if (actual != expected) {
        RLOGE("GOT verification for %s failed: found %p, expected %p",
              entry->symbol, actual, expected);
        return false;
    }
    if (actualProt != entry->protection) {
        RLOGE("GOT protection verification for %s failed: found %#x, "
              "expected %#x", entry->symbol, actualProt, entry->protection);
        return false;
    }
    return true;
}

/* Compare-and-publish one GOT word, then prove both its value and its original
 * page protection. GNU atomics are used on the loader-owned word because it is
 * not declared as a C _Atomic object. */
static bool writeGotValue(const GotEntry *entry, void *expected, void *desired,
                          GotWriteStep step)
{
    void *observed = expected;
    bool writable = (entry->protection & PROT_WRITE) != 0;
    bool success = true;
    bool skipRestore = false;

    (void)step;
#ifdef K50SV1_RIL_SHIM_HOST_TEST
    skipRestore = (sGotTestControl.failRestoreMask & (1U << step)) != 0;
    if ((sGotTestControl.failMakeWritableMask & (1U << step)) != 0) {
        return false;
    }
#endif

    if (!writable &&
        mprotect((void *)entry->page, entry->pageSize,
                 entry->protection | PROT_WRITE) != 0) {
        RLOGE("mprotect(%p, +w) for %s failed: %s", (void *)entry->page,
              entry->symbol, strerror(errno));
        return false;
    }

#ifdef K50SV1_RIL_SHIM_HOST_TEST
    if ((sGotTestControl.failBeforeWriteMask & (1U << step)) != 0) {
        success = false;
    } else
#endif
    if (!__atomic_compare_exchange_n(entry->slot, &observed, desired, false,
                                     __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
        RLOGE("GOT slot for %s changed concurrently: found %p, expected %p",
              entry->symbol, observed, expected);
        success = false;
    }

#ifdef K50SV1_RIL_SHIM_HOST_TEST
    if (success && sGotTestControl.afterWrite != NULL) {
        sGotTestControl.afterWrite(step);
    }
    if (success && sGotTestControl.afterWriteDelayUs != 0) {
        usleep(sGotTestControl.afterWriteDelayUs);
    }
    if ((sGotTestControl.failAfterWriteMask & (1U << step)) != 0) {
        success = false;
    }
#endif

    if (success && __atomic_load_n(entry->slot, __ATOMIC_ACQUIRE) != desired) {
        RLOGE("GOT slot for %s did not retain its published value",
              entry->symbol);
        success = false;
    }

    if (!writable && !skipRestore &&
        mprotect((void *)entry->page, entry->pageSize,
                 entry->protection) != 0) {
        RLOGE("mprotect(%p, restore) for %s failed: %s", (void *)entry->page,
              entry->symbol, strerror(errno));
        success = false;
    }
#ifdef K50SV1_RIL_SHIM_HOST_TEST
    if (skipRestore) {
        success = false;
    }
#endif
    return success && verifyGotValue(entry, desired);
}

/* Roll back in reverse publication order and then independently re-read both
 * slots. A failed write is not trusted; only this final verification decides
 * whether the transaction returned to its original state. */
static bool rollbackGotHooks(const GotEntry *unsol, const GotEntry *complete)
{
    bool completeRestored;
    bool unsolRestored;

    if (loadGotValue(complete) == complete->replacement) {
        (void)writeGotValue(complete, complete->replacement,
                            complete->original, GOT_WRITE_ROLLBACK_COMPLETE);
    }
    if (loadGotValue(unsol) == unsol->replacement) {
        (void)writeGotValue(unsol, unsol->replacement, unsol->original,
                            GOT_WRITE_ROLLBACK_UNSOL);
    }
    /* Do not short-circuit: rollback verification must cover both slots even
     * when the first one is already known to be wrong. */
    completeRestored = verifyGotValue(complete, complete->original);
    unsolRestored = verifyGotValue(unsol, unsol->original);
    return completeRestored && unsolRestored;
}

/*
 * Re-initialise sIaWake against CLOCK_MONOTONIC. Called from startIaWorker
 * before pthread_create, which is the only point at which anything can wait on
 * or signal it: unsolHook and completeHook both become reachable only after
 * this function's caller publishes IA_HOOKS_ACTIVE.
 */
/*
 * Returns 0 only when sIaWake is genuinely on CLOCK_MONOTONIC. It must FAIL
 * rather than fall back, because a silent fall-back is worse than no worker:
 * the condvar would keep PTHREAD_COND_INITIALIZER's realtime clock while
 * iaWorker builds every deadline from CLOCK_MONOTONIC, so a monotonic value
 * compared against realtime is always in the past, pthread_cond_timedwait
 * returns ETIMEDOUT immediately, and the in-flight recovery path becomes a hot
 * loop emitting one RLOGE per iteration inside the RIL process. That is the
 * same shape as the copyIa() failure this file already had to fix once.
 */
static int initIaWake(void)
{
    pthread_condattr_t attr;
    int rc;

    rc = pthread_condattr_init(&attr);
    if (rc != 0) {
        RLOGE("pthread_condattr_init failed: %s", strerror(rc));
        return rc;
    }
    rc = pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
    if (rc == 0) {
        rc = pthread_cond_init(&sIaWake, &attr);
        if (rc != 0) {
            RLOGE("pthread_cond_init(CLOCK_MONOTONIC) failed: %s",
                  strerror(rc));
        }
    } else {
        RLOGE("pthread_condattr_setclock(CLOCK_MONOTONIC) failed: %s",
              strerror(rc));
    }
    (void)pthread_condattr_destroy(&attr);
    return rc;
}

static int startIaWorker(void)
{
    pthread_attr_t attr;
    pthread_t worker;
    int rc;

    rc = initIaWake();
    if (rc != 0) {
        return rc;
    }

#ifdef K50SV1_RIL_SHIM_HOST_TEST
    if (sGotTestControl.failWorkerCreate) {
        return EAGAIN;
    }
#endif
    rc = pthread_attr_init(&attr);
    if (rc != 0) {
        return rc;
    }
    rc = pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    if (rc == 0) {
        rc = pthread_create(&worker, &attr, iaWorker, NULL);
    }
    (void)pthread_attr_destroy(&attr);
    return rc;
}

/* Install two hooks as one logical transaction. During the small physical
 * interval between the two atomic GOT stores, INSTALLING makes the first hook
 * a pure forwarding thunk. ACTIVE is published only after both stores, both
 * protections, and the worker have been verified. */
static int installAttachApnHooks(void)
{
    GotScan scan = { .soname = REAL_RIL_SONAME };
    GotEntry unsol;
    GotEntry complete;
    int expectedState = IA_HOOKS_DISABLED;
    int rc;

    if (!atomic_compare_exchange_strong_explicit(
                &sIaHookState, &expectedState, IA_HOOKS_INSTALLING,
                memory_order_acq_rel, memory_order_acquire)) {
        return expectedState == IA_HOOKS_ACTIVE ? 0 : -1;
    }

    dl_iterate_phdr(gotScanCallback, &scan);
    if (!scan.found ||
        !findGotEntry(&scan, "RIL_onUnsolicitedResponse", (void *)unsolHook,
                      &unsol) ||
        !findGotEntry(&scan, "RIL_onRequestComplete", (void *)completeHook,
                      &complete) ||
        unsol.slot == complete.slot) {
        RLOGE("could not resolve both %s callback GOT entries",
              REAL_RIL_SONAME);
        atomic_store_explicit(&sIaHookState, IA_HOOKS_DISABLED,
                              memory_order_release);
        return -1;
    }

    /* Publish BOTH originals before making EITHER hook reachable. */
    atomic_store_explicit(&sRealOnUnsol, (ril_unsol_fn)unsol.original,
                          memory_order_release);
    atomic_store_explicit(&sRealOnComplete,
                          (ril_complete_fn)complete.original,
                          memory_order_release);

    if (!writeGotValue(&unsol, unsol.original, unsol.replacement,
                       GOT_WRITE_INSTALL_UNSOL) ||
        !writeGotValue(&complete, complete.original, complete.replacement,
                       GOT_WRITE_INSTALL_COMPLETE) ||
        !verifyGotValue(&unsol, unsol.replacement) ||
        !verifyGotValue(&complete, complete.replacement)) {
        bool rolledBack = rollbackGotHooks(&unsol, &complete);

        atomic_store_explicit(&sIaHookState,
                              rolledBack ? IA_HOOKS_DISABLED : IA_HOOKS_FAILED,
                              memory_order_release);
        RLOGE("attach-APN hook installation failed; rollback %s",
              rolledBack ? "verified" : "FAILED (residual hooks only forward)");
        return -1;
    }

    rc = startIaWorker();
    if (rc != 0) {
        bool rolledBack = rollbackGotHooks(&unsol, &complete);

        atomic_store_explicit(&sIaHookState,
                              rolledBack ? IA_HOOKS_DISABLED : IA_HOOKS_FAILED,
                              memory_order_release);
        RLOGE("pthread_create for the attach-APN worker failed: %s; "
              "rollback %s", strerror(rc),
              rolledBack ? "verified" : "FAILED (residual hooks only forward)");
        return -1;
    }

    atomic_store_explicit(&sIaHookState, IA_HOOKS_ACTIVE,
                          memory_order_release);
    return 0;
}

static void onRequestShim(int request, void *data, size_t datalen, RIL_Token t,
                          RIL_SOCKET_ID socketId)
{
    if (request == RIL_REQUEST_GET_RADIO_CAPABILITY) {
        getRadioCapability(t, socketId);
        return;
    }

    if (request == RIL_REQUEST_SET_RADIO_CAPABILITY) {
        setRadioCapability(data, datalen, t, socketId);
        return;
    }

    /*
     * Copy BEFORE forwarding. librilproxy frees every heap string in this
     * payload on the instruction after onRequest returns, so a copy taken
     * afterwards would be of freed, memset-to-zero memory. Only when the hooks
     * are live: without them there is nobody to re-issue it and the cache would
     * be a pure leak of the APN password into this process's heap.
     */
    if (request == RIL_REQUEST_SET_INITIAL_ATTACH_APN &&
        attachApnHooksActive()) {
        cacheInitialAttachApn(socketId, data, datalen);
    }

    sRealOnRequest(request, data, datalen, t, socketId);
}

/*
 * The two _Static_asserts this file already carries pin RIL_RadioCapability and
 * MtkInitialAttachApn. This one pins the field patchOnRequest WRITES INTO. The
 * read-back after the store proves the store landed, not that offset 8 is
 * onRequest -- a header change that reordered the struct would pass it while
 * corrupting a different member. Trap 21 is the same lesson from the other
 * side: MediaTek's RIL_RadioFunctions is LONGER than AOSP's, so its tail cannot
 * be assumed, but the first three members are ABI between the blob and
 * librilproxy and are what this file relies on.
 */
_Static_assert(offsetof(RIL_RadioFunctions, version) == 0,
               "RIL_RadioFunctions.version moved");
_Static_assert(offsetof(RIL_RadioFunctions, onRequest) == 8,
               "RIL_RadioFunctions.onRequest moved; patchOnRequest writes it");

static int patchOnRequest(const RIL_RadioFunctions *funcs)
{
    uintptr_t field = (uintptr_t)&funcs->onRequest;
    long pageSize = sysconf(_SC_PAGESIZE);
    uintptr_t page;
    size_t span;
    int oldProt;
    bool patched;

    if (pageSize <= 0) {
        return -1;
    }
    /*
     * Check the table BEFORE writing to it. The version tripwire used to be
     * consulted only after the patch had already landed, which is the wrong
     * order for a tripwire. RIL_VERSION has been 6..15 across every AOSP
     * release this blob could target; anything outside that is not a
     * RIL_RadioFunctions and must not be written into.
     */
    if (funcs->version < 6 || funcs->version > 20) {
        RLOGE("vendor RIL_RadioFunctions.version is %d; refusing to patch",
              funcs->version);
        return -1;
    }
    if (funcs->onRequest == NULL) {
        RLOGE("vendor RIL_RadioFunctions.onRequest is NULL; refusing to patch");
        return -1;
    }
    page = field & ~(uintptr_t)(pageSize - 1);
    /* The field is one pointer wide and 8-byte aligned, so it can never
     * straddle a page, but size the range from the field anyway. */
    span = (size_t)(field + sizeof(RIL_RequestFunc) - page);

    oldProt = mappingProt(field);
    if (oldProt < 0) {
        RLOGE("onRequest at %p is in no mapping", (void *)field);
        return -1;
    }
    if ((oldProt & PROT_WRITE) == 0 &&
        mprotect((void *)page, span, oldProt | PROT_WRITE) != 0) {
        RLOGE("mprotect(%p, +w) failed", (void *)page);
        return -1;
    }

    /*
     * Publish sRealOnRequest BEFORE the table store, with release ordering.
     * Two plain stores to different objects can be reordered, and a blob thread
     * that dispatches through the table in the window between them would enter
     * onRequestShim and call a NULL sRealOnRequest. The pairing acquire load is
     * the read-back below.
     */
    __atomic_store_n(&sRealOnRequest, funcs->onRequest, __ATOMIC_RELEASE);
    ((RIL_RadioFunctions *)funcs)->onRequest = onRequestShim;
    /* Read back, the way writeGotValue:1331 does for the two GOT slots. A write
     * into a page whose mapping is not what mappingProt reported would
     * otherwise be reported as success and leave sRealOnRequest published
     * against a table that still holds the blob's own pointer.
     *
     * It has to be an atomic load, not `funcs->onRequest == onRequestShim`.
     * That plain form was here and it verified nothing: the store and the load
     * are the same object of the same type, so at -O2 - which is what Soong
     * builds this at - clang forwards the stored value and folds the comparison
     * to a constant true. Confirmed by compiling the pattern both ways: -O0
     * emits a real compare, -O2 emits `movb $1`. */
    patched = (__atomic_load_n((RIL_RequestFunc *)&funcs->onRequest,
                               __ATOMIC_ACQUIRE) == onRequestShim);

    if ((oldProt & PROT_WRITE) == 0 &&
        mprotect((void *)page, span, oldProt) != 0) {
        /* Retry once: a permanently writable .data.rel.ro page in the RIL
         * process is worth one more syscall to avoid. */
        if (mprotect((void *)page, span, oldProt) != 0) {
            RLOGE("mprotect(%p, restore) failed twice; the RIL function table "
                  "page stays writable", (void *)page);
        }
    }
    if (!patched) {
        RLOGE("onRequest patch did not take at %p", (void *)field);
        return -1;
    }
    return 0;
}

static void *openRealRil(void)
{
    if (sRealHandle == NULL) {
        sRealHandle = dlopen(REAL_RIL_SONAME, RTLD_LOCAL | RTLD_NOW);
        if (sRealHandle == NULL) {
            RLOGE("dlopen(%s) failed: %s", REAL_RIL_SONAME, dlerror());
        }
    }
    return sRealHandle;
}

/* Set only on the fully successful path, so a failed init can never be
 * mistaken for a completed one. */
static bool sOnRequestPatched;

const RIL_RadioFunctions *RIL_Init(const struct RIL_Env *env, int argc,
                                   char **argv)
{
    ril_init_fn realInit;
    void *handle;

    if (sOnRequestPatched) {
        /*
         * A second call would re-enter the blob's RIL_Init and then read
         * sRealFuncs->onRequest -- which is already onRequestShim, so
         * sRealOnRequest would become the shim itself and every dispatched
         * request would tail-call forever: no crash, no log, and a telephony
         * stack that goes silent while the RIL below it is visibly healthy.
         * rilproxy calls this once; the guard costs a branch and removes the
         * question.
         */
        RLOGE("RIL_Init called more than once; returning the patched table");
        return sRealFuncs;
    }

    handle = openRealRil();
    if (handle == NULL) {
        return NULL;
    }

    realInit = (ril_init_fn)dlsym(handle, "RIL_Init");
    if (realInit == NULL) {
        RLOGE("dlsym(RIL_Init) failed: %s", dlerror());
        return NULL;
    }

    sEnv = env;
    sRealFuncs = realInit(env, argc, argv);
    if (sRealFuncs == NULL) {
        RLOGE("%s RIL_Init returned NULL", REAL_RIL_SONAME);
        return NULL;
    }

    /*
     * Patch the blob's own table in place and hand back its own pointer.
     *
     * Do NOT return a private copy. MediaTek's RIL_RadioFunctions is LONGER
     * than the one in hardware/ril/include/telephony/ril.h: librilproxy's
     * onNewCommandConnect calls a function pointer at offset 0x30, which is one
     * slot past the end of the six-member AOSP struct. A 48-byte copy therefore
     * leaves that slot reading whatever static happens to follow it, and this
     * shim's first version crashed rilproxy exactly there:
     *
     *   #00 pc 000babe3b84cdbb9  <unknown>
     *   #01 pc 0000000000065e54  librilproxy.so (onNewCommandConnect+524)
     *   #02 pc 000000000006b7bc  librilproxy.so (RadioImpl::setResponseFunctions+2044)
     *
     * Patching in place needs no knowledge of the real size and cannot
     * truncate. The table may live in .rodata or in post-RELRO .data.rel.ro,
     * so make the page writable first and put the original protection back.
     */
    if (patchOnRequest(sRealFuncs) != 0) {
        /*
         * Fail closed. Returning the real table would silently put the broken,
         * destructive MediaTek capability switch back behind a Settings tap.
         *
         * What "closed" costs, traced rather than assumed, because the old
         * wording ("a half-initialised telephony stack") understated it:
         * /vendor/bin/hw/rilproxy does NOT null-check this return -- it does
         * `blr x24` then `mov x0, x19; bl RIL_register` -- and
         * librilproxy!RIL_register takes `cbz x19` straight to its epilogue
         * after one priority-6 log line. So the handset BOOTS, does not crash
         * and does not crash-loop; it comes up with binder alive, no IRadio
         * service registered, and telephony dead until reboot, with one E line
         * in the radio buffer naming the cause. RIL_SAP_Init still forwards, so
         * BT-SAP survives. If this ever fires, that log line is the only
         * symptom you will get.
         */
        RLOGE("could not patch onRequest; refusing to expose the unsafe MTK "
              "radio-capability path. NO IRadio WILL BE REGISTERED THIS BOOT");
        return NULL;
    }
    sOnRequestPatched = true;

    /*
     * The payload layout this shim caches is only the one in flight while the
     * blob reports version 15: librilproxy picks the 5-field 0x28 struct
     * instead at version <= 14 (`cmp w8, #0xe` in setInitialAttachApn). The
     * datalen check in cacheInitialAttachApn would catch that anyway; saying so
     * here costs one line and names the reason.
     */
    if (sRealFuncs->version < 15) {
        RLOGE("RIL version %d < 15: not installing the attach-APN hooks, "
              "E-092 stays open", sRealFuncs->version);
    } else if (installAttachApnHooks() != 0) {
        RLOGE("attach-APN hooks NOT installed; an airplane-mode cycle will "
              "still cost slot 0 its LTE attach until reboot (E-092)");
    } else {
        RLOGI("attach-APN re-send armed (URC %d)", RIL_UNSOL_RESET_ATTACH_APN);
    }

    RLOGI("wrapping %s, RIL version %d", REAL_RIL_SONAME, sRealFuncs->version);
    return sRealFuncs;
}

/*
 * rilproxy dlsyms this for the BT SIM Access Profile socket. Forward it
 * untouched; there is nothing on that path worth intercepting, and returning
 * NULL here would silently drop SAP.
 */
const RIL_RadioFunctions *RIL_SAP_Init(const struct RIL_Env *env, int argc,
                                       char **argv)
{
    ril_init_fn realSapInit;
    void *handle = openRealRil();

    if (handle == NULL) {
        return NULL;
    }

    realSapInit = (ril_init_fn)dlsym(handle, "RIL_SAP_Init");
    if (realSapInit == NULL) {
        RLOGE("dlsym(RIL_SAP_Init) failed: %s", dlerror());
        return NULL;
    }

    return realSapInit(env, argc, argv);
}
