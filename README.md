# open5gs-slice-measurement

A containerised three-slice 5G Core platform based on open5GS and UERANSIM with TC-BPF kernel instrumentation for per-slice UPF forwarding delay and N4 PFCP latency measurement.

## Overview

This repository provides a complete reproducible platform for measuring per-slice User Plane Function (UPF) forwarding delay and N4 PFCP session latency in a containerised 5G Core network. The platform implements three concurrent network slices — eMBB, URLLC, and mMTC — each served by a dedicated UPF instance, and instruments each UPF using TC-BPF programs attached to the correct network namespace via nsenter.

The measurement framework was developed as part of a PhD research programme on intelligent, latency-aware UPF orchestration for MEC-integrated 5G Core networks at MNNIT Allahabad.

## Key Contributions

- A namespace-aware TC-BPF instrumentation framework that resolves the container attribution problem for per-slice UPF forwarding delay measurement without modifying 5GC software
- A dataset of approximately 28 million matched N3 to N6 forwarding delay pairs across three slice types and three load conditions on open5GS v2.7.6 with UERANSIM v3.2.7
- Empirical characterisation of N4 PFCP session modification latency establishing a sub-200 microsecond lower bound with substantial headroom relative to the 2 ms budget assumed by AI-driven UPF orchestration designs
- Documentation of eighteen instrumentation obstacles and their resolutions providing a reproducible methodology for the 5GC measurement community

## Platform Summary

| Component | Version | Role |
|-----------|---------|------|
| open5GS | v2.7.6 | 5G Core (AMF, SMF, UPF, PCF, NWDAF stub) |
| UERANSIM | v3.2.7 | gNB and UE emulation |
| Incus | 6.23 | Container runtime |
| Ubuntu | 22.04 LTS | Host OS |
| Kernel | 6.8.0 | TC-BPF support required |

## Network Slices

| Slice | SST | DNN | Traffic | UPF |
|-------|-----|-----|---------|-----|
| eMBB | 1 | internet | iperf3 UDP 5/20/50 Mbps | UPF1 |
| URLLC | 2 | voip | SIPp → Asterisk 18 | UPF2 |
| mMTC | 3 | streaming | curl → Nginx | UPF3 |

## Quick Start

```bash
# 1. Start the 5G Core
bash platform/start_5g.sh

# 2. Start tmux and register all three UEs
# See docs/02_measurement_framework.md for step-by-step UE registration

# 3. Run all three load conditions at 600 seconds each
cd experiments
sudo bash run_all_loads.sh 600

# 4. Generate publication figures
cd ../analysis
python3 generate_plots.py
```

Results appear in `dataset/final/`.

## Repository Structure

```
open5gs-slice-measurement/
├── README.md
├── LICENSE
├── docs/
│   ├── 01_platform_setup.md        # How to install open5GS, UERANSIM, Incus
│   ├── 02_measurement_framework.md # TC-BPF instrumentation guide and operation
│   └── 03_dataset_schema.md        # CSV column descriptions and key statistics
├── platform/
│   ├── start_5g.sh                 # Start all containers and restore ogstun
│   ├── stop_5g.sh                  # Stop all containers cleanly
│   └── status_5g.sh                # Check platform health
├── instrumentation/
│   ├── upf_measure_v2.c            # TC-BPF source — M1 and M3 probes
│   ├── ebpf_probes.bt              # bpftrace M2 PFCP probe
│   └── parse_tcbpf.awk             # M1/M3 delay matching script
├── experiments/
│   ├── run_all_loads.sh            # Run all three load conditions sequentially
│   ├── run_experiment_light.sh     # Light load — 5 Mbps eMBB
│   ├── run_experiment_medium.sh    # Medium load — 20 Mbps eMBB
│   └── run_experiment_heavy.sh     # Heavy load — 50 Mbps eMBB
└── analysis/
    ├── plot_results.py             # Per-run CDF and statistics (auto-called)
    └── generate_plots.py           # Publication figures combining all loads
```

## Documentation

- [Platform Setup](docs/01_platform_setup.md) — Install open5GS, UERANSIM, and Incus from scratch
- [Measurement Framework](docs/02_measurement_framework.md) — TC-BPF instrumentation, UE registration, running experiments
- [Dataset Schema](docs/03_dataset_schema.md) — CSV column descriptions and dataset structure

## Citation

If you use this platform or dataset in your research please cite:

```
Akhil Dev Mishra and Mayank Pandey,
"Characterising Per-Slice UPF Forwarding Delay in Containerised 5G Core Networks:
A Kernel-Level Measurement Study,"
[venue and year to be updated after publication]
Department of CSE, MNNIT Allahabad, 2026.
```

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

The dataset files are additionally licensed under CC BY 4.0. If you use the dataset independently please cite the paper above.

## Contact

**Akhil Dev Mishra** — PhD Scholar
**Prof. Mayank Pandey** — Supervisor
Department of Computer Science and Engineering
Motilal Nehru National Institute of Technology Allahabad, Prayagraj, India
