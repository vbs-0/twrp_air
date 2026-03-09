#!/system/bin/sh
# TWRP Debug Boot Script
LOGFILE="/tmp/debug_boot.log"
exec > $LOGFILE 2>&1

echo "--- Debug Boot Log Start ---"
date
id
getenforce

echo ""
echo "--- Mount Points ---"
mount | grep -E "persist|system|vendor|product|metadata|data"

echo ""
echo "--- Persist Partition Check ---"
ls -laR /mnt/vendor/persist

echo ""
echo "--- Device Nodes (Binder/TEE) ---"
ls -l /dev/tee* /dev/teepriv* /dev/binder* /dev/vndbinder* /dev/hwbinder*

echo ""
echo "--- System Properties ---"
getprop | grep -E "crypto|hwserv|keymaster|keymint|vold|init.svc"

echo ""
echo "--- AIDL Services ---"
service list | grep -E "keymint|keystore|sharedsecret|secureclock"

echo ""
echo "--- HIDL Services (lshal) ---"
lshal | grep -E "keymaster|gatekeeper|health|boot"

echo ""
echo "--- Process List ---"
ps -A | grep -E "keystore|keymint|tee-supplicant|gatekeeper|hwservicemanager|servicemanager"

echo ""
echo "--- Debug Boot Log End ---"
