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
echo ">> TFLite: only using TensorFlow source v2.22.0-rc0 for .so and c_api.h (no mixed versions) ..."
# We build .so from source; c_api.h comes from the same cloned source.
# No AAR download needed.

# ---------- Build libtensorflowlite_c.so via Bazel (Method 1) ----------
# Bazel is the primary build system for TF; produces a monolithic binary.
# It builds for Linux (x86_64) by default; CMakeLists.txt uses find_library without ABI filter.
if [ ! -f "$HERE/tflite_ref/lib/libtensorflowlite_c.so" ]; then
  echo ">> Building libtensorflowlite_c.so from TensorFlow source (Bazel, newest version v2.22.0-rc0) ..."
  TF_BRANCH="v2.22.0-rc0"
  if ! git ls-remote --tags https://github.com/tensorflow/tensorflow.git "refs/tags/$TF_BRANCH" 2>/dev/null | grep -q "$TF_BRANCH"; then
    echo ">> Tag $TF_BRANCH not found; falling back to main ..."
    TF_BRANCH="main"
  fi
  rm -rf /tmp/tensorflow_src
  git clone --depth 1 --branch "$TF_BRANCH" https://github.com/tensorflow/tensorflow.git /tmp/tensorflow_src 2>/dev/null || git clone --depth 1 https://github.com/tensorflow/tensorflow.git /tmp/tensorflow_src || { echo "ERROR: tensorflow clone failed"; exit 1; }

  # Install bazelisk if bazel is not present
  if ! command -v bazel >/dev/null 2>&1; then
    echo ">> Installing bazelisk ..."
    wget -q -O /tmp/bazelisk https://github.com/bazelbuild/bazelisk/releases/download/v1.25.0/bazelisk-linux-amd64 || echo "bazelisk download skipped"
    chmod +x /tmp/bazelisk || true
    sudo mv /tmp/bazelisk /usr/local/bin/bazelisk 2>/dev/null || { echo "WARNING: could not install bazelisk"; }
    sudo ln -sf /usr/local/bin/bazelisk /usr/local/bin/bazel 2>/dev/null || true
  fi

  echo ">> Running bazel build (monolithic) ..."
  cd /tmp/tensorflow_src
  BAZEL_CMD=$(command -v bazel 2>/dev/null || echo "/usr/local/bin/bazelisk")
  $BAZEL_CMD build -c opt --config=monolithic //tensorflow/lite/c:libtensorflowlite_c.so 2>&1 | tail -n15 || { echo "ERROR: bazel build failed"; exit 1; }
  BUILT_SO=$(find bazel-bin -maxdepth 4 -name "libtensorflowlite_c.so" | head -n1)
  if [ -f "$BUILT_SO" ]; then
    cp "$BUILT_SO" "$HERE/tflite_ref/lib/libtensorflowlite_c.so"
    echo ">> libtensorflowlite_c.so built with Bazel (monolithic) and staged ($(du -h "$BUILT_SO" | cut -f1))"
  else
    echo "ERROR: libtensorflowlite_c.so not found after bazel build"
    exit 1
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

# c_api.h must match the .so version (v2.22.0-rc0 / same source)
if [ -f /tmp/tensorflow_src/tensorflow/lite/c/c_api.h ]; then
  cp /tmp/tensorflow_src/tensorflow/lite/c/c_api.h "$HERE/tflite_ref/include/c_api.h"
  echo ">> c_api.h staged from tensorflow source ($TF_BRANCH)"
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
