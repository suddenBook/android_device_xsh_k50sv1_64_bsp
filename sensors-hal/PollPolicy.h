/* SPDX-License-Identifier: Apache-2.0 */
#pragma once

#include <cstdint>

namespace sensors_legacy {

// poll() errors and empty results must not turn the service into a busy loop.
inline unsigned retryDelayMs(unsigned failures) {
    return failures >= 7 ? 1000 : 20U << (failures ? failures - 1 : 0);
}

inline bool belongsToSession(uint64_t pollEpoch, uint64_t currentEpoch,
                             int64_t timestamp, int64_t activatedAt) {
    return pollEpoch == currentEpoch && timestamp >= activatedAt;
}

}  // namespace sensors_legacy
