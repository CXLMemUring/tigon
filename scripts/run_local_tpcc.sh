#!/usr/bin/env bash

set -euo pipefail
export CXL_MEMORY_RESOURCE=/dev/dax0.0
export CXL_BACKEND=dax
# Simple single-node TPCC runner for local testing (incl. DAX/mmap)
# - Runs one coordinator (id=0) with a single servers entry (127.0.0.1:1234)
# - Honors CXL_BACKEND and CXL_MEMORY_RESOURCE if provided
# - Passes through any extra CLI args to bench_tpcc

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
BIN_DIR="${SCRIPT_DIR}/../build"
BENCH_BIN="${BIN_DIR}/bench_tpcc"

if [[ ! -x "${BENCH_BIN}" ]]; then
  echo "bench_tpcc not found at ${BENCH_BIN}" >&2
  echo "Build first:" >&2
  echo "  cmake -S ${SCRIPT_DIR}/.. -B ${BIN_DIR}" >&2
  echo "  cmake --build ${BIN_DIR} -j" >&2
  exit 1
fi

# CXL backend flags (optional)
CXL_BACKEND_FLAGS=()
if [[ -n "${CXL_BACKEND:-}" || -n "${CXL_MEMORY_RESOURCE:-}" ]]; then
  if [[ -z "${CXL_BACKEND:-}" ]]; then
    echo "CXL_MEMORY_RESOURCE set but CXL_BACKEND is empty. Set CXL_BACKEND to 'dax' or 'mmap'." >&2
    exit 1
  fi
  if [[ "${CXL_BACKEND}" == "dax" || "${CXL_BACKEND}" == "mmap" ]]; then
    if [[ -z "${CXL_MEMORY_RESOURCE:-}" || "${CXL_MEMORY_RESOURCE}" == "SS" ]]; then
      echo "Backend ${CXL_BACKEND} requires CXL_MEMORY_RESOURCE to be a file/device (not 'SS')." >&2
      exit 1
    fi
  fi
  CXL_BACKEND_FLAGS=("--cxl_backend=${CXL_BACKEND}" "--cxl_memory_resource=${CXL_MEMORY_RESOURCE}")
fi

# Defaults (can be overridden by passing flags via "$@")
THREADS=${THREADS:-3}
PARTITIONS=${PARTITIONS:-3}
QUERY=${QUERY:-mixed}

echo "Running single-node TPCC locally..."
if [[ -n "${CXL_BACKEND_FLAGS[*]:-}" ]]; then
  echo "  CXL backend: ${CXL_BACKEND}"
  echo "  CXL resource: ${CXL_MEMORY_RESOURCE}"
else
  echo "  CXL backend: (defaults in binary; using ivshmem if unconfigured)"
fi
echo "${BENCH_BIN}" \
  --logtostderr=1 \
  --id=0 \
  --servers="127.0.0.1:1234" \
  --threads="${THREADS}" \
  --partition_num="${PARTITIONS}" \
  --query="${QUERY}" \
  "${CXL_BACKEND_FLAGS[@]}" \
  "$@"

 
exec "${BENCH_BIN}" \
  --logtostderr=1 \
  --id=0 \
  --servers="127.0.0.1:1234" \
  --threads="${THREADS}" \
  --partition_num="${PARTITIONS}" \
  --query="${QUERY}" \
  "${CXL_BACKEND_FLAGS[@]}" \
  "$@"

