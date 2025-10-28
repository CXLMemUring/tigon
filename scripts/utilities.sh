#! /bin/bash

set -uo pipefail

# set -x

# Configuration for target machines
# Set USE_REMOTE_HOSTS=1 to use remote IP addresses instead of localhost
USE_REMOTE_HOSTS=${USE_REMOTE_HOSTS:-1}
REMOTE_BASE_IP=${REMOTE_BASE_IP:-"192.168.100"}  # Base IP, will append .10, .11, etc.
REMOTE_START_SUFFIX=${REMOTE_START_SUFFIX:-10}  # Start from 192.168.0.10
REMOTE_PORT=${REMOTE_PORT:-22}                  # SSH port for remote hosts
REMOTE_USER=${REMOTE_USER:-root}                # SSH user for remote hosts

function ssh_command {
        typeset command=$1
        typeset vm_id=$2

        # Use remote IP addresses
        typeset ip_suffix=$(expr $REMOTE_START_SUFFIX + $vm_id)
        typeset target_ip="${REMOTE_BASE_IP}.${ip_suffix}"
        ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p $REMOTE_PORT ${REMOTE_USER}@${target_ip} "$command"
}

function sync_files {
        typeset src=$1
        typeset dst=$2
        typeset vm_num=$3
        typeset i=0

        for (( i=0; i < $vm_num; ++i ))
        do
                if [ "$USE_REMOTE_HOSTS" = "1" ]; then
                        # Use remote IP addresses with scp
                        typeset ip_suffix=$(expr $REMOTE_START_SUFFIX + $i)
                        typeset target_ip="${REMOTE_BASE_IP}.${ip_suffix}"
                        echo "......syncing to ${target_ip}:${REMOTE_PORT} (VM $i)......"
                        scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -r -P $REMOTE_PORT $src ${REMOTE_USER}@${target_ip}:$dst > /dev/null
                else
                        # Use localhost with different ports (original behavior)
                        echo ......syncing to VM $i......
                        typeset base_port=10022
                        typeset port=$(expr $base_port + $i)
                        scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -r -P $port $src root@127.0.0.1:$dst > /dev/null
                fi
        done
}

function setup_hostnames {
        typeset vm_num=$1
        typeset base=2
        typeset i=0

        for (( i=0; i < $vm_num; ++i ))
        do
                echo ......setup hostname for VM $i......
                ip=$(expr $base + $i)
                ssh_command "hostnamectl set-hostname 192.168.100.$ip" $i
        done
}

function init_cxl_for_vms {
        typeset vm_num=$1
        typeset cxl_init=./cxl_init
        typeset i=0

        # echo initializing cxl memory...
        # ssh_command "$cxl_init --machine-count 16 --size $((2 ** 30 * 64)) -z" 0
        # for (( i=1; i < $vm_num; ++i ))
        # do
        #         ssh_command "./cxl_recover_meta --tot_machines 16" $i > /dev/null
        # done
}

function rm_files_for_vms {
        typeset file=$1
        typeset vm_num=$2
        typeset i=0
        for (( i=0; i < $vm_num; ++i ))
	do
		ssh_command "[ -e $file ] && rm -rf $file" $i
	done
}
