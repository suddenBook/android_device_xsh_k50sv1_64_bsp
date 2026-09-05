/*
 * Copyright 2026 The LineageOS Project
 * SPDX-License-Identifier: Apache-2.0
 */

#include <hardware/gatekeeper.h>
#include <hardware/hw_auth_token.h>
#include <gatekeeper/password_handle.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <endian.h>
#include <memory>
#include <string>
#include <thread>
#include <vector>

extern "C" gatekeeper_module HAL_MODULE_INFO_SYM;

namespace {

bool fail_random = false;
bool fail_scrypt = false;
bool fail_clock = false;
unsigned int checks = 0;

#define CHECK(condition) do { \
    ++checks; \
    if (!(condition)) { \
        std::fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #condition); \
        std::exit(1); \
    } \
} while (false)

const uint8_t* Bytes(const std::string& value) {
    return reinterpret_cast<const uint8_t*>(value.data());
}

gatekeeper_device_t* Open() {
    gatekeeper_device_t* device = nullptr;
    CHECK(gatekeeper_open(&HAL_MODULE_INFO_SYM.common, &device) == 0);
    CHECK(device != nullptr);
    CHECK(device->common.tag == HARDWARE_DEVICE_TAG);
    CHECK(device->enroll && device->verify && !device->delete_user && !device->delete_all_users);
    return device;
}

std::vector<uint8_t> Enroll(gatekeeper_device_t* device, uint32_t uid,
                            const std::string& password,
                            const std::vector<uint8_t>& old_handle = {},
                            const std::string& old_password = {}) {
    uint8_t* handle = nullptr;
    uint32_t length = 0;
    CHECK(device->enroll(device, uid, old_handle.data(), old_handle.size(),
                         Bytes(old_password), old_password.size(), Bytes(password), password.size(),
                         &handle, &length) == 0);
    std::unique_ptr<uint8_t[]> owned(handle);
    CHECK(handle != nullptr && length == sizeof(gatekeeper::password_handle_t));
    return {handle, handle + length};
}

gatekeeper::password_handle_t Decode(const std::vector<uint8_t>& bytes) {
    gatekeeper::password_handle_t handle;
    CHECK(bytes.size() == sizeof(handle));
    std::memcpy(&handle, bytes.data(), sizeof(handle));
    return handle;
}

int Verify(gatekeeper_device_t* device, uint32_t uid, const std::vector<uint8_t>& handle,
           const std::string& password, uint64_t challenge = 0, hw_auth_token_t* token_out = nullptr) {
    uint8_t* token = reinterpret_cast<uint8_t*>(1);
    uint32_t length = 123;
    bool reenroll = true;
    const int result = device->verify(device, uid, challenge, handle.data(), handle.size(),
                                     Bytes(password), password.size(), &token, &length, &reenroll);
    if (result == 0) {
        std::unique_ptr<uint8_t[]> owned(token);
        CHECK(token != nullptr && length == sizeof(hw_auth_token_t));
        CHECK(!reenroll);
        if (token_out) std::memcpy(token_out, token, sizeof(*token_out));
    } else {
        CHECK(token == nullptr && length == 0 && !reenroll);
    }
    return result;
}

void TestCredentials() {
    auto* device = Open();
    const std::string password("first\0password", 14);
    const std::string next_password = "second password";
    auto first = Enroll(device, 100, password);
    auto decoded = Decode(first);
    CHECK(decoded.version == gatekeeper::HANDLE_VERSION);
    CHECK(decoded.hardware_backed);
    CHECK(decoded.user_id != 0);
    CHECK(decoded.flags == HANDLE_FLAG_THROTTLE_SECURE);

    hw_auth_token_t token;
    constexpr uint64_t challenge = 0x123456789abcdef0;
    CHECK(Verify(device, 100, first, password, challenge, &token) == 0);
    CHECK(token.version == HW_AUTH_TOKEN_VERSION);
    CHECK(token.challenge == challenge && token.user_id == decoded.user_id);
    CHECK(token.authenticator_id == 0);
    CHECK(be32toh(token.authenticator_type) == HW_AUTH_PASSWORD);
    CHECK(be64toh(token.timestamp) > 0);
    CHECK(std::all_of(std::begin(token.hmac), std::end(token.hmac), [](uint8_t b) { return b == 0; }));
    CHECK(Verify(device, 100, first, "wrong") < 0);
    CHECK(Verify(device, 100, first, password) == 0);
    CHECK(device->verify(device, 100, 0, first.data(), first.size(), Bytes(password), password.size(),
                         nullptr, nullptr, nullptr) == 0);

    uint8_t* failed_handle = reinterpret_cast<uint8_t*>(1);
    uint32_t failed_length = 123;
    CHECK(device->enroll(device, 100, first.data(), first.size(), Bytes("wrong"), 5,
                         Bytes(next_password), next_password.size(),
                         &failed_handle, &failed_length) < 0);
    CHECK(failed_handle == nullptr && failed_length == 0);

    auto second = Enroll(device, 100, next_password, first, password);
    CHECK(Decode(second).user_id == decoded.user_id);
    CHECK(Verify(device, 100, second, password) < 0);
    CHECK(Verify(device, 100, second, next_password) == 0);
    auto corrupted = second;
    corrupted[offsetof(gatekeeper::password_handle_t, signature)] ^= 1;
    CHECK(Verify(device, 100, corrupted, next_password) < 0);
    CHECK(Verify(device, 100, second, next_password) == 0);

    // A separate open has its own lifetime, and either can be closed first.
    auto* other = Open();
    CHECK(other != device);
    CHECK(Verify(other, 100, second, next_password, challenge) == 0);
    CHECK(gatekeeper_close(device) == 0);
    CHECK(Verify(other, 100, second, next_password) == 0);
    CHECK(gatekeeper_close(other) == 0);
    device = Open();
    CHECK(Verify(device, 100, second, next_password) == 0);
    CHECK(Verify(device, 100, second, password) < 0);
    CHECK(gatekeeper_close(device) == 0);
}

void TestMalformed() {
    auto* device = Open();
    const std::string password = "correct";
    auto handle = Enroll(device, 200, password);
    auto oversized = handle;
    oversized.push_back(0);
    for (uint32_t size : {0U, 1U, 57U, 59U, UINT32_MAX}) {
        uint8_t* output = reinterpret_cast<uint8_t*>(1);
        uint32_t output_size = 123;
        bool reenroll = true;
        CHECK(device->verify(device, 200, 0, oversized.data(), size, Bytes(password), password.size(),
                             &output, &output_size, &reenroll) == -EINVAL);
        CHECK(output == nullptr && output_size == 0 && !reenroll);
        CHECK(device->enroll(device, 200, oversized.data(), size, Bytes(password), password.size(),
                             Bytes(password), password.size(), &output, &output_size) == -EINVAL);
        CHECK(output == nullptr && output_size == 0);
    }
    auto future = handle;
    future[0] = gatekeeper::HANDLE_VERSION + 1;
    CHECK(Verify(device, 200, future, password) < 0);
    uint8_t* output = reinterpret_cast<uint8_t*>(1);
    uint32_t length = 123;
    bool reenroll = true;
    CHECK(device->verify(device, 200, 0, nullptr, handle.size(), Bytes(password), password.size(),
                         &output, &length, &reenroll) == -EINVAL);
    CHECK(output == nullptr && length == 0 && !reenroll);
    CHECK(device->verify(device, 200, 0, handle.data(), handle.size(), Bytes(password), UINT32_MAX,
                         &output, &length, &reenroll) == -EINVAL);
    CHECK(device->verify(device, 200, 0, handle.data(), handle.size(), nullptr, password.size(),
                         &output, &length, &reenroll) == -EINVAL);
    CHECK(device->verify(device, 200, 0, handle.data(), handle.size(), Bytes(password), password.size(),
                         &output, nullptr, &reenroll) == -EINVAL);
    CHECK(output == nullptr && !reenroll);
    CHECK(device->enroll(device, 200, handle.data(), handle.size(), nullptr, 0,
                         Bytes(password), password.size(), &output, &length) == -EINVAL);
    CHECK(device->enroll(device, 200, nullptr, 0, nullptr, 0, nullptr, password.size(),
                         &output, &length) == -EINVAL);
    CHECK(device->enroll(device, 200, nullptr, 0, nullptr, 0, Bytes(password), UINT32_MAX,
                         &output, &length) == -EINVAL);
    CHECK(device->enroll(device, 200, nullptr, 0, nullptr, 0, Bytes(password), password.size(),
                         nullptr, &length) == -EINVAL);
    CHECK(length == 0);
    CHECK(gatekeeper_close(device) == 0);

    hw_device_t* raw = reinterpret_cast<hw_device_t*>(1);
    CHECK(HAL_MODULE_INFO_SYM.common.methods->open(&HAL_MODULE_INFO_SYM.common, "wrong", &raw) == -EINVAL);
    CHECK(raw == nullptr);
    CHECK(HAL_MODULE_INFO_SYM.common.methods->open(nullptr, HARDWARE_GATEKEEPER, &raw) == -EINVAL);
    CHECK(HAL_MODULE_INFO_SYM.common.methods->open(&HAL_MODULE_INFO_SYM.common, nullptr, &raw) == -EINVAL);
    CHECK(HAL_MODULE_INFO_SYM.common.methods->open(&HAL_MODULE_INFO_SYM.common, HARDWARE_GATEKEEPER,
                                                nullptr) == -EINVAL);
}

void TestFailures() {
    auto* device = Open();
    const std::string password = "correct";
    auto handle = Enroll(device, 300, password);
    for (bool* failure : {&fail_random, &fail_scrypt}) {
        *failure = true;
        uint8_t* output = reinterpret_cast<uint8_t*>(1);
        uint32_t length = 123;
        CHECK(device->enroll(device, 301, nullptr, 0, nullptr, 0, Bytes(password), password.size(),
                             &output, &length) == -EIO);
        CHECK(output == nullptr && length == 0);
        *failure = false;
    }
    for (bool* failure : {&fail_scrypt, &fail_clock}) {
        *failure = true;
        CHECK(Verify(device, 300, handle, password) == -EIO);
        *failure = false;
        CHECK(Verify(device, 300, handle, password) == 0);
    }
    // A crypto error cannot authenticate an all-zero signature either.
    auto zero = handle;
    std::fill(zero.begin() + offsetof(gatekeeper::password_handle_t, signature),
              zero.begin() + offsetof(gatekeeper::password_handle_t, hardware_backed), 0);
    fail_scrypt = true;
    CHECK(Verify(device, 300, zero, password) == -EIO);
    fail_scrypt = false;
    CHECK(Verify(device, 300, handle, password) == 0);

    for (unsigned int i = 0; i < 4; ++i) CHECK(Verify(device, 300, handle, "wrong") < 0);
    CHECK(Verify(device, 300, handle, "wrong") > 0);
    CHECK(Verify(device, 300, handle, password) > 0);
    CHECK(gatekeeper_close(device) == 0);
}

void TestConcurrent() {
    auto* device = Open();
    const std::string password = "correct";
    auto handle = Enroll(device, 400, password);
    std::atomic<unsigned int> passed{0};
    std::vector<std::thread> threads;
    for (unsigned int i = 0; i < 4; ++i) {
        threads.emplace_back([&] {
            if (device->verify(device, 400, 0, handle.data(), handle.size(),
                               Bytes(password), password.size(), nullptr, nullptr, nullptr) == 0) {
                ++passed;
            }
        });
    }
    for (auto& thread : threads) thread.join();
    CHECK(passed == 4);
    CHECK(gatekeeper_close(device) == 0);
}

void TestLegacyVector(const char* path) {
    std::array<uint8_t, sizeof(gatekeeper::password_handle_t)> bytes;
    FILE* file = std::fopen(path, "rb");
    CHECK(file != nullptr);
    CHECK(std::fread(bytes.data(), 1, bytes.size(), file) == bytes.size());
    CHECK(std::fgetc(file) == EOF);
    CHECK(std::fclose(file) == 0);
    const std::string password = "independent legacy vector";
    std::vector<uint8_t> handle(bytes.begin(), bytes.end());
    auto* device = Open();
    hw_auth_token_t token;
    CHECK(Verify(device, 500, handle, password, 42, &token) == 0);
    CHECK(token.user_id == 0x0123456789abcdef && token.challenge == 42);
    CHECK(Verify(device, 500, handle, "wrong") < 0);
    const auto next = Enroll(device, 500, "new independent password", handle, password);
    CHECK(Decode(next).user_id == 0x0123456789abcdef);
    CHECK(gatekeeper_close(device) == 0);
}

}  // namespace

extern "C" {
int __real_RAND_bytes(unsigned char*, int);
int __wrap_RAND_bytes(unsigned char* bytes, int size) {
    return fail_random ? 0 : __real_RAND_bytes(bytes, size);
}

int __real_crypto_scrypt(const uint8_t*, size_t, const uint8_t*, size_t, uint64_t,
                         uint32_t, uint32_t, uint8_t*, size_t);
int __wrap_crypto_scrypt(const uint8_t* password, size_t password_size, const uint8_t* salt,
                         size_t salt_size, uint64_t n, uint32_t r, uint32_t p,
                         uint8_t* output, size_t output_size) {
    return fail_scrypt ? -1 : __real_crypto_scrypt(password, password_size, salt, salt_size,
                                                 n, r, p, output, output_size);
}

int __real_clock_gettime(clockid_t, struct timespec*);
int __wrap_clock_gettime(clockid_t clock, struct timespec* time) {
    return fail_clock ? -1 : __real_clock_gettime(clock, time);
}
}

int main(int argc, char** argv) {
    CHECK(argc == 2);
    TestCredentials();
    TestMalformed();
    TestFailures();
    TestConcurrent();
    TestLegacyVector(argv[1]);
    std::printf("PASS: %u checks; enroll, challenge, re-enroll/SID, reopen, invalid input, "
                "crypto errors, throttling, concurrent calls and independent legacy vector\n", checks);
    return 0;
}
