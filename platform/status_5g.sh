#!/bin/bash
# ============================================================
# 5G Core Platform Status Check
# ============================================================
echo "============================================"
echo "  5G Platform Status"
echo "============================================"

echo ""
echo "Core NFs (amf-smf container):"
COUNT=$(incus exec amf-smf -- ps aux | grep open5gs | grep -v grep | wc -l)
echo "  Running: $COUNT/9 NFs"
incus exec amf-smf -- ps aux | grep open5gs | grep -v grep | awk '{print "  - " $11}' | sed 's/ -c.*//'

echo ""
echo "UPF Status:"
for c in upf1 upf2 upf3; do
  STATUS=$(incus exec $c -- ps aux | grep open5gs-upfd | grep -v grep | wc -l)
  if [ "$STATUS" -gt "0" ]; then
    echo "  $c: RUNNING"
  else
    echo "  $c: STOPPED"
  fi
done

echo ""
echo "UERANSIM Status:"
GNB=$(incus exec gnb-ue -- ps aux | grep nr-gnb | grep -v grep | wc -l)
UE=$(incus exec gnb-ue -- ps aux | grep nr-ue | grep -v grep | wc -l)
echo "  gNB: $([ $GNB -gt 0 ] && echo 'RUNNING' || echo 'STOPPED')"
echo "  UE:  $([ $UE -gt 0 ] && echo 'RUNNING' || echo 'STOPPED')"

echo ""
echo "Container IPs:"
incus list --format csv | awk -F',' '{printf "  %-10s %s\n", $1, $4}'
echo "============================================"
