#!/system/bin/sh
# TWRP Debug Boot Script - Enhanced Diagnostic Version
LOGFILE="/tmp/debug_boot.log"
exec > $LOGFILE 2>&1

echo "--- TWRP ENHANCED DEBUG BOOT START ---"
date
id
getenforce

# --- 1. VINTF dynamic patching ---
echo ""
echo "--- Waiting for Vendor Mount ---"
# Wait up to 10 seconds for real vendor partition to be mounted
TIMER=0
while [ ! -f /vendor/build.prop ] && [ $TIMER -lt 10 ]; do
    sleep 1
    TIMER=$((TIMER + 1))
done

if [ -f /vendor/etc/vintf/manifest.xml ]; then
    echo "Patching real vendor manifest..."
    cp /vendor/etc/vintf/manifest.xml /tmp/manifest_real.xml
    # Resolve the 4.1 vs 4.0 conflict by forcing 4.0
    sed -i 's/version="4.1"/version="4.0"/g' /tmp/manifest_real.xml
    mount none /tmp/manifest_real.xml /vendor/etc/vintf/manifest.xml bind
    echo "VINTF Patch applied. Status: $?"
    
    # Restart managers ONE LAST TIME to pick up the patched manifest
    echo "Restarting service managers for the final time..."
    setprop hwservicemanager.ready false
    killall -9 hwservicemanager keystore2 servicemanager
    # These will be restarted by init because they are not 'disabled'
else
    echo "CRITICAL: Vendor manifest not found even after wait!"
    # Fallback to our hardcoded fixed manifest
    mount none /vendor/etc/vintf/manifest_fixed.xml /vendor/etc/vintf/manifest.xml bind
fi

# Check if we can run vintf_check (if present in TWRP)
if [ -x "/system/bin/vintf_check" ]; then
    vintf_check --check-help 2>/dev/null
fi

# --- 2. Linker & Library Environment ---
echo ""
echo "--- Library Paths & Environment ---"
echo "LD_LIBRARY_PATH: $LD_LIBRARY_PATH"
ls -ld /vendor/lib64 /vendor/lib64/hw /system/lib64
ls -l /vendor/lib64/hw/android.hardware.keymaster@4.0-impl.so 2>/dev/null
ls -l /vendor/lib64/hw/android.hardware.gatekeeper@1.0-impl.so 2>/dev/null

# --- 3. Partition & Mount Status ---
echo ""
echo "--- Partition & Mount Details ---"
mount | grep -E "persist|system|vendor|product|metadata|data|apex"
df -h | grep -v "tmpfs"

# --- 4. Service Manager Status ---
echo ""
echo "--- Service Managers (Binder/Hwbinder) ---"
ls -l /dev/binder /dev/vndbinder /dev/hwbinder
ps -A | grep -E "servicemanager|hwservicemanager|vndservicemanager"

# --- 5. TEE & Security Service Status ---
echo ""
echo "--- TEE / Security HALs ---"
ls -l /dev/tee* /dev/teepriv*
# Try to list services via cmd if available, otherwise use service list
service list | grep -iE "keystore|keymint|clock|secret|gatekeeper"

# --- 6. HIDL Service Detailed Check (lshal) ---
echo ""
echo "--- HIDL Service Registration (lshal) ---"
lshal --debug android.hardware.keymaster@4.0::IKeymasterDevice/default 2>/dev/null
lshal | grep -E "keymaster|gatekeeper|health|boot|vibrator"

# --- 7. Critical Logs ---
echo ""
echo "--- Last 50 Lines of Logcat (Errors) ---"
logcat -d -L | tail -n 50 2>/dev/null # Previous boot logs if available
logcat -d *:E | tail -n 50

# --- 8. Properties ---
echo ""
echo "--- Relevant Properties ---"
getprop | grep -E "crypto|vold|init.svc|hwserv|mitee|vendor.sys.listener"

echo ""
echo "--- TWRP ENHANCED DEBUG BOOT END ---"

