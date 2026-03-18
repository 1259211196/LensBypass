# 指定目标架构和 iOS SDK 版本
ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LensBypass

# 你的主代码文件
LensBypass_FILES = Tweak.x

# [极度关键] 必须链接这些框架，否则 CMSampleBuffer 等 C 语言函数无法编译
LensBypass_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia CoreVideo

# 开启 ARC 自动引用计数 (注意：ARC 只管 Objective-C 对象，C 语言的 CFRelease 依然需要我们在代码里手动调用)
LensBypass_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
