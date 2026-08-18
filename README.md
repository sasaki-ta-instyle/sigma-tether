# sigma-tether

SIGMA fp / fpL を Mac に USB 接続し、**HTML ベースのブラウザ UI**（Mac / iPad / iPhone 対応）で操作、シャッターを切ると **DNG(RAW) が Dropbox 同期フォルダに自動保存**される、単体 `.app` バンドルのテザー撮影アプリ。

- SDK: SIGMA Camera Control SDK for Mac (2020-07-02, Ver 1.00, 27 framework)
- 対応カメラ: SIGMA fp Ver2.00+ / SIGMA fpL
- 対応 Mac: macOS 11+ (Apple Silicon は helper が Rosetta 2 実行 — SDK が x86_64 単一スライスのため)

## Phase 構造 (Codex レビュー反映後、2026-08-18)

3 フェーズで段階的に進める。**日数見積もりは検証ゲート通過後に再見積もる方針**（Wave 1b 閉塞で固定日数の直列計画は既に前提が崩れているため）。詳細プラン: `/Users/sasatake/.claude/plans/volumes-cameracontrolsdk-for-mac-docume-hidden-curry.md`

- **Phase 1** — Mac 版 tether (Rosetta 2 helper)。SIGMA SDK をそのまま使う。**現在ここ、Wave 1b で PTP 応答壁**
- **Phase 1.5** (クリティカルパス化) — PTP プロトコル解析 + arm64 native 化。**Wave 1b の壁解決 + Phase 2 可否判定を兼ねる**位置に前倒し、Phase 1 と並列
- **Phase 2** — iPad/iPhone ネイティブ tether (Xcode Personal Team sideload)。成立条件 3 段階スパイクを最優先

## 進捗

- ✅ Phase 1 Wave 1a: helper が Rosetta 2 で起動、`sgm_initializeSDK` が OK を返す（2026-08-16）
- ✅ Phase 1.5 準備: `SIGMA_TETHER_TRACE=1` で PTP 送受信バイトを stderr に吐く仕込み組み込み済
- ✅ `.app` バンドル化: Info.plist に `SGM_DEBUG` / `SGM_COMLOG` / `SGM_LOGPATH` / `SGM_TIMEOUT` を仕込み、SDK 内部 debug log がデスクトップに出力される状態
- 🚧 Phase 1 Wave 1b: fpL 実機で **session Open + content catalog 完了まで到達**、`sgm_ConfigAPI` / `sgm_GetCamStatus2` で **PTP 応答壁 (SGM_TIMEOUT=30秒 retry ループ)**。SIGMA 純正 SampleAPP は同じ fpL で正常動作 → helper 環境の差分が原因。詳細: `docs/WAVE1B_DEBUG_LOG.md`
- ⏭ Phase 1 Wave 2: HTTP + WebSocket + MJPEG サーバ化（既定 `127.0.0.1`、CLI 引数 `--lan` で開放時のみトークン認証 on）
- ⏭ Phase 1 Wave 3: HTML UI（dark tone flat）
- ⏭ Phase 1 Wave 4: 撮影 → Dropbox 保存フロー（**`GetBigPartialPictFile` の chunk 連結は返却バイトのヘッダ・チェックサム剥がしが必要**、Adobe DNG Converter で開けることが完了条件）
- ⏭ Phase 1 Wave 5: 設定パネル
- ⏭ Phase 1 Wave 6: `.app` バンドル化
- 🔥 Phase 1.5 前段診断: **Codex レビュー指摘の 5 項目スパイク**（`method_getTypeEncoding` での ABI 照合 / 標準 PTP `0x1001` 直接送信 / main queue 自己待ち対照試験 / SampleAPP LLDB で `operationCode1..3` 実値採取 / `sendCommandDelegate` 経路確認）

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

### ハマりそうな箇所（更新: 2026-08-18 Codex レビュー反映）

- **camera が検出されない**: macOS の Image Capture デーモン (`ptpcamerad`) が先に掴んでる可能性 → 一度 `sudo killall ptpcamerad` してから再実行
- **`sgm_ConfigAPI` / `sgm_GetCamStatus2` が SGM_TIMEOUT で retry ループ (現在ここ)**: 現時点の仮説は「Objective-C ABI 不一致」「main queue 自己待ち deadlock」「operationCode の実値誤り」「delegate 経路差分」のいずれか。詳細と対処ロードマップは `docs/WAVE1B_DEBUG_LOG.md`
- **`sgm_SnapCommand` は OK だが CaptStatus が 0x6004 (画像生成失敗) / 0x6005 (一般失敗) で落ちる**: カメラの露出モードが M 以外、レンズが装着されていない、シャッター物理的に切れない状態、など。カメラ本体で 1 枚シャッター切れることを先に確認
- **`sgm_GetBigPartialPictFile` の chunk が 0 バイトばかり返る**: `storeAddress` の意味を推測ミスしている可能性。`imageID` の代わりに `0` を試すか、`sgm_GetLastCommandData` で PTP 生バイトを覗く
- **DNG が壊れている** ⚠️ **Codex 指摘の構造リスク**: `GetBigPartialPictFile` の返却サイズはヘッダ・チェックサム込み (PDF 明記) なのに、現在の `main.mm` は全バイトそのまま連結している → Wave 1b の PTP 応答壁を突破しても **DNG が壊れて Lightroom で開けない**未来がある。Wave 4 実装時に chunk ごとに header/footer を剥がして中身だけ連結する。`hexdump -C <file>.dng | head` の先頭 4 バイトが `49 49 2A 00` (little-endian TIFF magic) にならないと NG

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

Private (個人利用のみ、配布予定なし)。

**SIGMA Camera Control SDK for Mac** は SIGMA Corporation の EULA に従う。この repo には SDK 本体の framework バイナリは含まれていない（helper 側の自前宣言ヘッダ / ラッパコードのみ）。ただし将来 `.app` バンドルに 27 framework をコピー・再署名して配布する形態を取る場合は、事前に SIGMA の**再配布条件・リバースエンジニアリング条件を確認**する（Codex レビュー指摘）。個人利用でも配布形態次第で EULA 判断が変わりうる。
