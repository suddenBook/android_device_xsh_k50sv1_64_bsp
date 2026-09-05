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

#pragma once

#include <gatekeeper/gatekeeper.h>
#include <openssl/rand.h>

#include <climits>
#include <cstring>
#include <ctime>
#include <unordered_map>

extern "C" {
#include <crypto_scrypt.h>
}

namespace k50sv1 {

// Preserves the software credential format of the shipped MTK Gatekeeper.
// Calls and operation-error state are serialized by the owning HAL device.
class SoftGateKeeper final : public gatekeeper::GateKeeper {
public:
    void BeginOperation() { operation_failed_ = false; }
    bool OperationFailed() const { return operation_failed_; }

protected:
    bool GetAuthTokenKey(const uint8_t** key, uint32_t* length) const override {
        *key = key_;
        *length = sizeof(key_);
        return true;
    }

    void GetPasswordKey(const uint8_t** key, uint32_t* length) override {
        *key = key_;
        *length = sizeof(key_);
    }

    void ComputePasswordSignature(uint8_t* signature, uint32_t signature_length,
                                  const uint8_t*, uint32_t, const uint8_t* password,
                                  uint32_t password_length, gatekeeper::salt_t salt) const override {
        if (crypto_scrypt(password, password_length, reinterpret_cast<const uint8_t*>(&salt),
                          sizeof(salt), 16384, 8, 1, signature, signature_length) != 0) {
            std::memset(signature, 0, signature_length);
            operation_failed_ = true;
        }
    }

    void GetRandom(void* random, uint32_t length) const override {
        if (length > INT_MAX || RAND_bytes(static_cast<uint8_t*>(random), length) != 1) {
            std::memset(random, 0, length);
            operation_failed_ = true;
        }
    }

    void ComputeSignature(uint8_t* signature, uint32_t signature_length, const uint8_t*,
                          uint32_t, const uint8_t*, uint32_t) const override {
        // The existing software backend emits unsigned authentication tokens.
        std::memset(signature, 0, signature_length);
    }

    uint64_t GetMillisecondsSinceBoot() const override {
        struct timespec time = {};
        if (clock_gettime(CLOCK_BOOTTIME, &time) != 0) {
            operation_failed_ = true;
            return 0;
        }
        return static_cast<uint64_t>(time.tv_sec) * 1000 + time.tv_nsec / 1000000;
    }

    bool IsHardwareBacked() const override {
        // Q gatekeeperd uses this byte to route existing HAL credentials and
        // preserve their SID during re-enrollment. It is NOT a TEE claim.
        return true;
    }

    bool GetFailureRecord(uint32_t uid, gatekeeper::secure_id_t user_id,
                          gatekeeper::failure_record_t* record, bool) override {
        auto& stored = failure_map_[uid];
        if (stored.secure_user_id != user_id) {
            stored = {user_id, 0, 0};
        }
        *record = stored;
        return true;
    }

    bool ClearFailureRecord(uint32_t uid, gatekeeper::secure_id_t user_id, bool) override {
        // This flag and the memory-only throttle match existing handles.
        failure_map_[uid] = {user_id, 0, 0};
        return true;
    }

    bool WriteFailureRecord(uint32_t uid, gatekeeper::failure_record_t* record, bool) override {
        failure_map_[uid] = *record;
        return true;
    }

private:
    uint8_t key_[32] = {};
    std::unordered_map<uint32_t, gatekeeper::failure_record_t> failure_map_;
    mutable bool operation_failed_ = false;
    // Use GateKeeper::DoVerify for every handle. A SID-only password cache can
    // accept the previous password after a re-enrollment that preserves SID.
};

}  // namespace k50sv1
