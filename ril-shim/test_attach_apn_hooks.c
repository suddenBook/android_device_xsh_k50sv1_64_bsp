#define K50SV1_RIL_SHIM_HOST_TEST 1
#define REAL_RIL_SONAME "libfake-mtk-rilproxy.so"
#define REISSUE_MIN_INTERVAL_NS (30L * 1000L * 1000L)
#define REISSUE_INFLIGHT_TIMEOUT_NS (400L * 1000L * 1000L)

/* Include the implementation so fault injection exercises the exact static
 * transaction and worker Android builds. The target GOT is still a separate,
 * genuinely relocatable shared object (fake_rilproxy.c). */
#include "k50sv1_ril_shim.c"

#include <signal.h>
#include <sys/wait.h>

typedef void (*fake_emit_unsol_fn)(int response, const void *data,
                                   size_t datalen, RIL_SOCKET_ID socketId);
typedef void (*fake_complete_call_fn)(RIL_Token token, RIL_Errno error,
                                      void *response, size_t responselen);

static _Atomic unsigned sOriginalUnsolCalls;
static _Atomic unsigned sOriginalCompleteCalls;
static _Atomic unsigned sAttemptedUnsolCalls;
static _Atomic unsigned sAttemptedCompleteCalls;
static void *sFakeHandle;
static fake_emit_unsol_fn sFakeEmitUnsol;
static fake_complete_call_fn sFakeCompleteCall;

/* These are the originals to which the fake DSO binds before its GOT is
 * patched. They intentionally have external visibility for -export-dynamic. */
void RIL_onUnsolicitedResponse(int response, const void *data, size_t datalen,
                               RIL_SOCKET_ID socketId)
{
    (void)response;
    (void)data;
    (void)datalen;
    (void)socketId;
    atomic_fetch_add_explicit(&sOriginalUnsolCalls, 1, memory_order_relaxed);
}

void RIL_onRequestComplete(RIL_Token token, RIL_Errno error, void *response,
                           size_t responselen)
{
    (void)token;
    (void)error;
    (void)response;
    (void)responselen;
    atomic_fetch_add_explicit(&sOriginalCompleteCalls, 1,
                              memory_order_relaxed);
}

#define CHECK(condition) do {                                                \
    if (!(condition)) {                                                      \
        fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition); \
        return 1;                                                            \
    }                                                                        \
} while (0)

static int loadFakeRil(void)
{
    void *symbol;

    sFakeHandle = dlopen(REAL_RIL_SONAME, RTLD_NOW | RTLD_LOCAL);
    CHECK(sFakeHandle != NULL);
    symbol = dlsym(sFakeHandle, "fakeRilEmitUnsolicited");
    CHECK(symbol != NULL);
    sFakeEmitUnsol = (fake_emit_unsol_fn)symbol;
    symbol = dlsym(sFakeHandle, "fakeRilComplete");
    CHECK(symbol != NULL);
    sFakeCompleteCall = (fake_complete_call_fn)symbol;
    return 0;
}

static int resolveFixtureEntries(GotEntry *unsol, GotEntry *complete)
{
    GotScan scan = { .soname = REAL_RIL_SONAME };

    dl_iterate_phdr(gotScanCallback, &scan);
    CHECK(scan.found);
    CHECK(findGotEntry(&scan, "RIL_onUnsolicitedResponse", (void *)unsolHook,
                       unsol));
    CHECK(findGotEntry(&scan, "RIL_onRequestComplete", (void *)completeHook,
                       complete));
    return 0;
}

static void callFixtureUnsol(int response)
{
    atomic_fetch_add_explicit(&sAttemptedUnsolCalls, 1,
                              memory_order_relaxed);
    sFakeEmitUnsol(response, NULL, 0, RIL_SOCKET_1);
}

static void callFixtureComplete(RIL_Token token)
{
    atomic_fetch_add_explicit(&sAttemptedCompleteCalls, 1,
                              memory_order_relaxed);
    sFakeCompleteCall(token, RIL_E_SUCCESS, NULL, 0);
}

static void callbackImmediatelyAfterGotWrite(GotWriteStep step)
{
    /* On each install store, invoke the newly reachable hook before the next
     * transaction step. Both calls must forward through already-published
     * originals while state is still INSTALLING. */
    if (step == GOT_WRITE_INSTALL_UNSOL) {
        callFixtureUnsol(2999);
    } else if (step == GOT_WRITE_INSTALL_COMPLETE) {
        callFixtureComplete((RIL_Token)(uintptr_t)0x1234);
    }
}

typedef struct {
    const char *name;
    unsigned failMakeWritable;
    unsigned failBefore;
    unsigned failAfter;
    unsigned failRestore;
    bool failWorker;
} InstallFailureCase;

static int testInstallFailure(const InstallFailureCase *testCase)
{
    GotEntry unsol;
    GotEntry complete;

    CHECK(loadFakeRil() == 0);
    CHECK(resolveFixtureEntries(&unsol, &complete) == 0);
    sGotTestControl.failMakeWritableMask = testCase->failMakeWritable;
    sGotTestControl.failBeforeWriteMask = testCase->failBefore;
    sGotTestControl.failAfterWriteMask = testCase->failAfter;
    sGotTestControl.failRestoreMask = testCase->failRestore;
    sGotTestControl.failWorkerCreate = testCase->failWorker;
    sGotTestControl.afterWrite = callbackImmediatelyAfterGotWrite;

    CHECK(installAttachApnHooks() == -1);
    CHECK(atomic_load_explicit(&sIaHookState, memory_order_acquire) ==
          IA_HOOKS_DISABLED);
    CHECK(verifyGotValue(&unsol, unsol.original));
    CHECK(verifyGotValue(&complete, complete.original));
    CHECK((void *)atomic_load_explicit(&sRealOnUnsol, memory_order_acquire) ==
          unsol.original);
    CHECK((void *)atomic_load_explicit(&sRealOnComplete, memory_order_acquire) ==
          complete.original);

    callFixtureUnsol(2998);
    callFixtureComplete((RIL_Token)(uintptr_t)0x5678);
    CHECK(atomic_load_explicit(&sOriginalUnsolCalls, memory_order_relaxed) ==
          atomic_load_explicit(&sAttemptedUnsolCalls, memory_order_relaxed));
    CHECK(atomic_load_explicit(&sOriginalCompleteCalls, memory_order_relaxed) ==
          atomic_load_explicit(&sAttemptedCompleteCalls, memory_order_relaxed));
    fprintf(stderr, "install failure %-28s: PASS\n", testCase->name);
    return 0;
}

static int testMissingLibrary(void)
{
    CHECK(installAttachApnHooks() == -1);
    CHECK(atomic_load_explicit(&sIaHookState, memory_order_acquire) ==
          IA_HOOKS_DISABLED);
    CHECK(atomic_load_explicit(&sRealOnUnsol, memory_order_acquire) == NULL);
    CHECK(atomic_load_explicit(&sRealOnComplete, memory_order_acquire) == NULL);
    fprintf(stderr, "install failure missing target DSO          : PASS\n");
    return 0;
}

static const char *sMissingCallbackSymbol;

static int testMissingCallback(void)
{
    GotEntry unsol;
    GotEntry complete;

    CHECK(loadFakeRil() == 0);
    CHECK(resolveFixtureEntries(&unsol, &complete) == 0);
    sGotTestControl.failResolveSymbol = sMissingCallbackSymbol;
    CHECK(installAttachApnHooks() == -1);
    CHECK(atomic_load_explicit(&sIaHookState, memory_order_acquire) ==
          IA_HOOKS_DISABLED);
    CHECK(verifyGotValue(&unsol, unsol.original));
    CHECK(verifyGotValue(&complete, complete.original));
    /* Publication happens only after both resolutions, so neither pointer is
     * exposed when either relocation is unavailable. */
    CHECK(atomic_load_explicit(&sRealOnUnsol, memory_order_acquire) == NULL);
    CHECK(atomic_load_explicit(&sRealOnComplete, memory_order_acquire) == NULL);
    fprintf(stderr, "install failure missing %-20s: PASS\n",
            sMissingCallbackSymbol);
    return 0;
}

typedef struct {
    const char *name;
    unsigned rollbackFailures;
    bool residualUnsol;
    bool residualComplete;
} RollbackFailureCase;

static int testRollbackFailure(const RollbackFailureCase *testCase)
{
    GotEntry unsol;
    GotEntry complete;
    unsigned originalCompleteBeforeSynthetic;

    CHECK(loadFakeRil() == 0);
    CHECK(resolveFixtureEntries(&unsol, &complete) == 0);
    sGotTestControl.failWorkerCreate = true;
    sGotTestControl.failBeforeWriteMask = testCase->rollbackFailures;
    sGotTestControl.afterWrite = callbackImmediatelyAfterGotWrite;

    CHECK(installAttachApnHooks() == -1);
    CHECK(atomic_load_explicit(&sIaHookState, memory_order_acquire) ==
          IA_HOOKS_FAILED);
    CHECK(loadGotValue(&unsol) ==
          (testCase->residualUnsol ? unsol.replacement : unsol.original));
    CHECK(loadGotValue(&complete) ==
          (testCase->residualComplete ? complete.replacement :
                                        complete.original));
    /* The crucial failure invariant: originals remain published even while a
     * rollback-surviving slot still points at a hook. */
    CHECK((void *)atomic_load_explicit(&sRealOnUnsol, memory_order_acquire) ==
          unsol.original);
    CHECK((void *)atomic_load_explicit(&sRealOnComplete, memory_order_acquire) ==
          complete.original);

    callFixtureUnsol(RIL_UNSOL_RESET_ATTACH_APN);
    callFixtureComplete((RIL_Token)(uintptr_t)0x7777);
    CHECK(atomic_load_explicit(&sOriginalUnsolCalls, memory_order_relaxed) ==
          atomic_load_explicit(&sAttemptedUnsolCalls, memory_order_relaxed));
    CHECK(atomic_load_explicit(&sOriginalCompleteCalls, memory_order_relaxed) ==
          atomic_load_explicit(&sAttemptedCompleteCalls, memory_order_relaxed));

    /* If completeHook survived rollback it must also keep the shim's synthetic
     * token away from the dereferencing original callback. */
    originalCompleteBeforeSynthetic = atomic_load_explicit(
            &sOriginalCompleteCalls, memory_order_relaxed);
    if (testCase->residualComplete) {
        callFixtureComplete(REISSUE_TOKEN_AT(sIaTokenSeq));
        CHECK(atomic_load_explicit(&sOriginalCompleteCalls,
                                   memory_order_relaxed) ==
              originalCompleteBeforeSynthetic);
        /* A token from earlier in the ring must be swallowed too. */
        callFixtureComplete(REISSUE_TOKEN_AT(sIaTokenSeq + 1));
        CHECK(atomic_load_explicit(&sOriginalCompleteCalls,
                                   memory_order_relaxed) ==
              originalCompleteBeforeSynthetic);
    }
    fprintf(stderr, "rollback failure %-27s: PASS\n", testCase->name);
    return 0;
}

static _Atomic bool sHammerRun;

static void *unsolHammer(void *unused)
{
    (void)unused;
    while (atomic_load_explicit(&sHammerRun, memory_order_acquire)) {
        callFixtureUnsol(2997);
    }
    return NULL;
}

static void *completeHammer(void *unused)
{
    (void)unused;
    while (atomic_load_explicit(&sHammerRun, memory_order_acquire)) {
        callFixtureComplete((RIL_Token)(uintptr_t)0x8888);
    }
    return NULL;
}

static void noOpRealRequest(int request, void *data, size_t datalen,
                            RIL_Token token, RIL_SOCKET_ID socketId)
{
    (void)request;
    (void)data;
    (void)datalen;
    (void)token;
    (void)socketId;
}

static int testConcurrentPublication(void)
{
    GotEntry unsol;
    GotEntry complete;
    pthread_t unsolThread;
    pthread_t completeThread;

    CHECK(loadFakeRil() == 0);
    CHECK(resolveFixtureEntries(&unsol, &complete) == 0);
    sRealOnRequest = noOpRealRequest;
    sGotTestControl.afterWrite = callbackImmediatelyAfterGotWrite;
    sGotTestControl.afterWriteDelayUs = 20000;
    atomic_store_explicit(&sHammerRun, true, memory_order_release);
    CHECK(pthread_create(&unsolThread, NULL, unsolHammer, NULL) == 0);
    CHECK(pthread_create(&completeThread, NULL, completeHammer, NULL) == 0);

    CHECK(installAttachApnHooks() == 0);
    atomic_store_explicit(&sHammerRun, false, memory_order_release);
    CHECK(pthread_join(unsolThread, NULL) == 0);
    CHECK(pthread_join(completeThread, NULL) == 0);
    CHECK(atomic_load_explicit(&sIaHookState, memory_order_acquire) ==
          IA_HOOKS_ACTIVE);
    /* A repeated initializer cannot patch again or start a second worker. */
    CHECK(installAttachApnHooks() == 0);
    CHECK(verifyGotValue(&unsol, unsol.replacement));
    CHECK(verifyGotValue(&complete, complete.replacement));
    CHECK(atomic_load_explicit(&sAttemptedUnsolCalls, memory_order_relaxed) > 0);
    CHECK(atomic_load_explicit(&sAttemptedCompleteCalls,
                               memory_order_relaxed) > 0);
    CHECK(atomic_load_explicit(&sOriginalUnsolCalls, memory_order_relaxed) ==
          atomic_load_explicit(&sAttemptedUnsolCalls, memory_order_relaxed));
    CHECK(atomic_load_explicit(&sOriginalCompleteCalls, memory_order_relaxed) ==
          atomic_load_explicit(&sAttemptedCompleteCalls, memory_order_relaxed));
    fprintf(stderr, "concurrent callback publication: PASS\n");
    return 0;
}

typedef struct {
    char *apn;
    char *protocol;
    char *roamingProtocol;
    char *username;
    char *password;
    char *mvnoType;
    char *mvnoMatchData;
} OwnedIaStrings;

typedef struct {
    char apn[64];
    char protocol[32];
    char roamingProtocol[32];
    char username[64];
    char password[64];
    char mvnoType[32];
    bool mvnoMatchWasNull;
    int authtype;
    int supportedTypesBitmask;
    int bearerBitmask;
    int modemCognitive;
    int mtu;
    int canHandleIms;
    RIL_Token token;
    struct timespec issuedAt;
} CapturedIa;

static pthread_mutex_t sCaptureLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t sCaptureWake = PTHREAD_COND_INITIALIZER;
static CapturedIa sCaptured[4];
static int sCapturedCount;
static int sOutstanding;
static int sMaxOutstanding;

static void copyText(char *dst, size_t dstSize, const char *src)
{
    if (src == NULL) {
        dst[0] = '\0';
        return;
    }
    snprintf(dst, dstSize, "%s", src);
}

static void captureRealRequest(int request, void *data, size_t datalen,
                               RIL_Token token, RIL_SOCKET_ID socketId)
{
    const MtkInitialAttachApn *ia = data;
    CapturedIa *capture;

    (void)socketId;
    if (request != RIL_REQUEST_SET_INITIAL_ATTACH_APN ||
        !isReissueToken(token)) {
        return;
    }
    if (datalen != sizeof(*ia)) {
        abort();
    }

    pthread_mutex_lock(&sCaptureLock);
    if (sCapturedCount >= (int)(sizeof(sCaptured) / sizeof(sCaptured[0]))) {
        abort();
    }
    capture = &sCaptured[sCapturedCount++];
    memset(capture, 0, sizeof(*capture));
    capture->token = token;
    copyText(capture->apn, sizeof(capture->apn), ia->apn);
    copyText(capture->protocol, sizeof(capture->protocol), ia->protocol);
    copyText(capture->roamingProtocol, sizeof(capture->roamingProtocol),
             ia->roamingProtocol);
    copyText(capture->username, sizeof(capture->username), ia->username);
    copyText(capture->password, sizeof(capture->password), ia->password);
    copyText(capture->mvnoType, sizeof(capture->mvnoType), ia->mvnoType);
    capture->mvnoMatchWasNull = ia->mvnoMatchData == NULL;
    capture->authtype = ia->authtype;
    capture->supportedTypesBitmask = ia->supportedTypesBitmask;
    capture->bearerBitmask = ia->bearerBitmask;
    capture->modemCognitive = ia->modemCognitive;
    capture->mtu = ia->mtu;
    capture->canHandleIms = ia->canHandleIms;
    (void)clock_gettime(CLOCK_MONOTONIC, &capture->issuedAt);
    sOutstanding++;
    if (sOutstanding > sMaxOutstanding) {
        sMaxOutstanding = sOutstanding;
    }
    pthread_cond_broadcast(&sCaptureWake);
    pthread_mutex_unlock(&sCaptureLock);
}

static MtkInitialAttachApn makeOwnedIa(const char *prefix, int marker,
                                       OwnedIaStrings *owned)
{
    MtkInitialAttachApn ia;
    char value[96];

    memset(&ia, 0, sizeof(ia));
    memset(owned, 0, sizeof(*owned));
#define OWN_FIELD(member, suffix) do {                                      \
    snprintf(value, sizeof(value), "%s-%s", prefix, suffix);                \
    owned->member = strdup(value);                                           \
    if (owned->member == NULL) abort();                                      \
    ia.member = owned->member;                                               \
} while (0)
    OWN_FIELD(apn, "apn");
    OWN_FIELD(protocol, "protocol");
    OWN_FIELD(roamingProtocol, "roaming");
    OWN_FIELD(username, "user");
    OWN_FIELD(password, "password");
    OWN_FIELD(mvnoType, "mvno");
#undef OWN_FIELD
    /* Exercise the NULL-preserving copy rule as well as owned strings. */
    ia.mvnoMatchData = NULL;
    ia.authtype = marker;
    ia.supportedTypesBitmask = marker + 1;
    ia.bearerBitmask = marker + 2;
    ia.modemCognitive = marker + 3;
    ia.mtu = marker + 4;
    ia.canHandleIms = marker + 5;
    return ia;
}

static void freeOwnedIa(OwnedIaStrings *owned)
{
    free(owned->apn);
    free(owned->protocol);
    free(owned->roamingProtocol);
    free(owned->username);
    free(owned->password);
    free(owned->mvnoType);
    free(owned->mvnoMatchData);
    memset(owned, 0, sizeof(*owned));
}

static int waitForCapturedCount(int target)
{
    struct timespec timeout;
    int rc = 0;

    CHECK(clock_gettime(CLOCK_REALTIME, &timeout) == 0);
    timeout.tv_sec += 2;
    pthread_mutex_lock(&sCaptureLock);
    while (sCapturedCount < target && rc == 0) {
        rc = pthread_cond_timedwait(&sCaptureWake, &sCaptureLock, &timeout);
    }
    pthread_mutex_unlock(&sCaptureLock);
    CHECK(rc == 0);
    return 0;
}

static void completeSyntheticRequest(void)
{
    pthread_mutex_lock(&sCaptureLock);
    if (sOutstanding <= 0) {
        abort();
    }
    sOutstanding--;
    pthread_mutex_unlock(&sCaptureLock);
    callFixtureComplete(REISSUE_TOKEN_AT(sIaTokenSeq));
}

static void *resetApnBurst(void *unused)
{
    int i;

    (void)unused;
    for (i = 0; i < 200; i++) {
        callFixtureUnsol(RIL_UNSOL_RESET_ATTACH_APN);
    }
    return NULL;
}

static int checkCaptured(const CapturedIa *captured, const char *prefix,
                         int marker)
{
    char expected[96];

#define CHECK_TEXT(member, suffix) do {                                     \
    snprintf(expected, sizeof(expected), "%s-%s", prefix, suffix);          \
    CHECK(strcmp(captured->member, expected) == 0);                          \
} while (0)
    CHECK_TEXT(apn, "apn");
    CHECK_TEXT(protocol, "protocol");
    CHECK_TEXT(roamingProtocol, "roaming");
    CHECK_TEXT(username, "user");
    CHECK_TEXT(password, "password");
    CHECK_TEXT(mvnoType, "mvno");
#undef CHECK_TEXT
    CHECK(captured->mvnoMatchWasNull);
    CHECK(captured->authtype == marker);
    CHECK(captured->supportedTypesBitmask == marker + 1);
    CHECK(captured->bearerBitmask == marker + 2);
    CHECK(captured->modemCognitive == marker + 3);
    CHECK(captured->mtu == marker + 4);
    CHECK(captured->canHandleIms == marker + 5);
    return 0;
}

static int testApnLifetimeSingleFlightAndRate(void)
{
    GotEntry unsol;
    GotEntry complete;
    OwnedIaStrings firstOwned;
    OwnedIaStrings secondOwned;
    OwnedIaStrings thirdOwned;
    MtkInitialAttachApn first;
    MtkInitialAttachApn second;
    MtkInitialAttachApn third;
    pthread_t bursts[4];
    int i;
    int outstandingBeforeStale;
    int64_t issueSpacing;
    struct timespec pause = { .tv_sec = 0, .tv_nsec = 70000000L };

    CHECK(loadFakeRil() == 0);
    CHECK(resolveFixtureEntries(&unsol, &complete) == 0);
    sRealOnRequest = captureRealRequest;
    CHECK(installAttachApnHooks() == 0);
    CHECK(verifyGotValue(&unsol, unsol.replacement));
    CHECK(verifyGotValue(&complete, complete.replacement));

    first = makeOwnedIa("first", 100, &firstOwned);
    onRequestShim(RIL_REQUEST_SET_INITIAL_ATTACH_APN, &first, sizeof(first),
                  (RIL_Token)(uintptr_t)0x1000, RIL_SOCKET_1);
    freeOwnedIa(&firstOwned); /* Producer lifetime ends immediately. */
    callFixtureUnsol(RIL_UNSOL_RESET_ATTACH_APN);
    CHECK(waitForCapturedCount(1) == 0);
    CHECK(checkCaptured(&sCaptured[0], "first", 100) == 0);

    second = makeOwnedIa("second", 200, &secondOwned);
    onRequestShim(RIL_REQUEST_SET_INITIAL_ATTACH_APN, &second, sizeof(second),
                  (RIL_Token)(uintptr_t)0x2000, RIL_SOCKET_1);
    freeOwnedIa(&secondOwned);
    for (i = 0; i < (int)(sizeof(bursts) / sizeof(bursts[0])); i++) {
        CHECK(pthread_create(&bursts[i], NULL, resetApnBurst, NULL) == 0);
    }
    for (i = 0; i < (int)(sizeof(bursts) / sizeof(bursts[0])); i++) {
        CHECK(pthread_join(bursts[i], NULL) == 0);
    }

    /* Hundreds of concurrent URCs cannot overlap the outstanding request. */
    nanosleep(&pause, NULL);
    CHECK(sCapturedCount == 1);
    CHECK(sOutstanding == 1);
    CHECK(sMaxOutstanding == 1);

    completeSyntheticRequest();
    CHECK(waitForCapturedCount(2) == 0);
    CHECK(checkCaptured(&sCaptured[1], "second", 200) == 0);
    CHECK(sOutstanding == 1);
    CHECK(sMaxOutstanding == 1);
    issueSpacing = timespecToNs(&sCaptured[1].issuedAt) -
                   timespecToNs(&sCaptured[0].issuedAt);
    CHECK(issueSpacing >= REISSUE_MIN_INTERVAL_NS);

    completeSyntheticRequest();
    nanosleep(&pause, NULL);
    CHECK(sCapturedCount == 2); /* pending burst was coalesced exactly once */
    CHECK(sOutstanding == 0);

    /*
     * A re-issued request that the vendor RIL accepts and never completes must
     * not cost the single-flight slot permanently. completeHook is the only
     * writer that clears sIaRequestInFlight, so before the bounded wait one
     * dropped completion stopped every later re-send for the rest of the boot
     * -- with IA_HOOKS_ACTIVE still published and nothing logged.
     */
    third = makeOwnedIa("third", 300, &thirdOwned);
    onRequestShim(RIL_REQUEST_SET_INITIAL_ATTACH_APN, &third, sizeof(third),
                  (RIL_Token)(uintptr_t)0x3000, RIL_SOCKET_1);
    freeOwnedIa(&thirdOwned);
    callFixtureUnsol(RIL_UNSOL_RESET_ATTACH_APN);
    CHECK(waitForCapturedCount(3) == 0);
    CHECK(checkCaptured(&sCaptured[2], "third", 300) == 0);

    /* No completeSyntheticRequest(): this is the dropped completion. */
    callFixtureUnsol(RIL_UNSOL_RESET_ATTACH_APN);
    CHECK(waitForCapturedCount(4) == 0);
    CHECK(checkCaptured(&sCaptured[3], "third", 300) == 0);

    /*
     * Every issue carries a DISTINCT token, and a late completion of a
     * timed-out request does not release the slot its successor holds.
     *
     * With one shared token this was the hole the bounded wait opened: the
     * worker released the slot at 10 s without cancelling request A, issued B
     * under the same token, and A's late completion then cleared the flag while
     * B was still outstanding - so C went out and two or more requests were live
     * in the vendor RIL under one identical token. Here sCaptured[2] is the
     * timed-out one and sCaptured[3] is its successor; completing the stale
     * token must leave sOutstanding untouched.
     */
    CHECK(sCaptured[2].token != sCaptured[3].token);
    CHECK(isReissueToken(sCaptured[2].token));
    CHECK(isReissueToken(sCaptured[3].token));
    outstandingBeforeStale = sOutstanding;
    callFixtureComplete(sCaptured[2].token);
    CHECK(sOutstanding == outstandingBeforeStale);
    /* And the current one still does release it. */
    completeSyntheticRequest();

    fprintf(stderr, "APN deep-copy, single-flight, and rate limiting: PASS\n");
    return 0;
}

typedef int (*child_test_fn)(void);

static int runChild(const char *name, child_test_fn test)
{
    pid_t pid = fork();
    int status;

    CHECK(pid >= 0);
    if (pid == 0) {
        int rc;

        alarm(8);
        rc = test();
        _exit(rc == 0 ? 0 : 1);
    }
    CHECK(waitpid(pid, &status, 0) == pid);
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        fprintf(stderr, "FAIL child case: %s (status=%#x)\n", name, status);
        return 1;
    }
    return 0;
}

static const InstallFailureCase *sCurrentInstallFailure;
static const RollbackFailureCase *sCurrentRollbackFailure;

static int runCurrentInstallFailure(void)
{
    return testInstallFailure(sCurrentInstallFailure);
}

static int runCurrentRollbackFailure(void)
{
    return testRollbackFailure(sCurrentRollbackFailure);
}

int main(void)
{
    static const InstallFailureCase installFailures[] = {
        { "first make-writable", 1U << GOT_WRITE_INSTALL_UNSOL,
          0, 0, 0, false },
        { "first write rejected", 0,
          1U << GOT_WRITE_INSTALL_UNSOL, 0, 0, false },
        { "first write verification", 0,
          0, 1U << GOT_WRITE_INSTALL_UNSOL, 0, false },
        { "first protection restore", 0,
          0, 0, 1U << GOT_WRITE_INSTALL_UNSOL, false },
        { "second make-writable", 1U << GOT_WRITE_INSTALL_COMPLETE,
          0, 0, 0, false },
        { "second write rejected", 0,
          1U << GOT_WRITE_INSTALL_COMPLETE, 0, 0, false },
        { "second write verification", 0,
          0, 1U << GOT_WRITE_INSTALL_COMPLETE, 0, false },
        { "second protection restore", 0,
          0, 0, 1U << GOT_WRITE_INSTALL_COMPLETE, false },
        { "worker creation", 0, 0, 0, 0, true },
    };
    static const RollbackFailureCase rollbackFailures[] = {
        { "complete slot", 1U << GOT_WRITE_ROLLBACK_COMPLETE, false, true },
        { "unsolicited slot", 1U << GOT_WRITE_ROLLBACK_UNSOL, true, false },
        { "both slots", (1U << GOT_WRITE_ROLLBACK_COMPLETE) |
                        (1U << GOT_WRITE_ROLLBACK_UNSOL), true, true },
    };
    size_t i;

    CHECK(runChild("missing target DSO", testMissingLibrary) == 0);
    sMissingCallbackSymbol = "RIL_onUnsolicitedResponse";
    CHECK(runChild("missing unsolicited callback", testMissingCallback) == 0);
    sMissingCallbackSymbol = "RIL_onRequestComplete";
    CHECK(runChild("missing complete callback", testMissingCallback) == 0);
    for (i = 0; i < sizeof(installFailures) / sizeof(installFailures[0]); i++) {
        sCurrentInstallFailure = &installFailures[i];
        CHECK(runChild(installFailures[i].name,
                       runCurrentInstallFailure) == 0);
    }
    for (i = 0; i < sizeof(rollbackFailures) / sizeof(rollbackFailures[0]); i++) {
        sCurrentRollbackFailure = &rollbackFailures[i];
        CHECK(runChild(rollbackFailures[i].name,
                       runCurrentRollbackFailure) == 0);
    }
    CHECK(runChild("concurrent publication", testConcurrentPublication) == 0);
    CHECK(runChild("APN worker", testApnLifetimeSingleFlightAndRate) == 0);
    puts("attach-APN hook transaction tests: PASS");
    return 0;
}
