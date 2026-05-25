#!/usr/bin/env bash
# =============================================================================
# run_experiment_light.sh — O1 Experiment with TC-BPF instrumentation
# Akhil's PhD: Intelligent Latency-Aware UPF Orchestration | MNNIT Allahabad
#
# Architecture:
#   M1: TC ingress BPF on each UPF's eth0  → bpf_trace_printk → trace_pipe
#   M3: TC egress  BPF on each UPF's ogstun → bpf_trace_printk → trace_pipe
#   M2: bpftrace syscall probes on SMF (PFCP latency, unchanged)
#
# Usage: sudo bash run_experiment_light.sh [DURATION] [RUN_ID]
# =============================================================================
set -u

DURATION="${1:-120}"
RUN_ID="${2:-exp_$(date +%Y%m%d_%H%M%S)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACE_DIR="/storage/student2/traces"
RAW_DIR="${TRACE_DIR}/raw"
DATASET_DIR="${TRACE_DIR}/dataset"
LOG_DIR="${TRACE_DIR}/logs"
CONDA_BASE="/storage/shared/miniconda3"
CONDA_ENV="Akhil5G"

OBJ="${SCRIPT_DIR}/upf_measure_v2.o"
AWK_SCRIPT="${SCRIPT_DIR}/parse_tcbpf.awk"
PLOT_SCRIPT="${SCRIPT_DIR}/plot_results.py"

TRACE_PIPE="/sys/kernel/debug/tracing/trace_pipe"
TCBPF_OUT="${RAW_DIR}/${RUN_ID}_tcbpf.txt"
PFCP_OUT="${RAW_DIR}/${RUN_ID}_pfcp.jsonl"
TSHARK_OUT="${RAW_DIR}/${RUN_ID}_teid.tsv"
TEID_MAP_OUT="${RAW_DIR}/${RUN_ID}_teid_map.txt"
DELAYS_OUT="${DATASET_DIR}/${RUN_ID}_delays_raw.csv"
LOG_FILE="${LOG_DIR}/${RUN_ID}.log"

PIDFILE_TRACE="/tmp/o1_trace.pid"
PIDFILE_PFCP="/tmp/o1_pfcp.pid"
PIDFILE_TSHARK="/tmp/o1_tshark.pid"

# Initialize PID variables — prevents unbound variable error in cleanup trap
UPF1_PID=""
UPF2_PID=""
UPF3_PID=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*" | tee -a "$LOG_FILE"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; }
section() { echo -e "\n${BOLD}══ $* ══${NC}" | tee -a "$LOG_FILE"; }

mkdir -p "$RAW_DIR" "$DATASET_DIR" "$LOG_DIR"
: > "$LOG_FILE"

cleanup() {
    local exit_code=$?
    section "Cleanup"
    for pf in "$PIDFILE_TRACE" "$PIDFILE_PFCP" "$PIDFILE_TSHARK"; do
        [[ -f "$pf" ]] && { kill $(cat "$pf") 2>/dev/null || true; rm -f "$pf"; }
    done
    # Detach TC filters
    for upf_pid in $UPF1_PID $UPF2_PID $UPF3_PID; do
        [[ -n "$upf_pid" ]] && {
            nsenter -t "$upf_pid" -n tc filter del dev eth0   ingress 2>/dev/null || true
            nsenter -t "$upf_pid" -n tc filter del dev ogstun ingress  2>/dev/null || true
        }
    done
    # Stop traffic
    incus exec gnb-ue -- bash -c "
        pkill -f sipp_run 2>/dev/null; pkill sipp 2>/dev/null
        pkill iperf3 2>/dev/null; pkill -f mtc_loop 2>/dev/null
        pkill curl 2>/dev/null; exit 0
    " || true
    incus exec upf1 -- pkill iperf3 2>/dev/null || true
    [[ $exit_code -ne 0 ]] && error "Aborted (exit $exit_code)"
}
trap cleanup EXIT INT TERM

# ── Pre-flight ────────────────────────────────────────────────────────────────
section "Pre-flight"
[[ $EUID -ne 0 ]] && { error "Run as root"; exit 1; }
[[ -f "$OBJ" ]] || { error "BPF object not found: $OBJ — run: clang -O2 -g -target bpf -c upf_measure_v2.c -o upf_measure_v2.o -I/usr/include -I/usr/include/x86_64-linux-gnu"; exit 1; }

for c in amf-smf upf1 upf2 upf3 gnb-ue; do
    state=$(incus list "$c" --format csv --columns s 2>/dev/null | head -1)
    [[ "$state" == "RUNNING" ]] && ok "$c: RUNNING" || { error "$c: $state"; exit 1; }
done

NF_COUNT=$(incus exec amf-smf -- bash -c "ps aux | grep open5gs | grep -v grep | wc -l" 2>/dev/null || echo 0)
[[ "$NF_COUNT" -ge 9 ]] && ok "NFs: $NF_COUNT" || { error "Only $NF_COUNT NFs"; exit 1; }

TUN_COUNT=$(incus exec gnb-ue -- bash -c "ip link show | grep -c uesimtun" || echo 0)
[[ "$TUN_COUNT" -ge 3 ]] && ok "UE tunnels: $TUN_COUNT" || { error "Only $TUN_COUNT tunnels"; exit 1; }

for upf in upf1 upf2 upf3; do
    ogstun_up=$(incus exec "$upf" -- bash -c "ip link show ogstun 2>/dev/null | grep -c ',UP,' || echo 0")
    [[ "$ogstun_up" -ge 1 ]] && ok "ogstun $upf: UP" || {
        warn "ogstun DOWN on $upf — bringing up"
        incus exec "$upf" -- ip link set ogstun up || true
    }
done

# Get UPF container init PIDs
UPF1_PID=$(incus info upf1 2>/dev/null | awk '/^PID:/{print $2; exit}') || true
UPF2_PID=$(incus info upf2 2>/dev/null | awk '/^PID:/{print $2; exit}') || true
UPF3_PID=$(incus info upf3 2>/dev/null | awk '/^PID:/{print $2; exit}') || true
ok "UPF PIDs: UPF1=$UPF1_PID  UPF2=$UPF2_PID  UPF3=$UPF3_PID"

GNB_NS_PID=$(ps aux | grep "nr-gnb" | grep -v grep | grep -v incus | awk 'NR==1{print $2}')
[[ -n "$GNB_NS_PID" ]] && ok "nr-gnb: $GNB_NS_PID" || warn "nr-gnb not found"

[[ -f "${CONDA_BASE}/envs/${CONDA_ENV}/bin/python3" ]] && \
    PYTHON="${CONDA_BASE}/envs/${CONDA_ENV}/bin/python3" || PYTHON=$(which python3)

# ── Attach TC-BPF filters ─────────────────────────────────────────────────────
section "Attaching TC-BPF filters"

attach_upf() {
    local pid=$1 slice_lo=$2
    nsenter -t "$pid" -n tc qdisc add dev eth0   clsact 2>/dev/null || true
    nsenter -t "$pid" -n tc qdisc add dev ogstun clsact 2>/dev/null || true
    nsenter -t "$pid" -n tc filter del dev eth0   ingress 2>/dev/null || true
    nsenter -t "$pid" -n tc filter del dev ogstun ingress  2>/dev/null || true
    nsenter -t "$pid" -n tc filter add dev eth0   ingress bpf da obj "$OBJ" sec "tc/m1_${slice_lo}" 2>>"$LOG_FILE"
    nsenter -t "$pid" -n tc filter add dev ogstun ingress  bpf da obj "$OBJ" sec "tc/m3_${slice_lo}" 2>>"$LOG_FILE"
}

attach_upf "$UPF1_PID" "embb"  && ok "UPF1 (eMBB): TC-BPF attached"
attach_upf "$UPF2_PID" "urllc" && ok "UPF2 (URLLC): TC-BPF attached"
attach_upf "$UPF3_PID" "mmtc"  && ok "UPF3 (mMTC): TC-BPF attached"

# Clear trace buffer
echo > /sys/kernel/debug/tracing/trace 2>/dev/null || true

# ── Start collectors ──────────────────────────────────────────────────────────
section "Starting collectors"

# M1/M3: read from trace_pipe
cat "$TRACE_PIPE" | grep --line-buffered "upf_m" > "$TCBPF_OUT" &
echo $! > "$PIDFILE_TRACE"
ok "trace_pipe collector running (PID $(cat $PIDFILE_TRACE))"

# M2: bpftrace PFCP probes on host
bpftrace -e '
tracepoint:syscalls:sys_enter_sendto
/comm == "open5gs-smfd"/
{ printf("{\"type\":\"m2_pfcp_send\",\"ts_ns\":%llu,\"tid\":%d,\"comm\":\"%s\"}\n", nsecs, tid, comm); }
tracepoint:syscalls:sys_exit_recvfrom
/comm == "open5gs-smfd" && args->ret > 0/
{ printf("{\"type\":\"m2_pfcp_recv\",\"ts_ns\":%llu,\"tid\":%d,\"comm\":\"%s\",\"ret\":%d}\n", nsecs, tid, comm, (int32)args->ret); }
' > "$PFCP_OUT" 2>>"$LOG_FILE" &
echo $! > "$PIDFILE_PFCP"
ok "PFCP bpftrace running (PID $(cat $PIDFILE_PFCP))"

# tshark TEID capture
if [[ -n "$GNB_NS_PID" ]]; then
    nsenter -t "$GNB_NS_PID" -n \
        tshark -i eth0 -f "udp port 2152" \
               -T fields -e frame.time_epoch -e gtp.teid -l \
        > "$TSHARK_OUT" 2>>"$LOG_FILE" &
    echo $! > "$PIDFILE_TSHARK"
    ok "tshark running (PID $(cat $PIDFILE_TSHARK))"
fi

# ── Start traffic ─────────────────────────────────────────────────────────────
section "Starting traffic"

UE1_IP=$(incus exec gnb-ue -- bash -c "ip addr show uesimtun0 | grep 'inet ' | awk '{print \$2}' | cut -d/ -f1")
UE2_IP=$(incus exec gnb-ue -- bash -c "ip addr show uesimtun1 | grep 'inet ' | awk '{print \$2}' | cut -d/ -f1")
UE3_IP=$(incus exec gnb-ue -- bash -c "ip addr show uesimtun2 | grep 'inet ' | awk '{print \$2}' | cut -d/ -f1")
info "UE IPs: $UE1_IP  $UE2_IP  $UE3_IP"

# eMBB
incus exec upf1 -- bash -c "pkill iperf3 2>/dev/null; sleep 0.3; iperf3 -s -p 5201 -B 10.41.0.1 -D"
incus exec gnb-ue -- pkill iperf3 2>/dev/null || true
incus exec gnb-ue -- start-stop-daemon --start --background \
    --make-pidfile --pidfile /tmp/ue1.pid --exec /usr/bin/iperf3 \
    -- -c 10.41.0.1 -p 5201 -u -b 5M -t $((DURATION+60)) -B ${UE1_IP}
ok "eMBB: iperf3 UDP 5 Mbps → UPF1"

# URLLC
SIPP_RATE=2; SIPP_LIMIT=5; SIPP_TOTAL=$((SIPP_RATE*(DURATION+60)))
incus exec gnb-ue -- bash -c "cat > /tmp/sipp_run.sh << 'SIPPEOF'
#!/bin/bash
exec /usr/local/bin/sipp 10.42.0.1 \
    -sf /root/uac_pcmu.xml -l ${SIPP_LIMIT} -r ${SIPP_RATE} -m ${SIPP_TOTAL} \
    -mi ${UE2_IP} -mp 6000 -p 5080 -t u1 -nd -fd 5 \
    -trace_err -error_file /tmp/sipp_errors.log > /tmp/sipp.log 2>&1
SIPPEOF
chmod +x /tmp/sipp_run.sh"
incus exec gnb-ue -- pkill sipp 2>/dev/null || true
incus exec gnb-ue -- start-stop-daemon --start --background \
    --make-pidfile --pidfile /tmp/ue2.pid --startas /bin/bash -- /tmp/sipp_run.sh 2>/dev/null || true
ok "URLLC: sipp 2 calls/s → Asterisk on UPF2"

# mMTC
incus exec gnb-ue -- bash -c "cat > /tmp/mtc_loop.sh << 'CURLEOF'
#!/bin/bash
while true; do
    curl -sf --interface ${UE3_IP} --max-time 10 \
         http://10.43.0.1/stream.bin -o /dev/null 2>/dev/null || true
    sleep 0.05
done
CURLEOF
chmod +x /tmp/mtc_loop.sh"
incus exec gnb-ue -- pkill -f mtc_loop 2>/dev/null || true
incus exec gnb-ue -- start-stop-daemon --start --background \
    --make-pidfile --pidfile /tmp/ue3.pid --startas /bin/bash -- /tmp/mtc_loop.sh 2>/dev/null || true
ok "mMTC: curl HTTP loop → Nginx on UPF3"
incus exec gnb-ue -- bash -c "nohup ping -i 0.2 -W 1 10.43.0.1 -I uesimtun2 > /dev/null 2>&1 &"

sleep 3
IPERF=$(incus exec gnb-ue -- pgrep -c iperf3 2>/dev/null || echo 0)
SIPP=$(incus exec gnb-ue -- pgrep -c sipp 2>/dev/null || echo 0)
CURL=$(incus exec gnb-ue -- pgrep -c curl 2>/dev/null || echo 0)
info "Traffic procs: iperf3=$IPERF sipp=$SIPP curl=$CURL"

# Capture TEID map
sleep 3
if [[ -n "$GNB_NS_PID" ]]; then
    nsenter -t "$GNB_NS_PID" -n \
        tshark -i eth0 -f "udp port 2152" \
               -T fields -e ip.dst -e gtp.teid -c 60 2>/dev/null | \
    awk -F'\t' '
        /10\.45\.0\.11/ { print $2, "eMBB" }
        /10\.45\.0\.12/ { print $2, "URLLC" }
        /10\.45\.0\.13/ { print $2, "mMTC" }
    ' | sort -u > "$TEID_MAP_OUT" || true
    [[ -s "$TEID_MAP_OUT" ]] && ok "TEID map: $(cat $TEID_MAP_OUT | tr '\n' '|')" || warn "TEID map empty"
fi

# ── Wait ──────────────────────────────────────────────────────────────────────
section "Running: ${RUN_ID} (${DURATION}s)"
START_TIME=$(date +%s)
while true; do
    ELAPSED=$(( $(date +%s) - START_TIME ))
    [[ $ELAPSED -ge $DURATION ]] && break
    if (( ELAPSED % 10 == 0 )); then
        EVENTS=$(wc -l < "$TCBPF_OUT" 2>/dev/null || echo 0)
        printf "\r  [%3ds/%3ds]  TC-BPF events: %d" "$ELAPSED" "$DURATION" "$EVENTS"
    fi
    sleep 1
done
echo ""

# ── Stop ──────────────────────────────────────────────────────────────────────
section "Stopping"
kill $(cat "$PIDFILE_TRACE") 2>/dev/null || true; sleep 1; rm -f "$PIDFILE_TRACE"
kill $(cat "$PIDFILE_PFCP")  2>/dev/null || true; sleep 1; rm -f "$PIDFILE_PFCP"
[[ -f "$PIDFILE_TSHARK" ]] && { kill $(cat "$PIDFILE_TSHARK") 2>/dev/null || true; rm -f "$PIDFILE_TSHARK"; }

TCBPF_EVENTS=$(wc -l < "$TCBPF_OUT" || echo 0)
ok "TC-BPF events captured: $TCBPF_EVENTS"

# Quick breakdown
awk '/upf_m1/{m1++} /upf_m3/{m3++} END{print "[INFO]  M1(ingress)="m1"  M3(egress)="m3}' "$TCBPF_OUT" | tee -a "$LOG_FILE"
awk '/eMBB/{e++} /URLLC/{u++} /mMTC/{m++} END{print "[INFO]  eMBB="e"  URLLC="u"  mMTC="m}' "$TCBPF_OUT" | tee -a "$LOG_FILE"

# ── Process ───────────────────────────────────────────────────────────────────
section "Processing"
info "Running parse_tcbpf.awk..."
awk -f "$AWK_SCRIPT" "$TCBPF_OUT" > "$DELAYS_OUT" 2>>"$LOG_FILE"
info "Delay pairs: $(($(wc -l < "$DELAYS_OUT") - 1))"

info "Plotting..."
"$PYTHON" "$PLOT_SCRIPT" \
    --delays "$DELAYS_OUT" \
    --teid   "${TSHARK_OUT}" \
    --pfcp   "$PFCP_OUT" \
    --run-id "${RUN_ID}" \
    --out-dir "$DATASET_DIR" \
    2>&1 | tee -a "$LOG_FILE"

section "Complete: ${RUN_ID}"
ok "Dataset: $DATASET_DIR"
ls -lh "${DATASET_DIR}/o1_"*"${RUN_ID}"* 2>/dev/null | awk '{print "  "$5,$9}' || true
