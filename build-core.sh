#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Cursor/sandbox may point this at a cache; this script reads workspace target/.
unset CARGO_TARGET_DIR

LIB_NAME="libvertias_app_core"
FFI_NAME="vertias_app_coreFFI"
SWIFT_FILE="vertias_app_core"
OUT_DIR="build/swift"
APP_DIR="app/veritas"
LIPO_DIR="${OUT_DIR}/lipo"

MAC_TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
IOS_DEVICE_TARGET="aarch64-apple-ios"
IOS_SIM_TARGETS=(aarch64-apple-ios-sim x86_64-apple-ios)

echo "==> Ensuring Rust Apple targets..."
rustup target add \
  "${MAC_TARGETS[@]}" \
  "${IOS_DEVICE_TARGET}" \
  "${IOS_SIM_TARGETS[@]}"

for triple in "${MAC_TARGETS[@]}" "${IOS_DEVICE_TARGET}" "${IOS_SIM_TARGETS[@]}"; do
  echo "==> Building ${triple}..."
  cargo build --release --target "${triple}"
done

echo "==> Generating Swift bindings..."
cargo run --bin uniffi-bindgen generate \
  --library target/aarch64-apple-darwin/release/${LIB_NAME}.a \
  --language swift \
  --out-dir ${OUT_DIR}

echo "==> Preparing headers..."
mkdir -p ${OUT_DIR}/headers
cp ${OUT_DIR}/${FFI_NAME}.h ${OUT_DIR}/headers/
cp ${OUT_DIR}/${FFI_NAME}.modulemap ${OUT_DIR}/headers/module.modulemap

lipo_libs() {
  local dest="$1"
  shift
  mkdir -p "$(dirname "$dest")"
  local inputs=()
  local triple
  for triple in "$@"; do
    inputs+=("target/${triple}/release/${LIB_NAME}.a")
  done
  lipo -create "${inputs[@]}" -output "$dest"
  lipo -info "$dest"
}

echo "==> Creating universal macOS library (arm64 + x86_64)..."
lipo_libs "${LIPO_DIR}/macos/${LIB_NAME}.a" "${MAC_TARGETS[@]}"

echo "==> Creating universal iOS simulator library (arm64 + x86_64)..."
lipo_libs "${LIPO_DIR}/ios-sim/${LIB_NAME}.a" "${IOS_SIM_TARGETS[@]}"

echo "==> Building XCFramework..."
rm -rf ${OUT_DIR}/${FFI_NAME}.xcframework

xcodebuild -create-xcframework \
  -library "${LIPO_DIR}/macos/${LIB_NAME}.a" \
  -headers ${OUT_DIR}/headers/ \
  -library "target/${IOS_DEVICE_TARGET}/release/${LIB_NAME}.a" \
  -headers ${OUT_DIR}/headers/ \
  -library "${LIPO_DIR}/ios-sim/${LIB_NAME}.a" \
  -headers ${OUT_DIR}/headers/ \
  -output ${OUT_DIR}/${FFI_NAME}.xcframework

echo "==> Copying to app..."
rm -rf "${APP_DIR}/${FFI_NAME}.xcframework"
cp -R ${OUT_DIR}/${FFI_NAME}.xcframework "${APP_DIR}/"
cp ${OUT_DIR}/${SWIFT_FILE}.swift "${APP_DIR}/"

echo ""
echo "Done! Files updated in ${APP_DIR}:"
echo "  ${FFI_NAME}.xcframework"
echo "    macos-arm64_x86_64"
echo "    ios-arm64"
echo "    ios-arm64_x86_64-simulator"
echo "  ${SWIFT_FILE}.swift"
