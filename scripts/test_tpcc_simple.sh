#!/bin/bash
# Simple test script - manually start both nodes

set -e

echo "========================================="
echo "Starting TPCC on 2 nodes with DAX"
echo "========================================="
echo ""

# Kill any existing processes
echo "Killing previous processes..."
ssh root@192.168.100.10 "pkill bench_tpcc || true"
ssh root@192.168.100.11 "pkill bench_tpcc || true"
sleep 2

# Common parameters
SERVERS="192.168.100.10:1234;192.168.100.11:1234"
THREADS=2
PARTITION_NUM=4
PROTOCOL="TwoPLPasha"
QUERY="mixed"

# Start node 1 (background)
echo "Starting Node 1 (192.168.100.11) in background..."
ssh -f root@192.168.100.11 "cd ~/pasha && nohup ./bench_tpcc \
  --logtostderr=1 \
  --id=1 \
  --servers='${SERVERS}' \
  --threads=${THREADS} \
  --partition_num=${PARTITION_NUM} \
  --protocol=${PROTOCOL} \
  --query=${QUERY} \
  --neworder_dist=10 \
  --payment_dist=15 \
  --cxl_backend=dax \
  --cxl_memory_resource=/dev/dax0.0 \
  --time_to_run=10 \
  --time_to_warmup=3 \
  --partitioner=hash \
  --granule_count=2000 \
  --use_cxl_transport=1 \
  --use_output_thread=0 \
  --cxl_trans_entry_struct_size=2048 \
  --cxl_trans_entry_num=8192 \
  --enable_migration_optimization=1 \
  --migration_policy=Clock \
  --when_to_move_out=OnDemand \
  --hw_cc_budget=200000000 \
  --enable_scc=1 \
  --scc_mechanism=WriteThrough \
  --pre_migrate=None \
  --log_path=/root/pasha_log \
  --lotus_checkpoint=0 \
  --persist_latency=0 \
  --wal_group_commit_time=0 \
  --wal_group_commit_size=0 \
  --hstore_command_logging=false \
  --replica_group=1 \
  --lock_manager=0 \
  --batch_flush=1 \
  --lotus_async_repl=true \
  --batch_size=0 \
  > output.txt 2>&1 < /dev/null &"

echo "✓ Node 1 started"
echo "Waiting 3 seconds for node 1 to initialize..."
sleep 3

# Start node 0 (foreground - we'll see the output)
echo ""
echo "Starting Node 0 (192.168.100.10)..."
echo "========================================="
ssh root@192.168.100.10 "cd ~/pasha && ./bench_tpcc \
  --logtostderr=1 \
  --id=0 \
  --servers='${SERVERS}' \
  --threads=${THREADS} \
  --partition_num=${PARTITION_NUM} \
  --protocol=${PROTOCOL} \
  --query=${QUERY} \
  --neworder_dist=10 \
  --payment_dist=15 \
  --cxl_backend=dax \
  --cxl_memory_resource=/dev/dax0.0 \
  --time_to_run=10 \
  --time_to_warmup=3 \
  --partitioner=hash \
  --granule_count=2000 \
  --use_cxl_transport=1 \
  --use_output_thread=0 \
  --cxl_trans_entry_struct_size=2048 \
  --cxl_trans_entry_num=8192 \
  --enable_migration_optimization=1 \
  --migration_policy=Clock \
  --when_to_move_out=OnDemand \
  --hw_cc_budget=200000000 \
  --enable_scc=1 \
  --scc_mechanism=WriteThrough \
  --pre_migrate=None \
  --log_path=/root/pasha_log \
  --lotus_checkpoint=0 \
  --persist_latency=0 \
  --wal_group_commit_time=0 \
  --wal_group_commit_size=0 \
  --hstore_command_logging=false \
  --replica_group=1 \
  --lock_manager=0 \
  --batch_flush=1 \
  --lotus_async_repl=true \
  --batch_size=0"

echo ""
echo "========================================="
echo "Benchmark complete!"
echo "========================================="
echo ""
echo "View node 1 output:"
echo "  ssh root@192.168.100.11 'cat ~/pasha/output.txt'"
