#!/bin/bash
# Manual TPCC launcher - starts Node 0 first, then Node 1

set -e

echo "========================================="
echo "TPCC Manual Launcher with DAX"
echo "========================================="
echo ""

# Clean up
echo "[1/4] 清理之前的进程..."
ssh root@192.168.100.10 "pkill -9 bench_tpcc || true"
ssh root@192.168.100.11 "pkill -9 bench_tpcc || true"
sleep 2

# Common parameters
SERVERS="192.168.100.10:1234;192.168.100.11:1234"
THREADS=1
PARTITION_NUM=2
TIME_TO_RUN=10
TIME_TO_WARMUP=2

# Start Node 0 FIRST in background (it initializes shared memory)
echo "[2/4] 启动 Node 0 (192.168.100.10) - 初始化共享内存..."
ssh root@192.168.100.10 "cd ~/pasha && rm -f output.txt"

# Use a background job marker file to track when Node 0 is ready
ssh root@192.168.100.10 "cd ~/pasha && ./bench_tpcc \
  --logtostderr=1 \
  --id=0 \
  --servers='${SERVERS}' \
  --threads=${THREADS} \
  --partition_num=${PARTITION_NUM} \
  --protocol=TwoPLPasha \
  --query=mixed \
  --neworder_dist=10 \
  --payment_dist=15 \
  --cxl_backend=dax \
  --cxl_memory_resource=/dev/dax0.0 \
  --time_to_run=${TIME_TO_RUN} \
  --time_to_warmup=${TIME_TO_WARMUP} \
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
  --hstore_command_logging=false \
  --replica_group=1 \
  --lock_manager=0 \
  --batch_flush=1 \
  --lotus_async_repl=true \
  --batch_size=0 \
  > output.txt 2>&1 < /dev/null &"

echo "   等待 Node 0 初始化共享内存..."
sleep 5

# Check if Node 0 initialized shared data
for i in {1..30}; do
    INIT_DONE=$(ssh root@192.168.100.10 "grep 'initializes CXL transport metadata' ~/pasha/output.txt 2>/dev/null || echo ''")
    if [ -n "$INIT_DONE" ]; then
        echo "   ✓ Node 0 已初始化CXL transport"
        break
    fi
    echo "   等待中... ($i/30)"
    sleep 1
done

# Start Node 1 (it will wait for Node 0's shared data)
echo "[3/4] 启动 Node 1 (192.168.100.11)..."
ssh root@192.168.100.11 "cd ~/pasha && rm -f output.txt"

ssh root@192.168.100.11 "cd ~/pasha && ./bench_tpcc \
  --logtostderr=1 \
  --id=1 \
  --servers='${SERVERS}' \
  --threads=${THREADS} \
  --partition_num=${PARTITION_NUM} \
  --protocol=TwoPLPasha \
  --query=mixed \
  --neworder_dist=10 \
  --payment_dist=15 \
  --cxl_backend=dax \
  --cxl_memory_resource=/dev/dax0.0 \
  --time_to_run=${TIME_TO_RUN} \
  --time_to_warmup=${TIME_TO_WARMUP} \
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
  --hstore_command_logging=false \
  --replica_group=1 \
  --lock_manager=0 \
  --batch_flush=1 \
  --lotus_async_repl=true \
  --batch_size=0 \
  > output.txt 2>&1 < /dev/null &"

echo "   ✓ Node 1 已启动"
echo ""
echo "[4/4] 等待基准测试完成..."
echo "   运行时间: ${TIME_TO_RUN}秒 (预热: ${TIME_TO_WARMUP}秒)"
echo ""

# Wait for benchmark to complete
TOTAL_TIME=$((TIME_TO_RUN + TIME_TO_WARMUP + 5))
for i in $(seq 1 $TOTAL_TIME); do
    echo -ne "   进度: $i/${TOTAL_TIME}秒\r"
    sleep 1
done

echo ""
echo ""
echo "========================================="
echo "基准测试应该已完成"
echo "========================================="
echo ""

# Show results
echo "Node 0 输出:"
ssh root@192.168.100.10 "tail -30 ~/pasha/output.txt"
echo ""
echo "========================================="
echo ""
echo "Node 1 输出:"
ssh root@192.168.100.11 "tail -30 ~/pasha/output.txt"
