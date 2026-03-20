#!/system/bin/sh
set -x
# TWRP Debug Boot - @vbs_1 & @dream_7x - FINAL
LOGFILE="/tmp/recovery_debug.log"
exec >>"$LOGFILE" 2>&1

log_msg() { echo "[debug_boot] $1" | tee -a "$LOGFILE" > /dev/kmsg; }

log_msg "--- TWRP DEBUG BOOT START ---"

# 0. SELinux permissive IMMEDIATELY
setenforce 0
log_msg "SELinux: $(getenforce)"

# 1. Identity restoration from vendor build.prop
VENDOR_PROP="/vendor/build.prop"
[ -f /vendor/etc/build.prop ] && VENDOR_PROP="/vendor/etc/build.prop"
REAL_VER=$(getprop ro.vendor.build.version.release)
REAL_PATCH=$(getprop ro.vendor.build.security_patch)
if [ "$REAL_PATCH" = "2099-12-31" ] || [ -z "$REAL_PATCH" ]; then
    if [ -f "$VENDOR_PROP" ]; then
        REAL_VER=$(grep -m1 "ro.vendor.build.version.release=" "$VENDOR_PROP" | cut -d'=' -f2)
        FILE_PATCH=$(grep -m1 "ro.vendor.build.security_patch=" "$VENDOR_PROP" | cut -d'=' -f2)
        [ -n "$FILE_PATCH" ] && [ "$FILE_PATCH" != "2099-12-31" ] && REAL_PATCH="$FILE_PATCH"
    fi
fi
if [ -n "$REAL_VER" ]; then
    log_msg "Identity: Android $REAL_VER patch:$REAL_PATCH"
    /system/bin/resetprop ro.build.version.release "$REAL_VER"
    /system/bin/resetprop ro.build.version.release_or_codename "$REAL_VER"
    [ -n "$REAL_PATCH" ] && /system/bin/resetprop ro.build.version.security_patch "$REAL_PATCH"
fi

# 2. Block Device Alignment
log_msg "Aligning block device paths..."
mkdir -p /dev/block/platform/bootdevice/by-name/
for part in preloader_raw_a preloader_raw_b; do
    [ -L /dev/block/by-name/$part ] && ln -sf /dev/block/by-name/$part /dev/block/platform/bootdevice/by-name/$part
done

# 3. TEE Node Readiness
log_msg "TEE nodes..."
chmod 0666 /dev/teepriv0 /dev/tee0 2>/dev/null
chown system:system /dev/teepriv0 /dev/tee0 2>/dev/null

# 4. VINTF manifest patch (version 5.0 -> 4.0 for TWRP compatibility)
log_msg "Patching VINTF..."
if [ -d /vendor/etc/vintf ]; then
    mkdir -p /tmp/vintf
    cp -rf /vendor/etc/vintf/* /tmp/vintf/
    find /tmp/vintf -type f -name "*.xml" -exec sed -i 's/version="5.0"/version="4.0"/g' {} +
    chmod -R 755 /tmp/vintf
    chown -R system:system /tmp/vintf
    mount -o bind /tmp/vintf /vendor/etc/vintf
    log_msg "VINTF patched OK"
fi

# 5. Touch module overlay — inject TWRP-compatible modules into vendor
# so that when Android system loads touch drivers, it loads ours (which match this kernel's CRC)
log_msg "Overlaying touch modules into vendor..."
VENDOR_MODS="/vendor/lib/modules"
if [ -d "$VENDOR_MODS" ]; then
    for mod in scp.ko lct_tp.ko xiaomi_tp.ko nt36528_spi.ko; do
        SRC="/lib/modules/$mod"
        if [ -f "$SRC" ]; then
            cp -f "$SRC" "$VENDOR_MODS/$mod" && log_msg "Overlaid $mod -> $VENDOR_MODS"
        fi
    done
else
    log_msg "WARNING: $VENDOR_MODS not found, skipping overlay"
fi

# 6. Signal VINTF Ready and clean restart of security chain
log_msg "Signaling VINTF ready + restarting security services..."
stop keystore2
stop gatekeeper-1-0
stop keymint-mitee
setprop twrp.vintf.ready 1

# 7. Wait for KeyMint AIDL and start Keystore2
(
    log_msg "[watcher] Waiting for IKeyMintDevice AIDL..."
    WAIT=0
    while [ $WAIT -lt 30 ]; do
        if service list 2>/dev/null | grep -q "IKeyMintDevice"; then
            log_msg "[watcher] KeyMint AIDL ready after ${WAIT}s -> starting keystore2"
            break
        fi
        sleep 1
        WAIT=$((WAIT+1))
    done
    if [ $WAIT -ge 30 ]; then
        log_msg "[watcher] TIMEOUT: KeyMint AIDL not found after 30s!"
    fi
    start keystore2
    log_msg "[watcher] keystore2 started."
) &
WATCHER_PID=$!

log_msg "--- DEBUG BOOT COMPLETE (watcher PID $WATCHER_PID running) ---"
wait $WATCHER_PID
exit 0
