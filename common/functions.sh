#!/system/bin/sh
# functions.sh — shared Clarifae helpers, sourced by customize.sh (install time)
# and by clarifae-ctl (runtime, from /data/adb/clarifae/functions.sh).
# POSIX sh / busybox ash only — no bashisms.

CLARIFAE_DIR=/data/adb/clarifae
CONFIG="$CLARIFAE_DIR/config.conf"
LOGFILE="$CLARIFAE_DIR/clarifae.log"
PATCH_MARK="$CLARIFAE_DIR/audio_effects.patched"   # holds the patched file path
BACKUP="$CLARIFAE_DIR/audio_effects.backup"

CLARIFAE_VERSION="v1.0.0"
EFFECT_UUID="c1a71fae-0001-4a5e-9b10-43578768aaf3"
LIB_NAME="clarifae"
EFFECT_NAME="clarifae_ns"

CLARIFAE_KEYS="enabled mode strength atten_db vad targets highpass autogain loglevel"

clarifae_defaults() {
  cat <<'EOF'
enabled=1
mode=1
strength=70
atten_db=24
vad=50
targets=mic,voice_comm
highpass=1
autogain=0
loglevel=1
EOF
}

clarifae_log() {
  mkdir -p "$CLARIFAE_DIR" 2>/dev/null
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOGFILE" 2>/dev/null
}

conf_init() {
  mkdir -p "$CLARIFAE_DIR" 2>/dev/null
  [ -f "$CONFIG" ] || clarifae_defaults > "$CONFIG"
}

# conf_get KEY -> value (falls back to default)
conf_get() {
  _k="$1"; _v=""
  [ -f "$CONFIG" ] && _v=$(grep "^$_k=" "$CONFIG" 2>/dev/null | tail -n1 | cut -d= -f2-)
  [ -z "$_v" ] && _v=$(clarifae_defaults | grep "^$_k=" | cut -d= -f2-)
  printf '%s' "$_v"
}

# conf_set KEY VALUE
conf_set() {
  _k="$1"; _v="$2"
  conf_init
  if grep -q "^$_k=" "$CONFIG" 2>/dev/null; then
    _tmp="$CONFIG.tmp.$$"
    sed "s|^$_k=.*|$_k=$_v|" "$CONFIG" > "$_tmp" && mv "$_tmp" "$CONFIG"
  else
    echo "$_k=$_v" >> "$CONFIG"
  fi
}

# write a single property (persisted)
_setp() {
  if command -v resetprop >/dev/null 2>&1; then
    resetprop -n -p "$1" "$2"
  else
    setprop "$1" "$2"
  fi
}

# push every config key to its persist.clarifae.* property
prop_sync() {
  for _k in $CLARIFAE_KEYS; do
    _setp "persist.clarifae.$_k" "$(conf_get "$_k")"
  done
  clarifae_log "props synced from config"
}

mode_name() {
  case "$1" in
    1) echo "RNNoise (Low latency)";;
    2) echo "DTLN (Balanced)";;
    3) echo "DeepFilterNet (Maximum clarity)";;
    *) echo "Unknown";;
  esac
}

# ---- audio_effects.xml / .conf integration ----

find_audio_effects_file() {
  for _f in /vendor/etc/audio_effects.xml /odm/etc/audio_effects.xml \
            /system/etc/audio_effects.xml /vendor/etc/audio_effects.conf \
            /system/etc/audio_effects.conf; do
    [ -f "$_f" ] && { echo "$_f"; return 0; }
  done
  return 1
}

# map a real partition path to the module overlay path (Magisk magic-mount)
overlay_path_for() {
  _mp="$1"; _real="$2"
  case "$_real" in
    /vendor/*) echo "$_mp/system$_real" ;;          # system/vendor -> /vendor
    /odm/*)    echo "$_mp/system/odm${_real#/odm}" ;;
    /system/*) echo "$_mp$_real" ;;
    *)         echo "$_mp/system$_real" ;;
  esac
}

# our csv target names -> AOSP audio_source stream types
map_targets() {
  _out=""
  _oifs="$IFS"; IFS=,
  for _t in $1; do
    case "$_t" in
      mic)        _s=mic ;;
      voice_comm) _s=voice_communication ;;
      camcorder)  _s=camcorder ;;
      voice_rec)  _s=voice_recognition ;;
      *)          _s="" ;;
    esac
    [ -n "$_s" ] && _out="$_out $_s"
  done
  IFS="$_oifs"
  echo "$_out"
}

_patch_xml_file() {
  _src="$1"; _dst="$2"; _streams="$3"
  awk -v uuid="$EFFECT_UUID" -v lib="$LIB_NAME" -v eff="$EFFECT_NAME" -v streams="$_streams" '
    BEGIN {
      lib_done=0; eff_done=0; pre_done=0; in_pre=0; cur="";
      n=split(streams, want, " ");
      for (i=1;i<=n;i++) if (want[i]!="") handled[want[i]]=0;
    }
    function emit_one(t) {
      print "        <stream type=\"" t "\">";
      print "            <apply effect=\"" eff "\"/>";
      print "        </stream>";
    }
    function emit_unhandled(   i) {
      for (i=1;i<=n;i++) if (want[i]!="" && handled[want[i]]==0) { emit_one(want[i]); handled[want[i]]=1 }
    }
    /<\/libraries>/ && !lib_done {
      print "        <library name=\"" lib "\" path=\"libclarifae.so\"/>"; lib_done=1
    }
    /<\/effects>/ && !eff_done {
      print "        <effect name=\"" eff "\" library=\"" lib "\" uuid=\"" uuid "\"/>"; eff_done=1
    }
    /<preprocess>/ { in_pre=1 }
    # track the current capture stream type inside <preprocess>
    {
      if (in_pre && /<stream/ && match($0, /type="[^"]*"/))
        cur = substr($0, RSTART + 6, RLENGTH - 7);
    }
    # append our apply into an existing matching stream, before its close tag
    /<\/stream>/ && in_pre {
      if (cur != "" && (cur in handled) && handled[cur]==0) {
        print "            <apply effect=\"" eff "\"/>"; handled[cur]=1;
      }
      cur="";
    }
    # add any target streams the device did not already define
    /<\/preprocess>/ && in_pre && !pre_done { emit_unhandled(); pre_done=1; in_pre=0 }
    # no <preprocess> block at all -> create one
    /<\/audio_effects_conf>/ && !pre_done {
      print "    <preprocess>"; emit_unhandled(); print "    </preprocess>"; pre_done=1
    }
    { print }
  ' "$_src" > "$_dst" 2>/dev/null
  [ -s "$_dst" ] && grep -q "clarifae" "$_dst"
}

_patch_conf_file() {
  _src="$1"; _dst="$2"; _streams="$3"
  awk -v uuid="$EFFECT_UUID" -v lib="$LIB_NAME" -v eff="$EFFECT_NAME" -v streams="$_streams" '
    BEGIN { lib_done=0; eff_done=0 }
    { print }
    /libraries[ \t]*\{/ && !lib_done { print "  " lib " { path libclarifae.so }"; lib_done=1 }
    /effects[ \t]*\{/   && !eff_done { print "  " eff " { library " lib " uuid " uuid " }"; eff_done=1 }
    /pre_processing[ \t]*\{/ {
      n=split(streams, arr, " ");
      for (i=1;i<=n;i++) if (arr[i]!="") print "  " arr[i] " { " eff " {} }";
    }
  ' "$_src" > "$_dst" 2>/dev/null
  [ -s "$_dst" ] && grep -q "clarifae" "$_dst"
}

# patch_audio_effects MODPATH -> 0 ok / 1 fail. Writes overlay + backup + marker.
patch_audio_effects() {
  _mp="$1"
  _real="$(find_audio_effects_file)" || { clarifae_log "audio_effects file not found"; return 1; }
  _streams="$(map_targets "$(conf_get targets)")"
  _overlay="$(overlay_path_for "$_mp" "$_real")"

  if grep -q "clarifae" "$_real" 2>/dev/null; then
    clarifae_log "audio_effects already references clarifae ($_real)"
    echo "$_real" > "$PATCH_MARK"
    return 0
  fi

  mkdir -p "$(dirname "$_overlay")" 2>/dev/null
  cp -f "$_real" "$BACKUP" 2>/dev/null

  case "$_real" in
    *.xml)  _patch_xml_file  "$_real" "$_overlay" "$_streams" ;;
    *.conf) _patch_conf_file "$_real" "$_overlay" "$_streams" ;;
    *) return 1 ;;
  esac

  if [ $? -eq 0 ]; then
    chmod 0644 "$_overlay" 2>/dev/null
    echo "$_overlay" > "$PATCH_MARK"
    clarifae_log "patched audio_effects: $_real -> $_overlay (streams:$_streams)"
    return 0
  fi
  clarifae_log "FAILED to patch $_real"
  return 1
}

is_audio_effects_patched() {
  _f="$(find_audio_effects_file)" || return 1
  grep -q "clarifae" "$_f" 2>/dev/null
}
