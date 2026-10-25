#!/bin/bash
set -uo pipefail

HERE="$(pwd)"
BUILD_DIR_BASE="$HERE/tflite_build"

echo "=== Prepare binaries for modes 2 & 3 (32-bit + 64-bit) ==="
echo ">> TFLite: compiling libtensorflowlite_c.so for Android ABIs from TF source main..."

# Asegurar flatc en el host vía apt para que CMake lo encuentre en /usr/bin
sudo apt-get update && sudo apt-get install -y flatbuffers-compiler

# Clonar la rama main de TensorFlow
rm -rf /tmp/tensorflow_src
git clone --depth 1 --branch main https://github.com/tensorflow/tensorflow.git /tmp/tensorflow_src

# Crear directorios de destino
mkdir -p "$HERE/tflite_ref/lib/arm64-v8a" "$HERE/tflite_ref/lib/armeabi-v7a" "$HERE/tflite_ref/lib/x86_64" "$HERE/tflite_ref/include"

ABIS=("arm64-v8a" "armeabi-v7a" "x86_64")

for ABI in "${ABIS[@]}"; do
    echo ">> Compilando libtensorflowlite_c.so para Android ABI $ABI (CMake + NDK) ..."
    BUILD_DIR="$BUILD_DIR_BASE/$ABI"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"

    cmake -S /tmp/tensorflow_src/tensorflow/lite \
          -B "$BUILD_DIR" \
          -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
          -DANDROID_ABI="$ABI" \
          -DANDROID_PLATFORM=21 \
          -DCMAKE_BUILD_TYPE=Release \
          -DTFLITE_ENABLE_XNNPACK=OFF \
          -DTFLITE_HOST_TOOLS_DIR=/usr/bin

    cmake --build "$BUILD_DIR" -j$(nproc) --target tensorflow-lite

    # Buscar y copiar el .so generado
    BUILT_SO=$(find "$BUILD_DIR" \( -name "libtensorflowlite_c.so" -o -name "libtensorflowlite.so" \) | head -n1)
    if [ -n "$BUILT_SO" ]; then
        cp "$BUILT_SO" "$HERE/tflite_ref/lib/$ABI/libtensorflowlite_c.so"
        echo ">> Éxito: libtensorflowlite_c.so copiado para $ABI"
    else
        echo ">> ERROR: libtensorflowlite_c.so no encontrado para $ABI"
        exit 1
    fi
done

# Copiar cabeceras necesarias
mkdir -p "$HERE/tflite_ref/include/tensorflow/lite/c"
cp -r /tmp/tensorflow_src/tensorflow/lite/c/*.h "$HERE/tflite_ref/include/tensorflow/lite/c/" 2>/dev/null || cp -r /tmp/tensorflow_src/tensorflow/lite/c "$HERE/tflite_ref/include/"

echo ">> ¡Proceso completado con éxito para todos los ABIs!"
