ARCHS = arm64e
TARGET := iphone:clang:latest:16.5
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard
THEOS = /home/judah/theos
export CLANG_MODULE_CACHE_PATH = /tmp/clang-module-cache
#THEOS_DEVICE_IP = 10.2.34.14
include $(THEOS)/makefiles/common.mk
#export THEOS_PACKAGE_ARCH = iphoneos-arm64e

TWEAK_NAME = test

test_FILES = Tweak.xm \
             Core/ClassManager.mm \
             Core/Logger.xm \
             PTFakeTouch/PTFakeMetaTouch.m \
             PTFakeTouch/addition/UITouch-KIFAdditions.m \
             PTFakeTouch/addition/UIEvent+KIFAdditions.m \
             PTFakeTouch/addition/IOHIDEvent+KIF.m \
             UI/MonitorViewController.xm \
             UI/MemorySearchController.xm \
             UI/LogButton.xm \
             UI/ClassListController.xm \
             UI/MethodListController.xm \
             UI/ExecutionTracker.m \
             UI/ThemeManager.m

test_CFLAGS = -fobjc-arc -I Core -I PTFakeTouch -I PTFakeTouch/addition -fmodules-cache-path=/tmp/clang-module-cache
test_FRAMEWORKS = IOKit
include $(THEOS_MAKE_PATH)/tweak.mk
