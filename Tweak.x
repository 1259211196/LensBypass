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

// [终极优化 1]：增加全局时间差锚点，用于完美平移时间轴，保证音画 100% 同步
static CMTime global_timeOffset = {0, 0, 0, 0}; 
static BOOL isPlaying = NO;

// ==========================================
// 2. 悬浮窗与相册控制器 (保持不变)
// ==========================================
@interface LensBypassUIManager : NSObject <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, strong) UIButton *floatingButton;
+ (instancetype)sharedInstance;
- (void)setupFloatingButtonInWindow:(UIWindow *)window;
@end

@implementation LensBypassUIManager
+ (instancetype)sharedInstance {
    static LensBypassUIManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}
- (void)setupFloatingButtonInWindow:(UIWindow *)window {
    if (self.floatingButton) return;
    self.floatingButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatingButton.frame = CGRectMake(20, 100, 60, 60);
    self.floatingButton.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.7];
    self.floatingButton.layer.cornerRadius = 30;
    [self.floatingButton setTitle:@"选片" forState:UIControlStateNormal];
    [self.floatingButton addTarget:self action:@selector(openAlbum) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.floatingButton addGestureRecognizer:pan];
    [window addSubview:self.floatingButton];
}
- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint point = [pan translationInView:self.floatingButton.superview];
    self.floatingButton.center = CGPointMake(self.floatingButton.center.x + point.x, self.floatingButton.center.y + point.y);
    [pan setTranslation:CGPointZero inView:self.floatingButton.superview];
}
- (UIViewController *)topViewController {
    UIViewController *topController = [UIApplication sharedApplication].keyWindow.rootViewController;
    while (topController.presentedViewController) { topController = topController.presentedViewController; }
    return topController;
}
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
            [self.floatingButton setTitle:@"已载" forState:UIControlStateNormal];
            self.floatingButton.backgroundColor = [[UIColor greenColor] colorWithAlphaComponent:0.7];
            
            // 如果更换了视频，强制重置状态
            global_timeOffset = kCMTimeInvalid;
            isPlaying = NO;
        }
    }
}
- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}
@end

// ==========================================
// 3. 底层控制与重构模块 (终极进化版)
// ==========================================

// 提前声明循环播放函数
static void startVirtualCameraLoop(void);

// 资源清理小助手
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
    
    // [终极优化 2]：视频播完检测与无缝循环 (EOF Check & Loop)
    if (!oldVideoBuffer) {
        cleanupAssetReader();
        // 循环时必须废弃旧的锚点，让下一轮重新对齐当前时间
        global_timeOffset = kCMTimeInvalid; 
        startVirtualCameraLoop();
        return; 
    }
    
    // 获取原视频的旧时间戳
    CMTime originalVideoPTS = CMSampleBufferGetPresentationTimeStamp(oldVideoBuffer);
    
    // 如果是第一帧，计算并锁定时间差锚点 (当前真实系统时间 - 视频原本的旧时间)
    if (CMTIME_IS_INVALID(global_timeOffset)) {
        CMTime now = CMClockGetTime(CMClockGetHostTimeClock());
        global_timeOffset = CMTimeSubtract(now, originalVideoPTS);
    }
    
    // 【核心平移算法】：新时间 = 旧时间 + 锚点差值。完美保留了微秒级的帧间距！
    CMTime newVideoPTS = CMTimeAdd(originalVideoPTS, global_timeOffset);
    
    // 重建视频帧
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
            [global_videoDelegate captureOutput:nil didOutputSampleBuffer:newVideoBuffer fromConnection:global_videoConnection];
            CFRelease(newVideoBuffer);
        }
        if (formatDesc) CFRelease(formatDesc);
    }
    CFRelease(oldVideoBuffer);
    
    // --- B. 音频追赶循环 (解决 Audio Pump Bug) ---
    // [终极优化 3]：音频不再盲目投喂。它会连续抽取，直到它的新时间戳“追平”刚刚投喂的视频时间戳
    while (global_audioTrackOutput) {
        CMSampleBufferRef oldAudioBuffer = [global_audioTrackOutput copyNextSampleBuffer];
        if (!oldAudioBuffer) break; // 音频轨读完
        
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
        
        // 如果这帧音频的时间已经赶上了视频时间，跳出循环，等待下一次定时器
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
        // [终极优化 4]：强制输出为 NV12，这是 iOS AVFoundation 最底层最安全的色彩格式，极大降低了因格式不对导致的崩溃
        global_videoTrackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)}];
        [global_assetReader addOutput:global_videoTrackOutput];
    }
    
    if (audioTrack) {
        global_audioTrackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack outputSettings:@{AVFormatIDKey: @(kAudioFormatLinearPCM)}];
        [global_assetReader addOutput:global_audioTrackOutput];
    }
    
    [global_assetReader startReading];
    isPlaying = YES;
    
    // [终极优化 5]：动态帧率自适应。不再写死 30fps。原视频是多少帧，我们就设多快的定时器！
    float nominalFPS = (videoTrack && videoTrack.nominalFrameRate > 0) ? videoTrack.nominalFrameRate : 30.0;
    
    if (global_videoQueue && !global_frameTimer) {
        global_frameTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, global_videoQueue);
        // 按视频真实帧率触发
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
    [[LensBypassUIManager sharedInstance] setupFloatingButtonInWindow:self];
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
    global_timeOffset = kCMTimeInvalid; // 每次开机重置时间锚点
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
