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
 * IF ANYTHING HERE FAILS it logs and disables itself. Telephony then behaves
 * exactly as it did before this part existed - E-092 is back, nothing else
 * changes. The mechanism only becomes active after both hooks and the worker
 * are verified. If a failed rollback physically leaves a hook in one GOT slot,
 * it remains a safe forwarding thunk; its published original is never cleared.
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
 * The token the re-issued request carries. Its VALUE is never interpreted -
 * only its identity, by completeHook. It must not be NULL and must not collide
 * with a real RequestInfo *, and the address of a file-static object cannot.
 */
static int sReissueTokenObject;
#define REISSUE_TOKEN ((RIL_Token)&sReissueTokenObject)

static pthread_mutex_t sIaLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t sIaWake = PTHREAD_COND_INITIALIZER;
static MtkInitialAttachApn sIaCache[SIM_COUNT];
static bool sIaCached[SIM_COUNT];
static bool sIaPending[SIM_COUNT];
static bool sIaRequestInFlight;
static bool sIaLastIssueValid;
static struct timespec sIaLastIssue;
static int sIaNextSocket;

static bool attachApnHooksActive(void)
{
    return atomic_load_explicit(&sIaHookState, memory_order_acquire) ==
            IA_HOOKS_ACTIVE;
}

static void freeIaStrings(MtkInitialAttachApn *ia)
{
    free(ia->apn);
    free(ia->protocol);
    free(ia->roamingProtocol);
    free(ia->username);
    free(ia->password);
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

    if (t == REISSUE_TOKEN) {
        /*
         * Ours. Swallow it: librilproxy's RIL_onRequestComplete dereferences
         * the token at +0x1c before it validates it, so this pointer must never
         * reach it. Completion is also the single-flight hand-off: only after
         * this request finishes may the worker issue the coalesced next one.
         * This remains true even for a residual hook after failed rollback.
         */
        pthread_mutex_lock(&sIaLock);
        sIaRequestInFlight = false;
        pthread_cond_signal(&sIaWake);
        pthread_mutex_unlock(&sIaLock);
        RLOGI("re-issued SET_INITIAL_ATTACH_APN completed, e=%d", (int)e);
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
            pthread_mutex_unlock(&sIaLock);
            RLOGE("out of memory re-issuing the initial-attach APN");
            continue;
        }
        sIaPending[socketId] = false;
        sIaRequestInFlight = true;
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
                       sizeof(outgoing), REISSUE_TOKEN,
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

static int startIaWorker(void)
{
    pthread_attr_t attr;
    pthread_t worker;
    int rc;

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

static int patchOnRequest(const RIL_RadioFunctions *funcs)
{
    uintptr_t field = (uintptr_t)&funcs->onRequest;
    long pageSize = sysconf(_SC_PAGESIZE);
    uintptr_t page;
    size_t span;
    int oldProt;

    if (pageSize <= 0) {
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

    sRealOnRequest = funcs->onRequest;
    ((RIL_RadioFunctions *)funcs)->onRequest = onRequestShim;

    if ((oldProt & PROT_WRITE) == 0 &&
        mprotect((void *)page, span, oldProt) != 0) {
        /* The patch is in; failing to restore is worth a line but not a
         * failure, and there is nothing useful to do about it. */
        RLOGE("mprotect(%p, restore) failed", (void *)page);
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

const RIL_RadioFunctions *RIL_Init(const struct RIL_Env *env, int argc,
                                   char **argv)
{
    ril_init_fn realInit;
    void *handle = openRealRil();

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
        /* Fail closed. Returning the real table would silently put the broken,
         * destructive MediaTek capability switch back behind a Settings tap. */
        RLOGE("could not patch onRequest; refusing to expose the unsafe MTK "
              "radio-capability path");
        return NULL;
    }

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
