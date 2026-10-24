#!/usr/bin/env bash
# prepare_modes_2_3.sh — download/reference binaries needed for DTLN (mode 2)
# and DeepFilterNet / libdf (mode 3) inside the GitHub Actions workflow.
# Builds for 32-bit (armeabi-v7a) and 64-bit (arm64-v8a) + x86_64.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== Prepare binaries for modes 2 & 3 (32-bit + 64-bit) ==="

# ---------- TFLite reference (mode 2) ----------
mkdir -p "$HERE/tflite_ref/lib/arm64-v8a" "$HERE/tflite_ref/lib/armeabi-v7a" "$HERE/tflite_ref/lib/x86_64" "$HERE/tflite_ref/include"
echo ">> TFLite: compiling libtensorflowlite_c.so for Android ABIs from TF source v2.22.0-rc0 ..."
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

# Build libtensorflowlite_c.so for each Android ABI using Bazel with NDK target
# Each ABI gets its own .so; CMake will pick the one matching ANDROID_ABI
for ABI in arm64-v8a armeabi-v7a x86_64; do
  echo ">> Building libtensorflowlite_c.so for Android ABI $ABI (Bazel + NDK target) ..."
  cd /tmp/tensorflow_src
  BAZEL_CMD=$(command -v bazel 2>/dev/null || echo "/usr/local/bin/bazelisk")
  # --cpu selects the architecture target; --config=monolithic keeps the C API library intact
  # We run one build per ABI so each .so is a native Android binary (not Linux host x86_64)
  case $ABI in
    "arm64-v8a") CPU="aarch64" ;;
    "armeabi-v7a") CPU="armeabi-v7a" ;;
    "x86_64") CPU="x86_64" ;;
  esac
  # Note: --config=monolithic is kept; Bazel builds the .so for the specified --cpu.
  # The output .so lands in bazel-bin/tensorflow/lite/c/libtensorflowlite_c.so for that target.
  $BAZEL_CMD build -c opt --config=monolithic --cpu="$CPU" //tensorflow/lite/c:libtensorflowlite_c.so 2>&1 | tail -n20 || echo ">> Bazel build for $ABI completed (check output)"

  BUILT_SO=$(find -L /tmp/tensorflow_src/bazel-bin -maxdepth 6 -name "libtensorflowlite_c.so" | head -n1)
  # Because Bazel may keep the same output path across runs, we verify the file exists and stage per ABI
  if [ -f "$BUILT_SO" ]; then
    cp -f "$BUILT_SO" "$HERE/tflite_ref/lib/$ABI/libtensorflowlite_c.so"
    echo ">> libtensorflowlite_c.so ($ABI) built with Bazel and staged ($(du -h "$BUILT_SO" | cut -f1))"
  else
    echo ">> WARNING: libtensorflowlite_c.so not found after bazel build for $ABI; checking bazel-bin ..."
    ls -la /tmp/tensorflow_src/bazel-bin/tensorflow/lite/c/ 2>/dev/null || echo "    (directory missing)"
    # Non-fatal for now; build proceeds so other ABIs can complete
  fi
done

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
echo ">> DeepFilterNet (mode 3): ensuring cargo-c and cbindgen ..."
if ! command -v cargo-cinstall >/dev/null 2>&1; then
  cargo install cargo-c || { echo "ERROR: cargo-c install failed"; exit 1; }
fi
if ! command -v cbindgen >/dev/null 2>&1; then
  cargo install cbindgen || { echo "ERROR: cbindgen install failed"; exit 1; }
fi

if [ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "$ANDROID_NDK_HOME" ]; then
  echo ">> Building libdf for ARM 32-bit and 64-bit (+ x86_64) ..."
  bash "$HERE/scripts/build_df.sh" 2>&1 || { echo "ERROR: build_df.sh failed"; exit 1; }

  # Generate C header using upstream cbindgen.toml
  echo ">> Generating C header for libdf (CAPI) ..."
  if [ -f "$HERE/cbindgen.toml" ]; then
    # Desde models/df/libDF, el archivo de config está en ../../../cbindgen.toml (raíz del proyecto)
    (cd "$HERE/models/df/libDF" && cbindgen --config ../../../cbindgen.toml --crate deep_filter --output deep_filter.h || echo "WARNING: cbindgen header generation skipped (non-fatal)")
  else
    echo "WARNING: cbindgen.toml not found at $HERE/cbindgen.toml; header generation skipped"
  fi
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
# Verificamos que existan los 3 .so de Android (uno por ABI)
for abi in arm64-v8a armeabi-v7a x86_64; do
  [ -f "$HERE/tflite_ref/lib/$abi/libtensorflowlite_c.so" ] || { echo "ERROR: tflite_ref/lib/$abi/libtensorflowlite_c.so missing"; exit 1; }
done
[ -f "$HERE/tflite_ref/include/c_api.h" ] || { echo "ERROR: tflite_ref/include/c_api.h missing"; exit 1; }

echo ">> All binaries for modes 2 & 3 (32-bit + 64-bit + x86_64) are present."
exit 0
