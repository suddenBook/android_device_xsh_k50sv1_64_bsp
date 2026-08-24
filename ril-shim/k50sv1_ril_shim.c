/*
 * k50sv1 RIL shim - force a static radio access family
 * =====================================================
 *
 * WHAT THIS DOES
 *
 * It is loaded by /vendor/bin/hw/rilproxy in place of mtk-rilproxy.so, forwards
 * every RIL entry point to the real blob, and changes exactly one thing:
 * RIL_REQUEST_GET_RADIO_CAPABILITY is completed with RIL_E_REQUEST_NOT_SUPPORTED
 * instead of being passed down.
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
 * Data on slot 1 runs on protocol stack 2, which is W/G, so it is 3G/2G. That
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
 */

#define LOG_TAG "k50sv1-ril-shim"

#include <dlfcn.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
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

    sRealOnRequest(request, data, datalen, t, socketId);
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
