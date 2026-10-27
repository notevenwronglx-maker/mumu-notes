#!/usr/bin/env bash
# ==============================================================================
# 木木笔记 · Windows Git Bash 一键编译脚本（基于 Butterfly 2.6.2）
# 解决：
# 1. 自动将 D:\android-toolchain\flutter\bin 与 platform-tools 加入 PATH
# 2. 自动检测并切换 JAVA_HOME 至 JDK 17（规避系统默认 JDK 8 与 AGP 9.4.1 不兼容）
# 3. 采用绝对路径与时间戳日志 + 互斥锁文件，防止后台执行时重复启动或覆盖截断日志
# ==============================================================================
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$APP_DIR"

LOCK_FILE="$APP_DIR/.build_running.lock"
if [ -f "$LOCK_FILE" ]; then
  OLD_PID="$(cat "$LOCK_FILE" 2>/dev/null || true)"
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "❌ 检测到已有构建进程正在运行 (PID: $OLD_PID)，请勿重复启动。"
    exit 1
  fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# 1. 配置 Flutter 与 ADB 工具链 PATH
export PATH="/d/android-toolchain/flutter/bin:/d/android-toolchain/sdk/platform-tools:$PATH"

# 2. 自动检测 JDK 17 (优先使用环境变量 JDK17_HOME，否则扫描常见安装路径)
if [ -n "${JDK17_HOME:-}" ] && [ -d "$JDK17_HOME" ]; then
  export JAVA_HOME="$JDK17_HOME"
else
  for candidate in \
    "/d/android-toolchain/jdk-17"* \
    "/d/android-toolchain/jbr"* \
    "/c/Program Files/Android/Android Studio/jbr" \
    "/c/Program Files/Eclipse Adoptium/jdk-17"* \
    "/c/Program Files/Java/jdk-17"* \
    "/c/Program Files/Microsoft/jdk-17"*
  do
    if [ -d "$candidate" ] && [ -x "$candidate/bin/java" ]; then
      export JAVA_HOME="$candidate"
      break
    fi
  done
fi

export PATH="$JAVA_HOME/bin:$PATH"
echo "✅ 当前工作目录: $APP_DIR"
echo "✅ JAVA_HOME: ${JAVA_HOME:-未显式指定}"
java -version 2>&1 | head -n 2
flutter --version | head -n 1

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$APP_DIR/build_${TIMESTAMP}.log"
echo "🚀 开始构建 Release APK (日志输出至: $LOG_FILE) ..."

flutter build apk --release --flavor production --no-tree-shake-icons 2>&1 | tee "$LOG_FILE"

echo "🎉 构建完成！APK 路径: $APP_DIR/build/app/outputs/flutter-apk/app-production-release.apk"
