# sigma-tether helper Makefile (Wave 1: 最小 CLI PoC)
#
# ビルド: `make`
# 実行:  `make run`   (build/sigma-tether-helper を fg 実行)
# 掃除:  `make clean`
#
# 想定環境:
#   - Apple Silicon Mac (M3 Pro / M4 Air) + Xcode Command Line Tools 15+
#   - SIGMA Camera Control SDK for Mac がマウント済み
#     (`ls /Volumes/CameraControlSDK_for_Mac/SDK` が通ること)
#
# SDK が別パスに置かれている場合は SDK_ROOT を上書きする:
#   make SDK_ROOT=/path/to/SDK

# ---- Paths --------------------------------------------------------------

SDK_ROOT ?= /Volumes/CameraControlSDK_for_Mac/SDK

SRC_DIR  := src
BUILD_DIR := build
TARGET   := $(BUILD_DIR)/sigma-tether-helper

SOURCES  := $(SRC_DIR)/main.mm
OBJECTS  := $(SOURCES:$(SRC_DIR)/%.mm=$(BUILD_DIR)/%.o)

# ---- Toolchain ----------------------------------------------------------

# SDK は x86_64 単一ビルドなので、helper 全体を x86_64 に統一する。
# Apple Silicon 上で実行する際は自動的に Rosetta 2 で走る。
CXX      := clang++
ARCH     := -arch x86_64
CXXSTD   := -std=gnu++17
OPT      := -O2 -g
WARN     := -Wall -Wextra -Wno-unused-parameter -Wno-unused-variable \
            -Wno-objc-missing-super-calls -Wno-incomplete-implementation \
            -Wno-objc-designated-initializers

OBJC_FLAGS := -fobjc-arc -fobjc-weak
DEFINES    := -DDEBUG=1

FRAMEWORK_SEARCH := -F"$(SDK_ROOT)"

# 実行時 rpath: dyld が @rpath/... を SDK_ROOT から解決するように焼き込む。
# 開発中は SDK_ROOT のマウントパスをそのまま使う。Wave 6 の .app 化で
# @executable_path/../Frameworks 相当に付け替える。
RPATH := -Wl,-rpath,"$(SDK_ROOT)"

# ---- Frameworks (Wave 1 で使う分だけ) -----------------------------------

# System
SYS_FRAMEWORKS := \
    -framework Foundation \
    -framework AppKit \
    -framework ImageCaptureCore \
    -framework CoreFoundation

# SIGMA SDK (Wave 1)
SDK_FRAMEWORKS := \
    -framework SharedPTP \
    -framework ConfigAPI \
    -framework GetCamStatus2 \
    -framework GetCamDataGroup2 \
    -framework SetCamDataGroup2 \
    -framework SnapCommand \
    -framework GetCamCaptStatus \
    -framework ClearImageDBSingle \
    -framework GetPictFileInfo2 \
    -framework GetBigPartialPictFile \
    -framework CloseApplication

# ---- Rules --------------------------------------------------------------

.PHONY: all clean run check-sdk app

all: check-sdk $(TARGET) app

APP_BUNDLE := $(BUILD_DIR)/SigmaTetherHelper.app

# .app バンドルを組み立てる。Info.plist の SGM_* 4 キー (DEBUG/COMLOG/LOGPATH/TIMEOUT)
# を持たせないと SDK が内部初期化に失敗するため、CLI 直実行ではなく .app 経由で
# 起動するのが正しいフロー。
app: $(TARGET)
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@cp $(TARGET) $(APP_BUNDLE)/Contents/MacOS/SigmaTetherHelper
	@cp Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@codesign --force --sign - $(APP_BUNDLE) 2>&1 | sed 's/^/[sign] /'
	@echo "[ok ] built: $(APP_BUNDLE)"
	@echo "[run] $(APP_BUNDLE)/Contents/MacOS/SigmaTetherHelper で起動"

check-sdk:
	@if [ ! -d "$(SDK_ROOT)" ]; then \
		echo "[ERR] SDK not found: $(SDK_ROOT)"; \
		echo "      SIGMA Camera Control SDK for Mac をマウントするか、"; \
		echo "      make SDK_ROOT=/path/to/SDK で場所を指定してください。"; \
		exit 1; \
	fi
	@echo "[ok ] SDK found at $(SDK_ROOT)"

$(BUILD_DIR)/%.o: $(SRC_DIR)/%.mm | $(BUILD_DIR)
	@echo "[cc ] $<"
	@$(CXX) $(ARCH) $(CXXSTD) $(OPT) $(WARN) $(OBJC_FLAGS) $(DEFINES) \
	    $(FRAMEWORK_SEARCH) \
	    -I$(SRC_DIR) \
	    -c $< -o $@

$(TARGET): $(OBJECTS) | $(BUILD_DIR)
	@echo "[ld ] $@"
	@$(CXX) $(ARCH) $(OPT) $(OBJECTS) \
	    $(FRAMEWORK_SEARCH) $(RPATH) \
	    $(SYS_FRAMEWORKS) $(SDK_FRAMEWORKS) \
	    -o $@
	@echo "[ok ] built: $@"
	@file $@ | sed 's/^/[     ] /'

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

run: app
	@echo "[run] $(APP_BUNDLE)/Contents/MacOS/SigmaTetherHelper (Rosetta 2)"
	@$(APP_BUNDLE)/Contents/MacOS/SigmaTetherHelper

clean:
	@rm -rf $(BUILD_DIR)
	@echo "[clean] $(BUILD_DIR) を削除"
