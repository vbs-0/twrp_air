#!/system/bin/sh
set -x
# TWRP Debug Boot Script - Phase 21
LOGFILE="/tmp/debug_boot.log"

log_msg() {
    echo "$1"
    echo "$1" > /dev/kmsg
}

exec > $LOGFILE 2>&1

log_msg "--- TWRP PHASE 21 DEBUG BOOT START ---"
date
id

# 0. Disable SELinux IMMEDIATELY
log_msg "Forcing SELinux Permissive..."
setenforce 0
getenforce

# Ensure mtk_plpath_utils is executable
chmod 755 /system/bin/mtk_plpath_utils

# 1. Fix Block Device Paths
log_msg "Fixing block device paths..."
mkdir -p /dev/block/platform/bootdevice/by-name/
chcon u:object_r:block_device:s0 /dev/block/platform/bootdevice/by-name/ 2>/dev/null

for part in preloader_raw_a preloader_raw_b; do
    if [ ! -L /dev/block/platform/bootdevice/by-name/$part ]; then
        log_msg "Creating symlink for $part..."
        ln -s /dev/block/by-name/$part /dev/block/platform/bootdevice/by-name/$part 2>/dev/null
    fi
done

# 2. TEE permissions — DO NOT chcon (mitee_client_device is INVALID in recovery context)
# chcon would flip the label to 'unlabeled', breaking tee-supplicant reopens.
# SELinux is permissive here so only permissions + ownership matter.
log_msg "Waiting for TEE device nodes..."
TIMER=0
while [ ! -c /dev/teepriv0 ] && [ $TIMER -lt 15 ]; do
    log_msg "Waiting for /dev/teepriv0... ($TIMER s)"
    sleep 1
    TIMER=$((TIMER + 1))
done

if [ -c /dev/teepriv0 ]; then
    log_msg "Found TEE nodes — setting perms only (no chcon — invalid in recovery)"
    chmod 0666 /dev/teepriv0 /dev/tee0 2>/dev/null
    chown system:system /dev/teepriv0 /dev/tee0 2>/dev/null
    ls -lZ /dev/teepriv0 /dev/tee0
else
    log_msg "WARNING: TEE nodes not found after 15s"
fi

# 3. VINTF patching
log_msg "--- Applying VINTF overrides ---"
if [ -d /vendor/etc/vintf ]; then
    mkdir -p /tmp/vintf
    cp -rf /vendor/etc/vintf/* /tmp/vintf/
    find /tmp/vintf -type f -name "*.xml" -exec sed -i 's/version="5.0"/version="4.0"/g' {} +
    chmod -R 755 /tmp/vintf
    chown -R system:system /tmp/vintf
    mount -o bind /tmp/vintf /vendor/etc/vintf
    log_msg "Bind-mount /tmp/vintf over /vendor/etc/vintf: $?"
fi

if [ -f /vendor/manifest.xml ]; then
    sed 's/version="5.0"/version="4.0"/g' /vendor/manifest.xml > /tmp/vendor_manifest.xml
    chmod 644 /tmp/vendor_manifest.xml
    chown system:system /tmp/vendor_manifest.xml
    mount -o bind /tmp/vendor_manifest.xml /vendor/manifest.xml
    log_msg "Bind-mount /vendor/manifest.xml: $?"
fi

# 4. Ensure keystore2 data directory exists with correct ownership
# keystore2.rc uses: /system/bin/keystore2 /data/misc/keystore
log_msg "Ensuring /data/misc/keystore exists..."
mkdir -p /data/misc/keystore
chown -R system:system /data/misc/keystore 2>/dev/null
chmod 0700 /data/misc/keystore 2>/dev/null

# 5. Stop the early keystore2 (started at late-init before TEE was ready)
# Then signal VINTF ready so init.recovery.mt6835.rc property trigger fires:
# It will start: tee-supplicant, gatekeeper-1-0, keymint-mitee, then keystore2
# PHASE 21 KEY FIX: Do NOT stop keymint-mitee or gatekeeper prematurely.
log_msg "Stopping stale keystore2, signaling VINTF ready..."
stop keystore2
sleep 1
setprop twrp.vintf.ready 1
log_msg "twrp.vintf.ready=1 signaled — init property trigger will start TEE chain"

# 6. Wait for keymint AIDL to register its interface, then start keystore2
# (keymint-mitee registers: android.hardware.security.keymint.IKeyMintDevice/default)
log_msg "Waiting for keymint AIDL registration (up to 30s)..."
WAIT=0
KEYMINT_READY=0
while [ $WAIT -lt 30 ]; do
    if service list 2>/dev/null | grep -q "IKeyMintDevice"; then
        log_msg "keymint AIDL registered after ${WAIT}s"
        KEYMINT_READY=1
        break
    fi
    sleep 1
    WAIT=$((WAIT + 1))
done

if [ $KEYMINT_READY -eq 1 ]; then
    log_msg "keymint ready — starting keystore2"
    start keystore2
else
    log_msg "WARNING: keymint AIDL not found after 30s, starting keystore2 anyway"
    start keystore2
fi

# 7. Diagnostics
log_msg "--- DIAGNOSTICS ---"
service list 2>/dev/null | grep -iE "keystore|keymint|secureclock|sharedsecret|gatekeeper"
ls -lZ /dev/tee* 2>/dev/null
getprop | grep -E 'init.svc.(tee|keystore|keymint|gatekeeper)|twrp|vintf|vold'
cat /metadata/vold/metadata_encryption/key/version 2>/dev/null \
    && log_msg "Metadata key version found" \
    || log_msg "No metadata key version file"

log_msg "--- TWRP PHASE 21 DEBUG BOOT END ---"

# 8. Persistence loop — lightweight, only restart critical services if they die
while true; do
    for svc in keymint-mitee gatekeeper-1-0; do
        if ! pgrep -f "$svc" > /dev/null 2>&1; then
            log_msg "RECOVERY: $svc missing, restarting..."
            start "$svc"
        fi
    done
    # Only restart keystore2 if keymint is confirmed running (prevents SIGSEGV loop)
    if ! pgrep -f "keystore2" > /dev/null 2>&1; then
        if pgrep -f "keymint" > /dev/null 2>&1; then
            log_msg "RECOVERY: keystore2 missing (keymint up), restarting..."
            start keystore2
        fi
    fi
    sleep 30
done
