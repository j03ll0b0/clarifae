#!/bin/bash
set -uo pipefail

# 0. CONFIGURACIÓN GLOBAL DE GIT CON PAT DE GITLAB (redactado en archivo persistente)
git config --global url."https://oauth2:[REDACTED]@gitlab.com/".insteadOf "https://gitlab.com/"

HERE="$(pwd)"
BUILD_DIR_BASE="$HERE/tflite_build"

echo "=== Prepare binaries for modes 2 & 3 (32-bit + 64-bit) ==="
echo ">> TFLite: compiling libtensorflowlite_c.so for Android ABIs from TF source v2.19.1 ..."

# 1. Clonar la versión v2.19.1 de TensorFlow (clon completo, sin --depth 1)
rm -rf /tmp/tensorflow_src
git clone --branch v2.19.1 https://github.com/tensorflow/tensorflow.git /tmp/tensorflow_src

# 2. Limpieza total del directorio de build
rm -rf "$HERE/tflite_build"
mkdir -p "$HERE/tflite_build"

# 4. Compilar flatc nativo con el subproyecto interno de TFLite
#    (tensorflow/lite/tools/cmake/native_tools/flatbuffers)
#    Se usa el flatc que trae el branch sin fijar versión externa.
echo ">> Compilando flatc nativo desde el repositorio TF ..."
rm -rf /tmp/tensorflow_src/flatc-native-build
mkdir -p /tmp/tensorflow_src/flatc-native-build
cmake -S /tmp/tensorflow_src/tensorflow/lite/tools/cmake/native_tools/flatbuffers \
      -B /tmp/tensorflow_src/flatc-native-build \
      -DCMAKE_BUILD_TYPE=Release
cmake --build /tmp/tensorflow_src/flatc-native-build -- -j$(nproc)
HOST_TOOLS_DIR="/tmp/tensorflow_src/flatc-native-build"

# PRE-DESCARGA LOCAL DE DEPENDENCIAS (Eigen + KleidiAI) — evita bloqueos de red/hash de GitLab
EIGEN_DIR="/tmp/eigen_src"
KLEIDI_DIR="/tmp/kleidiai_src"
mkdir -p "$EIGEN_DIR" "$KLEIDI_DIR"

echo ">> Descargando Eigen localmente..."
if [ ! -f /tmp/eigen.tar.gz ]; then
    curl -L -o /tmp/eigen.tar.gz https://gitlab.com/libeigen/eigen/-/archive/33d0937c6bdf5ec999939fb17f2a553183d14a74/eigen-33d0937c6bdf5ec999939fb17f2a553183d14a74.tar.gz
fi
if [ ! -f "$EIGEN_DIR/CMakeLists.txt" ]; then
    tar -xzf /tmp/eigen.tar.gz -C "$EIGEN_DIR" --strip-components=1
fi

echo ">> Descargando KleidiAI localmente..."
if [ ! -f /tmp/kleidiai.zip ]; then
    curl -L -o /tmp/kleidiai.zip -H 'PRIVATE-TOKEN: [REDACTED]' "https://gitlab.arm.com/kleidi/kleidiai/-/archive/847ebd19d0192528659b0a0fa2c6057eed674c6a/kleidiai-847ebd19d0192528659b0a0fa2c6057eed674c6a.zip"
fi
if [ ! -f "$KLEIDI_DIR/CMakeLists.txt" ] && [ -f /tmp/kleidiai.zip ]; then
    unzip -q /tmp/kleidiai.zip -d /tmp/
    mv /tmp/kleidiai-847ebd19d0192528659b0a0fa2c6057eed674c6a/* "$KLEIDI_DIR/" 2>/dev/null || cp -r /tmp/kleidiai-847ebd19d0192528659b0a0fa2c6057eed674c6a/* "$KLEIDI_DIR/"
fi

# 5. Crear directorios de destino
mkdir -p "$HERE/tflite_ref/lib/arm64-v8a" "$HERE/tflite_ref/lib/armeabi-v7a" "$HERE/tflite_ref/include"

ABIS=("arm64-v8a" "armeabi-v7a")

for ABI in "${ABIS[@]}"; do
    echo ">> Compilando libtensorflowlite_c.so para Android ABI $ABI (CMake + NDK) ..."
    BUILD_DIR="$BUILD_DIR_BASE/$ABI"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"

    cmake -S /tmp/tensorflow_src/tensorflow/lite/c \
          -B "$BUILD_DIR" \
          -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
          -DANDROID_ABI="$ABI" \
          -DANDROID_PLATFORM=21 \
          -DCMAKE_BUILD_TYPE=Release \
          -DTFLITE_ENABLE_XNNPACK=ON \
          -DTFLITE_C_BUILD_SHARED_LIBS=ON \
          -DTFLITE_HOST_TOOLS_DIR="$HOST_TOOLS_DIR" \
          -DTFLITE_ENABLE_INSTALL=OFF \
          -Wno-dev \
          -DKLEIDIAI_SOURCE_DIR="$KLEIDI_DIR" \
          -DEIGEN_BUILD_DIR="$EIGEN_DIR"

    cmake --build "$BUILD_DIR" -j$(nproc) --target tensorflowlite_c

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
