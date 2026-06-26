#!/system/bin/sh
# post-fs-data.sh — early boot. Ensure the Clarifae data dir exists with safe
# perms before anything reads it. Keep this lightweight (runs before full boot).
MODDIR=${0%/*}
DATADIR=/data/adb/clarifae

mkdir -p "$DATADIR/models/dtln" "$DATADIR/models/df"
chmod 0700 "$DATADIR" 2>/dev/null

# Keep a copy of the helper library reachable by clarifae-ctl from PATH.
[ -f "$MODDIR/common/functions.sh" ] && cp -f "$MODDIR/common/functions.sh" "$DATADIR/functions.sh"
