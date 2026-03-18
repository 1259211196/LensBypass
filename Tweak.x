#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

// ==========================================
// 1. 全局通信指针与状态
// ==========================================
static id<AVCaptureVideoDataOutputSampleBufferDelegate> global_videoDelegate = nil;
static dispatch_queue_t global_videoQueue = nil;
static AVCaptureVideoDataOutput *global_videoOutput = nil;

// [动态连线宏] 确保随时拿到最新视频连线
#define DYNAMIC_VIDEO_CONN [global_videoOutput connectionWithMediaType:AVMediaTypeVideo]

static AVAssetReader *global_assetReader = nil;
static AVAssetReaderTrackOutput *global_videoTrackOutput = nil;
static dispatch_source_t global_frameTimer = nil;

// 引入系统原生音频播放器（物理声学回环核心）
static AVAudioPlayer *global_audioPlayer = nil;

static NSString *dynamicVideoPath = nil; 
static CMTime global_timeOffset = {0, 0, 0, 0}; 
static BOOL isPlaying = NO;

// ==========================================
// 2. 视频哑巴替身 (Proxy Muting 核心防线)
// ==========================================
// 作用：接管真实摄像头数据并扔进黑洞，防止 App 报错崩溃
@interface LensVideoProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@end
@implementation LensVideoProxy
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    // 收到真实摄像头画面，直接丢弃，不传给 App
}
@end

static LensVideoProxy *g_videoProxy = nil;

// ==========================================
// 3. 潜行模式：隐形手势与相册控制器
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
    // 暗号：双指三击屏幕任意位置
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
    picker.videoQuality = UIImagePickerControllerQualityTypeHigh; // 强制原画直出，拒绝压缩
    [[self topViewController] presentViewController:picker animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];
    NSURL *videoURL = info[UIImagePickerControllerMediaURL];
    if (videoURL) {
        // 沙盒越权：将 tmp 文件固化到 Documents 防止被系统意外清理
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
            // 静默确认暗号：手机马达轻微震动
            UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            [feedback impactOccurred];
        }
    }
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}
@end

// ==========================================
// 4. 底层投喂与声学回环模块
// ==========================================
static void startVirtualCameraLoop(void);

static void cleanupAssetReader() {
    if (global_assetReader) {
        [global_assetReader cancelReading];
        global_assetReader = nil;
        global_videoTrackOutput = nil;
    }
    // 同步停止音频外放
    if (global_audioPlayer) {
        [global_audioPlayer stop];
        global_audioPlayer = nil;
    }
}

static void sendNextVirtualFrames() {
    if (!global_assetReader || global_assetReader.status != AVAssetReaderStatusReading) return;
    
    CMSampleBufferRef oldVideoBuffer = NULL;
    if (global_videoTrackOutput) oldVideoBuffer = [global_videoTrackOutput copyNextSampleBuffer];
    
    // 视频播完，触发底层无缝循环，重新对齐时间锚点
    if (!oldVideoBuffer) {
        cleanupAssetReader();
        global_timeOffset = kCMTimeInvalid; 
        startVirtualCameraLoop();
        return; 
    }
    
    // 【核心一：岁月史书时间重铸】
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
            // 【核心二：物理光学元数据注入 EXIF】
            CFMutableDictionaryRef cameraEXIF = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            float fNumber = 1.5; int iso = 100; float exposure = 0.0;
            CFNumberRef fNumberRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat32Type, &fNumber);
            CFNumberRef isoRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &iso);
            CFNumberRef exposureRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat32Type, &exposure);
            
            CFDictionarySetValue(cameraEXIF, CFSTR("FNumber"), fNumberRef);
            CFDictionarySetValue(cameraEXIF, CFSTR("ISOSpeedRatings"), isoRef);
            CFDictionarySetValue(cameraEXIF, CFSTR("ExposureBiasValue"), exposureRef);
            
            CMSetAttachment(newVideoBuffer, CFSTR("MetadataDictionary"), cameraEXIF, kCMAttachmentMode_ShouldPropagate);
            
            // 内存释放闭环
            CFRelease(fNumberRef); CFRelease(isoRef); CFRelease(exposureRef); CFRelease(cameraEXIF);

            // 动态连线投喂视频帧
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
    
    // 【核心三：物理声学回环外放】
    // 强制扬声器播放原视频声音，配合未被 Hook 的真实麦克风实现原生级录制
    NSError *audioError = nil;
    global_audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:videoURL error:&audioError];
    if (global_audioPlayer) {
        [global_audioPlayer setVolume:1.0];
        [global_audioPlayer prepareToPlay];
        [global_audioPlayer play];
    }
    
    // 强制精确读取，拒绝系统为了省电而引发的丢帧
    NSDictionary *options = @{ AVURLAssetPreferPreciseDurationAndTimingKey : @YES };
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:videoURL options:options];
    global_assetReader = [AVAssetReader assetReaderWithAsset:asset error:nil];
    
    AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    
    if (videoTrack) {
        // 输出最安全的 NV12 格式
        global_videoTrackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)}];
        [global_assetReader addOutput:global_videoTrackOutput];
    }
    
    [global_assetReader startReading];
    isPlaying = YES;
    
    // 动态帧率自适应
    float nominalFPS = (videoTrack && videoTrack.nominalFrameRate > 0) ? videoTrack.nominalFrameRate : 30.0;
    
    if (global_videoQueue && !global_frameTimer) {
        global_frameTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, global_videoQueue);
        dispatch_source_set_timer(global_frameTimer, dispatch_walltime(NULL, 0), (1.0 / nominalFPS) * NSEC_PER_SEC, 0);
        dispatch_source_set_event_handler(global_frameTimer, ^{ if(isPlaying) sendNextVirtualFrames(); });
        dispatch_resume(global_frameTimer);
    }
}

// ==========================================
// 5. API 拦截网
// ==========================================
%hook UIWindow
- (void)makeKeyAndVisible {
    %orig;
    [[LensBypassUIManager sharedInstance] setupHiddenGestureInWindow:self];
}
%end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    if (sampleBufferDelegate) {
        global_videoDelegate = sampleBufferDelegate;
        global_videoQueue = sampleBufferCallbackQueue;
        global_videoOutput = self; 
        
        // 派出替身，完美堵住真实摄像头的嘴
        if (!g_videoProxy) g_videoProxy = [[LensVideoProxy alloc] init];
        %orig(g_videoProxy, sampleBufferCallbackQueue);
    } else {
        %orig;
    }
}
%end

// [重要提示]：已经彻底删除对 AVCaptureAudioDataOutput 的所有 Hook
// 让真实麦克风畅通无阻，用来收录我们喇叭放出来的物理声音！

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
