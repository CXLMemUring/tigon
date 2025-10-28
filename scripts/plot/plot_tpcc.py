#!/usr/bin/env python3

import sys
import math
import pandas as pd
import matplotlib
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker

matplotlib.rcParams['pdf.fonttype'] = 42
matplotlib.rcParams['ps.fonttype'] = 42

if len(sys.argv) != 2:
        print("Usage: " + sys.argv[0] + " RESULT_ROOT_DIR")
        sys.exit(-1)

res_root_dir = sys.argv[1]

DEFAULT_PLOT = {
    "markersize": 10.0,
    "markeredgewidth": 2.4,
    "markevery": 1,
    "linewidth": 2.4,
}

plt.rcParams["font.size"] = 13

### plot TPCC ###
res_csv = res_root_dir + "/tpcc/tpcc.csv"

# Read the CSV file into a Pandas DataFrame
res_df = pd.read_csv(res_csv)

# Extract the data
x = res_df["Remote_Ratio"]

tigon_y = res_df["Tigon"]
sundial_cxl_improved_y = res_df["Sundial-CXL-improved"]
twopl_cxl_improved_y = res_df["TwoPL-CXL-improved"]
motor_y = res_df["Motor"]
sundial_net_y = res_df["Sundial-NET"]
twopl_net_y = res_df["TwoPL-NET"]
tigon_net_y = res_df["Tigon-NET"]

# Create figure with two subplots
fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 4.5))

### LEFT PANEL: Without CXL (Network-based) ###
ax1.grid(axis='y', alpha=0.3, linestyle='--')
ax1.set_xlabel("Multi-partition Transaction Percentage (%)")
ax1.set_ylabel("Throughput (txns/sec)")
ax1.set_title("(a) Without CXL (Network-based)", fontweight='bold', fontsize=14)

# Plot without CXL
ax1.plot(x, sundial_net_y, color="#4372c4", marker="^", **DEFAULT_PLOT, markerfacecolor="none", label="Sundial")
ax1.plot(x, twopl_net_y, color="#ffc003", marker=">", **DEFAULT_PLOT, markerfacecolor="none", label="DS2PL")
ax1.plot(x, tigon_net_y, color="#000000", marker="s", **DEFAULT_PLOT, label="Tigon")
ax1.plot(x, motor_y, color="#ed7d31", marker="o", **DEFAULT_PLOT, markerfacecolor="none", label="Motor")

ax1.set_ylim(0, 800000)
ax1.yaxis.set_major_formatter(ticker.FuncFormatter(lambda x, pos: '{:,.0f}'.format(x/1000) + 'K' if x != 0 else '0'))

legend1 = ax1.legend(loc='upper right', frameon=True, fancybox=False, framealpha=1, edgecolor='black', fontsize=12)
legend1.get_frame().set_linewidth(0.7)

### RIGHT PANEL: With CXL ###
ax2.grid(axis='y', alpha=0.3, linestyle='--')
ax2.set_xlabel("Multi-partition Transaction Percentage (%)")
ax2.set_ylabel("Throughput (txns/sec)")
ax2.set_title("(b) With CXL Memory", fontweight='bold', fontsize=14)

# Plot with CXL
ax2.plot(x, tigon_y, color="#000000", marker="s", **DEFAULT_PLOT, label="Tigon")
ax2.plot(x, sundial_cxl_improved_y, color="#4372c4", marker="^", **DEFAULT_PLOT, markerfacecolor="none", label="Sundial+")
ax2.plot(x, twopl_cxl_improved_y, color="#ffc003", marker=">", **DEFAULT_PLOT, markerfacecolor="none", label="DS2PL+")
ax2.plot(x, motor_y, color="#ed7d31", marker="o", **DEFAULT_PLOT, markerfacecolor="none", label="Motor")

ax2.set_ylim(0, 800000)
ax2.yaxis.set_major_formatter(ticker.FuncFormatter(lambda x, pos: '{:,.0f}'.format(x/1000) + 'K' if x != 0 else '0'))

legend2 = ax2.legend(loc='upper right', frameon=True, fancybox=False, framealpha=1, edgecolor='black', fontsize=12)
legend2.get_frame().set_linewidth(0.7)

plt.tight_layout()
plt.savefig(res_root_dir + "/tpcc/tpcc.pdf", format="pdf", bbox_inches="tight")
