/*
 * Copyright 2015 The Android Open Source Project
 * Copyright 2026 The LineageOS Project
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

#include <hardware/gatekeeper.h>

#include <cerrno>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <new>
#include <type_traits>

#include "SoftGateKeeper.h"

namespace {

struct State {
    k50sv1::SoftGateKeeper gatekeeper;
    std::mutex mutex;
};

struct Device {
    gatekeeper_device_t device;
    State* state;
};

static_assert(std::is_standard_layout<Device>::value, "HAL device must be pointer-interconvertible");
static_assert(sizeof(gatekeeper::password_handle_t) == 58, "MTK password handle ABI changed");

State* GetState(const gatekeeper_device_t* device) {
    return device ? reinterpret_cast<const Device*>(device)->state : nullptr;
}

bool ValidPassword(const uint8_t* password, uint32_t length) {
    // libgatekeeper adds the signed version/SID/flags length in uint32_t.
    constexpr uint32_t kMetadataLength = sizeof(uint8_t) + 2 * sizeof(uint64_t);
    return password && length && length <= UINT32_MAX - kMetadataLength;
}

bool ValidHandle(const uint8_t* handle, uint32_t length) {
    return handle && length == sizeof(gatekeeper::password_handle_t);
}

struct InputBuffer : gatekeeper::SizedBuffer {
    ~InputBuffer() { gatekeeper::memset_s(buffer.get(), 0, length); }

    bool Copy(const uint8_t* source, uint32_t size) {
        if (size == 0) return true;
        buffer.reset(new (std::nothrow) uint8_t[size]);
        if (!buffer.get()) return false;
        length = size;
        std::memcpy(buffer.get(), source, size);
        return true;
    }
};

int Result(const State& state, const gatekeeper::GateKeeperMessage& response) {
    if (state.gatekeeper.OperationFailed()) return -EIO;
    if (response.error == gatekeeper::ERROR_RETRY) return response.retry_timeout;
    return response.error == gatekeeper::ERROR_NONE ? 0 : -EINVAL;
}

int Enroll(const gatekeeper_device_t* device, uint32_t uid,
           const uint8_t* current_handle, uint32_t current_handle_length,
           const uint8_t* current_password, uint32_t current_password_length,
           const uint8_t* desired_password, uint32_t desired_password_length,
           uint8_t** enrolled_handle, uint32_t* enrolled_handle_length) {
    if (enrolled_handle) *enrolled_handle = nullptr;
    if (enrolled_handle_length) *enrolled_handle_length = 0;
    State* state = GetState(device);
    if (!state || !enrolled_handle || !enrolled_handle_length ||
        !ValidPassword(desired_password, desired_password_length)) {
        return -EINVAL;
    }

    const bool has_current_handle = current_handle_length != 0;
    const bool has_current_password = current_password_length != 0;
    if (has_current_handle != has_current_password ||
        (has_current_handle && (!ValidHandle(current_handle, current_handle_length) ||
                                !ValidPassword(current_password, current_password_length)))) {
        return -EINVAL;
    }

    std::lock_guard<std::mutex> lock(state->mutex);
    InputBuffer old_handle, old_password, new_password;
    if (!old_handle.Copy(current_handle, current_handle_length) ||
        !old_password.Copy(current_password, current_password_length) ||
        !new_password.Copy(desired_password, desired_password_length)) {
        return -ENOMEM;
    }
    gatekeeper::EnrollRequest request(uid, &old_handle, &new_password, &old_password);
    gatekeeper::EnrollResponse response;
    state->gatekeeper.BeginOperation();
    state->gatekeeper.Enroll(request, &response);
    const int result = Result(*state, response);
    if (result != 0) return result;

    *enrolled_handle = response.enrolled_password_handle.buffer.release();
    *enrolled_handle_length = response.enrolled_password_handle.length;
    return 0;
}

int Verify(const gatekeeper_device_t* device, uint32_t uid, uint64_t challenge,
           const uint8_t* enrolled_handle, uint32_t enrolled_handle_length,
           const uint8_t* password, uint32_t password_length,
           uint8_t** auth_token, uint32_t* auth_token_length, bool* request_reenroll) {
    if (auth_token) *auth_token = nullptr;
    if (auth_token_length) *auth_token_length = 0;
    if (request_reenroll) *request_reenroll = false;
    State* state = GetState(device);
    if (!state || !ValidHandle(enrolled_handle, enrolled_handle_length) ||
        !ValidPassword(password, password_length) ||
        ((auth_token == nullptr) != (auth_token_length == nullptr))) {
        return -EINVAL;
    }

    std::lock_guard<std::mutex> lock(state->mutex);
    InputBuffer handle_buffer, password_buffer;
    if (!handle_buffer.Copy(enrolled_handle, enrolled_handle_length) ||
        !password_buffer.Copy(password, password_length)) {
        return -ENOMEM;
    }
    gatekeeper::VerifyRequest request(uid, challenge, &handle_buffer, &password_buffer);
    gatekeeper::VerifyResponse response;
    state->gatekeeper.BeginOperation();
    state->gatekeeper.Verify(request, &response);
    const int result = Result(*state, response);
    if (result != 0) return result;

    if (auth_token) {
        *auth_token = response.auth_token.buffer.release();
        *auth_token_length = response.auth_token.length;
    }
    if (request_reenroll) *request_reenroll = response.request_reenroll;
    return 0;
}

int Close(hw_device_t* device) {
    if (!device) return -EINVAL;
    auto* instance = reinterpret_cast<Device*>(device);
    delete instance->state;
    delete instance;
    return 0;
}

int Open(const hw_module_t* module, const char* name, hw_device_t** device) {
    if (device) *device = nullptr;
    if (!module || !name || !device || std::strcmp(name, HARDWARE_GATEKEEPER) != 0) {
        return -EINVAL;
    }
    std::unique_ptr<Device> instance(new (std::nothrow) Device{});
    if (!instance) return -ENOMEM;
    instance->state = new (std::nothrow) State;
    if (!instance->state) return -ENOMEM;
    instance->device.common.tag = HARDWARE_DEVICE_TAG;
    instance->device.common.version = 1;
    instance->device.common.module = const_cast<hw_module_t*>(module);
    instance->device.common.close = Close;
    instance->device.enroll = Enroll;
    instance->device.verify = Verify;
    *device = &instance.release()->device.common;
    return 0;
}

hw_module_methods_t kMethods = { .open = Open };

}  // namespace

extern "C" {
gatekeeper_module HAL_MODULE_INFO_SYM __attribute__((visibility("default"))) = {
    .common = {
        .tag = HARDWARE_MODULE_TAG,
        .module_api_version = GATEKEEPER_MODULE_API_VERSION_0_1,
        .hal_api_version = HARDWARE_HAL_API_VERSION,
        .id = GATEKEEPER_HARDWARE_MODULE_ID,
        .name = "K50sv1 legacy software Gatekeeper",
        .author = "The Android Open Source Project",
        .methods = &kMethods,
        .dso = nullptr,
        .reserved = {},
    },
};
}
