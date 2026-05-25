# Measurement Framework

Setup, operation, and troubleshooting for the O1 TC-BPF measurement framework.

## 1. Quick Start

After the platform is up and all three UEs are registered:

```bash
cd experiments
sudo bash run_all_loads.sh 600
```

Results appear in `dataset/`. Each run produces a delay CSV, PFCP CSV, and a two-panel CDF PNG automatically.

---

## 2. Starting the Platform and Registering UEs

### 2.1 Start the 5G Core

```bash
bash platform/start_5g.sh
```

Wait for: `Platform is READY!`

Verify 9 NFs are running:

```bash
incus exec amf-smf -- ps aux | grep open5gs | grep -v grep | wc -l  # expect: 9
```

### 2.2 Start tmux with 4 Panes

```bash
tmux new-session -s 5g \; split-window -h \; split-window -v \; select-pane -t 0 \; split-window -v \; select-pane -t 0
```

### 2.3 Start gNB (Pane 0)

```bash
incus exec gnb-ue -- bash -c "cd /root/UERANSIM && ./build/nr-gnb -c config/gnb.yaml"
```

Wait for: `[ngap] [info] NG Setup procedure is successful`

### 2.4 Register UE1 — eMBB (Pane 1)

```bash
incus exec gnb-ue -- bash -c "cd /root/UERANSIM && ./build/nr-ue -c config/ue1.yaml"
```

Wait for: `TUN interface[uesimtun0, 10.41.0.2] is up`

### 2.5 Register UE2 — URLLC (Pane 2)

```bash
incus exec gnb-ue -- bash -c "cd /root/UERANSIM && ./build/nr-ue -c config/ue2.yaml"
```

Wait for: `TUN interface[uesimtun1, 10.42.0.2] is up`

### 2.6 Register UE3 — mMTC (Pane 3)

UE3 requires the rebuilt binary with the heartbeat fix described in [Platform Setup](01_platform_setup.md#ue3-heartbeat-fix--required-before-use).

```bash
incus exec gnb-ue -- bash -c "cd /root/UERANSIM && ./build_cmake/nr-ue -c config/ue3.yaml"
```

Wait for: `TUN interface[uesimtun2, 10.43.0.x] is up`

> **Why `build_cmake` and not `build`?** The default UERANSIM binary has `HEARTBEAT_THRESHOLD = 2000ms` in the RLS layer which causes UE3 to declare radio link failure within 9 minutes under mMTC curl traffic. The rebuilt binary in `build_cmake/` uses `HEARTBEAT_THRESHOLD = 10000ms` which keeps UE3 stable for the full 600-second experiment duration.

### 2.7 Verify All 3 Tunnels

```bash
incus exec gnb-ue -- ping -c 2 -I uesimtun0 10.41.0.1 | grep time=
incus exec gnb-ue -- ping -c 2 -I uesimtun1 10.42.0.1 | grep time=
incus exec gnb-ue -- ping -c 2 -I uesimtun2 10.43.0.1 | grep time=
```

All three must respond before running any experiment.

---

## 3. Running an Experiment

### 3.1 Basic Usage

```bash
# Single load condition — 120 seconds
sudo bash experiments/run_experiment_light.sh 120 exp_light

# All three load conditions — 600 seconds each (recommended)
sudo bash experiments/run_all_loads.sh 600
```

### 3.2 Experiment Stages

Each experiment script executes the following pipeline:

1. **Pre-flight** — checks containers, NFs, tunnel reachability, ogstun interfaces, UPF PIDs
2. **TC-BPF attachment** — attaches 6 BPF filters (M1 and M3 per UPF) via `nsenter -n` from host
3. **Collectors start** — trace_pipe reader, bpftrace PFCP probe on open5gs-smfd, tshark TEID capture
4. **Traffic starts** — iperf3 UDP (eMBB), SIPp → Asterisk (URLLC), curl → Nginx (mMTC)
5. **Wait** DURATION seconds
6. **Stop** — detach TC-BPF filters, stop collectors and traffic generators
7. **Parse** — `gawk parse_tcbpf.awk` matches M1→M3 timestamp pairs per slice
8. **Plot** — `python3 plot_results.py` generates statistics table and two-panel CDF PNG

### 3.3 Load Conditions

| Script | eMBB rate | URLLC rate | Duration |
|--------|-----------|------------|----------|
| run_experiment_light.sh | 5 Mbps | 2 calls/s | configurable |
| run_experiment_medium.sh | 20 Mbps | 4 calls/s | configurable |
| run_experiment_heavy.sh | 50 Mbps | 8 calls/s | configurable |

mMTC curl runs continuously at 0.05s sleep interval in all three conditions.

### 3.4 Output Files

| File | Description |
|------|-------------|
| `raw/<run>_tcbpf.txt` | Raw trace_pipe output — all M1/M3 events |
| `raw/<run>_pfcp.jsonl` | bpftrace PFCP send/recv events from open5gs-smfd |
| `raw/<run>_teid.tsv` | tshark GTP-U TEID capture |
| `raw/<run>_teid_map.txt` | ip.dst → slice TEID map |
| `dataset/<run>_delays_raw.csv` | gawk-matched M1/M3 pairs with slice label |
| `dataset/o1_forwarding_<run>.csv` | Final forwarding delay dataset |
| `dataset/o1_pfcp_<run>.csv` | Final PFCP latency dataset |
| `dataset/o1_cdf_<run>.png` | Two-panel CDF figure |
| `logs/<run>.log` | Full experiment log |

---

## 4. Instrumentation Design

### Measurement Points

The framework instruments three measurement points:

- **M1** — TC-BPF program attached to `eth0` ingress inside each UPF network namespace. Timestamps GTP-U packet arrival using `bpf_ktime_get_ns`.
- **M3** — TC-BPF program attached to `ogstun` ingress inside each UPF network namespace. Timestamps decapsulated IP packet delivery using `bpf_ktime_get_ns`.
- **M2** — bpftrace script attached to `sendto` and `recvfrom` syscalls of `open5gs-smfd` on the host. Measures N4 PFCP session establishment and modification round-trip time.

Forwarding delay = M3.ts − M1.ts (nanosecond resolution, same monotonic clock).

### The Container Namespace Problem

Standard host-level eBPF probes cannot be scoped to individual containers because each container runs in its own Linux network namespace. The `eth0` and `ogstun` interfaces inside a container are not visible from the host namespace.

The framework resolves this by using `nsenter -t <UPF_INIT_PID> -n` to enter each UPF's network namespace before attaching the TC-BPF object. This approach requires no modification to the container runtime or the open5GS source code.

### BPF Object Structure

`upf_measure_v2.c` contains six BPF sections:

| Section | Interface | Event |
|---------|-----------|-------|
| m1_upf1 | UPF1 eth0 ingress | GTP-U arrival — eMBB |
| m3_upf1 | UPF1 ogstun ingress | IP delivery — eMBB |
| m1_upf2 | UPF2 eth0 ingress | GTP-U arrival — URLLC |
| m3_upf2 | UPF2 ogstun ingress | IP delivery — URLLC |
| m1_upf3 | UPF3 eth0 ingress | GTP-U arrival — mMTC |
| m3_upf3 | UPF3 ogstun ingress | IP delivery — mMTC |

### Matching Algorithm

`parse_tcbpf.awk` reads the trace_pipe output as a continuous stream and maintains a circular buffer of 500 unmatched M1 events per UPF namespace keyed on TEID. When an M3 event arrives the script searches for a matching M1 event within a 10ms window, computes the delay, and writes a CSV record. Match rate consistently exceeds 99% across all experiments.

> **Note:** Always use `gawk` not `awk` for `parse_tcbpf.awk`. The script uses `match()` with array capture which is a gawk extension not available in mawk.

---

## 5. Plotting

### 5.1 Automatic Plot

`plot_results.py` is called automatically at the end of each experiment run. The per-run CDF PNG is saved to `dataset/` with the run-id in the filename (e.g. `o1_cdf_exp_light.png`).

### 5.2 Generate Publication Figures

Run once after all three load conditions are complete:

```bash
cd analysis
python3 generate_plots.py
```

Output goes to `dataset/final/`. Produces 8 figures:
1. `o1_cdf_FINAL_3load_forwarding.png` — three-panel forwarding delay CDF
2. `o1_pfcp_FINAL_3load_pfcp.png` — two-panel PFCP latency CDF
3-5. `o1_cdf_FINAL_{light,medium,heavy}_single.png` — per-run combined CDFs
6-8. `o1_pfcp_FINAL_{light,medium,heavy}_single.png` — per-run PFCP CDFs

### 5.3 Regenerate from Existing Data

```bash
conda activate <your_env>
python3 analysis/plot_results.py \
    --delays dataset/exp_name_delays_raw.csv \
    --teid   raw/exp_name_teid.tsv \
    --pfcp   raw/exp_name_pfcp.jsonl \
    --run-id exp_name \
    --out-dir dataset/
```

### 5.4 Monitor a Running Experiment

```bash
# Check if awk is still processing
ps aux | grep awk | grep -v grep

# Check raw trace file size
ls -lh raw/exp_heavy_tcbpf.txt

# Check matched pairs written so far
wc -l dataset/exp_heavy_delays_raw.csv

# Total lines in raw file (for progress estimate)
wc -l raw/exp_heavy_tcbpf.txt
# Progress % = (pairs_written x 2) / raw_lines x 100
```

> For 600-second heavy load experiments the raw trace file reaches approximately 2.6 GB and awk processing takes 35-40 minutes. This is expected.

---

## 6. Troubleshooting

| Problem | Fix |
|---------|-----|
| TC filter attach fails | Attach from host via `nsenter -n`, not inside container. Requires `CAP_SYS_ADMIN` on host. |
| No M3 events | `ogstun` hook must be TC INGRESS not egress. Check: `nsenter -t <PID> -n tc filter show dev ogstun ingress` |
| eMBB delay pairs very low | `WINDOW_NS` in `parse_tcbpf.awk` too small. Must be `10,000,000` (10 ms). |
| mMTC = 0 or truncated after ~9 min | UE3 radio link failure. Rebuild nr-ue with `HEARTBEAT_THRESHOLD=10000` as in Section 2.6. |
| Script exits 141 (SIGPIPE) | Change `set -euo pipefail` to `set -eo pipefail`. Add `\|\| true` to piped incus commands. |
| gawk syntax error on match() | Default awk is mawk. Always use `gawk -f parse_tcbpf.awk`. |
| UE3 gets uesimtun3 not uesimtun2 | Multiple UE3 processes running. Kill all and restart once. |
| plot_results.py KeyError 'slice' | Old delays_raw.csv without slice column. Re-run gawk with updated parse_tcbpf.awk. |
| CDF curves all overlap | Slice labelling wrong. Verify: `awk -F',' 'NR>1{c[$6]++}END{for(s in c)print s,c[s]}' delays_raw.csv` |
| Incus: Instance is not running | `sudo systemctl restart incus && incus start amf-smf upf1 upf2 upf3 gnb-ue` |

---

## 7. Critical Operating Rules

- Always run experiment scripts as root (`sudo`). TC-BPF attachment requires `CAP_SYS_ADMIN`.
- Only ONE nr-ue process per UE config. Two processes cause GTP session conflicts.
- UE3 must use `./build_cmake/nr-ue`. The default `./build/nr-ue` causes radio link failure under mMTC traffic.
- Always use `gawk`, not `awk`, for `parse_tcbpf.awk`.
- TC-BPF filters are detached at end of each run via cleanup trap. The next run reattaches them fresh.
- Do not run other bpftrace or BPF tools during experiments — `trace_pipe` is shared kernel-wide.
