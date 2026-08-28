/* Host-test fixture: a real relocatable DSO with the same two callback imports
 * that mtk-rilproxy.so uses. Its PLT/GOT is patched by the production scanner. */
#include <stddef.h>

#include <telephony/ril.h>

/* ril.h hides the libril entry points when RIL_SHLIB is defined because a
 * normal vendor RIL calls through RIL_Env. This fixture models the MTK proxy's
 * unusual direct imports, so declare those two imports explicitly. */
extern void RIL_onUnsolicitedResponse(int response, const void *data,
                                      size_t datalen,
                                      RIL_SOCKET_ID socketId);
extern void RIL_onRequestComplete(RIL_Token token, RIL_Errno error,
                                  void *response, size_t responselen);

void fakeRilEmitUnsolicited(int response, const void *data, size_t datalen,
                            RIL_SOCKET_ID socketId)
{
    RIL_onUnsolicitedResponse(response, data, datalen, socketId);
}

void fakeRilComplete(RIL_Token token, RIL_Errno error, void *response,
                     size_t responselen)
{
    RIL_onRequestComplete(token, error, response, responselen);
}
