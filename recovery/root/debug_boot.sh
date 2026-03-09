#!/system/bin/sh
# TWRP Debug Boot Script - Enhanced Diagnostic Version
LOGFILE="/tmp/debug_boot.log"

# Function to log to both file and kmsg
log_msg() {
    echo "$1"
    echo "$1" > /dev/kmsg
}

exec > $LOGFILE 2>&1

log_msg "--- TWRP ENHANCED DEBUG BOOT START ---"
date
id
getenforce

# --- 1. VINTF dynamic patching ---
log_msg "--- Waiting for Vendor Mount ---"
# Wait up to 10 seconds for real vendor partition to be mounted
TIMER=0
while [ ! -f /vendor/build.prop ] && [ $TIMER -lt 10 ]; do
    sleep 1
    TIMER=$((TIMER + 1))
done

if [ -f /vendor/etc/vintf/manifest_fixed.xml ]; then
    log_msg "Applying FULL VINTF override with manifest_fixed.xml..."
    # Copy our fixed manifest to tmp to ensure it's writable/bindable
    cp /vendor/etc/vintf/manifest_fixed.xml /tmp/manifest_custom.xml
    
    # Forcefully bind-mount over the real vendor manifest
    mount none /tmp/manifest_custom.xml /vendor/etc/vintf/manifest.xml bind
    log_msg "VINTF Override applied. Status: $?"
    
    # Restart managers to pick up the new manifest
    log_msg "Restarting service managers..."
    setprop hwservicemanager.ready false
    killall -9 hwservicemanager keystore2 servicemanager
    sleep 1
    setprop hwservicemanager.ready true
else
    log_msg "CRITICAL: /vendor/etc/vintf/manifest_fixed.xml not found!"
fi

# Check if we can run vintf_check (if present in TWRP)
if [ -x "/system/bin/vintf_check" ]; then
    vintf_check --check-help 2>/dev/null
fi

# --- 2. Linker & Library Environment ---
log_msg ""
log_msg "--- Library Paths & Environment ---"
log_msg "LD_LIBRARY_PATH: $LD_LIBRARY_PATH"
ls -ld /vendor/lib64 /vendor/lib64/hw /system/lib64
ls -l /vendor/lib64/hw/android.hardware.keymaster@4.0-impl.so 2>/dev/null
ls -l /vendor/lib64/hw/android.hardware.gatekeeper@1.0-impl.so 2>/dev/null

# --- 3. Partition & Mount Status ---
log_msg ""
log_msg "--- Partition & Mount Details ---"
mount | grep -E "persist|system|vendor|product|metadata|data|apex"
df -h | grep -v "tmpfs"

# --- 4. Service Manager Status ---
log_msg ""
log_msg "--- Service Managers (Binder/Hwbinder) ---"
ls -l /dev/binder /dev/vndbinder /dev/hwbinder
ps -A | grep -E "servicemanager|hwservicemanager|vndservicemanager"

# --- 5. TEE & Security Service Status ---
log_msg ""
log_msg "--- TEE / Security HALs ---"
ls -l /dev/tee* /dev/teepriv*
# Try to list services via cmd if available, otherwise use service list
service list | grep -iE "keystore|keymint|clock|secret|gatekeeper"

# --- 6. HIDL Service Detailed Check (lshal) ---
log_msg ""
log_msg "--- HIDL Service Registration (lshal) ---"
lshal --debug android.hardware.keymaster@4.0::IKeymasterDevice/default 2>/dev/null
lshal | grep -E "keymaster|gatekeeper|health|boot|vibrator"

# --- 7. Critical Logs ---
log_msg ""
log_msg "--- Last 50 Lines of Logcat (Errors) ---"
log_cat_check=$(logcat -d -L 2>/dev/null | tail -n 50)
if [ -n "$log_cat_check" ]; then
    log_msg "$log_cat_check"
fi
log_msg "--- Logcat Error Highlights ---"
log_msg "$(logcat -d *:E | tail -n 50)"

# --- 7b. Check Keystore Directory ---
log_msg ""
log_msg "--- Keystore Directory ---"
ls -ld /tmp/keystore
ls -l /tmp/keystore

# --- 8. Properties ---
log_msg ""
log_msg "--- Relevant Properties ---"
log_msg "$(getprop | grep -E 'crypto|vold|init.svc|hwserv|mitee|vendor.sys.listener')"

log_msg ""
log_msg "--- TWRP ENHANCED DEBUG BOOT END ---"

