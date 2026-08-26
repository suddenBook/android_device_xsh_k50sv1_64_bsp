#define K50SV1_RIL_SHIM_HOST_TEST 1

/* Include the implementation so this host test exercises the exact static
 * request handler Android builds, not a second copy of its protocol logic. */
#include "k50sv1_ril_shim.c"

typedef enum {
    EVENT_COMPLETE,
    EVENT_UNSOL,
} EventKind;

typedef struct {
    EventKind kind;
    RIL_Errno error;
    int unsolResponse;
    RIL_SOCKET_ID socketId;
    size_t length;
    bool hasCapability;
    RIL_RadioCapability capability;
} TestEvent;

static TestEvent sEvents[32];
static size_t sEventCount;
static int sForwardCount;

#define CHECK(condition) do {                                                \
    if (!(condition)) {                                                      \
        fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition); \
        return 1;                                                            \
    }                                                                        \
} while (0)

static void recordCapability(TestEvent *event, const void *response,
                             size_t responseLen)
{
    event->length = responseLen;
    if (response != NULL && responseLen == sizeof(RIL_RadioCapability)) {
        memcpy(&event->capability, response, sizeof(event->capability));
        event->hasCapability = true;
    }
}

static void fakeComplete(RIL_Token token, RIL_Errno error, void *response,
                         size_t responseLen)
{
    TestEvent *event;

    (void)token;
    if (sEventCount >= sizeof(sEvents) / sizeof(sEvents[0])) {
        abort();
    }
    event = &sEvents[sEventCount++];
    memset(event, 0, sizeof(*event));
    event->kind = EVENT_COMPLETE;
    event->error = error;
    recordCapability(event, response, responseLen);
}

static void fakeUnsol(int unsolResponse, const void *data, size_t datalen,
                      RIL_SOCKET_ID socketId)
{
    TestEvent *event;

    if (sEventCount >= sizeof(sEvents) / sizeof(sEvents[0])) {
        abort();
    }
    event = &sEvents[sEventCount++];
    memset(event, 0, sizeof(*event));
    event->kind = EVENT_UNSOL;
    event->unsolResponse = unsolResponse;
    event->socketId = socketId;
    recordCapability(event, data, datalen);
}

static void fakeTimedCallback(RIL_TimedCallback callback, void *param,
                              const struct timeval *relativeTime)
{
    (void)relativeTime;
    callback(param);
}

static void fakeAck(RIL_Token token)
{
    (void)token;
}

static void fakeRealOnRequest(int request, void *data, size_t datalen,
                              RIL_Token token, RIL_SOCKET_ID socketId)
{
    (void)request;
    (void)data;
    (void)datalen;
    (void)token;
    (void)socketId;
    sForwardCount++;
}

static const struct RIL_Env kFakeEnv = {
    .OnRequestComplete = fakeComplete,
    .OnUnsolicitedResponse = fakeUnsol,
    .RequestTimedCallback = fakeTimedCallback,
    .OnRequestAck = fakeAck,
};

static void resetEvents(void)
{
    memset(sEvents, 0, sizeof(sEvents));
    sEventCount = 0;
}

static void resetHarness(void)
{
    resetEvents();
    sForwardCount = 0;
    sEnv = &kFakeEnv;
    sRealOnRequest = fakeRealOnRequest;
    pthread_mutex_lock(&sRcLock);
    memset(sLastApplySession, 0, sizeof(sLastApplySession));
    memset(sLastApplySessionValid, 0, sizeof(sLastApplySessionValid));
    pthread_mutex_unlock(&sRcLock);
}

static int checkFixedCapability(const RIL_RadioCapability *capability,
                                RIL_SOCKET_ID socketId, int session,
                                int phase, int status)
{
    int expectedRaf = socketId == RIL_SOCKET_1
            ? SLOT0_NATIVE_RAF : SLOT1_NATIVE_RAF;
    const char *expectedUuid = socketId == RIL_SOCKET_1
            ? SLOT0_MODEM_UUID : SLOT1_MODEM_UUID;

    CHECK(capability->version == RIL_RADIO_CAPABILITY_VERSION);
    CHECK(capability->session == session);
    CHECK(capability->phase == phase);
    CHECK(capability->rat == expectedRaf);
    CHECK(strcmp(capability->logicalModemUuid, expectedUuid) == 0);
    CHECK(capability->status == status);
    return 0;
}

static RIL_RadioCapability makeSetRequest(int session, int phase, int status)
{
    RIL_RadioCapability request;

    memset(&request, 0, sizeof(request));
    /* The Q HIDL bridge leaves native version at zero and passes a framework-
     * encoded RAF. Both values must be ignored by the shim. */
    request.version = 0;
    request.session = session;
    request.phase = phase;
    request.rat = 0x12345678;
    memcpy(request.logicalModemUuid, "requested_other_modem",
           sizeof("requested_other_modem"));
    request.status = status;
    return request;
}

static int testGet(void)
{
    resetEvents();
    onRequestShim(RIL_REQUEST_GET_RADIO_CAPABILITY, NULL, 0,
                  (RIL_Token)0x1, RIL_SOCKET_1);
    CHECK(sEventCount == 1);
    CHECK(sEvents[0].kind == EVENT_COMPLETE);
    CHECK(sEvents[0].error == RIL_E_SUCCESS);
    CHECK(sEvents[0].length == sizeof(RIL_RadioCapability));
    CHECK(sEvents[0].hasCapability);
    CHECK(checkFixedCapability(&sEvents[0].capability, RIL_SOCKET_1, 0,
                               RC_PHASE_CONFIGURED, RC_STATUS_NONE) == 0);

    resetEvents();
    onRequestShim(RIL_REQUEST_GET_RADIO_CAPABILITY, NULL, 0,
                  (RIL_Token)0x2, RIL_SOCKET_2);
    CHECK(sEventCount == 1);
    CHECK(sEvents[0].error == RIL_E_SUCCESS);
    CHECK(checkFixedCapability(&sEvents[0].capability, RIL_SOCKET_2, 0,
                               RC_PHASE_CONFIGURED, RC_STATUS_NONE) == 0);
    CHECK(sForwardCount == 0);
    return 0;
}

static int testSetPhasesAndOrder(void)
{
    RIL_RadioCapability request;

    request = makeSetRequest(41, RC_PHASE_START, RC_STATUS_NONE);
    resetEvents();
    onRequestShim(RIL_REQUEST_SET_RADIO_CAPABILITY, &request, sizeof(request),
                  (RIL_Token)0x3, RIL_SOCKET_1);
    CHECK(sEventCount == 1);
    CHECK(sEvents[0].kind == EVENT_COMPLETE);
    CHECK(sEvents[0].error == RIL_E_SUCCESS);
    CHECK(checkFixedCapability(&sEvents[0].capability, RIL_SOCKET_1, 41,
                               RC_PHASE_START, RC_STATUS_SUCCESS) == 0);

    request = makeSetRequest(41, RC_PHASE_APPLY, RC_STATUS_NONE);
    resetEvents();
    onRequestShim(RIL_REQUEST_SET_RADIO_CAPABILITY, &request, sizeof(request),
                  (RIL_Token)0x4, RIL_SOCKET_1);
    CHECK(sEventCount == 2);
    CHECK(sEvents[0].kind == EVENT_COMPLETE);
    CHECK(sEvents[1].kind == EVENT_UNSOL);
    CHECK(sEvents[0].error == RIL_E_SUCCESS);
    CHECK(sEvents[1].unsolResponse == RIL_UNSOL_RADIO_CAPABILITY);
    CHECK(sEvents[1].socketId == RIL_SOCKET_1);
    CHECK(checkFixedCapability(&sEvents[0].capability, RIL_SOCKET_1, 41,
                               RC_PHASE_APPLY, RC_STATUS_SUCCESS) == 0);
    CHECK(checkFixedCapability(&sEvents[1].capability, RIL_SOCKET_1, 41,
                               RC_PHASE_UNSOL_RSP, RC_STATUS_SUCCESS) == 0);

    /* The duplicate gets a solicited completion but cannot decrement the
     * framework's APPLY counter with a second indication. */
    resetEvents();
    onRequestShim(RIL_REQUEST_SET_RADIO_CAPABILITY, &request, sizeof(request),
                  (RIL_Token)0x5, RIL_SOCKET_1);
    CHECK(sEventCount == 1);
    CHECK(sEvents[0].kind == EVENT_COMPLETE);

    /* A genuinely new transaction on the same socket must get its own URC. */
    request = makeSetRequest(42, RC_PHASE_APPLY, RC_STATUS_NONE);
    resetEvents();
    onRequestShim(RIL_REQUEST_SET_RADIO_CAPABILITY, &request, sizeof(request),
                  (RIL_Token)0x51, RIL_SOCKET_1);
    CHECK(sEventCount == 2);
    CHECK(sEvents[0].kind == EVENT_COMPLETE);
    CHECK(sEvents[1].kind == EVENT_UNSOL);
    CHECK(checkFixedCapability(&sEvents[1].capability, RIL_SOCKET_1, 42,
                               RC_PHASE_UNSOL_RSP, RC_STATUS_SUCCESS) == 0);

    /* Duplicate suppression is per socket, not global across the DSDS pair. */
    request = makeSetRequest(41, RC_PHASE_APPLY, RC_STATUS_NONE);
    resetEvents();
    onRequestShim(RIL_REQUEST_SET_RADIO_CAPABILITY, &request, sizeof(request),
                  (RIL_Token)0x6, RIL_SOCKET_2);
    CHECK(sEventCount == 2);
    CHECK(sEvents[1].kind == EVENT_UNSOL);
    CHECK(sEvents[1].socketId == RIL_SOCKET_2);
    CHECK(checkFixedCapability(&sEvents[1].capability, RIL_SOCKET_2, 41,
                               RC_PHASE_UNSOL_RSP, RC_STATUS_SUCCESS) == 0);

    request = makeSetRequest(41, RC_PHASE_FINISH, RC_STATUS_FAIL);
    resetEvents();
    onRequestShim(RIL_REQUEST_SET_RADIO_CAPABILITY, &request, sizeof(request),
                  (RIL_Token)0x7, RIL_SOCKET_2);
    CHECK(sEventCount == 1);
    CHECK(sEvents[0].kind == EVENT_COMPLETE);
    CHECK(checkFixedCapability(&sEvents[0].capability, RIL_SOCKET_2, 41,
                               RC_PHASE_FINISH, RC_STATUS_FAIL) == 0);
    CHECK(sForwardCount == 0);
    return 0;
}

static int expectRejectedSet(void *data, size_t datalen,
                             RIL_SOCKET_ID socketId)
{
    resetEvents();
    onRequestShim(RIL_REQUEST_SET_RADIO_CAPABILITY, data, datalen,
                  (RIL_Token)0x8, socketId);
    CHECK(sEventCount == 1);
    CHECK(sEvents[0].kind == EVENT_COMPLETE);
    CHECK(sEvents[0].error == RIL_E_INVALID_ARGUMENTS);
    CHECK(!sEvents[0].hasCapability);
    CHECK(sForwardCount == 0);
    return 0;
}

static int testNegativeAndForwarding(void)
{
    RIL_RadioCapability request = makeSetRequest(51, RC_PHASE_START,
                                                 RC_STATUS_NONE);

    CHECK(expectRejectedSet(NULL, 0, RIL_SOCKET_1) == 0);
    CHECK(expectRejectedSet(&request, sizeof(request) - 1, RIL_SOCKET_1) == 0);
    CHECK(expectRejectedSet(&request, sizeof(request) + 1, RIL_SOCKET_1) == 0);
    request.phase = RC_PHASE_CONFIGURED;
    CHECK(expectRejectedSet(&request, sizeof(request), RIL_SOCKET_1) == 0);
    request.phase = RC_PHASE_UNSOL_RSP;
    CHECK(expectRejectedSet(&request, sizeof(request), RIL_SOCKET_1) == 0);
    request.phase = RC_PHASE_START;
    CHECK(expectRejectedSet(&request, sizeof(request),
                            (RIL_SOCKET_ID)RIL_SOCKET_NUM) == 0);

    resetEvents();
    onRequestShim(RIL_REQUEST_GET_RADIO_CAPABILITY, NULL, 0,
                  (RIL_Token)0x9, (RIL_SOCKET_ID)RIL_SOCKET_NUM);
    CHECK(sEventCount == 1);
    CHECK(sEvents[0].error == RIL_E_INVALID_ARGUMENTS);
    CHECK(sForwardCount == 0);

    resetEvents();
    onRequestShim(RIL_REQUEST_GET_SIM_STATUS, NULL, 0,
                  (RIL_Token)0xa, RIL_SOCKET_1);
    CHECK(sEventCount == 0);
    CHECK(sForwardCount == 1);
    return 0;
}

int main(void)
{
    resetHarness();
    CHECK(testGet() == 0);
    CHECK(testSetPhasesAndOrder() == 0);
    CHECK(testNegativeAndForwarding() == 0);
    puts("radio capability shim tests: PASS");
    return 0;
}
