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

#include "HalProxy.h"

#include "SubHal.h"

#include <android/hardware/sensors/2.0/types.h>

#include <android-base/file.h>
#include <android-base/unique_fd.h>
#include <sstream>
#include "hardware_legacy/power.h"

#include <dlfcn.h>

#include <cinttypes>
#include <cmath>
#include <fstream>
#include <functional>
#include <thread>

namespace android {
namespace hardware {
namespace sensors {
namespace V2_0 {
namespace implementation {

using ::android::hardware::sensors::V2_0::EventQueueFlagBits;
using ::android::hardware::sensors::V2_0::WakeLockQueueFlagBits;
using ::android::hardware::sensors::V2_0::implementation::getTimeNow;
using ::android::hardware::sensors::V2_0::implementation::kWakelockTimeoutNs;

typedef ISensorsSubHal*(SensorsHalGetSubHalFunc)(uint32_t*);

static constexpr int32_t kBitsAfterSubHalIndex = 24;

/**
 * Set the subhal index as first byte of sensor handle and return this modified version.
 *
 * @param sensorHandle The sensor handle to modify.
 * @param subHalIndex The index in the hal proxy of the sub hal this sensor belongs to.
 *
 * @return The modified sensor handle.
 */
int32_t setSubHalIndex(int32_t sensorHandle, size_t subHalIndex) {
    return sensorHandle | (static_cast<int32_t>(subHalIndex) << kBitsAfterSubHalIndex);
}

/**
 * Extract the subHalIndex from sensorHandle.
 *
 * @param sensorHandle The sensorHandle to extract from.
 *
 * @return The subhal index.
 */
size_t extractSubHalIndex(int32_t sensorHandle) {
    return static_cast<size_t>(sensorHandle >> kBitsAfterSubHalIndex);
}

/**
 * Convert nanoseconds to milliseconds.
 *
 * @param nanos The nanoseconds input.
 *
 * @return The milliseconds count.
 */
int64_t msFromNs(int64_t nanos) {
    constexpr int64_t nanosecondsInAMillsecond = 1000000;
    return nanos / nanosecondsInAMillsecond;
}



HalProxy::HalProxy(std::vector<ISensorsSubHal*>& subHalList) : mSubHalList(subHalList) {
    init();
}

HalProxy::~HalProxy() {
    stopThreads();
}

Return<void> HalProxy::getSensorsList(getSensorsList_cb _hidl_cb) {
    std::vector<SensorInfo> sensors;
    for (const auto& iter : mSensors) {
        sensors.push_back(iter.second);
    }
    _hidl_cb(sensors);
    return Void();
}

Return<Result> HalProxy::setOperationMode(OperationMode mode) {
    Result result = Result::OK;
    size_t subHalIndex;
    for (subHalIndex = 0; subHalIndex < mSubHalList.size(); subHalIndex++) {
        ISensorsSubHal* subHal = mSubHalList[subHalIndex];
        result = subHal->setOperationMode(mode);
        if (result != Result::OK) {
            ALOGE("setOperationMode failed for SubHal: %s", subHal->getName().c_str());
            break;
        }
    }
    if (result != Result::OK) {
        // Reset the subhal operation modes that have been flipped
        for (size_t i = 0; i < subHalIndex; i++) {
            ISensorsSubHal* subHal = mSubHalList[i];
            subHal->setOperationMode(mCurrentOperationMode);
        }
    } else {
        mCurrentOperationMode = mode;
    }
    return result;
}

Return<Result> HalProxy::activate(int32_t sensorHandle, bool enabled) {
    if (!isSubHalIndexValid(sensorHandle)) {
        return Result::BAD_VALUE;
    }
    return getSubHalForSensorHandle(sensorHandle)
            ->activate(clearSubHalIndex(sensorHandle), enabled);
}

Return<Result> HalProxy::initialize(
        const ::android::hardware::MQDescriptorSync<Event>& eventQueueDescriptor,
        const ::android::hardware::MQDescriptorSync<uint32_t>& wakeLockDescriptor,
        const sp<ISensorsCallback>& sensorsCallback) {
    std::lock_guard<std::mutex> initializeLock(mInitializeMutex);
    stopThreads();
    resetSharedWakelock();
    disableAllSensors();
    {
        std::lock_guard<std::mutex> lock(mEventQueueWriteMutex);
        mPendingWriteEventsQueue = std::queue<std::pair<std::vector<Event>, size_t>>();
        mSizePendingWriteEventsQueue = 0;
    }
    {
        std::lock_guard<std::mutex> lock(mDynamicSensorsMutex);
        mDynamicSensors.clear();
        mDynamicSensorsCallback = sensorsCallback;
    }
    if (mEventQueueFlag != nullptr) EventFlag::deleteEventFlag(&mEventQueueFlag);
    if (mWakelockQueueFlag != nullptr) EventFlag::deleteEventFlag(&mWakelockQueueFlag);
    mEventQueue = std::make_unique<EventMessageQueue>(eventQueueDescriptor, true);
    mWakeLockQueue = std::make_unique<WakeLockMessageQueue>(wakeLockDescriptor, true);
    if (!sensorsCallback || !mEventQueue->isValid() || !mWakeLockQueue->isValid() ||
        EventFlag::createEventFlag(mEventQueue->getEventFlagWord(), &mEventQueueFlag) != OK ||
        EventFlag::createEventFlag(mWakeLockQueue->getEventFlagWord(), &mWakelockQueueFlag) != OK) {
        if (mEventQueueFlag != nullptr) EventFlag::deleteEventFlag(&mEventQueueFlag);
        if (mWakelockQueueFlag != nullptr) EventFlag::deleteEventFlag(&mWakelockQueueFlag);
        return Result::BAD_VALUE;
    }
    for (size_t i = 0; i < mSubHalList.size(); ++i) {
        const Result result = mSubHalList[i]->initialize(mSubHalCallbacks[i]);
        if (result != Result::OK) {
            ALOGE("Subhal '%s' failed to initialize.", mSubHalList[i]->getName().c_str());
            return result;
        }
    }
    mCurrentOperationMode = OperationMode::NORMAL;
    mThreadsRun.store(true);
    mPendingWritesThread = std::thread(startPendingWritesThread, this);
    mWakelockThread = std::thread(startWakelockThread, this);
    return Result::OK;
}

Return<Result> HalProxy::batch(int32_t sensorHandle, int64_t samplingPeriodNs,
                               int64_t maxReportLatencyNs) {
    if (!isSubHalIndexValid(sensorHandle)) {
        return Result::BAD_VALUE;
    }
    return getSubHalForSensorHandle(sensorHandle)
            ->batch(clearSubHalIndex(sensorHandle), samplingPeriodNs, maxReportLatencyNs);
}

Return<Result> HalProxy::flush(int32_t sensorHandle) {
    if (!isSubHalIndexValid(sensorHandle)) {
        return Result::BAD_VALUE;
    }
    return getSubHalForSensorHandle(sensorHandle)->flush(clearSubHalIndex(sensorHandle));
}

Return<Result> HalProxy::injectSensorData(const Event& event) {
    Result result = Result::OK;
    if (mCurrentOperationMode == OperationMode::NORMAL &&
        event.sensorType != V1_0::SensorType::ADDITIONAL_INFO) {
        ALOGE("An event with type != ADDITIONAL_INFO passed to injectSensorData while operation"
              " mode was NORMAL.");
        result = Result::BAD_VALUE;
    }
    if (result == Result::OK) {
        Event subHalEvent = event;
        if (!isSubHalIndexValid(event.sensorHandle)) {
            return Result::BAD_VALUE;
        }
        subHalEvent.sensorHandle = clearSubHalIndex(event.sensorHandle);
        result = getSubHalForSensorHandle(event.sensorHandle)->injectSensorData(subHalEvent);
    }
    return result;
}

Return<void> HalProxy::registerDirectChannel(const SharedMemInfo& mem,
                                             registerDirectChannel_cb _hidl_cb) {
    if (mDirectChannelSubHal == nullptr) {
        _hidl_cb(Result::INVALID_OPERATION, -1 /* channelHandle */);
    } else {
        mDirectChannelSubHal->registerDirectChannel(mem, _hidl_cb);
    }
    return Return<void>();
}

Return<Result> HalProxy::unregisterDirectChannel(int32_t channelHandle) {
    Result result;
    if (mDirectChannelSubHal == nullptr) {
        result = Result::INVALID_OPERATION;
    } else {
        result = mDirectChannelSubHal->unregisterDirectChannel(channelHandle);
    }
    return result;
}

Return<void> HalProxy::configDirectReport(int32_t sensorHandle, int32_t channelHandle,
                                          RateLevel rate, configDirectReport_cb _hidl_cb) {
    if (mDirectChannelSubHal == nullptr) {
        _hidl_cb(Result::INVALID_OPERATION, -1 /* reportToken */);
    } else {
        mDirectChannelSubHal->configDirectReport(clearSubHalIndex(sensorHandle), channelHandle,
                                                 rate, _hidl_cb);
    }
    return Return<void>();
}

Return<void> HalProxy::debug(const hidl_handle& fd, const hidl_vec<hidl_string>& /*args*/) {
    if (fd.getNativeHandle() == nullptr || fd->numFds < 1) {
        ALOGE("%s: missing fd for writing", __FUNCTION__);
        return Void();
    }

    android::base::unique_fd writeFd(dup(fd->data[0]));
    if (writeFd.get() < 0) return Void();

    std::ostringstream stream;
    stream << "===HalProxy===" << std::endl;
    stream << "Internal values:" << std::endl;
    stream << "  Threads are running: " << (mThreadsRun.load() ? "true" : "false") << std::endl;
    {
        std::lock_guard<std::recursive_mutex> lock(mWakelockMutex);
        const int64_t now = getTimeNow();
        stream << "  Wakelock timeout start: " << msFromNs(now - mWakelockTimeoutStartTime)
               << " ms ago; reset: " << msFromNs(now - mWakelockTimeoutResetTime) << " ms ago"
               << std::endl;
        stream << "  Wakelock ref count: " << mWakelockRefCount << std::endl;
    }
    {
        std::lock_guard<std::mutex> lock(mEventQueueWriteMutex);
        stream << "  Pending events: " << mSizePendingWriteEventsQueue
               << "; high water mark: " << mMostEventsObservedPendingWriteEventsQueue << std::endl;
    }
    stream << "  Static sensors: " << mSensors.size() << std::endl;
    {
        std::lock_guard<std::mutex> lock(mDynamicSensorsMutex);
        stream << "  Dynamic sensors: " << mDynamicSensors.size() << std::endl;
    }
    stream << "SubHals (" << mSubHalList.size() << "):" << std::endl;
    for (ISensorsSubHal* subHal : mSubHalList) {
        stream << "  Name: " << subHal->getName() << std::endl;
        stream << "  Debug dump: " << std::endl;
        android::base::WriteStringToFd(stream.str(), writeFd);
        subHal->debug(fd, {});
        stream.str("");
        stream << std::endl;
    }
    android::base::WriteStringToFd(stream.str(), writeFd);
    return Return<void>();
}

Return<void> HalProxy::onDynamicSensorsConnected(const hidl_vec<SensorInfo>& dynamicSensorsAdded,
                                                 int32_t subHalIndex) {
    std::vector<SensorInfo> sensors;
    {
        std::lock_guard<std::mutex> lock(mDynamicSensorsMutex);
        for (SensorInfo sensor : dynamicSensorsAdded) {
            if (!subHalIndexIsClear(sensor.sensorHandle)) {
                ALOGE("Dynamic sensor added %s had sensorHandle with first byte not 0.",
                      sensor.name.c_str());
            } else {
                sensor.sensorHandle = setSubHalIndex(sensor.sensorHandle, subHalIndex);
                mDynamicSensors[sensor.sensorHandle] = sensor;
                sensors.push_back(sensor);
            }
        }
    }
    mDynamicSensorsCallback->onDynamicSensorsConnected(sensors);
    return Return<void>();
}

Return<void> HalProxy::onDynamicSensorsDisconnected(
        const hidl_vec<int32_t>& dynamicSensorHandlesRemoved, int32_t subHalIndex) {
    // TODO(b/143302327): Block this call until all pending events are flushed from queue
    std::vector<int32_t> sensorHandles;
    {
        std::lock_guard<std::mutex> lock(mDynamicSensorsMutex);
        for (int32_t sensorHandle : dynamicSensorHandlesRemoved) {
            if (!subHalIndexIsClear(sensorHandle)) {
                ALOGE("Dynamic sensorHandle removed had first byte not 0.");
            } else {
                sensorHandle = setSubHalIndex(sensorHandle, subHalIndex);
                if (mDynamicSensors.find(sensorHandle) != mDynamicSensors.end()) {
                    mDynamicSensors.erase(sensorHandle);
                    sensorHandles.push_back(sensorHandle);
                }
            }
        }
    }
    mDynamicSensorsCallback->onDynamicSensorsDisconnected(sensorHandles);
    return Return<void>();
}



void HalProxy::initializeSubHalCallbacks() {
    for (size_t subHalIndex = 0; subHalIndex < mSubHalList.size(); subHalIndex++) {
        sp<IHalProxyCallback> callback = new HalProxyCallback(this, subHalIndex);
        mSubHalCallbacks.push_back(callback);
    }
}

void HalProxy::initializeSensorList() {
    for (size_t subHalIndex = 0; subHalIndex < mSubHalList.size(); subHalIndex++) {
        ISensorsSubHal* subHal = mSubHalList[subHalIndex];
        auto result = subHal->getSensorsList([&](const auto& list) {
            for (SensorInfo sensor : list) {
                if (!subHalIndexIsClear(sensor.sensorHandle)) {
                    ALOGE("SubHal sensorHandle's first byte was not 0");
                } else {
                    ALOGV("Loaded sensor: %s", sensor.name.c_str());
                    sensor.sensorHandle = setSubHalIndex(sensor.sensorHandle, subHalIndex);
                    setDirectChannelFlags(&sensor, subHal);
                    mSensors[sensor.sensorHandle] = sensor;
                }
            }
        });
        if (!result.isOk()) {
            ALOGE("getSensorsList call failed for SubHal: %s", subHal->getName().c_str());
        }
    }
}

void HalProxy::init() {
    initializeSubHalCallbacks();
    initializeSensorList();
}

void HalProxy::stopThreads() {
    {
        std::lock_guard<std::mutex> lock(mEventQueueWriteMutex);
        std::lock_guard<std::recursive_mutex> wakeLock(mWakelockMutex);
        mThreadsRun.store(false);
    }
    if (mEventQueueFlag != nullptr && mEventQueue != nullptr) {
        mEventQueueFlag->wake(static_cast<uint32_t>(EventQueueFlagBits::EVENTS_READ));
    }
    if (mWakelockQueueFlag != nullptr && mWakeLockQueue != nullptr) {
        mWakelockQueueFlag->wake(static_cast<uint32_t>(WakeLockQueueFlagBits::DATA_WRITTEN));
    }
    mWakelockCV.notify_one();
    mEventQueueWriteCV.notify_one();
    if (mPendingWritesThread.joinable()) {
        mPendingWritesThread.join();
    }
    if (mWakelockThread.joinable()) {
        mWakelockThread.join();
    }
}

void HalProxy::disableAllSensors() {
    for (const auto& sensorEntry : mSensors) {
        int32_t sensorHandle = sensorEntry.first;
        activate(sensorHandle, false /* enabled */);
    }
    std::lock_guard<std::mutex> dynamicSensorsLock(mDynamicSensorsMutex);
    for (const auto& sensorEntry : mDynamicSensors) {
        int32_t sensorHandle = sensorEntry.first;
        activate(sensorHandle, false /* enabled */);
    }
}

void HalProxy::startPendingWritesThread(HalProxy* halProxy) {
    halProxy->handlePendingWrites();
}

void HalProxy::handlePendingWrites() {
    // TODO(b/143302327): Find a way to optimize locking strategy maybe using two mutexes instead of
    // one.
    std::unique_lock<std::mutex> lock(mEventQueueWriteMutex);
    while (mThreadsRun.load()) {
        mEventQueueWriteCV.wait(
                lock, [&] { return !mPendingWriteEventsQueue.empty() || !mThreadsRun.load(); });
        if (mThreadsRun.load()) {
            std::vector<Event>& pendingWriteEvents = mPendingWriteEventsQueue.front().first;
            size_t eventQueueSize = mEventQueue->getQuantumCount();
            size_t numToWrite = std::min(pendingWriteEvents.size(), eventQueueSize);
            size_t numWakeupEvents = countNumWakeupEvents(pendingWriteEvents, numToWrite);
            lock.unlock();
            if (!mEventQueue->writeBlocking(
                        pendingWriteEvents.data(), numToWrite,
                        static_cast<uint32_t>(EventQueueFlagBits::EVENTS_READ),
                        static_cast<uint32_t>(EventQueueFlagBits::READ_AND_PROCESS),
                        kPendingWriteTimeoutNs, mEventQueueFlag)) {
                ALOGE("Dropping %zu events after blockingWrite failed.", numToWrite);
                decrementRefCountAndMaybeReleaseWakelock(numWakeupEvents);
            }
            lock.lock();
            mSizePendingWriteEventsQueue -= numToWrite;
            mPendingWriteEventsQueue.front().second -= numWakeupEvents;
            if (pendingWriteEvents.size() > eventQueueSize) {
                // TODO(b/143302327): Check if this erase operation is too inefficient. It will copy
                // all the events ahead of it down to fill gap off array at front after the erase.
                pendingWriteEvents.erase(pendingWriteEvents.begin(),
                                         pendingWriteEvents.begin() + eventQueueSize);
            } else {
                mPendingWriteEventsQueue.pop();
            }
        }
    }
}

void HalProxy::startWakelockThread(HalProxy* halProxy) {
    halProxy->handleWakelocks();
}

void HalProxy::handleWakelocks() {
    std::unique_lock<std::recursive_mutex> lock(mWakelockMutex);
    while (mThreadsRun.load()) {
        mWakelockCV.wait(lock, [&] { return mWakelockRefCount > 0 || !mThreadsRun.load(); });
        if (mThreadsRun.load()) {
            int64_t timeLeft;
            if (sharedWakelockDidTimeout(&timeLeft)) {
                resetSharedWakelock();
            } else {
                uint32_t numWakeLocksProcessed;
                lock.unlock();
                bool success = mWakeLockQueue->readBlocking(
                        &numWakeLocksProcessed, 1, 0,
                        static_cast<uint32_t>(WakeLockQueueFlagBits::DATA_WRITTEN),
                        std::min(timeLeft, INT64_C(100000000)), mWakelockQueueFlag);
                lock.lock();
                if (success) {
                    decrementRefCountAndMaybeReleaseWakelock(
                            static_cast<size_t>(numWakeLocksProcessed));
                }
            }
        }
    }
    resetSharedWakelock();
}

bool HalProxy::sharedWakelockDidTimeout(int64_t* timeLeft) {
    bool didTimeout;
    int64_t duration = getTimeNow() - mWakelockTimeoutStartTime;
    if (duration > kWakelockTimeoutNs) {
        didTimeout = true;
    } else {
        didTimeout = false;
        *timeLeft = kWakelockTimeoutNs - duration;
    }
    return didTimeout;
}

void HalProxy::resetSharedWakelock() {
    std::lock_guard<std::recursive_mutex> lockGuard(mWakelockMutex);
    decrementRefCountAndMaybeReleaseWakelock(mWakelockRefCount);
    mWakelockTimeoutResetTime = getTimeNow();
}

void HalProxy::postEventsToMessageQueue(const std::vector<Event>& events, size_t numWakeupEvents,
                                       ScopedWakelock wakelock) {
    std::lock_guard<std::mutex> lock(mEventQueueWriteMutex);
    if (!mThreadsRun.load()) return;
    if (wakelock.isLocked() && !incrementRefCountAndMaybeAcquireWakelock(numWakeupEvents)) return;
    size_t numToWrite = 0;
    if (mPendingWriteEventsQueue.empty()) {
        numToWrite = std::min(events.size(), mEventQueue->availableToWrite());
        if (numToWrite > 0) {
            if (mEventQueue->write(events.data(), numToWrite)) {
                mEventQueueFlag->wake(static_cast<uint32_t>(EventQueueFlagBits::READ_AND_PROCESS));
            } else {
                numToWrite = 0;
            }
        }
    }
    const size_t numLeft = events.size() - numToWrite;
    const size_t wakeupsLeft = numWakeupEvents - countNumWakeupEvents(events, numToWrite);
    if (numLeft == 0) return;
    if (mSizePendingWriteEventsQueue + numLeft <= kMaxSizePendingWriteEventsQueue) {
        std::vector<Event> eventsLeft(events.begin() + numToWrite, events.end());
        mPendingWriteEventsQueue.push({std::move(eventsLeft), wakeupsLeft});
        mSizePendingWriteEventsQueue += numLeft;
        mMostEventsObservedPendingWriteEventsQueue =
                std::max(mMostEventsObservedPendingWriteEventsQueue, mSizePendingWriteEventsQueue);
        mEventQueueWriteCV.notify_one();
    } else {
        ALOGE("Dropping %zu events because the pending event queue is full", numLeft);
        decrementRefCountAndMaybeReleaseWakelock(wakeupsLeft);
    }
}

bool HalProxy::incrementRefCountAndMaybeAcquireWakelock(size_t delta,
                                                        int64_t* timeoutStart /* = nullptr */) {
    std::lock_guard<std::recursive_mutex> lockGuard(mWakelockMutex);
    if (!mThreadsRun.load() || delta == 0) return false;
    if (mWakelockRefCount == 0) {
        if (acquire_wake_lock(PARTIAL_WAKE_LOCK, kWakelockName) != 0) {
            ALOGE("Unable to acquire sensors wake lock");
            return false;
        }
        mWakelockCV.notify_one();
    }
    mWakelockTimeoutStartTime = getTimeNow();
    mWakelockRefCount += delta;
    if (timeoutStart != nullptr) {
        *timeoutStart = mWakelockTimeoutStartTime;
    }
    return true;
}

void HalProxy::decrementRefCountAndMaybeReleaseWakelock(size_t delta,
                                                        int64_t timeoutStart /* = -1 */) {
    // Reinitialization must release the old wake lock after workers stop.
    std::lock_guard<std::recursive_mutex> lockGuard(mWakelockMutex);
    if (timeoutStart == -1) timeoutStart = mWakelockTimeoutResetTime;
    if (mWakelockRefCount == 0 || timeoutStart < mWakelockTimeoutResetTime) return;
    mWakelockRefCount -= std::min(mWakelockRefCount, delta);
    if (mWakelockRefCount == 0) {
        release_wake_lock(kWakelockName);
    }
}

void HalProxy::setDirectChannelFlags(SensorInfo* sensorInfo, ISensorsSubHal* subHal) {
    bool sensorSupportsDirectChannel =
            (sensorInfo->flags & (V1_0::SensorFlagBits::MASK_DIRECT_REPORT |
                                  V1_0::SensorFlagBits::MASK_DIRECT_CHANNEL)) != 0;
    if (mDirectChannelSubHal == nullptr && sensorSupportsDirectChannel) {
        mDirectChannelSubHal = subHal;
    } else if (mDirectChannelSubHal != nullptr && subHal != mDirectChannelSubHal) {
        // disable direct channel capability for sensors in subHals that are not
        // the only one we will enable
        sensorInfo->flags &= ~(V1_0::SensorFlagBits::MASK_DIRECT_REPORT |
                               V1_0::SensorFlagBits::MASK_DIRECT_CHANNEL);
    }
}

ISensorsSubHal* HalProxy::getSubHalForSensorHandle(int32_t sensorHandle) {
    return mSubHalList[extractSubHalIndex(sensorHandle)];
}

bool HalProxy::isSubHalIndexValid(int32_t sensorHandle) {
    return extractSubHalIndex(sensorHandle) < mSubHalList.size();
}

size_t HalProxy::countNumWakeupEvents(const std::vector<Event>& events, size_t n) {
    size_t numWakeupEvents = 0;
    for (size_t i = 0; i < n; i++) {
        int32_t sensorHandle = events[i].sensorHandle;
        if (mSensors.at(sensorHandle).flags & static_cast<uint32_t>(V1_0::SensorFlagBits::WAKE_UP)) {
            numWakeupEvents++;
        }
    }
    return numWakeupEvents;
}

int32_t HalProxy::clearSubHalIndex(int32_t sensorHandle) {
    return sensorHandle & (~kSensorHandleSubHalIndexMask);
}

bool HalProxy::subHalIndexIsClear(int32_t sensorHandle) {
    return (sensorHandle & kSensorHandleSubHalIndexMask) == 0;
}

void HalProxyCallback::postEvents(const std::vector<Event>& events, ScopedWakelock wakelock) {
    if (events.empty() || !mHalProxy->areThreadsRunning()) return;
    size_t numWakeupEvents;
    std::vector<Event> processedEvents = processEvents(events, &numWakeupEvents);
    if (numWakeupEvents > 0) {
        if (!wakelock.isLocked()) {
            ALOGE("Dropping wakeup events without a held wake lock");
            return;
        }
    } else {
        ALOG_ASSERT(!wakelock.isLocked(),
                    "No Wakeup events posted but wakelock locked for subhal"
                    " w/ index %" PRId32 ".",
                    mSubHalIndex);
    }
    mHalProxy->postEventsToMessageQueue(processedEvents, numWakeupEvents, std::move(wakelock));
}

ScopedWakelock HalProxyCallback::createScopedWakelock(bool lock) {
    ScopedWakelock wakelock(mHalProxy, lock);
    return wakelock;
}

std::vector<Event> HalProxyCallback::processEvents(const std::vector<Event>& events,
                                                   size_t* numWakeupEvents) const {
    *numWakeupEvents = 0;
    std::vector<Event> eventsOut;
    for (Event event : events) {
        event.sensorHandle = setSubHalIndex(event.sensorHandle, mSubHalIndex);
        eventsOut.push_back(event);
        const SensorInfo& sensor = mHalProxy->getSensorInfo(event.sensorHandle);
        if ((sensor.flags & V1_0::SensorFlagBits::WAKE_UP) != 0) {
            (*numWakeupEvents)++;
        }
    }
    return eventsOut;
}

}  // namespace implementation
}  // namespace V2_0
}  // namespace sensors
}  // namespace hardware
}  // namespace android
