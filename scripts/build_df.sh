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

# cargo-ndk gestiona los linkers dinámicamente; NO creamos .cargo/config.toml manual
# Limpiar configuraciones locales previas que puedan interferir con cargo-ndk
rm -rf "$LIBDF_DIR/.cargo/config.toml"

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
  # Use cargo-ndk as wrapper to inject NDK toolchain environment, then pass cbuild (cargo-c subcommand)
  # Ejecución cruda sin ocultar flujos para evitar interrupciones de subprocesos (SIGPIPE / tail -n20)
  cargo ndk --target "$TARGET" --platform 26 cbuild --release --features=capi -p deep_filter --target-dir="./target" || { echo "! cargo cbuild failed for $ABI (target=$TARGET)"; exit 1; }

  # cargo-c (via cargo-ndk) writes output to ./target/<TARGET>/release/
  # Find the produced .so in the target dir and stage it for build.sh
  BUILT_DIR="$LIBDF_DIR/target/$TARGET/release"
  mkdir -p "$DEST_DIR"
  SO_FILE=""
  for candidate in "$BUILT_DIR/libdf.so" "$BUILT_DIR/libdeep_filter.so"; do
    if [ -f "$candidate" ]; then
      SO_FILE="$candidate"
      break
    fi
  done
  if [ -n "$SO_FILE" ] && [ -f "$SO_FILE" ]; then
    cp -f "$SO_FILE" "$DEST_DIR/libdf.so"
    echo ">> libdf ($ABI / $TARGET) -> $DEST_DIR/libdf.so ($(du -h "$SO_FILE" | cut -f1))"
  else
    echo "! libdf.so not found in $BUILT_DIR; listing:"
    ls -la "$BUILT_DIR" | head -n20 || true
    exit 1
  fi
done

echo ">> Cross-compiled libdf (CAPI) complete. DF_DIR=$LIBDF_DIR/target/ndk-<ABI>/release"
