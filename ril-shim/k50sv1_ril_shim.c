/*
 * k50sv1 RIL shim
 * ===============
 *
 * WHAT THIS DOES
 *
 * It is loaded by /vendor/bin/hw/rilproxy in place of mtk-rilproxy.so, forwards
 * every RIL entry point to the real blob, and changes exactly two things.
 *
 *   1. RIL_REQUEST_GET_RADIO_CAPABILITY is completed with
 *      RIL_E_REQUEST_NOT_SUPPORTED instead of being passed down, so the MTK
 *      SIM switch never runs. See "PART 1" below.
 *
 *   2. It re-sends the initial-attach APN when the vendor RIL asks for it,
 *      which is the thing AOSP's framework does not do and MediaTek's own
 *      framework add-on would have. See "PART 2" below.
 *
 * ============================================================================
 * PART 1 - force a static radio access family
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
 * RadioResponse.getRadioCapabilityResponse (frameworks/opt/telephony) does:
 *
 *     if (responseInfo.error == RadioError.REQUEST_NOT_SUPPORTED
 *             || responseInfo.error == RadioError.GENERIC_FAILURE) {
 *         ret = mRil.makeStaticRadioCapability();
 *         responseInfo.error = RadioError.NONE;
 *     }
 *
 * and RIL.makeStaticRadioCapability() builds the RAF from the framework
 * resource config_radio_access_family, which is GLOBAL rather than per-phone.
 * Both phones therefore report the identical RAF, so
 * ProxyController.setRadioCapability() takes its early return
 *
 *     "setRadioCapability: Already in requested configuration, nothing to do."
 *
 * and no transaction is ever started. The device tree overlays
 * config_radio_access_family to slot 0's real capability; see
 * overlay/frameworks/base/core/res/res/values/config.xml.
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
 * switch is broken in the vendor blob (see above), not in this port. Both
 * slots now advertise slot 0's RAF, which is optimistic for slot 1; nothing in
 * Android 10 acts on per-phone RAF once the capability switch is out of the
 * picture.
 *
 * DO NOT ALSO INTERCEPT RIL_REQUEST_SET_RADIO_CAPABILITY. Failing it looks
 * safer and is not: ProxyController.completeRadioCapabilityTransaction()
 * responds to a failed transaction by calling doSetRadioCapabilities() again
 * with the old RAFs, which would fail again, forever.
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
 * changes. There is no partial state: the hooks are installed as a pair or not
 * at all.
 */

#define LOG_TAG "k50sv1-ril-shim"

#include <dlfcn.h>
#include <elf.h>
#include <errno.h>
#include <link.h>
#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include <log/log.h>
#include <telephony/ril.h>

/*
 * Resolved through the vendor linker namespace, exactly as rilproxy would have
 * resolved it from its own -l argument. Keep the bare SONAME: an absolute path
 * is rejected by the Treble vendor namespace for a permitted-path lookup.
 */
#define REAL_RIL_SONAME "mtk-rilproxy.so"

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

/* One re-issue per socket per second is plenty; the vendor RIL repeats the URC
 * ~3 times a second until the APN is valid again. */
#define REISSUE_MIN_INTERVAL_NS (1000L * 1000L * 1000L)

typedef void (*ril_unsol_fn)(int unsolResponse, const void *data, size_t datalen,
                             RIL_SOCKET_ID socketId);
typedef void (*ril_complete_fn)(RIL_Token t, RIL_Errno e, void *response,
                                size_t responselen);

static ril_unsol_fn sRealOnUnsol;
static ril_complete_fn sRealOnComplete;

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
static bool sIaWorkerRunning;

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

    pthread_mutex_lock(&sIaLock);
    if (sIaCached[socketId]) {
        freeIaStrings(&sIaCache[socketId]);
    }
    sIaCache[socketId] = fresh;
    sIaCached[socketId] = true;
    pthread_mutex_unlock(&sIaLock);

    RLOGI("cached initial-attach APN for socket %d (apn=%s, auth=%d)",
          (int)socketId, fresh.apn != NULL ? fresh.apn : "(null)",
          fresh.authtype);
}

static void completeHook(RIL_Token t, RIL_Errno e, void *response,
                         size_t responselen)
{
    if (t == REISSUE_TOKEN) {
        /*
         * Ours. Swallow it: librilproxy's RIL_onRequestComplete dereferences
         * the token at +0x1c before it validates it, so this pointer must never
         * reach it. One line per re-issue, and it is the only proof the vendor
         * RIL accepted the request.
         */
        RLOGI("re-issued SET_INITIAL_ATTACH_APN completed, e=%d", (int)e);
        return;
    }
    sRealOnComplete(t, e, response, responselen);
}

static void unsolHook(int unsolResponse, const void *data, size_t datalen,
                      RIL_SOCKET_ID socketId)
{
    if (unsolResponse == RIL_UNSOL_RESET_ATTACH_APN &&
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
    sRealOnUnsol(unsolResponse, data, datalen, socketId);
}

static void *iaWorker(void *unused)
{
    (void)unused;

    for (;;) {
        MtkInitialAttachApn outgoing;
        int socketId = -1;
        int i;

        pthread_mutex_lock(&sIaLock);
        for (;;) {
            for (i = 0; i < SIM_COUNT; i++) {
                if (sIaPending[i] && sIaCached[i]) {
                    socketId = i;
                    break;
                }
            }
            if (socketId >= 0) {
                break;
            }
            pthread_cond_wait(&sIaWake, &sIaLock);
        }
        sIaPending[socketId] = false;
        if (!copyIa(&outgoing, &sIaCache[socketId])) {
            pthread_mutex_unlock(&sIaLock);
            RLOGE("out of memory re-issuing the initial-attach APN");
            continue;
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

        {
            struct timespec pause = {
                .tv_sec = REISSUE_MIN_INTERVAL_NS / 1000000000L,
                .tv_nsec = REISSUE_MIN_INTERVAL_NS % 1000000000L,
            };
            nanosleep(&pause, NULL);
        }
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
    const char *soname;      /* in:  basename to match */
    ElfW(Addr) base;         /* out: load bias */
    const ElfW(Rela) *jmprel;
    size_t jmprelCount;
    const ElfW(Sym) *symtab;
    const char *strtab;
    bool found;
} GotScan;

static int gotScanCallback(struct dl_phdr_info *info, size_t size, void *arg)
{
    GotScan *scan = (GotScan *)arg;
    const ElfW(Dyn) *dyn = NULL;
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

    for (i = 0; i < info->dlpi_phnum; i++) {
        if (info->dlpi_phdr[i].p_type == PT_DYNAMIC) {
            dyn = (const ElfW(Dyn) *)(info->dlpi_addr +
                                      info->dlpi_phdr[i].p_vaddr);
            break;
        }
    }
    if (dyn == NULL) {
        return 0;
    }

    scan->base = info->dlpi_addr;
    for (; dyn->d_tag != DT_NULL; dyn++) {
        switch (dyn->d_tag) {
        case DT_JMPREL:
            scan->jmprel = (const ElfW(Rela) *)dyn->d_un.d_ptr;
            break;
        case DT_PLTRELSZ:
            scan->jmprelCount = dyn->d_un.d_val / sizeof(ElfW(Rela));
            break;
        case DT_SYMTAB:
            scan->symtab = (const ElfW(Sym) *)dyn->d_un.d_ptr;
            break;
        case DT_STRTAB:
            scan->strtab = (const char *)dyn->d_un.d_ptr;
            break;
        case DT_PLTREL:
            /* RELA only. A REL-based PLT would mean the entry layout above is
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
    scan->found = (scan->jmprel != NULL && scan->jmprelCount != 0 &&
                   scan->symtab != NULL && scan->strtab != NULL);
    return 1;
}

/*
 * Replace the PLT GOT entry for `symbol` with `replacement`, returning the
 * value that was there. bionic links this blob with -z now, so the slot already
 * holds the resolved address and there is no lazy-binding race to lose.
 */
static void *hookGotEntry(const GotScan *scan, const char *symbol,
                          void *replacement)
{
    size_t i;

    for (i = 0; i < scan->jmprelCount; i++) {
        const ElfW(Rela) *rela = &scan->jmprel[i];
        uint32_t symIndex = (uint32_t)ELF64_R_SYM(rela->r_info);
        const char *name;
        void **slot;
        void *previous;
        uintptr_t page;
        long pageSize;
        int oldProt;

        if (ELF64_R_TYPE(rela->r_info) != R_AARCH64_JUMP_SLOT) {
            continue;
        }
        name = scan->strtab + scan->symtab[symIndex].st_name;
        if (strcmp(name, symbol) != 0) {
            continue;
        }

        slot = (void **)(scan->base + rela->r_offset);
        pageSize = sysconf(_SC_PAGESIZE);
        if (pageSize <= 0) {
            return NULL;
        }
        page = (uintptr_t)slot & ~(uintptr_t)(pageSize - 1);
        oldProt = mappingProt((uintptr_t)slot);
        if (oldProt < 0) {
            RLOGE("GOT slot for %s at %p is in no mapping", symbol,
                  (void *)slot);
            return NULL;
        }
        /* PT_GNU_RELRO covers .got.plt here, so the slot is read-only by the
         * time RIL_Init runs. Same dance as patchOnRequest. */
        if ((oldProt & PROT_WRITE) == 0 &&
            mprotect((void *)page, (size_t)pageSize, oldProt | PROT_WRITE) != 0) {
            RLOGE("mprotect(%p, +w) for %s failed: %s", (void *)page, symbol,
                  strerror(errno));
            return NULL;
        }
        previous = *slot;
        *slot = replacement;
        if ((oldProt & PROT_WRITE) == 0 &&
            mprotect((void *)page, (size_t)pageSize, oldProt) != 0) {
            RLOGE("mprotect(%p, restore) for %s failed: %s", (void *)page,
                  symbol, strerror(errno));
        }
        return previous;
    }
    RLOGE("%s has no PLT GOT entry for %s", scan->soname, symbol);
    return NULL;
}

/*
 * Install both hooks, or neither. Returns 0 on success; on failure the caller
 * carries on with E-092 unfixed and nothing else changed.
 */
static int installAttachApnHooks(void)
{
    GotScan scan = { .soname = REAL_RIL_SONAME };
    void *realUnsol;
    void *realComplete;
    pthread_t worker;
    int rc;

    dl_iterate_phdr(gotScanCallback, &scan);
    if (!scan.found) {
        RLOGE("could not read %s's dynamic PLT relocations", REAL_RIL_SONAME);
        return -1;
    }

    realUnsol = hookGotEntry(&scan, "RIL_onUnsolicitedResponse", unsolHook);
    if (realUnsol == NULL) {
        return -1;
    }
    sRealOnUnsol = (ril_unsol_fn)realUnsol;

    realComplete = hookGotEntry(&scan, "RIL_onRequestComplete", completeHook);
    if (realComplete == NULL) {
        /* Put the first one back rather than run with half a mechanism: an
         * un-swallowed synthetic token reaches a function that dereferences it. */
        (void)hookGotEntry(&scan, "RIL_onUnsolicitedResponse", realUnsol);
        sRealOnUnsol = NULL;
        return -1;
    }
    sRealOnComplete = (ril_complete_fn)realComplete;

    rc = pthread_create(&worker, NULL, iaWorker, NULL);
    if (rc != 0) {
        (void)hookGotEntry(&scan, "RIL_onUnsolicitedResponse", realUnsol);
        (void)hookGotEntry(&scan, "RIL_onRequestComplete", realComplete);
        sRealOnUnsol = NULL;
        sRealOnComplete = NULL;
        RLOGE("pthread_create for the attach-APN worker failed: %s",
              strerror(rc));
        return -1;
    }
    pthread_detach(worker);
    sIaWorkerRunning = true;
    return 0;
}

static void onRequestShim(int request, void *data, size_t datalen, RIL_Token t,
                          RIL_SOCKET_ID socketId)
{
    if (request == RIL_REQUEST_GET_RADIO_CAPABILITY) {
        /*
         * One line per boot per slot; keep it, it is the only evidence that
         * the shim is live.
         */
        RLOGI("GET_RADIO_CAPABILITY -> REQUEST_NOT_SUPPORTED "
              "(framework falls back to config_radio_access_family)");
        sEnv->OnRequestComplete(t, RIL_E_REQUEST_NOT_SUPPORTED, NULL, 0);
        return;
    }

    /*
     * Copy BEFORE forwarding. librilproxy frees every heap string in this
     * payload on the instruction after onRequest returns, so a copy taken
     * afterwards would be of freed, memset-to-zero memory. Only when the hooks
     * are live: without them there is nobody to re-issue it and the cache would
     * be a pure leak of the APN password into this process's heap.
     */
    if (request == RIL_REQUEST_SET_INITIAL_ATTACH_APN && sIaWorkerRunning) {
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
        RLOGE("could not patch onRequest; GET_RADIO_CAPABILITY will NOT be "
              "faked and the MTK SIM switch is live again");
        return sRealFuncs;
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
