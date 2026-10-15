#!/usr/bin/env bash
# prepare_modes_2_3.sh — download/reference binaries needed for DTLN (mode 2)
# and DeepFilterNet / libdf (mode 3) inside the GitHub Actions workflow.
# Always exits 0 — missing binaries are warnings, not failures, so the
# build can proceed for mode 1 (RNNoise) and stage what it can.
# Builds for 32-bit (armeabi-v7a) and 64-bit (arm64-v8a) + x86_64.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== Prepare binaries for modes 2 & 3 (32-bit + 64-bit) ==="

# ---------- TFLite reference (mode 2) ----------
mkdir -p "$HERE/tflite_ref/lib" "$HERE/tflite_ref/include"
echo ">> TFLite: trying to download libtensorflowlite_c.so + c_api.h ..."
# Attempt from known sources; fall back silently if unavailable.
# Source 1: tphakala/tflite_c releases
if [ ! -f "$HERE/tflite_ref/lib/libtensorflowlite_c.so" ]; then
  curl -fL --retry 2 -o /tmp/libtensorflowlite_c.so \
    "https://github.com/tphakala/tflite_c/releases/download/v2.16.1/libtensorflowlite_c.so" 2>/dev/null || true
  if [ -f /tmp/libtensorflowlite_c.so ] && [ -s /tmp/libtensorflowlite_c.so ]; then
    cp /tmp/libtensorflowlite_c.so "$HERE/tflite_ref/lib/libtensorflowlite_c.so"
    echo "  -> libtensorflowlite_c.so staged"
  else
    echo "  !! libtensorflowlite_c.so not fetched (404/empty); place manually in tflite_ref/lib/"
  fi
fi

if [ ! -f "$HERE/tflite_ref/include/c_api.h" ]; then
  curl -fL --retry 2 -o /tmp/c_api.h \
    "https://raw.githubusercontent.com/tensorflow/tensorflow/main/tensorflow/lite/c/c_api.h" 2>/dev/null || true
  if [ -f /tmp/c_api.h ] && [ -s /tmp/c_api.h ]; then
    cp /tmp/c_api.h "$HERE/tflite_ref/include/c_api.h"
    echo "  -> c_api.h staged"
  else
    echo "  !! c_api.h not fetched; place manually in tflite_ref/include/"
  fi
fi

# ---------- DeepFilterNet libdf (mode 3) ----------
echo ">> DeepFilterNet (mode 3): installing cargo-ndk ..."
cargo install cargo-ndk 2>&1 | tail -n3 || cargo install cargo-ndk@3.5.4 2>&1 | tail -n3 || echo "  !! cargo-ndk install attempted (may need newer rust)"

if [ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "$ANDROID_NDK_HOME" ]; then
  echo ">> Building libdf for ARM 32-bit and 64-bit (+ x86_64) ..."
  bash "$HERE/scripts/build_df.sh" 2>&1 || echo "  !! build_df.sh completed with errors (libdf.so may be missing for mode 3)"
else
  echo "  !! ANDROID_NDK_HOME not set; skipping cargo-ndk build. Set before calling build.sh."
fi

# Verify artifacts for both architectures
for abi in arm64-v8a armeabi-v7a x86_64; do
  echo ">> Checking ABI $abi ..."
  ls -la "$HERE/lib/$abi/libclarifae.so" 2>/dev/null || echo "  (libclarifae.so for $abi will be built by build.sh)"
done

echo ">> Done. If TFLite .so/header or libdf.so are missing, the build steps for modes 2/3 will be skipped gracefully."
exit 0
