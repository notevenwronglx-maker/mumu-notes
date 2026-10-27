#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"
export FLUTTER_SUPPRESS_ANALYTICS=true

echo "[1/4] Running pub get in packages/onenote_parser..."
(cd "$ROOT_DIR/packages/onenote_parser" && flutter --no-version-check pub get)

echo "[2/4] Running pub get in api..."
(cd "$ROOT_DIR/api" && flutter --no-version-check pub get)

echo "[3/4] Running pub get in app..."
(cd "$ROOT_DIR/app" && flutter --no-version-check pub get)

echo "[4/4] Building production release APK (2.6.2+7003)..."
(cd "$ROOT_DIR/app" && flutter --no-version-check build apk --release --flavor production --target-platform android-arm64 --build-name=2.6.2 --build-number=7003)

cp -f "$ROOT_DIR/app/build/app/outputs/flutter-apk/app-production-release.apk" "$ROOT_DIR/Mumu-Notes-release.apk"
echo "Done: $ROOT_DIR/Mumu-Notes-release.apk"
