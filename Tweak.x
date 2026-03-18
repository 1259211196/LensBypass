#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

// ==========================================
// 1. 全局核心指针与状态池
// ==========================================
static id<AVCaptureVideoDataOutputSampleBufferDelegate> global_videoDelegate = nil;
static dispatch_queue_t global_videoQueue = nil;
static AVCaptureVideoDataOutput *global_videoOutput = nil;

// 动态获取真实视频通道
#define DYNAMIC_VIDEO_CONN [global_videoOutput connectionWithMediaType:AVMediaTypeVideo]

static AVAssetReader *global_assetReader = nil;
static AVAssetReaderTrackOutput *global_videoTrackOutput = nil;
static dispatch_source_t global_frameTimer = nil;

// 物理声学回环引擎
static AVAudioPlayer *global_audioPlayer = nil;

static NSString *dynamicVideoPath = nil; 
static CMTime global_timeOffset = {0, 0, 0, 0}; 
static BOOL isPlaying = NO;

// ==========================================
// 2. 视频哑巴替身 (代理黑洞)
// ==========================================
@interface LensVideoProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@end
@implementation LensVideoProxy
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    // 真实摄像头数据流入此黑洞，彻底销毁
}
@end

static LensVideoProxy *g_videoProxy = nil;

// ==========================================
// 3. 潜行控制面板 (双指三击触发)
// ==========================================
@interface LensBypassUIManager : NSObject <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
+ (instancetype)sharedInstance;
- (void)setupHiddenGestureInWindow:(UIWindow *)window;
@end

@implementation LensBypassUIManager
+ (instancetype)sharedInstance {
    static LensBypassUIManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (void)setupHiddenGestureInWindow:(UIWindow *)window {
    for (UIGestureRecognizer *gesture in window.gestureRecognizers) {
        if ([gesture.accessibilityLabel isEqualToString:@"LensBypassGesture"]) return; 
    }
    // 隐形暗号：双指同时点击屏幕三次
    UITapGestureRecognizer *secretTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openAlbum)];
    secretTap.numberOfTouchesRequired = 2; 
    secretTap.numberOfTapsRequired = 3;    
    secretTap.accessibilityLabel = @"LensBypassGesture"; 
    [window addGestureRecognizer:secretTap];
}

- (UIViewController *)topViewController {
    UIWindow *targetWindow = nil;
    for (UIWindow *window in [[UIApplication sharedApplication] windows]) {
        if (window.isKeyWindow) { targetWindow = window; break; }
    }
    if (!targetWindow) targetWindow = [[[UIApplication sharedApplication] windows] firstObject];
    
    UIViewController *topController = targetWindow.rootViewController;
    while (topController.presentedViewController) { topController = topController.presentedViewController; }
    return topController;
}

- (void)openAlbum {
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.delegate = self;
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes = @[@"public.movie", @"public.video"]; 
    picker.videoQuality = UIImagePickerControllerQualityTypeHigh; // 强制系统不压缩画质
    [[self topViewController] presentViewController:picker animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];
    NSURL *videoURL = info[UIImagePickerControllerMediaURL];
    if (videoURL) {
        NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSString *destPath = [docPath stringByAppendingPathComponent:@"lensbypass_target.mp4"];
        NSError *error = nil;
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm fileExistsAtPath:destPath]) { [fm removeItemAtPath:destPath error:nil]; }
        [fm copyItemAtPath:videoURL.path toPath:destPath error:&error];
        
        if (!error) {
            dynamicVideoPath = destPath;
            global_timeOffset = kCMTimeInvalid;
            isPlaying = NO;
            // 选片成功后，震动反馈确认弹药上膛
            UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
            [feedback impactOccurred];
        }
    }
}
- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}
@end

// ==========================================
// 4. 底层投喂与岁月史书引擎
// ==========================================
static void startVirtualCameraLoop(void);

static void cleanupAssetReader() {
    if (global_assetReader) {
        [global_assetReader cancelReading];
        global_assetReader = nil;
        global_videoTrackOutput = nil;
    }
    if (global_audioPlayer) {
        [global_audioPlayer stop];
        global_audioPlayer = nil;
    }
}

static void sendNextVirtualFrames() {
    if (!global_assetReader || global_assetReader.status != AVAssetReaderStatusReading) return;
    
    CMSampleBufferRef oldVideoBuffer = NULL;
    if (global_videoTrackOutput) oldVideoBuffer = [global_videoTrackOutput copyNextSampleBuffer];
    
    // 循环点：播完后瞬间重置时间锚点与播放器
    if (!oldVideoBuffer) {
        cleanupAssetReader();
        global_timeOffset = kCMTimeInvalid; 
        startVirtualCameraLoop();
        return; 
    }
    
    CMTime originalVideoPTS = CMSampleBufferGetPresentationTimeStamp(oldVideoBuffer);
    
    // 核心：相对时间锚点锁定
    if (CMTIME_IS_INVALID(global_timeOffset)) {
        CMTime now = CMClockGetTime(CMClockGetHostTimeClock());
        global_timeOffset = CMTimeSubtract(now, originalVideoPTS);
    }
    
    CMTime newVideoPTS = CMTimeAdd(originalVideoPTS, global_timeOffset);
    
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(oldVideoBuffer);
    if (pixelBuffer) {
        CMSampleTimingInfo newVideoTiming;
        newVideoTiming.presentationTimeStamp = newVideoPTS;
        newVideoTiming.decodeTimeStamp = kCMTimeInvalid;
        newVideoTiming.duration = CMSampleBufferGetDuration(oldVideoBuffer);
        
        CMVideoFormatDescriptionRef formatDesc = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDesc);
        
        CMSampleBufferRef newVideoBuffer = NULL;
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, NULL, NULL, formatDesc, &newVideoTiming, &newVideoBuffer);
        
        if (newVideoBuffer && global_videoDelegate && global_videoOutput) {
            // 核心：光学物理元数据注入，骗过 CV 纯净度检测
            CFMutableDictionaryRef cameraEXIF = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            float fNumber = 1.8; int iso = 125; float exposure = 0.0;
            CFNumberRef fNumberRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat32Type, &fNumber);
            CFNumberRef isoRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &iso);
            CFNumberRef exposureRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat32Type, &exposure);
            
            CFDictionarySetValue(cameraEXIF, CFSTR("FNumber"), fNumberRef);
            CFDictionarySetValue(cameraEXIF, CFSTR("ISOSpeedRatings"), isoRef);
            CFDictionarySetValue(cameraEXIF, CFSTR("ExposureBiasValue"), exposureRef);
            
            CMSetAttachment(newVideoBuffer, CFSTR("MetadataDictionary"), cameraEXIF, kCMAttachmentMode_ShouldPropagate);
            CFRelease(fNumberRef); CFRelease(isoRef); CFRelease(exposureRef); CFRelease(cameraEXIF);

            [global_videoDelegate captureOutput:global_videoOutput didOutputSampleBuffer:newVideoBuffer fromConnection:DYNAMIC_VIDEO_CONN];
            CFRelease(newVideoBuffer);
        }
        if (formatDesc) CFRelease(formatDesc);
    }
    CFRelease(oldVideoBuffer);
}

static void startVirtualCameraLoop() {
    if (!dynamicVideoPath) return;
    
    NSURL *videoURL = [NSURL fileURLWithPath:dynamicVideoPath];
    
    // --- 启动声学回环外放 ---
    NSError *audioError = nil;
    global_audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:videoURL error:&audioError];
    if (global_audioPlayer) {
        [global_audioPlayer setVolume:1.0];
        [global_audioPlayer prepareToPlay];
        [global_audioPlayer play];
    }
    
    NSDictionary *options = @{ AVURLAssetPreferPreciseDurationAndTimingKey : @YES };
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:videoURL options:options];
    global_assetReader = [AVAssetReader assetReaderWithAsset:asset error:nil];
    
    AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (videoTrack) {
        global_videoTrackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)}];
        [global_assetReader addOutput:global_videoTrackOutput];
    }
    
    [global_assetReader startReading];
    isPlaying = YES;
    
    float nominalFPS = (videoTrack && videoTrack.nominalFrameRate > 0) ? videoTrack.nominalFrameRate : 30.0;
    
    if (global_videoQueue && !global_frameTimer) {
        global_frameTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, global_videoQueue);
        dispatch_source_set_timer(global_frameTimer, dispatch_walltime(NULL, 0), (1.0 / nominalFPS) * NSEC_PER_SEC, 0);
        dispatch_source_set_event_handler(global_frameTimer, ^{ if(isPlaying) sendNextVirtualFrames(); });
        dispatch_resume(global_frameTimer);
    }
}

// ==========================================
// 5. 最高权限 API 拦截网
// ==========================================

// 战术 1：暴力重写音频法则，防止 TikTok 静音我们的外放
%hook AVAudioSession
- (BOOL)setCategory:(AVAudioSessionCategory)category withOptions:(AVAudioSessionCategoryOptions)options error:(NSError **)outError {
    // [精准修复]：补全了 Category 关键字，完全符合苹果官方 API 规范
    AVAudioSessionCategoryOptions forceOptions = options | AVAudioSessionCategoryOptionMixWithOthers | AVAudioSessionCategoryOptionDefaultToSpeaker;
    return %orig(category, forceOptions, outError);
}

- (BOOL)setCategory:(NSString *)category error:(NSError **)outError {
    // [精准修复]：补全了 Category 关键字
    return [self setCategory:category withOptions:(AVAudioSessionCategoryOptionMixWithOthers | AVAudioSessionCategoryOptionDefaultToSpeaker) error:outError];
}
%end

// 战术 2：手势注入
%hook UIWindow
- (void)makeKeyAndVisible {
    %orig;
    [[LensBypassUIManager sharedInstance] setupHiddenGestureInWindow:self];
}
%end

// 战术 3：拦截视频流，扔进黑洞
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    if (sampleBufferDelegate) {
        global_videoDelegate = sampleBufferDelegate;
        global_videoQueue = sampleBufferCallbackQueue;
        global_videoOutput = self; 
        
        if (!g_videoProxy) g_videoProxy = [[LensVideoProxy alloc] init];
        %orig(g_videoProxy, sampleBufferCallbackQueue);
    } else {
        %orig;
    }
}
%end

// 战术 4：监听相机启动信号，开始投喂
%hook AVCaptureSession
- (void)startRunning {
    %orig;
    global_timeOffset = kCMTimeInvalid;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        startVirtualCameraLoop();
    });
}
- (void)stopRunning {
    %orig;
    isPlaying = NO;
    if (global_frameTimer) { dispatch_source_cancel(global_frameTimer); global_frameTimer = nil; }
    cleanupAssetReader();
}
%end
