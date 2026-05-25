#!/bin/bash
# ============================================================
# 5G Core Platform Shutdown Script
# ============================================================
echo "Stopping 5G Platform..."

# Stop UERANSIM
incus exec gnb-ue -- bash -c "kill -9 \$(ps aux | grep -E 'nr-gnb|nr-ue' | grep -v grep | awk '{print \$2}') 2>/dev/null; echo 'UERANSIM stopped'"

# Stop UPFs
for c in upf1 upf2 upf3; do
  incus exec $c -- bash -c "kill -9 \$(ps aux | grep open5gs | grep -v grep | awk '{print \$2}') 2>/dev/null; echo '$c stopped'"
done

# Stop Core NFs
incus exec amf-smf -- bash -c "kill -9 \$(ps aux | grep open5gs | grep -v grep | awk '{print \$2}') 2>/dev/null; echo 'Core NFs stopped'"

echo "5G Platform stopped successfully!"
