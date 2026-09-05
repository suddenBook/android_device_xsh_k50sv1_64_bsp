/*
 * Copyright (C) 2019 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "ScopedWakelock.h"
#include <utils/SystemClock.h>

namespace android {
namespace hardware {
namespace sensors {
namespace V2_0 {
namespace implementation {

int64_t getTimeNow() {
    return android::elapsedRealtimeNano();
}

ScopedWakelock::ScopedWakelock(ScopedWakelock&& other) noexcept
    : mRefCounter(other.mRefCounter), mCreatedAtTimeNs(other.mCreatedAtTimeNs),
      mLocked(other.mLocked) {
    other.mLocked = false;
}

ScopedWakelock& ScopedWakelock::operator=(ScopedWakelock&& other) noexcept {
    if (this != &other) {
        if (mLocked) {
            mRefCounter->decrementRefCountAndMaybeReleaseWakelock(1, mCreatedAtTimeNs);
        }
        mRefCounter = other.mRefCounter;
        mCreatedAtTimeNs = other.mCreatedAtTimeNs;
        mLocked = other.mLocked;
        other.mLocked = false;
    }
    return *this;
}

ScopedWakelock::ScopedWakelock(IScopedWakelockRefCounter* refCounter, bool locked)
    : mRefCounter(refCounter), mLocked(locked) {
    if (mLocked) {
        mLocked = mRefCounter->incrementRefCountAndMaybeAcquireWakelock(1, &mCreatedAtTimeNs);
    }
}

ScopedWakelock::~ScopedWakelock() {
    if (mLocked) {
        mRefCounter->decrementRefCountAndMaybeReleaseWakelock(1, mCreatedAtTimeNs);
    }
}

}  // namespace implementation
}  // namespace V2_0
}  // namespace sensors
}  // namespace hardware
}  // namespace android