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
# Disable SELinux early to ensure all diagnostic tools and mounts work
log_msg "Disabling SELinux Enforcement..."
setenforce 0
getenforce

# Reset the synchronization property to ensure any subsequent triggers re-fire
setprop twrp.vintf.ready 0
log_msg "Reset twrp.vintf.ready to 0"

# --- 1. VINTF dynamic patching (Complete Directory) ---
log_msg "--- Checking for VINTF override ---"

# Wait for /vendor/etc/vintf directory to exist
TIMER=0
while [ ! -d /vendor/etc/vintf ] && [ $TIMER -lt 15 ]; do
    sleep 1
    TIMER=$((TIMER + 1))
done

if [ -d /vendor/etc/vintf ]; then
    log_msg "Applying comprehensive VINTF overrides..."
    
    # 1. Create a writable copy of the VINTF directory in /tmp
    mkdir -p /tmp/vintf
    cp -rf /vendor/etc/vintf/* /tmp/vintf/
    
    # 2. Use sed to patch version 5.0 -> 4.0 in ALL files in our copy
    # This catches the main manifest and any fragments (e.g. manifest_c3vinl.xml)
    find /tmp/vintf -type f -name "*.xml" -exec sed -i 's/version="5.0"/version="4.0"/g' {} +
    
    # 3. Bind-mount our patched directory over the original
    mount -o bind /tmp/vintf /vendor/etc/vintf
    log_msg "Bind-mount /tmp/vintf over /vendor/etc/vintf status: $?"

    # Also patch /vendor/manifest.xml if it exists at root
    if [ -f /vendor/manifest.xml ]; then
        sed 's/version="5.0"/version="4.0"/g' /vendor/manifest.xml > /tmp/vendor_manifest.xml
        mount -o bind /tmp/vendor_manifest.xml /vendor/manifest.xml
        log_msg "Bind-mount /tmp/vendor_manifest.xml status: $?"
    fi

    # 4. Create writable Keystore2 directory
    log_msg "Setting up /tmp/keystore..."
    mkdir -p /tmp/keystore
    chown 1000:1000 /tmp/keystore
    chmod 0700 /tmp/keystore

    # 5. Signal that VINTF is patched
    setprop twrp.vintf.ready 1
    log_msg "Property twrp.vintf.ready set to 1."

    # 6. Kill services to force reload
    # We do this BEFORE manual starts to ensure init doesn't have stale handles
    pkill -9 keystore2
    pkill -9 android.hardware.security.keymint
    pkill -9 android.hardware.gatekeeper
    pkill -9 tee-supplicant
    pkill -9 mitee_supplicant
    pkill -9 vndservicemanager
    log_msg "Restarted security services after VINTF patch."
else
    log_msg "CRITICAL: /vendor/etc/vintf not found! Signaling ready anyway."
    setprop twrp.vintf.ready 1
fi
        export LD_LIBRARY_PATH=/vendor/lib64:/vendor/lib:/system/lib64:/system/lib:/sbin
        
        # Correct path for KeyMint mitee
        KEYMINT_BIN="/vendor/bin/hw/android.hardware.security.keymint@2.0-service.mitee"
        if [ -f "$KEYMINT_BIN" ]; then
            $KEYMINT_BIN > /tmp/keymint_exec.log 2>&1 &
        else
            log_msg "ERROR: KeyMint binary not found at $KEYMINT_BIN"
        fi
        
        /system/bin/keystore2 /tmp/keystore > /tmp/keystore2_exec.log 2>&1 &
        /vendor/bin/hw/android.hardware.gatekeeper@1.0-service > /tmp/gatekeeper_exec.log 2>&1 &
        
        # Try both common supplicant names
        if [ -f /vendor/bin/tee-supplicant ]; then
            /vendor/bin/tee-supplicant > /tmp/tee_supplicant_exec.log 2>&1 &
        elif [ -f /vendor/bin/mitee_supplicant ]; then
            /vendor/bin/mitee_supplicant > /tmp/tee_supplicant_exec.log 2>&1 &
        fi
        
        sleep 2
        
        log_msg "--- KEYMINT EXEC LOG ---"
        log_msg "$(cat /tmp/keymint_exec.log 2>/dev/null)"
        log_msg "--- KEYSTORE2 EXEC LOG ---"
        log_msg "$(cat /tmp/keystore2_exec.log 2>/dev/null)"
        log_msg "--- TEE SUPPLICANT EXEC LOG ---"
        log_msg "$(cat /tmp/tee_supplicant_exec.log 2>/dev/null)"
        log_msg "------------------------"
        
        # Ensure SELinux is permissive before starting services
        setenforce 0
        
        # Explicitly start the security HALs just in case the property trigger is missed
        log_msg "Explicitly starting security HALs..."
        start tee-supplicant
        start gatekeeper-1-0
        start keymint-mitee
        start keystore2
        log_msg "Explicitly started security HALs."

    else
        log_msg "CRITICAL: /vendor/etc/vintf not found after 15s. Signaling ready anyway."
        setprop twrp.vintf.ready 1
    fi
else
    log_msg "CRITICAL: /manifest_fixed.xml not found! Skipping VINTF patch."
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

# --- 9. PERSISTENCE LOOP ---
# Init kills backgrounded services in a oneshot process group when the script exits.
# We keep this script alive indefinitely to protect our HALs.
log_msg "Entering persistence loop to prevent service termination..."
while true; do
    # Periodic check to see if critical services are still alive
    if ! pgrep -f "keystore2" > /dev/null; then
        log_msg "WARNING: keystore2 died, attempting restart..."
        start keystore2
    fi
    sleep 60
done

