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
static const struct RIL_Env *sEnv;
static RIL_RadioFunctions sShimFuncs;
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

    sRealFuncs->onRequest(request, data, datalen, t, socketId);
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
     * Copy field by field rather than memcpy. RIL_RadioFunctions is an ABI
     * struct that no vendor extends -- the `version` field is how it is
     * versioned -- but reading only the six documented members cannot fault
     * even if this blob's struct were shorter than the header's.
     */
    sShimFuncs.version = sRealFuncs->version;
    sShimFuncs.onRequest = onRequestShim;
    sShimFuncs.onStateRequest = sRealFuncs->onStateRequest;
    sShimFuncs.supports = sRealFuncs->supports;
    sShimFuncs.onCancel = sRealFuncs->onCancel;
    sShimFuncs.getVersion = sRealFuncs->getVersion;

    RLOGI("wrapping %s, RIL version %d", REAL_RIL_SONAME, sShimFuncs.version);
    return &sShimFuncs;
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
