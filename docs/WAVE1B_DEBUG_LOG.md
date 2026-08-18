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

1. **Objective-C ABI 一致検証**
   `class_getClassMethod([sgm_ConfigAPI class], @selector(sgm_ConfigAPI:AdjustmentMode:cameraHandle:))` で取得したメソッドの `method_getTypeEncoding()` を dump し、自前宣言と比較。ポインタ幅・`UInt32`・構造体 packing・引数順が一致するかを確認。他の 27 fw クラスの主要 selector も全部照合。**不一致があれば PTP レスポンス受信時に stack を壊して SDK が retry ループに落ちる可能性がある**
2. **標準 PTP `GetDeviceInfo (0x1001)` を SDK バイパスで直接送信**
   `sgm_*` を通さず、`ICCameraDevice.requestSendPTPCommand:outData:sendCommandDelegate:didSendCommandSelector:contextInfo:` で `0x1001` を直接送って completion が返るか確認。**返れば ICC transport 層は健全 → SDK 内部の問題に絞れる**、返らなければ ICC/TCC/USB 層の問題
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
