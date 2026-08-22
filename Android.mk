LOCAL_PATH := $(call my-dir)

ifneq ($(filter k50sv1_64_bsp,$(TARGET_DEVICE)),)
include $(call all-makefiles-under,$(LOCAL_PATH))
endif
