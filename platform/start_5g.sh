#!/bin/bash
# ============================================================
# 5G Core Platform Startup Script
# MNNIT Allahabad - Akhil's UPF Orchestration Project
# Prof. Mayank Pandey | May 2026
# ============================================================
# Usage: bash start_5g.sh
# This script starts ALL daemons in background.
# After this script completes, open separate terminals for:
#   - Monitoring logs
#   - Running UEs (ue1/ue2/ue3)
#   - Research experiments
# ============================================================

echo "============================================"
echo "  5G Core Platform Startup"
echo "  MNNIT Allahabad - Open5GS + UERANSIM"
echo "============================================"

# --- Step 0: Ensure Incus daemon is running and containers are started ---
echo ""
echo "[0/5] Ensuring Incus daemon and containers are up..."

# Restart Incus daemon — required after reboot (daemon sometimes hangs on init)
systemctl restart incus
echo "  Incus daemon restarted."
sleep 8

# Start all containers (safe to call even if already running)
incus start amf-smf upf1 upf2 upf3 gnb-ue 2>/dev/null || true
echo "  Container start requested."
sleep 8

# Verify all 5 are RUNNING before proceeding
ALL_UP=1
for c in amf-smf upf1 upf2 upf3 gnb-ue; do
    STATE=$(incus list "$c" --format csv --columns s 2>/dev/null | head -1)
    if [[ "$STATE" != "RUNNING" ]]; then
        echo "  WARNING: $c is $STATE — retrying..."
        incus start "$c" 2>/dev/null || true
        sleep 5
        STATE=$(incus list "$c" --format csv --columns s 2>/dev/null | head -1)
        [[ "$STATE" != "RUNNING" ]] && { echo "  ERROR: $c failed to start. Aborting."; exit 1; }
    fi
    echo "  $c: RUNNING ✓"
done
echo ""

# --- Step 1: Start Core NFs in amf-smf container ---
echo ""
echo "[1/5] Starting Core Network Functions in amf-smf..."
incus exec amf-smf -- bash -c "
kill -9 \$(ps aux | grep open5gs | grep -v grep | awk '{print \$2}') 2>/dev/null
sleep 1
open5gs-nrfd  -c /etc/open5gs/nrf.yaml  > /var/log/open5gs/nrf.log  2>&1 & sleep 2
open5gs-udrd  -c /etc/open5gs/udr.yaml  > /var/log/open5gs/udr.log  2>&1 & sleep 1
open5gs-ausfd -c /etc/open5gs/ausf.yaml > /var/log/open5gs/ausf.log 2>&1 & sleep 1
open5gs-udmd  -c /etc/open5gs/udm.yaml  > /var/log/open5gs/udm.log  2>&1 & sleep 1
open5gs-pcfd  -c /etc/open5gs/pcf.yaml  > /var/log/open5gs/pcf.log  2>&1 & sleep 1
open5gs-nssfd -c /etc/open5gs/nssf.yaml > /var/log/open5gs/nssf.log 2>&1 & sleep 1
open5gs-bsfd  -c /etc/open5gs/bsf.yaml  > /var/log/open5gs/bsf.log  2>&1 & sleep 1
open5gs-amfd  -c /etc/open5gs/amf.yaml  > /var/log/open5gs/amf.log  2>&1 & sleep 2
open5gs-smfd  -c /etc/open5gs/smf.yaml  > /var/log/open5gs/smf.log  2>&1 & sleep 3
echo '  Core NFs running:' \$(ps aux | grep open5gs | grep -v grep | wc -l) '/9'
"

# --- Step 2: Start UPF1 (eMBB/Internet) ---
echo ""
echo "[2/5] Starting UPF1 (eMBB - Internet Slice, 10.41.0.0/16)..."
incus exec upf1 -- bash -c "
kill -9 \$(ps aux | grep open5gs | grep -v grep | awk '{print \$2}') 2>/dev/null
sleep 1
sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
ip link set ogstun up 2>/dev/null
ip addr flush dev ogstun 2>/dev/null
ip addr add 10.41.0.1/16 dev ogstun 2>/dev/null
iptables -t nat -F 2>/dev/null
iptables -F FORWARD 2>/dev/null
iptables -t nat -A POSTROUTING -s 10.41.0.0/16 -o eth0 -j MASQUERADE
iptables -A FORWARD -i ogstun -o eth0 -j ACCEPT
iptables -A FORWARD -i eth0 -o ogstun -m state --state RELATED,ESTABLISHED -j ACCEPT
open5gs-upfd -c /etc/open5gs/upf.yaml > /var/log/open5gs/upf.log 2>&1 &
sleep 3
echo '  UPF1:' \$(ps aux | grep open5gs-upfd | grep -v grep | wc -l) 'process(es) running'
"

# --- Step 3: Start UPF2 (URLLC/VoIP) ---
echo ""
echo "[3/5] Starting UPF2 (URLLC - VoIP Slice, 10.42.0.0/16)..."
incus exec upf2 -- bash -c "
kill -9 \$(ps aux | grep open5gs | grep -v grep | awk '{print \$2}') 2>/dev/null
sleep 1
sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
ip link set ogstun up 2>/dev/null
ip addr flush dev ogstun 2>/dev/null
ip addr add 10.42.0.1/16 dev ogstun 2>/dev/null
iptables -t nat -F 2>/dev/null
iptables -F FORWARD 2>/dev/null
iptables -t nat -A POSTROUTING -s 10.42.0.0/16 -o eth0 -j MASQUERADE
iptables -A FORWARD -i ogstun -o eth0 -j ACCEPT
iptables -A FORWARD -i eth0 -o ogstun -m state --state RELATED,ESTABLISHED -j ACCEPT
open5gs-upfd -c /etc/open5gs/upf.yaml > /var/log/open5gs/upf.log 2>&1 &
sleep 3
echo '  UPF2:' \$(ps aux | grep open5gs-upfd | grep -v grep | wc -l) 'process(es) running'
"

# --- Step 4: Start UPF3 (mMTC/Streaming) ---
echo ""
echo "[4/5] Starting UPF3 (mMTC - Streaming Slice, 10.43.0.0/16)..."
incus exec upf3 -- bash -c "
kill -9 \$(ps aux | grep open5gs | grep -v grep | awk '{print \$2}') 2>/dev/null
sleep 1
sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
ip link set ogstun up 2>/dev/null
ip addr flush dev ogstun 2>/dev/null
ip addr add 10.43.0.1/16 dev ogstun 2>/dev/null
iptables -t nat -F 2>/dev/null
iptables -F FORWARD 2>/dev/null
iptables -t nat -A POSTROUTING -s 10.43.0.0/16 -o eth0 -j MASQUERADE
iptables -A FORWARD -i ogstun -o eth0 -j ACCEPT
iptables -A FORWARD -i eth0 -o ogstun -m state --state RELATED,ESTABLISHED -j ACCEPT
open5gs-upfd -c /etc/open5gs/upf.yaml > /var/log/open5gs/upf.log 2>&1 &
sleep 3
echo '  UPF3:' \$(ps aux | grep open5gs-upfd | grep -v grep | wc -l) 'process(es) running'
"

# --- Step 5: Start gNodeB ---
echo ""
echo "[5/5] Starting gNodeB (UERANSIM)..."
incus exec gnb-ue -- bash -c "
kill -9 \$(ps aux | grep nr-gnb | grep -v grep | awk '{print \$2}') 2>/dev/null
sleep 1
cd /root/UERANSIM
nohup ./build/nr-gnb -c config/gnb.yaml > /tmp/gnb.log 2>&1 &
sleep 3
echo '  gNB:' \$(ps aux | grep nr-gnb | grep -v grep | wc -l) 'process(es) running'
"

# --- Final Status ---
echo ""
echo "============================================"
echo "  Platform Status Summary"
echo "============================================"
echo ""
echo "  Core NFs (amf-smf):"
NF=$(incus exec amf-smf -- ps aux | grep open5gs | grep -v grep | wc -l)
echo "    Running: $NF/9 NFs"
echo ""
echo "  UPF Status:"
for c in upf1 upf2 upf3; do
  S=$(incus exec $c -- ps aux | grep open5gs-upfd | grep -v grep | wc -l)
  if [ "$S" -gt "0" ]; then
    echo "    $c: RUNNING ✓"
  else
    echo "    $c: STOPPED ✗"
  fi
done
echo ""
echo "  gNB Status:"
GNB=$(incus exec gnb-ue -- ps aux | grep nr-gnb | grep -v grep | wc -l)
if [ "$GNB" -gt "0" ]; then
  echo "    gNB: RUNNING ✓"
else
  echo "    gNB: STOPPED ✗"
fi
echo ""
echo "============================================"
echo "  Platform is READY!"
echo ""
echo "  To start a UE (open a new terminal):"
echo ""
echo "  UE1 (eMBB/internet):"
echo "  incus exec gnb-ue -- bash -c 'cd /root/UERANSIM && ./build/nr-ue -c config/ue1.yaml'"
echo ""
echo "  UE2 (URLLC/VoIP):"
echo "  incus exec gnb-ue -- bash -c 'cd /root/UERANSIM && ./build/nr-ue -c config/ue2.yaml'"
echo ""
echo "  UE3 (mMTC/Streaming):"
echo "  incus exec gnb-ue -- bash -c 'cd /root/UERANSIM && ./build/nr-ue -c config/ue3.yaml'"
echo ""
echo "  Test connectivity:"
echo "  incus exec gnb-ue -- ping -c 3 -I uesimtun0 8.8.8.8"
echo ""
echo "  To stop platform:"
echo "  bash /storage/student2/scripts/stop_5g.sh"
echo "============================================"

# Restore data plane (ogstun + NAT) — lost on every reboot
for upf in upf1 upf2 upf3; do
    incus exec $upf -- ip link set ogstun up 2>/dev/null || true
done
incus exec upf1 -- ip addr add 10.41.0.1/16 dev ogstun 2>/dev/null || true
incus exec upf2 -- ip addr add 10.42.0.1/16 dev ogstun 2>/dev/null || true
incus exec upf3 -- ip addr add 10.43.0.1/16 dev ogstun 2>/dev/null || true
incus exec upf1 -- bash -c "sysctl -w net.ipv4.ip_forward=1; iptables -t nat -A POSTROUTING -s 10.41.0.0/16 -o eth0 -j MASQUERADE" 2>/dev/null || true
incus exec upf2 -- bash -c "sysctl -w net.ipv4.ip_forward=1; iptables -t nat -A POSTROUTING -s 10.42.0.0/16 -o eth0 -j MASQUERADE" 2>/dev/null || true
incus exec upf3 -- bash -c "sysctl -w net.ipv4.ip_forward=1; iptables -t nat -A POSTROUTING -s 10.43.0.0/16 -o eth0 -j MASQUERADE" 2>/dev/null || true
