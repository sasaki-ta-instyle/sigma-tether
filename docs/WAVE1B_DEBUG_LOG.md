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

## 未検証で試す価値ある項目

1. **Developer ID 署名の効果** — SampleAPP は SIGMA が Developer ID で正式署名 (TeamIdentifier=YPD8HGHUQZ)。macOS 15 は ad-hoc 署名だと Camera 系 API の権限が制限される可能性
2. **`NSMainNibFile = MainMenu` の効果** — SampleAPP は MainMenu.nib を持ち NSApplicationMain で標準起動、我々は init を手動でやる
3. **`applicationDidFinishLaunching:` 経路での SDK 呼び出し** — SDK が `NSApplication` の起動通知を待って内部状態を初期化する可能性
4. **USB パケットキャプチャ** (Phase 1.5 でどのみち必要) → SampleAPP と helper の USB PTP パケット差分を採取して、SDK が実際に送っている内容の違いを検証
5. **SIGMA developer support への問い合わせ** — vendor が持っている実装ガイドラインの共有

## 収集済み診断データ

- `docs/debug/sigma-tether-log-20260817.log` — helper 側 SDK 内部 log
- `~/Desktop/SampleAPPLog-*.log` — SampleAPP 側 SDK 内部 log (成功時の参考)
- OS 統合 log (`log show --predicate ...`) で helper と SampleAPP の IC framework レベルの動作差分

## 現時点でのコード状態

`helper/src/main.mm` / `helper/src/SDKGateway.h` / `helper/Makefile` / `helper/build/SigmaTetherHelper.app/Contents/Info.plist`:
- ビルド可能、実行可能
- session 確立まで完璧
- sgm_ 呼び出しで retry ループに入る

## 次に着手すべきこと

**優先度順**:

1. **Wave 1b は一旦保留**。Phase 1.5 の USB パケットキャプチャ (PTP RE) を前倒しで着手し、SampleAPP の PTP パケット列を採取
2. 差分解析で「SDK が SampleAPP のときだけ camera に送っている特定の初期化コマンド」を発見
3. その初期化を helper に追加して Wave 1b を再開
4. あるいは並行して SIGMA developer support に問い合わせ（4-5 週待ちを覚悟）
5. どうしても解決しない場合は Wave 2 以降を Phase 1.5 (arm64 native + PTP RE) にジャンプ

**現時点で helper の外形は完成**しているので、PTP プロトコルレベルの初期化ハンドシェイクを解読すればすぐ再開できる。
