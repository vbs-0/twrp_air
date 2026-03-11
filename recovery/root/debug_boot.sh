#!/system/bin/sh
set -x
# TWRP Debug Boot Script - @vbs_1 & @dream_7x - Final-Success
LOGFILE="/tmp/debug_boot.log"

log_msg() {
    echo "$1"
    echo "$1" > /dev/kmsg
}

insmod_safe() {
    local mod="$1"
    local name=$(basename $mod .ko)
    if lsmod | grep -q "^${name} "; then
        log_msg "Touch: $name already loaded"
        return 0
    fi
    if [ ! -f "$mod" ]; then
        log_msg "Touch: ERROR - $mod not found!"
        return 1
    fi
    insmod "$mod" 2>&1
    if lsmod | grep -q "^${name} "; then
        log_msg "Touch: $name loaded"
        return 0
    else
        log_msg "Touch: ERROR loading $name"
        return 1
    fi
}

modprobe_safe() {
    local name="$1"
    if lsmod | grep -q "^${name} "; then
        log_msg "Touch: $name already loaded"
        return 0
    fi
    modprobe "$name" 2>&1
    if lsmod | grep -q "^${name} "; then
        log_msg "Touch: $name loaded via modprobe"
        return 0
    else
        log_msg "Touch: ERROR modprobing $name"
        return 1
    fi
}

exec > $LOGFILE 2>&1

log_msg "--- TWRP @vbs_1 & @dream_7x DEBUG BOOT START ---"
date
id

# 0. Force SELinux Permissive and keep it that way
log_msg "Forcing SELinux Permissive..."
setenforce 0
getenforce

# 0.5 Universal Decryption: Property Detection
log_msg "Detecting OS version via properties..."

# Wait a maximum of 2 seconds for vendor properties to be read by init
V_WAIT=0
while [ -z "$(getprop ro.vendor.build.version.release)" ] && [ $V_WAIT -lt 2 ]; do
    log_msg "Waiting for vendor props... (${V_WAIT}s)"
    sleep 1
    V_WAIT=$((V_WAIT + 1))
done

OS_VER=$(getprop ro.vendor.build.version.release)
if [ ! -z "$OS_VER" ]; then
    log_msg "Detected OS version: $OS_VER"
    if [ "$OS_VER" = "15" ]; then
        log_msg "Android 15 detected! Overriding properties..."
        resetprop ro.build.version.release 15
        resetprop ro.build.version.release_or_codename 15
        resetprop ro.vendor.build.version.release 15
        resetprop ro.system.build.version.release 15
    fi
else
    log_msg "Warning: Vendor props not found. Using defaults."
fi

# Ensure filesystem is ready and stable
sleep 1

log_msg "--- Loading essential touch stack ---"
# Load SCP (Sensor Core Processor) and Audio Front End (Dependencies)
insmod_safe /lib/modules/scp.ko
insmod_safe /lib/modules/mtk-afe-external.ko

# Touch Layer
insmod_safe /lib/modules/lct_tp.ko
insmod_safe /lib/modules/hf_manager.ko
insmod_safe /lib/modules/xiaomi_tp.ko
modprobe_safe nt36528_spi

log_msg "Touch stack loading sequence finished."

# Ensure utilities are executable
chmod 755 /system/bin/mtk_plpath_utils

# 1. Fix Block Device Paths
log_msg "Fixing block device paths..."
mkdir -p /dev/block/platform/bootdevice/by-name/
chcon u:object_r:block_device:s0 /dev/block/platform/bootdevice/by-name/ 2>/dev/null

for part in preloader_raw_a preloader_raw_b; do
    if [ ! -L /dev/block/platform/bootdevice/by-name/$part ]; then
        ln -s /dev/block/by-name/$part /dev/block/platform/bootdevice/by-name/$part 2>/dev/null
    fi
done

# 2. TEE nodes permissions
log_msg "Waiting for TEE device nodes..."
TIMER=0
while [ ! -c /dev/teepriv0 ] && [ $TIMER -lt 5 ]; do
    sleep 1
    TIMER=$((TIMER + 1))
done

if [ -c /dev/teepriv0 ]; then
    log_msg "Found TEE nodes — setting perms"
    chmod 0666 /dev/teepriv0 /dev/tee0 2>/dev/null
    chown system:system /dev/teepriv0 /dev/tee0 2>/dev/null
    ls -lZ /dev/teepriv0 /dev/tee0
fi

# 3. VINTF patching (Version 4.0 compatibility)
log_msg "Applying VINTF overrides..."
if [ -d /vendor/etc/vintf ]; then
    mkdir -p /tmp/vintf
    cp -rf /vendor/etc/vintf/* /tmp/vintf/
    find /tmp/vintf -type f -name "*.xml" -exec sed -i 's/version="5.0"/version="4.0"/g' {} +
    chmod -R 755 /tmp/vintf
    chown -R system:system /tmp/vintf
    mount -o bind /tmp/vintf /vendor/etc/vintf
fi

# 4. Stop early services, signal VINTF ready
# This will trigger the TEE chain startup in recovery.rc
log_msg "Stopping stale services, signaling VINTF ready..."
stop keystore2
stop gatekeeper-1-0
stop keymint-mitee
setprop twrp.vintf.ready 1

# 5. Wait for keymint AIDL to register, then start keystore2 (BACKGROUNDED)
# (keymint-mitee registers: android.hardware.security.keymint.IKeyMintDevice/default)
log_msg "Backgrounding keymint AIDL wait to bypass watchdog..."
(
    WAIT=0
    while [ $WAIT -lt 30 ]; do
        if service list 2>/dev/null | grep -q "IKeyMintDevice"; then
            log_msg "keymint AIDL registered after ${WAIT}s"
            break
        fi
        sleep 1
        WAIT=$((WAIT + 1))
    done

    # Start keystore2 - it will use /tmp/misc/keystore (standard TWRP staging)
    log_msg "Starting keystore2..."
    start keystore2
) &

# 6. Thermal & Health Fixes
# log_msg "Setting thermal permissions for UI..."
# chmod 0666 /sys/class/thermal/thermal_zone*/temp 2>/dev/null

# 7. Diagnostics
log_msg "--- DIAGNOSTICS ---"
getprop | grep -E 'init.svc.(tee|keystore|keymint|gatekeeper)|twrp|vintf|vold'

log_msg "--- TWRP DEBUG BOOT SYNC END ---"
exit 0
# Persistence loop disabled to prevent instability
# (Service monitoring should be handled by init.recovery.rc triggers)
