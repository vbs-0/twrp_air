#!/system/bin/sh
set -x
# TWRP Debug Boot Script - Phase 19 High-Stability Version
LOGFILE="/tmp/debug_boot.log"

# Function to log to both file and kmsg
log_msg() {
    echo "$1"
    echo "$1" > /dev/kmsg
}

exec > $LOGFILE 2>&1

log_msg "--- TWRP PHASE 19 DEBUG BOOT START ---"
date
id

# 0. Disable SELinux IMMEDIATELY
log_msg "Forcing SELinux Permissive..."
setenforce 0
getenforce

# 1. Fix Block Device Paths (Critical for mtk_plpath_utils)
log_msg "Fixing block device paths..."
mkdir -p /dev/block/platform/bootdevice/by-name/
# Ensure the parent directory is reachable and labeled
chcon u:object_r:block_device:s0 /dev/block/platform/bootdevice/by-name/

# Link existing nodes if they are missing from the bootdevice path
for part in preloader_raw_a preloader_raw_b; do
    if [ ! -L /dev/block/platform/bootdevice/by-name/$part ]; then
        log_msg "Creating symlink for $part..."
        ln -s /dev/block/by-name/$part /dev/block/platform/bootdevice/by-name/$part 2>/dev/null
        chcon -h u:object_r:preloader_block_device:s0 /dev/block/platform/bootdevice/by-name/$part 2>/dev/null
    fi
done

# 2. Wait and Relabel TEE Nodes (Robust Loop)
log_msg "Waiting for TEE device nodes..."
TIMER=0
while [ ! -c /dev/teepriv0 ] && [ $TIMER -lt 15 ]; do
    log_msg "Still waiting for /dev/teepriv0 ($TIMER)..."
    sleep 1
    TIMER=$((TIMER + 1))
done

if [ -c /dev/teepriv0 ]; then
    log_msg "Found /dev/teepriv0, applying working system label (mitee_client_device)..."
    # IMPORTANT: The normal system uses mitee_client_device, not tee_device
    chcon u:object_r:mitee_client_device:s0 /dev/teepriv0 /dev/tee0 2>/dev/null
    chmod 0666 /dev/teepriv0 /dev/tee0 2>/dev/null
    chown system:system /dev/teepriv0 /dev/tee0 2>/dev/null
    ls -lZ /dev/teepriv0 /dev/tee0
else
    log_msg "WARNING: TEE nodes not found after 15s"
fi

# 3. VINTF dynamic patching
log_msg "--- Checking for VINTF override ---"
if [ -d /vendor/etc/vintf ]; then
    log_msg "Applying comprehensive VINTF overrides..."
    mkdir -p /tmp/vintf
    cp -rf /vendor/etc/vintf/* /tmp/vintf/
    find /tmp/vintf -type f -name "*.xml" -exec sed -i 's/version="5.0"/version="4.0"/g' {} +
    mount -o bind /tmp/vintf /vendor/etc/vintf
    log_msg "Bind-mount /tmp/vintf over /vendor/etc/vintf status: $?"

    # Also patch /vendor/manifest.xml if it exists at root
    if [ -f /vendor/manifest.xml ]; then
        sed 's/version="5.0"/version="4.0"/g' /vendor/manifest.xml > /tmp/vendor_manifest.xml
        mount -o bind /tmp/vendor_manifest.xml /vendor/manifest.xml
        log_msg "Bind-mount /tmp/vendor_manifest.xml status: $?"
    fi

    # 4. Keystore2 Setup
    log_msg "Setting up /tmp/keystore..."
    mkdir -p /tmp/keystore
    chown system:system /tmp/keystore
    chmod 0775 /tmp/keystore

    # 5. Fix Entrypoints and Binary Contexts
    log_msg "Fixing binary contexts..."
    chcon u:object_r:update_engine_exec:s0 /system/bin/mtk_plpath_utils 2>/dev/null
    chcon u:object_r:recovery_exec:s0 /vendor/bin/hw/android.hardware.security.keymint@2.0-service.mitee 2>/dev/null
    chcon u:object_r:recovery_exec:s0 /system/bin/keystore2 2>/dev/null
    chcon u:object_r:recovery_exec:s0 /vendor/bin/tee-supplicant 2>/dev/null
    
    # 6. Signal VINTF ready and RESTART HALs via init
    setprop twrp.vintf.ready 1
    log_msg "Restarting core security services..."
    
    # Stop them first to ensure clean state
    stop keystore2
    stop keymint-mitee
    stop gatekeeper-1-0
    stop tee-supplicant
    
    # Kill any stray processes
    pkill -9 keystore2
    pkill -9 tee-supplicant
    
    sleep 1
    
    # Start via init triggers (matches dependency logic in rc)
    start tee-supplicant
    start gatekeeper-1-0
    start keymint-mitee
    start keystore2
fi

# Linker path verification
export LD_LIBRARY_PATH=/vendor/lib64:/vendor/lib:/system/lib64:/system/lib:/sbin
log_msg "Environment ready. Diagnostics follow..."

# --- 7. Diagnostics ---
lshal | grep -E "keymaster|gatekeeper|health|boot|vibrator"
service list | grep -iE "keystore|keymint|clock|secret|gatekeeper"
ls -l /dev/tee* /dev/teepriv*
getprop | grep -E 'crypto|vold|init.svc|hwserv|mitee|vintf'

log_msg "--- TWRP PHASE 18 DEBUG BOOT END ---"

# --- 8. PERSISTENCE LOOP ---
while true; do
    # Check if critical services are running, attempt restart if init fails
    for svc in tee-supplicant keystore2 keymint-mitee gatekeeper-1-0; do
        if ! pgrep -f "$svc" > /dev/null; then
            echo "RECOVERY: $svc missing, starting..." > /dev/kmsg
            start "$svc"
        fi
    done
    sleep 30
done
