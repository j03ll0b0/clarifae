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

# Fallback / extra attempts for .so (public sources are unreliable; fail clearly)
if [ ! -f "$HERE/tflite_ref/lib/libtensorflowlite_c.so" ]; then
  echo ">> Attempting additional .so sources ..."
  EXTRA_SO_URLS=(
    "https://github.com/ValYouW/tflite-dist/releases/download/latest/libtensorflowlite_c.so"
    "https://github.com/google-ai-edge/litert/releases/download/v2.16.1/libtensorflowlite_c.so"
    "https://github.com/tphakala/tflite_c/releases/download/v2.16.1/libtensorflowlite_c.so"
  )
  for url in "${EXTRA_SO_URLS[@]}"; do
    if curl -fL --retry 2 -o /tmp/libtensorflowlite_c.so "$url" 2>/dev/null && [ -s /tmp/libtensorflowlite_c.so ]; then
      cp /tmp/libtensorflowlite_c.so "$HERE/tflite_ref/lib/libtensorflowlite_c.so"
      echo ">> libtensorflowlite_c.so staged from $url"
      break
    else
      echo ">> $url unavailable or empty"
    fi
  done
fi

if [ -f "$HERE/tflite_ref/lib/libtensorflowlite_c.so" ]; then
  echo ">> libtensorflowlite_c.so present ($(du -h "$HERE/tflite_ref/lib/libtensorflowlite_c.so" | cut -f1))"
else
  echo ">> libtensorflowlite_c.so NOT AVAILABLE in any public source (AAR and releases)."
  echo ">> ACTION REQUIRED: place the file manually at:"
  echo "    $HERE/tflite_ref/lib/libtensorflowlite_c.so"
  echo ">> You can build/download it from: https://github.com/tensorflow/tensorflow/releases"
  echo ">> or from https://github.com/tphakala/tflite_c/releases (manual selection)"
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
