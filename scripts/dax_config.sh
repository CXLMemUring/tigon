#!/bin/bash

# DAX/mmap Configuration for Tigon on QEMU
# This script configures tigon to use mmap over DAX devices for CXL memory access

# ============================================================================
# Configuration Options
# ============================================================================

# Backend Mode: "dax" or "mmap" (both use mmap underneath)
# "dax" will be converted to "mmap" internally
export CXL_BACKEND="${CXL_BACKEND:-dax}"

# Memory Resource: Path to DAX device or file
# Options:
#   - DAX device: /dev/dax0.0, /dev/dax1.0, etc. (requires DAX-enabled CXL/PMEM device)
#   - File on DAX filesystem: /mnt/pmem0/cxl_memory
#   - Regular file: /tmp/cxl_memory (for testing without actual DAX)
#   - "SS" means shared memory (ivshmem) - original default
export CXL_MEMORY_RESOURCE="${CXL_MEMORY_RESOURCE:-/dev/dax0.0}"

# Alternative: use a file on DAX filesystem
# export CXL_MEMORY_RESOURCE="/mnt/pmem0/cxl_memory"

# Alternative: use regular file for testing
# export CXL_MEMORY_RESOURCE="/tmp/cxl_memory"

# ============================================================================
# Display Configuration
# ============================================================================

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Tigon DAX/mmap Configuration${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "Backend: ${YELLOW}${CXL_BACKEND}${NC}"
echo -e "Memory Resource: ${YELLOW}${CXL_MEMORY_RESOURCE}${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# ============================================================================
# Validation
# ============================================================================

if [ "$CXL_BACKEND" != "dax" ] && [ "$CXL_BACKEND" != "mmap" ]; then
    echo -e "${YELLOW}Warning: CXL_BACKEND should be 'dax' or 'mmap'. Got: $CXL_BACKEND${NC}"
    echo "Continuing anyway..."
fi

if [ "$CXL_MEMORY_RESOURCE" = "SS" ]; then
    echo -e "${YELLOW}Warning: CXL_MEMORY_RESOURCE is set to 'SS' (shared memory mode).${NC}"
    echo "For DAX/mmap mode, set it to a device or file path."
    echo ""
fi

# Check if resource exists (skip for SS mode)
if [ "$CXL_MEMORY_RESOURCE" != "SS" ]; then
    # Extract directory if it's a file path
    resource_dir=$(dirname "$CXL_MEMORY_RESOURCE")

    if [ ! -e "$CXL_MEMORY_RESOURCE" ]; then
        echo -e "${YELLOW}Note: Resource does not exist: $CXL_MEMORY_RESOURCE${NC}"

        # Check if it's a device
        if [[ "$CXL_MEMORY_RESOURCE" == /dev/* ]]; then
            echo "This appears to be a device path."
            echo "Make sure the DAX device is configured in QEMU with:"
            echo "  -object memory-backend-file,id=cxl-mem,share=on,mem-path=/dev/dax0.0,size=XXG"
            echo "  -device cxl-type3,memdev=cxl-mem,..."
        else
            # It's a file, try to create it
            echo "Attempting to create the file..."
            if mkdir -p "$resource_dir" 2>/dev/null && touch "$CXL_MEMORY_RESOURCE" 2>/dev/null; then
                echo -e "${GREEN}Created: $CXL_MEMORY_RESOURCE${NC}"
            else
                echo -e "${YELLOW}Failed to create file. It will be created when tigon runs.${NC}"
            fi
        fi
    else
        echo -e "${GREEN}Resource exists: $CXL_MEMORY_RESOURCE${NC}"

        # Show resource info
        if [ -c "$CXL_MEMORY_RESOURCE" ] || [ -b "$CXL_MEMORY_RESOURCE" ]; then
            echo "  Type: Character/Block device"
            ls -lh "$CXL_MEMORY_RESOURCE"
        elif [ -f "$CXL_MEMORY_RESOURCE" ]; then
            echo "  Type: Regular file"
            ls -lh "$CXL_MEMORY_RESOURCE"
        fi
    fi
fi

echo ""
echo -e "${BLUE}Usage:${NC}"
echo "  source ./scripts/dax_config.sh"
echo "  ./scripts/run.sh <parameters>"
echo ""
echo -e "${BLUE}The run.sh script will automatically use these settings.${NC}"
echo ""
