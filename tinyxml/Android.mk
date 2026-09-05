LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)

# The RIL imports this SONAME and the non-STL TiXmlString/class ABI.
LOCAL_MODULE := libmtktinyxml
LOCAL_PROPRIETARY_MODULE := true
LOCAL_MULTILIB := 64
LOCAL_SRC_FILES := \
    ../../../../external/tinyxml/tinyxml.cpp \
    ../../../../external/tinyxml/tinyxmlparser.cpp \
    ../../../../external/tinyxml/tinyxmlerror.cpp \
    ../../../../external/tinyxml/tinystr.cpp
LOCAL_CFLAGS := \
    -Wno-implicit-fallthrough \
    -Wno-logical-op-parentheses \
    -Wno-missing-braces \
    -Wno-undefined-bool-conversion \
    -Werror

include $(BUILD_SHARED_LIBRARY)
