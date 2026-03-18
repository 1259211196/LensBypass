#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

// ==========================================
// 1. 全局通信指针与状态 (纯净视频版)
// ==========================================
static id<AVCaptureVideoDataOutputSampleBufferDelegate> global_videoDelegate = nil;
static dispatch_queue_t global_videoQueue = nil;
static AVCaptureVideoDataOutput *global_videoOutput = nil;

// [动态连线宏] 确保随时拿到最新视频连线
#define DYNAMIC_VIDEO_CONN [global_videoOutput connectionWithMediaType:AVMediaTypeVideo]

static AVAssetReader *global_assetReader = nil;
static AVAssetReaderTrackOutput *global_videoTrackOutput = nil;
static dispatch_source_t global_frameTimer = nil;

static NSString *dynamicVideoPath = nil; 
static CMTime global_timeOffset = {0, 0, 0, 0}; 
static BOOL isPlaying = NO;

// ==========================================
// 2. 潜行模式：隐形手势与相册控制器
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
    // 暗号：双指三击屏幕任意位置唤出相册
    UITapGestureRecognizer *secretTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openAlbum)];
    secretTap.numberOfTouchesRequired = 2; 
    secretTap.numberOfTapsRequired = 3;    
    secretTap.accessibilityLabel = @"LensBypassGesture"; 
    [window addGestureRecognizer:secretTap];
    NSLog(@"[LensBypass] 隐形手势注入成功，暗号：双指三击");
}

- (UIViewController *)topViewController {
    UIWindow *targetWindow = nil;
    for (UIWindow *window in [[UIApplication sharedApplication] windows]) {
        if (window.isKeyWindow) { targetWindow = window; break; }
    }
    if (!targetWindow) targetWindow = [[[UIApplication sharedApplication] windows] firstObject];
    
    UIViewController *topController = targetWindow.rootViewController;
    while (topController.presentedViewController) { 
        topController = topController.presentedViewController; 
    }
    return topController;
}

- (void)openAlbum {
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.delegate = self;
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes = @[@"public.movie", @"public.video"]; 
    
    // 强制系统不压缩画质，保持原画直出
    picker.videoQuality = UIImagePickerControllerQualityTypeHigh; 
    
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
            // 选片成功，手机震动反馈
            UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            [feedback impactOccurred];
            NSLog(@"[LensBypass] 视频已就绪，潜行等待中...");
        }
    }
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}
@end

// ==========================================
// 3. 底层视频投喂模块 (纯视频)
// ==========================================

static void startVirtualCameraLoop(void);

static void cleanupAssetReader() {
    if (global_assetReader) {
        [global_assetReader cancelReading];
        global_assetReader = nil;
        global_videoTrackOutput = nil;
    }
}

static void sendNextVirtualFrames() {
    if (!global_assetReader || global_assetReader.status != AVAssetReaderStatusReading) return;
    
    // --- 视频抽帧与锚点重铸 ---
    CMSampleBufferRef oldVideoBuffer = NULL;
    if (global_videoTrackOutput) oldVideoBuffer = [global_videoTrackOutput copyNextSampleBuffer];
    
    // 视频播完，触发循环并废弃旧时间锚点
    if (!oldVideoBuffer) {
        cleanupAssetReader();
        global_timeOffset = kCMTimeInvalid; 
        startVirtualCameraLoop();
        return; 
    }
    
    CMTime originalVideoPTS = CMSampleBufferGetPresentationTimeStamp(oldVideoBuffer);
    
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
            // [极其重要的光学元数据注入] 骗过系统判定，赋予真实灵魂
            CFMutableDictionaryRef cameraEXIF = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            float fNumber = 1.5; int iso = 100; float exposure = 0.0;
            CFNumberRef fNumberRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat32Type, &fNumber);
            CFNumberRef isoRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &iso);
            CFNumberRef exposureRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat32Type, &exposure);
            
            CFDictionarySetValue(cameraEXIF, CFSTR("FNumber"), fNumberRef);
            CFDictionarySetValue(cameraEXIF, CFSTR("ISOSpeedRatings"), isoRef);
            CFDictionarySetValue(cameraEXIF, CFSTR("ExposureBiasValue"), exposureRef);
            
            CMSetAttachment(newVideoBuffer, CFSTR("MetadataDictionary"), cameraEXIF, kCMAttachmentMode_ShouldPropagate);
            CFRelease(fNumberRef); CFRelease(isoRef); CFRelease(exposureRef); CFRelease(cameraEXIF);

            // 动态连线投喂
            [global_videoDelegate captureOutput:global_videoOutput didOutputSampleBuffer:newVideoBuffer fromConnection:DYNAMIC_VIDEO_CONN];
            CFRelease(newVideoBuffer);
        }
        if (formatDesc) CFRelease(formatDesc);
    }
    CFRelease(oldVideoBuffer);
}

static void startVirtualCameraLoop() {
    if (!dynamicVideoPath) return;
    
    // 强制精确读取时间轴
    NSDictionary *options = @{ AVURLAssetPreferPreciseDurationAndTimingKey : @YES };
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:dynamicVideoPath] options:options];
    global_assetReader = [AVAssetReader assetReaderWithAsset:asset error:nil];
    
    AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    
    if (videoTrack) {
        // 强制转换为最安全的底层色彩格式 NV12
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
// 4. API 拦截网
// ==========================================

%hook UIWindow
- (void)makeKeyAndVisible {
    %orig;
    [[LensBypassUIManager sharedInstance] setupHiddenGestureInWindow:self];
}
%end

// [保留]：劫持视频通道，阻止真实镜头数据流入 App
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    if (sampleBufferDelegate) {
        global_videoDelegate = sampleBufferDelegate;
        global_videoQueue = sampleBufferCallbackQueue;
        global_videoOutput = self; 
    }
    %orig(nil, nil); 
}
%end

// [重要]：我们完全删除了对 AVCaptureAudioDataOutput 的 hook！
// 这意味着宿主 App (TikTok) 现在会完完全全、正正常常地去连接并使用手机底部的物理麦克风。

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
