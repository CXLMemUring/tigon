#!/bin/bash
# Script to run Tigon with DAX/mmap on remote nodes

set -e

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
BIN_DIR="${SCRIPT_DIR}/../build"

# Configuration
NODE1="192.168.100.10"
NODE2="192.168.100.11"
CXL_BACKEND="dax"
CXL_MEMORY_RESOURCE="/dev/dax0.0"

echo "==================================="
echo "Tigon DAX Test Runner"
echo "==================================="
echo "Backend: ${CXL_BACKEND}"
echo "Resource: ${CXL_MEMORY_RESOURCE}"
echo "Node 1: ${NODE1}"
echo "Node 2: ${NODE2}"
echo "==================================="
echo ""

# Check binary
if [ ! -f "${BIN_DIR}/bench_tpcc" ]; then
    echo "ERROR: bench_tpcc not found at ${BIN_DIR}/bench_tpcc"
    echo "Build first with:"
    echo "  cmake -B ${BIN_DIR} -S ${SCRIPT_DIR}/.."
    echo "  cmake --build ${BIN_DIR} -j"
    exit 1
fi

# Copy binary to nodes
echo "Copying binary to nodes..."
scp "${BIN_DIR}/bench_tpcc" "root@${NODE1}:/tmp/"
scp "${BIN_DIR}/bench_tpcc" "root@${NODE2}:/tmp/"
echo "✓ Binary copied"
echo ""

# Function to run on node
run_node() {
    local node=$1
    local id=$2
    local servers="${NODE1}:1234;${NODE2}:1234"

    echo "Starting node ${id} on ${node}..."
    ssh root@${node} "cd /tmp && \
        CXL_BACKEND=${CXL_BACKEND} \
        CXL_MEMORY_RESOURCE=${CXL_MEMORY_RESOURCE} \
        ./bench_tpcc \
        --logtostderr=1 \
        --id=${id} \
        --servers='${servers}' \
        --threads=2 \
        --partition_num=2 \
        --cxl_backend=${CXL_BACKEND} \
        --cxl_memory_resource=${CXL_MEMORY_RESOURCE}" &

    echo "✓ Node ${id} started (PID: $!)"
}

# Start nodes
echo "Starting Tigon on both nodes..."
echo ""

run_node "${NODE1}" 0
sleep 2
run_node "${NODE2}" 1

echo ""
echo "==================================="
echo "Both nodes started!"
echo "==================================="
echo "Monitor logs on each node:"
echo "  ssh root@${NODE1} 'tail -f /tmp/tigon.log'"
echo "  ssh root@${NODE2} 'tail -f /tmp/tigon.log'"
echo ""
echo "To kill:"
echo "  ssh root@${NODE1} 'pkill bench_tpcc'"
echo "  ssh root@${NODE2} 'pkill bench_tpcc'"
echo ""

wait
