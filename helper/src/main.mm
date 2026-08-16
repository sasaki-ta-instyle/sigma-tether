//
//  main.mm — Wave 1 PoC
//
//  目的: x86_64 helper が Rosetta 2 下で
//    (1) sgm_initializeSDK に成功する
//    (2) ImageCaptureCore で SIGMA fp/fpL を検出できる
//    (3) [camera requestOpenSession] → sgm_CamOpen → sgm_ConfigAPI に成功する
//    (4) ImageQuality を DNG に設定できる
//    (5) SnapCommand で 1 枚シャッターを切れる
//    (6) GetCamCaptStatus をポーリングして 0x8003 (画像保存完了) を検出できる
//    (7) GetPictFileInfo2 で FileCount を確認できる
//    (8) GetBigPartialPictFile を反復して 1 枚の DNG バイト列を取り出せる
//    (9) 得られたバイト列を ~/Desktop/sigma-tether-YYYYMMDD-HHMMSS.dng に保存
//   (10) sgm_CloseApplication → sgm_CamClose → sgm_terminateSDK で綺麗に落とす
//
//  実行方法: helper/Makefile で `make` → `./build/sigma-tether-helper`
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <ImageCaptureCore/ImageCaptureCore.h>
#import "SDKGateway.h"

#include <sys/stat.h>
#include <unistd.h>

// --------------------------------------------------------------------------
// ロギング
// --------------------------------------------------------------------------

static void LogInfo(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stderr, "[info] %s\n", s.UTF8String);
}

static void LogErr(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stderr, "[err ] %s\n", s.UTF8String);
}

static void LogSdk(NSString *op, int rc) {
    if (SgmSucceeded(rc)) {
        fprintf(stderr, "[sdk ] %-32s OK\n", op.UTF8String);
    } else {
        fprintf(stderr, "[sdk ] %-32s FAIL rc=0x%08x\n", op.UTF8String, (unsigned)rc);
    }
}

// --------------------------------------------------------------------------
// PTP trace: SIGMA_TETHER_TRACE=1 のとき、各 SDK 呼び出し後に
// sgm_GetLastCommandData で直前送受信の生バイトを吐く。
// Phase 1.5 (arm64 native 化) の PTP プロトコル解読の一次データにする。
// --------------------------------------------------------------------------

static BOOL g_traceEnabled = NO;

static void HexDumpBrief(const char *label, NSData *data, NSUInteger maxBytes) {
    if (!data) { fprintf(stderr, "[ptp ] %s: (nil)\n", label); return; }
    NSUInteger n = MIN(data.length, maxBytes);
    const UInt8 *b = (const UInt8 *)data.bytes;
    fprintf(stderr, "[ptp ] %s: len=%lu head=", label, (unsigned long)data.length);
    for (NSUInteger i = 0; i < n; i++) fprintf(stderr, "%02x", b[i]);
    if (data.length > n) fprintf(stderr, "...");
    fprintf(stderr, "\n");
}

static void TraceLastPTP(NSString *op) {
    if (!g_traceEnabled) return;
    NSData *sent = nil, *received = nil;
    int rc = [DeviceInterface sgm_GetLastCommandData:&sent resData:&received];
    if (!SgmSucceeded(rc)) {
        fprintf(stderr, "[ptp ] %s: GetLastCommandData FAIL rc=0x%08x\n", op.UTF8String, (unsigned)rc);
        return;
    }
    fprintf(stderr, "[ptp ] --- %s ---\n", op.UTF8String);
    HexDumpBrief("sent    ", sent, 64);
    HexDumpBrief("received", received, 64);
}

// --------------------------------------------------------------------------
// ICBrowser / ICCameraDevice delegate
// --------------------------------------------------------------------------

@interface CameraFinder : NSObject <ICDeviceBrowserDelegate, ICDeviceDelegate, ICCameraDeviceDelegate>
@property (nonatomic, strong, nullable) ICCameraDevice *camera;
@property (nonatomic, assign) BOOL sessionOpened;
@property (nonatomic, assign) BOOL contentCatalogReady;   // ← ★ ptpcamerad enumerate 完了フラグ
@property (nonatomic, strong, nullable) NSError *sessionError;
@end

@implementation CameraFinder

- (void)deviceBrowser:(ICDeviceBrowser *)browser
         didAddDevice:(ICDevice *)addedDevice
           moreComing:(BOOL)moreComing {
    LogInfo(@"deviceBrowser didAddDevice: name=%@ type=0x%lx",
            addedDevice.name, (unsigned long)addedDevice.type);

    if (![addedDevice isKindOfClass:[ICCameraDevice class]]) return;
    ICCameraDevice *cam = (ICCameraDevice *)addedDevice;

    if (!(cam.capabilities && [cam.capabilities containsObject:ICCameraDeviceCanAcceptPTPCommands])) {
        LogInfo(@"  → skip: not PTP-capable");
        return;
    }

    if (self.camera == nil) {
        self.camera = cam;
        cam.delegate = self;
        LogInfo(@"  → adopted as target, calling [cam requestOpenSession]");
        // NOTE: SampleAPP のシンボル strings で確認 (2026-08-17):
        //       SampleAPP は sgm_CamOpen: を呼ばず、素の requestOpenSession
        //       だけでセッションを開いていた。sgm_CamOpen を挟むと
        //       sgm_ConfigAPI がハングする挙動あり (原因は未特定だが避けるのが確実)。
        [cam requestOpenSession];
    }
}

- (void)deviceBrowser:(ICDeviceBrowser *)browser
      didRemoveDevice:(ICDevice *)device
             moreGoing:(BOOL)moreGoing {
    LogInfo(@"deviceBrowser didRemoveDevice: name=%@", device.name);
}

// --- ICDeviceDelegate ---

- (void)didRemoveDevice:(ICDevice *)device {
    LogInfo(@"didRemoveDevice: %@", device.name);
}

- (void)device:(ICDevice *)device didOpenSessionWithError:(NSError *)error {
    if (error) {
        LogErr(@"didOpenSessionWithError: %@", error);
        self.sessionError = error;
    } else {
        LogInfo(@"didOpenSessionWithError: (no error, session opened)");
    }
    self.sessionOpened = YES;
}

- (void)device:(ICDevice *)device didCloseSessionWithError:(NSError *)error {
    LogInfo(@"didCloseSessionWithError: %@", error);
}

- (void)deviceDidBecomeReady:(ICDevice *)device {
    LogInfo(@"deviceDidBecomeReady: %@", device.name);
}

// --- ICCameraDeviceDelegate stubs ---

- (void)cameraDevice:(ICCameraDevice *)camera didAddItems:(NSArray<ICCameraItem *> *)items { }
- (void)cameraDevice:(ICCameraDevice *)camera didRemoveItems:(NSArray<ICCameraItem *> *)items { }
- (void)cameraDevice:(ICCameraDevice *)camera didRenameItems:(NSArray<ICCameraItem *> *)items { }
- (void)cameraDevice:(ICCameraDevice *)camera didReceiveThumbnail:(CGImageRef)thumbnail forItem:(ICCameraItem *)item error:(NSError *)error { }
- (void)cameraDevice:(ICCameraDevice *)camera didReceiveMetadata:(NSDictionary *)metadata forItem:(ICCameraItem *)item error:(NSError *)error { }
- (void)cameraDeviceDidChangeCapability:(ICCameraDevice *)camera { }
- (void)cameraDeviceDidEnableAccessRestriction:(ICDevice *)device { }
- (void)cameraDeviceDidRemoveAccessRestriction:(ICDevice *)device { }
- (void)cameraDevice:(ICCameraDevice *)camera didReceivePTPEvent:(NSData *)eventData {
    LogInfo(@"didReceivePTPEvent: %lu bytes", (unsigned long)eventData.length);
}
- (void)deviceDidBecomeReadyWithCompleteContentCatalog:(ICCameraDevice *)device {
    LogInfo(@"deviceDidBecomeReadyWithCompleteContentCatalog: %@ (PTP コマンド発行可能)", device.name);
    self.contentCatalogReady = YES;
}

@end

// --------------------------------------------------------------------------
// メインフロー
// --------------------------------------------------------------------------

static NSString * DesktopOutputPath(void) {
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *stamp = [fmt stringFromDate:[NSDate date]];
    NSString *desktop = [NSHomeDirectory() stringByAppendingPathComponent:@"Desktop"];
    return [NSString stringWithFormat:@"%@/sigma-tether-%@.dng", desktop, stamp];
}

// カメラを見つける (セッション Open は sgm_CamOpen 側でやるのでここでは待たない)
// browser は返り値 (out 引数) で main に渡して、operation 全部が終わるまで
// stop せず保持する。stop すると IC framework が device を無効化する挙動あり。
static BOOL FindCamera(CameraFinder *finder,
                       ICDeviceBrowser * __strong *outBrowser,
                       NSTimeInterval timeout) {
    ICDeviceBrowser *browser = [ICDeviceBrowser new];
    browser.delegate = finder;
    browser.browsedDeviceTypeMask =
        (ICDeviceTypeMask)(ICDeviceTypeMaskCamera | ICDeviceLocationTypeMaskLocal);
    [browser start];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!finder.camera &&
           [deadline compare:[NSDate date]] == NSOrderedDescending) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    if (!finder.camera) {
        LogErr(@"タイムアウト: SIGMA カメラが検出されなかった (%.1f 秒)", timeout);
        [browser stop];
        return NO;
    }
    *outBrowser = browser;   // caller が保持
    return YES;
}

// sgm_CamOpen 発行後、didOpenSessionWithError と
// deviceDidBecomeReadyWithCompleteContentCatalog: の両方を待つ。
// 後者は ptpcamerad の content 列挙が完了して PTP コマンドが受け付け可能に
// なったことを意味する (SIGMA SampleAPP のログ「PTP camera 'SIGMA fp L' is ready」
// に対応)。この待ちを入れないと sgm_ConfigAPI が PTP 応答を得られずハングする。
static BOOL WaitForCameraReady(CameraFinder *finder, NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ((!finder.sessionOpened || !finder.contentCatalogReady) &&
           [deadline compare:[NSDate date]] == NSOrderedDescending) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    if (!finder.sessionOpened) {
        LogErr(@"タイムアウト: didOpenSessionWithError が来なかった (%.1f 秒)", timeout);
        return NO;
    }
    if (finder.sessionError) {
        LogErr(@"session open error: %@", finder.sessionError);
        return NO;
    }
    if (!finder.contentCatalogReady) {
        LogErr(@"タイムアウト: deviceDidBecomeReadyWithCompleteContentCatalog: が来なかった (%.1f 秒)", timeout);
        return NO;
    }
    return YES;
}

// 単発撮影 → 完了待ち。imageID を out で返す
static BOOL ShootOne(ICCameraDevice *cam, UInt8 *outImageID, NSTimeInterval timeout) {
    SgmSnapState snap = { .CaptureMode = 0x01, .CaptureAmount = 0x01 };
    int rc = [sgm_SnapCommand sgm_SnapCommand:&snap cameraHandle:cam];
    LogSdk(@"sgm_SnapCommand", rc);
    TraceLastPTP(@"sgm_SnapCommand");
    if (!SgmSucceeded(rc)) return NO;

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([deadline compare:[NSDate date]] == NSOrderedDescending) {
        SgmCapStatus st = {};
        int r2 = [sgm_GetCamCaptStatus sgm_GetCamCaptStatus:&st
                                                    imageID:0
                                               cameraDevice:cam];
        if (!SgmSucceeded(r2)) {
            LogSdk(@"sgm_GetCamCaptStatus", r2);
            return NO;
        }
        fprintf(stderr, "[poll] CaptStatus=0x%04x  ImageID=%u  DBHead=%u  DBTail=%u  Dest=0x%02x\n",
                st.CaptStatus, st.ImageID, st.ImageDBHead, st.ImageDBTail, st.DestToSave);

        switch ((SgmCaptStatus)st.CaptStatus) {
            case SgmCaptStatusImageSaved:
                *outImageID = st.ImageID;
                return YES;
            case SgmCaptStatusAFFail:
            case SgmCaptStatusBufferFull:
            case SgmCaptStatusCWBFail:
            case SgmCaptStatusImageGenFail:
            case SgmCaptStatusGeneralFail:
                LogErr(@"CaptStatus error: 0x%04x", st.CaptStatus);
                return NO;
            default:
                break;
        }
        usleep(100 * 1000);
    }
    LogErr(@"CaptStatus タイムアウト (%.1f 秒)", timeout);
    return NO;
}

// ImageID の picture を chunk 分割で全部取ってきて連結
static NSData * DownloadPicture(ICCameraDevice *cam, UInt8 imageID) {
    SgmPictureFileInfoData2 info = {};
    int rc = [sgm_GetPictFileInfo2 sgm_GetPictFileInfo2:&info cameraHandle:cam];
    LogSdk(@"sgm_GetPictFileInfo2", rc);
    TraceLastPTP(@"sgm_GetPictFileInfo2");
    if (!SgmSucceeded(rc)) return nil;
    LogInfo(@"PictFileInfo2: DataLength=%u FileCount=%u", info.DataLength, info.FileCount);

    const UInt32 storeAddress = imageID;
    const UInt32 chunkSize    = 1024 * 1024;
    const UInt32 hardLimit    = 200 * 1024 * 1024;

    NSMutableData *acc = [NSMutableData dataWithCapacity:8 * 1024 * 1024];
    UInt32 offset = 0;
    for (int i = 0; ; i++) {
        UInt8  *buf  = NULL;
        UInt32  got  = 0;
        int r = [sgm_GetBigPartialPictFile sgm_GetBigPartialPictFile:storeAddress
                                                                start:offset
                                                               length:chunkSize
                                                                 data:&buf
                                                             dataSize:&got
                                                         cameraHandle:cam];
        if (!SgmSucceeded(r)) {
            LogSdk([NSString stringWithFormat:@"sgm_GetBigPartialPictFile[%d]", i], r);
            if (buf) free(buf);
            return nil;
        }
        fprintf(stderr, "[dl  ] chunk[%d] offset=%u got=%u bytes\n", i, offset, got);
        if (got == 0) {
            if (buf) free(buf);
            break;
        }
        [acc appendBytes:buf length:got];
        if (buf) free(buf);
        offset += got;
        if (got < chunkSize) break;
        if (offset > hardLimit) {
            LogErr(@"hard limit 到達 (%u bytes)、中断", hardLimit);
            break;
        }
    }
    return acc;
}

// 接続後の一連の作業。teardown は呼び出し側で必ず実行するので、
// ここは早期 return が許される (goto 不要)。
static int RunCaptureSequence(ICCameraDevice *cam) {
    // 事前 warm-up: SampleAPP は ConfigAPI 前に GetCamStatus2 を polling する。
    // これを叩かないと ConfigAPI がハングする可能性が高いので、まず 2 回叩く。
    for (int i = 0; i < 2; i++) {
        UInt8 statusBuf[128] = {0};
        UInt32 recvLen = 0;
        int rs = [sgm_GetCamStatus2 sgm_GetCamStatus2:statusBuf
                                            buffLength:sizeof(statusBuf)
                                            recvLength:&recvLen
                                        operationCode1:0
                                        operationCode2:0
                                        operationCode3:0
                                          cameraHandle:cam];
        LogSdk([NSString stringWithFormat:@"sgm_GetCamStatus2[%d]", i], rs);
        if (!SgmSucceeded(rs)) {
            LogErr(@"CameraStatus polling failed at iter=%d, continuing anyway", i);
        }
        usleep(300 * 1000);  // 300ms 間隔 (SampleAPP と同じ)
    }

    // sgm_ConfigAPI: 有効な SgmAdjustmentConfig 構造体を渡す
    // (NULL 渡しはハング、PDF 上「出力として APIConfig IFD が返る」ため実体が必要)
    SgmAdjustmentConfig apiConfig = { .dataLength = 0, .directoryCount = 0, .directoryEntry = NULL };
    int rc = [sgm_ConfigAPI sgm_ConfigAPI:&apiConfig
                          AdjustmentMode:0
                            cameraHandle:cam];
    LogSdk(@"sgm_ConfigAPI", rc);
    TraceLastPTP(@"sgm_ConfigAPI");
    if (!SgmSucceeded(rc)) return 3;
    LogInfo(@"APIConfig: dataLength=%u directoryCount=%u", apiConfig.dataLength, apiConfig.directoryCount);

    // ImageQuality = DNG (0x10) を書き込む
    SgmDataGroup2 dg2 = {};
    dg2.ImageQuality = SgmImageQualityDng;
    int rw = [sgm_SetCamDataGroup2 sgm_SetCamDataGroup2:&dg2
                                          fieldPresent1:0
                                          fieldPresent2:SgmDG2_FP2_ImageQuality
                                           cameraHandle:cam];
    LogSdk(@"SetCamDataGroup2 (DNG)", rw);
    TraceLastPTP(@"SetCamDataGroup2 (DNG)");
    if (!SgmSucceeded(rw)) return 4;

    // 撮影 → CaptStatus 完了待ち
    UInt8 imageID = 0;
    if (!ShootOne(cam, &imageID, 30.0)) return 5;
    LogInfo(@"撮影完了 imageID=%u", imageID);

    // chunk ダウンロード
    NSData *dng = DownloadPicture(cam, imageID);
    if (!dng || dng.length == 0) {
        LogErr(@"ダウンロード失敗 or 空データ");
        return 6;
    }
    LogInfo(@"ダウンロード完了 %lu bytes", (unsigned long)dng.length);

    // デスクトップに保存
    NSString *outPath = DesktopOutputPath();
    NSError *werr = nil;
    if (![dng writeToFile:outPath options:NSDataWritingAtomic error:&werr]) {
        LogErr(@"保存失敗: %@", werr);
        return 7;
    }
    LogInfo(@"保存成功: %@", outPath);

    // DB クリア
    int rClr = [sgm_ClearImageDBSingle sgm_ClearImageDBSingle:imageID cameraHandle:cam];
    LogSdk(@"sgm_ClearImageDBSingle", rClr);
    return 0;
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        LogInfo(@"===== sigma-tether helper Wave 1 PoC =====");
        LogInfo(@"process arch: %s", (sizeof(void*) == 8 ? "64-bit" : "32-bit"));
        LogInfo(@"mainBundle bundlePath: %@", [NSBundle mainBundle].bundlePath);
        LogInfo(@"mainBundle infoDict: %@", [NSBundle mainBundle].infoDictionary);

        // NOTE: NSApplication の初期化は 「カメラ検出 + Ready 待ち」 完了後に
        // 行う。sharedApplication を早期に呼ぶと ICBrowser の device add
        // callback が来なくなる (macOS 15 実測、2026-08-17)。
        // sgm_ConfigAPI 段階でだけ NSApp.run が必要なので、遅延初期化する。

        // trace 有効判定 (SIGMA_TETHER_TRACE=1)
        const char *traceEnv = getenv("SIGMA_TETHER_TRACE");
        g_traceEnabled = (traceEnv && strcmp(traceEnv, "1") == 0);
        if (g_traceEnabled) LogInfo(@"PTP trace enabled (SIGMA_TETHER_TRACE=1)");

        // (1) SDK 初期化
        int rc = [DeviceInterface sgm_initializeSDK];
        LogSdk(@"sgm_initializeSDK", rc);
        if (!SgmSucceeded(rc)) return 1;

        // ComLog: SampleAPP と同じく最初に叩いておく (内部状態の初期化に必要な可能性)
        [DeviceInterface sgm_SetComLogFunc:^{
            fprintf(stderr, "[com ] (ComLog block invoked)\n");
        }];
        [DeviceInterface sgm_SetIsCallComLogFunc:YES];
        LogInfo(@"sgm_SetComLogFunc + sgm_SetIsCallComLogFunc(YES) installed");

        // (2) カメラ検出のみ (session open はまだしない)
        CameraFinder *finder = [CameraFinder new];
        ICDeviceBrowser *browser = nil;
        if (!FindCamera(finder, &browser, 30.0)) {
            [DeviceInterface sgm_terminateSDK];
            return 2;
        }
        ICCameraDevice *cam = finder.camera;
        LogInfo(@"camera adopted: name=%@", cam.name);

        // (3) [cam requestOpenSession] は didAddDevice 内で既に発行済み。
        //     session open + content catalog 完了 を待つ (SampleAPP と同じ順序)
        //     sgm_CamOpen は SampleAPP でも呼ばれていないため使わない。
        if (!WaitForCameraReady(finder, 30.0)) {
            [browser stop];
            [DeviceInterface sgm_terminateSDK];
            return 3;
        }
        LogInfo(@"camera fully ready, entering capture sequence");

        // ここで初めて NSApplication を用意し、NSApp.run で本格的な Cocoa
        // event loop に入る。sgm_ConfigAPI 等の SDK 呼び出しは requestSendPTPCommand
        // のコールバックがメインスレッドで dispatch されるのに依存しているため。
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        // NSApp.run が Cocoa event loop を start してから、メインキューに
        // sgm_ 呼び出しを dispatch する。SampleAPP のボタンハンドラと同じ
        // 挙動: sgm_ はメインスレッドで実行され、SGMLock 内で待機する間も
        // ICC の XPC callback は別キューで走って正常に応答を返す想定。
        __block int runRc = -1;
        dispatch_async(dispatch_get_main_queue(), ^{
            runRc = RunCaptureSequence(cam);
            [NSApp stop:nil];
            NSEvent *wake = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                              location:NSMakePoint(0, 0)
                                         modifierFlags:0
                                             timestamp:0
                                          windowNumber:0
                                               context:nil
                                               subtype:0
                                                 data1:0
                                                 data2:0];
            [NSApp postEvent:wake atStart:YES];
        });
        [NSApp run];
        LogInfo(@"RunCaptureSequence rc=%d", runRc);

        // teardown (常に実行)。SampleAPP と同じく sgm_CamClose は呼ばない、
        // requestCloseSession だけを使う。
        LogInfo(@"===== teardown =====");
        int rClose = [sgm_CloseApplication sgm_CloseApplication:cam];
        LogSdk(@"sgm_CloseApplication", rClose);
        TraceLastPTP(@"sgm_CloseApplication");
        [cam requestCloseSession];
        [browser stop];
        int rTerm = [DeviceInterface sgm_terminateSDK];
        LogSdk(@"sgm_terminateSDK", rTerm);

        return runRc;
    }
}
