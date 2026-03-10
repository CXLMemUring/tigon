#!/bin/bash
set -uo pipefail

# Sweep cross-partition ratio to simulate effect of different HW coherent region sizes
# Higher HW coherent region → more data cached locally → fewer cross-partition txns
# Usage: ./sweep_hw_cc.sh

export GLIBC_TUNABLES=glibc.cpu.hwcaps=-AVX_Usable,-AVX2_Usable,-AVX512F_Usable

VM0="192.168.100.10"
VM1="192.168.100.11"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SERVER_STRING="${VM0}:1234;${VM1}:1234"

RESULTS_FILE="/mnt/ubuntu/cxlmemsim/workloads/tigon/hw_cc_results.csv"

# Cross-partition ratios to sweep
# Maps to HW coherent region: 0% cross = unlimited HCC, 100% cross = no HCC
CROSS_RATIOS=(0 5 10 20 30 50 75 100)

echo "cross_ratio,hw_cc_equiv,avg_commit_n0,avg_abort_n0,avg_commit_n1,avg_abort_n1,total_commit" > "$RESULTS_FILE"

for ratio in "${CROSS_RATIOS[@]}"; do
    # HW coherent region equivalent: 100% - cross_ratio
    hcc_equiv=$((100 - ratio))
    echo "=========================================="
    echo "Cross-partition ratio = ${ratio}% (HW Coherent Region ~ ${hcc_equiv}%)"
    echo "=========================================="

    # Kill previous
    ssh $SSH_OPTS root@$VM0 "pkill -9 bench_tpcc" 2>/dev/null
    ssh $SSH_OPTS root@$VM1 "pkill -9 bench_tpcc" 2>/dev/null
    sleep 2

    # Launch node 1 (background)
    ssh $SSH_OPTS root@$VM1 "export GLIBC_TUNABLES=glibc.cpu.hwcaps=-AVX_Usable,-AVX2_Usable,-AVX512F_Usable; cd pasha; nohup ./bench_tpcc --logtostderr=1 --id=1 --servers='${SERVER_STRING}' \
--threads=1 --partition_num=2 --granule_count=2000 \
--log_path= --lotus_checkpoint=0 --persist_latency=0 --wal_group_commit_time=0 --wal_group_commit_size=0 \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=15 --time_to_warmup=5 \
--use_cxl_transport=false --use_output_thread=true --cxl_trans_entry_struct_size=65536 --cxl_trans_entry_num=8192 \
--protocol=TwoPL --query=neworder --neworder_dist=${ratio} --payment_dist=0 &> output.txt < /dev/null &"

    # Launch node 0 (foreground, capture output)
    OUTPUT0=$(ssh $SSH_OPTS root@$VM0 "export GLIBC_TUNABLES=glibc.cpu.hwcaps=-AVX_Usable,-AVX2_Usable,-AVX512F_Usable; cd pasha; timeout 150 ./bench_tpcc --logtostderr=1 --id=0 --servers='${SERVER_STRING}' \
--threads=1 --partition_num=2 --granule_count=2000 \
--log_path= --lotus_checkpoint=0 --persist_latency=0 --wal_group_commit_time=0 --wal_group_commit_size=0 \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=15 --time_to_warmup=5 \
--use_cxl_transport=false --use_output_thread=true --cxl_trans_entry_struct_size=65536 --cxl_trans_entry_num=8192 \
--protocol=TwoPL --query=neworder --neworder_dist=${ratio} --payment_dist=0 2>&1" || true)

    # Extract average commit/abort from node 0
    AVG_LINE0=$(echo "$OUTPUT0" | grep "average commit:" | tail -1)
    COMMIT0=$(echo "$AVG_LINE0" | grep -oP 'average commit: \K[0-9.]+' || echo "0")
    ABORT0=$(echo "$AVG_LINE0" | grep -oP 'abort: \K[0-9.]+' || echo "0")

    # Get node 1 output
    sleep 2
    OUTPUT1=$(ssh $SSH_OPTS root@$VM1 "cat pasha/output.txt 2>/dev/null" || true)
    AVG_LINE1=$(echo "$OUTPUT1" | grep "average commit:" | tail -1)
    COMMIT1=$(echo "$AVG_LINE1" | grep -oP 'average commit: \K[0-9.]+' || echo "0")
    ABORT1=$(echo "$AVG_LINE1" | grep -oP 'abort: \K[0-9.]+' || echo "0")

    # Total
    TOTAL=$(echo "$COMMIT0 + $COMMIT1" | bc 2>/dev/null || echo "0")

    echo "  Node 0: commit=${COMMIT0}/s abort=${ABORT0}/s"
    echo "  Node 1: commit=${COMMIT1}/s abort=${ABORT1}/s"
    echo "  Total:  ${TOTAL}/s"

    echo "${ratio},${hcc_equiv},${COMMIT0},${ABORT0},${COMMIT1},${ABORT1},${TOTAL}" >> "$RESULTS_FILE"

    # Cleanup
    ssh $SSH_OPTS root@$VM0 "pkill -9 bench_tpcc" 2>/dev/null
    ssh $SSH_OPTS root@$VM1 "pkill -9 bench_tpcc" 2>/dev/null
    sleep 2
done

echo ""
echo "=========================================="
echo "Results saved to: ${RESULTS_FILE}"
echo "=========================================="
cat "$RESULTS_FILE"
