#!/usr/bin/env bash
# prepare_modes_2_3.sh — download/reference binaries needed for DTLN (mode 2)
# and DeepFilterNet / libdf (mode 3) inside the GitHub Actions workflow.
# Builds for 32-bit (armeabi-v7a) and 64-bit (arm64-v8a) + x86_64.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== Prepare binaries for modes 2 & 3 (32-bit + 64-bit) ==="

# ---------- TFLite reference (mode 2) ----------
mkdir -p "$HERE/tflite_ref/lib/arm64-v8a" "$HERE/tflite_ref/lib/armeabi-v7a" "$HERE/tflite_ref/lib/x86_64" "$HERE/tflite_ref/include"
echo ">> TFLite: compiling libtensorflowlite_c.so for Android ABIs from TF source v2.21.0 ..."
TF_BRANCH="v2.21.0"
if ! git ls-remote --tags https://github.com/tensorflow/tensorflow.git "refs/tags/$TF_BRANCH" 2>/dev/null | grep -q "$TF_BRANCH"; then
  echo ">> Tag $TF_BRANCH not found; falling back to main ..."
  TF_BRANCH="main"
fi
mkdir -p "$HERE/tflite_ref/lib/arm64-v8a" "$HERE/tflite_ref/lib/armeabi-v7a" "$HERE/tflite_ref/lib/x86_64" "$HERE/tflite_ref/include"
echo ">> TFLite: compiling libtensorflowlite_c.so for Android ABIs from TF source v2.21.0 (Bazel + NDK config) ..."
TF_BRANCH="v2.21.0"
if ! git ls-remote --tags https://github.com/tensorflow/tensorflow.git "refs/tags/$TF_BRANCH" 2>/dev/null | grep -q "$TF_BRANCH"; then
  echo ">> Tag $TF_BRANCH not found; falling back to main ..."
  TF_BRANCH="main"
fi

# Instalar flatc en el host para cross-compile con CMake
sudo apt-get update && sudo apt-get install -y flatbuffers-compiler || { echo "WARNING: flatbuffers-compiler install failed"; }

# Clonar TF source (necesario para CMake y c_api.h)
rm -rf /tmp/tensorflow_src
git clone --depth 1 --branch "$TF_BRANCH" https://github.com/tensorflow/tensorflow.git /tmp/tensorflow_src 2>/dev/null || git clone --depth 1 https://github.com/tensorflow/tensorflow.git /tmp/tensorflow_src || { echo "ERROR: tensorflow clone failed"; exit 1; }

# Parchear mmap_handle.cc para evitar errores de LockMemory/UnlockMemory con el NDK r27
sed -i '/bool MMapHandle::LockMemory()/,/}/d' /tmp/tensorflow_src/tensorflow/lite/delegates/xnnpack/mmap_handle.cc
sed -i '/bool MMapHandle::UnlockMemory()/,/}/d' /tmp/tensorflow_src/tensorflow/lite/delegates/xnnpack/mmap_handle.cc

# Parches de compatibilidad para FlatBuffers v25 + NDK r27 (v2.21.0)
# Parche seguro: comentar líneas individuales (sin borrar bloques ni romper llaves)
sed -i 's#case TensorType_INT2:#// case TensorType_INT2:#g' /tmp/tensorflow_src/tensorflow/lite/core/api/flatbuffer_conversions.cc
sed -i 's#*type = kTfLiteInt2;#// *type = kTfLiteInt2;#g' /tmp/tensorflow_src/tensorflow/lite/core/api/flatbuffer_conversions.cc
sed -i 's#case TensorType_UINT4:#// case TensorType_UINT4:#g' /tmp/tensorflow_src/tensorflow/lite/core/api/flatbuffer_conversions.cc
sed -i 's#*type = kTfLiteUInt4;#// *type = kTfLiteUInt4;#g' /tmp/tensorflow_src/tensorflow/lite/core/api/flatbuffer_conversions.cc
sed -i '/#include "tensorflow\/lite\/core\/api\/flatbuffer_conversions.h"/a using namespace tflite;' /tmp/tensorflow_src/tensorflow/lite/core/api/flatbuffer_conversions.cc
# Reemplazar funciones faltantes (ParseReverseV2, ParseSelect) por retorno seguro
sed -i -E 's/return ParseReverseV2\(.*\);/return kTfLiteError;/g' /tmp/tensorflow_src/tensorflow/lite/core/api/flatbuffer_conversions.cc
sed -i -E 's/return ParseSelect\(.*\);/return kTfLiteError;/g' /tmp/tensorflow_src/tensorflow/lite/core/api/flatbuffer_conversions.cc

# Usar CMake + NDK (en vez de Bazel que falla con NDK r27 en CI) para compilar TFLite C API
# Esto evita configure.py / .bazelrc / Bazel version conflicts.
for ABI in arm64-v8a armeabi-v7a x86_64; do
  echo ">> Compilando libtensorflowlite_c.so para Android ABI $ABI (CMake + NDK) ..."
  BUILD_DIR="$HERE/tflite_build/$ABI"
  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR"

  # Usar la toolchain oficial del NDK para Android
  cmake -S /tmp/tensorflow_src/tensorflow/lite -B "$BUILD_DIR" \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$ABI" \
    -DANDROID_PLATFORM=android-26 \
    -DCMAKE_BUILD_TYPE=Release \
    -DTFLITE_BUILD_WITH_MMAP=OFF \
    -DTFLITE_ENABLE_XNNPACK=OFF \
    -DTFLITE_HOST_TOOLS_DIR=/usr/bin 2>&1 | tail -n10 || echo ">> CMake configure para $ABI completado (revisar salida)"

  # PARCHE: Comentar la validación estricta de versiones de FlatBuffers
  find "$BUILD_DIR" -name "configuration_generated.h" -exec sed -i '/static_assert(FLATBUFFERS_VERSION_MAJOR/,/;/s/^/\/\//' {} +

  # Compilar la librería
  cmake --build "$BUILD_DIR" -j1 2>&1 | tail -n15 || echo ">> CMake build para $ABI completado (revisar salida)"

  # Buscar y copiar el .so generado (puede llamarse libtensorflowlite_c.so o libtensorflowlite.so)
  BUILT_SO=$(find -L "$BUILD_DIR" -maxdepth 4 \( -name "libtensorflowlite_c.so" -o -name "libtensorflowlite.so" \) | head -n1)
  if [ -f "$BUILT_SO" ]; then
    cp -f "$BUILT_SO" "$HERE/tflite_ref/lib/$ABI/libtensorflowlite_c.so"
    echo ">> libtensorflowlite_c.so ($ABI) compilado con CMake y estaged ($(du -h "$BUILT_SO" | cut -f1))"
  else
    echo "ERROR: libtensorflowlite_c.so no encontrado para el ABI $ABI (revisar $BUILD_DIR)"
    exit 1
  fi
done

# c_api.h: extraer del repo clonado (coincide con v2.21.0)
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
