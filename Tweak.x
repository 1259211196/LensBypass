#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <mach/mach_time.h>

// ==========================================
// 1. 全局变量声明：建立我们的“地下通道”
// ==========================================
static id<AVCaptureVideoDataOutputSampleBufferDelegate> global_videoDelegate = nil;
static dispatch_queue_t global_videoQueue = nil;
static AVCaptureConnection *global_videoConnection = nil;

static AVAssetReader *global_assetReader = nil;
static AVAssetReaderTrackOutput *global_videoTrackOutput = nil;
static dispatch_source_t global_frameTimer = nil;
static BOOL isVirtualCameraRunning = NO;

// 你需要替换的本地视频路径 (建议放在 App 沙盒的 Documents 目录下，或者固定路径)
#define TARGET_VIDEO_PATH @"/var/mobile/Media/DCIM/vcam_target.mp4" 

// ==========================================
// 2. 核心大招：时间戳重铸与帧清洗函数
// ==========================================
static void sendNextVirtualFrame() {
    if (!global_assetReader || global_assetReader.status != AVAssetReaderStatusReading) {
        return;
    }
    
    // 1. 从原视频读取带有“旧年份”时间戳的原始帧
    CMSampleBufferRef oldSampleBuffer = [global_videoTrackOutput copyNextSampleBuffer];
    if (!oldSampleBuffer) {
        // 视频播放完毕，可以写循环播放逻辑
        NSLog(@"[VCAM] 视频播放结束");
        return;
    }
    
    // 2. 暴力剥离：只提取最纯净的像素数据，丢弃原视频的所有元数据和旧时间
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(oldSampleBuffer);
    if (!pixelBuffer) {
        CFRelease(oldSampleBuffer);
        return;
    }
    
    // 3. 时间戳重铸：获取手机此刻的绝对系统时间
    // 这是绕过风控、让视频变成“今天刚刚拍的”的核心
    CMTime currentPTS = CMClockGetTime(CMClockGetHostTimeClock());
    
    // 4. 构建全新的时间信息结构体
    CMSampleTimingInfo newTimingInfo;
    newTimingInfo.presentationTimeStamp = currentPTS;
    newTimingInfo.decodeTimeStamp = kCMTimeInvalid;
    // 保持原有的帧持续时间 (通常是 1/30 秒)
    newTimingInfo.duration = CMSampleBufferGetDuration(oldSampleBuffer); 
    
    // 5. 重新包装成全新的 CMSampleBuffer
    CMSampleBufferRef newSampleBuffer = NULL;
    CMVideoFormatDescriptionRef formatDescription = NULL;
    
    // 根据干净的像素数据生成新的格式描述
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDescription);
    
    // 创建属于“此时此刻”的崭新视频帧
    OSStatus status = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault,
                                                         pixelBuffer,
                                                         true,
                                                         NULL,
                                                         NULL,
                                                         formatDescription,
                                                         &newTimingInfo,
                                                         &newSampleBuffer);
    
    if (status == noErr && newSampleBuffer) {
        // 6. 主动投喂：将重铸好的完美帧，塞给 App 的真实代理
        if (global_videoDelegate && [global_videoDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
            [global_videoDelegate captureOutput:nil didOutputSampleBuffer:newSampleBuffer fromConnection:global_videoConnection];
        }
        CFRelease(newSampleBuffer);
    }
    
    // 7. 极其关键的内存管理：释放 C 对象，否则瞬间内存爆满闪退！
    if (formatDescription) CFRelease(formatDescription);
    CFRelease(oldSampleBuffer);
}

// ==========================================
// 3. 视频读取器初始化逻辑
// ==========================================
static void startVirtualCameraLoop() {
    if (isVirtualCameraRunning) return;
    
    NSURL *videoURL = [NSURL fileURLWithPath:TARGET_VIDEO_PATH];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:videoURL options:nil];
    
    NSError *error = nil;
    global_assetReader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    
    AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!videoTrack) return;
    
    // 设定输出格式为 NV12 (大多数 iOS 相机的默认底层格式)
    NSDictionary *outputSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    };
    
    global_videoTrackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack outputSettings:outputSettings];
    [global_assetReader addOutput:global_videoTrackOutput];
    [global_assetReader startReading];
    
    // 开启定时器，模拟相机 30fps 的出帧率 (1.0/30.0 秒)
    if (global_videoQueue) {
        global_frameTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, global_videoQueue);
        dispatch_source_set_timer(global_frameTimer, dispatch_walltime(NULL, 0), (1.0 / 30.0) * NSEC_PER_SEC, 0);
        dispatch_source_set_event_handler(global_frameTimer, ^{
            sendNextVirtualFrame();
        });
        dispatch_resume(global_frameTimer);
        isVirtualCameraRunning = YES;
        NSLog(@"[VCAM] 虚拟相机数据流已启动，开始按 30fps 投喂...");
    }
}

// ==========================================
// 4. 底层 API Hook 拦截区
// ==========================================

%hook AVCaptureVideoDataOutput

// 拦截 1：窃取代理，断开真实相机的画面输送
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    
    if (sampleBufferDelegate != nil) {
        global_videoDelegate = sampleBufferDelegate;
        global_videoQueue = sampleBufferCallbackQueue;
        NSLog(@"[VCAM] 成功劫持 Delegate!");
    }
    
    // 传入 nil，让真实相机闭嘴
    %orig(nil, nil); 
}

%end


%hook AVCaptureSession

// 拦截 2：监听相机启动动作，同步启动我们的“本地播放器”
- (void)startRunning {
    %orig; // 允许原始的 Session 启动，欺骗应用状态
    
    NSLog(@"[VCAM] 监测到 App 请求启动相机，准备注入虚拟视频流...");
    
    // 延迟一小会儿启动我们的流，确保 App 内部的 UI 和代理已经准备就绪
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        startVirtualCameraLoop();
    });
}

// 拦截 3：监听相机停止动作，同步关闭并清理我们的资源
- (void)stopRunning {
    %orig;
    
    if (global_frameTimer) {
        dispatch_source_cancel(global_frameTimer);
        global_frameTimer = nil;
    }
    if (global_assetReader) {
        [global_assetReader cancelReading];
        global_assetReader = nil;
    }
    isVirtualCameraRunning = NO;
    NSLog(@"[VCAM] 虚拟相机数据流已停止。");
}

%end
