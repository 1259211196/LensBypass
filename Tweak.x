#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <MobileCoreServices/MobileCoreServices.h>

// ==========================================
// 1. 全局通信指针与状态
// ==========================================
static id<AVCaptureVideoDataOutputSampleBufferDelegate> global_videoDelegate = nil;
static id<AVCaptureAudioDataOutputSampleBufferDelegate> global_audioDelegate = nil;
static dispatch_queue_t global_videoQueue = nil;
static dispatch_queue_t global_audioQueue = nil;
static AVCaptureConnection *global_videoConnection = nil;
static AVCaptureConnection *global_audioConnection = nil;

static AVAssetReader *global_assetReader = nil;
static AVAssetReaderTrackOutput *global_videoTrackOutput = nil;
static AVAssetReaderTrackOutput *global_audioTrackOutput = nil;
static dispatch_source_t global_frameTimer = nil;

static NSString *dynamicVideoPath = nil; 

// 增加全局时间差锚点，用于完美平移时间轴，保证音画 100% 同步
static CMTime global_timeOffset = {0, 0, 0, 0}; 
static BOOL isPlaying = NO;

// ==========================================
// 2. 潜行模式：隐形手势与相册控制器 (无UI注入版)
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

// 挂载隐形手势，代替悬浮窗
- (void)setupHiddenGestureInWindow:(UIWindow *)window {
    // 防止重复添加
    for (UIGestureRecognizer *gesture in window.gestureRecognizers) {
        if ([gesture.accessibilityLabel isEqualToString:@"LensBypassGesture"]) {
            return; 
        }
    }
    
    // 设置暗号：双指三击 (两个手指同时连续点3下屏幕)
    UITapGestureRecognizer *secretTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openAlbum)];
    secretTap.numberOfTouchesRequired = 2; // 需要两个手指
    secretTap.numberOfTapsRequired = 3;    // 需要点击三次
    secretTap.accessibilityLabel = @"LensBypassGesture"; // 打个内部标记防重复
    
    [window addGestureRecognizer:secretTap];
    NSLog(@"[LensBypass] 隐形手势注入成功，暗号：双指三击");
}

- (UIViewController *)topViewController {
    UIViewController *topController = [UIApplication sharedApplication].keyWindow.rootViewController;
    while (topController.presentedViewController) { topController = topController.presentedViewController; }
    return topController;
}

// 手势触发后直接弹出相册
- (void)openAlbum {
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.delegate = self;
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes = @[(NSString *)kUTTypeMovie, (NSString *)kUTTypeVideo]; 
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
            // 每次重新选片，重置底层时间锚点，准备开工
            global_timeOffset = kCMTimeInvalid;
            isPlaying = NO;
            NSLog(@"[LensBypass] 视频已就绪，潜行等待中...");
        }
    }
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}
@end

// ==========================================
// 3. 底层控制与重构模块
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
    if (global_videoTrackOutput) {
        oldVideoBuffer = [global_videoTrackOutput copyNextSampleBuffer];
    }
    
    // 视频播完检测与无缝循环
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
        
        if (newVideoBuffer && global_videoDelegate) {
            
            // 【核心补全】：注入物理光学元数据 (EXIF)，赋予视频帧真实摄像头的“灵魂”
            CFMutableDictionaryRef cameraEXIF = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            float fNumber = 1.5;
            int iso = 100;
            float exposure = 0.0;
            
            CFNumberRef fNumberRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat32Type, &fNumber);
            CFNumberRef isoRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &iso);
            CFNumberRef exposureRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat32Type, &exposure);
            
            CFDictionarySetValue(cameraEXIF, CFSTR("FNumber"), fNumberRef);
            CFDictionarySetValue(cameraEXIF, CFSTR("ISOSpeedRatings"), isoRef);
            CFDictionarySetValue(cameraEXIF, CFSTR("ExposureBiasValue"), exposureRef);
            
            // 绑定到当前帧
            CMSetAttachment(newVideoBuffer, CFSTR("MetadataDictionary"), cameraEXIF, kCMAttachmentMode_ShouldPropagate);
            
            // 内存闭环释放
            CFRelease(fNumberRef);
            CFRelease(isoRef);
            CFRelease(exposureRef);
            CFRelease(cameraEXIF);

            // 投喂带有真实连接与光学指纹的完美帧
            [global_videoDelegate captureOutput:nil didOutputSampleBuffer:newVideoBuffer fromConnection:global_videoConnection];
            CFRelease(newVideoBuffer);
        }
        if (formatDesc) CFRelease(formatDesc);
    }
    CFRelease(oldVideoBuffer);
    
    // --- B. 音频追赶循环 ---
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
        
        if (newAudioBuffer && global_audioDelegate) {
            [global_audioDelegate captureOutput:nil didOutputSampleBuffer:newAudioBuffer fromConnection:global_audioConnection];
            CFRelease(newAudioBuffer);
        }
        CFRelease(oldAudioBuffer);
        
        if (CMTimeCompare(newAudioPTS, newVideoPTS) >= 0) {
            break;
        }
    }
}

static void startVirtualCameraLoop() {
    if (!dynamicVideoPath) return;
    
    NSURL *videoURL = [NSURL fileURLWithPath:dynamicVideoPath];
    AVURLAsset *asset = [AVURLAsset assetWithURL:videoURL];
    global_assetReader = [AVAssetReader assetReaderWithAsset:asset error:nil];
    
    AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    AVAssetTrack *audioTrack = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    
    if (videoTrack) {
        global_videoTrackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)}];
        [global_assetReader addOutput:global_videoTrackOutput];
    }
    
    if (audioTrack) {
        global_audioTrackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack outputSettings:@{AVFormatIDKey: @(kAudioFormatLinearPCM)}];
        [global_assetReader addOutput:global_audioTrackOutput];
    }
    
    [global_assetReader startReading];
    isPlaying = YES;
    
    float nominalFPS = (videoTrack && videoTrack.nominalFrameRate > 0) ? videoTrack.nominalFrameRate : 30.0;
    
    if (global_videoQueue && !global_frameTimer) {
        global_frameTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, global_videoQueue);
        dispatch_source_set_timer(global_frameTimer, dispatch_walltime(NULL, 0), (1.0 / nominalFPS) * NSEC_PER_SEC, 0);
        dispatch_source_set_event_handler(global_frameTimer, ^{ 
            if(isPlaying) { sendNextVirtualFrames(); }
        });
        dispatch_resume(global_frameTimer);
    }
}


// ==========================================
// 4. API 拦截网
// ==========================================

%hook UIWindow
- (void)makeKeyAndVisible {
    %orig;
    // 调用新的手势注入方法
    [[LensBypassUIManager sharedInstance] setupHiddenGestureInWindow:self];
}
%end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    if (sampleBufferDelegate) {
        global_videoDelegate = sampleBufferDelegate;
        global_videoQueue = sampleBufferCallbackQueue;
    }
    %orig(nil, nil); // 切断真实镜头
}
%end

%hook AVCaptureAudioDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureAudioDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    if (sampleBufferDelegate) {
        global_audioDelegate = sampleBufferDelegate;
        global_audioQueue = sampleBufferCallbackQueue;
    }
    %orig(nil, nil); // 切断真实麦克风
}
%end

%hook AVCaptureSession
- (void)startRunning {
    %orig;
    
    // 获取真实设备的通信管道
    for (AVCaptureOutput *output in self.outputs) {
        if ([output isKindOfClass:[AVCaptureVideoDataOutput class]]) {
            global_videoConnection = [output connectionWithMediaType:AVMediaTypeVideo];
            NSLog(@"[LensBypass] 成功窃取真实视频 Connection: %@", global_videoConnection);
        } else if ([output isKindOfClass:[AVCaptureAudioDataOutput class]]) {
            global_audioConnection = [output connectionWithMediaType:AVMediaTypeAudio];
            NSLog(@"[LensBypass] 成功窃取真实音频 Connection: %@", global_audioConnection);
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
