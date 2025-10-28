#!/bin/bash

# DAX Setup Verification Script for Tigon
# This script checks if your system is properly configured for DAX/mmap mode

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Tigon DAX Setup Verification${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check 1: Environment Variables
echo -e "${BLUE}[1] Checking Environment Variables${NC}"
echo -n "  CXL_BACKEND: "
if [ -n "$CXL_BACKEND" ]; then
    echo -e "${GREEN}$CXL_BACKEND${NC}"
else
    echo -e "${YELLOW}Not set (will use default: mmap)${NC}"
fi

echo -n "  CXL_MEMORY_RESOURCE: "
if [ -n "$CXL_MEMORY_RESOURCE" ]; then
    echo -e "${GREEN}$CXL_MEMORY_RESOURCE${NC}"
else
    echo -e "${YELLOW}Not set (will use default: SS - shared memory)${NC}"
fi
echo ""

# Check 2: DAX Devices
echo -e "${BLUE}[2] Checking for DAX Devices${NC}"
if command -v daxctl &> /dev/null; then
    echo "  daxctl is installed"
    dax_count=$(daxctl list 2>/dev/null | grep -c "chardev" || echo "0")
    if [ "$dax_count" -gt 0 ]; then
        echo -e "  ${GREEN}Found $dax_count DAX device(s)${NC}"
        daxctl list 2>/dev/null | grep -E "chardev|size" | sed 's/^/    /'
    else
        echo -e "  ${YELLOW}No DAX devices found${NC}"
    fi
else
    echo -e "  ${YELLOW}daxctl not installed (install with: apt-get install daxctl)${NC}"
fi

# List /dev/dax* devices
if ls /dev/dax* &>/dev/null; then
    echo "  DAX character devices:"
    ls -lh /dev/dax* | sed 's/^/    /'
else
    echo -e "  ${YELLOW}No /dev/dax* devices found${NC}"
fi
echo ""

# Check 3: NVDIMM/PMEM Devices
echo -e "${BLUE}[3] Checking for NVDIMM/PMEM Devices${NC}"
if command -v ndctl &> /dev/null; then
    echo "  ndctl is installed"
    ns_count=$(ndctl list -N 2>/dev/null | grep -c "dev" || echo "0")
    if [ "$ns_count" -gt 0 ]; then
        echo -e "  ${GREEN}Found $ns_count namespace(s)${NC}"
        ndctl list -N 2>/dev/null | sed 's/^/    /'
    else
        echo -e "  ${YELLOW}No NVDIMM namespaces found${NC}"
    fi
else
    echo -e "  ${YELLOW}ndctl not installed (install with: apt-get install ndctl)${NC}"
fi

# List /dev/pmem* devices
if ls /dev/pmem* &>/dev/null; then
    echo "  PMEM block devices:"
    ls -lh /dev/pmem* | sed 's/^/    /'
else
    echo -e "  ${YELLOW}No /dev/pmem* devices found${NC}"
fi
echo ""

# Check 4: CXL Devices
echo -e "${BLUE}[4] Checking for CXL Devices${NC}"
if [ -d /sys/bus/cxl/devices ]; then
    cxl_count=$(ls -1 /sys/bus/cxl/devices/ 2>/dev/null | wc -l)
    if [ "$cxl_count" -gt 0 ]; then
        echo -e "  ${GREEN}Found $cxl_count CXL device(s)${NC}"
        ls -1 /sys/bus/cxl/devices/ | sed 's/^/    /'
    else
        echo -e "  ${YELLOW}No CXL devices found${NC}"
        echo "    (This is normal if not running in QEMU with CXL devices)"
    fi
else
    echo -e "  ${YELLOW}/sys/bus/cxl/devices not found${NC}"
    echo "    (This is normal if CXL support is not enabled)"
fi
echo ""

# Check 5: Memory Resource Accessibility
echo -e "${BLUE}[5] Checking Memory Resource Accessibility${NC}"
if [ -n "$CXL_MEMORY_RESOURCE" ] && [ "$CXL_MEMORY_RESOURCE" != "SS" ]; then
    echo "  Checking: $CXL_MEMORY_RESOURCE"

    if [ -e "$CXL_MEMORY_RESOURCE" ]; then
        echo -e "  ${GREEN}Resource exists${NC}"

        # Check type
        if [ -c "$CXL_MEMORY_RESOURCE" ]; then
            echo "    Type: Character device (DAX)"
        elif [ -b "$CXL_MEMORY_RESOURCE" ]; then
            echo "    Type: Block device (PMEM)"
        elif [ -f "$CXL_MEMORY_RESOURCE" ]; then
            echo "    Type: Regular file"
        elif [ -d "$CXL_MEMORY_RESOURCE" ]; then
            echo -e "    ${RED}Type: Directory (invalid - should be file or device)${NC}"
        fi

        # Check permissions
        if [ -r "$CXL_MEMORY_RESOURCE" ] && [ -w "$CXL_MEMORY_RESOURCE" ]; then
            echo -e "    Permissions: ${GREEN}Read/Write OK${NC}"
        else
            echo -e "    Permissions: ${RED}Cannot read/write${NC}"
            echo "      Run: sudo chmod 666 $CXL_MEMORY_RESOURCE"
        fi

        # Show details
        ls -lh "$CXL_MEMORY_RESOURCE" | sed 's/^/    /'
    else
        echo -e "  ${YELLOW}Resource does not exist${NC}"
        if [[ "$CXL_MEMORY_RESOURCE" == /dev/* ]]; then
            echo "    This appears to be a device path - it will be created when available"
        else
            echo "    This appears to be a file path - it will be created when tigon runs"
            resource_dir=$(dirname "$CXL_MEMORY_RESOURCE")
            if [ -w "$resource_dir" ]; then
                echo -e "    Directory is writable: ${GREEN}$resource_dir${NC}"
            else
                echo -e "    ${RED}Directory not writable: $resource_dir${NC}"
            fi
        fi
    fi
elif [ "$CXL_MEMORY_RESOURCE" = "SS" ] || [ -z "$CXL_MEMORY_RESOURCE" ]; then
    echo -e "  Using shared memory (IVSHMEM) mode - no resource file needed"
else
    echo -e "  ${YELLOW}CXL_MEMORY_RESOURCE not configured${NC}"
fi
echo ""

# Check 6: Tigon Binary
echo -e "${BLUE}[6] Checking Tigon Binary${NC}"
if [ -f "../build/bench_tpcc" ]; then
    echo -e "  ${GREEN}bench_tpcc found${NC}"
    ls -lh ../build/bench_tpcc | sed 's/^/    /'
else
    echo -e "  ${YELLOW}bench_tpcc not found in ../build/${NC}"
    echo "    Run: cmake -B build && cmake --build build"
fi
echo ""

# Check 7: Recommended Configuration
echo -e "${BLUE}[7] Recommended Configuration${NC}"

# Check current settings vs recommendations
backend_ok=false
resource_ok=false

if [ "$CXL_BACKEND" = "dax" ] || [ "$CXL_BACKEND" = "mmap" ]; then
    backend_ok=true
fi

if [ -n "$CXL_MEMORY_RESOURCE" ] && [ "$CXL_MEMORY_RESOURCE" != "SS" ]; then
    resource_ok=true
fi

if $backend_ok && $resource_ok; then
    echo -e "  ${GREEN}✓ Configuration looks good for DAX/mmap mode${NC}"
elif [ "$CXL_BACKEND" = "mmap" ] && [ "$CXL_MEMORY_RESOURCE" = "SS" ]; then
    echo -e "  ${GREEN}✓ Configuration set for shared memory (IVSHMEM) mode${NC}"
else
    echo -e "  ${YELLOW}⚠ Configuration suggestions:${NC}"
    echo ""
    echo "  For DAX mode with device:"
    echo "    export CXL_BACKEND=\"dax\""
    echo "    export CXL_MEMORY_RESOURCE=\"/dev/dax0.0\""
    echo ""
    echo "  For mmap mode with file:"
    echo "    export CXL_BACKEND=\"mmap\""
    echo "    export CXL_MEMORY_RESOURCE=\"/tmp/cxl_memory\""
    echo ""
    echo "  For shared memory (IVSHMEM) mode:"
    echo "    export CXL_BACKEND=\"mmap\""
    echo "    export CXL_MEMORY_RESOURCE=\"SS\""
fi
echo ""

# Summary
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Summary${NC}"
echo -e "${BLUE}========================================${NC}"

issues=0

if [ "$CXL_BACKEND" != "dax" ] && [ "$CXL_BACKEND" != "mmap" ] && [ -n "$CXL_BACKEND" ]; then
    echo -e "${YELLOW}⚠ Invalid CXL_BACKEND: $CXL_BACKEND${NC}"
    ((issues++))
fi

if [ -n "$CXL_MEMORY_RESOURCE" ] && [ "$CXL_MEMORY_RESOURCE" != "SS" ] && [ ! -e "$CXL_MEMORY_RESOURCE" ]; then
    if [[ ! "$CXL_MEMORY_RESOURCE" == /dev/* ]] && [[ ! "$CXL_MEMORY_RESOURCE" == /tmp/* ]]; then
        echo -e "${YELLOW}⚠ Memory resource doesn't exist and isn't in /dev or /tmp: $CXL_MEMORY_RESOURCE${NC}"
        ((issues++))
    fi
fi

if [ $issues -eq 0 ]; then
    echo -e "${GREEN}✓ No issues found${NC}"
else
    echo -e "${YELLOW}⚠ Found $issues potential issue(s)${NC}"
fi

echo ""
echo -e "${BLUE}Next Steps:${NC}"
echo "  1. If using DAX: source ./scripts/dax_config.sh"
echo "  2. Run tigon: ./scripts/run_tpcc.sh ./results"
echo "  3. Check logs for: 'cxlalloc initialized for thread ... backend=...'"
echo ""
