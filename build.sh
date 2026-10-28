#!/usr/bin/env bash
# build.sh — cross-compile libclarifae.so for each Android ABI with the NDK and
# stage it into lib/<abi>/ and system/lib(64)/soundfx/ ready for packaging.
#
#   ABIS="arm64-v8a armeabi-v7a x86_64" ./build.sh
#   CLARIFAE_WITH_DTLN=ON TFLITE_DIR=/path/to/tflite ./build.sh   # optional
#   CLARIFAE_WITH_DF=ON   DF_DIR=/path/to/libdf       ./build.sh   # optional
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NATIVE="$HERE/native"

# --- locate NDK ---
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
if [ -z "$NDK" ]; then
  for base in "$HOME/Android/Sdk/ndk" "$HOME/Library/Android/sdk/ndk" "/opt/android-sdk/ndk"; do
    if [ -d "$base" ]; then
      NDK="$base/$(ls "$base" | sort -V | tail -n1)"
      break
    fi
  done
fi
[ -n "$NDK" ] && [ -d "$NDK" ] || { echo "ERROR: Android NDK not found. Set ANDROID_NDK_HOME."; exit 1; }
echo ">> NDK: $NDK"

TOOLCHAIN="$NDK/build/cmake/android.toolchain.cmake"
[ -f "$TOOLCHAIN" ] || { echo "ERROR: toolchain not found: $TOOLCHAIN"; exit 1; }

# --- ensure RNNoise is present ---
if [ ! -f "$NATIVE/third_party/rnnoise/include/rnnoise.h" ]; then
  echo ">> Fetching RNNoise..."
  "$HERE/scripts/fetch_deps.sh"
fi

ABIS="${ABIS:-}"
if [ -z "$ABIS" ]; then
  # Derive ABIs automatically from available .so libraries under tflite_ref/lib/
  if [ -n "${TFLITE_DIR:-}" ] && [ -d "$TFLITE_DIR/lib" ]; then
    ABIS="$(find "$TFLITE_DIR/lib" -mindepth 1 -maxdepth 1 -type f -name 'libtensorflowlite_c.so' | xargs -n1 dirname | xargs -n1 basename | sort -u | tr '\n' ' ')"
  fi
fi
ABIS="${ABIS:-arm64-v8a armeabi-v7a}"
API="${ANDROID_API:-26}"
GEN="Unix Makefiles"; JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
if command -v ninja >/dev/null 2>&1; then GEN="Ninja"; fi

# --- TFLite reference directory (modes 2 & 3) ---
TFLITE_REF_DIR="${HERE}/tflite_ref"
if [ -z "${TFLITE_DIR:-}" ]; then
  if [ -d "$TFLITE_REF_DIR" ]; then
    TFLITE_DIR="$TFLITE_REF_DIR"
  else
    echo "ERROR: TFLITE_DIR not set and $TFLITE_REF_DIR not found. Run scripts/prepare_modes_2_3.sh first."
    exit 1
  fi
fi
export TFLITE_DIR

# --- Validate .so files exist per ABI before building ---
for ABI in $ABIS; do
  SO_FILE="$TFLITE_DIR/lib/$ABI/libtensorflowlite_c.so"
  if [ ! -f "$SO_FILE" ]; then
    echo "ERROR: Required TFLite binary missing: $SO_FILE"
    echo "       Run scripts/prepare_modes_2_3.sh (or build mode 2/3 libraries) first."
    exit 1
  fi
done
echo ">> TFLITE_DIR: $TFLITE_DIR (validated for ABIs: $ABIS)"

EXTRA=()
CLARIFAE_WITH_DTLN="${CLARIFAE_WITH_DTLN:-ON}"
CLARIFAE_WITH_DF="${CLARIFAE_WITH_DF:-ON}"
[ "${CLARIFAE_WITH_DTLN}" = "ON" ] && EXTRA+=("-DCLARIFAE_WITH_DTLN=ON" "-DTFLITE_DIR=${TFLITE_DIR}")
[ "${CLARIFAE_WITH_DF}"   = "ON" ] && EXTRA+=("-DCLARIFAE_WITH_DF=ON"   "-DDF_DIR=${DF_DIR:?set DF_DIR}")

for ABI in $ABIS; do
  echo ">> Building $ABI ..."
  BUILD="$HERE/build/$ABI"
  rm -rf "$BUILD"; mkdir -p "$BUILD"
  cmake -S "$NATIVE" -B "$BUILD" -G "$GEN" \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
        -DANDROID_ABI="$ABI" \
        -DANDROID_PLATFORM="android-$API" \
        -DCMAKE_BUILD_TYPE=Release \
        -Wno-dev -Wno-author -Wno-deprecated \
        "${EXTRA[@]}"
  cmake --build "$BUILD" -j "$JOBS"

  SO="$BUILD/libclarifae.so"
  [ -f "$SO" ] || { echo "ERROR: $SO not produced"; exit 1; }
  "$NDK"/toolchains/llvm/prebuilt/*/bin/llvm-strip --strip-unneeded "$SO" 2>/dev/null || true

  # Stage per-ABI only. customize.sh installs the one matching the device into
  # system/lib(64)/soundfx at flash time (both 64-bit ABIs share lib64, so we
  # must NOT pre-stage system/ here — they would collide).
  mkdir -p "$HERE/lib/$ABI"
  cp -f "$SO" "$HERE/lib/$ABI/libclarifae.so"
  echo "   -> lib/$ABI/libclarifae.so  ($(du -h "$SO" | cut -f1))"
done

# scrub any stale pre-staged libs (the module ships per-ABI in lib/, not system/)
rm -f "$HERE"/system/lib/soundfx/libclarifae.so "$HERE"/system/lib64/soundfx/libclarifae.so 2>/dev/null

echo ">> Done. Built ABIs: $ABIS"
