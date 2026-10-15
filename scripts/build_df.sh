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

# cargo-ndk --platform expects Android API level (integer, e.g. 26), NOT ABI name or triple
for ABI in arm64-v8a armeabi-v7a x86_64; do
  echo ">> Building libdf for $ABI ..."
  cd "$LIBDF_DIR"
  cargo ndk \
    --platform 26 \
    --target-dir "target/ndk-$ABI" \
    --release \
    -- build 2>&1 | tail -n5 || { echo "! cargo-ndk build failed for $ABI (platform=26)"; exit 1; }
  echo ">> libdf (Android $ABI) -> $(pwd)/target/ndk-$ABI/release/libdf.so"
done

echo ">> Cross-compiled libdf complete. Use DF_DIR=.../target/ndk-<ABI> with build.sh."
