#!/usr/bin/env python3
"""Plot HW Coherent Region scalability graph for all workloads."""

import csv
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np

RESULTS_DIR = "/mnt/ubuntu/cxlmemsim/workloads/tigon"
OUTPUT_PDF = f"{RESULTS_DIR}/hw_cc_all_workloads.pdf"
OUTPUT_PNG = f"{RESULTS_DIR}/hw_cc_all_workloads.png"

WORKLOADS = [
    ("results_tpcc_neworder_twoPL.csv", "TPC-C NewOrder"),
    ("results_tpcc_payment_twoPL.csv", "TPC-C Payment"),
    ("results_ycsb_rmw_twoPL.csv", "YCSB RMW"),
]

COLORS = ['#2196F3', '#E53935', '#4CAF50']
MARKERS = ['o', 's', '^']

def read_csv(path):
    hw_cc, total = [], []
    with open(path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            hw_cc.append(int(row['hw_cc_equiv']))
            total.append(float(row['total_commit']))
    indices = np.argsort(hw_cc)
    return [hw_cc[i] for i in indices], [total[i] for i in indices]

fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 5.5))

all_data = []
for (fname, label), color, marker in zip(WORKLOADS, COLORS, MARKERS):
    hw_cc, total = read_csv(f"{RESULTS_DIR}/{fname}")
    total_k = [t / 1000 for t in total]
    all_data.append((hw_cc, total, total_k, label, color, marker))

    ax1.plot(hw_cc, total_k, f'{marker}-', color=color, linewidth=2.5,
             markersize=8, label=label, zorder=3)

ax1.set_xlabel('HW Coherent Region Coverage (%)', fontsize=12)
ax1.set_ylabel('Throughput (K txn/s)', fontsize=12)
ax1.set_title('Throughput vs. HW Coherent Region Size\n(TwoPL, 2 nodes, TCP transport)', fontsize=13)
ax1.legend(fontsize=10, loc='upper left')
ax1.grid(True, alpha=0.3)
ax1.set_xlim(-5, 105)

# --- Right plot: Speedup (normalized to 0% HCC baseline for each workload) ---
bar_width = 0.25
x = np.arange(len(all_data[0][0]))

for idx, (hw_cc, total, total_k, label, color, marker) in enumerate(all_data):
    baseline = total[0]  # 0% HCC = worst case
    speedups = [t / baseline for t in total]
    bars = ax2.bar(x + idx * bar_width, speedups, bar_width,
                   color=color, alpha=0.85, label=label, edgecolor='white', linewidth=0.5)
    for i, s in enumerate(speedups):
        if s > 2:
            ax2.text(x[i] + idx * bar_width, s + 0.3, f'{s:.0f}x',
                     ha='center', fontsize=7, fontweight='bold', color=color)

ax2.set_xticks(x + bar_width)
ax2.set_xticklabels([f'{h}%' for h in all_data[0][0]], fontsize=10)
ax2.set_xlabel('HW Coherent Region Coverage (%)', fontsize=12)
ax2.set_ylabel('Speedup over 0% HCC', fontsize=12)
ax2.set_title('Speedup from HW Coherent Region\n(TwoPL, 2 nodes)', fontsize=13)
ax2.legend(fontsize=9, loc='upper left')
ax2.grid(True, alpha=0.3, axis='y')

plt.tight_layout()
plt.savefig(OUTPUT_PDF, dpi=150, bbox_inches='tight')
plt.savefig(OUTPUT_PNG, dpi=150, bbox_inches='tight')
print(f"Saved: {OUTPUT_PDF}")
print(f"Saved: {OUTPUT_PNG}")

# Print summary table
for hw_cc, total, total_k, label, color, marker in all_data:
    baseline = total[0]
    print(f"\n{'='*60}")
    print(f"  {label}")
    print(f"{'='*60}")
    print(f"{'HCC (%)':>10} {'Total (K/s)':>14} {'Speedup':>10}")
    print(f"{'-'*36}")
    for i in range(len(hw_cc)):
        s = total[i] / baseline
        print(f"{hw_cc[i]:>10}% {total_k[i]:>13.1f} {s:>9.1f}x")
