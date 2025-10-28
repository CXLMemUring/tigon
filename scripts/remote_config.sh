#!/bin/bash

# Remote Host Configuration for Tigon Scripts
# Source this file before running tigon scripts to use remote hosts instead of localhost

# Usage examples:
#
# 1. For IP range 192.168.0.10 - 192.168.0.17 (8 hosts):
#    export USE_REMOTE_HOSTS=1
#    export REMOTE_BASE_IP="192.168.0"
#    export REMOTE_START_SUFFIX=10
#
# 2. For IP range 192.168.1.10 - 192.168.1.25 (16 hosts):
#    export USE_REMOTE_HOSTS=1
#    export REMOTE_BASE_IP="192.168.1"
#    export REMOTE_START_SUFFIX=10
#
# 3. For custom port (non-22):
#    export REMOTE_PORT=2222
#
# 4. For non-root user:
#    export REMOTE_USER=ubuntu

# Enable remote hosts mode
export USE_REMOTE_HOSTS=1

# Configure your IP range
# This will use IPs: 192.168.0.10, 192.168.0.11, ..., 192.168.0.17
export REMOTE_BASE_IP="192.168.0"
export REMOTE_START_SUFFIX=10

# SSH Configuration
export REMOTE_PORT=22        # Standard SSH port
export REMOTE_USER="root"    # SSH user

# Color output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}Tigon Remote Host Configuration${NC}"
echo -e "${GREEN}======================================${NC}"
echo -e "Mode: ${YELLOW}Remote Hosts${NC}"
echo -e "IP Range: ${YELLOW}${REMOTE_BASE_IP}.${REMOTE_START_SUFFIX} - ${REMOTE_BASE_IP}.<suffix+N>${NC}"
echo -e "SSH Port: ${YELLOW}${REMOTE_PORT}${NC}"
echo -e "SSH User: ${YELLOW}${REMOTE_USER}${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""
echo "Example usage for 8 hosts:"
echo -e "  ${YELLOW}./scripts/setup.sh VMS 8${NC}"
echo ""
echo "This will use hosts:"
for i in {0..7}; do
    suffix=$((REMOTE_START_SUFFIX + i))
    echo "  VM $i -> ${REMOTE_BASE_IP}.${suffix}:${REMOTE_PORT}"
done
echo ""
echo -e "${GREEN}To use localhost mode instead, run:${NC}"
echo -e "  ${YELLOW}export USE_REMOTE_HOSTS=0${NC}"
echo ""
