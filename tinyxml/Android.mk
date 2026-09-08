# Anchor borrowed sources in the Android checkout, outside the linked device tree.
LOCAL_PATH := external/tinyxml

include $(CLEAR_VARS)

# The RIL imports this SONAME and the non-STL TiXmlString/class ABI.
LOCAL_MODULE := libmtktinyxml
LOCAL_PROPRIETARY_MODULE := true
LOCAL_MULTILIB := 64
LOCAL_SRC_FILES := \
    tinyxml.cpp \
    tinyxmlparser.cpp \
    tinyxmlerror.cpp \
    tinystr.cpp
LOCAL_CFLAGS := \
    -Wno-implicit-fallthrough \
    -Wno-logical-op-parentheses \
    -Wno-missing-braces \
    -Wno-undefined-bool-conversion \
    -Werror

include $(BUILD_SHARED_LIBRARY)
