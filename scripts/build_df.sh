#!/bin/bash
# Build DeepFilterNet libdf (C-FFI / CAPI) CROSS-COMPILED for Android ABIs
# Bypasses all faulty cargo-c/cargo-ndk sub-shell wrapper traps.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NDK="${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to Android NDK}"

echo ">> NDK: $NDK"
echo ">> Building libdf for Android ABIs: arm64-v8a armeabi-v7a x86_64 ..."

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

cd "$LIBDF_DIR"

# FORCE CACHE PURGE: Wipe out historical compilation layers to force complete re-evaluation
rm -rf .cargo/config.toml target/

for ABI in "arm64-v8a" "armeabi-v7a" "x86_64"; do
  echo ">> Compiling libdf CAPI binaries natively for $ABI ..."

  case $ABI in
    "arm64-v8a")
      TARGET="aarch64-linux-android"
      LINKER_ARCH="aarch64"
      ;;
    "armeabi-v7a")
      TARGET="armv7-linux-androideabi"
      LINKER_ARCH="arm"
      ;;
    "x86_64")
      TARGET="x86_64-linux-android"
      LINKER_ARCH="x86_64"
      ;;
  esac

  DEST_DIR="$LIBDF_DIR/target/ndk-$ABI/release"
  rm -rf "$LIBDF_DIR/staging-$ABI"
  mkdir -p "$DEST_DIR"

  # Path to the cross-compiler tool inside the runner's native Android NDK layout
  ANDROID_LINKER="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/${LINKER_ARCH}-linux-android26-clang"

  # Convert target string to Cargo target linker naming specifications
  # Example: CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER
  CARGO_TARGET_ENV=$(echo "CARGO_TARGET_${TARGET}_LINKER" | tr '-' '_' | tr '[:lower:]' '[:upper:]')

  echo ">> Injecting environment linker: $ANDROID_LINKER"

  # Pure, explicit cross-compilation block using direct rustup target passing
  export "$CARGO_TARGET_ENV"="$ANDROID_LINKER"

  rustup run stable cargo build --target "$TARGET" --release --features=capi -p deep_filter --target-dir="./target" || {
    echo "! Core cargo compilation failed for ABI: $ABI (target=$TARGET)";
    exit 1;
  }

  # Build structural C header bindings via standalone cbindgen
  cbindgen --crate deep_filter --output "$DEST_DIR/df.h" || echo ">> cbindgen skipped"

  # Map compiled library (.so) output binary layout
  BUILT_DIR="$LIBDF_DIR/target/$TARGET/release"
  SO_FILE=""
  for candidate in "$BUILT_DIR/libdf.so" "$BUILT_DIR/libdeep_filter.so"; do
    if [ -f "$candidate" ]; then
      SO_FILE="$candidate"
      break
    fi
  done

  if [ -n "$SO_FILE" ] && [ -f "$SO_FILE" ]; then
    cp -f "$SO_FILE" "$DEST_DIR/libdf.so"
    echo ">> Success: libdf ($ABI / $TARGET) -> $DEST_DIR/libdf.so ($(du -h "$SO_FILE" | cut -f1))"
  else
    echo "! ERROR: Shared library binary missing inside target directory: $BUILT_DIR"
    exit 1
  fi
done

echo ">> Cross-compiled libdf complete. Build pipeline cleared."
