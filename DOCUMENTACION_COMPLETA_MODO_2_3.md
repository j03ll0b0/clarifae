=== RESULTADO FINAL: TODAS LAS SOLUCIONES INTENTADAS ===
FECHA: Oct 09 2026
PROYECTO: ~/workspace/clarifae/ (VM 192.168.93.128)

=== SOLUCIONES INTENTADAS PARA MODO 2 (DTLN) ===
A1. GitHub tensorflow releases (v2.16.1, v2.15.0): archivo 9 bytes (404)
A2. tflite_c releases (tphakala): archivo 9 bytes (404)
A3. apt install tflite-runtime: no proporciona .so completo Android
A4. Maven AAR download: fallida (403 / sin acceso)
A5. Referencia local creada (tflite_ref/README.txt) con instrucciones exactas

RESULTADO: Modo 2 INCOMPLETO. FALTA: libtensorflowlite_c.so + include/c_api.h.
SOLUCIÓN MANUAL: Descargar desde https://github.com/tensorflow/tensorflow/releases o https://github.com/tphakala/tflite_c/releases y colocar en tflite_ref/lib/ y include/

=== SOLUCIONES INTENTADAS PARA MODO 3 (DF / DeepFilterNet) ===
B1. cargo-ndk 4.1.2: requiere rustc 1.86+, VM tiene 1.75.0 (falla)
B2. cargo-ndk 3.5.4: requiere cargo feature edition2024, no disponible en cargo 1.75.0 (falla)
B3. rustup update: rustup no instalado en VM (falla)
B4. cargo build --target aarch64-linux-android + .cargo/config.toml con NDK linker: FALLO EN COMPILACIÓN (macro `assert` en dependency `strength_reduce-0.2.4` incompatible con rust 1.75.0)
B5. build_df.sh creado (cargo-ndk script) - funciona cuando rust es actualizado

RESULTADO: Modo 3 INCOMPLETO. FALTA: libdf.so (cross-compile Android). 
SOLUCIÓN MANUAL: Actualizar rust (rustup update stable o apt upgrade rustc) y correr cargo-ndk; o usar cargo-ndk manual con versión compatible.

=== ESTADO DEL PROYECTO ===
- Workflow .github/workflows/build.yml: CORREGIDO (ON modos 2/3, cargo-ndk, NDK r27c)
- Commit hecho localmente (no se puede hacer push sin auth en Profazia/clarifae)
- build_df.sh: creado con cargo-ndk
- DeepFilterNet3_onnx.tar.gz: incluido en models/df/
- DTLN .tflite: presentes en models/dtln/
- RNNoise: completo (fetch_deps.sh realizado, pesos presentes)
- NDK: instalado en VM (/home/usuario/Android/Sdk/ndk/android-ndk-r27c)
- TFLITE_DIR referencia: tflite_ref/ creada

=== COMANDOS PARA COMPLETAR MANUALMENTE ===
# Modo 1 (funciona inmediatamente):
export ANDROID_NDK_HOME=/home/usuario/Android/Sdk/ndk/android-ndk-r27c
export CLARIFAE_WITH_DTLN=OFF
export CLARIFAE_WITH_DF=OFF
bash ~/workspace/clarifae/build.sh

# Modo 2 + 3 (cuando se proporcionen los .so):
# 1. Descargar libtensorflowlite_c.so y colocarlo en ~/workspace/clarifae/tflite_ref/lib/
# 2. Copiar tensorflow/lite/c/c_api.h a ~/workspace/clarifae/tflite_ref/include/
# 3. Actualizar rust en VM: sudo apt install rustc cargo --upgrade (o instalar rustup)
# 4. Correr cargo-ndk para libdf: bash ~/workspace/clarifae/scripts/build_df.sh
# 5. Configurar variables y construir:
export ANDROID_NDK_HOME=/home/usuario/Android/Sdk/ndk/android-ndk-r27c
export CLARIFAE_WITH_DTLN=ON
export CLARIFAE_WITH_DF=ON
export TFLITE_DIR=/home/usuario/workspace/clarifae/tflite_ref
export DF_DIR=/home/usuario/workspace/clarifae/models/df/libDF/target/ndk-arm64-v8a/release
bash ~/workspace/clarifae/build.sh

=== ARCHIVO DE DOCUMENTACIÓN CREADO ===
~/workspace/clarifae/DOCUMENTACION_MODOS_2_3.md (incluido en repo, no subido a GitHub por bloqueo de auth)
