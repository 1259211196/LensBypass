#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

// ==========================================
// 1. 全局通信指针与状态
// ==========================================
static id<AVCaptureVideoDataOutputSampleBufferDelegate> global_videoDelegate = nil;
static id<AVCaptureAudioDataOutputSampleBufferDelegate> global_audioDelegate = nil;
static dispatch_queue_t global_videoQueue = nil;
static dispatch_queue_t global_audioQueue = nil;

static AVCaptureVideoDataOutput *global_videoOutput = nil;
static AVCaptureAudioDataOutput *global_audioOutput = nil;

#define DYNAMIC_VIDEO_CONN [global_videoOutput connectionWithMediaType:AVMediaTypeVideo]
#define DYNAMIC_AUDIO_CONN [global_audioOutput connectionWithMediaType:AVMediaTypeAudio]

static AVAssetReader *global_assetReader = nil;
static AVAssetReaderTrackOutput *global_videoTrackOutput = nil;
static AVAssetReaderTrackOutput *global_audioTrackOutput = nil;
static dispatch_source_t global_frameTimer = nil;

static NSString *dynamicVideoPath = nil; 
static CMTime global_timeOffset = {0, 0, 0, 0}; 
static BOOL isPlaying = NO;

// ==========================================
// 2. 哑巴替身 (Proxy Muting 核心防线)
// ==========================================
// 作用：接管真实硬件数据并扔进黑洞，防止 App 启用备用麦克风
@interface LensVideoProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@end
@implementation LensVideoProxy
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    // 收到真实摄像头画面，直接丢弃，不传给 App！
}
@end

@interface LensAudioProxy : NSObject <AVCaptureAudioDataOutputSampleBufferDelegate>
@end
@implementation LensAudioProxy
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    // 收到真实麦克风声音，直接丢弃，不传给 App！
}
@end

static LensVideoProxy *g_videoProxy = nil;
static LensAudioProxy *g_audioProxy = nil;

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
    picker.videoQuality = UIImagePickerControllerQualityTypeHigh; // 强制原画
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
// 4. 底层控制与重构模块
// ==========================================
static void startVirtualCameraLoop(void);

static void cleanupAssetReader() {
    if (global_assetReader) {
        [global_assetReader cancelReading];
        global_assetReader = nil;
        global_videoTrackOutput = nil;
        global_audioTrackOutput = nil;
    }
}

static void sendNextVirtualFrames() {
    if (!global_assetReader || global_assetReader.status != AVAssetReaderStatusReading) return;
    
    // --- A. 视频抽帧与锚点重铸 ---
    CMSampleBufferRef oldVideoBuffer = NULL;
    if (global_videoTrackOutput) oldVideoBuffer = [global_videoTrackOutput copyNextSampleBuffer];
    
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
            // 光学元数据注入
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

            [global_videoDelegate captureOutput:global_videoOutput didOutputSampleBuffer:newVideoBuffer fromConnection:DYNAMIC_VIDEO_CONN];
            CFRelease(newVideoBuffer);
        }
        if (formatDesc) CFRelease(formatDesc);
    }
    CFRelease(oldVideoBuffer);
    
    // --- B. 音频追赶循环 (解决丢声断层) ---
    while (global_audioTrackOutput) {
        CMSampleBufferRef oldAudioBuffer = [global_audioTrackOutput copyNextSampleBuffer];
        if (!oldAudioBuffer) break; 
        
        CMTime originalAudioPTS = CMSampleBufferGetPresentationTimeStamp(oldAudioBuffer);
        CMTime newAudioPTS = CMTimeAdd(originalAudioPTS, global_timeOffset);
        
        CMSampleTimingInfo newAudioTiming;
        newAudioTiming.presentationTimeStamp = newAudioPTS;
        newAudioTiming.decodeTimeStamp = kCMTimeInvalid;
        newAudioTiming.duration = CMSampleBufferGetDuration(oldAudioBuffer);
        
        CMSampleBufferRef newAudioBuffer = NULL;
        CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, oldAudioBuffer, 1, &newAudioTiming, &newAudioBuffer);
        
        if (newAudioBuffer && global_audioDelegate && global_audioOutput) {
            CMSampleBufferRef bufferToPass = newAudioBuffer;
            CFRetain(bufferToPass); // 保留引用防止被提前释放
            
            // [极其关键]：将音频精准推送到 App 要求的音频专线，绝不在视频线程投喂音频！
            if (global_audioQueue && global_audioQueue != global_videoQueue) {
                dispatch_async(global_audioQueue, ^{
                    [global_audioDelegate captureOutput:global_audioOutput didOutputSampleBuffer:bufferToPass fromConnection:DYNAMIC_AUDIO_CONN];
                    CFRelease(bufferToPass);
                });
            } else {
                [global_audioDelegate captureOutput:global_audioOutput didOutputSampleBuffer:bufferToPass fromConnection:DYNAMIC_AUDIO_CONN];
                CFRelease(bufferToPass);
            }
            CFRelease(newAudioBuffer);
        } else {
            if (newAudioBuffer) CFRelease(newAudioBuffer);
        }
        CFRelease(oldAudioBuffer);
        
        if (CMTimeCompare(newAudioPTS, newVideoPTS) >= 0) break;
    }
}

static void startVirtualCameraLoop() {
    if (!dynamicVideoPath) return;
    
    NSDictionary *options = @{ AVURLAssetPreferPreciseDurationAndTimingKey : @YES };
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:dynamicVideoPath] options:options];
    global_assetReader = [AVAssetReader assetReaderWithAsset:asset error:nil];
    
    AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    AVAssetTrack *audioTrack = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    
    if (videoTrack) {
        global_videoTrackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)}];
        [global_assetReader addOutput:global_videoTrackOutput];
    }
    
    if (audioTrack) {
        // [音频防排异核心]：强制重采样为 44.1kHz + 单声道 + 16位PCM！拒绝静默丢弃！
        NSDictionary *audioSettings = @{
            AVFormatIDKey: @(kAudioFormatLinearPCM),
            AVSampleRateKey: @(44100.0),      // 极其关键：对齐 iPhone 麦克风标准采样率
            AVNumberOfChannelsKey: @(1),      // 极其关键：对齐单声道
            AVLinearPCMBitDepthKey: @(16),
            AVLinearPCMIsFloatKey: @NO,
            AVLinearPCMIsBigEndianKey: @NO,
            AVLinearPCMIsNonInterleaved: @NO
        };
        global_audioTrackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack outputSettings:audioSettings];
        [global_assetReader addOutput:global_audioTrackOutput];
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

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    if (sampleBufferDelegate) {
        global_videoDelegate = sampleBufferDelegate;
        global_videoQueue = sampleBufferCallbackQueue;
        global_videoOutput = self; 
        
        // 派出替身，完美堵住真实摄像头的嘴，且骗过 App 的底层检测
        if (!g_videoProxy) g_videoProxy = [[LensVideoProxy alloc] init];
        %orig(g_videoProxy, sampleBufferCallbackQueue);
    } else {
        %orig;
    }
}
%end

%hook AVCaptureAudioDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureAudioDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    if (sampleBufferDelegate) {
        global_audioDelegate = sampleBufferDelegate;
        global_audioQueue = sampleBufferCallbackQueue;
        global_audioOutput = self; 
        
        // 派出替身，完美堵住真实麦克风的嘴，且骗过 App 的底层检测
        if (!g_audioProxy) g_audioProxy = [[LensAudioProxy alloc] init];
        %orig(g_audioProxy, sampleBufferCallbackQueue);
    } else {
        %orig;
    }
}
%end

%hook AVCaptureSession
- (void)startRunning {
    %orig;
    for (AVCaptureOutput *output in self.outputs) {
        if ([output isKindOfClass:[AVCaptureVideoDataOutput class]]) {
            global_videoConnection = [output connectionWithMediaType:AVMediaTypeVideo];
        } else if ([output isKindOfClass:[AVCaptureAudioDataOutput class]]) {
            global_audioConnection = [output connectionWithMediaType:AVMediaTypeAudio];
        }
    }
    
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
