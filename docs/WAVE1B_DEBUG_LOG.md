# Wave 1b 実機テスト — 進捗と未解決の壁 (2026-08-17)

## 到達点

fpL 実機接続で helper を走らせ、**セッション Open + content catalog 完了までは完璧に到達**。しかし **SDK 側の `sgm_GetCamStatus2` / `sgm_ConfigAPI` の PTP コマンド (OpCode 0x902c / 0x9035) を送っても fpL が応答を返さず、30 秒毎に retry する状態**で停止。SIGMA 純正 SampleAPP は同じ fpL で正常に応答が返るため、**カメラの問題ではなく helper の環境設定の差分**が原因。

## 検証済み事実

### ✅ 成功

- x86_64 Rosetta 2 での起動
- 27 SIGMA framework のロード + `DeviceInterface` / `sgm_ConfigAPI` 等のクラスメソッド dispatch
- `sgm_initializeSDK` = OK
- ICDeviceBrowser で `SIGMA fp L` (VID 0x1003 / PID 0xC442) 検出
- `[cam requestOpenSession]` → `didOpenSessionWithError` (成功) → `deviceDidBecomeReadyWithCompleteContentCatalog:`
- Info.plist に `SGM_DEBUG` / `SGM_COMLOG` / `SGM_LOGPATH` / `SGM_TIMEOUT` を仕込むと SDK 内部 debug log がデスクトップに出力される
- SDK が PTP コマンドを `requestSendPTPCommand:...:sendCommandDelegate:` 経由で送信することを disassemble で確認 (`DeviceInterface` 自身が sendCommandDelegate)

### ❌ 未解決

- `sgm_GetCamStatus2 (OpCode 0x902c)` / `sgm_ConfigAPI (OpCode 0x9035)` の PTP コマンドをカメラが受理しない → SGM_TIMEOUT (30秒) で timeout → `[WAR] cmd=0x902c retry...N times` を無限に繰り返す
- SampleAPP は同じ fpL で同じ OpCode を **数十 ms で応答受信** できる

## SampleAPP との差分 (試したがどれも効果なし)

| 差分ポイント | SampleAPP | 我々の helper | 効果 |
|---|---|---|---|
| bundle 化 | `.app` | 生 CLI → `.app` | ✗ 変わらず |
| Info.plist / SGM_* keys | あり | 同キー追加 | ✗ 変わらず |
| Bundle Identifier | `jp.co.sigma-inc.SampleAPP` | 同 ID コピー | ✗ 変わらず |
| 署名 | SIGMA Developer ID | ad-hoc | (未検証) |
| NSApp.run 有無 | あり (Cocoa app) | 遅延 init + NSApp.run 追加 | ✗ 変わらず |
| メインキューで sgm 呼び出し | main thread | main queue dispatch | ✗ 変わらず |
| GetCamStatus2 warm-up | あり (ConfigAPI 前 2 回 polling) | 追加 | ✗ 変わらず |
| `sgm_CamOpen:` を挟むか | 呼ばない | 呼ばない (SampleAPP に合わせた) | (関係ない) |
| `[cam requestOpenSession]` 直接 | 呼ぶ | 呼ぶ | (関係ない) |
| Content Catalog Complete 待ち | (推定) 待つ | 待つ | (関係ない) |
| `sgm_SetComLogFunc:` 事前呼び | あり | あり | ✗ 変わらず |
| `sgm_SetIsCallComLogFunc(YES)` | あり | あり | (SDK log は出るように) |

## 未検証で試す価値ある項目 (2026-08-18 Codex レビュー反映で優先順位を再構築)

### 【最優先】USB キャプチャ前に helper 単体でできる無料診断 5 件

Codex の指摘: Wave 1b の壁を「Developer ID 署名不足」と見た仮説は**弱い**（PTP 送信処理まで到達しているのが観測できているため）。以下 5 項目を先に消化する。

### Wave 1b 実機検証結果 (2026-08-18 セッション後半)

fpL 接続 + `arch -x86_64 lldb -p <SampleAPP-PID>` (get-task-allow 再署名) で LLDB attach、
Spike 2/2b/2c/2d/2f を実施した結果、**主犯仮説がほぼ確定**した:

| 検証項目 | 結果 |
|---|---|
| **Spike 2** (Apple ICC 直接 `requestSendPTPCommand` 0x1001) | ✅ **成功** (281 bytes response, callback on main thread) |
| **Spike 2b** (SDK 内部 `PTP_Command:param:commandType:retry:` for 0x1001, commandType=0/1/2) | ❌ 全 3 パターン rc=4097 (SgmResultSystemError) |
| **Spike 2c** (SDK 内部 `PTP_ReceiveData:param:retry:` for 0x1001) | ❌ rc=4097 |
| **Spike 2d** (`sgm_CamOpen` → `sgm_ConfigAPI` = SampleAPP 同順序) | ❌ rc=4097 |
| **Spike 2f** (bundle ID を `jp.co.sigma-inc.SampleAPP` に変更) | ❌ rc=4097 |
| **Spike 4** (SampleAPP LLDB attach) | ⚠️ 部分成功 |
| **同じ fpL に SampleAPP** で `sgm_ConfigAPI` | ✅ **成功** (0x9035 ResCode 0x2001, 76 bytes) |

Spike 4 LLDB での hit カウント (SampleAPP 側):
- `+[sgm_GetCamStatus2 sgm_GetCamStatus2:...]` hit=0 (SampleAPP は warm-up 呼ばない)
- **`-[DeviceInterface PTP_Command:param:commandType:retry:]` hit=1** ← SDK 内部で使う
- **`-[DeviceInterface PTP_ReceiveData:param:retry:]` hit=1** ← SDK 内部で使う
- `-[DeviceInterface PTP_SendCommand:param:retry:]` hit=0
- `-[DeviceInterface didSendPTPCommand:...]` hit=0
- `-[ICCameraDevice requestSendPTPCommand:...]` hit=0

### 主犯仮説の絞り込み

- ❌ **selector 選択** (PTP_Command vs PTP_ReceiveData) → どちらでも失敗
- ❌ **commandType 値** (0/1/2) → 全部失敗
- ❌ **sgm_CamOpen 順序** → 有無どちらでも失敗
- ❌ **bundle identifier** → SampleAPP と同じにしても失敗
- ✅ **Apple ICC 直接** = ICC/USB/Rosetta/カメラ側 は健全
- 🎯 **残る主犯候補 (次セッション着手順)**:
  1. **AppKit 初期化順序**: SampleAPP は NSApplicationMain + Nib (MainMenu.xib) 経由、
     我々は `[NSApplication sharedApplication]` を手動 → SDK が nib-driven runloop 前提の
     可能性 (`[NSApp finishLaunching]` 明示呼び, `LSUIElement` 削除, MainMenu.xib 化 が候補)
  2. **署名層** (Developer ID / notarization / hardened runtime): SIGMA は Developer ID
     Application `YPD8HGHUQZ` で signed + notarized。ad-hoc 署名との差が SDK 内部の
     PTP callback dispatch 判定に影響している可能性

### Info.plist の差分参照

SampleAPP と我々の Info.plist を突合した結果 (次セッションで真似できる範囲):
- SampleAPP: `NSMainNibFile = MainMenu` (我々は無し)
- SampleAPP: `LSUIElement` 無し (Dock 表示アプリ)、我々は `LSUIElement = true` (Accessory)
- SampleAPP: `NSHumanReadableCopyright = ©SIGMA Corporation`
- SampleAPP: `NSPrincipalClass = NSApplication` (同一)
- SampleAPP: `Team ID YPD8HGHUQZ (SIGMA), Notarized, Runtime v10.15.0, hardened runtime`

### 次セッションのクリティカルパス

1. Spike 2g: `LSUIElement` を削除、`[NSApp finishLaunching]` を明示呼び + `[NSApp activate]`
   → NSApplicationMain 相当の初期化順序を手動で完成させる
2. Spike 2h: MainMenu.xib + AppDelegate.m を追加、`main.m` を `NSApplicationMain(argc, argv)` に
   置き換え (Nib driven の完全再現)
3. どちらもダメなら **署名層** の実験へ (Apple Developer 加入 or SIGMA サポート問い合わせ)

--- 

1. ✅ **Objective-C ABI 一致検証** (2026-08-18 完了)
   `--abi-dump` サブコマンドで SDK 実 selector 署名を `method_getTypeEncoding` で全部
   ダンプ。**4 件の struct 不一致を発見** (`SgmPictureFileInfoData` 8→45 bytes が 🔴 BLOCKER、
   `SgmDataGroup2` 16→18 bytes、`SgmSnapState` 2→3 bytes、`SgmCapStatus` 6→7 bytes)。
   同日中に `SDKGateway.h` を修正、`--abi-dump` を byte-exact 比較に拡張して 4 件すべて
   MATCH / exit=0 を確認。詳細は `docs/SPIKE1_ABI_ANALYSIS.md` / dump は
   `docs/debug/abi-dump-2026-08-18.txt` (修正前) + `docs/debug/abi-dump-after-fix.txt` (修正後)。
   → **PTP 応答受信時のスタック破壊リスクを除去**。ただし SDK が呼び出し ABI (`sgm_ConfigAPI` /
   `sgm_GetCamStatus2`) 自体は完全一致していたので、Wave 1b の PTP 応答壁の直接原因では
   なさそう。Spike 2/3/4/5 に続く。
2. **標準 PTP `GetDeviceInfo (0x1001)` を SDK バイパスで直接送信** (コード実装済み)
   - **`--spike2`** (ICC 直接): `sgm_*` も SDK の PTP_Command も通さず、Apple ICC
     `requestSendPTPCommand:` で `0x1001` を直接送って completion が返るか確認
   - **`--spike2b`** (SDK 内部経由): SDK 内部の `-[DeviceInterface PTP_Command:param:commandType:retry:]`
     を SgmPassThrough struct 経由で叩き、SDK の PTP transport 層だけを使う対照試験
   - 4 象限で切り分ける (fpL 接続時実行):
     - Spike 2 OK / Spike 2b OK → sgm_* 層の問題
     - Spike 2 OK / Spike 2b NG → SDK 内部経路が壊れている (PTP_Command params 誤り等)
     - Spike 2 NG / Spike 2b OK → 想定外 (通常起き得ない)
     - Spike 2 NG / Spike 2b NG → ICC/TCC/USB 層の問題 (Developer ID 署名や TCC 権限)
3. **main queue 自己待ち対照試験**
   現状 `dispatch_async(dispatch_get_main_queue(), ^{ RunCaptureSequence(cam); ... })` で main queue 上で同期 SDK 呼び出しをしている。**PTP completion が main queue に戻る実装だと deadlock する** ため、専用 worker queue から発行して main queue は完全に runloop pump に専念する構成に切り替えて比較
4. **`GetCamStatus2` の operationCode1..3 の実値採取**
   SampleAPP の `-[DeviceInterface PTP_Command:param:commandType:retry:]` に LLDB breakpoint を仕掛けて、SampleAPP が 0x902c を送るときの実 param を採取。**全ゼロで送っている我々の実装と比較**。全ゼロが SIGMA fp/fpL にとって「意味のあるコマンド」でない場合、カメラは応答返さない可能性が高い
5. **`sendCommandDelegate` の実体・selector・スレッド確認**
   `class-dump` + LLDB で SampleAPP 実行時に `DeviceInterface` が sendCommandDelegate 引数に何を渡し、`didSendPTPCommand:...` がどのスレッドで発火するかを確認。helper 側と比較して差分があれば callback 経路の穴を特定

これらは helper 単体でできる。**5 項目全部が空振りなら USB キャプチャに進む**。

### 【中優先】USB キャプチャベースの本格 PTP RE (Phase 1.5 Wave 1)

- SampleAPP を fpL に繋いだ状態で `sudo tcpdump -i XHC20 -w sample.pcap`
- 我々の helper でも同じキャプチャ
- Wireshark PTP dissector で **バイト単位で差分解析**
- SIGMA vendor OperationCode の完全表を `docs/PTP_PROTOCOL_NOTES.md` に

### 【低優先】外部確認

- **Developer ID 署名の効果** — 上記 5 項目が全部空振りなら SIGMA から一時的な Developer 証明書を借りて試すか、有料 Apple Developer 加入 ($99/年) で試す
- **`NSMainNibFile = MainMenu` の効果** — Nib 経由の NSApplicationMain で起動する構成に組み替え
- **SIGMA developer support への問い合わせ** — vendor が持っている実装ガイドラインの共有交渉

## 収集済み診断データ

- `docs/debug/sigma-tether-log-20260817.log` — helper 側 SDK 内部 log
- `~/Desktop/SampleAPPLog-*.log` — SampleAPP 側 SDK 内部 log (成功時の参考)
- OS 統合 log (`log show --predicate ...`) で helper と SampleAPP の IC framework レベルの動作差分

## 現時点でのコード状態

`helper/src/main.mm` / `helper/src/SDKGateway.h` / `helper/Makefile` / `helper/build/SigmaTetherHelper.app/Contents/Info.plist`:
- ビルド可能、実行可能
- session 確立まで完璧
- sgm_ 呼び出しで retry ループに入る

## 次に着手すべきこと (2026-08-18 Codex レビュー反映後)

**優先度順**:

1. **上記【最優先】5 項目スパイクを消化** — USB キャプチャに行く前に helper 単体で試せる無料テスト群。ABI 照合 → 標準 PTP 直接送信 → main queue 対照試験 → operationCode 実値採取 → delegate 経路確認 の順
2. **並行: `GetBigPartialPictFile` chunk 連結ロジックの修正着手** — Codex 指摘の構造リスク。返却バイトのヘッダ・チェックサム剥がしを実装しないと Wave 1b が通っても DNG が壊れる
3. スパイクで原因が絞れれば helper を修正 → Wave 1b 突破 → Wave 2 (HTTP サーバ) に進む
4. **5 項目全部空振り**なら Phase 1.5 の USB PTP キャプチャに正式着手
5. **SIGMA vendor OperationCode に暗号化 / 非公開拡張が見つかったら** SIGMA developer support への問い合わせに切り替え (4-5 週待ちを覚悟)、その間は Wave 2〜6 のうち PTP に依存しない部分 (HTTP サーバ / UI シェル / Dropbox 書き込みロジック) を先行実装

**現時点で helper の外形はほぼ完成**しているので、PTP プロトコルレベルの初期化ハンドシェイクを解読すればすぐ再開できる。
