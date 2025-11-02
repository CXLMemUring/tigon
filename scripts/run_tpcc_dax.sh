#!/bin/bash

# Wrapper script to run TPCC with DAX backend
# This sets up environment variables and calls run.sh with proper parameters

set -e

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# ============================================================================
# CXL Backend Configuration for DAX
# ============================================================================
export CXL_BACKEND="dax"
export CXL_MEMORY_RESOURCE="/dev/dax0.0"

echo "========================================="
echo "Running Tigon TPCC with DAX Backend"
echo "========================================="
echo "Backend: ${CXL_BACKEND}"
echo "Resource: ${CXL_MEMORY_RESOURCE}"
echo "========================================="
echo ""

# Default parameters (can override via command line)
PROTOCOL=${1:-TwoPLPasha}
HOST_NUM=${2:-2}
WORKER_NUM=${3:-3}
QUERY_TYPE=${4:-mixed}
REMOTE_NEWORDER_PERC=${5:-10}
REMOTE_PAYMENT_PERC=${6:-15}
USE_CXL_TRANS=${7:-1}
USE_OUTPUT_THREAD=${8:-0}
ENABLE_MIGRATION_OPTIMIZATION=${9:-1}
MIGRATION_POLICY=${10:-Clock}
WHEN_TO_MOVE_OUT=${11:-OnDemand}
HW_CC_BUDGET=${12:-200000000}
ENABLE_SCC=${13:-1}
SCC_MECH=${14:-WriteThrough}
PRE_MIGRATE=${15:-None}
TIME_TO_RUN=${16:-30}
TIME_TO_WARMUP=${17:-10}
LOGGING_TYPE=${18:-BLACKHOLE}
EPOCH_LEN=${19:-20000}
MODEL_CXL_SEARCH=${20:-0}
GATHER_OUTPUTS=${21:-0}

echo "Parameters:"
echo "  Protocol: ${PROTOCOL}"
echo "  Hosts: ${HOST_NUM}"
echo "  Workers: ${WORKER_NUM}"
echo "  Query Type: ${QUERY_TYPE}"
echo "  Runtime: ${TIME_TO_RUN}s (warmup: ${TIME_TO_WARMUP}s)"
echo ""

# Call the main run.sh script
${SCRIPT_DIR}/run.sh TPCC \
    ${PROTOCOL} \
    ${HOST_NUM} \
    ${WORKER_NUM} \
    ${QUERY_TYPE} \
    ${REMOTE_NEWORDER_PERC} \
    ${REMOTE_PAYMENT_PERC} \
    ${USE_CXL_TRANS} \
    ${USE_OUTPUT_THREAD} \
    ${ENABLE_MIGRATION_OPTIMIZATION} \
    ${MIGRATION_POLICY} \
    ${WHEN_TO_MOVE_OUT} \
    ${HW_CC_BUDGET} \
    ${ENABLE_SCC} \
    ${SCC_MECH} \
    ${PRE_MIGRATE} \
    ${TIME_TO_RUN} \
    ${TIME_TO_WARMUP} \
    ${LOGGING_TYPE} \
    ${EPOCH_LEN} \
    ${MODEL_CXL_SEARCH} \
    ${GATHER_OUTPUTS}
