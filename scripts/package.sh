#!/usr/bin/env bash
# package.sh — zip the module into a flashable dist/clarifae-<ver>.zip.
# Excludes build-only material (native sources, build dirs, host scripts).
set -euo pipefail

MOD="$(cd "$(dirname "$0")/.." && pwd)"     # project root == module root
VER="$(grep '^version=' "$MOD/module.prop" | cut -d= -f2)"
OUT="$MOD/dist/clarifae-$VER.zip"

# Warn (don't fail) if the native lib hasn't been built yet.
if ! ls "$MOD"/system/lib*/soundfx/libclarifae.so >/dev/null 2>&1 \
   && ! ls "$MOD"/lib/*/libclarifae.so >/dev/null 2>&1; then
  echo "WARNING: no libclarifae.so staged. Run ./build.sh first or the zip won't install." >&2
fi

mkdir -p "$MOD/dist"
rm -f "$OUT"

# Zip the module, excluding build-only material AND the repo docs/assets that now
# live alongside the module in the same folder.
( cd "$MOD" && zip -r9 "$OUT" . \
    -x 'native/*' \
    -x 'build/*' \
    -x 'scripts/*' \
    -x 'build.sh' \
    -x 'dist/*' \
    -x 'docs/*' \
    -x '.git/*' \
    -x '*.o' \
    -x '*.tmp*' \
    -x 'rnnoise-*.tar.gz' \
    -x 'README.md' \
    -x 'INSTALL.md' \
    -x 'realtime_audio_denoising_models.md' \
    -x 'tflite_ref/lib/*' \
    -x 'tflite_ref/lib/*/*' \
    -x 'models/df/libDF/src/*' \
    -x 'models/df/libDF/src/*/*' \
    -x 'models/df/libDF/src/*/*/*' \
    -x 'models/df/libDF/src/*/*/*/*' \
    -x 'models/df/libDF/Cargo.toml' \
    -x 'models/df/libDF/Cargo.lock' \
    -x 'models/df/libDF/.cargo/config.toml' \
    -x 'models/df/libDF/post-release.sh' \
    -x 'models/df/libDF/release.sh' \
    -x 'models/df/libDF/target/debug/*' \
    -x 'models/df/libDF/target/debug/*/*' \
    -x 'models/df/libDF/target/debug/*/*/*' \
    -x 'models/df/libDF/target/debug/*/*/*/*' \
    -x 'models/df/libDF/target/debug/*/*/*/*/*' \
    -x 'models/df/libDF/clippy.toml' \
    -x 'models/df/libDF/rustfmt.toml' \
    -x 'models/df/target/*' \
    -x 'models/df/target/*/*' \
    -x 'models/df/target/*/*/*' \
    -x 'models/df/target/*/*/*/*' \
    -x 'models/df/target/*/*/*/*/*' \
    -x 'models/df/assets/*' \
    -x 'models/df/assets/*/*' \
    -x 'models/df/demo/*' \
    -x 'models/df/demo/*/*' \
    -x 'models/df/scripts/*' \
    -x 'models/df/pyDF/*' \
    -x 'models/df/pyDF/*/*' \
    -x 'models/df/pyDF/*/*/*' \
    -x 'models/df/pyDF/*/*/*/*' \
    -x 'models/df/pyDF-data/*' \
    -x 'models/df/pyDF-data/*/*' \
    -x 'models/df/pyDF-data/*/*/*' \
    -x 'models/df/pyDF-data/*/*/*/*' \
    -x 'models/df/DeepFilterNet/*' \
    -x 'models/df/DeepFilterNet/*/*' \
    -x 'models/df/DeepFilterNet/*/*/*' \
    -i 'models/df/DeepFilterNet/LICENSE*' \
    -x 'models/df/post-release.sh' \
    -x 'models/df/release.sh' \
    -x 'models/df/clippy.toml' \
    -x 'models/df/rustfmt.toml' \
    -x 'models/df/Cargo.lock' \
    -x 'models/df/Cargo.toml' \
    -x 'models/df/README.md' \
    -x 'models/dtln/pretrained_model/*' \
    -x 'models/dtln/pretrained_model/*/*' \
    -x 'models/dtln/pretrained_model/*/*/*' \
    -x 'models/dtln/pretrained_model/*/*/*/*' \
    -x 'tflite_build/*' \
    -x 'tflite_ref/*' \
    -x 'tflite_ref/*/*' \
    -x 'tflite_ref/*/*/*' \
    -x 'tflite_ref/*/*/*/*' \
    -x 'tflite_ref/*/*/*/*/*' \
    -x '.github/*' \
    -x '.github/*/*' \
    -x '.github/*/*/*' \
    -x 'models/df/assets/*' \
    -x 'models/df/assets/*/*' \
    -x '*.DS_Store' \
    -x 'brand.txt' \
    -x 'logo.svg' >/dev/null )

echo "Created: $OUT  ($(du -h "$OUT" | cut -f1))"
echo "Contents (top level):"
unzip -l "$OUT" | awk 'NR>3 && $4 !~ /\// {print "  "$4}' | head -20
echo "  ..."
echo

# Verify critical files are present in the zip
MISSING=0
for check in common/audio_effects.clarifae.xml customize.sh service.sh module.prop webroot/index.html; do
  if ! unzip -l "$OUT" | awk 'NR>3 {print $4}' | grep -qxF "$check"; then
    echo "WARNING: $check MISSING from zip" >&2
    MISSING=1
  fi
done
# Check that at least one .so ABI is bundled (if build was run)
if ! unzip -l "$OUT" 2>/dev/null | awk 'NR>3 {print $4}' | grep -qE 'lib/(arm64-v8a|armeabi-v7a|x86_64)/libclarifae\.so'; then
  echo "WARNING: no lib/<abi>/libclarifae.so found in zip. Run ./build.sh first." >&2
  MISSING=1
fi
# Check model weights (.zip) are present
if ! unzip -l "$OUT" 2>/dev/null | awk 'NR>3 {print $4}' | grep -qE 'models/df/models/DeepFilterNet[0-9]?\.zip'; then
  echo "WARNING: DeepFilterNet model .zip files missing from models/df/models/" >&2
  MISSING=1
fi
if [ "$MISSING" -ne 0 ]; then
  echo "Package audit: MISSING critical files (see warnings above)." >&2
fi

echo "Flash $OUT in Magisk / KernelSU / APatch."
