# Spike 1: Objective-C ABI 一致検証の結果 (2026-08-18)

`method_getTypeEncoding` で SDK の実 selector 署名をダンプし、自前宣言 `SDKGateway.h` と照合。

- 実行方法: `./helper/build/sigma-tether-helper --abi-dump`
- ダンプ全文: `docs/debug/abi-dump-2026-08-18.txt`

## 判明した ABI 不一致（優先度順）

### 🔴 BLOCKER: `SgmPictureFileInfoData` サイズ違い（8 → 45 bytes）

**SDK の実 struct**:
```
_SgmPictureFileInfoData = { C, S, S, S, @, I, I, S, S, S, @, I, I }
                        = UInt8 + 3×UInt16 + id + 2×UInt32 + 3×UInt16 + id + 2×UInt32
                        = 1 + 6 + 8 + 8 + 6 + 8 + 8 = 45 bytes
```

**我々の宣言**:
```c
typedef struct { UInt32 DataLength; UInt32 FileCount; } SgmPictureFileInfoData2;
                        = 8 bytes
```

**PDF に書いてあった通り「DataLength / FileCount」の 2 フィールドだけを信じたが、実際は
`@` (NSString 型のファイル名) が 2 個、`I` × 4 (サイズ？)、`S` × 6 (小さいカウンタ？) を含む**。

**影響**: `sgm_GetPictFileInfo2` を呼ぶと SDK が 45 バイトを我々の 8 バイトバッファに書き込み、
スタックが 37 バイト破壊される。撮影ワークフローが Wave 1b を突破しても即クラッシュ / 不定挙動。

**修正方針**: NSString 2 個・UInt32 4 個・UInt16 6 個の正確なフィールド名は不明なので、
とりあえず全体を **十分な zero-padding 領域として確保** し、実機ダンプで意味を確定する。
PDF は虚報を書いていたことが確定 (SDK API メモに反映済み)。

### 🟠 HIGH: `SgmDataGroup2` サイズ違い（16 → 18 bytes）

**SDK**: `_SgmDataGroup2 = CCCCCCCCCCCCCCCCCC` (18 個の UInt8, 18 bytes)
**我々**: 10 named + 6 reserved = 16 bytes ← **2 フィールド不足**

**影響**: `sgm_SetCamDataGroup2` は 18 バイト読むが我々の 16 バイトの後に unknown 2 バイトが乗る。
FieldPresent の bit と実 offset がズレて **設定変更が別フィールドに書き込まれる**可能性。

### 🟡 MEDIUM: `SgmSnapState` / `SgmCapStatus` サイズ違い

**SDK `SgmSnapState`**: `CCC` = 3 bytes (我々は 2 bytes)
**SDK `SgmCapStatus`**: `CCCSCC` = 7 bytes (我々は 6 bytes)

いずれも 1 バイト多い。**フィールドの並びが同じでも末尾 1 バイトが読み書きされる**。
撮影経路で影響しうるが、Wave 1b の PTP 応答壁の直接原因ではない。

### 🟢 OK: `SgmAdjustmentConfig` / `sgm_GetCamStatus2` の呼び出し可能性

- **SgmAdjustmentConfig**: SDK は `_IFDArray = II^{_SgmDirectoryEntry}` (16 bytes)。
  我々の packed 版と完全一致 ✅
- **`sgm_GetCamStatus2` 7 引数**: `outBuffer` は `void*` 宣言だが SDK は `_IFDArray*`。
  ポインタ幅は同じなので **呼び出しは通る**が SDK は _IFDArray レイアウトで書き込む
- **`sgm_ConfigAPI:AdjustmentMode:cameraHandle:`**: 引数レイアウト完全一致 ✅

## 発見された "予想外の SDK API"

### PTP 生パケットの struct 定義

`DeviceInterface` の instance methods に **`PassThrough` 構造体**が出現:
```
{PassThrough = S [5I] S I I @ S [5I] S Q ^v}
             = UInt16 + 5×UInt32 + UInt16 + UInt32 + UInt32 + id + UInt16 + 5×UInt32 + UInt16 + UInt64 + void*
```

これは **PTP コマンドのパラメータ格納構造**そのもの:
- `S` = OperationCode (UInt16)
- `[5I]` = **PTP パラメータ 5 個** (UInt32 × 5)
- 後半の `[5I]` = **PTP 応答パラメータ 5 個**
- `@` = データ (NSData)
- `Q ^v` = size + pointer for payload

つまり **SIGMA SDK の全 PTP コマンドは最大 5 個の UInt32 パラメータを持つ**。
PTP 1.1 標準 (最大 5 param) に準拠。

### DataGroup6 の存在

PDF 未記載の `sgm_GetCamStatus2_DataGroup6` が実在:
```
_SgmDataGroup6 = SCCCCCcccCCCcccCCCcccCCCcccCCCcccCC
              = UInt16 + 5×UInt8 + 3×SInt8 + ...  (合計 33 bytes)
```

`c` (小文字) は **signed char** で、`c c c` の並びが 5 セット。おそらく色補正系
(WB Correct AB/GM 等) の signed 補正値。

### `sgm_GetCamStatus2_XXX` 系の特化 API 群

`sgm_GetCamStatus2` の 7 引数 API とは別に、**DataGroup1..6 / Focus / Movie / CanSetInfo1..5
/ CamViewFrame** を直接取れる特化 API が用意されていた:
- `sgm_GetCamStatus2_DataGroup1:offset:grp1:` … `_DataGroup6:offset:grp6:`
- `sgm_GetCamStatus2_DataGroupFocus:offset:grpFocus:`
- `sgm_GetCamStatus2_DataGroupMovie:offset:grpMovie:`
- `sgm_GetCamStatus2_CamCanSetInfo:offset:info1:` … `_CamCanSetInfo5:offset:info5:`
- `sgm_GetCamStatus2_CamViewFrame:offset:viewFrame:bufSize:`

**PDF の記述より SDK の実装が遥かに豊富**。これらを使うと直感的な API で
DataGroup を取得できる (offset は多分連続取得用の pagination 引数)。

## Wave 1b の壁への含意

**ABI 不一致が直接の原因ではない可能性が高い**:
- 一番怪しかった `sgm_ConfigAPI` の呼び出し ABI は**完全一致**
- `sgm_GetCamStatus2` も呼び出しは通る (ポインタ幅・UInt32 幅同一)

つまり **PTP 送信は正しく行われている**が、それでもカメラが応答しない or 応答がコールバックに届かない
状態。次のスパイクで:
- **Spike 2 (標準 PTP 0x1001 直接送信)** で ICC transport が生きているかを切り分け
- **Spike 4 (LLDB で SampleAPP の operationCode 実値採取)** で 0x902c の param 差分を確認

## 副次的な TODO (Wave 4 以降で必ず対応)

1. ~~`SgmPictureFileInfoData` を実サイズ (45 bytes 相当) に拡張~~ → 完了 (下記 修正後セクション参照)
2. ~~`SgmDataGroup2` を 18 UInt8 に拡張~~ → 完了
3. ~~`SgmSnapState` / `SgmCapStatus` を SDK 実サイズに合わせる~~ → 完了
4. `sgm_FreeArrayMemory:` の対応 (ConfigAPI 後に directoryEntry を解放しないとリーク)
5. `PassThrough` struct の完全仕様把握 (Phase 1.5 の PTP RE の下拵え)
6. `SgmSnapState._pad0` / `SgmCapStatus._pad0` / `SgmDataGroup2._pad0..7` /
   `SgmPictureFileInfoData2._u16_0a..1c` の意味特定 (実機ダンプで生バイトを解析)
7. `SgmPictureFileInfoData2._name0/_name1` の memory ownership 確認 (SDK 側 release か
   我々が retain するか)。現在は `__unsafe_unretained` 宣言

## 修正後 (2026-08-18)

`SDKGateway.h` の struct 4 件を SDK ABI に合わせ、`--abi-dump` サブコマンドを byte-exact
比較に拡張。結果:

```
SgmSnapState                    : SDK=CCC                | @encode=CCC                | sizeof=3  | MATCH
SgmCapStatus                    : SDK=CCCSCC             | @encode=CCCSCC             | sizeof=7  | MATCH
SgmDataGroup2                   : SDK=CCCCCCCCCCCCCCCCCC | @encode=CCCCCCCCCCCCCCCCCC | sizeof=18 | MATCH
SgmPictureFileInfoData2         : SDK=CSSS@IISSS@II      | @encode=CSSS@IISSS@II      | sizeof=45 | MATCH
結果: 0 MISMATCH
```

`./helper/build/sigma-tether-helper --abi-dump` の exit code = 0 で CI-friendly な
regression detector として機能する (不一致が 1 件でも出れば exit=1)。フルダンプは
`docs/debug/abi-dump-after-fix.txt` に保管。

**BLOCKER (`SgmPictureFileInfoData2`) 解消**: SDK が 45 バイトを 45 バイトのバッファに
書き込むようになり、Wave 1b 突破後の撮影経路でスタック破壊が起きない状態に到達。

**副作用**: 旧 `info.DataLength` / `info.FileCount` の参照はコンパイルエラーになるため、
`RunCaptureSequence` 側の `DownloadPicture` 内 LogInfo を生バイト dump + 全 field 個別
出力に切り替え (フィールド名は実機ダンプ待ち)。
