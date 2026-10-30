#!/system/bin/sh
# customize.sh — Clarifae installer (sourced by Magisk / KernelSU / APatch).
SKIPUNZIP=0

ui_print " "
ui_print "  ============================================"
ui_print "   Clarifae — Real-Time AI Audio Clarity"
ui_print "   RNNoise / DTLN / DeepFilterNet  +  WebUI"
ui_print "  ============================================"
ui_print " "

. "$MODPATH/common/functions.sh"

# --- architecture -> ABI / lib dir ---
ui_print "- Architecture: $ARCH (API $API)"
case "$ARCH" in
  arm64) ABI=arm64-v8a;   LIBD=lib64 ;;
  arm)   ABI=armeabi-v7a; LIBD=lib   ;;
  x64)   ABI=x86_64;      LIBD=lib64 ;;
  x86)   ABI=x86;         LIBD=lib   ;;
  *) abort "! Unsupported architecture: $ARCH" ;;
esac

# --- install the native effect for THIS device's ABI ---
# The zip bundles every ABI under lib/<abi>/; install only the matching one into
# system/lib(64)/soundfx (both 64-bit ABIs share lib64, so we must pick here).
[ -f "$MODPATH/lib/$ABI/libclarifae.so" ] || \
  abort "! libclarifae.so for $ABI not bundled. Build it: ABIS=\"$ABI\" ./build.sh"

# clear any stale soundfx libs, then install the correct one
rm -f "$MODPATH/system/lib/soundfx/libclarifae.so" "$MODPATH/system/lib64/soundfx/libclarifae.so" 2>/dev/null
mkdir -p "$MODPATH/system/$LIBD/soundfx"
cp -f "$MODPATH/lib/$ABI/libclarifae.so" "$MODPATH/system/$LIBD/soundfx/libclarifae.so"
ui_print "- Installed libclarifae.so ($ABI) -> system/$LIBD/soundfx"

# --- install libdf.so (DeepFilterNet C-FFI) for CLARIFAE_WITH_DF ---
for df_candidate in "$MODPATH/models/df/libDF/staging-$ABI/libdf.so" "$MODPATH/models/df/libDF/target/ndk-$ABI/release/libdf.so" "$MODPATH/models/df/libDF/libdf.so"; do
  [ -f "$df_candidate" ] || continue
  cp -f "$df_candidate" "$MODPATH/system/$LIBD/soundfx/libdf.so"
  ui_print "- Installed libdf.so ($ABI) -> system/$LIBD/soundfx/libdf.so"
  break
done

# --- install libtensorflowlite_c.so (TFLite C library, required for DTLN mode 2) ---
for tflite_candidate in "$MODPATH/tflite_ref/lib/$ABI/libtensorflowlite_c.so" "$MODPATH/tflite_ref/lib/libtensorflowlite_c.so" "$MODPATH/tflite_ref/libtensorflowlite_c.so"; do
  [ -f "$tflite_candidate" ] || continue
  cp -f "$tflite_candidate" "$MODPATH/system/$LIBD/soundfx/libtensorflowlite_c.so"
  ui_print "- Installed libtensorflowlite_c.so ($ABI) -> system/$LIBD/soundfx/libtensorflowlite_c.so"
  break
done

# drop per-ABI archive + any stray dev dirs to keep the installed module small
rm -rf "$MODPATH/lib" "$MODPATH/native" "$MODPATH/build" 2>/dev/null

# --- runtime data dir + config + helpers ---
mkdir -p "$CLARIFAE_DIR/models/dtln" "$CLARIFAE_DIR/models/df"
conf_init
cp -f "$MODPATH/common/functions.sh" "$CLARIFAE_DIR/functions.sh"
ui_print "- Config: $CONFIG"

# --- CLI: on PATH (system/bin, post-reboot) + always-present data-dir copy ---
# The WebUI calls the data-dir copy by absolute path, so toggles work even
# before a reboot and regardless of whether the system overlay is on PATH.
mkdir -p "$MODPATH/system/bin"
cp -f "$MODPATH/common/clarifae-ctl" "$MODPATH/system/bin/clarifae-ctl"
cp -f "$MODPATH/common/clarifae-ctl" "$CLARIFAE_DIR/clarifae-ctl"
chmod 0755 "$CLARIFAE_DIR/clarifae-ctl"

# --- copy any bundled optional models to /data ---
[ -d "$MODPATH/models" ] && cp -rf "$MODPATH/models/." "$CLARIFAE_DIR/models/" 2>/dev/null

# --- auto-attach the effect via audio_effects.xml ---
ui_print "- Registering Clarifae pre-processing effect..."
if patch_audio_effects "$MODULE_DIR"; then
  ui_print "  + audio_effects patched: $(cat "$PATCH_MARK")"
else
  ui_print "  ! Auto-patch of audio_effects.xml failed on this device."
  ui_print "    Library is installed; see docs/TROUBLESHOOTING.md to attach manually."
fi

# --- seed props (service.sh re-applies on every boot) ---
prop_sync 2>/dev/null

# --- permissions ---
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/system/bin/clarifae-ctl" 0 0 0755
[ -f "$MODPATH/system/lib64/soundfx/libclarifae.so" ] && set_perm "$MODPATH/system/lib64/soundfx/libclarifae.so" 0 0 0644
[ -f "$MODPATH/system/lib/soundfx/libclarifae.so" ]   && set_perm "$MODPATH/system/lib/soundfx/libclarifae.so" 0 0 0644
[ -f "$MODPATH/system/lib64/soundfx/libdf.so" ]         && set_perm "$MODPATH/system/lib64/soundfx/libdf.so" 0 0 0644
[ -f "$MODPATH/system/lib/soundfx/libdf.so" ]           && set_perm "$MODPATH/system/lib/soundfx/libdf.so" 0 0 0644
[ -f "$MODPATH/system/lib64/soundfx/libtensorflowlite_c.so" ] && set_perm "$MODPATH/system/lib64/soundfx/libtensorflowlite_c.so" 0 0 0644
[ -f "$MODPATH/system/lib/soundfx/libtensorflowlite_c.so" ]   && set_perm "$MODPATH/system/lib/soundfx/libtensorflowlite_c.so" 0 0 0644

ui_print " "
ui_print "  Installed. Reboot, then open the WebUI:"
ui_print "   - KernelSU/APatch: Modules > Clarifae > Open"
ui_print "   - Magisk: use the MMRL app to open Clarifae's WebUI"
ui_print "  Default engine = RNNoise (works out of the box)."
ui_print " "
