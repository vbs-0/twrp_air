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

# --- 1. VINTF dynamic patching ---
log_msg "--- Checking for VINTF override ---"

# The manifest_fixed.xml should be in the root of the ramdisk (/)
# to avoid being hidden by the /vendor mount.
if [ -f /manifest_fixed.xml ]; then
    log_msg "Found /manifest_fixed.xml. Waiting for /vendor/etc/vintf to be ready..."
    
    # Wait for /vendor/etc/vintf directory to exist
    TIMER=0
    while [ ! -d /vendor/etc/vintf ] && [ $TIMER -lt 15 ]; do
        sleep 1
        TIMER=$((TIMER + 1))
    done
    
    if [ -d /vendor/etc/vintf ]; then
        log_msg "Applying VINTF overrides surgically..."
        
        # 1. Overlay /vendor/etc/vintf using tmpfs to avoid breaking /odm symlinks
        # Check if /odm is a symlink to /vendor/odm
        if [ -L /odm ]; then
            log_msg "/odm is a symlink: $(ls -ld /odm)"
        fi

        # Use a more targeted approach. If we can't mount tmpfs safely, we just try to bind-mount the files.
        # But tmpfs is usually better if it doesn't break underlying links.
        # To be safe, we only patch the EXACT files we need.
        
        # Patch /vendor/etc/vintf/manifest.xml
        if [ -f /vendor/etc/vintf/manifest.xml ]; then
            mount -o bind /manifest_fixed.xml /vendor/etc/vintf/manifest.xml
            log_msg "Bind-mount /vendor/etc/vintf/manifest.xml status: $?"
        fi

        # Patch /vendor/manifest.xml
        if [ -f /vendor/manifest.xml ]; then
            mount -o bind /manifest_fixed.xml /vendor/manifest.xml
            log_msg "Bind-mount /vendor/manifest.xml status: $?"
        fi

        # 2. Patch /odm/etc/vintf/manifest_c3vinl.xml to prevent the "Too many symbolic links" error
        # If the error is "Too many symbolic links", it means the system is chasing a loop.
        # We can try to bind-mount our manifest over the problematic ODM manifest too.
        if [ -f /odm/etc/vintf/manifest_c3vinl.xml ]; then
            mount -o bind /manifest_fixed.xml /odm/etc/vintf/manifest_c3vinl.xml
            log_msg "Bind-mount /odm/etc/vintf/manifest_c3vinl.xml status: $?"
        fi

        # 3. Create writable Keystore2 directory
        log_msg "Setting up /tmp/keystore..."
        mkdir -p /tmp/keystore
        chown 1000:1000 /tmp/keystore
        chmod 0700 /tmp/keystore

        # 4. Synchronize: Signal that VINTF is patched
        setprop twrp.vintf.ready 1
        log_msg "Property twrp.vintf.ready set to 1."

        # 5. Restart managers AND security HALs to pick up new manifest and binder context
        log_msg "Restarting service managers and security HALs..."
        # Kill both managers and the actual HAL services so init restarts them all
        killall -9 hwservicemanager keystore2 servicemanager tee-supplicant keymint-mitee gatekeeper-1-0
        sleep 2
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

