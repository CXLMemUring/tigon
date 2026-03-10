#!/usr/bin/env python3
"""Plot throughput vs read_write_ratio for Tigon, DS2PL+, Sundial+, and Motor."""
import csv
import sys
import os

def main():
    result_dir = sys.argv[1] if len(sys.argv) > 1 else "/mnt/ubuntu/cxlmemsim/workloads/tigon/results/rw_ratio_sweep"
    csv_file = os.path.join(result_dir, "results.csv")

    if not os.path.exists(csv_file):
        print(f"Error: {csv_file} not found")
        sys.exit(1)

    # Read data, skipping failed runs (throughput=0 with bad abort_rate)
    data = {}
    with open(csv_file) as f:
        reader = csv.DictReader(f)
        for row in reader:
            proto = row["protocol"]
            rw = int(row["read_write_ratio"])
            try:
                tp = float(row["throughput"])
            except (ValueError, TypeError):
                tp = 0.0
            # Skip failed runs (0 throughput is likely a failure)
            if tp <= 0:
                print(f"  Skipping failed run: {proto} rw={rw} (throughput={row['throughput']})")
                continue
            if proto not in data:
                data[proto] = {}
            data[proto][rw] = tp

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import matplotlib.ticker as ticker

    fig, ax = plt.subplots(figsize=(8, 5))

    styles = {
        "Tigon":    {"color": "#e41a1c", "marker": "o", "linestyle": "-"},
        "DS2PL+":   {"color": "#377eb8", "marker": "s", "linestyle": "--"},
        "Sundial+": {"color": "#4daf4a", "marker": "^", "linestyle": "-."},
        "Motor":    {"color": "#984ea3", "marker": "D", "linestyle": ":"},
    }

    for proto in ["Tigon", "DS2PL+", "Sundial+", "Motor"]:
        if proto not in data:
            continue
        rws = sorted(data[proto].keys())
        tps = [data[proto][r] for r in rws]
        s = styles.get(proto, {"color": "gray", "marker": "x", "linestyle": "-"})
        ax.plot(rws, tps, label=proto, marker=s["marker"], color=s["color"],
                linestyle=s["linestyle"], linewidth=2, markersize=7)

    ax.set_xlabel("Read/Write Ratio (%)", fontsize=13)
    ax.set_ylabel("Throughput (txn/sec)", fontsize=13)
    ax.set_title("YCSB Throughput vs Read/Write Ratio", fontsize=14)
    ax.legend(fontsize=11, loc="upper left")
    ax.grid(True, alpha=0.3)
    ax.set_xticks(range(0, 101, 10))
    ax.set_xlim(-2, 102)
    ax.yaxis.set_minor_locator(ticker.AutoMinorLocator())

    plt.tight_layout()
    out_pdf = os.path.join(result_dir, "rw_ratio_throughput.pdf")
    out_png = os.path.join(result_dir, "rw_ratio_throughput.png")
    plt.savefig(out_pdf, dpi=150)
    plt.savefig(out_png, dpi=150)
    print(f"Plot saved to {out_pdf} and {out_png}")

if __name__ == "__main__":
    main()
