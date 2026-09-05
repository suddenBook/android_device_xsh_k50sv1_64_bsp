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

#include <android/hardware/sensors/2.0/ISensors.h>
#include <hidl/HidlTransportSupport.h>
#include <log/log.h>
#include <utils/StrongPointer.h>
#include <cstdlib>
#include <unistd.h>
#include "HalProxy.h"

using android::hardware::configureRpcThreadpool;
using android::hardware::joinRpcThreadpool;
using android::hardware::sensors::V2_0::ISensors;
using android::hardware::sensors::V2_0::implementation::HalProxy;

int main(int /* argc */, char** /* argv */) {
    configureRpcThreadpool(1, true);

    uint32_t version = 0;
    ISensorsSubHal* subHal = sensorsHalGetSubHal(&version);
    if (subHal == nullptr || version != SUB_HAL_2_0_VERSION) {
        ALOGE("Board legacy sensors backend is unavailable");
        return EXIT_FAILURE;
    }
    std::vector<ISensorsSubHal*> subHals{subHal};
    android::sp<ISensors> halProxy = new HalProxy(subHals);
    if (halProxy->registerAsService() != ::android::OK) {
        ALOGE("Failed to register Sensors HAL instance");
        return -1;
    }

    joinRpcThreadpool();
    // The legacy poll API has no cancellation contract. Terminate the process
    // if Binder unexpectedly stops; never destroy an object still used by poll.
    _exit(EXIT_FAILURE);
}
