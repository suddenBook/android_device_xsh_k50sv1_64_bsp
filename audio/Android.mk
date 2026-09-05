LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)

# Use the AOSP multi-version service with the existing device init contract.
# The MTK Audio 5.0 and primary HAL implementations remain vendor libraries.
LOCAL_MODULE := android.hardware.audio@5.0-service-mediatek
LOCAL_MODULE_RELATIVE_PATH := hw
LOCAL_PROPRIETARY_MODULE := true
LOCAL_MULTILIB := 32
LOCAL_INIT_RC := ../rootdir/etc/init/android.hardware.audio@5.0-service-mediatek.rc
LOCAL_SRC_FILES := ../../../../hardware/interfaces/audio/common/all-versions/default/service/service.cpp
LOCAL_CFLAGS := -Wall -Werror
LOCAL_SHARED_LIBRARIES := \
    libcutils \
    libbinder \
    libhidlbase \
    libhidltransport \
    liblog \
    libutils \
    libhardware \
    libhwbinder \
    android.hardware.audio@2.0 \
    android.hardware.audio@4.0 \
    android.hardware.audio@5.0 \
    android.hardware.audio.common@2.0 \
    android.hardware.audio.common@4.0 \
    android.hardware.audio.common@5.0 \
    android.hardware.audio.effect@2.0 \
    android.hardware.audio.effect@4.0 \
    android.hardware.audio.effect@5.0 \
    android.hardware.bluetooth.a2dp@1.0 \
    android.hardware.bluetooth.audio@2.0 \
    android.hardware.soundtrigger@2.0 \
    android.hardware.soundtrigger@2.1 \
    android.hardware.soundtrigger@2.2

include $(BUILD_EXECUTABLE)
