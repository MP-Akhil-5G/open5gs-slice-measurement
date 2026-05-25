#!/usr/bin/env python3
"""
generate_plots.py — O1 Plot Generation Script
Akhil's PhD: Intelligent Latency-Aware UPF Orchestration | MNNIT Allahabad

Generates all publication figures from the O1 dataset CSVs.
Usage:
    conda activate Akhil5G
    python3 generate_plots.py

Output directory: /storage/student2/traces/dataset/final/

Figures produced:
  1. o1_cdf_FINAL_3load_forwarding.png  — 3-panel forwarding delay CDF (light/medium/heavy)
  2. o1_pfcp_FINAL_3load_pfcp.png       — 2-panel PFCP latency CDF (light/medium/heavy)
  3. o1_cdf_FINAL_light_single.png      — Single-run CDF: forwarding + PFCP (light load)
  4. o1_cdf_FINAL_medium_single.png     — Single-run CDF: forwarding + PFCP (medium load)
  5. o1_cdf_FINAL_heavy_single.png      — Single-run CDF: forwarding + PFCP (heavy load)
  6. o1_pfcp_FINAL_light_single.png     — PFCP-only CDF (light load)
  7. o1_pfcp_FINAL_medium_single.png    — PFCP-only CDF (medium load)
  8. o1_pfcp_FINAL_heavy_single.png     — PFCP-only CDF (heavy load)
"""

import pandas as pd
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import os

# ── Paths ────────────────────────────────────────────────────────────────────
BASE    = '/storage/student2/traces/dataset'
OUT_DIR = '/storage/student2/traces/dataset/final'
os.makedirs(OUT_DIR, exist_ok=True)

# ── Style ────────────────────────────────────────────────────────────────────
plt.rcParams.update({
    'font.size': 11, 'axes.labelsize': 11, 'legend.fontsize': 9,
    'figure.dpi': 150, 'savefig.dpi': 300, 'savefig.bbox': 'tight',
    'lines.linewidth': 1.8,
})

LOAD_COLORS  = {'Light (5 Mbps)': '#2ca02c', 'Medium (20 Mbps)': '#ff7f0e', 'Heavy (50 Mbps)': '#d62728'}
PFCP_COLORS  = {'establishment': '#185FA5', 'modification': '#D85A30'}
SLICE_COLORS = {'eMBB': '#2ca02c', 'URLLC': '#ff7f0e', 'mMTC': '#9467bd'}

LOADS = {
    'Light (5 Mbps)':   'exp_light',
    'Medium (20 Mbps)': 'exp_medium',
    'Heavy (50 Mbps)':  'exp_heavy',
}

CAPTION = ('Platform: open5GS v2.7.6 + UERANSIM v3.2.7, Incus containers, Ubuntu 22.04, kernel 6.8.0.  '
           'Instrumentation: TC-BPF (upf_measure_v2.c) on eth0 ingress (M1) and ogstun ingress (M3).  '
           'Traffic: eMBB=iperf3 UDP, URLLC=sipp→Asterisk, mMTC=curl→Nginx.')

def save(fig, name):
    path = f'{OUT_DIR}/{name}'
    fig.savefig(path)
    plt.close(fig)
    print(f'  Saved: {name}  ({os.path.getsize(path)//1024} KB)')

# ── Figure 1: 3-load forwarding delay comparison ─────────────────────────────
print('[1/8] 3-load forwarding delay CDF...')
fig, axes = plt.subplots(1, 3, figsize=(15, 5))
fig.suptitle('O1 N3→N6 Forwarding Delay — Three Load Conditions',
             fontsize=13, fontweight='bold')
for i, sl in enumerate(['eMBB', 'URLLC', 'mMTC']):
    ax = axes[i]
    for label, run in LOADS.items():
        df = pd.read_csv(f'{BASE}/o1_forwarding_{run}.csv')
        sub = df[df['slice'] == sl]['delay_us'].sort_values()
        cdf = np.arange(1, len(sub) + 1) / len(sub)
        ax.plot(sub, cdf, label=label, color=LOAD_COLORS[label])
        p99 = np.percentile(sub, 99)
        ax.axvline(p99, color=LOAD_COLORS[label], linestyle=':', alpha=0.4, linewidth=1)
    ax.set_title(sl, fontweight='bold')
    ax.set_xlabel('Forwarding delay (µs)')
    ax.set_xscale('log')
    ax.set_xlim(left=1, right=15000)
    ax.set_ylim(0, 1.02)
    ax.grid(True, alpha=0.3, which='both')
    ax.legend(loc='lower right')
    if i == 0:
        ax.set_ylabel('CDF')
fig.text(0.5, -0.02, CAPTION, ha='center', fontsize=8, color='grey', style='italic')
plt.tight_layout()
save(fig, 'o1_cdf_FINAL_3load_forwarding.png')

# ── Figure 2: 3-load PFCP comparison ─────────────────────────────────────────
print('[2/8] 3-load PFCP latency CDF...')
fig, axes = plt.subplots(1, 2, figsize=(12, 5))
fig.suptitle('O1 N4 PFCP Session Latency — Three Load Conditions',
             fontsize=13, fontweight='bold')
for label, run in LOADS.items():
    df = pd.read_csv(f'{BASE}/o1_pfcp_{run}.csv')
    for ax, ptype in zip(axes, ['establishment', 'modification']):
        sub = df[df['pfcp_type'] == ptype]['latency_us'].sort_values()
        if len(sub) == 0:
            continue
        cdf = np.arange(1, len(sub) + 1) / len(sub)
        ax.plot(sub, cdf, label=f'{label} (n={len(sub)})', color=LOAD_COLORS[label])
for ax, title in zip(axes, ['PFCP Session Establishment', 'PFCP Session Modification']):
    ax.axvline(2000, color='red', linestyle='--', linewidth=1.5, label='2 ms budget')
    ax.set_title(title, fontweight='bold')
    ax.set_xlabel('PFCP latency (µs)')
    ax.set_ylabel('CDF')
    ax.set_xlim(left=0)
    ax.grid(True, alpha=0.3)
    ax.legend(loc='lower right')
plt.tight_layout()
save(fig, 'o1_pfcp_FINAL_3load_pfcp.png')

# ── Figures 3-5: Single-run combined CDFs ────────────────────────────────────
for load_label, run in LOADS.items():
    load_short = run.replace('exp_', '')
    print(f'[{3 + list(LOADS.keys()).index(load_label)}/8] Single CDF: {load_short}...')
    df_fwd  = pd.read_csv(f'{BASE}/o1_forwarding_{run}.csv')
    df_pfcp = pd.read_csv(f'{BASE}/o1_pfcp_{run}.csv')

    fig, axes = plt.subplots(1, 2, figsize=(12, 5))
    fig.suptitle(f'O1 Latency CDFs — {load_label}', fontsize=13, fontweight='bold')

    # Left: forwarding delay per slice
    ax = axes[0]
    for sl, color in SLICE_COLORS.items():
        sub = df_fwd[df_fwd['slice'] == sl]['delay_us'].sort_values()
        if len(sub) == 0:
            continue
        cdf = np.arange(1, len(sub) + 1) / len(sub)
        ax.plot(sub, cdf, label=f'{sl} (n={len(sub):,})', color=color)
    ax.set_xlabel('Forwarding delay (µs)')
    ax.set_ylabel('CDF')
    ax.set_title('N3→N6 forwarding delay')
    ax.set_xscale('log')
    ax.set_xlim(left=1, right=15000)
    ax.set_ylim(0, 1.02)
    ax.grid(True, alpha=0.3, which='both')
    ax.legend(loc='lower right')

    # Right: PFCP latency
    ax = axes[1]
    for ptype, color in PFCP_COLORS.items():
        sub = df_pfcp[df_pfcp['pfcp_type'] == ptype]['latency_us'].sort_values()
        if len(sub) == 0:
            continue
        cdf = np.arange(1, len(sub) + 1) / len(sub)
        ax.plot(sub, cdf, label=f'{ptype} (n={len(sub)})', color=color)
    ax.axvline(2000, color='red', linestyle='--', linewidth=1.2, label='2 ms budget')
    ax.set_xlabel('PFCP latency (µs)')
    ax.set_ylabel('CDF')
    ax.set_title('N4 PFCP session latency')
    ax.set_xlim(left=0)
    ax.grid(True, alpha=0.3)
    ax.legend(loc='lower right')

    plt.tight_layout()
    save(fig, f'o1_cdf_FINAL_{load_short}_single.png')

# ── Figures 6-8: Single PFCP CDFs ────────────────────────────────────────────
for load_label, run in LOADS.items():
    load_short = run.replace('exp_', '')
    print(f'[{6 + list(LOADS.keys()).index(load_label)}/8] PFCP single: {load_short}...')
    df_pfcp = pd.read_csv(f'{BASE}/o1_pfcp_{run}.csv')

    fig, axes = plt.subplots(1, 2, figsize=(10, 4))
    fig.suptitle(f'O1 N4 PFCP Latency — {load_label}', fontsize=12, fontweight='bold')
    for ax, ptype in zip(axes, ['establishment', 'modification']):
        sub = df_pfcp[df_pfcp['pfcp_type'] == ptype]['latency_us'].sort_values()
        if len(sub) == 0:
            continue
        cdf = np.arange(1, len(sub) + 1) / len(sub)
        ax.plot(sub, cdf, color=PFCP_COLORS[ptype], linewidth=2,
                label=f'{ptype} (n={len(sub)})')
        ax.axvline(2000, color='red', linestyle='--', linewidth=1.2, label='2 ms budget')
        ax.set_title(ptype.capitalize(), fontweight='bold')
        ax.set_xlabel('PFCP latency (µs)')
        ax.set_ylabel('CDF')
        ax.set_xlim(left=0)
        ax.grid(True, alpha=0.3)
        ax.legend()
    plt.tight_layout()
    save(fig, f'o1_pfcp_FINAL_{load_short}_single.png')

print('\nAll figures generated.')
print(f'Output: {OUT_DIR}/')
import subprocess
result = subprocess.run(['ls', '-lh', OUT_DIR], capture_output=True, text=True)
print(result.stdout)
