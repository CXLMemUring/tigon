#!/bin/bash

# Reset Tigon Configuration
# This script clears all Tigon-related environment variables

echo "Resetting Tigon configuration..."

# Clear CXL backend configuration
unset CXL_BACKEND
unset CXL_MEMORY_RESOURCE

# Clear remote host configuration
unset USE_REMOTE_HOSTS
unset REMOTE_BASE_IP
unset REMOTE_START_SUFFIX
unset REMOTE_PORT
unset REMOTE_USER

echo "✓ All configuration variables cleared"
echo ""
echo "Current state:"
echo "  CXL_BACKEND: ${CXL_BACKEND:-(not set)}"
echo "  CXL_MEMORY_RESOURCE: ${CXL_MEMORY_RESOURCE:-(not set)}"
echo "  USE_REMOTE_HOSTS: ${USE_REMOTE_HOSTS:-(not set)}"
echo ""
echo "Tigon will now use default settings:"
echo "  - IVSHMEM mode for CXL memory"
echo "  - Remote hosts (192.168.100.10-17) for SSH"
echo ""
echo "To reconfigure, run:"
echo "  source ./scripts/dax_config.sh    # For DAX/mmap mode"
echo "  source ./scripts/remote_config.sh # For remote host settings"
echo ""
