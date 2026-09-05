/*
 * SPDX-FileCopyrightText: 2019 The Android Open Source Project
 * SPDX-FileCopyrightText: 2024 The LineageOS Project
 * SPDX-License-Identifier: Apache-2.0
 */

#pragma once

#include <hardware/sensors.h>
#include <sensors/convert.h>
#include <map>
#include <mutex>
#include <set>
#include <thread>
#include <vector>

#include "SubHal.h"

namespace android {
namespace hardware {
namespace sensors {
namespace V2_0 {
namespace subhal {
namespace implementation {

using ::android::hardware::sensors::V1_0::Event;
using ::android::hardware::sensors::V1_0::OperationMode;
using ::android::hardware::sensors::V1_0::RateLevel;
using ::android::hardware::sensors::V1_0::Result;
using ::android::hardware::sensors::V1_0::SensorInfo;
using ::android::hardware::sensors::V1_0::SharedMemInfo;
using ::android::hardware::sensors::V2_0::implementation::IHalProxyCallback;
using ::android::hardware::sensors::V2_0::implementation::ISensorsSubHal;

class SensorsSubHal : public ISensorsSubHal {
  public:
    SensorsSubHal();

    bool isReady() const { return mInitStatus == OK; }

    Return<void> getSensorsList(ISensors::getSensorsList_cb _hidl_cb);
    Return<Result> injectSensorData(const Event& event);
    Return<Result> initialize(const sp<IHalProxyCallback>& halProxyCallback);

    virtual Return<Result> setOperationMode(OperationMode mode);

    Return<Result> activate(int32_t sensorHandle, bool enabled);

    Return<Result> batch(int32_t sensorHandle, int64_t samplingPeriodNs,
                         int64_t maxReportLatencyNs);

    Return<Result> flush(int32_t sensorHandle);

    Return<void> registerDirectChannel(const SharedMemInfo& mem,
                                       ISensors::registerDirectChannel_cb _hidl_cb);

    Return<Result> unregisterDirectChannel(int32_t channelHandle);

    Return<void> configDirectReport(int32_t sensorHandle, int32_t channelHandle, RateLevel rate,
                                    ISensors::configDirectReport_cb _hidl_cb);

    Return<void> debug(const hidl_handle& fd, const hidl_vec<hidl_string>& args);

    const std::string getName() { return "Sensors1SubHal"; }

  private:
    std::map<int32_t, SensorInfo> mSensors;
    std::mutex mMutex;
    sp<IHalProxyCallback> mCallback;
    OperationMode mCurrentOperationMode = OperationMode::NORMAL;
    status_t mInitStatus = NO_INIT;
    std::map<int32_t, int64_t> mActiveSince;
    std::set<int32_t> mDirectChannels;
    uint64_t mEpoch = 0;

    static constexpr int32_t kPollMaxBufferSize = 128;
    // The singleton and legacy device live until process exit. The legacy poll
    // API cannot be cancelled safely by closing a device on another thread.
    std::thread mPollThread;
    sensors_poll_device_1_t* mSensorDevice = nullptr;
    struct sensors_module_t* mSensorModule = nullptr;

    bool isWakeUpSensor(int32_t handle);
    int getHalDeviceVersion() const;
    status_t enumerateSensors();
    void pollForEvents();
    Result setOperationModeLocked(OperationMode mode);
    bool supportsDirectChannels() const;
};

}  // namespace implementation
}  // namespace subhal
}  // namespace V2_0
}  // namespace sensors
}  // namespace hardware
}  // namespace android
