#!/bin/bash
set -uo pipefail

# Sweep cross-partition ratio for multiple workloads & protocols
# Generates data for HW coherent region scalability graph

export GLIBC_TUNABLES=glibc.cpu.hwcaps=-AVX_Usable,-AVX2_Usable,-AVX512F_Usable

VM0="192.168.100.10"
VM1="192.168.100.11"
SSH="ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

RESULTS_DIR="/mnt/ubuntu/cxlmemsim/workloads/tigon"
CROSS_RATIOS=(0 5 10 20 30 50 75 100)

# Note: --servers uses single quotes inside the remote command to protect the semicolon
COMMON_ARGS="--logtostderr=1 --threads=1 --partition_num=2 --granule_count=2000 \
--log_path= --lotus_checkpoint=0 --persist_latency=0 --wal_group_commit_time=0 --wal_group_commit_size=0 \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=15 --time_to_warmup=5 \
--use_cxl_transport=false --use_output_thread=true --cxl_trans_entry_struct_size=65536 --cxl_trans_entry_num=8192"

SERVER_ARG="'--servers=${VM0}:1234;${VM1}:1234'"

function kill_all {
    $SSH root@$VM0 "pkill -9 bench_tpcc; pkill -9 bench_ycsb" 2>/dev/null
    $SSH root@$VM1 "pkill -9 bench_tpcc; pkill -9 bench_ycsb" 2>/dev/null
    sleep 2
}

function extract_results {
    local output="$1"
    local avg_line=$(echo "$output" | grep "average commit:" | tail -1)
    local commit=$(echo "$avg_line" | grep -oP 'average commit: \K[0-9.]+' || echo "0")
    local abort=$(echo "$avg_line" | grep -oP 'abort: \K[0-9.]+' || echo "0")
    echo "${commit},${abort}"
}

function run_tpcc_sweep {
    local protocol=$1
    local query=$2
    local label=$3
    local csv="${RESULTS_DIR}/results_${label}.csv"

    echo ""
    echo "############################################################"
    echo "# ${label}: ${protocol} / ${query}"
    echo "############################################################"
    echo "cross_ratio,hw_cc_equiv,avg_commit_n0,avg_abort_n0,avg_commit_n1,avg_abort_n1,total_commit" > "$csv"

    for ratio in "${CROSS_RATIOS[@]}"; do
        hcc=$((100 - ratio))
        echo "  [${label}] cross=${ratio}% (HCC=${hcc}%) ..."

        kill_all

        # Node 1 background
        $SSH root@$VM1 "export GLIBC_TUNABLES=glibc.cpu.hwcaps=-AVX_Usable,-AVX2_Usable,-AVX512F_Usable; cd pasha; nohup ./bench_tpcc --id=1 ${SERVER_ARG} ${COMMON_ARGS} --protocol=${protocol} --query=${query} --neworder_dist=${ratio} --payment_dist=${ratio} &> output.txt < /dev/null &"

        # Node 0 foreground
        OUTPUT0=$($SSH root@$VM0 "export GLIBC_TUNABLES=glibc.cpu.hwcaps=-AVX_Usable,-AVX2_Usable,-AVX512F_Usable; cd pasha; timeout 150 ./bench_tpcc --id=0 ${SERVER_ARG} ${COMMON_ARGS} --protocol=${protocol} --query=${query} --neworder_dist=${ratio} --payment_dist=${ratio} 2>&1" || true)

        IFS=',' read C0 A0 <<< $(extract_results "$OUTPUT0")

        sleep 2
        OUTPUT1=$($SSH root@$VM1 "cat pasha/output.txt 2>/dev/null" || true)
        IFS=',' read C1 A1 <<< $(extract_results "$OUTPUT1")

        TOTAL=$(echo "$C0 + $C1" | bc 2>/dev/null || echo "0")
        echo "    -> Node0=${C0} Node1=${C1} Total=${TOTAL}"
        echo "${ratio},${hcc},${C0},${A0},${C1},${A1},${TOTAL}" >> "$csv"
    done

    echo "  Saved: ${csv}"
}

function run_ycsb_sweep {
    local protocol=$1
    local label=$2
    local csv="${RESULTS_DIR}/results_${label}.csv"

    echo ""
    echo "############################################################"
    echo "# ${label}: ${protocol} / YCSB RMW"
    echo "############################################################"
    echo "cross_ratio,hw_cc_equiv,avg_commit_n0,avg_abort_n0,avg_commit_n1,avg_abort_n1,total_commit" > "$csv"

    for ratio in "${CROSS_RATIOS[@]}"; do
        hcc=$((100 - ratio))
        echo "  [${label}] cross=${ratio}% (HCC=${hcc}%) ..."

        kill_all

        # Node 1 background
        $SSH root@$VM1 "export GLIBC_TUNABLES=glibc.cpu.hwcaps=-AVX_Usable,-AVX2_Usable,-AVX512F_Usable; cd pasha; nohup ./bench_ycsb --id=1 ${SERVER_ARG} ${COMMON_ARGS} --protocol=${protocol} --query=rmw --keys=200000 --cross_ratio=${ratio} --zipf=0 &> output.txt < /dev/null &"

        # Node 0 foreground
        OUTPUT0=$($SSH root@$VM0 "export GLIBC_TUNABLES=glibc.cpu.hwcaps=-AVX_Usable,-AVX2_Usable,-AVX512F_Usable; cd pasha; timeout 150 ./bench_ycsb --id=0 ${SERVER_ARG} ${COMMON_ARGS} --protocol=${protocol} --query=rmw --keys=200000 --cross_ratio=${ratio} --zipf=0 2>&1" || true)

        IFS=',' read C0 A0 <<< $(extract_results "$OUTPUT0")

        sleep 2
        OUTPUT1=$($SSH root@$VM1 "cat pasha/output.txt 2>/dev/null" || true)
        IFS=',' read C1 A1 <<< $(extract_results "$OUTPUT1")

        TOTAL=$(echo "$C0 + $C1" | bc 2>/dev/null || echo "0")
        echo "    -> Node0=${C0} Node1=${C1} Total=${TOTAL}"
        echo "${ratio},${hcc},${C0},${A0},${C1},${A1},${TOTAL}" >> "$csv"
    done

    echo "  Saved: ${csv}"
}

# Run all sweeps
run_tpcc_sweep TwoPL neworder "tpcc_neworder_twoPL"
run_tpcc_sweep TwoPL payment "tpcc_payment_twoPL"
run_ycsb_sweep TwoPL "ycsb_rmw_twoPL"

kill_all

echo ""
echo "============================================================"
echo "ALL SWEEPS COMPLETE"
echo "============================================================"
for f in ${RESULTS_DIR}/results_*.csv; do
    echo ""
    echo "--- $(basename $f) ---"
    cat "$f"
done
