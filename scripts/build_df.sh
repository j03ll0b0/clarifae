#!/bin/bash
# Build DeepFilterNet libdf (C-FFI) CROSS-COMPILED for Android ABIs via cargo-ndk
# Requires: cargo-ndk installed, ANDROID_NDK_HOME set to Android NDK r27+
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NDK="${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to Android NDK r27+}"

echo ">> NDK: $NDK"
echo ">> Building libdf for Android ABIs: arm64-v8a armeabi-v7a x86_64 ..."

# cargo-ndk builds each ABI using the NDK toolchain; outputs to target/<triple>/release/
for ABI in arm64-v8a armeabi-v7a x86_64; do
  echo ">> Building libdf for $ABI ..."
  cd "$HERE/../../models/df/libDF"
  cargo ndk \
    --platform $ABI \
    --target-dir "target/ndk-$ABI" \
    --release \
    -- build 2>&1 | tail -n5 || { echo "! cargo-ndk build failed for $ABI"; exit 1; }
  # Reference output for DF_DIR in native build
  echo ">> libdf (Android $ABI) -> $(pwd)/target/ndk-$ABI/release/libdf.so"
done

echo ">> Cross-compiled libdf complete. Use DF_DIR=.../target/ndk-<ABI> with build.sh."
