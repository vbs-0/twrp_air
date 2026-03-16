#!/system/bin/sh
set -x
# TWRP Debug Boot Script - HIOS1 Baseline - Recovery-Sync
LOGFILE="/tmp/recovery_debug.log"

log_msg() {
    MSG="[debug_boot] $1"
    echo "$MSG" | tee -a "$LOGFILE" > /dev/kmsg
}

exec 2>>"$LOGFILE" # Capture all stderr to logfile

log_msg "--- TWRP HIOS1 BASELINE START ---"

# 1. Block Device Alignment (Mediatek)
log_msg "Aligning block device paths..."
mkdir -p /dev/block/platform/bootdevice/by-name/
for part in preloader_raw_a preloader_raw_b; do
    [ -L /dev/block/by-name/$part ] && ln -sf /dev/block/by-name/$part /dev/block/platform/bootdevice/by-name/$part
done

# 2. TEE Node Readiness
log_msg "Ensuring TEE node permissions..."
chmod 0666 /dev/teepriv0 /dev/tee0 2>/dev/null
chown system:system /dev/teepriv0 /dev/tee0 2>/dev/null

# 3. Basic Xiaomi Touch Property (Commonly needed)
log_msg "Setting touch status..."
setprop sys.touch.status 1

# 4. Signal readiness for services
log_msg "Signaling VINTF ready (Minimal)..."
setprop twrp.vintf.ready 1

log_msg "--- TWRP HIOS1 BASELINE END ---"
exit 0
