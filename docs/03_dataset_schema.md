# Dataset Schema

This document describes the structure, column definitions, and key statistics of the O1 measurement dataset.

## Dataset Files

| File | Rows (approx) | Size | Description |
|------|--------------|------|-------------|
| `o1_forwarding_exp_light.csv` | 4.9 million | 231 MB | Light load — eMBB 5 Mbps, URLLC 2 calls/s — 600s |
| `o1_forwarding_exp_medium.csv` | 11.9 million | 576 MB | Medium load — eMBB 20 Mbps, URLLC 4 calls/s — 600s |
| `o1_forwarding_exp_heavy.csv` | 12.0 million | 586 MB | Heavy load — eMBB 50 Mbps, URLLC 8 calls/s — 600s |
| `o1_pfcp_exp_light.csv` | 244 | 5 KB | PFCP session latency — light load |
| `o1_pfcp_exp_medium.csv` | 239 | 5 KB | PFCP session latency — medium load |
| `o1_pfcp_exp_heavy.csv` | 239 | 5 KB | PFCP session latency — heavy load |

Total dataset: approximately 28 million matched forwarding delay pairs across three slice types and three load conditions.

---

## Forwarding Delay CSV Schema

| Column | Type | Unit | Description |
|--------|------|------|-------------|
| `slice` | string | — | Network slice: `eMBB`, `URLLC`, or `mMTC` |
| `delay_us` | float | microseconds | N3 to N6 UPF forwarding delay (M3.ts − M1.ts) |
| `pkt_len` | integer | bytes | Inner IP packet length recorded at M3 (ogstun ingress) |
| `ts_rx_ns` | integer | nanoseconds | M1 timestamp — GTP-U arrival at eth0 (`bpf_ktime_get_ns`) |
| `ts_tx_ns` | integer | nanoseconds | M3 timestamp — IP delivery at ogstun (`bpf_ktime_get_ns`) |
| `netif_rx` | string | — | Network interface at M1 (always `eth0`) |

All timestamps use `CLOCK_MONOTONIC_RAW` via `bpf_ktime_get_ns`. Both M1 and M3 timestamps are collected on the same physical host so the difference is a valid elapsed time measurement.

All measurements are **uplink direction only** (UE → UPF).

---

## PFCP Latency CSV Schema

| Column | Type | Unit | Description |
|--------|------|------|-------------|
| `pfcp_type` | string | — | `establishment` or `modification` |
| `latency_us` | float | microseconds | PFCP round-trip time (recv.ts − send.ts on open5gs-smfd) |

PFCP type is classified by latency threshold: establishment > 200 µs, modification ≤ 200 µs. This threshold reflects the observed bimodal distribution and is documented in `analysis/plot_results.py`.

---

## Key Statistics — 600s Runs

### Forwarding Delay

| Slice | Load | N | Mean (µs) | P50 (µs) | P99 (µs) |
|-------|------|---|-----------|----------|----------|
| eMBB | Light | 281,428 | 93 | 66 | 574 |
| eMBB | Medium | 1,126,235 | 56 | 38 | 325 |
| eMBB | Heavy | 2,814,633 | 86 | 30 | 1,243 |
| URLLC | Light | 3,624 | 102 | 77 | 517 |
| URLLC | Medium | 7,302 | 77 | 61 | 314 |
| URLLC | Heavy | 14,592 | 84 | 63 | 404 |
| mMTC | Light | 4,655,720 | 132 | 23 | 2,533 |
| mMTC | Medium | 10,722,385 | 102 | 21 | 1,934 |
| mMTC | Heavy | 9,188,335 | 125 | 22 | 2,401 |

### PFCP Session Latency

| Load | Type | N | Mean (µs) | P99 (µs) |
|------|------|---|-----------|----------|
| Light | Establishment | 203 | 600 | 2,915 |
| Light | Modification | 41 | 125 | 197 |
| Medium | Establishment | 203 | 566 | 3,169 |
| Medium | Modification | 36 | 115 | 199 |
| Heavy | Establishment | 173 | 635 | 3,541 |
| Heavy | Modification | 66 | 142 | 197 |

All PFCP modification P99 values are below the 2 ms orchestration budget. The budget line is shown in all PFCP CDF figures.

---

## Loading the Dataset in Python

```python
import pandas as pd
import numpy as np

# Load forwarding delay dataset
df = pd.read_csv('dataset/o1_forwarding_exp_light.csv')

# Per-slice statistics
print(df.groupby('slice')['delay_us'].describe(percentiles=[.5, .95, .99]))

# P99 per slice
for sl in ['eMBB', 'URLLC', 'mMTC']:
    p99 = df[df['slice'] == sl]['delay_us'].quantile(0.99)
    print(f'{sl}: P99 = {p99:.0f} µs')
```

---

## Experimental Platform

All measurements collected on:

| Parameter | Value |
|-----------|-------|
| 5G Core | open5GS v2.7.6 |
| RAN emulator | UERANSIM v3.2.7 |
| Container runtime | Incus 6.23, Ubuntu 22.04 LTS |
| Kernel | 6.8.0-111-generic |
| Host CPU | Intel Xeon Gold 5218R |
| Host RAM | 92 GB |
| Instrumentation | TC-BPF (upf_measure_v2.c) on eth0 ingress (M1) and ogstun ingress (M3) |
| PFCP probe | bpftrace (ebpf_probes.bt) on open5gs-smfd sendto/recvfrom |
| Direction | Uplink only (UE → UPF) |

---

## License

Dataset files are licensed under **CC BY 4.0**. If you use this dataset in your research please cite:

```
Akhil Dev Mishra and Mayank Pandey,
"Kernel-Level Per-Slice UPF Latency Measurement in Containerised 5G Core Networks,"
arXiv:2605.28185 [cs.NI], May 2026.
https://doi.org/10.48550/arXiv.2605.28185
```
