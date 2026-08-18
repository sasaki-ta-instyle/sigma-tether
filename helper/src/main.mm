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
#import <objc/runtime.h>
#import "SDKGateway.h"

#include <sys/stat.h>
#include <unistd.h>
#include <string.h>

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
    // NOTE: SDK ABI が PDF と食い違うと発覚 (Spike 1)。旧 DataLength/FileCount は
    // 存在しない。実際は 2 セットの (UInt8 flag + UInt16×3 + NSString + UInt32×2)。
    // 意味未確定なので生バイトをそのまま dump し、Wave 1b 突破後に field 名を確定させる。
    LogInfo(@"PictFileInfo2: raw=%@",
            [NSData dataWithBytes:&info length:sizeof(info)]);
    LogInfo(@"PictFileInfo2 [set0]: flag=%u u16=(%u,%u,%u) name=%@ u32=(%u,%u)",
            info._flag0, info._u16_0a, info._u16_0b, info._u16_0c,
            info._name0, info._u32_0a, info._u32_0b);
    LogInfo(@"PictFileInfo2 [set1]: u16=(%u,%u,%u) name=%@ u32=(%u,%u)",
            info._u16_1a, info._u16_1b, info._u16_1c,
            info._name1, info._u32_1a, info._u32_1b);

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

    // SDK が alloc した directoryEntry 領域を明示解放 (解放しないとリーク)。
    // 現状 helper は 1 セッション 1 撮影で exit するので実害は小さいが、
    // 将来的に長時間 tether するとき (Wave 4 以降) に効く。
    if (apiConfig.directoryEntry != NULL) {
        int rfree = [DeviceInterface sgm_FreeArrayMemory:&apiConfig];
        LogSdk(@"sgm_FreeArrayMemory (ConfigAPI)", rfree);
        // 解放後は directoryEntry を NULL に (二重解放防止)
        apiConfig.directoryEntry = NULL;
        apiConfig.dataLength = 0;
        apiConfig.directoryCount = 0;
    }

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

// --------------------------------------------------------------------------
// Spike 2: 標準 PTP GetDeviceInfo (0x1001) を SDK バイパスで直接送信
//
// SIGMA SDK 経由の PTP コマンド (sgm_ConfigAPI 0x9035 / sgm_GetCamStatus2 0x902c)
// はカメラが応答しない。ICC transport 自体が生きているかを切り分けるため、
// requestSendPTPCommand: で標準 PTP OperationCode 0x1001 GetDeviceInfo を直接送る。
// 応答が来れば ICC は生きている → SDK 内部 (delegate 引数・スレッド・struct 引数)
// の問題に絞れる。応答が来なければ ICC/TCC/USB 層の問題。
// --------------------------------------------------------------------------

@interface Spike2Delegate : NSObject
@property (nonatomic, assign) BOOL done;
@property (nonatomic, assign) BOOL succeeded;
@property (nonatomic, strong) NSError *error;
@property (nonatomic, strong) NSData *responseCmd;   // PTP response block
@property (nonatomic, strong) NSData *inData;        // Data phase (if any)
- (void)didSendPTPCommand:(NSData *)command
                   inData:(NSData *)data
                 response:(NSData *)response
                    error:(NSError *)error
              contextInfo:(void *)contextInfo;
@end

@implementation Spike2Delegate
- (void)didSendPTPCommand:(NSData *)command
                   inData:(NSData *)data
                 response:(NSData *)response
                    error:(NSError *)error
              contextInfo:(void *)contextInfo {
    self.responseCmd = response;
    self.inData = data;
    self.error = error;
    self.succeeded = (error == nil);
    self.done = YES;
    LogInfo(@"[spike2] callback thread=%@", [NSThread currentThread].description);
    LogInfo(@"[spike2] error=%@", error);
    LogInfo(@"[spike2] response=%@", response);
    LogInfo(@"[spike2] data=%@", data);
}
@end

static NSData * BuildPTPCommandBlock(UInt16 opCode, NSArray<NSNumber *> *params) {
    // PTP Command Block Container:
    //   UInt32 length (including itself)
    //   UInt16 type = 1 (Command)
    //   UInt16 code = opCode
    //   UInt32 transactionID = 0
    //   UInt32 params[0..5]
    NSUInteger paramCount = MIN(params.count, (NSUInteger)5);
    UInt32 length = 12 + (UInt32)(paramCount * 4);
    NSMutableData *d = [NSMutableData dataWithCapacity:length];
    [d appendBytes:&length length:4];
    UInt16 type = 1;
    [d appendBytes:&type length:2];
    [d appendBytes:&opCode length:2];
    UInt32 txid = 0;
    [d appendBytes:&txid length:4];
    for (NSUInteger i = 0; i < paramCount; i++) {
        UInt32 p = (UInt32)[params[i] unsignedIntValue];
        [d appendBytes:&p length:4];
    }
    return d;
}

// Spike 2b: SDK 内部の PTP_Command 経由で GetDeviceInfo (0x1001) を送る対照。
// Spike 2 (ICC 直接) と組み合わせて 4 象限で切り分ける:
//   Spike 2 OK / Spike 2b OK  → ICC も SDK 内部経路も生きている → sgm_* 層の問題
//   Spike 2 OK / Spike 2b NG  → SDK 内部経路が壊れている (PTP_Command params 誤り等)
//   Spike 2 NG / Spike 2b OK  → 想定外 (先に ICC が動かないと SDK も動かないはず)
//   Spike 2 NG / Spike 2b NG  → ICC/TCC/USB 層の問題 (Developer ID 署名や TCC 権限)
static int RunSpike2bPTPCommand(ICCameraDevice *cam) {
    LogInfo(@"[spike2b] SDK 内部 PTP_Command 経由で GetDeviceInfo (0x1001) を送信");

    // DeviceInterface のシングルトンを取得
    DeviceInterface *di = [DeviceInterface sgm_GetActiveDriverInstance];
    if (!di) {
        LogInfo(@"[spike2b] sgm_GetActiveDriverInstance が nil → getInstance を試す");
        di = [DeviceInterface getInstance];
    }
    if (!di) {
        LogErr(@"[spike2b] DeviceInterface instance が取れない");
        return 1;
    }
    LogInfo(@"[spike2b] DeviceInterface instance: %@", di);

    // PassThrough を初期化して 0x1001 を送る
    SgmPassThrough pt = {};
    pt.opCode = 0x1001;
    LogInfo(@"[spike2b] PassThrough size=%zu opCode=0x%04x", sizeof(pt), pt.opCode);

    // commandType = 0 (plain command in-only) を仮定。実値は Spike 4 で確定させる。
    int rc = [di PTP_Command:cam param:&pt commandType:0 retry:1];
    LogInfo(@"[spike2b] PTP_Command rc=%d respCode=0x%04x", rc, pt.respCode);
    if (pt.payloadSize > 0) {
        LogInfo(@"[spike2b] payload received: %llu bytes", (unsigned long long)pt.payloadSize);
    }
    if (pt.respCode == 0x2001 || rc == 0) {
        LogInfo(@"[spike2b] ✅ 応答受信 (respCode=0x2001)");
        return 0;
    }
    LogErr(@"[spike2b] ❌ 応答なし or エラー (rc=%d respCode=0x%04x)", rc, pt.respCode);
    return 2;
}

static int RunSpike2GetDeviceInfo(ICCameraDevice *cam) {
    LogInfo(@"[spike2] 標準 PTP GetDeviceInfo (0x1001) を直接送信");
    Spike2Delegate *delegate = [Spike2Delegate new];

    NSData *cmd = BuildPTPCommandBlock(0x1001, @[]);
    LogInfo(@"[spike2] command block: %@", cmd);

    [cam requestSendPTPCommand:cmd
                       outData:nil
           sendCommandDelegate:delegate
        didSendCommandSelector:@selector(didSendPTPCommand:inData:response:error:contextInfo:)
                   contextInfo:NULL];
    LogInfo(@"[spike2] requestSendPTPCommand issued, waiting up to 15s...");

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15.0];
    while (!delegate.done && [deadline compare:[NSDate date]] == NSOrderedDescending) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    if (!delegate.done) {
        LogErr(@"[spike2] タイムアウト: callback が 15 秒で来なかった");
        return 1;
    }
    if (delegate.error) {
        LogErr(@"[spike2] error: %@", delegate.error);
        return 2;
    }
    LogInfo(@"[spike2] ✅ 応答受信 response=%lu bytes inData=%lu bytes",
            (unsigned long)delegate.responseCmd.length, (unsigned long)delegate.inData.length);

    // response block 解析
    if (delegate.responseCmd.length >= 8) {
        const UInt8 *b = (const UInt8 *)delegate.responseCmd.bytes;
        UInt32 len = b[0] | (b[1]<<8) | (b[2]<<16) | (b[3]<<24);
        UInt16 type = b[4] | (b[5]<<8);
        UInt16 code = b[6] | (b[7]<<8);
        LogInfo(@"[spike2] response: len=%u type=0x%04x code=0x%04x", len, type, code);
        // code 0x2001 = OK
    }
    return 0;
}

// --------------------------------------------------------------------------
// Spike 1: ABI 一致検証 (--abi-dump)
// SDK が公開ヘッダを持たないため、実 framework 側の method_getTypeEncoding を
// 全部ダンプして自前宣言 SDKGateway.h との差分を目視で確認する診断コマンド。
// カメラも NSApp.run も不要。sgm_initializeSDK すら要らない (class ref だけで load される)。
// --------------------------------------------------------------------------

static void DumpMethodListForClass(Class cls, BOOL isMetaclass) {
    Class target = isMetaclass ? object_getClass((id)cls) : cls;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(target, &count);
    const char *tag = isMetaclass ? "+" : "-";
    printf("=== %s[%s] (%u methods) ===\n", tag, class_getName(cls), count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        const char *enc = method_getTypeEncoding(methods[i]);
        printf("  %s%-70s %s\n", tag, sel_getName(sel), enc ? enc : "(null)");
    }
    free(methods);
}

static void DumpABI(void) {
    printf("# SDK ABI dump (2026-08-18)\n#\n");
    printf("# 各 class の class/instance methods とその type encoding を全部吐く。\n");
    printf("# 自前宣言 SDKGateway.h と比較して packing / 引数順 / 幅の不一致を検出する。\n#\n");
    printf("# 参考 encoding 表:\n");
    printf("#   v void, c char, i int32, s int16, l long32, q int64, C uchar, I uint32, S uint16, L ulong32, Q uint64\n");
    printf("#   f float, d double, B bool, * char*, @ id, # Class, : SEL, ^X ptr to X, {name=fields} struct\n");
    printf("#   数字は frame offset。例: `i32@0:8@16I24@28` = int返, self@0, _cmd@8, id@16, uint32@24, id@28\n#\n\n");

    // SharedPTP のライフサイクル / ロギング系
    DumpMethodListForClass([DeviceInterface class], YES);
    // Operation classes (全部 class methods 化されている)
    DumpMethodListForClass([sgm_ConfigAPI class], YES);
    DumpMethodListForClass([sgm_GetCamStatus2 class], YES);
    DumpMethodListForClass([sgm_GetCamDataGroup2 class], YES);
    DumpMethodListForClass([sgm_SetCamDataGroup2 class], YES);
    DumpMethodListForClass([sgm_SnapCommand class], YES);
    DumpMethodListForClass([sgm_GetCamCaptStatus class], YES);
    DumpMethodListForClass([sgm_GetPictFileInfo2 class], YES);
    DumpMethodListForClass([sgm_GetBigPartialPictFile class], YES);
    DumpMethodListForClass([sgm_ClearImageDBSingle class], YES);
    DumpMethodListForClass([sgm_CloseApplication class], YES);

    // 参考: DeviceInterface の instance methods (PTP_Command 系がここにいるはず)
    printf("\n# --- DeviceInterface instance methods (参考: PTP_Command 系) ---\n\n");
    DumpMethodListForClass([DeviceInterface class], NO);
}

// --------------------------------------------------------------------------
// 我々の自前宣言側の encoding を @encode ベースで組み立てる (対照表用)
// --------------------------------------------------------------------------

static void DumpOurEncodingExpectations(void) {
    printf("\n# --- 我々の自前宣言 (SDKGateway.h) から @encode で組み立てた期待値 ---\n\n");

    // sgm_ConfigAPI:AdjustmentMode:cameraHandle:
    printf("+sgm_ConfigAPI:AdjustmentMode:cameraHandle: 期待\n");
    printf("  return int = %s\n", @encode(int));
    printf("  arg SgmAdjustmentConfig* = %s\n", @encode(SgmAdjustmentConfig *));
    printf("  arg UInt32 = %s\n", @encode(UInt32));
    printf("  arg ICCameraDevice* = %s\n", @encode(ICCameraDevice *));

    printf("\n+sgm_GetCamStatus2:buffLength:recvLength:operationCode1:operationCode2:operationCode3:cameraHandle: 期待\n");
    printf("  return int = %s\n", @encode(int));
    printf("  arg void* = %s\n", @encode(void *));
    printf("  arg UInt32 = %s\n", @encode(UInt32));
    printf("  arg UInt32* = %s\n", @encode(UInt32 *));
    printf("  arg UInt32 = %s\n", @encode(UInt32));
    printf("  arg UInt32 = %s\n", @encode(UInt32));
    printf("  arg UInt32 = %s\n", @encode(UInt32));
    printf("  arg ICCameraDevice* = %s\n", @encode(ICCameraDevice *));

    printf("\n+sgm_SnapCommand:cameraHandle: 期待\n");
    printf("  return int = %s\n", @encode(int));
    printf("  arg SgmSnapState* = %s (sizeof=%zu)\n", @encode(SgmSnapState *), sizeof(SgmSnapState));
    printf("  arg ICCameraDevice* = %s\n", @encode(ICCameraDevice *));

    printf("\n+sgm_GetCamCaptStatus:imageID:cameraDevice: 期待\n");
    printf("  return int = %s\n", @encode(int));
    printf("  arg SgmCapStatus* = %s (sizeof=%zu)\n", @encode(SgmCapStatus *), sizeof(SgmCapStatus));
    printf("  arg UInt8 = %s\n", @encode(UInt8));
    printf("  arg ICCameraDevice* = %s\n", @encode(ICCameraDevice *));

    printf("\n+sgm_SetCamDataGroup2:fieldPresent1:fieldPresent2:cameraHandle: 期待\n");
    printf("  return int = %s\n", @encode(int));
    printf("  arg SgmDataGroup2* = %s (sizeof=%zu)\n", @encode(SgmDataGroup2 *), sizeof(SgmDataGroup2));
    printf("  arg UInt8 fp1 = %s\n", @encode(UInt8));
    printf("  arg UInt8 fp2 = %s\n", @encode(UInt8));
    printf("  arg ICCameraDevice* = %s\n", @encode(ICCameraDevice *));

    printf("\n+sgm_GetBigPartialPictFile:start:length:data:dataSize:cameraHandle: 期待\n");
    printf("  return int = %s\n", @encode(int));
    printf("  arg storeAddress UInt32 = %s\n", @encode(UInt32));
    printf("  arg startAddress UInt32 = %s\n", @encode(UInt32));
    printf("  arg maxLength UInt32 = %s\n", @encode(UInt32));
    printf("  arg data UInt8** = %s\n", @encode(UInt8 **));
    printf("  arg dataSize UInt32* = %s\n", @encode(UInt32 *));
    printf("  arg ICCameraDevice* = %s\n", @encode(ICCameraDevice *));

    printf("\n+sgm_GetPictFileInfo2:cameraHandle: 期待\n");
    printf("  return int = %s\n", @encode(int));
    printf("  arg SgmPictureFileInfoData2* = %s (sizeof=%zu)\n", @encode(SgmPictureFileInfoData2 *), sizeof(SgmPictureFileInfoData2));
    printf("  arg ICCameraDevice* = %s\n", @encode(ICCameraDevice *));
}

// --------------------------------------------------------------------------
// Spike 1 修正後の byte-exact 一致検証
//
// SDK 側 method_getTypeEncoding から struct 引数の encoding を取り出し、
// 我々の @encode(struct*) の encoding と field 部だけを比較する。
// SDK: `^{_SgmXxx=CCC}` / 我々: `^{?=CCC}` → 内側 `CCC` が一致すれば MATCH。
//
// 4 struct すべて MATCH でなければ exit code = 1 を返して CI で検知可能にする。
// --------------------------------------------------------------------------

// 与えられた encoding 文字列 `s` の中で、最初の `{` から対応する `}` までの
// struct フィールド部 (`=` 以降 `}` 直前まで) を newly-allocated C string として返す。
// 見つからなければ NULL。呼び出し側が free() する。
static char * ExtractStructFieldsFromEncoding(const char *s) {
    if (!s) return NULL;
    const char *brace = strchr(s, '{');
    if (!brace) return NULL;
    const char *eq = strchr(brace, '=');
    if (!eq) return NULL;
    // 対応する '}' を depth counter で探す (ネスト構造対応)
    const char *p = eq + 1;
    int depth = 1;
    while (*p) {
        if (*p == '{') depth++;
        else if (*p == '}') { depth--; if (depth == 0) break; }
        p++;
    }
    if (depth != 0) return NULL;
    size_t len = (size_t)(p - (eq + 1));
    char *out = (char *)malloc(len + 1);
    if (!out) return NULL;
    memcpy(out, eq + 1, len);
    out[len] = '\0';
    return out;
}

// class method の SEL を method_getTypeEncoding で解決する
static const char * TypeEncodingForClassMethod(Class cls, SEL sel) {
    Method m = class_getClassMethod(cls, sel);
    return m ? method_getTypeEncoding(m) : NULL;
}

// instance method の SEL を method_getTypeEncoding で解決する
static const char * TypeEncodingForInstanceMethod(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    return m ? method_getTypeEncoding(m) : NULL;
}

// 1 struct 分の比較を printf しつつ、mismatch なら global fail flag を立てる
static int g_abiMismatchCount = 0;

static void CompareStruct(const char *label,
                          const char *sdkMethodEncoding,
                          const char *ourFieldsEncoding,
                          size_t ourSizeof) {
    char *sdkFields = ExtractStructFieldsFromEncoding(sdkMethodEncoding);
    if (!sdkFields) {
        printf("  %-32s: SDK encoding 取得失敗 (source=%s)\n", label, sdkMethodEncoding ?: "(null)");
        g_abiMismatchCount++;
        return;
    }
    // 我々側 @encode(SgmXxx*) は "^{?=CCC}" のように来るので中身抽出
    char *ourFields = ExtractStructFieldsFromEncoding(ourFieldsEncoding);
    if (!ourFields) {
        printf("  %-32s: 我々の encoding 取得失敗 (source=%s)\n", label, ourFieldsEncoding ?: "(null)");
        free(sdkFields);
        g_abiMismatchCount++;
        return;
    }
    BOOL match = (strcmp(sdkFields, ourFields) == 0);
    printf("  %-32s: SDK=%-24s | @encode=%-24s | sizeof=%zu | %s\n",
           label, sdkFields, ourFields, ourSizeof, match ? "MATCH" : "MISMATCH");
    if (!match) g_abiMismatchCount++;
    free(sdkFields);
    free(ourFields);
}

static int VerifyStructAbiMatches(void) {
    printf("\n# --- byte-exact ABI 一致検証 (Spike 1 修正後) ---\n\n");
    g_abiMismatchCount = 0;

    // SgmSnapState: 引数 1 番目 (sgm_SnapCommand:cameraHandle:)
    CompareStruct("SgmSnapState",
                  TypeEncodingForClassMethod([sgm_SnapCommand class],
                                             @selector(sgm_SnapCommand:cameraHandle:)),
                  @encode(SgmSnapState *),
                  sizeof(SgmSnapState));

    // SgmCapStatus: sgm_GetCamCaptStatus:imageID:cameraDevice:
    CompareStruct("SgmCapStatus",
                  TypeEncodingForClassMethod([sgm_GetCamCaptStatus class],
                                             @selector(sgm_GetCamCaptStatus:imageID:cameraDevice:)),
                  @encode(SgmCapStatus *),
                  sizeof(SgmCapStatus));

    // SgmDataGroup2: sgm_SetCamDataGroup2:fieldPresent1:fieldPresent2:cameraHandle:
    CompareStruct("SgmDataGroup2",
                  TypeEncodingForClassMethod([sgm_SetCamDataGroup2 class],
                                             @selector(sgm_SetCamDataGroup2:fieldPresent1:fieldPresent2:cameraHandle:)),
                  @encode(SgmDataGroup2 *),
                  sizeof(SgmDataGroup2));

    // SgmPictureFileInfoData2: sgm_GetPictFileInfo2:cameraHandle:
    CompareStruct("SgmPictureFileInfoData2",
                  TypeEncodingForClassMethod([sgm_GetPictFileInfo2 class],
                                             @selector(sgm_GetPictFileInfo2:cameraHandle:)),
                  @encode(SgmPictureFileInfoData2 *),
                  sizeof(SgmPictureFileInfoData2));

    // SgmPassThrough: instance method -PTP_Command:param:commandType:retry:
    // (SDK 内部の PTP 送信構造体。Spike 2b で使う)
    CompareStruct("SgmPassThrough",
                  TypeEncodingForInstanceMethod([DeviceInterface class],
                                                @selector(PTP_Command:param:commandType:retry:)),
                  @encode(SgmPassThrough *),
                  sizeof(SgmPassThrough));

    printf("\n# 結果: %d MISMATCH\n", g_abiMismatchCount);
    return g_abiMismatchCount;
}

// spike モード判定用のグローバル
static BOOL g_spike2Mode  = NO;   // 標準 PTP 0x1001 を ICC 直接送信
static BOOL g_spike2bMode = NO;   // 標準 PTP 0x1001 を SDK 内部 PTP_Command 経由で送信
static BOOL g_spike3Mode  = NO;   // main queue 自己待ち対照試験 (専用 worker から発行)

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // 診断コマンド分岐
        if (argc >= 2 && strcmp(argv[1], "--abi-dump") == 0) {
            DumpABI();
            DumpOurEncodingExpectations();
            int mismatch = VerifyStructAbiMatches();
            return mismatch == 0 ? 0 : 1;
        }
        if (argc >= 2 && strcmp(argv[1], "--spike2") == 0) {
            g_spike2Mode = YES;
        }
        if (argc >= 2 && strcmp(argv[1], "--spike2b") == 0) {
            g_spike2bMode = YES;
        }
        if (argc >= 2 && strcmp(argv[1], "--spike3") == 0) {
            g_spike3Mode = YES;
        }

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
        LogInfo(@"camera fully ready");

        // Spike 2 モード: 標準 PTP GetDeviceInfo 直接送信して即終了
        if (g_spike2Mode) {
            int spikeRc = RunSpike2GetDeviceInfo(cam);
            [cam requestCloseSession];
            [browser stop];
            [DeviceInterface sgm_terminateSDK];
            return spikeRc;
        }

        // Spike 2b モード: SDK 内部 PTP_Command 経由で 0x1001 を送信
        if (g_spike2bMode) {
            int spikeRc = RunSpike2bPTPCommand(cam);
            [cam requestCloseSession];
            [browser stop];
            [DeviceInterface sgm_terminateSDK];
            return spikeRc;
        }

        LogInfo(@"entering capture sequence");

        // ここで初めて NSApplication を用意し、NSApp.run で本格的な Cocoa
        // event loop に入る。sgm_ConfigAPI 等の SDK 呼び出しは requestSendPTPCommand
        // のコールバックがメインスレッドで dispatch されるのに依存しているため。
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        // Spike 3 (--spike3): 専用 worker queue から SDK 呼び出しを発行し、
        //   main queue は完全に runloop pump に専念する対照試験。
        //   PTP completion callback が main thread で発火する実装だと、
        //   main queue で同期 SDK 呼び出しをすると self-wait deadlock する仮説の検証。
        // 既定: これまで通り main queue に dispatch (SampleAPP のボタンハンドラと同じ挙動)
        __block int runRc = -1;
        void (^wake_and_stop)(void) = ^{
            [NSApp stop:nil];
            NSEvent *wake = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                              location:NSMakePoint(0, 0)
                                         modifierFlags:0 timestamp:0
                                          windowNumber:0 context:nil
                                               subtype:0 data1:0 data2:0];
            [NSApp postEvent:wake atStart:YES];
        };
        if (g_spike3Mode) {
            LogInfo(@"[spike3] 専用 worker queue から SDK 呼び出しを発行");
            dispatch_queue_t worker = dispatch_queue_create("sgm.worker", DISPATCH_QUEUE_SERIAL);
            dispatch_async(worker, ^{
                runRc = RunCaptureSequence(cam);
                LogInfo(@"[spike3] worker: RunCaptureSequence rc=%d", runRc);
                dispatch_async(dispatch_get_main_queue(), wake_and_stop);
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                runRc = RunCaptureSequence(cam);
                wake_and_stop();
            });
        }
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
