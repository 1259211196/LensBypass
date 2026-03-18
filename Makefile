# ==========================================
# 1. 编译目标与环境配置
# ==========================================
# 锁定现代 iOS 设备的架构 (支持 A12 及以上的芯片)
ARCHS = arm64 arm64e

# 指定编译器和最低兼容版本 (建议 14.0 起步，兼顾绝大多数巨魔设备)
TARGET := iphone:clang:latest:14.0

# 注入宿主 (虽然我们针对特定 App，但 Tweak 编译默认需要一个载体)
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

# ==========================================
# 2. 核心项目信息
# ==========================================
TWEAK_NAME = LensBypass

# 指定需要编译的源文件
LensBypass_FILES = Tweak.x

# ==========================================
# 3. 动态库与框架链接 (极其重要)
# ==========================================
# UIKit: 支撑悬浮窗 UIButton、UIImagePickerController (相册) 和 UIWindow 的 Hook
# Foundation: 支撑 NSString、NSURL、NSFileManager (文件拷贝)
# AVFoundation: 支撑相机劫持 (AVCapture) 和视频读取 (AVAssetReader)
# CoreMedia: 支撑底层时间戳重铸 (CMTime, CMSampleTimingInfo)
# CoreVideo: 支撑底层像素缓冲 (CVPixelBuffer)
# MobileCoreServices: 支撑相册过滤，只允许选择视频类型 (kUTTypeMovie)
LensBypass_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia CoreVideo MobileCoreServices

# ==========================================
# 4. 编译器指令
# ==========================================
# 开启 Objective-C 的自动引用计数 (ARC)
# 注意：ARC 只负责 OC 对象，C 语言级的 CFRelease (如释放 CMSampleBufferRef) 代码里已手动处理
LensBypass_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
