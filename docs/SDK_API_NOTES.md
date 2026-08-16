# SIGMA Camera Control SDK for Mac — API メモ

SDK PDF (`/Volumes/CameraControlSDK_for_Mac/Document/SIGMA_Camera_Control_SDK_Help_for_mac_JP.pdf`, 全 74p, Ver 1.00 / 2020-07-02) から抽出した、helper 実装で必要になる API 情報の集約。ページ番号は PDF 印字ページ。

> **公開ヘッダ無し**。SDK は Objective-C class method `sgm_<Operation>` を各 framework に持つが、`.h` は同梱されていない。helper 側で `SDKGateway.h` として `@interface` を自前宣言し、runtime dispatch で解決する。

---

## 1. 対応カメラ・接続要件

- 対応カメラ: **SIGMA fp Ver2.00 以降**（p.4, 3-2）。fpL は PDF 明記なしだが SIGMA サンプルアプリで動作実績あり
- 対応 IDE: Xcode 11.3.1、言語 Objective-C（p.4, 3-1）
- 通信プロトコル: 内部は **PTP (ISO15740)**（p.67）。macOS の Image Capture サブシステム経由でハンドルを取得する
- USB モード: PDF 明記なし。fp 側のメニューで「PC 接続」モードに入る必要がある可能性あり（実機で確認）

## 2. Framework 構成（全 27 個）

| Framework | Function | 備考 |
|---|---|---|
| SharedPTP | `sgm_initializeSDK` / `sgm_terminateSDK` / `sgm_FreeArrayMemory` / `sgm_GetLastCommandData` / `sgm_SetComLogFunc` / `sgm_SetIsCallComLogFunc` / `sgm_GetActiveDriverInstance` / `sgm_CamOpen` / `sgm_CamClose` | 共通・必須 |
| ConfigAPI | `sgm_ConfigAPI` | 接続後の必須初期化 |
| GetCamDataGrp1..5 / SetCamDataGrp1..5 | Group1..5 read/write | 露出・ドライブ・色・光学補正・インターバル |
| GetCamDataGroupFocus / SetCamDataGroupFocus | フォーカス系 | AF エリア・顔検出等 |
| GetCamDataGroupMovie / SetCamDataGroupMovie | 動画系 | 記録フォーマット・FPS |
| GetCamCanSetInfo5 | 設定可能項目取得 | UI ドロップダウンの選択肢メタ |
| SetCamClockAdj | カメラ時刻設定 | |
| GetCamStatus2 | 状態ポーリング | バッテリー・メディア |
| GetCamViewFrame | ライブビュー 1 フレーム取得 | pull 型 |
| SnapCommand | 撮影 | |
| GetCamCaptStatus | キャプチャ状態ポーリング | |
| ClearImageDBSingle | 撮影結果クリア | |
| GetPictFileInfo2 | 静止画ファイル情報 | 薄い（DataLength/FileCount のみ） |
| GetBigPartialPictFile | 静止画 chunk ダウンロード | |
| GetMovieFileInfo | 動画ファイル情報 | 静止画版と非対称：FileName/FileSize が返る |
| GetPartialMovieFile | 動画 chunk ダウンロード | 64bit オフセット版 |
| CloseApplication | アプリ終了通知 | |

## 3. ライフサイクル

```
起動 (PC 上で一度)
  ├─ sgm_initializeSDK                                   [+int, PDF p.10]
  │
接続 (カメラごと)
  ├─ ICDeviceBrowser* browser = [ICDeviceBrowser new];
  ├─ browser.browsedDeviceTypeMask = ICDeviceTypeMaskCamera | ICDeviceLocationTypeMaskLocal
  ├─ delegate.didAddDevice → capabilities に ICCameraDeviceCanAcceptPTPCommands
  ├─ [camera requestOpenSession]                         [async, delegate.didOpenSessionWithError]
  ├─ sgm_CamOpen(camera)                                 [+void, requestOpenSession をラップ]
  ├─ sgm_ConfigAPI(config, mode, camera)                 [+int, model/serial/fw ver 取得]
  ├─ sgm_GetCamCanSetInfo5(&info, camera)                [+int, 選択肢メタ]
  │
運用 (何でも)
  ├─ sgm_GetCamDataGrpN / SetCamDataGrpN
  ├─ sgm_SnapCommand → sgm_GetCamCaptStatus → sgm_GetPictFileInfo2 → sgm_GetBigPartialPictFile
  ├─ sgm_GetCamViewFrame (pull ループ)
  │
切断 (逆順)
  ├─ sgm_CloseApplication(camera)                        [+int, PDF p.45]
  ├─ sgm_CamClose(camera)                                [+void, requestCloseSession をラップ]
  ├─ [camera requestCloseSession] (CamClose が代理する想定)
  │
終了 (PC 上で最後)
  └─ sgm_terminateSDK                                    [+int]
```

順序ミスは `0xA081` (Not Initialized) / `0x80004002` (Not Interface) で検出可能。

## 4. 撮影 (SnapCommand)

```objc
+(int) sgm_SnapCommand:(SgmSnapState*)state cameraHandle:(ICCameraDevice*)handle;

typedef struct {
    UInt8 CaptureMode;    // 0x01 General / 0x02 Non-AF / 0x03 AF Drive Only /
                          // 0x04 Start AF / 0x05 Stop AF / 0x06 Start Capture /
                          // 0x07 Stop Capture / 0x10..0x30 Movie
    UInt8 CaptureAmount;  // 連続撮影枚数、単写は 0x01
} SgmSnapState;
```

## 5. キャプチャ状態 (GetCamCaptStatus)

```objc
+(int) sgm_GetCamCaptStatus:(SgmCapStatus*)out imageID:(UInt8)id cameraHandle:(ICCameraDevice*)h;

typedef struct {
    UInt8  ImageID;
    UInt8  ImageDBHead;
    UInt8  ImageDBTail;
    UInt16 CaptStatus;
    UInt8  DestToSave;    // 0x01 カメラ / 0x02 PC / 0x03 両方
} SgmCapStatus;
```

CaptStatus:
- **処理中**: 0x0001 待機/動作中 / 0x0002 撮影成功（画像生成なし）/ 0x0004 画像生成中・CWB 処理中 / 0x0005 画像データ生成完了 / 0x0006 動画停止準備 / 0x0007 動画生成完了
- **成功終了**: 0x8001 AF 成功 / 0x8002 CWB 取得成功 / **0x8003 画像保存完了 ← ここでファイル取得可** / 0x8004 その他中断
- **失敗終了**: 0x6001 AF 失敗 / 0x6002 バッファフル / 0x6003 CWB 失敗 / 0x6004 画像生成中エラー / 0x6005 一般失敗

推奨ポーリング間隔: 100ms（PDF 明記なし、経験則）。

## 6. ライブビュー (GetCamViewFrame)

```objc
+(int) sgm_GetCamViewFrame:(UInt8**)outBuffer
             imageDataSize:(UInt32*)outSize
              cameraHandle:(ICCameraDevice*)handle;
```

- pull 型。コールバック無し
- **返却バッファの free 責務は呼び出し側**（PDF p.36）
- LV 有効化には事前に `sgm_SetCamDataGroup2` で `SpecialMode = 0x02 (Live View Mode)` を書く（PDF p.16）
- フォーマット: PDF 明記なし → JPEG stream と推測（先頭 `FF D8` を実機で確認）

## 7. ファイル取得

### 7-1. GetPictFileInfo2 (静止画情報)

```objc
+(int) sgm_GetPictFileInfo2:(SgmPictureFileInfoData2*)out cameraHandle:(ICCameraDevice*)h;

typedef struct {
    UInt32 DataLength;
    UInt32 FileCount;
} SgmPictureFileInfoData2;
```

**ファイル名・サイズは返らない**。ファイル名は helper 側で `SIGMA-YYYYMMDD-HHMMSS-####.dng` として採番。総サイズは chunk 反復で「返却バイトが要求バイト未満になる」まで読む。

### 7-2. GetBigPartialPictFile (chunk ダウンロード)

```objc
+(int) sgm_GetBigPartialPictFile:(UInt32)storeAddress
                           start:(UInt32)startAddress
                          length:(UInt32)maxLength
                            data:(UInt8**)outData
                        dataSize:(UInt32*)outSize
                    cameraHandle:(ICCameraDevice*)handle;
```

- storeAddress: 画像ファイル格納先アドレス（先頭）※ ImageID との対応関係は PDF 明記なし。**Wave 1 の実機テストで確定**
- startAddress: 取得開始オフセット（0 → 逐次加算）
- maxLength: リクエストする転送サイズ（推奨 chunk size は PDF 明記なし → 1MB で開始）
- outData: SDK 側 alloc。**呼び出し側で free 必要**
- outSize: 実際に読めたバイト数（データヘッダ・チェックサム込）

## 8. カメラ設定 (DataGroup1-5, Focus, Movie)

`+(int) sgm_GetCamDataGrpN:(SgmDataGroupN*)out cameraHandle:(ICCameraDevice*)h;`
`+(int) sgm_SetCamDataGrpN:(SgmDataGroupN*)in fieldPresent1:(UInt8)fp1 fieldPresent2:(UInt8)fp2 cameraHandle:(ICCameraDevice*)h;`

**Set は FieldPresent ビットマスクで変更対象を明示**。値だけ埋めても bit が立っていないと反映されない。

### DataGroup 割り当て

- **1** (p.13): ShutterSpeed / Aperture / ProgramShift / ISOAuto / ISOSpeed / ExpCompensation / ABValue / ABSetting / FrameBufferState / MediaFreeSpace / MediaStatus / CurrentLensFocalLength / BatteryState
- **2** (p.16): DriveMode / **SpecialMode (0x02 LV)** / ExposureMode / AEMeteringMode / FlashType / WhiteBalance / Resolution / **ImageQuality (0x02 JPEG FINE, 0x04 JPEG NORMAL, 0x08 JPEG BASIC, 0x10 DNG, 0x12 DNG+FINE)**
- **3** (p.19): ColorSpace / ColorMode / BatteryKind / AFAuxiliaryLight / AFBeep / TimerSound / **DestToSave (0x01 カメラ / 0x02 PC / 0x03 両方)**
- **4** (p.22): DcCropMode / LVMagnifyRatio / 高感度 ISO 拡張 / 連写速度 / HDR / DNG 画質 (12/14bit) / レンズ光学補正
- **5** (p.25): IntervalTimerSecond / IntervalTimerFrame / ColorTemp (K) / AspectRatio / ToneEffect
- **Focus** (p.28, 64): FocusMode / AF Lock / 顔・瞳優先 / FocusArea / 測距枠位置
- **Movie** (p.30, 65): 静止画・動画切替 / T値 / シャッター角度 / オーディオ / 記録フォーマット / 動画解像度 / FPS

### FieldPresent の例 (DataGroup1, p.13)

```
FieldPresent1
  b0 ShutterSpeed / b1 Aperture / b2 ProgramShift / b3 ISOAuto
  b4 ISOSpeed / b5 ExpCompensation / b6 ABValue / b7 ABSetting
FieldPresent2
  b0 FrameBufferState / b1 MediaFreeSpace / b2 MediaStatus
  b3 CurrentLensFocalLength / b4 BatteryState / b5 AB Shot Number
  b6 ExpComp Exclude AB / b7 Reserved
```

## 9. 可変範囲取得 (GetCamCanSetInfo5)

IFD 形式でタグごとの選択肢配列を返す。抜粋（PDF p.53-63）:

| Tag | 内容 |
|---|---|
| 0001 | ドライブモード |
| 0011 | 画質 (RAW=DNG=0x02 / JPEG FINE=0x10 / …/ DNG+FINE=0x12) |
| 0200 | 露出モード (P/A/S/M/C1/C2/C3) |
| 0210 | F 値 (SSHORT, min/max/step) |
| 0212 | シャッター速度 (SSHORT, APEX) |
| 0215 | ISO Manual (SSHORT) |
| 0217 | 露出補正 (SSHORT) |
| 0301 | WB (オート/晴れ/日陰/白熱電球/蛍光灯/フラッシュ/色温度/カスタム1..3) |
| 0302 | 色温度 (K, min/max/step) |
| 0320 | カラーモード (11 種) |
| 0600 | フォーカスモード |
| 0700 | LV 転送 |

## 10. APEX 変換 (PDF p.69-74)

8bit APEX Step (SSHORT の整数部) と 16bit APEX Step (S7.8 = 整数7bit + 小数8bit) の 2 系統。

抜粋:
- ISO: 32=100, 40=200, 48=400, 56=800, 64=1600, 72=3200, 80=6400
- Aperture: 16=F1.4, 24=F2.0, 32=F2.8, 40=F4.0, 48=F5.6, 56=F8.0
- ShutterSpeed: 16=30" 24=15" 32=8" 40=4" 56=1" 72=1/4 80=1/8 88=1/15 96=1/30 104=1/60 112=1/125 …
- ExpComp: 0=0.0EV

helper 内で LUT 化して UI に「1/125」「F2.8」「ISO 400」で見せる。

## 11. エラーコード (PDF p.67)

すべて `int` を返す。慣習: 成功 = `Result_OK` (`0x2001`) または `0`。**NSError / NSException は使わない**。

主要:
- `0x2001` OK
- `0x2002` GENERAL_ERROR
- `0x2005` OPERATION_NOT_SUPPORTED
- `0x2006` PARAMETER_NOT_SUPPORTED
- `0x2007` INCOMPLETE_TRANSFER
- `0x2019` DEVICE_BUSY
- `0x201D` INVALID_PARAMETER (NULL 渡し含む)
- `0xA080` CHECKSUM_ERROR
- `0xA081` NOT_INITIALIZED
- `0x80004002` NOT_INTERFACE (セッション未 Open で API 呼び出し)
- `0x1001` SYSTEM_ERR (レスポンス無し)
- `0x1002` PTP_Not_Err

デバッグ: `sgm_SetComLogFunc` (block callback) + `sgm_SetIsCallComLogFunc(YES)` で通信ログ、`sgm_GetLastCommandData` で直前送受信の生バイト取得。

## 12. 並行性・スレッド

PDF 明記なし。**同一カメラハンドルへの sgm_ 呼び出しは 1 本の serial GCD queue に畳んで直列化**するのが安全。特に LV pull ループ (`GetCamViewFrame`) と CaptStatus ポーリング (`GetCamCaptStatus`) の並行は競合しやすい。

## 13. 実装含意（Helper 側の決めごと）

1. helper は `ImageCaptureCore.framework` + 全 27 SIGMA framework をリンクした Objective-C ホストプロセス
2. **全 SDK 呼び出しを 1 本の serial queue に直列化**
3. LV 再開/停止は「1 フレーム取ったら次を予約」の chain 方式、CaptureFlow が割り込める
4. 撮影の正典パターン: `SnapCommand(0x01, 0x01)` → `GetCamCaptStatus` を 100ms 周期で poll、`captStatus == 0x8003` を待つ → `GetPictFileInfo2` (FileCount 確認) → `GetBigPartialPictFile(storeAddress, 0..N, 1MB)` を逐次 → `ClearImageDBSingle`
5. 終了は逆順 `CloseApplication` → `CamClose` → `terminateSDK`。SIGTERM で確実に

## 14. PDF に明記されず実機で確定する項目

- fpL の対応可否・要求 fw
- `ptpcamerad`（macOS Image Capture デーモン）との排他
- `GetCamViewFrame` の返却バイナリの厳密なフォーマットと FPS
- `GetPictFileInfo2` の後にファイル名/サイズを取る手段（`sgm_GetLastCommandData` 生バイト解析の要否）
- `GetBigPartialPictFile` の推奨 chunk size と storeAddress の意味
- CaptStatus の ImageID の割当ルール（DBHead 起点か連番か）
- ポーリング推奨間隔（LV / CaptStatus / CamStatus2）
