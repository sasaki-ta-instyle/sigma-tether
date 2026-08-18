#!/bin/bash
# Spike 4: LLDB で SampleAPP を追いかけて sgm_GetCamStatus2 (0x902c) の
# operationCode1..3 実値と、sendCommandDelegate の実体を採取する。
#
# 実施手順:
#   1. fp か fpL を USB で Mac に繋ぐ
#   2. `sudo killall ptpcamerad` (race 回避)
#   3. このスクリプトを実行 → SampleAPP 起動 & LLDB attach
#   4. LLDB プロンプトで下記のコマンドを順に叩く (別途 spike4_lldb_commands.txt に記載)
#   5. SampleAPP は自動でカメラ検出→ConfigAPI→GetCamStatus2 polling を始める
#      → breakpoint が hit したらレジスタ / スタック / 引数を dump
#
# 目的:
#   - `+[sgm_GetCamStatus2 sgm_GetCamStatus2:buffLength:recvLength:operationCode1:operationCode2:operationCode3:cameraHandle:]`
#     の実 param (opCode1..3) を採取
#   - `-[DeviceInterface PTP_Command:param:commandType:retry:]` の PassThrough struct 中身
#   - `[cam requestSendPTPCommand:...:sendCommandDelegate:X ...]` の X (sendCommandDelegate 実体)
#   - callback `didSendPTPCommand:...` が発火するスレッドの識別
#
# 前提: Xcode Command Line Tools の lldb (`xcode-select --install` 済み)

set -e

SAMPLE_APP="/Volumes/CameraControlSDK_for_Mac/SampleProgram/SampleAPP.app/Contents/MacOS/SampleAPP"

if [[ ! -f "$SAMPLE_APP" ]]; then
    echo "❌ SampleAPP が見つからない: $SAMPLE_APP"
    echo "   SIGMA Camera Control SDK for Mac をマウントしてください"
    exit 1
fi

echo "🎬 SampleAPP を LLDB attach 前提で起動します"
echo ""
echo "手順:"
echo "  1. 別 terminal で: sudo killall ptpcamerad"
echo "  2. このスクリプト実行中の LLDB プロンプトで:"
echo "     (lldb) source scripts/spike4_lldb_commands.txt"
echo "  3. run コマンドで SampleAPP 実行を開始"
echo ""
echo "続行するには Enter..."
read -r

# LLDB で起動 (attach ではなく launch)
exec /usr/bin/lldb -o "target create $SAMPLE_APP" \
    -o "source $(dirname "$0")/spike4_lldb_commands.txt" \
    -o "run"
