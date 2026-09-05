#!/usr/bin/env python3
"""Host regressions of production poll/initialize and wake-lock functions.

Android plumbing is replaced with a scripted backend. No device/Android build is
performed; the production function bodies are extracted rather than reimplemented.
"""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def function(source, marker):
    start = source.index(marker)
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end] + '\n'

def run(name, code):
    with tempfile.TemporaryDirectory(prefix='k50-sensors-') as tmp:
        source = Path(tmp) / (name + '.cpp')
        binary = Path(tmp) / name
        source.write_text(code)
        subprocess.run(['c++', '-std=c++17', '-O1', '-g', '-pthread',
                        '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
                        '-no-pie', '-I', str(ROOT), str(source), '-o', str(binary)], check=True)
        env = dict(os.environ, ASAN_OPTIONS='detect_leaks=0')
        subprocess.run([str(binary)], check=True, timeout=15, env=env)

common = r'''
#include <algorithm>
#include <array>
#include <atomic>
#include <cassert>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <queue>
#include <set>
#include <thread>
#include <utility>
#include <vector>
using namespace std::chrono_literals;
#define LOG(x) std::cerr
#define ALOGE(...) ((void)0)
#define ALOGW(...) ((void)0)
using status_t = int;
constexpr int OK=0, NO_INIT=-19, BAD_VALUE=-22, NO_MEMORY=-12, PERMISSION_DENIED=-1;
enum class Result { OK, BAD_VALUE, INVALID_OPERATION, NO_MEMORY, PERMISSION_DENIED };
enum class OperationMode { NORMAL, DATA_INJECTION };
template<class T> using Return = T;
template<class T> using sp = std::shared_ptr<T>;
namespace android {
int64_t elapsedRealtimeNano() {
 return std::chrono::duration_cast<std::chrono::nanoseconds>(
  std::chrono::steady_clock::now().time_since_epoch()).count();
}
}
namespace V1_0 {
enum class SensorType { META_DATA=0, ACCELEROMETER=1 };
enum SensorFlagBits { WAKE_UP=1 };
}
using SensorFlagBits=V1_0::SensorFlagBits;
struct Event { int sensorHandle=0; V1_0::SensorType sensorType=V1_0::SensorType::ACCELEROMETER;
 int64_t timestamp=0; };
struct SensorInfo { int sensorHandle=0; unsigned flags=0; };
'''

adapter = common + r'''
#include "PollPolicy.h"
constexpr int SENSORS_DEVICE_API_VERSION_1_3=0x103, SENSORS_DEVICE_API_VERSION_1_4=0x104;
constexpr const char* SENSORS_HARDWARE_MODULE_ID="sensors";
struct hw_module_t {};
struct sensors_event_t { Event event; };
struct sensor_t { int handle; unsigned flags; };
struct sensors_poll_device_t {};
struct sensors_poll_device_1_t {
 struct { int version; } common;
 int (*poll)(sensors_poll_device_t*,sensors_event_t*,int);
 int (*activate)(sensors_poll_device_t*,int,bool);
 int (*batch)(sensors_poll_device_1_t*,int,int,int64_t,int64_t);
 int (*flush)(sensors_poll_device_1_t*,int);
 int (*register_direct_channel)(sensors_poll_device_1_t*,void*,int);
};
struct sensors_module_t {
 hw_module_t common;
 int (*get_sensors_list)(sensors_module_t*,const sensor_t**);
 int (*set_operation_mode)(unsigned);
};
std::mutex backendMutex;
std::condition_variable backendCV;
std::queue<std::pair<int,Event>> scripted;
std::atomic<int> polls{0};
bool failModule=false, failActivate=false, errorMode=false;
int backendPoll(sensors_poll_device_t*, sensors_event_t* events, int) {
 std::unique_lock<std::mutex> lock(backendMutex);
 ++polls; backendCV.notify_all();
 backendCV.wait(lock, []{return errorMode || !scripted.empty();});
 if(errorMode) return -EIO;
 auto next=scripted.front(); scripted.pop();
 if(next.first==1) events[0].event=next.second;
 return next.first;
}
int backendActivate(sensors_poll_device_t*, int, bool) { return failActivate ? -EIO : OK; }
int backendBatch(sensors_poll_device_1_t*,int,int,int64_t,int64_t) {return OK;}
int backendFlush(sensors_poll_device_1_t*,int) {return OK;}
int backendChannel(sensors_poll_device_1_t*,void*,int) {return OK;}
int backendList(sensors_module_t*,const sensor_t** list) { static sensor_t sensor{42,0}; *list=&sensor; return 1; }
int backendMode(unsigned) {return OK;}
sensors_poll_device_1_t device{{0x104},backendPoll,backendActivate,backendBatch,backendFlush,backendChannel};
sensors_module_t module{{},backendList,backendMode};
int hw_get_module(const char*,const hw_module_t** out) {if(failModule) return -ENODEV; *out=&module.common; return OK;}
int sensors_open_1(hw_module_t*,sensors_poll_device_1_t** out) {*out=&device;return OK;}
void convertFromSensor(const sensor_t& src,SensorInfo* dst) {*dst={src.handle,src.flags};}
void convertFromSensorEvent(const sensors_event_t& src,Event* dst) {*dst=src.event;}
struct Callback {
 std::mutex mutex; std::condition_variable cv; std::vector<Event> received;
 int createScopedWakelock(bool) {return 0;}
 void postEvents(const std::vector<Event>& events,int) {
  std::lock_guard<std::mutex> lock(mutex); received.insert(received.end(),events.begin(),events.end()); cv.notify_all();
 }
 void waitCount(size_t n) {
  std::unique_lock<std::mutex> lock(mutex);
  assert(cv.wait_for(lock,2s,[&]{return received.size()>=n;}));
 }
 size_t size() {std::lock_guard<std::mutex> lock(mutex); return received.size();}
};
using IHalProxyCallback=Callback;
class SensorsSubHal {
public:
 SensorsSubHal();
 bool isReady() const {return mInitStatus==OK;}
 int getHalDeviceVersion() const;
 status_t enumerateSensors();
 bool isWakeUpSensor(int32_t);
 void pollForEvents();
 Result setOperationModeLocked(OperationMode);
 Return<Result> activate(int32_t,bool);
 Return<Result> initialize(const sp<IHalProxyCallback>&);
 std::map<int32_t,SensorInfo> mSensors;
 std::mutex mMutex;
 sp<IHalProxyCallback> mCallback;
 OperationMode mCurrentOperationMode=OperationMode::NORMAL;
 status_t mInitStatus=NO_INIT;
 std::map<int32_t,int64_t> mActiveSince;
 std::set<int32_t> mDirectChannels;
 uint64_t mEpoch=0;
 static constexpr int32_t kPollMaxBufferSize=128;
 std::thread mPollThread;
 sensors_poll_device_1_t* mSensorDevice=nullptr;
 sensors_module_t* mSensorModule=nullptr;
};
void submit(int count, int handle=42, int64_t timestamp=0) {
 std::lock_guard<std::mutex> lock(backendMutex);
 scripted.push({count,{handle,V1_0::SensorType::ACCELEROMETER,
                       timestamp ? timestamp : android::elapsedRealtimeNano()+1000000000}});
 backendCV.notify_all();
}
void waitPoll(int target) {
 std::unique_lock<std::mutex> lock(backendMutex);
 assert(backendCV.wait_for(lock,2s,[&]{return polls.load()>=target;}));
}
'''
s = (ROOT/'SensorsSubHal.cpp').read_text()
for marker in ['static Result resultFromStatus', 'SensorsSubHal::SensorsSubHal()',
               'int SensorsSubHal::getHalDeviceVersion', 'bool SensorsSubHal::isWakeUpSensor',
               'status_t SensorsSubHal::enumerateSensors', 'void SensorsSubHal::pollForEvents',
               'Result SensorsSubHal::setOperationModeLocked',
               'Return<Result> SensorsSubHal::activate',
               'Return<Result> SensorsSubHal::initialize']:
    adapter += function(s,marker)
adapter += r'''
int main() {
 failModule=true;
 SensorsSubHal unavailable;
 assert(!unavailable.isReady());
 assert(unavailable.activate(42,true)==Result::INVALID_OPERATION);
 failModule=false;
 auto* hal=new SensorsSubHal;
 assert(hal->isReady());
 std::this_thread::sleep_for(30ms);
 assert(polls==0);
 assert(hal->initialize(nullptr)==Result::BAD_VALUE);
 assert(polls==0);
 auto first=std::make_shared<Callback>();
 assert(hal->initialize(first)==Result::OK);
 assert(hal->activate(999,true)==Result::BAD_VALUE);
 assert(hal->activate(42,true)==Result::OK);
 waitPoll(1); submit(1); first->waitCount(1);
 waitPoll(2);
 // A blocked old poll may complete after a framework session is replaced.
 auto second=std::make_shared<Callback>();
 assert(hal->initialize(second)==Result::OK);
 assert(hal->activate(42,true)==Result::OK);
 submit(1); waitPoll(3);
 assert(first->size()==1 && second->size()==0);
 submit(1); second->waitCount(1); waitPoll(4);
 submit(1,999); waitPoll(5);
 submit(1,42,1); waitPoll(6);
 assert(second->size()==1);
 // A failed disable must remain tracked so a later initialize can retry.
 failActivate=true;
 assert(hal->initialize(second)==Result::INVALID_OPERATION);
 assert(hal->mActiveSince.size()==1);
 failActivate=false;
 assert(hal->initialize(second)==Result::OK);
 assert(hal->mActiveSince.empty());
 assert(hal->activate(42,true)==Result::OK);
 submit(1); waitPoll(7); // Drain the batch begun before the failed initialize.
 // Oversized and negative counts never index outside the 128-event buffer.
 submit(129); waitPoll(8);
 {std::lock_guard<std::mutex> lock(backendMutex);errorMode=true;backendCV.notify_all();}
 int before=polls;
 std::this_thread::sleep_for(220ms);
 assert(polls-before<=5);
 {std::lock_guard<std::mutex> lock(backendMutex);errorMode=false;backendCV.notify_all();}
 submit(1); second->waitCount(2);
 std::cout<<"PASS poll initialization, session replacement, unknown/stale events, disable retry, count bounds and error backoff\n"<<std::flush;
 std::_Exit(0); // The production legacy worker is intentionally process-lifetime.
}
'''
run('legacy-lifecycle', adapter)

wake = common + r'''
struct RefBase {virtual ~RefBase()=default;};
int acquired=0, released=0;
constexpr int PARTIAL_WAKE_LOCK=1;
int acquire_wake_lock(int,const char*) {++acquired;return 0;}
int release_wake_lock(const char*) {++released;return 0;}
int64_t getTimeNow();
'''
h=(ROOT/'multihal/include/ScopedWakelock.h').read_text()
wake += h[h.index('class IScopedWakelockRefCounter'):h.index('}  // namespace implementation')]
wake += r'''
class HalProxyCallback {
public:
 static ScopedWakelock make(IScopedWakelockRefCounter* counter,bool locked=true) {
  return ScopedWakelock(counter,locked);
 }
};
struct FakeQueue {
 size_t capacity=1;
 size_t availableToWrite() {return capacity;}
 bool write(const Event*,size_t n) {capacity-=n;return true;}
};
struct Flag {void wake(uint32_t) {}};
enum class EventQueueFlagBits { READ_AND_PROCESS=1 };
class HalProxy : public IScopedWakelockRefCounter {
public:
 bool incrementRefCountAndMaybeAcquireWakelock(size_t,int64_t* =nullptr) override;
 void decrementRefCountAndMaybeReleaseWakelock(size_t,int64_t =-1) override;
 void resetSharedWakelock();
 void postEventsToMessageQueue(const std::vector<Event>&,size_t,ScopedWakelock);
 size_t countNumWakeupEvents(const std::vector<Event>&,size_t);
 std::atomic_bool mThreadsRun{true};
 std::recursive_mutex mWakelockMutex;
 std::condition_variable_any mWakelockCV;
 size_t mWakelockRefCount=0;
 int64_t mWakelockTimeoutStartTime=0,mWakelockTimeoutResetTime=0;
 const char* kWakelockName="SensorsHAL_WAKEUP";
 std::mutex mEventQueueWriteMutex;
 std::condition_variable mEventQueueWriteCV;
 std::queue<std::pair<std::vector<Event>,size_t>> mPendingWriteEventsQueue;
 size_t mSizePendingWriteEventsQueue=0,mMostEventsObservedPendingWriteEventsQueue=0;
 static constexpr size_t kMaxSizePendingWriteEventsQueue=3;
 std::unique_ptr<FakeQueue> mEventQueue=std::make_unique<FakeQueue>();
 Flag flag; Flag* mEventQueueFlag=&flag;
 std::map<int32_t,SensorInfo> mSensors{{1,{1,1}},{2,{2,0}}};
};
'''
s=(ROOT/'multihal/ScopedWakelock.cpp').read_text()
for marker in ['int64_t getTimeNow()', 'ScopedWakelock::ScopedWakelock(ScopedWakelock&&',
 'ScopedWakelock& ScopedWakelock::operator=',
 'ScopedWakelock::ScopedWakelock(IScoped', 'ScopedWakelock::~ScopedWakelock']:
    wake += function(s,marker)
s=(ROOT/'multihal/HalProxy.cpp').read_text()
for marker in ['bool HalProxy::incrementRefCountAndMaybeAcquireWakelock',
 'void HalProxy::decrementRefCountAndMaybeReleaseWakelock',
 'void HalProxy::resetSharedWakelock', 'void HalProxy::postEventsToMessageQueue',
 'size_t HalProxy::countNumWakeupEvents']:
    wake += function(s,marker)
wake += r'''
int main() {
 HalProxy proxy;
 {
  auto a=HalProxyCallback::make(&proxy);
  assert(proxy.mWakelockRefCount==1);
  auto b=std::move(a);
  assert(!a.isLocked() && b.isLocked() && proxy.mWakelockRefCount==1);
  auto c=HalProxyCallback::make(&proxy);
  assert(proxy.mWakelockRefCount==2);
  c=std::move(b);
  assert(!b.isLocked() && c.isLocked() && proxy.mWakelockRefCount==1);
  c=std::move(c);
  assert(proxy.mWakelockRefCount==1);
 }
 assert(proxy.mWakelockRefCount==0 && acquired==released);
 {
  auto token=HalProxyCallback::make(&proxy);
  proxy.mThreadsRun=false;
  proxy.resetSharedWakelock();
  assert(proxy.mWakelockRefCount==0 && acquired==released);
 }
 proxy.mThreadsRun=true;
 std::vector<Event> events{{1},{2},{1}};
 proxy.postEventsToMessageQueue(events,2,HalProxyCallback::make(&proxy));
 assert(proxy.mWakelockRefCount==2);
 assert(proxy.mPendingWriteEventsQueue.front().first.size()==2);
 assert(proxy.mPendingWriteEventsQueue.front().second==1);
 assert(proxy.mSizePendingWriteEventsQueue==2);
 // Overflow drops two wake events and releases only their references.
 proxy.postEventsToMessageQueue(events,2,HalProxyCallback::make(&proxy));
 assert(proxy.mWakelockRefCount==2);
 proxy.decrementRefCountAndMaybeReleaseWakelock(2);
 assert(proxy.mWakelockRefCount==0 && acquired==released);
 proxy.mThreadsRun=false;
 proxy.postEventsToMessageQueue(events,2,HalProxyCallback::make(&proxy,false));
 assert(proxy.mWakelockRefCount==0 && proxy.mSizePendingWriteEventsQueue==2);
 std::cout<<"PASS wake-lock move ownership, reset after stop, partial FMQ writes, overflow and stopped delivery\n";
}
'''
run('wake-locks', wake)

fmq = common + r'''
namespace android { namespace hardware {
template<class T> struct MQDescriptorSync { bool valid; };
}}
struct ISensorsCallback {};
enum class EventQueueFlagBits {EVENTS_READ=2};
enum class WakeLockQueueFlagBits {DATA_WRITTEN=1};
struct EventFlag {
 static int live;
 static int createEventFlag(int* word,EventFlag** out) {
  if(!word) return BAD_VALUE;
  *out=new EventFlag; ++live; return OK;
 }
 static void deleteEventFlag(EventFlag** out) {delete *out;*out=nullptr;--live;}
 void wake(uint32_t) {}
};
int EventFlag::live=0;
template<class T> struct Queue {
 bool valid; int word=0;
 Queue(const android::hardware::MQDescriptorSync<T>& d,bool):valid(d.valid){}
 bool isValid() {return valid;}
 int* getEventFlagWord() {assert(valid);return &word;}
};
struct SubHal {
 Result result=Result::OK;
 int calls=0;
 Result initialize(int) {++calls;return result;}
 std::string getName() {return "test";}
};
class HalProxy {
public:
 using EventMessageQueue=Queue<Event>;
 using WakeLockMessageQueue=Queue<uint32_t>;
 Return<Result> initialize(const android::hardware::MQDescriptorSync<Event>&,
                          const android::hardware::MQDescriptorSync<uint32_t>&,
                          const sp<ISensorsCallback>&);
 void stopThreads();
 void resetSharedWakelock() {++resets;}
 void disableAllSensors() {++disables;}
 static void startPendingWritesThread(HalProxy* p) {++p->starts;}
 static void startWakelockThread(HalProxy* p) {++p->starts;}
 std::mutex mInitializeMutex,mEventQueueWriteMutex,mDynamicSensorsMutex;
 std::recursive_mutex mWakelockMutex;
 std::condition_variable mEventQueueWriteCV;
 std::condition_variable_any mWakelockCV;
 std::atomic_bool mThreadsRun{false};
 std::thread mPendingWritesThread,mWakelockThread;
 std::queue<std::pair<std::vector<Event>,size_t>> mPendingWriteEventsQueue;
 size_t mSizePendingWriteEventsQueue=0;
 std::map<int,int> mDynamicSensors;
 sp<ISensorsCallback> mDynamicSensorsCallback;
 std::unique_ptr<EventMessageQueue> mEventQueue;
 std::unique_ptr<WakeLockMessageQueue> mWakeLockQueue;
 EventFlag* mEventQueueFlag=nullptr; EventFlag* mWakelockQueueFlag=nullptr;
 SubHal subHal;
 std::vector<SubHal*> mSubHalList{&subHal};
 std::vector<int> mSubHalCallbacks{1};
 OperationMode mCurrentOperationMode=OperationMode::NORMAL;
 int resets=0,disables=0;
 std::atomic<int> starts{0};
};
'''
s=(ROOT/'multihal/HalProxy.cpp').read_text()
fmq += function(s,'Return<Result> HalProxy::initialize(')
fmq += function(s,'void HalProxy::stopThreads()')
fmq += r'''
int main() {
 HalProxy proxy;
 auto callback=std::make_shared<ISensorsCallback>();
 assert(proxy.initialize({false},{true},callback)==Result::BAD_VALUE);
 assert(proxy.starts==0 && !proxy.mThreadsRun && proxy.subHal.calls==0);
 assert(proxy.initialize({true},{false},callback)==Result::BAD_VALUE);
 assert(proxy.starts==0 && EventFlag::live==0);
 assert(proxy.initialize({true},{true},nullptr)==Result::BAD_VALUE);
 assert(proxy.starts==0 && EventFlag::live==0);
 proxy.subHal.result=Result::INVALID_OPERATION;
 assert(proxy.initialize({true},{true},callback)==Result::INVALID_OPERATION);
 assert(proxy.starts==0 && !proxy.mThreadsRun);
 proxy.subHal.result=Result::OK;
 assert(proxy.initialize({true},{true},callback)==Result::OK);
 proxy.stopThreads();
 assert(proxy.starts==2 && EventFlag::live==2);
 // Concurrent framework initialization is serialized, including old worker joins.
 std::thread a([&]{assert(proxy.initialize({true},{true},callback)==Result::OK);});
 std::thread b([&]{assert(proxy.initialize({true},{true},callback)==Result::OK);});
 a.join();b.join();proxy.stopThreads();
 assert(proxy.starts==6 && EventFlag::live==2);
 assert(proxy.initialize({false},{true},callback)==Result::BAD_VALUE);
 assert(EventFlag::live==0 && !proxy.mThreadsRun && proxy.starts==6);
 std::cout<<"PASS invalid FMQs/callback, sub-HAL failure, worker restart and concurrent initialize\n";
}
'''
run('fmq-lifecycle',fmq)
