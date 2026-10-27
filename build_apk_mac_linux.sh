#!/usr/bin/env bash
set -e

echo "============================================================================"
echo "  木木笔记 2.6.2（手写与防误触整合版） 一键打包脚本"
echo "  已内置：--split-per-abi 分包减重 + 国内镜像加速 + R8 混淆规则保护"
echo "============================================================================"

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8
export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"

if ! command -v flutter &> /dev/null; then
    echo "[错误] 未检测到 Flutter SDK，请先安装 Flutter 并加入 PATH。"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 清理可能残留的 Kotlin 编译器日志目录
rm -rf "$SCRIPT_DIR/app/android/.kotlin"

echo "[1/3] 正在拉取 packages/onenote_parser、api 与 app 模块依赖..."
cd "$SCRIPT_DIR/packages/onenote_parser"
flutter pub get
cd "$SCRIPT_DIR/api"
flutter pub get
cd "$SCRIPT_DIR/app"
flutter pub get

echo "[2/3] 正在按 ABI 架构拆分编译生产环境 APK (--split-per-abi 缩减体积 45%~55%)..."
flutter build apk --release --flavor production --split-per-abi

ARM64_APK="$SCRIPT_DIR/app/build/app/outputs/flutter-apk/app-arm64-v8a-production-release.apk"
ARM32_APK="$SCRIPT_DIR/app/build/app/outputs/flutter-apk/app-armeabi-v7a-production-release.apk"
X86_64_APK="$SCRIPT_DIR/app/build/app/outputs/flutter-apk/app-x86_64-production-release.apk"
UNIV_APK="$SCRIPT_DIR/app/build/app/outputs/flutter-apk/app-production-release.apk"

if [ -f "$ARM64_APK" ]; then
    cp "$ARM64_APK" "$SCRIPT_DIR/Mumu-Notes-arm64-v8a-release.apk"
    cp "$ARM64_APK" "$SCRIPT_DIR/Mumu-Notes-release.apk"
    if [ -f "$ARM32_APK" ]; then
        cp "$ARM32_APK" "$SCRIPT_DIR/Mumu-Notes-armeabi-v7a-release.apk"
    fi
    if [ -f "$X86_64_APK" ]; then
        cp "$X86_64_APK" "$SCRIPT_DIR/Mumu-Notes-x86_64-release.apk"
    fi
    echo "[3/3] 打包成功！已生成按 ABI 拆分的精简 APK："
    echo "      平板主力包 (arm64-v8a): $SCRIPT_DIR/Mumu-Notes-arm64-v8a-release.apk"
    echo "      默认快捷包 (同 arm64) : $SCRIPT_DIR/Mumu-Notes-release.apk"
    echo "      安装命令：adb install -r -d \"$SCRIPT_DIR/Mumu-Notes-arm64-v8a-release.apk\""
elif [ -f "$UNIV_APK" ]; then
    cp "$UNIV_APK" "$SCRIPT_DIR/Mumu-Notes-release.apk"
    echo "[3/3] 打包成功！安装包已生成至：$SCRIPT_DIR/Mumu-Notes-release.apk"
else
    echo "[错误] 未找到生成的 APK，请检查编译日志。"
    exit 1
fi
