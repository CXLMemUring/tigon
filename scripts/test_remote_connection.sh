#!/bin/bash

# Test script for remote host configuration
# This script helps verify that your remote host setup is working correctly

set -e

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source $SCRIPT_DIR/utilities.sh

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Tigon Remote Connection Test${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Display current configuration
if [ "${USE_REMOTE_HOSTS:-0}" = "1" ]; then
    echo -e "${GREEN}Mode: Remote Hosts${NC}"
    echo "  Base IP: ${REMOTE_BASE_IP}"
    echo "  Start Suffix: ${REMOTE_START_SUFFIX}"
    echo "  Port: ${REMOTE_PORT}"
    echo "  User: ${REMOTE_USER}"
else
    echo -e "${YELLOW}Mode: Localhost${NC}"
    echo "  Base Port: 10022"
    echo "  User: root"
fi

echo ""
read -p "Number of hosts to test (default: 2): " num_hosts
num_hosts=${num_hosts:-2}

echo ""
echo -e "${YELLOW}Testing connections to $num_hosts hosts...${NC}"
echo ""

# Test 1: Basic SSH connectivity
echo -e "${BLUE}Test 1: SSH Connectivity${NC}"
success_count=0
for i in $(seq 0 $((num_hosts - 1))); do
    echo -n "  VM $i: "
    if ssh_command "echo 'OK'" $i &> /dev/null; then
        echo -e "${GREEN}✓ Connected${NC}"
        ((success_count++))
    else
        echo -e "${RED}✗ Failed${NC}"
    fi
done
echo "  Result: $success_count/$num_hosts hosts reachable"
echo ""

# Test 2: Command execution
echo -e "${BLUE}Test 2: Command Execution${NC}"
for i in $(seq 0 $((num_hosts - 1))); do
    echo "  VM $i:"
    echo -n "    Hostname: "
    hostname=$(ssh_command "hostname" $i 2>/dev/null || echo "FAILED")
    if [ "$hostname" != "FAILED" ]; then
        echo -e "${GREEN}$hostname${NC}"
    else
        echo -e "${RED}FAILED${NC}"
    fi

    echo -n "    Uptime: "
    uptime=$(ssh_command "uptime -p" $i 2>/dev/null || echo "FAILED")
    if [ "$uptime" != "FAILED" ]; then
        echo -e "${GREEN}$uptime${NC}"
    else
        echo -e "${RED}FAILED${NC}"
    fi
done
echo ""

# Test 3: File sync
echo -e "${BLUE}Test 3: File Synchronization${NC}"
test_file="/tmp/tigon_test_$$"
test_content="Tigon remote test - $(date)"
echo "$test_content" > $test_file

echo "  Creating test file: $test_file"
echo "  Content: $test_content"
echo "  Syncing to $num_hosts hosts..."

sync_files $test_file $test_file $num_hosts

echo "  Verifying file on remote hosts..."
for i in $(seq 0 $((num_hosts - 1))); do
    echo -n "    VM $i: "
    remote_content=$(ssh_command "cat $test_file 2>/dev/null" $i || echo "FAILED")
    if [ "$remote_content" = "$test_content" ]; then
        echo -e "${GREEN}✓ Match${NC}"
    else
        echo -e "${RED}✗ Mismatch${NC}"
    fi
done

# Cleanup
echo "  Cleaning up test files..."
rm -f $test_file
for i in $(seq 0 $((num_hosts - 1))); do
    ssh_command "rm -f $test_file" $i &> /dev/null || true
done
echo ""

# Test 4: Directory creation and permissions
echo -e "${BLUE}Test 4: Directory Operations${NC}"
test_dir="/tmp/tigon_dir_test_$$"
for i in $(seq 0 $((num_hosts - 1))); do
    echo -n "  VM $i: "
    if ssh_command "mkdir -p $test_dir && touch $test_dir/test.txt && rm -rf $test_dir" $i &> /dev/null; then
        echo -e "${GREEN}✓ Read/Write OK${NC}"
    else
        echo -e "${RED}✗ Permission issue${NC}"
    fi
done
echo ""

# Test 5: Network info
if [ "${USE_REMOTE_HOSTS:-0}" = "1" ]; then
    echo -e "${BLUE}Test 5: Network Configuration${NC}"
    for i in $(seq 0 $((num_hosts - 1))); do
        suffix=$((${REMOTE_START_SUFFIX} + i))
        target_ip="${REMOTE_BASE_IP}.${suffix}"

        echo "  VM $i (${target_ip}):"

        # Get IP address
        echo -n "    IP check: "
        remote_ip=$(ssh_command "hostname -I | awk '{print \$1}'" $i 2>/dev/null || echo "FAILED")
        if [ "$remote_ip" != "FAILED" ]; then
            echo -e "${GREEN}$remote_ip${NC}"
            if [ "$remote_ip" = "$target_ip" ]; then
                echo -e "      ${GREEN}✓ Matches expected IP${NC}"
            else
                echo -e "      ${YELLOW}⚠ Expected: $target_ip${NC}"
            fi
        else
            echo -e "${RED}FAILED${NC}"
        fi
    done
    echo ""
fi

# Summary
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Test Summary${NC}"
echo -e "${BLUE}========================================${NC}"

if [ $success_count -eq $num_hosts ]; then
    echo -e "${GREEN}✓ All tests passed!${NC}"
    echo ""
    echo "Your remote host configuration is working correctly."
    echo "You can now run:"
    echo "  ./scripts/setup.sh VMS $num_hosts"
else
    echo -e "${RED}✗ Some tests failed${NC}"
    echo ""
    echo "Troubleshooting steps:"
    echo "  1. Verify network connectivity:"
    if [ "${USE_REMOTE_HOSTS:-0}" = "1" ]; then
        echo "     ping ${REMOTE_BASE_IP}.${REMOTE_START_SUFFIX}"
    else
        echo "     Check that QEMU VMs are running"
    fi
    echo "  2. Test SSH manually:"
    if [ "${USE_REMOTE_HOSTS:-0}" = "1" ]; then
        echo "     ssh -p ${REMOTE_PORT} ${REMOTE_USER}@${REMOTE_BASE_IP}.${REMOTE_START_SUFFIX}"
    else
        echo "     ssh -p 10022 root@127.0.0.1"
    fi
    echo "  3. Setup SSH keys:"
    if [ "${USE_REMOTE_HOSTS:-0}" = "1" ]; then
        echo "     ssh-copy-id -p ${REMOTE_PORT} ${REMOTE_USER}@${REMOTE_BASE_IP}.${REMOTE_START_SUFFIX}"
    else
        echo "     ssh-copy-id -p 10022 root@127.0.0.1"
    fi
fi

echo ""
