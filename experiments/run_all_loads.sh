#!/usr/bin/env bash
# =============================================================================
# run_all_loads.sh — Run all 3 load conditions sequentially for O1
# Akhil's PhD: Intelligent Latency-Aware UPF Orchestration | MNNIT Allahabad
#
# Usage: sudo bash run_all_loads.sh [DURATION_SEC]
#   sudo bash run_all_loads.sh 120
# =============================================================================
DURATION="${1:-120}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================"
echo "  O1 Full Data Collection — All Load Conditions"
echo "  Duration per run: ${DURATION}s"
echo "  Start: $(date)"
echo "============================================"

# ── UE3 health check and restart ─────────────────────────────────────────────
check_ue3() {
    echo "[UE3] Checking mMTC tunnel..."
    # Check if uesimtun2 has a 10.43.x.x IP
    UE3_IP=$(incus exec gnb-ue -- bash -c \
        "ip addr show uesimtun2 2>/dev/null | grep 'inet 10\.43\.' | awk '{print \$2}' | cut -d/ -f1")

    if [ -n "$UE3_IP" ]; then
        # Check reachability
        if incus exec gnb-ue -- ping -c 1 -W 3 -I uesimtun2 10.43.0.1 \
                > /dev/null 2>&1; then
            echo "[UE3] OK — $UE3_IP reachable"
            return 0
        fi
    fi

    echo "[UE3] Session lost — restarting nr-ue3..."
    # Kill any stale UE3 processes
    incus exec gnb-ue -- bash -c "pkill -f 'nr-ue.*ue3' 2>/dev/null; sleep 2" || true

    # Restart via tmux pane 3
    incus exec gnb-ue -- bash -c \
        "nohup /root/UERANSIM/build/nr-ue -c /root/UERANSIM/config/ue3.yaml \
        > /tmp/ue3_restart.log 2>&1 &"
    sleep 10

    # Verify
    if incus exec gnb-ue -- ping -c 2 -W 3 -I uesimtun2 10.43.0.1 \
            > /dev/null 2>&1; then
        echo "[UE3] Restarted successfully"
        return 0
    else
        echo "[UE3] WARNING: restart may have failed — check tmux pane 3"
        return 1
    fi
}

# ── Keepalive during cooling ──────────────────────────────────────────────────
keepalive_ue3() {
    local secs=$1
    echo "[UE3] Keepalive ping for ${secs}s cooling period..."
    local end=$(( $(date +%s) + secs ))
    while [ $(date +%s) -lt $end ]; do
        incus exec gnb-ue -- ping -c 1 -W 2 -I uesimtun2 10.43.0.1 \
            > /dev/null 2>&1 || true
        sleep 3
    done
    echo "[UE3] Cooling complete"
}

# ── Main loop ─────────────────────────────────────────────────────────────────
for LOAD in light medium heavy; do
    echo ""
    echo ">>> Checking UE3 before ${LOAD} run..."
    check_ue3

    echo ""
    echo ">>> Starting: ${LOAD} load ($(date))"
    sudo bash "${SCRIPT_DIR}/run_experiment_${LOAD}.sh" "${DURATION}" "exp_${LOAD}"
    echo ">>> Completed: ${LOAD}."

    if [ "$LOAD" != "heavy" ]; then
        echo ">>> Cooling 30s with UE3 keepalive..."
        keepalive_ue3 30
    fi
done

echo ""
echo "============================================"
echo "  ALL RUNS COMPLETE at $(date)"
echo "  Results in /storage/student2/traces/dataset/"
ls -lh /storage/student2/traces/dataset/o1_cdf_exp_light.png \
        /storage/student2/traces/dataset/o1_cdf_exp_medium.png \
        /storage/student2/traces/dataset/o1_cdf_exp_heavy.png 2>/dev/null
echo "============================================"
