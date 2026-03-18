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

// 动态存储相册选取的视频路径
static NSString *dynamicVideoPath = nil; 

// ==========================================
// 2. 悬浮窗与相册控制器 (UI交互层)
// ==========================================
// 使用常规的 Objective-C 语法在 Theos 中声明一个控制器来处理相册代理
@interface LensBypassUIManager : NSObject <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, strong) UIButton *floatingButton;
+ (instancetype)sharedInstance;
- (void)setupFloatingButtonInWindow:(UIWindow *)window;
@end

@implementation LensBypassUIManager

+ (instancetype)sharedInstance {
    static LensBypassUIManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
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
    
    // 添加拖拽手势
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.floatingButton addGestureRecognizer:pan];
    
    [window addSubview:self.floatingButton];
    NSLog(@"[LensBypass] 悬浮控制台注入成功");
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint point = [pan translationInView:self.floatingButton.superview];
    self.floatingButton.center = CGPointMake(self.floatingButton.center.x + point.x, self.floatingButton.center.y + point.y);
    [pan setTranslation:CGPointZero inView:self.floatingButton.superview];
}

// 寻找当前顶层视图控制器以弹出相册
- (UIViewController *)topViewController {
    UIViewController *topController = [UIApplication sharedApplication].keyWindow.rootViewController;
    while (topController.presentedViewController) {
        topController = topController.presentedViewController;
    }
    return topController;
}

- (void)openAlbum {
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.delegate = self;
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    // 限制只能选视频
    picker.mediaTypes = @[(NSString *)kUTTypeMovie, (NSString *)kUTTypeVideo, (NSString *)kUTTypeMPEG4]; 
    picker.videoExportPreset = AVAssetExportPresetHighestQuality;
    
    [[self topViewController] presentViewController:picker animated:YES completion:nil];
}

// 相册选取完成回调
- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];
    
    NSURL *videoURL = info[UIImagePickerControllerMediaURL];
    if (videoURL) {
        // [极度关键]：系统相册返回的是 tmp 目录下的临时文件，App 随时会清理。
        // 我们必须把它拷贝到 Documents 目录下固化下来。
        NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSString *destPath = [docPath stringByAppendingPathComponent:@"lensbypass_target.mp4"];
        
        NSError *error = nil;
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm fileExistsAtPath:destPath]) {
            [fm removeItemAtPath:destPath error:nil]; // 删掉旧的
        }
        [fm copyItemAtPath:videoURL.path toPath:destPath error:&error];
        
        if (!error) {
            dynamicVideoPath = destPath;
            [self.floatingButton setTitle:@"已载" forState:UIControlStateNormal];
            self.floatingButton.backgroundColor = [[UIColor greenColor] colorWithAlphaComponent:0.7];
            NSLog(@"[LensBypass] 视频已就绪，路径: %@", dynamicVideoPath);
        } else {
            NSLog(@"[LensBypass] 视频拷贝失败: %@", error);
        }
    }
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

@end


// ==========================================
// 3. 底层投喂核心：音视频双轨同步与时间重铸
// ==========================================

static void sendNextVirtualFrames() {
    if (!global_assetReader || global_assetReader.status != AVAssetReaderStatusReading) return;
    
    // 获取当前绝对系统时间，实现彻底的“岁月史书”
    CMTime currentSystemTime = CMClockGetTime(CMClockGetHostTimeClock());
    
    // --- 视频流处理 ---
    if (global_videoTrackOutput) {
        CMSampleBufferRef oldVideoBuffer = [global_videoTrackOutput copyNextSampleBuffer];
        if (oldVideoBuffer) {
            CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(oldVideoBuffer);
            if (pixelBuffer) {
                CMSampleTimingInfo newVideoTiming;
                newVideoTiming.presentationTimeStamp = currentSystemTime;
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
        } else {
            // 这里可以处理视频循环播放逻辑
        }
    }
    
    // --- 音频流处理 ---
    if (global_audioTrackOutput) {
        CMSampleBufferRef oldAudioBuffer = [global_audioTrackOutput copyNextSampleBuffer];
        if (oldAudioBuffer) {
            CMSampleTimingInfo newAudioTiming;
            newAudioTiming.presentationTimeStamp = currentSystemTime;
            newAudioTiming.decodeTimeStamp = kCMTimeInvalid;
            newAudioTiming.duration = CMSampleBufferGetDuration(oldAudioBuffer);
            
            CMSampleBufferRef newAudioBuffer = NULL;
            CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, oldAudioBuffer, 1, &newAudioTiming, &newAudioBuffer);
            
            if (newAudioBuffer && global_audioDelegate) {
                [global_audioDelegate captureOutput:nil didOutputSampleBuffer:newAudioBuffer fromConnection:global_audioConnection];
                CFRelease(newAudioBuffer);
            }
            CFRelease(oldAudioBuffer);
        }
    }
}

static void startVirtualCameraLoop() {
    if (!dynamicVideoPath || global_frameTimer) return; // 如果还没选视频，就不启动
    
    NSURL *videoURL = [NSURL fileURLWithPath:dynamicVideoPath];
    global_assetReader = [AVAssetReader assetReaderWithAsset:[AVURLAsset assetWithURL:videoURL] error:nil];
    
    AVAssetTrack *videoTrack = [[[AVURLAsset assetWithURL:videoURL] tracksWithMediaType:AVMediaTypeVideo] firstObject];
    AVAssetTrack *audioTrack = [[[AVURLAsset assetWithURL:videoURL] tracksWithMediaType:AVMediaTypeAudio] firstObject];
    
    if (videoTrack) {
        global_videoTrackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)}];
        [global_assetReader addOutput:global_videoTrackOutput];
    }
    
    if (audioTrack) {
        global_audioTrackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack outputSettings:@{AVFormatIDKey: @(kAudioFormatLinearPCM)}];
        [global_assetReader addOutput:global_audioTrackOutput];
    }
    
    [global_assetReader startReading];
    
    if (global_videoQueue) {
        global_frameTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, global_videoQueue);
        dispatch_source_set_timer(global_frameTimer, dispatch_walltime(NULL, 0), (1.0 / 30.0) * NSEC_PER_SEC, 0);
        dispatch_source_set_event_handler(global_frameTimer, ^{
            sendNextVirtualFrames();
        });
        dispatch_resume(global_frameTimer);
    }
}


// ==========================================
// 4. API 拦截网
// ==========================================

%hook UIWindow
// 拦截 Window 显示，注入悬浮按钮
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
    %orig(nil, nil); // 屏蔽真实相机
}
%end


%hook AVCaptureAudioDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureAudioDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    if (sampleBufferDelegate) {
        global_audioDelegate = sampleBufferDelegate;
        global_audioQueue = sampleBufferCallbackQueue;
    }
    %orig(nil, nil); // 屏蔽真实麦克风
}
%end


%hook AVCaptureSession
- (void)startRunning {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        startVirtualCameraLoop();
    });
}

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
}
%end
