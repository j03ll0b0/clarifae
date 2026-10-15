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
echo ">> TFLite: downloading AAR for headers + attempting .so reference ..."
# Try newest AAR first, then fall back to verified 2.16.1
AAR_URLS=(
  "https://repo1.maven.org/maven2/org/tensorflow/tensorflow-lite/2.17.0/tensorflow-lite-2.17.0.aar"
  "https://repo1.maven.org/maven2/org/tensorflow/tensorflow-lite/2.16.1/tensorflow-lite-2.16.1.aar"
  "https://repo1.maven.org/maven2/org/tensorflow/tensorflow-lite/2.15.0/tensorflow-lite-2.15.0.aar"
)
AAR_OK=0
AAR_URL=""
for url in "${AAR_URLS[@]}"; do
  echo ">> Trying AAR: $url"
  if curl -fL --retry 2 -o /tmp/tensorflow-lite.aar "$url" 2>/dev/null && [ -s /tmp/tensorflow-lite.aar ]; then
    AAR_OK=1
    AAR_URL="$url"
    echo ">> AAR downloaded ($(stat -c%s /tmp/tensorflow-lite.aar) bytes) from $url"
    break
  else
    echo ">> AAR $url not available or empty"
  fi
done

# Extract c_api.h from AAR (always available)
if [ "$AAR_OK" -eq 1 ]; then
  echo ">> Unzipping AAR for headers ..."
  mkdir -p /tmp/aar_extract
  rm -rf /tmp/aar_extract/*
  unzip -o -q /tmp/tensorflow-lite.aar -d /tmp/aar_extract/ || true
  if [ -f /tmp/aar_extract/headers/tensorflow/lite/c/c_api.h ]; then
    cp /tmp/aar_extract/headers/tensorflow/lite/c/c_api.h "$HERE/tflite_ref/include/c_api.h"
    echo ">> c_api.h staged from AAR"
  fi
  # Try .so from AAR (most versions don't include libtensorflowlite_c.so, but check anyway)
  for abi_dir in arm64-v8a armeabi-v7a; do
    AAR_SO="/tmp/aar_extract/jni/$abi_dir/libtensorflowlite_c.so"
    if [ -f "$AAR_SO" ]; then
      cp "$AAR_SO" "$HERE/tflite_ref/lib/libtensorflowlite_c.so"
      echo ">> libtensorflowlite_c.so staged from AAR ($abi_dir)"
    fi
  done
fi

# ---------- Build libtensorflowlite_c.so via CMake (most reliable) ----------
if [ ! -f "$HERE/tflite_ref/lib/libtensorflowlite_c.so" ]; then
  echo ">> Building libtensorflowlite_c.so from TensorFlow source (CMake method) ..."
  # Clone latest/stable tag shallow to save time; fall back to main
  TF_BRANCH="v2.16.1"
  if ! git ls-remote --tags https://github.com/tensorflow/tensorflow.git "refs/tags/$TF_BRANCH" 2>/dev/null | grep -q "$TF_BRANCH"; then
    TF_BRANCH="main"
  fi
  echo ">> Cloning tensorflow source (branch $TF_BRANCH) ..."
  rm -rf /tmp/tensorflow_src
  git clone --depth 1 --branch "$TF_BRANCH" https://github.com/tensorflow/tensorflow.git /tmp/tensorflow_src 2>/dev/null || git clone --depth 1 https://github.com/tensorflow/tensorflow.git /tmp/tensorflow_src || { echo "ERROR: tensorflow clone failed"; exit 1; }
  echo ">> Compiling with CMake ..."
  rm -rf /tmp/tflite_c_build
  mkdir -p /tmp/tflite_c_build
  cmake -S /tmp/tensorflow_src/tensorflow/lite/c -B /tmp/tflite_c_build -DCMAKE_BUILD_TYPE=Release 2>&1 | tail -n10 || { echo "ERROR: cmake configure failed"; exit 1; }
  cmake --build /tmp/tflite_c_build -j$(nproc) 2>&1 | tail -n10 || { echo "ERROR: cmake build failed"; exit 1; }
  if [ -f /tmp/tflite_c_build/libtensorflowlite_c.so ]; then
    cp /tmp/tflite_c_build/libtensorflowlite_c.so "$HERE/tflite_ref/lib/libtensorflowlite_c.so"
    echo ">> libtensorflowlite_c.so built from source and staged"
  else
    echo ">> Note: .so not produced by cmake (checking alternate paths)"
    find /tmp/tflite_c_build -name "libtensorflowlite_c.so" -exec cp {} "$HERE/tflite_ref/lib/libtensorflowlite_c.so" \; 2>/dev/null || { echo "ERROR: libtensorflowlite_c.so not found after cmake build"; exit 1; }
  fi
fi

if [ -f "$HERE/tflite_ref/lib/libtensorflowlite_c.so" ]; then
  echo ">> libtensorflowlite_c.so present ($(du -h "$HERE/tflite_ref/lib/libtensorflowlite_c.so" | cut -f1))"
else
  echo ">> libtensorflowlite_c.so MISSING after AAR + CMake build."
  echo ">> ACTION REQUIRED: place the file manually at:"
  echo "    $HERE/tflite_ref/lib/libtensorflowlite_c.so"
  echo ">> Source: https://github.com/tensorflow/tensorflow/releases (select Linux/Android .so)"
  exit 1
fi

if [ -f /tmp/aar_extract/include/c_api.h ]; then
  cp /tmp/aar_extract/include/c_api.h "$HERE/tflite_ref/include/c_api.h"
  echo ">> c_api.h staged from AAR"
fi

C_API_URLS=(
  "https://raw.githubusercontent.com/tensorflow/tensorflow/main/tensorflow/lite/c/c_api.h"
  "https://github.com/tphakala/tflite_c/raw/main/c_api.h"
)
if [ ! -f "$HERE/tflite_ref/include/c_api.h" ]; then
  for url in "${C_API_URLS[@]}"; do
    echo ">> Trying c_api.h from $url"
    if curl -fL --retry 2 -o /tmp/c_api.h "$url" 2>/dev/null; then
      if [ -s /tmp/c_api.h ]; then
        cp /tmp/c_api.h "$HERE/tflite_ref/include/c_api.h"
        echo "  -> c_api.h staged"
        break 2
      else
        echo "  -> empty file from $url"
      fi
    else
      echo "  -> fetch failed for $url"
    fi
  done
  [ -f "$HERE/tflite_ref/include/c_api.h" ] || { echo "ERROR: c_api.h could not be fetched"; exit 1; }
fi

# ---------- DeepFilterNet libdf (mode 3) ----------
echo ">> DeepFilterNet (mode 3): installing cargo-ndk ..."
cargo install cargo-ndk 2>&1 | tail -n3 || cargo install cargo-ndk@3.5.4 2>&1 | tail -n3 || echo "  !! cargo-ndk install attempted (may need newer rust)"

if [ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "$ANDROID_NDK_HOME" ]; then
  echo ">> Building libdf for ARM 32-bit and 64-bit (+ x86_64) ..."
  bash "$HERE/scripts/build_df.sh" 2>&1 || { echo "ERROR: build_df.sh failed"; exit 1; }
else
  echo "ERROR: ANDROID_NDK_HOME not set or missing; cannot build libdf"; exit 1
fi

# Verify artifacts for both architectures
for abi in arm64-v8a armeabi-v7a x86_64; do
  echo ">> Checking ABI $abi ..."
  ls -la "$HERE/lib/$abi/libclarifae.so" 2>/dev/null || echo "  (libclarifae.so for $abi will be built by build.sh)"
done

echo ">> Verifying libdf.so exists for all ABIs ..."
for abi in arm64-v8a armeabi-v7a x86_64; do
  SO_FILE="$HERE/models/df/libDF/target/ndk-$abi/release/libdf.so"
  if [ -f "$SO_FILE" ]; then
    echo ">> $abi: libdf.so present ($(du -h "$SO_FILE" | cut -f1))"
  else
    echo "ERROR: $SO_FILE missing — cargo-ndk build did not complete for $abi"
    exit 1
  fi
done

echo ">> Verify TFLite reference ..."
[ -f "$HERE/tflite_ref/lib/libtensorflowlite_c.so" ] || { echo "ERROR: tflite_ref/lib/libtensorflowlite_c.so missing"; exit 1; }
[ -f "$HERE/tflite_ref/include/c_api.h" ] || { echo "ERROR: tflite_ref/include/c_api.h missing"; exit 1; }

echo ">> All binaries for modes 2 & 3 (32-bit + 64-bit + x86_64) are present."
exit 0
