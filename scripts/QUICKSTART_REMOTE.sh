#!/bin/bash

# Quickstart Script for Tigon Remote Deployment
# This script provides an interactive way to configure and deploy to remote hosts

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Tigon Remote Host Deployment Setup${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Function to test SSH connectivity
test_ssh_connection() {
    local ip=$1
    local port=$2
    local user=$3

    echo -n "Testing connection to ${user}@${ip}:${port}... "
    if timeout 5 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR -p ${port} ${user}@${ip} "echo OK" &> /dev/null; then
        echo -e "${GREEN}SUCCESS${NC}"
        return 0
    else
        echo -e "${RED}FAILED${NC}"
        return 1
    fi
}

# Get configuration from user
echo -e "${YELLOW}Configuration:${NC}"
echo ""

read -p "Use remote hosts? (y/n, default: y): " use_remote
use_remote=${use_remote:-y}

if [[ "$use_remote" != "y" && "$use_remote" != "Y" ]]; then
    echo -e "${YELLOW}Using localhost mode...${NC}"
    export USE_REMOTE_HOSTS=0
    echo ""
    read -p "Number of VMs (default: 8): " num_vms
    num_vms=${num_vms:-8}

    echo ""
    echo -e "${GREEN}Configuration:${NC}"
    echo "  Mode: Localhost"
    echo "  Number of VMs: $num_vms"
    echo "  Ports: 10022-$((10022 + num_vms - 1))"
    echo ""
    read -p "Proceed with setup? (y/n): " proceed

    if [[ "$proceed" == "y" || "$proceed" == "Y" ]]; then
        ./scripts/setup.sh VMS $num_vms
    fi
    exit 0
fi

# Remote host configuration
echo ""
echo "Enter the IP address range for your remote hosts."
echo "Example: For 192.168.0.10 - 192.168.0.17"
echo "  Base IP: 192.168.0"
echo "  Start suffix: 10"
echo ""

read -p "Base IP address (default: 192.168.0): " base_ip
base_ip=${base_ip:-192.168.0}

read -p "Starting IP suffix (default: 10): " start_suffix
start_suffix=${start_suffix:-10}

read -p "SSH port (default: 22): " ssh_port
ssh_port=${ssh_port:-22}

read -p "SSH user (default: root): " ssh_user
ssh_user=${ssh_user:-root}

read -p "Number of hosts (default: 8): " num_hosts
num_hosts=${num_hosts:-8}

# Export configuration
export USE_REMOTE_HOSTS=1
export REMOTE_BASE_IP="$base_ip"
export REMOTE_START_SUFFIX="$start_suffix"
export REMOTE_PORT="$ssh_port"
export REMOTE_USER="$ssh_user"

# Display configuration
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Configuration Summary:${NC}"
echo -e "${GREEN}========================================${NC}"
echo "Mode: Remote Hosts"
echo "Number of hosts: $num_hosts"
echo "SSH Port: $ssh_port"
echo "SSH User: $ssh_user"
echo ""
echo "Target hosts:"
for i in $(seq 0 $((num_hosts - 1))); do
    suffix=$((start_suffix + i))
    echo "  VM $i -> ${ssh_user}@${base_ip}.${suffix}:${ssh_port}"
done
echo ""

# Ask to test connections
read -p "Test SSH connectivity to all hosts? (y/n, default: y): " test_conn
test_conn=${test_conn:-y}

if [[ "$test_conn" == "y" || "$test_conn" == "Y" ]]; then
    echo ""
    echo -e "${YELLOW}Testing connections...${NC}"
    failed_hosts=()

    for i in $(seq 0 $((num_hosts - 1))); do
        suffix=$((start_suffix + i))
        ip="${base_ip}.${suffix}"
        if ! test_ssh_connection "$ip" "$ssh_port" "$ssh_user"; then
            failed_hosts+=("VM $i ($ip)")
        fi
    done

    echo ""
    if [ ${#failed_hosts[@]} -eq 0 ]; then
        echo -e "${GREEN}All hosts are reachable!${NC}"
    else
        echo -e "${RED}Failed to connect to the following hosts:${NC}"
        for host in "${failed_hosts[@]}"; do
            echo "  - $host"
        done
        echo ""
        echo -e "${YELLOW}Troubleshooting tips:${NC}"
        echo "  1. Check network connectivity: ping ${base_ip}.$start_suffix"
        echo "  2. Verify SSH service is running on remote hosts"
        echo "  3. Setup SSH keys: ssh-copy-id -p $ssh_port ${ssh_user}@${base_ip}.$start_suffix"
        echo ""
        read -p "Continue anyway? (y/n): " continue_anyway
        if [[ "$continue_anyway" != "y" && "$continue_anyway" != "Y" ]]; then
            exit 1
        fi
    fi
fi

# Offer to setup SSH keys
echo ""
read -p "Setup SSH keys for passwordless access? (y/n, default: n): " setup_keys
setup_keys=${setup_keys:-n}

if [[ "$setup_keys" == "y" || "$setup_keys" == "Y" ]]; then
    echo ""
    echo -e "${YELLOW}Setting up SSH keys...${NC}"

    # Generate key if not exists
    if [ ! -f ~/.ssh/id_rsa ]; then
        echo "Generating SSH key..."
        ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa
    fi

    # Copy to each host
    for i in $(seq 0 $((num_hosts - 1))); do
        suffix=$((start_suffix + i))
        ip="${base_ip}.${suffix}"
        echo "Copying key to ${ssh_user}@${ip}..."
        ssh-copy-id -p "$ssh_port" "${ssh_user}@${ip}" 2>/dev/null || echo "  (may already exist or failed)"
    done
    echo -e "${GREEN}SSH key setup complete${NC}"
fi

# Run setup
echo ""
echo -e "${GREEN}========================================${NC}"
read -p "Proceed with Tigon setup on remote hosts? (y/n): " proceed
proceed=${proceed:-y}

if [[ "$proceed" != "y" && "$proceed" != "Y" ]]; then
    echo "Setup cancelled."
    echo ""
    echo "To run setup manually later with these settings, use:"
    echo ""
    echo "  export USE_REMOTE_HOSTS=1"
    echo "  export REMOTE_BASE_IP=\"$base_ip\""
    echo "  export REMOTE_START_SUFFIX=\"$start_suffix\""
    echo "  export REMOTE_PORT=\"$ssh_port\""
    echo "  export REMOTE_USER=\"$ssh_user\""
    echo "  ./scripts/setup.sh VMS $num_hosts"
    echo ""
    exit 0
fi

echo ""
echo -e "${YELLOW}Running setup...${NC}"
echo ""

# Run the actual setup
cd "$(dirname "$0")/.."
./scripts/setup.sh VMS $num_hosts

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Setup Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "You can now run benchmarks with:"
echo "  ./scripts/run_tpcc.sh ./results"
echo "  ./scripts/run_ycsb.sh ./results"
echo ""
echo "Environment is configured for remote hosts."
echo "Settings will persist in this shell session."
echo ""
