#!/bin/bash
# Build DeepFilterNet libdf (C-FFI / CAPI) CROSS-COMPILED for Android ABIs
# Uses upstream approach: cargo-c + nightly + .cargo/config.toml linkers
# Requires: cargo-c installed, ANDROID_NDK_HOME set, .cargo/config.toml present
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NDK="${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to Android NDK r27+}"

echo ">> NDK: $NDK"
echo ">> Building libdf (CAPI) for Android ABIs: arm64-v8a armeabi-v7a x86_64 ..."

# Find libDF directory robustly
LIBDF_DIR=""
for rel in "../../models/df/libDF" "models/df/libDF" "../models/df/libDF"; do
  if [ -d "$HERE/$rel" ]; then
    LIBDF_DIR="$HERE/$rel"
    break
  fi
  if [ -d "$PWD/$rel" ]; then
    LIBDF_DIR="$PWD/$rel"
    break
  fi
done
[ -n "$LIBDF_DIR" ] && [ -f "$LIBDF_DIR/Cargo.toml" ] || { echo "ERROR: models/df/libDF not found"; exit 1; }
echo ">> libDF source: $LIBDF_DIR"

# Ensure cargo-c is available
if ! command -v cargo-cinstall >/dev/null 2>&1; then
  echo ">> Installing cargo-c ..."
  cargo install cargo-c || { echo "ERROR: cargo-c install failed"; exit 1; }
fi

# Use .cargo/config.toml for Android linkers (must exist in libDF dir)
if [ ! -f "$LIBDF_DIR/.cargo/config.toml" ]; then
  echo ">> Creating .cargo/config.toml in $LIBDF_DIR ..."
  mkdir -p "$LIBDF_DIR/.cargo"
  cat > "$LIBDF_DIR/.cargo/config.toml" <<EOF
[target.aarch64-linux-android]
linker = "$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"

[target.armv7-linux-androideabi]
linker = "$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/arm-linux-androideabi26-clang"

[target.x86_64-linux-android]
linker = "$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android26-clang"
EOF
fi

for ABI in "arm64-v8a" "armeabi-v7a" "x86_64"; do
  echo ">> Building libdf CAPI for $ABI ..."

  case $ABI in
    "arm64-v8a")   TARGET="aarch64-linux-android" ;;
    "armeabi-v7a") TARGET="armv7-linux-androideabi" ;;
    "x86_64")      TARGET="x86_64-linux-android" ;;
  esac

  DEST_DIR="$LIBDF_DIR/target/ndk-$ABI/release"
  DESTDIR="$LIBDF_DIR/staging-$ABI"

  rm -rf "$DESTDIR"
  mkdir -p "$DESTDIR"

  cd "$LIBDF_DIR"
  # Upstream approach: cargo cinstall with capi feature, nightly preferred
  cargo cinstall --profile=release-lto -p deep_filter \
    --features=capi \
    --target "$TARGET" \
    --destdir="$DESTDIR" 2>&1 | tail -n10 || { echo "! cargo cinstall failed for $ABI (target=$TARGET)"; exit 1; }

  # cargo-c puts .so under $DESTDIR/usr/lib/ or $DESTDIR/lib/ depending on version
  # Find the produced .so and stage it for build.sh
  SO_FILE=$(find "$DESTDIR" -name "libdf.so" -o -name "libdeep_filter.so" | head -n1 || true)
  if [ -n "$SO_FILE" ] && [ -f "$SO_FILE" ]; then
    mkdir -p "$DEST_DIR"
    cp -f "$SO_FILE" "$DEST_DIR/libdf.so"
    echo ">> libdf ($ABI / $TARGET) -> $DEST_DIR/libdf.so ($(du -h "$SO_FILE" | cut -f1))"
  else
    echo "! libdf.so not found in $DESTDIR; listing:"
    find "$DESTDIR" -type f | head -n20 || true
    exit 1
  fi
done

echo ">> Cross-compiled libdf (CAPI) complete. DF_DIR=$LIBDF_DIR/target/ndk-<ABI>/release"
