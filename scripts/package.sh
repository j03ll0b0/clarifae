#!/usr/bin/env bash
# package.sh — build dist/clarifae-<ver>.zip, flashable in Magisk / KernelSU / APatch.
#
# Run it AFTER the binaries exist:
#   scripts/prepare_modes_2_3.sh  -> tflite_ref/lib/<abi>/libtensorflowlite_c.so
#   scripts/build_df.sh           -> models/df/libDF/target/ndk-<abi>/release/libdf.so
#   build.sh                      -> lib/<abi>/libclarifae.so
#
#   bash scripts/package.sh
#   ABIS="arm64-v8a armeabi-v7a x86_64" bash scripts/package.sh     # other ABI set
#
# WHAT THE ZIP CONTAINS, AND WHY (derived from customize.sh and native/*.c):
#
#   module.prop customize.sh service.sh post-fs-data.sh uninstall.sh sepolicy.rule system.prop
#   common/   META-INF/   webroot/
#
#   lib/<abi>/libclarifae.so                      customize.sh installs the one matching the
#                                                 device into system/lib(64)/soundfx/
#   tflite_ref/lib/<abi>/libtensorflowlite_c.so   customize.sh -> system/lib(64)/soundfx/
#   models/df/libDF/staging-<abi>/libdf.so        customize.sh -> system/lib(64)/soundfx/
#                                                 (libclarifae.so links both of these, so
#                                                 they must sit next to it on the device)
#
#   models/dtln/model_1.tflite, model_2.tflite    customize.sh copies models/ to
#                                                 /data/adb/clarifae/models/; backend_dtln.c
#                                                 loads them from there (M1_PATH / M2_PATH)
#   models/df/DeepFilterNet3_onnx.tar.gz          same; backend_deepfilternet.c loads it
#                                                 (DF_MODEL_PATH). This is the ONNX export, not
#                                                 the PyTorch DeepFilterNet*.zip checkpoints.
#
# NOT in the zip: native/ build/ tflite_build/ scripts/, DTLN training code and checkpoints
# (models/dtln/*.py, *.h5, pretrained_model/), DeepFilterNet sources/assets, models/df/models/.
#
# Exit status: 0 only if every required file is present, sane, and matches its ABI.
# Any problem prints a list of what is wrong, removes the zip, and exits 1 (so CI fails too).
set -euo pipefail

MOD="$(cd "$(dirname "$0")/.." && pwd)"
VER="$(grep '^version=' "$MOD/module.prop" | cut -d= -f2)"
[ -n "$VER" ] || { echo "ERROR: no version= line in module.prop" >&2; exit 1; }
OUT="$MOD/dist/clarifae-$VER.zip"
STAGE="$MOD/dist/stage"
ABIS="${ABIS:-arm64-v8a armeabi-v7a}"

ERRORS=()
WARNINGS=()
EXPECTED=()      # every path (relative to the zip root) that MUST be in the final zip

err()  { ERRORS+=("$1");   echo "    ! $1" >&2; }
warn() { WARNINGS+=("$1"); echo "    ~ $1" >&2; }

# _pick PATH... -> prints the first PATH that is a regular file
_pick() {
  local f
  for f in "$@"; do
    if [ -f "$f" ]; then printf '%s' "$f"; return 0; fi
  done
  return 1
}

# stage DEST SRC...  : copy the first existing SRC to $STAGE/DEST; required
stage() {
  local dest="$1" src tried=""
  shift
  if src="$(_pick "$@")"; then
    mkdir -p "$STAGE/$(dirname "$dest")"
    cp -f "$src" "$STAGE/$dest"
    EXPECTED+=("$dest")
    echo "    + $dest   <- ${src#"$MOD"/}"
  else
    for src in "$@"; do tried="$tried ${src#"$MOD"/}"; done
    err "missing $dest (looked for:$tried)"
  fi
}

# stage_optional DEST SRC...  : same, but only a warning if absent
stage_optional() {
  local dest="$1" src
  shift
  if src="$(_pick "$@")"; then
    mkdir -p "$STAGE/$(dirname "$dest")"
    cp -f "$src" "$STAGE/$dest"
    echo "    + $dest   <- ${src#"$MOD"/}"
  else
    warn "optional $dest not found"
  fi
}

# stage_dir DIR : copy a whole directory of module scaffolding; required
stage_dir() {
  if [ -d "$MOD/$1" ]; then
    cp -R "$MOD/$1" "$STAGE/$1"
    echo "    + $1/"
  else
    err "missing directory $1/"
  fi
}

# --- ELF helpers (readelf or llvm-readelf) ---------------------------------
READELF="$(command -v readelf || command -v llvm-readelf || true)"

elf_field()  { "$READELF" -h "$1" 2>/dev/null | awk -F: -v k="$2" '$1 ~ k { sub(/^[ \t]+/, "", $2); print $2; exit }'; }
elf_needed() { "$READELF" -d "$1" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p'; }

# "<readelf Machine>|<readelf Class>" expected for each Android ABI
abi_signature() {
  case "$1" in
    arm64-v8a)   echo "AArch64|ELF64" ;;
    armeabi-v7a) echo "ARM|ELF32" ;;
    x86_64)      echo "Advanced Micro Devices X86-64|ELF64" ;;
    x86)         echo "Intel 80386|ELF32" ;;
    *)           echo "" ;;
  esac
}

# Check every staged .so: right architecture, and every library it links to is either an
# Android system library or is itself shipped for that ABI.
audit_elf() {
  if [ -z "$READELF" ]; then
    warn "readelf / llvm-readelf not found: skipping architecture and dependency checks"
    return 0
  fi
  local abi sig want_m want_c so got_m got_c n shipped
  local libs
  for abi in $ABIS; do
    sig="$(abi_signature "$abi")"
    [ -n "$sig" ] || continue
    want_m="${sig%%|*}"; want_c="${sig##*|}"
    libs=("lib/$abi/libclarifae.so"
          "tflite_ref/lib/$abi/libtensorflowlite_c.so"
          "models/df/libDF/staging-$abi/libdf.so")
    shipped=" "
    for so in "${libs[@]}"; do shipped="$shipped$(basename "$so") "; done

    for so in "${libs[@]}"; do
      [ -f "$STAGE/$so" ] || continue
      got_m="$(elf_field "$STAGE/$so" Machine)"
      got_c="$(elf_field "$STAGE/$so" Class)"
      if [ "$got_m" != "$want_m" ] || [ "$got_c" != "$want_c" ]; then
        err "$so is ${got_c:-not an ELF file}/${got_m:-?} but ABI $abi needs $want_c/$want_m"
        continue
      fi
      while IFS= read -r n; do
        [ -n "$n" ] || continue
        case "$n" in
          libc.so|libm.so|libdl.so|liblog.so|libstdc++.so|libz.so|libandroid.so) continue ;;
        esac
        case "$shipped" in
          *" $n "*) ;;
          *) case "$n" in
               */*) err "$so links '$n' by absolute path (library has no SONAME); it will not resolve on the device" ;;
               *)   err "$so needs $n, which is not shipped for $abi" ;;
             esac ;;
        esac
      done < <(elf_needed "$STAGE/$so")
    done
  done
}

# Check that the staged model files are the real thing (not git-lfs stubs / truncated / wrong kind).
audit_models() {
  local f need listing
  for f in models/dtln/model_1.tflite models/dtln/model_2.tflite; do
    [ -f "$STAGE/$f" ] || continue
    if [ "$(dd if="$STAGE/$f" bs=1 skip=4 count=4 2>/dev/null)" != "TFL3" ]; then
      err "$f is not a TFLite model (git-lfs pointer or truncated download?)"
    fi
  done
  f=models/df/DeepFilterNet3_onnx.tar.gz
  if [ -f "$STAGE/$f" ]; then
    if ! listing="$(tar -tzf "$STAGE/$f" 2>/dev/null)"; then
      err "$f is not a readable .tar.gz"
    else
      for need in enc.onnx erb_dec.onnx df_dec.onnx config.ini; do
        [[ "$listing" == *"$need"* ]] || err "$f does not contain $need (is it the ONNX export?)"
      done
    fi
  fi
}

finish_failed() {
  rm -f "$OUT"
  echo >&2
  echo "PACKAGE FAILED: ${#ERRORS[@]} problem(s):" >&2
  local e
  for e in "${ERRORS[@]}"; do echo "  - $e" >&2; done
  exit 1
}

echo "[*] Cleaning dist/ ..."
rm -rf "$MOD/dist"
mkdir -p "$STAGE"
trap 'rm -rf "$STAGE"' EXIT

echo "[*] Module scaffolding ..."
for f in module.prop customize.sh service.sh post-fs-data.sh uninstall.sh sepolicy.rule system.prop; do
  stage "$f" "$MOD/$f"
done
stage_dir common
stage_dir META-INF
stage_dir webroot
EXPECTED+=(common/functions.sh common/clarifae-ctl common/audio_effects.clarifae.xml
           META-INF/com/google/android/update-binary META-INF/com/google/android/updater-script
           webroot/index.html webroot/app.js)

echo "[*] Native libraries (ABIs: $ABIS) ..."
for abi in $ABIS; do
  if [ -z "$(abi_signature "$abi")" ]; then err "unsupported ABI '$abi'"; continue; fi
  stage "lib/$abi/libclarifae.so" \
        "$MOD/lib/$abi/libclarifae.so" \
        "$MOD/build/$abi/libclarifae.so" \
        "$MOD/build/$abi/lib/libclarifae.so" \
        "$MOD/build/$abi/lib/$abi/libclarifae.so"
  stage "tflite_ref/lib/$abi/libtensorflowlite_c.so" \
        "$MOD/tflite_ref/lib/$abi/libtensorflowlite_c.so"
  stage "models/df/libDF/staging-$abi/libdf.so" \
        "$MOD/models/df/libDF/staging-$abi/libdf.so" \
        "$MOD/models/df/libDF/target/ndk-$abi/release/libdf.so"
done

echo "[*] Model files ..."
stage "models/dtln/model_1.tflite" \
      "$MOD/models/dtln/model_1.tflite" "$MOD/models/dtln/pretrained_model/model_1.tflite"
stage "models/dtln/model_2.tflite" \
      "$MOD/models/dtln/model_2.tflite" "$MOD/models/dtln/pretrained_model/model_2.tflite"
stage "models/df/DeepFilterNet3_onnx.tar.gz" \
      "$MOD/models/df/DeepFilterNet3_onnx.tar.gz" "$MOD/models/df/models/DeepFilterNet3_onnx.tar.gz"
stage_optional "models/dtln/LICENSE"       "$MOD/models/dtln/LICENSE"
stage_optional "models/df/LICENSE-APACHE"  "$MOD/models/df/LICENSE-APACHE"
stage_optional "models/df/LICENSE-MIT"     "$MOD/models/df/LICENSE-MIT"

echo "[*] Checking staged files ..."
audit_models
audit_elf

if [ "${#ERRORS[@]}" -ne 0 ]; then
  finish_failed
fi

echo "[*] Zipping ..."
( cd "$STAGE" && zip -qr9 -X "$OUT" . -x '*.DS_Store' -x '*~' -x '*.swp' )

echo "[*] Auditing zip ..."
ENTRIES="$(unzip -Z1 "$OUT")"
for e in "${EXPECTED[@]}"; do
  grep -qxF -- "$e" <<<"$ENTRIES" || err "zip is missing $e"
done
UNWANTED="$(grep -E '(^|/)(native|build|dist|\.git|pretrained_model|tflite_build)/|^models/df/models/|^models/df/(DeepFilterNet|libDF/src|libDF/target|assets)/|\.(py|h5|pb|hdf5|wav|rs|zip|ckpt)$' <<<"$ENTRIES" || true)"
if [ -n "$UNWANTED" ]; then
  err "zip contains files that should not ship: $(printf '%s' "$UNWANTED" | head -n 5 | tr '\n' ' ')"
fi
if [ "${#ERRORS[@]}" -ne 0 ]; then
  finish_failed
fi

echo
echo "Created: $OUT ($(du -h "$OUT" | cut -f1))"
unzip -l "$OUT" | grep -E '\.(so|tflite|tar\.gz)$' || true
echo
if [ "${#WARNINGS[@]}" -ne 0 ]; then
  echo "Warnings: ${#WARNINGS[@]} (see above)"
fi
echo "Package audit: OK — ${#EXPECTED[@]} required entries verified for ABIs: $ABIS"
echo "Flash $OUT in Magisk / KernelSU / APatch."
