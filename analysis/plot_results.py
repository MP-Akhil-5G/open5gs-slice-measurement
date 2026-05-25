#!/usr/bin/env python3
"""
plot_results.py — Read awk-matched delays CSV + tshark TEID TSV, produce stats + plots.
Usage:
    conda activate Akhil5G
    python3 plot_results.py \
        --delays  /storage/student2/traces/dataset/delays_raw.csv \
        --teid    /storage/student2/traces/raw/exp_clean_run_teid.tsv \
        --pfcp    /storage/student2/traces/raw/exp_clean_run_bpftrace.jsonl \
        --run-id  exp_clean_run \
        --out-dir /storage/student2/traces/dataset
"""

import sys
import json
import argparse
import os
from pathlib import Path
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

# ── Static TEID fallback (used only if auto-detection fails) ─────────────────
# Uplink TEIDs are always 1,2,3 (assigned sequentially by open5gs per UE).
# Downlink TEIDs change every UE re-registration — auto-detected from ip.dst.
UPLINK_TEID_SLICE = {1: "eMBB", 2: "URLLC", 3: "mMTC"}

# UPF container IPs → slice (stable, never change)
DST_IP_SLICE = {
    "10.45.0.11": "eMBB",    # UPF1
    "10.42.0.1":  "eMBB",    # UPF1 ogstun (uplink inner)
    "10.45.0.12": "URLLC",   # UPF2
    "10.42.0.2":  "URLLC",   # UPF2 ogstun (uplink inner)
    "10.45.0.13": "mMTC",    # UPF3
    "10.43.0.2":  "mMTC",    # UPF3 ogstun (uplink inner)
}

SLICE_COLORS = {"eMBB": "#1D9E75", "URLLC": "#BA7517", "mMTC": "#534AB7"}


def load_teid_counts(teid_file: str) -> dict:
    """
    Auto-detect TEID→slice mapping from tshark TSV using ip.dst field.

    tshark TSV format (two fields: frame.time_epoch, gtp.teid):
      The current tshark capture only has time + teid columns.
      We use uplink TEIDs (1,2,3) which are stable, plus count remaining
      TEIDs and map by packet-count rank using the confirmed ip.dst mapping
      stored in DST_IP_SLICE for the known UPF container IPs.

    Since tshark TSV only has teid (no ip.dst), we use a combined strategy:
      1. Uplink TEIDs 1→eMBB, 2→URLLC, 3→mMTC (always stable)
      2. Downlink TEIDs: use the confirmed session mapping written to
         /tmp/teid_map.txt by run_experiment.sh (if present), otherwise
         fall back to treating all non-1/2/3 TEIDs as needing manual mapping.
    """
    from collections import Counter
    counts = {"eMBB": 0, "URLLC": 0, "mMTC": 0}
    teid_counter = Counter()

    # Load teid_map written by run_experiment.sh (teid→slice, one per line)
    teid_map = {}  # int teid → slice string
    map_file = teid_file.replace("_teid.tsv", "_teid_map.txt")
    if os.path.exists(map_file):
        with open(map_file) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split()
                if len(parts) >= 2:
                    try:
                        teid_map[int(parts[0], 16)] = parts[1]
                    except ValueError:
                        pass
        print(f"[plot] Loaded TEID map from {map_file}: {teid_map}")

    try:
        with open(teid_file) as f:
            for line in f:
                line = line.strip()
                if not line or "\t" not in line:
                    continue
                parts = line.split("\t")
                if len(parts) < 2:
                    continue
                try:
                    teid = int(parts[1].strip(), 16)
                    teid_counter[teid] += 1
                except ValueError:
                    continue
    except Exception as e:
        print(f"[WARN] TEID file error: {e}", file=sys.stderr)
        return counts, 0

    # Map uplink TEIDs (stable)
    for teid, sl in UPLINK_TEID_SLICE.items():
        counts[sl] += teid_counter.get(teid, 0)

    # Map downlink TEIDs using teid_map file
    uplink_set = set(UPLINK_TEID_SLICE.keys())
    for teid, cnt in teid_counter.items():
        if teid in uplink_set:
            continue
        if teid in teid_map:
            counts[teid_map[teid]] += cnt
        # else: unknown TEID, skip

    total = sum(counts.values())
    print(f"[plot] TEID counts — eMBB:{counts['eMBB']:,} URLLC:{counts['URLLC']:,} "
          f"mMTC:{counts['mMTC']:,} (total {total:,})")
    return counts, total


def label_slices(df: pd.DataFrame, counts: dict, total: int) -> pd.DataFrame:
    """Assign slice labels proportionally based on tshark TEID packet counts."""
    n = len(df)
    if total > 0:
        embb_n  = int(n * counts["eMBB"]  / total)
        urllc_n = int(n * counts["URLLC"] / total)
        mmtc_n  = n - embb_n - urllc_n
        labels = ["eMBB"] * embb_n + ["URLLC"] * urllc_n + ["mMTC"] * mmtc_n
        # Shuffle labels to avoid all eMBB at start
        import random
        random.shuffle(labels)
        df["slice"] = labels
    else:
        df["slice"] = "unknown"
    return df


def load_pfcp_latency(jsonl_file: str) -> pd.DataFrame:
    """Extract PFCP send/recv pairs from bpftrace JSONL for N4 latency."""
    sends = []
    recvs = []
    print("[plot] Loading PFCP events (streaming)...")
    with open(jsonl_file) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
                t = r.get("type", "")
                comm = r.get("comm", "")
                if t == "m2_pfcp_send" and "smfd" in comm:
                    sends.append(r["ts_ns"])
                elif t == "m2_pfcp_recv" and r.get("ret", 0) > 0 and "smfd" in comm:
                    recvs.append(r["ts_ns"])
            except Exception:
                continue

    if not sends or not recvs:
        print("[WARN] No PFCP events found", file=sys.stderr)
        return pd.DataFrame()

    sends = sorted(sends)
    recvs = sorted(recvs)
    recvs_np = np.array(recvs)

    rows = []
    recv_used = set()
    # Tight window: 5ms max RTT for PFCP (local container network)
    WINDOW = 5_000_000  # 5ms in ns

    for ts_req in sends:
        idx = np.searchsorted(recvs_np, ts_req)
        best_j = -1
        best_diff = WINDOW + 1
        for j in range(idx, min(idx + 10, len(recvs))):
            if j in recv_used:
                continue
            diff = recvs[j] - ts_req
            if diff < 0 or diff > WINDOW:
                continue
            if diff < best_diff:
                best_diff = diff
                best_j = j
        if best_j == -1:
            continue
        recv_used.add(best_j)
        lat_us = best_diff / 1_000
        rows.append({"latency_us": lat_us})

    if not rows:
        return pd.DataFrame()

    # Classify establishment vs modification by latency bimodality:
    # Establishment (full PFCP session create): typically > 200µs
    # Modification (update existing session):   typically < 200µs
    df = pd.DataFrame(rows)
    df["pfcp_type"] = df["latency_us"].apply(
        lambda x: "establishment" if x > 200 else "modification"
    )
    print(f"[plot] PFCP pairs matched: {len(df):,}  "
          f"(est:{(df.pfcp_type=='establishment').sum()}  "
          f"mod:{(df.pfcp_type=='modification').sum()})")
    return df


def print_summary(df_fwd: pd.DataFrame, df_pfcp: pd.DataFrame):
    print()
    print("=" * 72)
    print("  O1 MEASUREMENT SUMMARY")
    print("=" * 72)

    if not df_fwd.empty:
        print("\n── UPF Forwarding Delay (μs) — per slice ─────────────────────────────")
        print(f"  {'Slice':<8} {'N':>7} {'Min':>8} {'Mean':>8} {'P50':>8} {'P95':>8} {'P99':>8} {'Max':>8}")
        print(f"  {'-'*7} {'-'*7} {'-'*8} {'-'*8} {'-'*8} {'-'*8} {'-'*8} {'-'*8}")
        for sl in ["eMBB", "URLLC", "mMTC"]:
            sub = df_fwd[df_fwd["slice"] == sl]["delay_us"]
            if len(sub) == 0:
                continue
            print(f"  {sl:<8} {len(sub):>7,} "
                  f"{sub.min():>8.2f} {sub.mean():>8.2f} "
                  f"{sub.quantile(0.50):>8.2f} "
                  f"{sub.quantile(0.95):>8.2f} "
                  f"{sub.quantile(0.99):>8.2f} "
                  f"{sub.max():>8.2f}")

    if not df_pfcp.empty:
        print("\n── N4 PFCP Latency (μs) — by type ───────────────────────────────────")
        print(f"  {'Type':<16} {'N':>5} {'Min':>8} {'Mean':>8} {'P95':>8} {'P99':>8} {'Max':>8}")
        print(f"  {'-'*15} {'-'*5} {'-'*8} {'-'*8} {'-'*8} {'-'*8} {'-'*8}")
        for ptype in ["establishment", "modification"]:
            sub = df_pfcp[df_pfcp["pfcp_type"] == ptype]["latency_us"]
            if len(sub) == 0:
                continue
            print(f"  {ptype:<16} {len(sub):>5,} "
                  f"{sub.min():>8.2f} {sub.mean():>8.2f} "
                  f"{sub.quantile(0.95):>8.2f} "
                  f"{sub.quantile(0.99):>8.2f} "
                  f"{sub.max():>8.2f}")
        mod = df_pfcp[df_pfcp["pfcp_type"] == "modification"]["latency_us"]
        if len(mod) > 0:
            p99 = mod.quantile(0.99)
            sym = "✓" if p99 <= 2000 else "⚠"
            print(f"\n  {sym}  P99 modification latency {p99:.0f} μs — "
                  f"{'within' if p99 <= 2000 else 'EXCEEDS'} 2ms budget")

    print("\n" + "=" * 72)


def plot_cdfs(df_fwd: pd.DataFrame, df_pfcp: pd.DataFrame, run_id: str, out_dir: Path):
    fig, axes = plt.subplots(1, 2, figsize=(12, 5))
    fig.suptitle(f"O1 Latency CDFs — {run_id}", fontsize=13)

    ax = axes[0]
    if not df_fwd.empty:
        for sl in ["eMBB", "URLLC", "mMTC"]:
            sub = df_fwd[df_fwd["slice"] == sl]["delay_us"].sort_values()
            if len(sub) == 0:
                continue
            cdf = np.arange(1, len(sub) + 1) / len(sub)
            ax.plot(sub.values, cdf, label=sl,
                    color=SLICE_COLORS.get(sl, "gray"), linewidth=1.5)
    ax.set_xlabel("UPF forwarding delay (μs)")
    ax.set_ylabel("CDF")
    ax.set_title("N3→N6 forwarding delay")
    ax.legend(loc='lower right')
    ax.grid(True, alpha=0.3, which='both')
    ax.set_xscale('log')
    ax.set_xlim(left=1, right=15000)
    ax.xaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(lambda x, _: f'{int(x):,}'))

    ax = axes[1]
    pcolors = {"establishment": "#185FA5", "modification": "#D85A30"}
    if not df_pfcp.empty:
        for ptype in ["establishment", "modification"]:
            sub = df_pfcp[df_pfcp["pfcp_type"] == ptype]["latency_us"].sort_values()
            if len(sub) == 0:
                continue
            cdf = np.arange(1, len(sub) + 1) / len(sub)
            ax.plot(sub.values, cdf, label=ptype,
                    color=pcolors[ptype], linewidth=1.5)
        ax.axvline(x=2000, color="red", linestyle="--", linewidth=1, label="2 ms budget")
    ax.set_xlabel("PFCP latency (μs)")
    ax.set_ylabel("CDF")
    ax.set_title("N4 PFCP session latency")
    ax.legend(loc='lower right')
    ax.grid(True, alpha=0.3)
    ax.set_xlim(left=0)

    plt.tight_layout()
    path = out_dir / f"o1_cdf_{run_id}.png"
    plt.savefig(path, dpi=150, bbox_inches="tight")
    plt.close()
    print(f"[plot] CDF saved: {path}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--delays",  required=True, help="awk output CSV")
    parser.add_argument("--teid",    required=True, help="tshark TEID TSV")
    parser.add_argument("--pfcp",    required=True, help="bpftrace JSONL (for PFCP)")
    parser.add_argument("--run-id",  default="run")
    parser.add_argument("--out-dir", default="/storage/student2/traces/dataset")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    # Load awk delay CSV — slice column already set by match_delays.awk
    print(f"[plot] Loading delay CSV: {args.delays}")
    df_fwd = pd.read_csv(args.delays, comment="#")
    print(f"[plot] Loaded {len(df_fwd):,} delay pairs")

    # Use slice column if present, otherwise fall back to proportional TEID labelling
    if "slice" in df_fwd.columns and df_fwd["slice"].nunique() > 1:
        known = df_fwd["slice"].isin(["eMBB", "URLLC", "mMTC"])
        print(f"[plot] Using veth-based slice labels: "
              f"{df_fwd[known].groupby('slice').size().to_dict()}")
        df_fwd = df_fwd[known]  # drop 'unknown' rows
    else:
        print("[plot] No slice column — falling back to TEID proportional labelling")
        counts, total = load_teid_counts(args.teid)
        df_fwd = label_slices(df_fwd, counts, total)

    # Load PFCP latency from JSONL
    df_pfcp = load_pfcp_latency(args.pfcp)

    # Summary
    print_summary(df_fwd, df_pfcp)

    # Save CSVs
    fwd_path = out_dir / f"o1_forwarding_{args.run_id}.csv"
    df_fwd.to_csv(fwd_path, index=False)
    print(f"[plot] CSV: {fwd_path}  ({os.path.getsize(fwd_path)//1024} KB)")

    if not df_pfcp.empty:
        pfcp_path = out_dir / f"o1_pfcp_{args.run_id}.csv"
        df_pfcp.to_csv(pfcp_path, index=False)
        print(f"[plot] CSV: {pfcp_path}  ({os.path.getsize(pfcp_path)//1024} KB)")

    # Plot
    plot_cdfs(df_fwd, df_pfcp, args.run_id, out_dir)
    print("[plot] Done.")


if __name__ == "__main__":
    main()
