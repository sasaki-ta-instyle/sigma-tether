# sigma-tether

SIGMA fp / fpL を Mac に USB 接続し、**HTML ベースのブラウザ UI**（Mac / iPad / iPhone 対応）で操作、シャッターを切ると **DNG(RAW) が Dropbox 同期フォルダに自動保存**される、単体 `.app` バンドルのテザー撮影アプリ。

- SDK: SIGMA Camera Control SDK for Mac (2020-07-02, Ver 1.00, 27 framework)
- 対応カメラ: SIGMA fp Ver2.00+ / SIGMA fpL
- 対応 Mac: macOS 11+ (Apple Silicon は helper が Rosetta 2 実行 — SDK が x86_64 単一スライスのため)

## Phase 構造

3 フェーズで段階的に進める（プラン詳細: `/Users/sasatake/.claude/plans/volumes-cameracontrolsdk-for-mac-docume-hidden-curry.md`）:

- **Phase 1 (2〜3 週)** — Mac 版 tether (Rosetta 2 helper)。SIGMA SDK をそのまま使う。**現在ここ**
- **Phase 1.5 (5〜7 週)** — Mac 版 arm64 native 化。PTP プロトコル解読 → SDK 依存を排除
- **Phase 2 (3〜4 週)** — iPad/iPhone ネイティブ tether (Xcode Personal Team sideload)

## 進捗

- ✅ Phase 1 Wave 1a: helper が Rosetta 2 で起動、`sgm_initializeSDK` が OK を返す（カメラ無しで検証済み、2026-08-16）
- ✅ Phase 1.5 準備: `SIGMA_TETHER_TRACE=1` で PTP 送受信バイトを stderr に吐く仕込みを組み込み済
- ⏳ Phase 1 Wave 1b: fp / fpL 実機で 1 枚 DNG が取れるか（sasaki 手元で試走が必要）
- ⏭ Phase 1 Wave 2: HTTP + WebSocket + MJPEG サーバ化、LAN 開放（Bonjour / トークン認証は v1 不要）
- ⏭ Phase 1 Wave 3: HTML UI（dark tone flat）
- ⏭ Phase 1 Wave 4: 撮影 → Dropbox 保存フロー
- ⏭ Phase 1 Wave 5: 設定パネル
- ⏭ Phase 1 Wave 6: `.app` バンドル化
- ⏭ Phase 1.5 Wave 1: PTP パケットキャプチャ（Phase 1 と並行可）

SDK API 抽出メモ: `docs/SDK_API_NOTES.md`

## Wave 1 の実機テスト手順（sasaki 手動）

### 準備

1. SIGMA fp（または fpL）を USB-C ケーブルで Mac に接続
2. カメラを M モードにセット
3. カメラのメニューで PC 接続モードに入る（fp: MENU → USB モード → PC 接続 相当。無ければケーブル接続だけで OK）
4. SD カードは抜いておく or 入れておく、どちらでも試す（`DestToSave` のふるまい確認のため）
5. SIGMA Camera Control SDK for Mac をマウント（`/Volumes/CameraControlSDK_for_Mac/` が見えていること）

### ビルド + 実行

```bash
cd "/Users/sasatake/Library/CloudStorage/Dropbox-cr-team/Sasaki Takeshi/Workspace/sigma-tether/helper"
make                                    # → build/sigma-tether-helper (x86_64)
./build/sigma-tether-helper             # 実行 (Rosetta 2 で自動)

# ↓ Phase 1.5 の PTP 解読に必要な生バイトを吐きながら実行する場合
SIGMA_TETHER_TRACE=1 ./build/sigma-tether-helper 2>&1 | tee /tmp/sigma-tether-trace.log
```

`SIGMA_TETHER_TRACE=1` を付けると、各 SDK 呼び出しの後に `[ptp ] sent:` / `[ptp ] received:` が出て、直前 PTP 送受信の生バイト (先頭 64 byte hex dump) が見える。Phase 1.5 の RE 素材になるので **Wave 1b の実機テストは trace 有効で走らせるのを推奨**。

期待する出力の骨格:

```
[info] ===== sigma-tether helper Wave 1 PoC =====
[info] process arch: 64-bit
[sdk ] sgm_initializeSDK                OK
[info] deviceBrowser didAddDevice: name=SIGMA fp  type=0x...
[info]   → adopted as target
[info] didOpenSessionWithError: (no error, session opened)
[info] camera adopted: name=SIGMA fp
[sdk ] sgm_CamOpen                      OK
[sdk ] sgm_ConfigAPI                    OK
[sdk ] SetCamDataGroup2 (DNG)           OK
[sdk ] sgm_SnapCommand                  OK
[poll] CaptStatus=0x0001  ImageID=0  DBHead=0  DBTail=1  Dest=0x02
[poll] CaptStatus=0x0004  ImageID=0  ...
[poll] CaptStatus=0x0005  ImageID=0  ...
[poll] CaptStatus=0x8003  ImageID=1  ...
[info] 撮影完了 imageID=1
[sdk ] sgm_GetPictFileInfo2             OK
[info] PictFileInfo2: DataLength=... FileCount=1
[dl  ] chunk[0] offset=0 got=1048576 bytes
[dl  ] chunk[1] offset=1048576 got=1048576 bytes
...
[info] ダウンロード完了 <N> bytes
[info] 保存成功: /Users/sasatake/Desktop/sigma-tether-YYYYMMDD-HHMMSS.dng
[sdk ] sgm_ClearImageDBSingle           OK
[info] ===== teardown =====
[sdk ] sgm_CloseApplication             OK
[sdk ] sgm_CamClose                     OK
[sdk ] sgm_terminateSDK                 OK
```

### 通ったら

1. `~/Desktop/sigma-tether-*.dng` を Adobe DNG Converter か Lightroom か `exiftool -a -G0 <file>` で開く
2. 通れば「実機接続 + 撮影 + ファイル取得」の**構造的な骨**は通ったので Wave 2 (LAN サーバ化) へ進む

### ハマりそうな箇所

- **camera が検出されない**: macOS の Image Capture デーモン (`ptpcamerad`) が先に掴んでる可能性 → 一度 `sudo killall ptpcamerad` してから再実行
- **`sgm_ConfigAPI` が FAIL**: 引数 NULL 渡しが問題の可能性。PDF p.12 の `SgmAdjustmentConfig` 構造体を用意して非 NULL で渡す
- **`sgm_SnapCommand` は OK だが CaptStatus が 0x6004 (画像生成失敗) / 0x6005 (一般失敗) で落ちる**: カメラの露出モードが M 以外、レンズが装着されていない、シャッター物理的に切れない状態、など。カメラ本体で 1 枚シャッター切れることを先に確認
- **`sgm_GetBigPartialPictFile` の chunk が 0 バイトばかり返る**: `storeAddress` の意味を推測ミスしている可能性。`imageID` の代わりに `0` を試すか、`sgm_GetLastCommandData` で PTP 生バイトを覗く
- **DNG が壊れている**: chunk の連結順が違うか、chunk データにヘッダ/フッタが混じっている。`hexdump -C <file>.dng | head` の先頭 4 バイトが `49 49 2A 00` (little-endian TIFF magic) になっていれば OK

### 生成物をこちらに送る場合

`~/Desktop/sigma-tether-*.dng` と、上記のログ全文（terminal から丸ごとコピペ）を貼ってもらえれば、Wave 1b の失敗ポイントを Claude 側で追える。

## リポ構造

```
sigma-tether/
├── docs/
│   ├── SDK_API_NOTES.md      # PDF から抽出した API 全体像
│   └── (RESUMING.md)         # 後で追加
├── helper/                   # x86_64 helper (Objective-C++)
│   ├── src/
│   │   ├── SDKGateway.h      # SDK class method の自前宣言
│   │   └── main.mm           # Wave 1 PoC
│   ├── Makefile
│   └── build/                # gitignore
└── README.md                 # このファイル
```

## ライセンス

Private. SIGMA Camera Control SDK は SIGMA Corporation の EULA に従う。
