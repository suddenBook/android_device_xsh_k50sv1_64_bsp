/*
 * SPDX-FileCopyrightText: 2019 The Android Open Source Project
 * SPDX-FileCopyrightText: 2024 The LineageOS Project
 * SPDX-License-Identifier: Apache-2.0
 */

#include "SensorsSubHal.h"
#include "PollPolicy.h"

#include <android-base/logging.h>
#include <android/hardware/sensors/2.0/types.h>
#include <utils/SystemClock.h>

#include <array>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <sstream>
#include <unistd.h>

using ::android::hardware::sensors::V1_0::SensorFlagBits;
using ::android::hardware::sensors::V1_0::implementation::convertFromRateLevel;
using ::android::hardware::sensors::V1_0::implementation::convertFromSensor;
using ::android::hardware::sensors::V1_0::implementation::convertFromSensorEvent;
using ::android::hardware::sensors::V1_0::implementation::convertFromSharedMemInfo;
using ::android::hardware::sensors::V1_0::implementation::convertToSensorEvent;
using ::android::hardware::sensors::V2_0::implementation::ISensorsSubHal;
using ::android::hardware::sensors::V2_0::subhal::implementation::SensorsSubHal;

namespace android {
namespace hardware {
namespace sensors {
namespace V2_0 {
namespace subhal {
namespace implementation {

using ::android::hardware::Void;

static Result resultFromStatus(status_t err) {
    switch (err) {
        case OK: return Result::OK;
        case PERMISSION_DENIED: return Result::PERMISSION_DENIED;
        case NO_MEMORY: return Result::NO_MEMORY;
        case BAD_VALUE: return Result::BAD_VALUE;
        default: return Result::INVALID_OPERATION;
    }
}

SensorsSubHal::SensorsSubHal() {
    const hw_module_t* module = nullptr;
    mInitStatus = hw_get_module(SENSORS_HARDWARE_MODULE_ID, &module);
    mSensorModule = reinterpret_cast<sensors_module_t*>(const_cast<hw_module_t*>(module));
    if (mInitStatus != OK || mSensorModule == nullptr ||
        mSensorModule->get_sensors_list == nullptr) {
        LOG(ERROR) << "Cannot load the board sensors module: " << mInitStatus;
        mInitStatus = NO_INIT;
        return;
    }

    mInitStatus = sensors_open_1(&mSensorModule->common, &mSensorDevice);
    if (mInitStatus != OK || mSensorDevice == nullptr) {
        LOG(ERROR) << "Cannot open the board sensors device: " << mInitStatus;
        mInitStatus = NO_INIT;
        return;
    }
    if (getHalDeviceVersion() < SENSORS_DEVICE_API_VERSION_1_3 ||
        mSensorDevice->poll == nullptr || mSensorDevice->activate == nullptr ||
        mSensorDevice->batch == nullptr || mSensorDevice->flush == nullptr) {
        LOG(ERROR) << "Incomplete legacy sensors 1.3 contract";
        mInitStatus = NO_INIT;
        return;
    }
    mInitStatus = enumerateSensors();
    // Polling begins only after initialize publishes a usable callback.
}

int SensorsSubHal::getHalDeviceVersion() const {
    return mSensorDevice ? mSensorDevice->common.version : -1;
}

bool SensorsSubHal::isWakeUpSensor(int32_t handle) {
    const auto sensor = mSensors.find(handle);
    return sensor != mSensors.end() &&
           (sensor->second.flags & static_cast<uint32_t>(SensorFlagBits::WAKE_UP));
}

status_t SensorsSubHal::enumerateSensors() {
    const sensor_t* list = nullptr;
    const int count = mSensorModule->get_sensors_list(mSensorModule, &list);
    if (count <= 0 || list == nullptr) {
        LOG(ERROR) << "Invalid board sensor list: " << count;
        return NO_INIT;
    }
    for (int i = 0; i < count; ++i) {
        SensorInfo sensor;
        convertFromSensor(list[i], &sensor);
        mSensors.emplace(sensor.sensorHandle, sensor);
    }
    return OK;
}

void SensorsSubHal::pollForEvents() {
    std::array<sensors_event_t, kPollMaxBufferSize> data;
    unsigned failures = 0;
    for (;;) {
        uint64_t epoch;
        {
            std::lock_guard<std::mutex> lock(mMutex);
            epoch = mEpoch;
        }
        const int count = mSensorDevice->poll(
                reinterpret_cast<sensors_poll_device_t*>(mSensorDevice),
                data.data(), data.size());
        if (count == -EINTR) continue;
        if (count <= 0 || count > kPollMaxBufferSize) {
            if (failures < 31) ++failures;
            if (failures == 1 || (failures & (failures - 1)) == 0) {
                LOG(ERROR) << "Legacy sensors poll returned " << count;
            }
            std::this_thread::sleep_for(
                    std::chrono::milliseconds(sensors_legacy::retryDelayMs(failures)));
            continue;
        }
        failures = 0;
        std::lock_guard<std::mutex> lock(mMutex);
        if (mCallback == nullptr || epoch != mEpoch) continue;
        std::vector<Event> events;
        events.reserve(count);
        bool wakeup = false;
        for (int i = 0; i < count; ++i) {
            Event event;
            convertFromSensorEvent(data[i], &event);
            const auto active = mActiveSince.find(event.sensorHandle);
            if (mSensors.find(event.sensorHandle) == mSensors.end() ||
                active == mActiveSince.end()) continue;
            // Flush metadata has no sample timestamp. The session epoch still
            // prevents a pre-initialize poll batch from entering the new FMQ.
            if (event.sensorType != V1_0::SensorType::META_DATA &&
                !sensors_legacy::belongsToSession(epoch, mEpoch, event.timestamp,
                                                  active->second)) continue;
            wakeup |= isWakeUpSensor(event.sensorHandle);
            events.push_back(event);
        }
        if (!events.empty()) {
            auto wakelock = mCallback->createScopedWakelock(wakeup);
            mCallback->postEvents(events, std::move(wakelock));
        }
    }
}

Return<void> SensorsSubHal::getSensorsList(ISensors::getSensorsList_cb callback) {
    std::vector<SensorInfo> sensors;
    for (const auto& sensor : mSensors) sensors.push_back(sensor.second);
    callback(sensors);
    return Void();
}

Result SensorsSubHal::setOperationModeLocked(OperationMode mode) {
    if (!isReady()) return Result::INVALID_OPERATION;
    if (mode == mCurrentOperationMode) return Result::OK;
    if (getHalDeviceVersion() < SENSORS_DEVICE_API_VERSION_1_4 ||
        mSensorModule->set_operation_mode == nullptr) return Result::INVALID_OPERATION;
    const status_t status = mSensorModule->set_operation_mode(static_cast<uint32_t>(mode));
    if (status == OK) mCurrentOperationMode = mode;
    return resultFromStatus(status);
}

Return<Result> SensorsSubHal::setOperationMode(OperationMode mode) {
    std::lock_guard<std::mutex> lock(mMutex);
    return setOperationModeLocked(mode);
}

Return<Result> SensorsSubHal::activate(int32_t handle, bool enabled) {
    std::lock_guard<std::mutex> lock(mMutex);
    if (!isReady()) return Result::INVALID_OPERATION;
    if (mSensors.find(handle) == mSensors.end()) return Result::BAD_VALUE;
    if (enabled && mCallback == nullptr) return Result::INVALID_OPERATION;
    const status_t status = mSensorDevice->activate(
            reinterpret_cast<sensors_poll_device_t*>(mSensorDevice), handle, enabled);
    if (status == OK) {
        if (enabled) {
            // Repeated activation must not discard already active samples.
            mActiveSince.emplace(handle, android::elapsedRealtimeNano());
        } else {
            mActiveSince.erase(handle);
        }
    }
    return resultFromStatus(status);
}

Return<Result> SensorsSubHal::batch(int32_t handle, int64_t period, int64_t latency) {
    std::lock_guard<std::mutex> lock(mMutex);
    if (!isReady()) return Result::INVALID_OPERATION;
    if (mSensors.find(handle) == mSensors.end() || period < 0 || latency < 0)
        return Result::BAD_VALUE;
    return resultFromStatus(mSensorDevice->batch(mSensorDevice, handle, 0, period, latency));
}

Return<Result> SensorsSubHal::flush(int32_t handle) {
    std::lock_guard<std::mutex> lock(mMutex);
    if (!isReady()) return Result::INVALID_OPERATION;
    if (mActiveSince.find(handle) == mActiveSince.end()) return Result::BAD_VALUE;
    return resultFromStatus(mSensorDevice->flush(mSensorDevice, handle));
}

Return<Result> SensorsSubHal::injectSensorData(const Event& event) {
    std::lock_guard<std::mutex> lock(mMutex);
    if (!isReady() || getHalDeviceVersion() < SENSORS_DEVICE_API_VERSION_1_4 ||
        mSensorDevice->inject_sensor_data == nullptr) return Result::INVALID_OPERATION;
    if (mSensors.find(event.sensorHandle) == mSensors.end()) return Result::BAD_VALUE;
    sensors_event_t out = {};
    convertToSensorEvent(event, &out);
    return resultFromStatus(mSensorDevice->inject_sensor_data(mSensorDevice, &out));
}

bool SensorsSubHal::supportsDirectChannels() const {
    return isReady() && getHalDeviceVersion() >= SENSORS_DEVICE_API_VERSION_1_4 &&
           mSensorDevice->register_direct_channel != nullptr &&
           mSensorDevice->config_direct_report != nullptr;
}

Return<void> SensorsSubHal::registerDirectChannel(const SharedMemInfo& mem,
                                                 ISensors::registerDirectChannel_cb callback) {
    std::lock_guard<std::mutex> lock(mMutex);
    if (!supportsDirectChannels()) {
        callback(Result::INVALID_OPERATION, -1);
        return Void();
    }
    sensors_direct_mem_t out = {};
    if (!convertFromSharedMemInfo(mem, &out)) {
        callback(Result::BAD_VALUE, -1);
        return Void();
    }
    const int channel = mSensorDevice->register_direct_channel(mSensorDevice, &out, -1);
    if (channel > 0) mDirectChannels.insert(channel);
    callback(channel > 0 ? Result::OK : resultFromStatus(channel ? channel : BAD_VALUE),
             channel > 0 ? channel : -1);
    return Void();
}

Return<Result> SensorsSubHal::unregisterDirectChannel(int32_t channel) {
    std::lock_guard<std::mutex> lock(mMutex);
    if (!supportsDirectChannels()) return Result::INVALID_OPERATION;
    if (mDirectChannels.find(channel) == mDirectChannels.end()) return Result::BAD_VALUE;
    const int status = mSensorDevice->register_direct_channel(mSensorDevice, nullptr, channel);
    if (status == OK) mDirectChannels.erase(channel);
    return resultFromStatus(status);
}

Return<void> SensorsSubHal::configDirectReport(int32_t handle, int32_t channel, RateLevel rate,
                                              ISensors::configDirectReport_cb callback) {
    std::lock_guard<std::mutex> lock(mMutex);
    if (!supportsDirectChannels()) {
        callback(Result::INVALID_OPERATION, -1);
        return Void();
    }
    sensors_direct_cfg_t cfg = {};
    cfg.rate_level = convertFromRateLevel(rate);
    if (cfg.rate_level < 0 || mDirectChannels.find(channel) == mDirectChannels.end() ||
        (mSensors.find(handle) == mSensors.end() && !(handle == -1 && rate == RateLevel::STOP))) {
        callback(Result::BAD_VALUE, -1);
        return Void();
    }
    const int result = mSensorDevice->config_direct_report(mSensorDevice, handle, channel, &cfg);
    if (rate == RateLevel::STOP) {
        callback(resultFromStatus(result), -1);
    } else {
        callback(result > 0 ? Result::OK : resultFromStatus(result ? result : BAD_VALUE), result);
    }
    return Void();
}

Return<void> SensorsSubHal::debug(const hidl_handle& fd, const hidl_vec<hidl_string>&) {
    if (fd.getNativeHandle() == nullptr || fd->numFds < 1) return Void();
    const int duplicate = dup(fd->data[0]);
    if (duplicate < 0) return Void();
    FILE* out = fdopen(duplicate, "w");
    if (out == nullptr) {
        close(duplicate);
        return Void();
    }
    std::lock_guard<std::mutex> lock(mMutex);
    fprintf(out, "Legacy sensors status: %d; session: %llu; sensors: %zu; active: %zu\n",
            mInitStatus, static_cast<unsigned long long>(mEpoch),
            mSensors.size(), mActiveSince.size());
    for (const auto& sensor : mSensors) {
        fprintf(out, "  %d: %s\n", sensor.first, sensor.second.name.c_str());
    }
    fclose(out);
    return Void();
}

Return<Result> SensorsSubHal::initialize(const sp<IHalProxyCallback>& callback) {
    std::lock_guard<std::mutex> lock(mMutex);
    if (!isReady()) return Result::INVALID_OPERATION;
    if (callback == nullptr) return Result::BAD_VALUE;
    // Invalidate any batch already being read from the old framework session.
    ++mEpoch;
    mCallback = nullptr;
    Result result = Result::OK;
    for (auto active = mActiveSince.begin(); active != mActiveSince.end();) {
        const int status = mSensorDevice->activate(
                reinterpret_cast<sensors_poll_device_t*>(mSensorDevice), active->first, false);
        if (status != OK) {
            result = resultFromStatus(status);
            ++active;
        } else {
            active = mActiveSince.erase(active);
        }
    }
    for (auto channel = mDirectChannels.begin(); channel != mDirectChannels.end();) {
        const int status = mSensorDevice->register_direct_channel(mSensorDevice, nullptr, *channel);
        if (status != OK) {
            result = resultFromStatus(status);
            ++channel;
        } else {
            channel = mDirectChannels.erase(channel);
        }
    }
    const Result modeResult = setOperationModeLocked(OperationMode::NORMAL);
    if (modeResult != Result::OK) result = modeResult;
    if (result != Result::OK) return result;
    mCallback = callback;
    if (!mPollThread.joinable()) mPollThread = std::thread(&SensorsSubHal::pollForEvents, this);
    return Result::OK;
}

}  // namespace implementation
}  // namespace subhal
}  // namespace V2_0
}  // namespace sensors
}  // namespace hardware
}  // namespace android

ISensorsSubHal* sensorsHalGetSubHal(uint32_t* version) {
    // Legacy poll has no cancellation primitive. Keep its device, callback
    // synchronization and thread alive until the service process exits.
    static SensorsSubHal* const subHal = new SensorsSubHal;
    *version = SUB_HAL_2_0_VERSION;
    return subHal->isReady() ? subHal : nullptr;
}
