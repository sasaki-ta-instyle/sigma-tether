# Codex レビュー (2026-08-18)

Codex (`gpt-5-4`, Codex CLI 0.147.0) に sigma-tether プロジェクトを「お題との整合性」観点でレビュー依頼した結果。修正コードなし、講評と論点整理のみ。

- 依頼元: Claude Code セッション (`~/Workspace/sigma-tether/`)
- Codex セッション ID: `01a01303-58c1-7450-9189-7f605900238d`
- 実行時間: 1 分 32 秒

## 1. お題整合性の総評

Phase 1〜2 を完遂すれば「USB 制御・DNG テザー保存・Dropbox・HTML UI・Mac 無し iOS 直結」は概ね満たす。ただし現状は撮影成立前で、Phase 2 の iOS PTP 可否も未実証のため、納期見積もりと「実用完成」の確度はまだ低い。特に **Phase 1.5 を独立した将来対応ではなく、Wave 1b 解決と Phase 2 可否判定のための検証フェーズとして再定義する余地がある**。

## 2. 強い懸念（早めに手を打つべき）

- **Phase 2 の成立条件が未検証のまま、3〜4 週と見積もられている**。計画自身も「iPadOS で fp/fpL 認識」「vendor OpCode 許可」を撤退条件としており、まず検出・標準 PTP・0x9000 系の 3 段階スパイクが必要
- **Wave 1b の 30 秒タイムアウトを署名問題と見る根拠は弱い**。`docs/WAVE1B_DEBUG_LOG.md` とログでは、セッション・catalog・PTP 送信処理まで到達している。Developer ID より、ABI、コマンド引数、応答コールバック経路を先に疑うべき
- **API 宣言・構造体レイアウトが実機未確定のまま進んでいる**。`SDKGateway.h` の `packed` 構造体、`GetCamStatus2` の 7 引数、全ゼロの operationCode、DataGroup2 の「安全側 padding」は、Objective-C dispatch 自体が成功しても ABI 不一致を起こし得る
- **成果物の受け入れ基準が正常系中心で、個人利用の実用性を十分定義していない**。切断・再接続、Dropbox 停止/容量不足、撮影連打、30 分運用、保存失敗時の再取得、アプリ強制終了後の復旧が E2E 基準にない
- **Phase 1 の 2〜3 週は既に前提が崩れている**。最大未知数だった Wave 1 が未解決で、PTP RE も前倒し対象になった。以後の期間は固定日数ではなく、検証ゲート通過後に再見積もりする方が妥当

## 3. 論点として上げたい提案

- Phase 1.5 Wave 1 を今すぐ前倒しし、「USB キャプチャ」だけでなく SampleAPP の正確な呼び出し引数・スレッド・delegate 経路を確定する診断フェーズとして扱ってはどうか
- Phase 1 の価値を早く出すなら、Wave 1b 突破後は設定パネルより先に「シャッター、DNG 保存、保存結果、再接続」へ絞ってはどうか。全 DataGroup 対応は MVP 後でもお題の中核を損なわない
- 反対に、ライブビューは「コントロール」の期待値に直結するため完全後回しにせず、撮影成立直後に返却形式・実 FPS・撮影との排他だけ検証してはどうか
- Rosetta MVP → arm64 native の順序自体は合理的。ただし SDK 経路がすでに閉塞しているため、Phase 1 完了後に始める直列計画ではなく、PTP 解析のみ並行する現在方針を正式なクリティカルパスにしてはどうか
- WKWebView による HTML/JS 再利用は妥当だが、「同じ UI ソース」までを目標にし、HTTP/WebSocket/MJPEG まで同一にすることは必須にしない方がよい。計画にも MJPEG が WKWebView で効かない可能性が記載されている
- Bonjour 広告省略は個人 LAN 用途なら許容できる。一方、認証なしで `0.0.0.0` へ公開すると LAN 上の誰でも撮影・設定変更・終了 API を実行できるため、少なくとも既定 localhost/LAN 公開切替を検討してはどうか
- Dropbox 保存の成功を「rename 成功」ではなく、「DNG 検証成功・Dropbox 配下への確定・同期状態または同期開始確認」の段階表示にしてはどうか。クラウド同期完了は helper 単独では保証できない
- MVP の受け入れ基準として、fp と fpL 双方、50〜100 枚連続、USB 抜去復旧、Dropbox 停止、ディスク不足、同名衝突、DNG を Lightroom/Adobe DNG Converter で開けることを明文化してはどうか

## 4. Wave 1b の壁に対する追加突破仮説

- **Objective-C ABI 不一致仮説**。`method_getTypeEncoding` で実 framework の `GetCamStatus2` / `ConfigAPI` 署名を取得し、自前宣言と照合する。特にポインタ幅、`UInt32`、構造体 packing、引数順を確認する価値が高い
- **メインキュー自己待ち仮説**。現実装はメインキュー上で同期 SDK 呼び出しを行うため、PTP completion がメインキューへ戻る実装なら停止する。NSApp の run loop を空け、専用 worker から 1 コマンドだけ発行する対照試験が有効
- **`GetCamStatus2` 引数内容の誤り仮説**。現実装は 3 つの operationCode をすべて 0 で渡している。SampleAPP の `DeviceInterface PTP_Command:param:commandType:retry:` へ LLDB breakpoint を置き、0x902c の実 param を USB キャプチャ前に比較できる
- **ImageCapture transport と SIGMA SDK を切り分ける仮説**。catalog 完了直後に `requestSendPTPCommand:` で標準 `GetDeviceInfo(0x1001)` を直接送り、completion が返るか確認する。返れば USB/TCC より SDK の delegate・引数側へ絞れる
- **SDK 内部 delegate 配線差分仮説**。SampleAPP 実行時の `sendCommandDelegate` 実体、対応 selector、コールバックスレッドを runtime/LLDB で採取し、helper 側と比較する。送信ログが出ても応答受領先が欠けている可能性は未排除

## 5. リスク・盲点

- `SDK_API_NOTES.md` では `GetBigPartialPictFile` の返却サイズがヘッダ・チェックサム込みとされる一方、`main.mm` は全バイトをそのまま DNG へ連結する。**撮影まで通っても TIFF/DNG として壊れる構造リスクがある**
- SIGMA SDK framework を単体 `.app` へコピー・再署名・公開リポジトリへ載せられるかは **EULA 確認が必要**。個人利用でも再配布条件とリバースエンジニアリング条件は別問題になる
- macOS の TCC では Camera 権限だけでなく、Dropbox Business の CloudStorage 領域へのアクセスが起動主体・署名変更で **再許可**になる可能性がある。ad-hoc 再ビルド時の権限継続性は未確認
- iPad/iPhone 直結ではカメラへの給電方向、接続中の iPad 充電、USB ハブ経由、長時間ライブビュー時の発熱が実用性を左右する。PTP 成功だけでなく給電込みの 30 分試験が必要
- **Personal Team の 7 日失効**は「Mac 無しロケ」の直前にアプリが起動不能になる運用リスクになる。Phase 2 の技術成功とは別に、現場受け入れ基準へ署名有効期限確認を含める必要がある

---

## 反映状況 (2026-08-18)

上記のうち以下は既にプランと README に反映済:

- Phase 1.5 の再定義（クリティカルパス化、Wave 1b 診断 + Phase 2 可否判定を兼ねる）
- Wave 1b 突破のための 5 項目スパイク（プラン Wave 1 前段に追加）
- `GetBigPartialPictFile` の chunk 連結問題（プラン Wave 4 と README ハマりどころに構造リスクとして明記）
- 実用受け入れ基準（fp/fpL 両方、50〜100 枚連続、USB 抜去復旧、Dropbox 停止、ディスク不足、同名衝突、DNG が Lightroom で開ける）をプラン E2E 節に明文化
- LAN 開放と認証の設計（既定 `127.0.0.1`、CLI `--lan` で開放時にトークン認証自動 on）
- 保存完了の段階表示（`dng.received` → `dng.verified` → `dng.persisted` → `dng.syncing`）
- SIGMA SDK EULA チェックを README ライセンス節と落とし穴節に追加
- Personal Team 7 日失効を Phase 2 側の落とし穴として明記
- macOS TCC の Dropbox CloudStorage 再許可リスクを落とし穴節に追加
- 日数見積もりを固定日数から検証ゲートベースに変更
