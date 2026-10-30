#!/usr/bin/env bash
# package.sh — Staged build packager for dist/clarifae-<ver>.zip.
set -euo pipefail

MOD="$(cd "$(dirname "$0")/.." && pwd)"     # project root == module root
VER="$(grep '^version=' "$MOD/module.prop" | cut -d= -f2)"
OUT="$MOD/dist/clarifae-$VER.zip"
STAGE="$MOD/dist/stage"

echo "[*] Cleaning up old deployment targets..."
rm -rf "$MOD/dist"
mkdir -p "$STAGE"

# ============================================================================
# 1. CORE ROOT FILES
# ============================================================================
echo "[*] Copying core flash infrastructure..."
ROOT_FILES=(module.prop customize.sh service.sh post-fs-data.sh sepolicy.rule system.prop uninstall.sh)
for file in "${ROOT_FILES[@]}"; do
    [ -f "$MOD/$file" ] && cp -f "$MOD/$file" "$STAGE/"
done

[ -d "$MOD/common" ] && cp -r "$MOD/common" "$STAGE/"
[ -d "$MOD/META-INF" ] && cp -r "$MOD/META-INF" "$STAGE/"
[ -d "$MOD/webroot" ] && cp -r "$MOD/webroot" "$STAGE/"

# Copiar TFLite binaries al stage para que zip los vea dentro de STAGE
if [ -d "$MOD/tflite_ref/lib" ]; then
    mkdir -p "$STAGE/tflite_ref/lib"
    cp -r "$MOD/tflite_ref/lib/"* "$STAGE/tflite_ref/lib/"
fi

# ============================================================================
# 2. AUDIO LIBRARIES (libclarifae.so)
# ============================================================================
echo "[*] Routing primary libclarifae binary channels..."
mkdir -p "$STAGE/lib"

if [ -d "$MOD/lib" ]; then
    cp -r "$MOD/lib/"* "$STAGE/lib/"
elif [ -d "$MOD/build" ]; then
    for abi_dir in "$MOD"/build/*/; do
        [ -d "$abi_dir" ] || continue
        abi=$(basename "$abi_dir")
        for so in "$abi_dir/lib/libclarifae.so" "$abi_dir/lib/$abi/libclarifae.so"; do
            if [ -f "$so" ]; then
                mkdir -p "$STAGE/lib/$abi"
                cp -f "$so" "$STAGE/lib/$abi/libclarifae.so"
                break
            fi
        done
    done
fi

# ============================================================================
# 3. EXTRA SYSTEM SO TARGETS (DTLN & DeepFilterNet support files)
# ============================================================================
echo "[*] Handling third-party dynamic binary maps..."

if [ -d "$MOD/tflite_ref/lib" ]; then
    mkdir -p "$STAGE/tflite_ref/lib"
    cp -r "$MOD/tflite_ref/lib/"* "$STAGE/tflite_ref/lib/"
fi

mkdir -p "$STAGE/models/df/libDF"
for abi in arm64-v8a armeabi-v7a; do
    SRC_SO=""
    if [ -f "$MOD/models/df/libDF/staging-$abi/libdf.so" ]; then
        SRC_SO="$MOD/models/df/libDF/staging-$abi/libdf.so"
    elif [ -f "$MOD/models/df/libDF/target/ndk-$abi/release/libdf.so" ]; then
        SRC_SO="$MOD/models/df/libDF/target/ndk-$abi/release/libdf.so"
    fi

    if [ -n "$SRC_SO" ]; then
        mkdir -p "$STAGE/models/df/libDF/staging-$abi"
        cp -f "$SRC_SO" "$STAGE/models/df/libDF/staging-$abi/libdf.so"
    fi
done

# ============================================================================
# 4. NEURAL NETWORK MODEL WEIGHTS
# ============================================================================
echo "[*] Extracting model weight archives..."
mkdir -p "$STAGE/models/df/models"

[ -f "$MOD/models/df/DeepFilterNet/LICENSE-APACHE" ] && \
    mkdir -p "$STAGE/models/df/DeepFilterNet" && \
    cp "$MOD/models/df/DeepFilterNet/LICENSE-APACHE" "$STAGE/models/df/DeepFilterNet/"

find "$MOD/models/df/models" -maxdepth 1 -type f -name "DeepFilterNet*.zip" -exec cp -f {} "$STAGE/models/df/models/" \; || true

# ============================================================================
# 5. FINAL PACKAGING & COMPRESSION
# ============================================================================
echo "[*] Commencing clean zip build sequence..."
( cd "$STAGE" && zip -r9 "$OUT" ./* >/dev/null )

rm -rf "$STAGE"

echo "Created: $OUT ($(du -h "$OUT" | cut -f1))"
echo "Contents verification profile initialized..."
echo

MISSING=0
for check in common/audio_effects.clarifae.xml customize.sh service.sh module.prop webroot/index.html; do
  if ! unzip -l "$OUT" | awk 'NR>3 {print $4}' | grep -qxF "$check"; then
    echo "WARNING: $check MISSING from zip" >&2
    MISSING=1
  fi
done

if ! unzip -l "$OUT" 2>/dev/null | awk 'NR>3 {print $4}' | grep -qE 'lib/(arm64-v8a|armeabi-v7a)/libclarifae\.so'; then
  echo "WARNING: no lib/<abi>/libclarifae.so found in zip. Run ./build.sh first." >&2
  MISSING=1
fi

if ! unzip -l "$OUT" 2>/dev/null | awk 'NR>3 {print $4}' | grep -qE 'models/df/models/DeepFilterNet[0-9]?\.zip'; then
  echo "WARNING: DeepFilterNet model .zip files missing from models/df/models/" >&2
  MISSING=1
fi

if ! unzip -l "$OUT" 2>/dev/null | awk 'NR>3 {print $4}' | grep -qE 'tflite_ref/lib/(arm64-v8a|armeabi-v7a)/libtensorflowlite_c\.so'; then
  echo "WARNING: libtensorflowlite_c.so missing from zip (tflite_ref/lib/<abi>/). Mode 2 (DTLN) will crash at runtime." >&2
  MISSING=1
fi

if ! unzip -l "$OUT" 2>/dev/null | awk 'NR>3 {print $4}' | grep -qE 'models/df/libDF/staging-(arm64-v8a|armeabi-v7a)/libdf\.so'; then
  echo "WARNING: libdf.so missing from zip (models/df/libDF/staging-...). Mode 3 (DeepFilterNet) will fail." >&2
  MISSING=1
fi

if [ "$MISSING" -ne 0 ]; then
  echo "Package audit: MISSING critical files (see warnings above)." >&2
else
  echo "Package audit: SUCCESS. All critical AI runtime hooks verified."
fi

echo "Flash $OUT in Magisk / KernelSU / APatch."
