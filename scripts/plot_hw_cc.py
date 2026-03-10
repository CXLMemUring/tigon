#!/usr/bin/env python3
"""Plot HW Coherent Region scalability graph from sweep results."""

import csv
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np

RESULTS_FILE = "/mnt/ubuntu/cxlmemsim/workloads/tigon/hw_cc_results.csv"
OUTPUT_FILE = "/mnt/ubuntu/cxlmemsim/workloads/tigon/hw_cc_scalability.pdf"
OUTPUT_PNG = "/mnt/ubuntu/cxlmemsim/workloads/tigon/hw_cc_scalability.png"

# Read data
hw_cc = []
total_commits = []
node0_commits = []
node1_commits = []
abort_rates = []

with open(RESULTS_FILE) as f:
    reader = csv.DictReader(f)
    for row in reader:
        hw_cc.append(int(row['hw_cc_equiv']))
        total_commits.append(float(row['total_commit']) / 1000)  # K txn/s
        node0_commits.append(float(row['avg_commit_n0']) / 1000)
        node1_commits.append(float(row['avg_commit_n1']) / 1000)
        c = float(row['avg_commit_n0'])
        a = float(row['avg_abort_n0'])
        abort_rates.append(a / (c + a) * 100 if (c + a) > 0 else 0)

# Sort by hw_cc ascending
indices = np.argsort(hw_cc)
hw_cc = [hw_cc[i] for i in indices]
total_commits = [total_commits[i] for i in indices]
node0_commits = [node0_commits[i] for i in indices]
node1_commits = [node1_commits[i] for i in indices]
abort_rates = [abort_rates[i] for i in indices]

# Create figure with two subplots
fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 5.5))

# --- Left plot: Throughput ---
ax1.plot(hw_cc, total_commits, 'o-', color='#2196F3', linewidth=2.5,
         markersize=8, label='Total (2 nodes)', zorder=3)
ax1.plot(hw_cc, node0_commits, 's--', color='#4CAF50', linewidth=1.5,
         markersize=6, label='Node 0', alpha=0.8, zorder=2)
ax1.plot(hw_cc, node1_commits, '^--', color='#FF9800', linewidth=1.5,
         markersize=6, label='Node 1', alpha=0.8, zorder=2)

ax1.set_xlabel('HW Coherent Region Coverage (%)', fontsize=12)
ax1.set_ylabel('Throughput (K txn/s)', fontsize=12)
ax1.set_title('TPC-C New Order Throughput\nvs. HW Coherent Region Size', fontsize=13)
ax1.legend(fontsize=10, loc='upper left')
ax1.grid(True, alpha=0.3)
ax1.set_xlim(-5, 105)
ax1.set_ylim(0, max(total_commits) * 1.15)

# Add annotations for key points
ax1.annotate(f'{total_commits[0]:.1f}K',
             xy=(hw_cc[0], total_commits[0]),
             xytext=(hw_cc[0] + 8, total_commits[0] - 8),
             fontsize=9, color='#2196F3')
ax1.annotate(f'{total_commits[-1]:.1f}K',
             xy=(hw_cc[-1], total_commits[-1]),
             xytext=(hw_cc[-1] - 18, total_commits[-1] + 8),
             fontsize=9, color='#2196F3')

# --- Right plot: Speedup relative to 0% HCC ---
baseline = total_commits[0]  # 0% HCC (all remote)
speedups = [t / baseline for t in total_commits]

ax2.bar(range(len(hw_cc)), speedups, color=['#E53935' if s < 2 else '#FF9800' if s < 5 else '#4CAF50' if s < 10 else '#2196F3' for s in speedups],
        alpha=0.85, edgecolor='white', linewidth=0.5)
ax2.set_xticks(range(len(hw_cc)))
ax2.set_xticklabels([f'{h}%' for h in hw_cc], fontsize=10)
ax2.set_xlabel('HW Coherent Region Coverage (%)', fontsize=12)
ax2.set_ylabel('Speedup over 0% HCC', fontsize=12)
ax2.set_title('Speedup from HW Coherent Region\n(TPC-C New Order, 2 nodes)', fontsize=13)
ax2.grid(True, alpha=0.3, axis='y')

# Add value labels on bars
for i, (s, h) in enumerate(zip(speedups, hw_cc)):
    ax2.text(i, s + 0.15, f'{s:.1f}x', ha='center', fontsize=9, fontweight='bold')

plt.tight_layout()
plt.savefig(OUTPUT_FILE, dpi=150, bbox_inches='tight')
plt.savefig(OUTPUT_PNG, dpi=150, bbox_inches='tight')
print(f"Saved: {OUTPUT_FILE}")
print(f"Saved: {OUTPUT_PNG}")

# Print summary table
print("\n" + "="*70)
print(f"{'HW CC (%)':>10} {'Total (K/s)':>14} {'Node0 (K/s)':>14} {'Node1 (K/s)':>14} {'Speedup':>10}")
print("="*70)
for i in range(len(hw_cc)):
    print(f"{hw_cc[i]:>10}% {total_commits[i]:>13.1f} {node0_commits[i]:>13.1f} {node1_commits[i]:>13.1f} {speedups[i]:>9.1f}x")
print("="*70)
