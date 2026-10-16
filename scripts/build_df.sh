#!/bin/bash
# Build DeepFilterNet libdf (C-FFI) CROSS-COMPILED for Android ABIs via cargo-ndk
# Requires: cargo-ndk installed, ANDROID_NDK_HOME set to Android NDK r27+
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NDK="${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to Android NDK r27+}"

echo ">> NDK: $NDK"
echo ">> Building libdf for Android ABIs: arm64-v8a armeabi-v7a x86_64 ..."

# Find libDF directory robustly
LIBDF_DIR=""
for rel in "../../models/df/libDF" "models/df/libDF" "../models/df/libDF"; do
  if [ -d "$HERE/$rel" ]; then
    LIBDF_DIR="$HERE/$rel"
    break
  fi
  if [ -d "$PWD/$rel" ]; then
    LIBDF_DIR="$PWD/$rel"
    break
  fi
done
[ -n "$LIBDF_DIR" ] && [ -f "$LIBDF_DIR/Cargo.toml" ] || { echo "ERROR: models/df/libDF not found (looked from $HERE and $PWD)"; exit 1; }
echo ">> libDF source: $LIBDF_DIR"

# Explicit ABI -> Rust target mapping; correct cargo-ndk syntax order:
# cargo ndk --target <TRIPLE> --platform <API> build --release
for ABI in "arm64-v8a" "armeabi-v7a" "x86_64"; do
  echo ">> Building libdf for $ABI ..."

  case $ABI in
    "arm64-v8a")   TARGET="aarch64-linux-android" ;;
    "armeabi-v7a") TARGET="armv7-linux-androideabi" ;;
    "x86_64")      TARGET="x86_64-linux-android" ;;
  esac

  cd "$LIBDF_DIR"
  cargo ndk \
    --target "$TARGET" \
    --platform 26 \
    --target-dir "target/ndk-$ABI" \
    build --release 2>&1 | tail -n5 || { echo "! cargo-ndk build failed for $ABI (target=$TARGET platform=26)"; exit 1; }
  echo ">> libdf (Android $ABI / $TARGET) -> $(pwd)/target/ndk-$ABI/release/libdf.so"
done

echo ">> Cross-compiled libdf complete. Use DF_DIR=.../target/ndk-<ABI> with build.sh."
