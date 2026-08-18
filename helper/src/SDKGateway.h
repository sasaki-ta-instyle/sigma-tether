//
//  SDKGateway.h
//  sigma-tether helper
//
//  SIGMA Camera Control SDK for Mac (2020-07-02, Ver 1.00) の
//  自前宣言ヘッダ。SDK 側は公開ヘッダを持たないため、PDF 仕様書
//  (Document/SIGMA_Camera_Control_SDK_Help_for_mac_JP.pdf) の記述を
//  元に @interface / struct を宣言し、runtime dispatch でシンボルを
//  解決する。
//
//  PDF に明記されていない引数名は "in_/out_" の慣習で命名した。実際の
//  Selector と署名は SDK バイナリ側で確定するため、コンパイル/リンク時
//  にミスマッチが出た場合はこのヘッダを PDF 該当ページを再確認して
//  修正する。
//

#ifndef SDKGATEWAY_H
#define SDKGATEWAY_H

#import <Foundation/Foundation.h>
#import <ImageCaptureCore/ImageCaptureCore.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Error codes (SDK PDF p.67)

typedef NS_ENUM(NSInteger, SgmResult) {
    SgmResultOK                    = 0x2001,
    SgmResultGeneralError          = 0x2002,
    SgmResultOperationNotSupported = 0x2005,
    SgmResultParameterNotSupported = 0x2006,
    SgmResultIncompleteTransfer    = 0x2007,
    SgmResultInvalidCodeFormat     = 0x2016,
    SgmResultUndefinedCommand      = 0x2017,
    SgmResultCaptureTerminated     = 0x2018,
    SgmResultDeviceBusy            = 0x2019,
    SgmResultInvalidParameter      = 0x201D,
    SgmResultChecksumError         = 0xA080,
    SgmResultNotInitialized        = 0xA081,
    SgmResultSystemError           = 0x1001,
    SgmResultPtpNotErr             = 0x1002,
    SgmResultNotInterface          = (NSInteger)0x80004002,
};

// 慣習: 成功は 0x2001 か 0 のどちらか (PDF 記述にゆらぎあり)
static inline BOOL SgmSucceeded(int r) { return r == 0 || r == SgmResultOK; }

#pragma mark - Capture (SDK PDF 4-24, 4-25)

// SDK ABI (2026-08-18 method_getTypeEncoding ダンプ): _SgmSnapState=CCC (3 UInt8)
// PDF は 2 バイトと記載していたが SDK 実装は 3 バイト。追加 1 バイトの意味も配置も
// 未確定 (encoding が同じ CCC のため文字列比較では offset を区別できない)。
// 一時的に末尾 _unknown0 で埋めているが、実位置は LLDB で SampleAPP を追って確認する。
typedef struct __attribute__((packed)) {
    UInt8 CaptureMode;    // 0x01 General Capture / 0x02 Non-AF / 0x03 AF Drive Only
                          // 0x04 Start AF / 0x05 Stop AF / 0x06 Start Capture / 0x07 Stop Capture
                          // 0x10 Movie w/AF / 0x20 Movie w/o AF / 0x30 Stop Movie
    UInt8 CaptureAmount;  // 連続撮影枚数、単写は 0x01
    UInt8 _unknown0;      // TODO: SampleAPP LLDB で offset 確定 (現状「末尾」は仮定)
} SgmSnapState;

// SDK ABI (2026-08-18 ダンプ): _SgmCaptStatus=CCCSCC (7 バイト)
// PDF の CCCSC (6 バイト) より 1 バイト多い。encoding 文字列が S を挟む形になっている
// ため、追加バイトは末尾である確度が高い (Codex Medium 5)。ただし LLDB で確定させる。
typedef struct __attribute__((packed)) {
    UInt8  ImageID;
    UInt8  ImageDBHead;
    UInt8  ImageDBTail;
    UInt16 CaptStatus;
    UInt8  DestToSave;    // 0x01 カメラ内メディア / 0x02 PC / 0x03 両方
    UInt8  _unknown0;     // TODO: SampleAPP LLDB で offset 確定
} SgmCapStatus;

typedef NS_ENUM(UInt16, SgmCaptStatus) {
    SgmCaptStatusCleared              = 0x0000,
    SgmCaptStatusShooting             = 0x0001,
    SgmCaptStatusShootSuccess         = 0x0002,
    SgmCaptStatusGeneratingImage      = 0x0004,
    SgmCaptStatusFileGenerated        = 0x0005,
    SgmCaptStatusMovieStopping        = 0x0006,
    SgmCaptStatusMovieFileGenerated   = 0x0007,
    SgmCaptStatusAFSuccess            = 0x8001,
    SgmCaptStatusCWBSuccess           = 0x8002,
    SgmCaptStatusImageSaved           = 0x8003,  // ★ この状態で GetBigPartialPictFile 可
    SgmCaptStatusOtherEndOK           = 0x8004,
    SgmCaptStatusAFFail               = 0x6001,
    SgmCaptStatusBufferFull           = 0x6002,
    SgmCaptStatusCWBFail              = 0x6003,
    SgmCaptStatusImageGenFail         = 0x6004,
    SgmCaptStatusGeneralFail          = 0x6005,
};

#pragma mark - PictFileInfo (SDK PDF 4-27, 4-28)

// SDK ABI (2026-08-18 ダンプ): _SgmPictureFileInfoData=CSSS@IISSS@II (45 bytes)
//
// PDF は「DataLength / FileCount の 2 UInt32」しか記載しておらず、実際の SDK は
// 45 バイトを書き込む。8 バイトで受けると 37 バイトのスタック破壊が起きる (🔴 BLOCKER)。
// フィールド名は不明なので実 layout をそのまま宣言する。おそらく 2 セット (main
// image + thumbnail?) の (UInt8 flag + UInt16×3 + NSString name + UInt32×2 size)。
// `@` は Objective-C object pointer (id, 8 bytes)。ARC 管理を避けるため
// __unsafe_unretained を使う (SDK が NSString の memory owner)。
typedef struct __attribute__((packed)) {
    UInt8  _flag0;
    UInt16 _u16_0a;
    UInt16 _u16_0b;
    UInt16 _u16_0c;
    __unsafe_unretained NSString *_name0;
    UInt32 _u32_0a;      // 推定: FileSize
    UInt32 _u32_0b;      // 推定: DataLength
    UInt16 _u16_1a;
    UInt16 _u16_1b;
    UInt16 _u16_1c;
    __unsafe_unretained NSString *_name1;
    UInt32 _u32_1a;
    UInt32 _u32_1b;
} SgmPictureFileInfoData2;

#pragma mark - DataGroup2 (SDK PDF p.16 抜粋、Wave 1 で最小限だけ)

// ImageQuality
typedef NS_ENUM(UInt8, SgmImageQuality) {
    SgmImageQualityJpegFine   = 0x02,
    SgmImageQualityJpegNormal = 0x04,
    SgmImageQualityJpegBasic  = 0x08,
    SgmImageQualityDng        = 0x10,
    SgmImageQualityDngJpeg    = 0x12,
};

// SpecialMode
typedef NS_ENUM(UInt8, SgmSpecialMode) {
    SgmSpecialModeNone      = 0x00,
    SgmSpecialModeLiveView  = 0x02,
};

// PDF の DataGroup2 構造体は全フィールドを含むが、Wave 1 は「ImageQuality
// と SpecialMode を書ければよい」ので、パディングを含む安全側の layout で
// 宣言する。全フィールドは Wave 5 の SettingsBridge で網羅する。
// SDK ABI (2026-08-18 ダンプ): _SgmDataGroup2=CCCCCCCCCCCCCCCCCC (18× UInt8, 18 bytes)
// PDF は 16 バイトと記載していたが SDK 実装は 18 バイト。追加 2 バイトの意味は
// 未確定なので `_reserved[8]` で埋める (末尾 8 バイトが reserved 扱い)。
typedef struct __attribute__((packed)) {
    UInt8 DriveMode;         // b0 of FP1
    UInt8 SpecialMode;       // b1
    UInt8 ExposureMode;      // b2
    UInt8 AEMeteringMode;    // b3
    UInt8 FlashType;         // b4
    UInt8 FlashMode;         // b5
    UInt8 FlashSetting;      // b6
    UInt8 WhiteBalance;      // b7
    UInt8 Resolution;        // b0 of FP2
    UInt8 ImageQuality;      // b1
    // SDK ABI 一致用: 追加 8 UInt8 (総 18 バイト)。encoding が同じ C の連続なので
    // 位置は encoding からは区別できない (Codex Critical 1 / High 5)。
    // 実位置は LLDB で SampleAPP を追って確定させる。個別 field 名で宣言しているのは
    // @encode が SDK 側 "CCCCCCCCCCCCCCCCCC" と文字列一致するため (配列 [8C] だと崩れる)。
    UInt8 _unknown0, _unknown1, _unknown2, _unknown3,
          _unknown4, _unknown5, _unknown6, _unknown7;
} SgmDataGroup2;

// FieldPresent bit for DataGroup2 (PDF p.16)
static const UInt8 SgmDG2_FP1_ImageQuality_via_FP2 = 0x00;  // ImageQuality は FP2
static const UInt8 SgmDG2_FP2_ImageQuality         = 0x02;  // b1
static const UInt8 SgmDG2_FP1_SpecialMode          = 0x02;  // b1

#pragma mark - SDK class method 宣言
//
// 実体は各 framework 内。ここでは selector と型のみを宣言し、リンク時に
// 解決させる。@implementation は書かない（フォワード宣言のみ）。
//

// SharedPTP.framework が公開するライフサイクルクラス。
// クラス名は SIGMA 命名慣習の sgm_APIBase でも sgm_SharedPTP でもなく、
// 素の `DeviceInterface` (nm -m で +[DeviceInterface sgm_...] を確認済)。
//
// この名前は generic すぎるが、リンク時に SharedPTP.framework 内の
// _OBJC_CLASS_$_DeviceInterface と結線されるので実害は無い。
@interface DeviceInterface : NSObject
+ (int)sgm_initializeSDK;
+ (int)sgm_terminateSDK;
+ (void)sgm_CamOpen:(ICCameraDevice *)inCamera;
+ (void)sgm_CamClose:(ICCameraDevice *)inCamera;
+ (int)sgm_GetLastCommandData:(NSData * _Nullable * _Nullable)outSend
                      resData:(NSData * _Nullable * _Nullable)outReceive;
+ (int)sgm_SetComLogFunc:(void (^ _Nullable)(void))inBlock;
+ (int)sgm_SetIsCallComLogFunc:(BOOL)inEnable;
@end

// SDK PDF p.12, 5-5 に記載の IFD 構造。SgmDirectoryEntry の中身は詳細不明
// のため void* で扱う。実運用では SDK が directoryEntry を alloc して返し、
// sgm_FreeArrayMemory: で解放する想定。
//
// SDK 側では `_IFDArray = II^{_SgmDirectoryEntry}` として現れる (sgm_FreeArrayMemory:
// / sgm_ConfigAPI / sgm_GetCamStatus2 系の引数)。同一レイアウトなので typedef 別名
// にして「ABI 上は同じもの」であることを明示 (Codex Medium 7)。
typedef struct __attribute__((packed)) {
    UInt32 dataLength;
    UInt32 directoryCount;
    void * _Nullable directoryEntry;   // SgmDirectoryEntry* (詳細後日)
} SgmIFDArray;

// SgmAdjustmentConfig は SgmIFDArray の PDF 命名。ABI 上は完全同一。
typedef SgmIFDArray SgmAdjustmentConfig;

#pragma mark - PassThrough (SDK 内部 PTP コマンド構造体)

// Spike 1 で ABI ダンプから発掘した SDK 内部の PTP コマンド構造体。
// `-[DeviceInterface PTP_Command:param:commandType:retry:]` の第 2 引数がこれ。
// ABI dump: `{PassThrough=S[5I]SII@S[5I]SQ^v}`
//
//   UInt16 opCode              PTP OperationCode
//   UInt32 cmdParams[5]        PTP コマンド params (最大 5)
//   UInt16 _pad0
//   UInt32 dataLength          データフェーズ長 (推定)
//   UInt32 transactionID       (推定, SDK が採番)
//   id     data                データフェーズの NSData (SendData 用)
//   UInt16 respCode            PTP ResponseCode (0x2001 = OK)
//   UInt32 respParams[5]       PTP 応答 params (最大 5)
//   UInt16 _pad1
//   UInt64 payloadSize         受信データサイズ (推定)
//   void*  payload             受信データポインタ (SDK が alloc)
//
// packed 前提の内部レイアウト。field 名は推定なので実機実験で確定させる。
// SDK の PTP_Command 系はこの構造体経由で全 PTP コマンドを送るため、
// sgm_* 層をバイパスして直接コマンド発行できる (Spike 2b 用途)。
// NOTE: field 名は全部推定。encoding (S[5I]SII@S[5I]SQ^v) は SDK と一致するが、
// 意味論と offset は LLDB で SampleAPP を追って確定させる (Codex Critical 1 / 2)。
typedef struct __attribute__((packed)) {
    UInt16 opCode;                       // 推定
    UInt32 cmdParams[5];                 // 推定: 送信 param
    UInt16 _unknown_after_cmdParams;     // encoding 上の S、意味未確定
    UInt32 dataLength;                   // 推定
    UInt32 transactionID;                // 推定
    __unsafe_unretained id data;         // 推定: NSData for SendData 経路
    UInt16 respCode;                     // 推定: PTP ResponseCode (0x2001=OK)
    UInt32 respParams[5];                // 推定: 応答 param
    UInt16 _unknown_after_respParams;    // encoding 上の S、意味未確定
    UInt64 payloadSize;                  // 推定: 受信データサイズ
    void * _Nullable payload;            // 推定: 受信データポインタ
} SgmPassThrough;

// PTP コマンドタイプ (PTP_Command の 3rd 引数): 推定
//   0 = plain command (in-only)、1 = SendData、2 = ReceiveData
// ABI dump に `PTP_SendCommand: / PTP_ReceiveData: / PTP_SendData:` の別 selector が
// あるので、PTP_Command 自体は分岐用の抽象呼び出し。実値は Spike 4 で確定する。

// _IFDArray (== SgmAdjustmentConfig) の directoryEntry 解放。
// SDK が alloc した領域は sgm_FreeArrayMemory: を呼ばないとリークする。
// ABI dump: `+sgm_FreeArrayMemory: i24@0:8^{_IFDArray=II^{_SgmDirectoryEntry}}16`
// (@interface DeviceInterface は上で既に開いているが、SgmAdjustmentConfig 型を
// 参照するため型定義の後にカテゴリで追加)
@interface DeviceInterface (Memory)
+ (int)sgm_FreeArrayMemory:(SgmAdjustmentConfig * _Nonnull)inArray;
// SDK が管理する DeviceInterface のシングルトン取得 (ABI dump 由来)。
+ (instancetype _Nullable)sgm_GetActiveDriverInstance;
+ (instancetype _Nullable)getInstance;
@end

// DeviceInterface instance methods: SDK 内部 PTP コマンド送信の抽象呼び出し。
// ABI dump:
//   -PTP_Command:param:commandType:      i36@0:8@16^{PassThrough=...}24i32
//   -PTP_Command:param:commandType:retry:i40@0:8@16^{PassThrough=...}24i32i36
//   -PTP_SendCommand:param:retry:        i36@0:8@16^{PassThrough=...}24i32
//   -PTP_ReceiveData:param:retry:        i36@0:8@16^{PassThrough=...}24i32
//   -PTP_SendData:param:retry:           i36@0:8@16^{PassThrough=...}24i32
@interface DeviceInterface (PTP)
- (int)PTP_Command:(ICCameraDevice *)inCamera
             param:(SgmPassThrough *)inParam
       commandType:(int)inType;
- (int)PTP_Command:(ICCameraDevice *)inCamera
             param:(SgmPassThrough *)inParam
       commandType:(int)inType
             retry:(int)inRetry;
- (int)PTP_SendCommand:(ICCameraDevice *)inCamera
                 param:(SgmPassThrough *)inParam
                 retry:(int)inRetry;
- (int)PTP_ReceiveData:(ICCameraDevice *)inCamera
                 param:(SgmPassThrough *)inParam
                 retry:(int)inRetry;
- (int)PTP_SendData:(ICCameraDevice *)inCamera
              param:(SgmPassThrough *)inParam
              retry:(int)inRetry;
@end

@interface sgm_ConfigAPI : NSObject
// PDF: 「API を使用するアプリケーションがカメラに対して最初に発行する命令」
// 出力として APIConfig IFD (Tag 0001 モデル/0002 シリアル/0003 fw ver/0005 通信 ver)
// が返る想定なので、inSgmAdjustmentConfig は非 NULL の実体を渡す必要がある。
+ (int)sgm_ConfigAPI:(SgmAdjustmentConfig * _Nonnull)inSgmAdjustmentConfig
       AdjustmentMode:(UInt32)inAdjustmentMode
         cameraHandle:(ICCameraDevice *)inCameraHandle;
@end

@interface sgm_SetCamDataGroup2 : NSObject
+ (int)sgm_SetCamDataGroup2:(SgmDataGroup2 *)inData
              fieldPresent1:(UInt8)inFP1
              fieldPresent2:(UInt8)inFP2
               cameraHandle:(ICCameraDevice *)inCameraHandle;
@end

@interface sgm_GetCamDataGroup2 : NSObject
+ (int)sgm_GetCamDataGroup2:(SgmDataGroup2 *)outData
               cameraHandle:(ICCameraDevice *)inCameraHandle;
@end

@interface sgm_SnapCommand : NSObject
+ (int)sgm_SnapCommand:(SgmSnapState *)inState
          cameraHandle:(ICCameraDevice *)inCameraHandle;
@end

// GetCamStatus2 (SampleAPP が ConfigAPI 前に polling している 7 引数 API)
// 呼び出し例では recv/buffLength と 3 つの OperationCode を渡す。
// 実際の返却構造体レイアウトは未確定なので、Wave 1 では void* バッファに書かせる。
@interface sgm_GetCamStatus2 : NSObject
+ (int)sgm_GetCamStatus2:(void * _Nullable)outBuffer
              buffLength:(UInt32)inBuffLength
              recvLength:(UInt32 * _Nullable)outRecvLength
          operationCode1:(UInt32)inOp1
          operationCode2:(UInt32)inOp2
          operationCode3:(UInt32)inOp3
            cameraHandle:(ICCameraDevice *)inCameraHandle;
@end

@interface sgm_GetCamCaptStatus : NSObject
// NOTE: 3rd keyword は cameraHandle: ではなく cameraDevice: (strings 確認済)
+ (int)sgm_GetCamCaptStatus:(SgmCapStatus *)outStatus
                    imageID:(UInt8)inImageID
               cameraDevice:(ICCameraDevice *)inCameraDevice;
@end

@interface sgm_ClearImageDBSingle : NSObject
+ (int)sgm_ClearImageDBSingle:(UInt8)inImageID
                 cameraHandle:(ICCameraDevice *)inCameraHandle;
@end

@interface sgm_GetPictFileInfo2 : NSObject
+ (int)sgm_GetPictFileInfo2:(SgmPictureFileInfoData2 *)outInfo
               cameraHandle:(ICCameraDevice *)inCameraHandle;
@end

@interface sgm_GetBigPartialPictFile : NSObject
+ (int)sgm_GetBigPartialPictFile:(UInt32)inStoreAddress
                           start:(UInt32)inStartAddress
                          length:(UInt32)inMaxLength
                            data:(UInt8 * _Nullable * _Nullable)outData
                        dataSize:(UInt32 *)outSize
                    cameraHandle:(ICCameraDevice *)inCameraHandle;
@end

@interface sgm_CloseApplication : NSObject
+ (int)sgm_CloseApplication:(ICCameraDevice *)inCameraHandle;
@end

NS_ASSUME_NONNULL_END

// --------------------------------------------------------------------------
// 自前 struct の sizeof / offsetof 固定 (Codex Critical 1)
//
// method_getTypeEncoding は SDK 側 field の並びは吐くが offset は吐かない。
// また `CCC` のように同じ型が連続する encoding では offset の位置を区別できない。
// これらの static_assert は「自前仮説」を固定するもので、SDK 側との一致証明では
// ない (SDK 側の実 offset は LLDB で SampleAPP を追って確認する)。
// 未来の誰かが field 順を変えても、ここでビルドが弾く。
// --------------------------------------------------------------------------
_Static_assert(sizeof(SgmSnapState) == 3, "SgmSnapState must be 3 bytes");
_Static_assert(sizeof(SgmCapStatus) == 7, "SgmCapStatus must be 7 bytes");
_Static_assert(sizeof(SgmDataGroup2) == 18, "SgmDataGroup2 must be 18 bytes");
_Static_assert(sizeof(SgmPictureFileInfoData2) == 45, "SgmPictureFileInfoData2 must be 45 bytes");
_Static_assert(sizeof(SgmPassThrough) == 80, "SgmPassThrough must be 80 bytes");
_Static_assert(sizeof(SgmIFDArray) == 16, "SgmIFDArray must be 16 bytes");

// SgmPassThrough の主要 offset (自前仮説)
_Static_assert(offsetof(SgmPassThrough, opCode) == 0, "opCode at 0");
_Static_assert(offsetof(SgmPassThrough, cmdParams) == 2, "cmdParams at 2");
_Static_assert(offsetof(SgmPassThrough, dataLength) == 24, "dataLength at 24");
_Static_assert(offsetof(SgmPassThrough, respCode) == 40, "respCode at 40");
_Static_assert(offsetof(SgmPassThrough, respParams) == 42, "respParams at 42");
_Static_assert(offsetof(SgmPassThrough, payloadSize) == 64, "payloadSize at 64");
_Static_assert(offsetof(SgmPassThrough, payload) == 72, "payload at 72");

// SgmPictureFileInfoData2 の主要 offset (自前仮説)
_Static_assert(offsetof(SgmPictureFileInfoData2, _flag0) == 0, "flag0 at 0");
_Static_assert(offsetof(SgmPictureFileInfoData2, _name0) == 7, "name0 at 7");
_Static_assert(offsetof(SgmPictureFileInfoData2, _name1) == 29, "name1 at 29");

#endif  // SDKGATEWAY_H
