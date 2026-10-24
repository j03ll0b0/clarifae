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
mkdir -p "$HERE/tflite_ref/lib/arm64-v8a" "$HERE/tflite_ref/lib/armeabi-v7a" "$HERE/tflite_ref/lib/x86_64" "$HERE/tflite_ref/include"
echo ">> TFLite: compiling libtensorflowlite_c.so for Android ABIs from TF source v2.22.0-rc0 (Bazel + NDK config) ..."
TF_BRANCH="v2.22.0-rc0"
if ! git ls-remote --tags https://github.com/tensorflow/tensorflow.git "refs/tags/$TF_BRANCH" 2>/dev/null | grep -q "$TF_BRANCH"; then
  echo ">> Tag $TF_BRANCH not found; falling back to main ..."
  TF_BRANCH="main"
fi

# Clonar TF source (necesario para configure.py y c_api.h)
rm -rf /tmp/tensorflow_src
git clone --depth 1 --branch "$TF_BRANCH" https://github.com/tensorflow/tensorflow.git /tmp/tensorflow_src 2>/dev/null || git clone --depth 1 https://github.com/tensorflow/tensorflow.git /tmp/tensorflow_src || { echo "ERROR: tensorflow clone failed"; exit 1; }

# Configurar TensorFlow inyectando el NDK (configura .bazelrc con Android toolchains)
export PYTHON_BIN_PATH=$(which python3)
export USE_DEFAULT_PYTHON_LIB_PATH=1
if [ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "$ANDROID_NDK_HOME" ]; then
  echo ">> Configuring TensorFlow for Android (NDK: $ANDROID_NDK_HOME) ..."
  cd /tmp/tensorflow_src
  # Automático: rechaza opciones no necesarias, confirma NDK
  # Configurar automáticamente (archivo de respuestas temporal)
  RESP="/tmp/tf_config_resp_$$"
  printf 'n\nn\nn\nn\ny\n%s\n/usr/local/lib/android/sdk\n26\n34\n36.0.0\n' "$ANDROID_NDK_HOME" > "$RESP"
  PYTHON_BIN_PATH=$(which python3) USE_DEFAULT_PYTHON_LIB_PATH=1 python3 configure.py < "$RESP" 2>/dev/null || { echo "WARNING: configure.py falló (puede ser normal en CI)"; }
fi

# Instalar bazelisk si bazel no está presente (requerido para Bazel build)
if ! command -v bazel >/dev/null 2>&1; then
  echo ">> Installing bazelisk ..."
  wget -q -O /tmp/bazelisk https://github.com/bazelbuild/bazelisk/releases/download/v1.25.0/bazelisk-linux-amd64 || echo "bazelisk download skipped"
  chmod +x /tmp/bazelisk || true
  sudo mv /tmp/bazelisk /usr/local/bin/bazelisk 2>/dev/null || { echo "WARNING: could not install bazelisk"; }
  sudo ln -sf /usr/local/bin/bazelisk /usr/local/bin/bazel 2>/dev/null || true
fi

# Compilar libtensorflowlite_c.so para cada ABI de Android con Bazel + config oficial
for ABI in arm64-v8a armeabi-v7a x86_64; do
  echo ">> Compilando libtensorflowlite_c.so para Android ABI $ABI (Bazel + Android Config) ..."
  case $ABI in
    "arm64-v8a") BAZEL_ANDROID_CONFIG="--config=android_arm64" ;;
    "armeabi-v7a") BAZEL_ANDROID_CONFIG="--config=android_arm" ;;
    "x86_64") BAZEL_ANDROID_CONFIG="--config=android_x86_64" ;;
  esac

  cd /tmp/tensorflow_src
  BAZEL_CMD=$(command -v bazel 2>/dev/null || echo "/usr/local/bin/bazelisk")
  # --config=monolithic mantiene la librería C API completa; $BAZEL_ANDROID_CONFIG activa el NDK
  $BAZEL_CMD build -c opt --config=monolithic $BAZEL_ANDROID_CONFIG //tensorflow/lite/c:libtensorflowlite_c.so 2>&1 | tail -n20 || echo ">> Bazel build para $ABI completado (revisar salida)"

  # Localizar y estagear el .so resultante en la carpeta del ABI
  BUILT_SO=$(find -L /tmp/tensorflow_src/bazel-bin -maxdepth 6 -name "libtensorflowlite_c.so" | head -n1)
  if [ -f "$BUILT_SO" ]; then
    mkdir -p "$HERE/tflite_ref/lib/$ABI"
    cp -f "$BUILT_SO" "$HERE/tflite_ref/lib/$ABI/libtensorflowlite_c.so"
    echo ">> libtensorflowlite_c.so ($ABI) compilado con éxito y estaged ($(du -h "$BUILT_SO" | cut -f1))"
  else
    echo "ERROR: libtensorflowlite_c.so no encontrado para el ABI $ABI"
    exit 1
  fi
done

# c_api.h: extraer del repo clonado (coincide con v2.22.0-rc0)
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
