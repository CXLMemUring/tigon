#!/bin/bash
# Sweep read_write_ratio (0-100) for Tigon, DS2PL+, and Sundial+ with DAX CXL transport

RESULT_DIR=${RESULT_DIR:-/mnt/ubuntu/cxlmemsim/workloads/tigon/results/rw_ratio_sweep}
mkdir -p "$RESULT_DIR"

# VM configuration (VM0=id0, VM1=id1)
VM0=192.168.100.11
VM1=192.168.100.10
SERVERS="${VM0}:1234;${VM1}:1234"

TIME_TO_RUN=15
TIME_TO_WARMUP=5

CSV_FILE="$RESULT_DIR/results.csv"
echo "protocol,read_write_ratio,throughput,abort_rate" > "$CSV_FILE"

run_one() {
    local PROTOCOL_NAME=$1
    shift
    local RW_RATIO=$1
    shift
    local EXTRA_FLAGS="$@"

    local RUN_ID="${PROTOCOL_NAME}_rw${RW_RATIO}"
    echo "===== Running $PROTOCOL_NAME with read_write_ratio=$RW_RATIO ====="

    # Kill previous processes
    ssh root@$VM0 "pkill -9 bench_ycsb 2>/dev/null; true" 2>/dev/null
    ssh root@$VM1 "pkill -9 bench_ycsb 2>/dev/null; true" 2>/dev/null
    sleep 2

    # Start VM0 (id=0) first - initializes CXL shared memory
    ssh root@$VM0 "nohup ~/pasha/run_bench.sh 0 '${SERVERS}' --read_write_ratio=$RW_RATIO $EXTRA_FLAGS </dev/null >/dev/null 2>&1 &" </dev/null

    # Wait for CXL init
    echo "  Waiting for VM0 CXL init..."
    local FOUND=0
    for i in $(seq 1 90); do
        local INIT
        INIT=$(ssh root@$VM0 "grep -c 'initializes CXL transport metadata' ~/pasha/output.txt 2>/dev/null" 2>/dev/null || true)
        if [ "${INIT:-0}" -ge 1 ] 2>/dev/null; then
            echo "  VM0 CXL initialized (${i}s)"
            FOUND=1
            break
        fi
        sleep 1
    done
    if [ "$FOUND" = "0" ]; then
        echo "  WARNING: VM0 CXL init timeout, continuing anyway..."
    fi

    # Start VM1 (id=1)
    ssh root@$VM1 "nohup ~/pasha/run_bench.sh 1 '${SERVERS}' --read_write_ratio=$RW_RATIO $EXTRA_FLAGS </dev/null >/dev/null 2>&1 &" </dev/null

    # Wait for benchmark to complete
    local TOTAL_WAIT=$((TIME_TO_RUN + TIME_TO_WARMUP + 30))
    echo "  Waiting ${TOTAL_WAIT}s for completion..."
    sleep $TOTAL_WAIT

    # Extract results from VM0
    local OUTPUT
    OUTPUT=$(ssh root@$VM0 "cat ~/pasha/output.txt" 2>/dev/null || true)

    # Save full output
    echo "$OUTPUT" > "$RESULT_DIR/${RUN_ID}_vm0.txt"
    ssh root@$VM1 "cat ~/pasha/output.txt" 2>/dev/null > "$RESULT_DIR/${RUN_ID}_vm1.txt" || true

    # Parse throughput: "average commit: X.Y"
    local THROUGHPUT
    THROUGHPUT=$(echo "$OUTPUT" | grep "average commit:" | tail -1 | sed 's/.*average commit: \([0-9.]*\).*/\1/' || true)
    local ABORT_RATE
    ABORT_RATE=$(echo "$OUTPUT" | grep "abort_rate:" | tail -1 | sed 's/.*abort_rate: \([0-9.e+-]*\).*/\1/' || true)

    if [ -z "$THROUGHPUT" ]; then
        echo "  WARNING: Could not extract throughput for $RUN_ID"
        THROUGHPUT="0"
        ABORT_RATE="0"
    else
        echo "  Result: throughput=$THROUGHPUT, abort_rate=$ABORT_RATE"
    fi

    echo "$PROTOCOL_NAME,$RW_RATIO,$THROUGHPUT,$ABORT_RATE" >> "$CSV_FILE"

    # Kill processes
    ssh root@$VM0 "pkill -9 bench_ycsb 2>/dev/null; true" 2>/dev/null
    ssh root@$VM1 "pkill -9 bench_ycsb 2>/dev/null; true" 2>/dev/null
    sleep 2
}

# Protocol-specific extra flags
TIGON_EXTRA="--protocol=TwoPLPasha --enable_migration_optimization=true --migration_policy=Clock --when_to_move_out=OnDemand --hw_cc_budget=104857600 --enable_scc=true --scc_mechanism=WriteThrough"
DS2PL_EXTRA="--protocol=TwoPL"
SUNDIAL_EXTRA="--protocol=Sundial"

RW_RATIOS="0 10 20 30 40 50 60 70 80 90 100"

echo "Starting sweep: protocols=Tigon,DS2PL+,Sundial+ ratios=$RW_RATIOS"
echo "Results will be saved to $CSV_FILE"
echo ""

for rw in $RW_RATIOS; do
    run_one "Tigon" "$rw" $TIGON_EXTRA
    run_one "DS2PL+" "$rw" $DS2PL_EXTRA
    run_one "Sundial+" "$rw" $SUNDIAL_EXTRA
done

echo ""
echo "===== Sweep complete ====="
echo "Results saved to $CSV_FILE"
cat "$CSV_FILE"
