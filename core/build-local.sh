#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$WORKSPACE_ROOT"

LIB_NAME="libvertias_app_core"
FFI_NAME="vertias_app_coreFFI"
SWIFT_FILE="vertias_app_core"
OUT_DIR="core/build/swift"
APP_DIR="app/veritas"

echo "==> Building for macOS (arm64)..."
cargo build --release --target aarch64-apple-darwin

echo "==> Building for iOS simulator (arm64)..."
cargo build --release --target aarch64-apple-ios-sim

echo "==> Building for iOS device (arm64)..."
cargo build --release --target aarch64-apple-ios

echo "==> Generating Swift bindings..."
cargo run --bin uniffi-bindgen generate \
  --library target/aarch64-apple-darwin/release/${LIB_NAME}.a \
  --language swift \
  --out-dir ${OUT_DIR}

echo "==> Preparing headers..."
mkdir -p ${OUT_DIR}/headers
cp ${OUT_DIR}/${FFI_NAME}.h ${OUT_DIR}/headers/
cp ${OUT_DIR}/${FFI_NAME}.modulemap ${OUT_DIR}/headers/module.modulemap

echo "==> Building XCFramework..."
rm -rf ${OUT_DIR}/${FFI_NAME}.xcframework

xcodebuild -create-xcframework \
  -library target/aarch64-apple-darwin/release/${LIB_NAME}.a \
  -headers ${OUT_DIR}/headers/ \
  -library target/aarch64-apple-ios-sim/release/${LIB_NAME}.a \
  -headers ${OUT_DIR}/headers/ \
  -library target/aarch64-apple-ios/release/${LIB_NAME}.a \
  -headers ${OUT_DIR}/headers/ \
  -output ${OUT_DIR}/${FFI_NAME}.xcframework

echo "==> Copying to app..."
rm -rf "${APP_DIR}/${FFI_NAME}.xcframework"
cp -R ${OUT_DIR}/${FFI_NAME}.xcframework "${APP_DIR}/"
cp ${OUT_DIR}/${SWIFT_FILE}.swift "${APP_DIR}/"

echo ""
echo "Done! Files updated in ${APP_DIR}:"
echo "  ${FFI_NAME}.xcframework"
echo "  ${SWIFT_FILE}.swift"