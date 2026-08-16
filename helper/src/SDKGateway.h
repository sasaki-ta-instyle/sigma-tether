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

typedef struct __attribute__((packed)) {
    UInt8 CaptureMode;    // 0x01 General Capture / 0x02 Non-AF / 0x03 AF Drive Only
                          // 0x04 Start AF / 0x05 Stop AF / 0x06 Start Capture / 0x07 Stop Capture
                          // 0x10 Movie w/AF / 0x20 Movie w/o AF / 0x30 Stop Movie
    UInt8 CaptureAmount;  // 連続撮影枚数、単写は 0x01
} SgmSnapState;

typedef struct __attribute__((packed)) {
    UInt8  ImageID;
    UInt8  ImageDBHead;
    UInt8  ImageDBTail;
    UInt16 CaptStatus;
    UInt8  DestToSave;    // 0x01 カメラ内メディア / 0x02 PC / 0x03 両方
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

typedef struct __attribute__((packed)) {
    UInt32 DataLength;
    UInt32 FileCount;
    // NOTE: PDF 上 FileCount 以降のフィールド定義なし。
    //       実機ダンプで FileSize / FileName 相当があれば拡張する。
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
    UInt8 _reserved[6];      // safety padding
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
typedef struct __attribute__((packed)) {
    UInt32 dataLength;
    UInt32 directoryCount;
    void * _Nullable directoryEntry;   // SgmDirectoryEntry* (詳細後日)
} SgmAdjustmentConfig;

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

#endif  // SDKGATEWAY_H
