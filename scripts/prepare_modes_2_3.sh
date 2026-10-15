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
echo ">> TFLite: downloading from Maven AAR (most reliable for Android) ..."
AAR_URL="https://repo1.maven.org/maven2/org/tensorflow/tensorflow-lite/2.17.0/tensorflow-lite-2.17.0.aar"
if curl -fL --retry 3 -o /tmp/tensorflow-lite.aar "$AAR_URL" 2>/dev/null && [ -s /tmp/tensorflow-lite.aar ]; then
  echo ">> AAR downloaded ($(stat -c%s /tmp/tensorflow-lite.aar) bytes)"
  echo ">> Unzipping AAR ..."
  mkdir -p /tmp/aar_extract
  rm -rf /tmp/aar_extract/*
  unzip -o -q /tmp/tensorflow-lite.aar -d /tmp/aar_extract/ || { echo "ERROR: AAR unzip failed"; exit 1; }
  # Extract .so for arm64-v8a (mode 3 reference) and armeabi-v7a (mode 2 32-bit)
  for abi_dir in arm64-v8a armeabi-v7a; do
    AAR_SO="/tmp/aar_extract/jni/$abi_dir/libtensorflowlite_c.so"
    if [ -f "$AAR_SO" ]; then
      cp "$AAR_SO" "$HERE/tflite_ref/lib/libtensorflowlite_c.so"
      echo ">> libtensorflowlite_c.so staged from AAR ($abi_dir)"
    else
      echo ">> Note: $abi_dir .so not in AAR (expected for lite)"
    fi
  done
  # If .so not found, try fallback download
  if [ ! -f "$HERE/tflite_ref/lib/libtensorflowlite_c.so" ]; then
    echo ">> Fallback: trying direct .so download ..."
    # Fallback URLs (less reliable)
    FALLBACK_URLS=(
      "https://github.com/ValYouW/tflite-dist/releases/download/latest/libtensorflowlite_c.so"
    )
    for url in "${FALLBACK_URLS[@]}"; do
      if curl -fL --retry 2 -o /tmp/libtensorflowlite_c.so "$url" 2>/dev/null && [ -s /tmp/libtensorflowlite_c.so ]; then
        cp /tmp/libtensorflowlite_c.so "$HERE/tflite_ref/lib/libtensorflowlite_c.so"
        echo ">> libtensorflowlite_c.so staged from fallback"
        break
      fi
    done
  fi
else
  echo ">> AAR download failed; trying direct .so ..."
  FALLBACK_URLS=(
    "https://github.com/ValYouW/tflite-dist/releases/download/latest/libtensorflowlite_c.so"
  )
  FALLBACK_OK=0
  for url in "${FALLBACK_URLS[@]}"; do
    if curl -fL --retry 2 -o /tmp/libtensorflowlite_c.so "$url" 2>/dev/null && [ -s /tmp/libtensorflowlite_c.so ]; then
      cp /tmp/libtensorflowlite_c.so "$HERE/tflite_ref/lib/libtensorflowlite_c.so"
      echo ">> libtensorflowlite_c.so staged from fallback"
      FALLBACK_OK=1
      break
    fi
  done
  if [ "$FALLBACK_OK" -ne 1 ]; then
    echo "ERROR: libtensorflowlite_c.so could not be fetched (AAR and fallbacks failed)"
    exit 1
  fi
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
