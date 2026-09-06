LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)

# Build the existing Lineage sources under a device-specific module name.
# The installed filename and ELF SONAME retain the vendor-consumed ABI.
LOCAL_MODULE := libtinycompress_k50
LOCAL_OVERRIDES_MODULES := libtinycompress
LOCAL_MODULE_STEM := libtinycompress
LOCAL_PROPRIETARY_MODULE := true
LOCAL_MULTILIB := both
LOCAL_SRC_FILES := \
    ../../../../external/tinycompress/compress.c \
    ../../../../external/tinycompress/utils.c
LOCAL_C_INCLUDES := external/tinycompress/include
LOCAL_EXPORT_C_INCLUDE_DIRS := external/tinycompress/include
LOCAL_HEADER_LIBRARIES := k50_tinycompress_kernel_headers
LOCAL_SHARED_LIBRARIES := libcutils libutils
LOCAL_CFLAGS := -Wall -Werror -Wno-macro-redefined -Wno-unused-function
LOCAL_NOTICE_FILE := external/tinycompress/NOTICE

include $(BUILD_SHARED_LIBRARY)
