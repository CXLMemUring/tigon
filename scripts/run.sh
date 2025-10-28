#! /bin/bash

set -uo pipefail
# set -x

typeset SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
typeset current_date_time="`date +%Y%m%d%H%M`"

source $SCRIPT_DIR/utilities.sh

# ============================================================================
# CXL Backend Configuration (DAX/mmap support)
# ============================================================================
# Default: use ivshmem (shared memory) mode - original tigon behavior
# To use DAX/mmap mode, set environment variables BEFORE running:
#   export CXL_BACKEND="dax"  # or "mmap"
#   export CXL_MEMORY_RESOURCE="/dev/dax0.0"  # or file path
# Or source the config script:
#   source ./scripts/dax_config.sh
# ============================================================================

# Only set CXL backend flags if explicitly configured
# If not set, tigon will use its internal default (ivshmem with "SS")
if [ -n "${CXL_BACKEND:-}" ] && [ -n "${CXL_MEMORY_RESOURCE:-}" ]; then
    # User explicitly configured both - use them
    CXL_BACKEND_FLAGS="--cxl_backend=$CXL_BACKEND --cxl_memory_resource=$CXL_MEMORY_RESOURCE"
elif [ -n "${CXL_BACKEND:-}" ]; then
    # Only backend set - validate it makes sense
    if [ "$CXL_BACKEND" = "dax" ] || [ "$CXL_BACKEND" = "mmap" ]; then
        echo "WARNING: CXL_BACKEND=$CXL_BACKEND but CXL_MEMORY_RESOURCE not set"
        echo "You must set CXL_MEMORY_RESOURCE to a file or device path"
        echo "Example: export CXL_MEMORY_RESOURCE=/dev/dax0.0"
        echo "Falling back to default (ivshmem mode)"
        CXL_BACKEND_FLAGS=""
    else
        CXL_BACKEND_FLAGS="--cxl_backend=$CXL_BACKEND"
    fi
elif [ -n "${CXL_MEMORY_RESOURCE:-}" ]; then
    # Only resource set - infer backend
    if [ "$CXL_MEMORY_RESOURCE" != "SS" ]; then
        # Assume mmap mode with the specified resource
        CXL_BACKEND_FLAGS="--cxl_backend=mmap --cxl_memory_resource=$CXL_MEMORY_RESOURCE"
    else
        # SS means shared memory - don't set flags (use tigon defaults)
        CXL_BACKEND_FLAGS=""
    fi
else
    # Nothing configured - use tigon defaults (ivshmem mode)
    CXL_BACKEND_FLAGS=""
fi

function print_usage {
        echo "[usage] ./run.sh [TPCC/YCSB/KILL/COMPILE/COMPILE_SYNC/CI/COLLECT_OUTPUTS] EXP-SPECIFIC"
        echo "TPCC: [SundialPasha/Sundial/TwoPLPasha/TwoPLPashaPhantom/TwoPL] HOST_NUM WORKER_NUM QUERY_TYPE REMOTE_NEWORDER_PERC REMOTE_PAYMENT_PERC USE_CXL_TRANS USE_OUTPUT_THREAD ENABLE_MIGRATION_OPTIMIZATION MIGRATION_POLICY WHEN_TO_MOVE_OUT HW_CC_BUDGET ENABLE_SCC SCC_MECH PRE_MIGRATE TIME_TO_RUN TIME_TO_WARMUP LOGGING_TYPE EPOCH_LEN MODEL_CXL_SEARCH GATHER_OUTPUTS"
        echo "YCSB: [SundialPasha/Sundial/TwoPLPasha/TwoPLPashaPhantom/TwoPL] HOST_NUM WORKER_NUM QUERY_TYPE KEYS RW_RATIO ZIPF_THETA CROSS_RATIO USE_CXL_TRANS USE_OUTPUT_THREAD ENABLE_MIGRATION_OPTIMIZATION MIGRATION_POLICY WHEN_TO_MOVE_OUT HW_CC_BUDGET ENABLE_SCC SCC_MECH PRE_MIGRATE TIME_TO_RUN TIME_TO_WARMUP LOGGING_TYPE EPOCH_LEN MODEL_CXL_SEARCH GATHER_OUTPUTS"
        echo "SmallBank: [SundialPasha/Sundial/TwoPLPasha/TwoPLPashaPhantom/TwoPL] HOST_NUM WORKER_NUM KEYS ZIPF_THETA CROSS_RATIO USE_CXL_TRANS USE_OUTPUT_THREAD ENABLE_MIGRATION_OPTIMIZATION MIGRATION_POLICY WHEN_TO_MOVE_OUT HW_CC_BUDGET ENABLE_SCC SCC_MECH PRE_MIGRATE TIME_TO_RUN TIME_TO_WARMUP LOGGING_TYPE EPOCH_LEN MODEL_CXL_SEARCH GATHER_OUTPUTS"
        echo "TATP: [SundialPasha/Sundial/TwoPLPasha/TwoPLPashaPhantom/TwoPL] HOST_NUM WORKER_NUM KEYS CROSS_RATIO USE_CXL_TRANS USE_OUTPUT_THREAD ENABLE_MIGRATION_OPTIMIZATION MIGRATION_POLICY WHEN_TO_MOVE_OUT HW_CC_BUDGET ENABLE_SCC SCC_MECH PRE_MIGRATE TIME_TO_RUN TIME_TO_WARMUP LOGGING_TYPE EPOCH_LEN MODEL_CXL_SEARCH GATHER_OUTPUTS"
        echo "KILL: None"
        echo "COMPILE: None"
        echo "COMPILE_SYNC: HOST_NUM"
        echo "CI: HOST_NUM WORKER_NUM"
        echo "COLLECT_OUTPUTS: HOST_NUM"
}

function kill_prev_exps {
        typeset HOST_NUM=$1
        typeset i=0

        echo "killing previous experiments..."
        for (( i=0; i < $HOST_NUM; ++i ))
        do
                ssh_command "pkill bench_tpcc" $i
                ssh_command "pkill bench_ycsb" $i
                # ssh_command "pkill bench_smallbank" $i
                # ssh_command "pkill bench_tatp" $i
        done
}

function delete_log_files {
        typeset MAX_HOST_NUM=8
        typeset LOG_FILE_NAME=pasha_log_non_group_commit.txt
        typeset i=0

        echo "deleting log files..."
        # for (( i=0; i < $MAX_HOST_NUM; ++i ))
        # do
        #         ssh_command "[ -e $LOG_FILE_NAME ] && rm $LOG_FILE_NAME" $i
        #         ssh_command "echo 1 > /proc/sys/vm/drop_caches" $i
        #         ssh_command "sync" $i
        # done
}

function gather_other_output {
        typeset HOST_NUM=$1

        typeset i=0

        for (( i=1; i < $HOST_NUM; ++i ))
        do
                ssh_command "cat pasha/output.txt" $i
        done
}

function sync_binaries {
        typeset HOST_NUM=$1

        cd $SCRIPT_DIR
        echo "Syncing executables and configs..."
        for (( i=0; i < $HOST_NUM; ++i ))
        do
                ssh_command "mkdir -p pasha" $i
        done
        sync_files $SCRIPT_DIR/../build/bench_tpcc /root/pasha/ $HOST_NUM
        sync_files $SCRIPT_DIR/../build/bench_ycsb /root/pasha/ $HOST_NUM
        # sync_files $SCRIPT_DIR/../build/bench_smallbank /root/pasha/ $HOST_NUM
        # sync_files $SCRIPT_DIR/../build/bench_tatp /root/pasha/ $HOST_NUM
        exit -1
}

function print_server_string {
        typeset HOST_NUM=$1

        # Use the same base as remote host configuration
        # This matches REMOTE_START_SUFFIX in utilities.sh (default: 10)
        typeset base=${REMOTE_START_SUFFIX:-10}
        typeset i=0

        for (( i=0; i < $HOST_NUM; ++i ))
        do
                typeset ip=$(expr $base + $i)
                if [ $i = 0 ]; then
                        echo -n "${REMOTE_BASE_IP:-192.168.100}.$ip:1234"
                else
                        echo -n ";${REMOTE_BASE_IP:-192.168.100}.$ip:1234"
                fi
        done
}

function run_exp_tpcc {
        if [ $# != 25 ]; then
                print_usage
                exit -1
        fi
        typeset PROTOCOL=$1
        typeset HOST_NUM=$2
        typeset WORKER_NUM=$3
        typeset QUERY_TYPE=$4
        typeset REMOTE_NEWORDER_PERC=$5
        typeset REMOTE_PAYMENT_PERC=$6
        typeset USE_CXL_TRANS=$7
        typeset USE_OUTPUT_THREAD=$8
        typeset CXL_TRANS_ENTRY_STRUCT_SIZE=$9
        typeset CXL_TRANS_ENTRY_NUM=${10}
        typeset ENABLE_MIGRATION_OPTIMIZATION=${11}
        typeset MIGRATION_POLICY=${12}
        typeset WHEN_TO_MOVE_OUT=${13}
        typeset HW_CC_BUDGET=${14}
        typeset ENABLE_SCC=${15}
        typeset SCC_MECH=${16}
        typeset PRE_MIGRATE=${17}
        typeset TIME_TO_RUN=${18}
        typeset TIME_TO_WARMUP=${19}
        typeset LOG_PATH=${20}
        typeset LOTUS_CHECKPOINT=${21}
        typeset WAL_GROUP_COMMIT_TIME=${22}
        typeset WAL_GROUP_COMMIT_BATCH_SIZE=${23}
        typeset MODEL_CXL_SEARCH_OVERHEAD=${24}
        typeset GATHER_OUTPUT=${25}

        typeset PARTITION_NUM=$(expr $HOST_NUM \* $WORKER_NUM)  # TPCC uses one partition per worker
        typeset SERVER_STRING=$(print_server_string $HOST_NUM)
        typeset i=0

        kill_prev_exps $HOST_NUM
        delete_log_files
        init_cxl_for_vms $HOST_NUM

        if [ $PROTOCOL = "SundialPasha" ]; then
                # launch 1-$HOST_NUM processes
                for (( i=1; i < $HOST_NUM; ++i ))
                do
                        ssh_command "cd pasha; nohup ./bench_tpcc --logtostderr=1 --id=$i --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--enable_migration_optimization=$ENABLE_MIGRATION_OPTIMIZATION --migration_policy=$MIGRATION_POLICY --when_to_move_out=$WHEN_TO_MOVE_OUT --hw_cc_budget=$HW_CC_BUDGET \
--enable_scc=$ENABLE_SCC --scc_mechanism=$SCC_MECH \
--pre_migrate=$PRE_MIGRATE \
--protocol=SundialPasha --query=$QUERY_TYPE --neworder_dist=$REMOTE_NEWORDER_PERC --payment_dist=$REMOTE_PAYMENT_PERC &> output.txt < /dev/null &" $i
                done

                # launch the first process
                ssh_command "cd pasha; ./bench_tpcc --logtostderr=1 --id=0 --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--enable_migration_optimization=$ENABLE_MIGRATION_OPTIMIZATION --migration_policy=$MIGRATION_POLICY --when_to_move_out=$WHEN_TO_MOVE_OUT --hw_cc_budget=$HW_CC_BUDGET \
--enable_scc=$ENABLE_SCC --scc_mechanism=$SCC_MECH \
--pre_migrate=$PRE_MIGRATE \
--protocol=SundialPasha --query=$QUERY_TYPE --neworder_dist=$REMOTE_NEWORDER_PERC --payment_dist=$REMOTE_PAYMENT_PERC" 0

        elif [ $PROTOCOL = "Sundial" ]; then
                # launch 1-$HOST_NUM processes
                for (( i=1; i < $HOST_NUM; ++i ))
                do
                        ssh_command "cd pasha; nohup ./bench_tpcc --logtostderr=1 --id=$i --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--protocol=Sundial --query=$QUERY_TYPE --neworder_dist=$REMOTE_NEWORDER_PERC --payment_dist=$REMOTE_PAYMENT_PERC &> output.txt < /dev/null &" $i
                done

                # launch the first process
                ssh_command "cd pasha; ./bench_tpcc --logtostderr=1 --id=0 --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--protocol=Sundial --query=$QUERY_TYPE --neworder_dist=$REMOTE_NEWORDER_PERC --payment_dist=$REMOTE_PAYMENT_PERC" 0

        elif [ $PROTOCOL = "TwoPLPasha" ]; then
                # launch 1-$HOST_NUM processes
                for (( i=1; i < $HOST_NUM; ++i ))
                do
                        ssh_command "cd pasha; nohup ./bench_tpcc --logtostderr=1 --id=$i --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--enable_migration_optimization=$ENABLE_MIGRATION_OPTIMIZATION --migration_policy=$MIGRATION_POLICY --when_to_move_out=$WHEN_TO_MOVE_OUT --hw_cc_budget=$HW_CC_BUDGET \
--enable_scc=$ENABLE_SCC --scc_mechanism=$SCC_MECH --model_cxl_search_overhead=$MODEL_CXL_SEARCH_OVERHEAD \
--pre_migrate=$PRE_MIGRATE \
--protocol=TwoPLPasha --query=$QUERY_TYPE --neworder_dist=$REMOTE_NEWORDER_PERC --payment_dist=$REMOTE_PAYMENT_PERC &> output.txt < /dev/null &" $i
                done

                # launch the first process
                ssh_command "cd pasha; ./bench_tpcc --logtostderr=1 --id=0 --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--enable_migration_optimization=$ENABLE_MIGRATION_OPTIMIZATION --migration_policy=$MIGRATION_POLICY --when_to_move_out=$WHEN_TO_MOVE_OUT --hw_cc_budget=$HW_CC_BUDGET \
--enable_scc=$ENABLE_SCC --scc_mechanism=$SCC_MECH --model_cxl_search_overhead=$MODEL_CXL_SEARCH_OVERHEAD \
--pre_migrate=$PRE_MIGRATE \
--protocol=TwoPLPasha --query=$QUERY_TYPE --neworder_dist=$REMOTE_NEWORDER_PERC --payment_dist=$REMOTE_PAYMENT_PERC" 0

        elif [ $PROTOCOL = "TwoPLPashaPhantom" ]; then
                # launch 1-$HOST_NUM processes
                for (( i=1; i < $HOST_NUM; ++i ))
                do
                        ssh_command "cd pasha; nohup ./bench_tpcc --logtostderr=1 --id=$i --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--enable_migration_optimization=$ENABLE_MIGRATION_OPTIMIZATION --migration_policy=$MIGRATION_POLICY --when_to_move_out=$WHEN_TO_MOVE_OUT --hw_cc_budget=$HW_CC_BUDGET \
--enable_scc=$ENABLE_SCC --scc_mechanism=$SCC_MECH --enable_phantom_detection=false --model_cxl_search_overhead=$MODEL_CXL_SEARCH_OVERHEAD \
--pre_migrate=$PRE_MIGRATE \
--protocol=TwoPLPasha --query=$QUERY_TYPE --neworder_dist=$REMOTE_NEWORDER_PERC --payment_dist=$REMOTE_PAYMENT_PERC &> output.txt < /dev/null &" $i
                done

                # launch the first process
                ssh_command "cd pasha; ./bench_tpcc --logtostderr=1 --id=0 --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--enable_migration_optimization=$ENABLE_MIGRATION_OPTIMIZATION --migration_policy=$MIGRATION_POLICY --when_to_move_out=$WHEN_TO_MOVE_OUT --hw_cc_budget=$HW_CC_BUDGET \
--enable_scc=$ENABLE_SCC --scc_mechanism=$SCC_MECH --enable_phantom_detection=false --model_cxl_search_overhead=$MODEL_CXL_SEARCH_OVERHEAD \
--pre_migrate=$PRE_MIGRATE \
--protocol=TwoPLPasha --query=$QUERY_TYPE --neworder_dist=$REMOTE_NEWORDER_PERC --payment_dist=$REMOTE_PAYMENT_PERC" 0

        elif [ $PROTOCOL = "TwoPL" ]; then
                # launch 1-$HOST_NUM processes
                for (( i=1; i < $HOST_NUM; ++i ))
                do
                        ssh_command "cd pasha; nohup ./bench_tpcc --logtostderr=1 --id=$i --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--protocol=TwoPL --query=$QUERY_TYPE --neworder_dist=$REMOTE_NEWORDER_PERC --payment_dist=$REMOTE_PAYMENT_PERC &> output.txt < /dev/null &" $i
                done

                # launch the first process
                ssh_command "cd pasha; ./bench_tpcc --logtostderr=1 --id=0 --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--protocol=TwoPL --query=$QUERY_TYPE --neworder_dist=$REMOTE_NEWORDER_PERC --payment_dist=$REMOTE_PAYMENT_PERC" 0
        else
                echo "Protocol not supported!"
                exit -1
        fi

        if [ $GATHER_OUTPUT == 1 ]; then
                gather_other_output $HOST_NUM
        fi

        kill_prev_exps $HOST_NUM
}

function run_exp_ycsb {
        if [ $# != 27 ]; then
                print_usage
                exit -1
        fi
        typeset PROTOCOL=$1
        typeset HOST_NUM=$2
        typeset WORKER_NUM=$3
        typeset QUERY_TYPE=$4
        typeset KEYS=$5
        typeset RW_RATIO=$6
        typeset ZIPF_THETA=$7
        typeset CROSS_RATIO=$8
        typeset USE_CXL_TRANS=$9
        typeset USE_OUTPUT_THREAD=${10}
        typeset CXL_TRANS_ENTRY_STRUCT_SIZE=${11}
        typeset CXL_TRANS_ENTRY_NUM=${12}
        typeset ENABLE_MIGRATION_OPTIMIZATION=${13}
        typeset MIGRATION_POLICY=${14}
        typeset WHEN_TO_MOVE_OUT=${15}
        typeset HW_CC_BUDGET=${16}
        typeset ENABLE_SCC=${17}
        typeset SCC_MECH=${18}
        typeset PRE_MIGRATE=${19}
        typeset TIME_TO_RUN=${20}
        typeset TIME_TO_WARMUP=${21}
        typeset LOG_PATH=${22}
        typeset LOTUS_CHECKPOINT=${23}
        typeset WAL_GROUP_COMMIT_TIME=${24}
        typeset WAL_GROUP_COMMIT_BATCH_SIZE=${25}
        typeset MODEL_CXL_SEARCH_OVERHEAD=${26}
        typeset GATHER_OUTPUT=${27}

        typeset PARTITION_NUM=$(expr $HOST_NUM) # YCSB uses one partition per host
        typeset SERVER_STRING=$(print_server_string $HOST_NUM)
        typeset i=0

        kill_prev_exps $HOST_NUM
        delete_log_files
        init_cxl_for_vms $HOST_NUM

        if [ $PROTOCOL = "SundialPasha" ]; then
                # launch 1-$HOST_NUM processes
                for (( i=1; i < $HOST_NUM; ++i ))
                do
                        ssh_command "cd pasha; nohup ./bench_ycsb --logtostderr=1 --id=$i --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--enable_migration_optimization=$ENABLE_MIGRATION_OPTIMIZATION --migration_policy=$MIGRATION_POLICY --when_to_move_out=$WHEN_TO_MOVE_OUT --hw_cc_budget=$HW_CC_BUDGET \
--enable_scc=$ENABLE_SCC --scc_mechanism=$SCC_MECH \
--pre_migrate=$PRE_MIGRATE \
--protocol=SundialPasha --query=$QUERY_TYPE --keys=$KEYS --read_write_ratio=$RW_RATIO --zipf=$ZIPF_THETA --cross_ratio=$CROSS_RATIO --cross_part_num=2 &> output.txt < /dev/null &" $i
                done

                # launch the first process
                ssh_command "cd pasha; ./bench_ycsb --logtostderr=1 --id=0 --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--enable_migration_optimization=$ENABLE_MIGRATION_OPTIMIZATION --migration_policy=$MIGRATION_POLICY --when_to_move_out=$WHEN_TO_MOVE_OUT --hw_cc_budget=$HW_CC_BUDGET \
--enable_scc=$ENABLE_SCC --scc_mechanism=$SCC_MECH \
--pre_migrate=$PRE_MIGRATE \
--protocol=SundialPasha --query=$QUERY_TYPE --keys=$KEYS --read_write_ratio=$RW_RATIO --zipf=$ZIPF_THETA --cross_ratio=$CROSS_RATIO --cross_part_num=2" 0

        elif [ $PROTOCOL = "Sundial" ]; then
                # launch 1-$HOST_NUM processes
                for (( i=1; i < $HOST_NUM; ++i ))
                do
                        ssh_command "cd pasha; nohup ./bench_ycsb --logtostderr=1 --id=$i --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--protocol=Sundial --query=$QUERY_TYPE --keys=$KEYS --read_write_ratio=$RW_RATIO --zipf=$ZIPF_THETA --cross_ratio=$CROSS_RATIO --cross_part_num=2 &> output.txt < /dev/null &" $i
                done

                # launch the first process
                ssh_command "cd pasha; ./bench_ycsb --logtostderr=1 --id=0 --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--protocol=Sundial --query=$QUERY_TYPE --keys=$KEYS --read_write_ratio=$RW_RATIO --zipf=$ZIPF_THETA --cross_ratio=$CROSS_RATIO --cross_part_num=2" 0

        elif [ $PROTOCOL = "TwoPLPasha" ]; then
                # launch 1-$HOST_NUM processes
                for (( i=1; i < $HOST_NUM; ++i ))
                do
                        ssh_command "cd pasha; nohup ./bench_ycsb --logtostderr=1 --id=$i --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--enable_migration_optimization=$ENABLE_MIGRATION_OPTIMIZATION --migration_policy=$MIGRATION_POLICY --when_to_move_out=$WHEN_TO_MOVE_OUT --hw_cc_budget=$HW_CC_BUDGET \
--enable_scc=$ENABLE_SCC --scc_mechanism=$SCC_MECH --model_cxl_search_overhead=$MODEL_CXL_SEARCH_OVERHEAD \
--pre_migrate=$PRE_MIGRATE \
--protocol=TwoPLPasha --query=$QUERY_TYPE --keys=$KEYS --read_write_ratio=$RW_RATIO --zipf=$ZIPF_THETA --cross_ratio=$CROSS_RATIO --cross_part_num=2 &> output.txt < /dev/null &" $i
                done

                # launch the first process
                ssh_command "cd pasha; ./bench_ycsb --logtostderr=1 --id=0 --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--enable_migration_optimization=$ENABLE_MIGRATION_OPTIMIZATION --migration_policy=$MIGRATION_POLICY --when_to_move_out=$WHEN_TO_MOVE_OUT --hw_cc_budget=$HW_CC_BUDGET \
--enable_scc=$ENABLE_SCC --scc_mechanism=$SCC_MECH --model_cxl_search_overhead=$MODEL_CXL_SEARCH_OVERHEAD \
--pre_migrate=$PRE_MIGRATE \
--protocol=TwoPLPasha --query=$QUERY_TYPE --keys=$KEYS --read_write_ratio=$RW_RATIO --zipf=$ZIPF_THETA --cross_ratio=$CROSS_RATIO --cross_part_num=2" 0

        elif [ $PROTOCOL = "TwoPLPashaPhantom" ]; then
                # launch 1-$HOST_NUM processes
                for (( i=1; i < $HOST_NUM; ++i ))
                do
                        ssh_command "cd pasha; nohup ./bench_ycsb --logtostderr=1 --id=$i --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--enable_migration_optimization=$ENABLE_MIGRATION_OPTIMIZATION --migration_policy=$MIGRATION_POLICY --when_to_move_out=$WHEN_TO_MOVE_OUT --hw_cc_budget=$HW_CC_BUDGET \
--enable_scc=$ENABLE_SCC --scc_mechanism=$SCC_MECH --enable_phantom_detection=false --model_cxl_search_overhead=$MODEL_CXL_SEARCH_OVERHEAD \
--pre_migrate=$PRE_MIGRATE \
--protocol=TwoPLPasha --query=$QUERY_TYPE --keys=$KEYS --read_write_ratio=$RW_RATIO --zipf=$ZIPF_THETA --cross_ratio=$CROSS_RATIO --cross_part_num=2 &> output.txt < /dev/null &" $i
                done

                # launch the first process
                ssh_command "cd pasha; ./bench_ycsb --logtostderr=1 --id=0 --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--enable_migration_optimization=$ENABLE_MIGRATION_OPTIMIZATION --migration_policy=$MIGRATION_POLICY --when_to_move_out=$WHEN_TO_MOVE_OUT --hw_cc_budget=$HW_CC_BUDGET \
--enable_scc=$ENABLE_SCC --scc_mechanism=$SCC_MECH --enable_phantom_detection=false --model_cxl_search_overhead=$MODEL_CXL_SEARCH_OVERHEAD \
--pre_migrate=$PRE_MIGRATE \
--protocol=TwoPLPasha --query=$QUERY_TYPE --keys=$KEYS --read_write_ratio=$RW_RATIO --zipf=$ZIPF_THETA --cross_ratio=$CROSS_RATIO --cross_part_num=2" 0

        elif [ $PROTOCOL = "TwoPL" ]; then
                # launch 1-$HOST_NUM processes
                for (( i=1; i < $HOST_NUM; ++i ))
                do
                        ssh_command "cd pasha; nohup ./bench_ycsb --logtostderr=1 --id=$i --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--protocol=TwoPL --query=$QUERY_TYPE --keys=$KEYS --read_write_ratio=$RW_RATIO --zipf=$ZIPF_THETA --cross_ratio=$CROSS_RATIO --cross_part_num=2 &> output.txt < /dev/null &" $i
                done

                # launch the first process
                ssh_command "cd pasha; ./bench_ycsb --logtostderr=1 --id=0 --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--protocol=TwoPL --query=$QUERY_TYPE --keys=$KEYS --read_write_ratio=$RW_RATIO --zipf=$ZIPF_THETA --cross_ratio=$CROSS_RATIO --cross_part_num=2" 0
        else
                echo "Protocol not supported!"
                exit -1
        fi

        if [ $GATHER_OUTPUT == 1 ]; then
                gather_other_output $HOST_NUM
        fi

        kill_prev_exps $HOST_NUM
}

function run_exp_smallbank {
        if [ $# != 25 ]; then
                print_usage
                exit -1
        fi
        typeset PROTOCOL=$1
        typeset HOST_NUM=$2
        typeset WORKER_NUM=$3
        typeset KEYS=$4
        typeset ZIPF_THETA=$5
        typeset CROSS_RATIO=$6
        typeset USE_CXL_TRANS=$7
        typeset USE_OUTPUT_THREAD=$8
        typeset CXL_TRANS_ENTRY_STRUCT_SIZE=$9
        typeset CXL_TRANS_ENTRY_NUM=${10}
        typeset ENABLE_MIGRATION_OPTIMIZATION=${11}
        typeset MIGRATION_POLICY=${12}
        typeset WHEN_TO_MOVE_OUT=${13}
        typeset HW_CC_BUDGET=${14}
        typeset ENABLE_SCC=${15}
        typeset SCC_MECH=${16}
        typeset PRE_MIGRATE=${17}
        typeset TIME_TO_RUN=${18}
        typeset TIME_TO_WARMUP=${19}
        typeset LOG_PATH=${20}
        typeset LOTUS_CHECKPOINT=${21}
        typeset WAL_GROUP_COMMIT_TIME=${22}
        typeset WAL_GROUP_COMMIT_BATCH_SIZE=${23}
        typeset MODEL_CXL_SEARCH_OVERHEAD=${24}
        typeset GATHER_OUTPUT=${25}

        typeset PARTITION_NUM=$(expr $HOST_NUM) # one partition per host
        typeset SERVER_STRING=$(print_server_string $HOST_NUM)
        typeset i=0

        kill_prev_exps $HOST_NUM
        delete_log_files
        init_cxl_for_vms $HOST_NUM

        if [ $PROTOCOL = "SundialPasha" ]; then
                # launch 1-$HOST_NUM processes
                for (( i=1; i < $HOST_NUM; ++i ))
                do
                        ssh_command "cd pasha; nohup ./bench_smallbank --logtostderr=1 --id=$i --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--enable_migration_optimization=$ENABLE_MIGRATION_OPTIMIZATION --migration_policy=$MIGRATION_POLICY --when_to_move_out=$WHEN_TO_MOVE_OUT --hw_cc_budget=$HW_CC_BUDGET \
--enable_scc=$ENABLE_SCC --scc_mechanism=$SCC_MECH \
--pre_migrate=$PRE_MIGRATE \
--protocol=SundialPasha --keys=$KEYS --zipf=$ZIPF_THETA --cross_ratio=$CROSS_RATIO &> output.txt < /dev/null &" $i
                done

                # launch the first process
                ssh_command "cd pasha; ./bench_smallbank --logtostderr=1 --id=0 --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--enable_migration_optimization=$ENABLE_MIGRATION_OPTIMIZATION --migration_policy=$MIGRATION_POLICY --when_to_move_out=$WHEN_TO_MOVE_OUT --hw_cc_budget=$HW_CC_BUDGET \
--enable_scc=$ENABLE_SCC --scc_mechanism=$SCC_MECH \
--pre_migrate=$PRE_MIGRATE \
--protocol=SundialPasha --keys=$KEYS --zipf=$ZIPF_THETA --cross_ratio=$CROSS_RATIO" 0

        elif [ $PROTOCOL = "Sundial" ]; then
                # launch 1-$HOST_NUM processes
                for (( i=1; i < $HOST_NUM; ++i ))
                do
                        ssh_command "cd pasha; nohup ./bench_smallbank --logtostderr=1 --id=$i --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--protocol=Sundial --keys=$KEYS --zipf=$ZIPF_THETA --cross_ratio=$CROSS_RATIO &> output.txt < /dev/null &" $i
                done

                # launch the first process
                ssh_command "cd pasha; ./bench_smallbank --logtostderr=1 --id=0 --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--protocol=Sundial --keys=$KEYS --zipf=$ZIPF_THETA --cross_ratio=$CROSS_RATIO" 0

        elif [ $PROTOCOL = "TwoPLPasha" ]; then
                # launch 1-$HOST_NUM processes
                for (( i=1; i < $HOST_NUM; ++i ))
                do
                        ssh_command "cd pasha; nohup ./bench_smallbank --logtostderr=1 --id=$i --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--enable_migration_optimization=$ENABLE_MIGRATION_OPTIMIZATION --migration_policy=$MIGRATION_POLICY --when_to_move_out=$WHEN_TO_MOVE_OUT --hw_cc_budget=$HW_CC_BUDGET \
--enable_scc=$ENABLE_SCC --scc_mechanism=$SCC_MECH --model_cxl_search_overhead=$MODEL_CXL_SEARCH_OVERHEAD \
--pre_migrate=$PRE_MIGRATE \
--protocol=TwoPLPasha --keys=$KEYS --zipf=$ZIPF_THETA --cross_ratio=$CROSS_RATIO &> output.txt < /dev/null &" $i
                done

                # launch the first process
                ssh_command "cd pasha; ./bench_smallbank --logtostderr=1 --id=0 --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--enable_migration_optimization=$ENABLE_MIGRATION_OPTIMIZATION --migration_policy=$MIGRATION_POLICY --when_to_move_out=$WHEN_TO_MOVE_OUT --hw_cc_budget=$HW_CC_BUDGET \
--enable_scc=$ENABLE_SCC --scc_mechanism=$SCC_MECH --model_cxl_search_overhead=$MODEL_CXL_SEARCH_OVERHEAD \
--pre_migrate=$PRE_MIGRATE \
--protocol=TwoPLPasha --keys=$KEYS --zipf=$ZIPF_THETA --cross_ratio=$CROSS_RATIO" 0

        elif [ $PROTOCOL = "TwoPLPashaPhantom" ]; then
                # launch 1-$HOST_NUM processes
                for (( i=1; i < $HOST_NUM; ++i ))
                do
                        ssh_command "cd pasha; nohup ./bench_smallbank --logtostderr=1 --id=$i --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--enable_migration_optimization=$ENABLE_MIGRATION_OPTIMIZATION --migration_policy=$MIGRATION_POLICY --when_to_move_out=$WHEN_TO_MOVE_OUT --hw_cc_budget=$HW_CC_BUDGET \
--enable_scc=$ENABLE_SCC --scc_mechanism=$SCC_MECH --enable_phantom_detection=false --model_cxl_search_overhead=$MODEL_CXL_SEARCH_OVERHEAD \
--pre_migrate=$PRE_MIGRATE \
--protocol=TwoPLPasha --keys=$KEYS --zipf=$ZIPF_THETA --cross_ratio=$CROSS_RATIO &> output.txt < /dev/null &" $i
                done

                # launch the first process
                ssh_command "cd pasha; ./bench_smallbank --logtostderr=1 --id=0 --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--enable_migration_optimization=$ENABLE_MIGRATION_OPTIMIZATION --migration_policy=$MIGRATION_POLICY --when_to_move_out=$WHEN_TO_MOVE_OUT --hw_cc_budget=$HW_CC_BUDGET \
--enable_scc=$ENABLE_SCC --scc_mechanism=$SCC_MECH --enable_phantom_detection=false --model_cxl_search_overhead=$MODEL_CXL_SEARCH_OVERHEAD \
--pre_migrate=$PRE_MIGRATE \
--protocol=TwoPLPasha --keys=$KEYS --zipf=$ZIPF_THETA --cross_ratio=$CROSS_RATIO" 0

        elif [ $PROTOCOL = "TwoPL" ]; then
                # launch 1-$HOST_NUM processes
                for (( i=1; i < $HOST_NUM; ++i ))
                do
                        ssh_command "cd pasha; nohup ./bench_smallbank --logtostderr=1 --id=$i --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--protocol=TwoPL --keys=$KEYS --zipf=$ZIPF_THETA --cross_ratio=$CROSS_RATIO &> output.txt < /dev/null &" $i
                done

                # launch the first process
                ssh_command "cd pasha; ./bench_smallbank --logtostderr=1 --id=0 --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--protocol=TwoPL --keys=$KEYS --zipf=$ZIPF_THETA --cross_ratio=$CROSS_RATIO" 0
        else
                echo "Protocol not supported!"
                exit -1
        fi

        if [ $GATHER_OUTPUT == 1 ]; then
                gather_other_output $HOST_NUM
        fi

        kill_prev_exps $HOST_NUM
}

function run_exp_tatp {
        if [ $# != 25 ]; then
                print_usage
                exit -1
        fi
        typeset PROTOCOL=$1
        typeset HOST_NUM=$2
        typeset WORKER_NUM=$3
        typeset KEYS=$4
        typeset ZIPF_THETA=$5
        typeset CROSS_RATIO=$6
        typeset USE_CXL_TRANS=$7
        typeset USE_OUTPUT_THREAD=$8
        typeset CXL_TRANS_ENTRY_STRUCT_SIZE=$9
        typeset CXL_TRANS_ENTRY_NUM=${10}
        typeset ENABLE_MIGRATION_OPTIMIZATION=${11}
        typeset MIGRATION_POLICY=${12}
        typeset WHEN_TO_MOVE_OUT=${13}
        typeset HW_CC_BUDGET=${14}
        typeset ENABLE_SCC=${15}
        typeset SCC_MECH=${16}
        typeset PRE_MIGRATE=${17}
        typeset TIME_TO_RUN=${18}
        typeset TIME_TO_WARMUP=${19}
        typeset LOG_PATH=${20}
        typeset LOTUS_CHECKPOINT=${21}
        typeset WAL_GROUP_COMMIT_TIME=${22}
        typeset WAL_GROUP_COMMIT_BATCH_SIZE=${23}
        typeset MODEL_CXL_SEARCH_OVERHEAD=${24}
        typeset GATHER_OUTPUT=${25}

        typeset PARTITION_NUM=$(expr $HOST_NUM \* 1)    # one partition per host
        typeset SERVER_STRING=$(print_server_string $HOST_NUM)
        typeset i=0

        kill_prev_exps $HOST_NUM
        delete_log_files
        init_cxl_for_vms $HOST_NUM

        if [ $PROTOCOL = "SundialPasha" ]; then
                # launch 1-$HOST_NUM processes
                for (( i=1; i < $HOST_NUM; ++i ))
                do
                        ssh_command "cd pasha; nohup ./bench_tatp --logtostderr=1 --id=$i --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--enable_migration_optimization=$ENABLE_MIGRATION_OPTIMIZATION --migration_policy=$MIGRATION_POLICY --when_to_move_out=$WHEN_TO_MOVE_OUT --hw_cc_budget=$HW_CC_BUDGET \
--enable_scc=$ENABLE_SCC --scc_mechanism=$SCC_MECH \
--pre_migrate=$PRE_MIGRATE \
--protocol=SundialPasha --keys=$KEYS --zipf=$ZIPF_THETA --cross_ratio=$CROSS_RATIO &> output.txt < /dev/null &" $i
                done

                # launch the first process
                ssh_command "cd pasha; ./bench_tatp --logtostderr=1 --id=0 --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--enable_migration_optimization=$ENABLE_MIGRATION_OPTIMIZATION --migration_policy=$MIGRATION_POLICY --when_to_move_out=$WHEN_TO_MOVE_OUT --hw_cc_budget=$HW_CC_BUDGET \
--enable_scc=$ENABLE_SCC --scc_mechanism=$SCC_MECH \
--pre_migrate=$PRE_MIGRATE \
--protocol=SundialPasha --keys=$KEYS --zipf=$ZIPF_THETA --cross_ratio=$CROSS_RATIO" 0

        elif [ $PROTOCOL = "Sundial" ]; then
                # launch 1-$HOST_NUM processes
                for (( i=1; i < $HOST_NUM; ++i ))
                do
                        ssh_command "cd pasha; nohup ./bench_tatp --logtostderr=1 --id=$i --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--protocol=Sundial --keys=$KEYS --zipf=$ZIPF_THETA --cross_ratio=$CROSS_RATIO &> output.txt < /dev/null &" $i
                done

                # launch the first process
                ssh_command "cd pasha; ./bench_tatp --logtostderr=1 --id=0 --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--protocol=Sundial --keys=$KEYS --zipf=$ZIPF_THETA --cross_ratio=$CROSS_RATIO" 0

        elif [ $PROTOCOL = "TwoPLPasha" ]; then
                # launch 1-$HOST_NUM processes
                for (( i=1; i < $HOST_NUM; ++i ))
                do
                        ssh_command "cd pasha; nohup ./bench_tatp --logtostderr=1 --id=$i --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--enable_migration_optimization=$ENABLE_MIGRATION_OPTIMIZATION --migration_policy=$MIGRATION_POLICY --when_to_move_out=$WHEN_TO_MOVE_OUT --hw_cc_budget=$HW_CC_BUDGET \
--enable_scc=$ENABLE_SCC --scc_mechanism=$SCC_MECH --model_cxl_search_overhead=$MODEL_CXL_SEARCH_OVERHEAD \
--pre_migrate=$PRE_MIGRATE \
--protocol=TwoPLPasha --keys=$KEYS --zipf=$ZIPF_THETA --cross_ratio=$CROSS_RATIO &> output.txt < /dev/null &" $i
                done

                # launch the first process
                ssh_command "cd pasha; ./bench_tatp --logtostderr=1 --id=0 --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--enable_migration_optimization=$ENABLE_MIGRATION_OPTIMIZATION --migration_policy=$MIGRATION_POLICY --when_to_move_out=$WHEN_TO_MOVE_OUT --hw_cc_budget=$HW_CC_BUDGET \
--enable_scc=$ENABLE_SCC --scc_mechanism=$SCC_MECH --model_cxl_search_overhead=$MODEL_CXL_SEARCH_OVERHEAD \
--pre_migrate=$PRE_MIGRATE \
--protocol=TwoPLPasha --keys=$KEYS --zipf=$ZIPF_THETA --cross_ratio=$CROSS_RATIO" 0

        elif [ $PROTOCOL = "TwoPLPashaPhantom" ]; then
                # launch 1-$HOST_NUM processes
                for (( i=1; i < $HOST_NUM; ++i ))
                do
                        ssh_command "cd pasha; nohup ./bench_tatp --logtostderr=1 --id=$i --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--enable_migration_optimization=$ENABLE_MIGRATION_OPTIMIZATION --migration_policy=$MIGRATION_POLICY --when_to_move_out=$WHEN_TO_MOVE_OUT --hw_cc_budget=$HW_CC_BUDGET \
--enable_scc=$ENABLE_SCC --scc_mechanism=$SCC_MECH --enable_phantom_detection=false --model_cxl_search_overhead=$MODEL_CXL_SEARCH_OVERHEAD \
--pre_migrate=$PRE_MIGRATE \
--protocol=TwoPLPasha --keys=$KEYS --zipf=$ZIPF_THETA --cross_ratio=$CROSS_RATIO &> output.txt < /dev/null &" $i
                done

                # launch the first process
                ssh_command "cd pasha; ./bench_tatp --logtostderr=1 --id=0 --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--enable_migration_optimization=$ENABLE_MIGRATION_OPTIMIZATION --migration_policy=$MIGRATION_POLICY --when_to_move_out=$WHEN_TO_MOVE_OUT --hw_cc_budget=$HW_CC_BUDGET \
--enable_scc=$ENABLE_SCC --scc_mechanism=$SCC_MECH --enable_phantom_detection=false --model_cxl_search_overhead=$MODEL_CXL_SEARCH_OVERHEAD \
--pre_migrate=$PRE_MIGRATE \
--protocol=TwoPLPasha --keys=$KEYS --zipf=$ZIPF_THETA --cross_ratio=$CROSS_RATIO" 0

        elif [ $PROTOCOL = "TwoPL" ]; then
                # launch 1-$HOST_NUM processes
                for (( i=1; i < $HOST_NUM; ++i ))
                do
                        ssh_command "cd pasha; nohup ./bench_tatp --logtostderr=1 --id=$i --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--protocol=TwoPL --keys=$KEYS --zipf=$ZIPF_THETA --cross_ratio=$CROSS_RATIO &> output.txt < /dev/null &" $i
                done

                # launch the first process
                ssh_command "cd pasha; ./bench_tatp --logtostderr=1 --id=0 --servers=\"$SERVER_STRING\" \
--threads=$WORKER_NUM --partition_num=$PARTITION_NUM --granule_count=2000 \
--log_path=$LOG_PATH --lotus_checkpoint=$LOTUS_CHECKPOINT --persist_latency=0 --wal_group_commit_time=$WAL_GROUP_COMMIT_TIME --wal_group_commit_size=$WAL_GROUP_COMMIT_BATCH_SIZE \
--partitioner=hash --hstore_command_logging=false \
--replica_group=1 --lock_manager=0 --batch_flush=1 --lotus_async_repl=true --batch_size=0 --time_to_run=$TIME_TO_RUN --time_to_warmup=$TIME_TO_WARMUP \
--use_cxl_transport=$USE_CXL_TRANS --use_output_thread=$USE_OUTPUT_THREAD --cxl_trans_entry_struct_size=$CXL_TRANS_ENTRY_STRUCT_SIZE --cxl_trans_entry_num=$CXL_TRANS_ENTRY_NUM $CXL_BACKEND_FLAGS \
--protocol=TwoPL --keys=$KEYS --zipf=$ZIPF_THETA --cross_ratio=$CROSS_RATIO" 0
        else
                echo "Protocol not supported!"
                exit -1
        fi

        if [ $GATHER_OUTPUT == 1 ]; then
                gather_other_output $HOST_NUM
        fi

        kill_prev_exps $HOST_NUM
}

# process arguments
if [ $# -lt 1 ]; then
        print_usage
        exit -1
fi

typeset RUN_TYPE=$1

# global configurations
typeset PASHA_CXL_TRANS_ENTRY_STRUCT_SIZE=2048
typeset PASHA_CXL_TRANS_ENTRY_NUM=8192

typeset BASELINE_CXL_TRANS_ENTRY_STRUCT_SIZE=65536
typeset BASELINE_CXL_TRANS_ENTRY_NUM=8192

if [ $RUN_TYPE = "TPCC" ]; then
        if [ $# != 22 ]; then
                print_usage
                exit -1
        fi

        typeset PROTOCOL=$2
        typeset HOST_NUM=$3
        typeset WORKER_NUM=$4
        typeset QUERY_TYPE=$5
        typeset REMOTE_NEWORDER_PERC=$6
        typeset REMOTE_PAYMENT_PERC=$7
        typeset USE_CXL_TRANS=$8
        typeset USE_OUTPUT_THREAD=$9
        typeset ENABLE_MIGRATION_OPTIMIZATION=${10}
        typeset MIGRATION_POLICY=${11}
        typeset WHEN_TO_MOVE_OUT=${12}
        typeset HW_CC_BUDGET=${13}
        typeset ENABLE_SCC=${14}
        typeset SCC_MECH=${15}
        typeset PRE_MIGRATE=${16}
        typeset TIME_TO_RUN=${17}
        typeset TIME_TO_WARMUP=${18}
        typeset LOGGING_TYPE=${19}
        typeset EPOCH_LEN=${20}
        typeset MODEL_CXL_SEARCH_OVERHEAD=${21}
        typeset GATHER_OUTPUT=${22}

        if [ $PROTOCOL = "SundialPasha" ] || [ $PROTOCOL = "TwoPLPasha" ]; then
                typeset CXL_TRANS_ENTRY_STRUCT_SIZE=$PASHA_CXL_TRANS_ENTRY_STRUCT_SIZE
                typeset CXL_TRANS_ENTRY_NUM=$PASHA_CXL_TRANS_ENTRY_NUM
        else
                typeset CXL_TRANS_ENTRY_STRUCT_SIZE=$BASELINE_CXL_TRANS_ENTRY_STRUCT_SIZE
                typeset CXL_TRANS_ENTRY_NUM=$BASELINE_CXL_TRANS_ENTRY_NUM
        fi

        typeset LOG_PATH="/root/pasha_log"
        if [ $LOGGING_TYPE = "WAL" ]; then
                typeset LOTUS_CHECKPOINT=1
                typeset WAL_GROUP_COMMIT_TIME=0
                typeset WAL_GROUP_COMMIT_BATCH_SIZE=0

        elif [ $LOGGING_TYPE = "GROUP_WAL" ]; then
                typeset LOTUS_CHECKPOINT=1
                typeset WAL_GROUP_COMMIT_TIME=$EPOCH_LEN     # SiloR uses 40ms
                typeset WAL_GROUP_COMMIT_BATCH_SIZE=10

        elif [ $LOGGING_TYPE = "BLACKHOLE" ]; then
                typeset LOTUS_CHECKPOINT=0
                typeset WAL_GROUP_COMMIT_TIME=0
                typeset WAL_GROUP_COMMIT_BATCH_SIZE=0
        else
                print_usage
                exit -1
        fi

        run_exp_tpcc $PROTOCOL $HOST_NUM $WORKER_NUM $QUERY_TYPE $REMOTE_NEWORDER_PERC $REMOTE_PAYMENT_PERC $USE_CXL_TRANS $USE_OUTPUT_THREAD $CXL_TRANS_ENTRY_STRUCT_SIZE $CXL_TRANS_ENTRY_NUM $ENABLE_MIGRATION_OPTIMIZATION $MIGRATION_POLICY $WHEN_TO_MOVE_OUT $HW_CC_BUDGET $ENABLE_SCC $SCC_MECH $PRE_MIGRATE $TIME_TO_RUN $TIME_TO_WARMUP $LOG_PATH $LOTUS_CHECKPOINT $WAL_GROUP_COMMIT_TIME $WAL_GROUP_COMMIT_BATCH_SIZE $MODEL_CXL_SEARCH_OVERHEAD $GATHER_OUTPUT
        exit 0
elif [ $RUN_TYPE = "YCSB" ]; then
        if [ $# != 24 ]; then
                print_usage
                exit -1
        fi

        typeset PROTOCOL=$2
        typeset HOST_NUM=$3
        typeset WORKER_NUM=$4
        typeset QUERY_TYPE=$5
        typeset KEYS=$6
        typeset RW_RATIO=$7
        typeset ZIPF_THETA=$8
        typeset CROSS_RATIO=$9
        typeset USE_CXL_TRANS=${10}
        typeset USE_OUTPUT_THREAD=${11}
        typeset ENABLE_MIGRATION_OPTIMIZATION=${12}
        typeset MIGRATION_POLICY=${13}
        typeset WHEN_TO_MOVE_OUT=${14}
        typeset HW_CC_BUDGET=${15}
        typeset ENABLE_SCC=${16}
        typeset SCC_MECH=${17}
        typeset PRE_MIGRATE=${18}
        typeset TIME_TO_RUN=${19}
        typeset TIME_TO_WARMUP=${20}
        typeset LOGGING_TYPE=${21}
        typeset EPOCH_LEN=${22}
        typeset MODEL_CXL_SEARCH_OVERHEAD=${23}
        typeset GATHER_OUTPUT=${24}

        if [ $PROTOCOL = "SundialPasha" ] || [ $PROTOCOL = "TwoPLPasha" ]; then
                typeset CXL_TRANS_ENTRY_STRUCT_SIZE=$PASHA_CXL_TRANS_ENTRY_STRUCT_SIZE
                typeset CXL_TRANS_ENTRY_NUM=$PASHA_CXL_TRANS_ENTRY_NUM
        else
                typeset CXL_TRANS_ENTRY_STRUCT_SIZE=$BASELINE_CXL_TRANS_ENTRY_STRUCT_SIZE
                typeset CXL_TRANS_ENTRY_NUM=$BASELINE_CXL_TRANS_ENTRY_NUM
        fi

        typeset LOG_PATH="/root/pasha_log"
        if [ $LOGGING_TYPE = "WAL" ]; then
                typeset LOTUS_CHECKPOINT=1
                typeset WAL_GROUP_COMMIT_TIME=0
                typeset WAL_GROUP_COMMIT_BATCH_SIZE=0

        elif [ $LOGGING_TYPE = "GROUP_WAL" ]; then
                typeset LOTUS_CHECKPOINT=1
                typeset WAL_GROUP_COMMIT_TIME=$EPOCH_LEN   # SiloR uses 40ms
                typeset WAL_GROUP_COMMIT_BATCH_SIZE=10

        elif [ $LOGGING_TYPE = "BLACKHOLE" ]; then
                typeset LOTUS_CHECKPOINT=0
                typeset WAL_GROUP_COMMIT_TIME=0
                typeset WAL_GROUP_COMMIT_BATCH_SIZE=0
        else
                print_usage
                exit -1
        fi

        run_exp_ycsb $PROTOCOL $HOST_NUM $WORKER_NUM $QUERY_TYPE $KEYS $RW_RATIO $ZIPF_THETA $CROSS_RATIO $USE_CXL_TRANS $USE_OUTPUT_THREAD $CXL_TRANS_ENTRY_STRUCT_SIZE $CXL_TRANS_ENTRY_NUM $ENABLE_MIGRATION_OPTIMIZATION $MIGRATION_POLICY $WHEN_TO_MOVE_OUT $HW_CC_BUDGET $ENABLE_SCC $SCC_MECH $PRE_MIGRATE $TIME_TO_RUN $TIME_TO_WARMUP $LOG_PATH $LOTUS_CHECKPOINT $WAL_GROUP_COMMIT_TIME $WAL_GROUP_COMMIT_BATCH_SIZE $MODEL_CXL_SEARCH_OVERHEAD $GATHER_OUTPUT
        exit 0
elif [ $RUN_TYPE = "SmallBank" ]; then
        if [ $# != 22 ]; then
                print_usage
                exit -1
        fi

        typeset PROTOCOL=$2
        typeset HOST_NUM=$3
        typeset WORKER_NUM=$4
        typeset KEYS=$5
        typeset ZIPF_THETA=$6
        typeset CROSS_RATIO=$7
        typeset USE_CXL_TRANS=$8
        typeset USE_OUTPUT_THREAD=$9
        typeset ENABLE_MIGRATION_OPTIMIZATION=${10}
        typeset MIGRATION_POLICY=${11}
        typeset WHEN_TO_MOVE_OUT=${12}
        typeset HW_CC_BUDGET=${13}
        typeset ENABLE_SCC=${14}
        typeset SCC_MECH=${15}
        typeset PRE_MIGRATE=${16}
        typeset TIME_TO_RUN=${17}
        typeset TIME_TO_WARMUP=${18}
        typeset LOGGING_TYPE=${19}
        typeset EPOCH_LEN=${20}
        typeset MODEL_CXL_SEARCH_OVERHEAD=${21}
        typeset GATHER_OUTPUT=${22}

        if [ $PROTOCOL = "SundialPasha" ] || [ $PROTOCOL = "TwoPLPasha" ]; then
                typeset CXL_TRANS_ENTRY_STRUCT_SIZE=$PASHA_CXL_TRANS_ENTRY_STRUCT_SIZE
                typeset CXL_TRANS_ENTRY_NUM=$PASHA_CXL_TRANS_ENTRY_NUM
        else
                typeset CXL_TRANS_ENTRY_STRUCT_SIZE=$BASELINE_CXL_TRANS_ENTRY_STRUCT_SIZE
                typeset CXL_TRANS_ENTRY_NUM=$BASELINE_CXL_TRANS_ENTRY_NUM
        fi

        typeset LOG_PATH="/root/pasha_log"
        if [ $LOGGING_TYPE = "WAL" ]; then
                typeset LOTUS_CHECKPOINT=1
                typeset WAL_GROUP_COMMIT_TIME=0
                typeset WAL_GROUP_COMMIT_BATCH_SIZE=0

        elif [ $LOGGING_TYPE = "GROUP_WAL" ]; then
                typeset LOTUS_CHECKPOINT=1
                typeset WAL_GROUP_COMMIT_TIME=$EPOCH_LEN   # SiloR uses 40ms
                typeset WAL_GROUP_COMMIT_BATCH_SIZE=10

        elif [ $LOGGING_TYPE = "BLACKHOLE" ]; then
                typeset LOTUS_CHECKPOINT=0
                typeset WAL_GROUP_COMMIT_TIME=0
                typeset WAL_GROUP_COMMIT_BATCH_SIZE=0
        else
                print_usage
                exit -1
        fi

        run_exp_smallbank $PROTOCOL $HOST_NUM $WORKER_NUM $KEYS $ZIPF_THETA $CROSS_RATIO $USE_CXL_TRANS $USE_OUTPUT_THREAD $CXL_TRANS_ENTRY_STRUCT_SIZE $CXL_TRANS_ENTRY_NUM $ENABLE_MIGRATION_OPTIMIZATION $MIGRATION_POLICY $WHEN_TO_MOVE_OUT $HW_CC_BUDGET $ENABLE_SCC $SCC_MECH $PRE_MIGRATE $TIME_TO_RUN $TIME_TO_WARMUP $LOG_PATH $LOTUS_CHECKPOINT $WAL_GROUP_COMMIT_TIME $WAL_GROUP_COMMIT_BATCH_SIZE $MODEL_CXL_SEARCH_OVERHEAD $GATHER_OUTPUT
        exit 0
elif [ $RUN_TYPE = "TATP" ]; then
        if [ $# != 22 ]; then
                print_usage
                exit -1
        fi

        typeset PROTOCOL=$2
        typeset HOST_NUM=$3
        typeset WORKER_NUM=$4
        typeset KEYS=$5
        typeset ZIPF_THETA=$6
        typeset CROSS_RATIO=$7
        typeset USE_CXL_TRANS=$8
        typeset USE_OUTPUT_THREAD=$9
        typeset ENABLE_MIGRATION_OPTIMIZATION=${10}
        typeset MIGRATION_POLICY=${11}
        typeset WHEN_TO_MOVE_OUT=${12}
        typeset HW_CC_BUDGET=${13}
        typeset ENABLE_SCC=${14}
        typeset SCC_MECH=${15}
        typeset PRE_MIGRATE=${16}
        typeset TIME_TO_RUN=${17}
        typeset TIME_TO_WARMUP=${18}
        typeset LOGGING_TYPE=${19}
        typeset EPOCH_LEN=${20}
        typeset MODEL_CXL_SEARCH_OVERHEAD=${21}
        typeset GATHER_OUTPUT=${22}

        if [ $PROTOCOL = "SundialPasha" ] || [ $PROTOCOL = "TwoPLPasha" ]; then
                typeset CXL_TRANS_ENTRY_STRUCT_SIZE=$PASHA_CXL_TRANS_ENTRY_STRUCT_SIZE
                typeset CXL_TRANS_ENTRY_NUM=$PASHA_CXL_TRANS_ENTRY_NUM
        else
                typeset CXL_TRANS_ENTRY_STRUCT_SIZE=$BASELINE_CXL_TRANS_ENTRY_STRUCT_SIZE
                typeset CXL_TRANS_ENTRY_NUM=$BASELINE_CXL_TRANS_ENTRY_NUM
        fi

        typeset LOG_PATH="/root/pasha_log"
        if [ $LOGGING_TYPE = "WAL" ]; then
                typeset LOTUS_CHECKPOINT=1
                typeset WAL_GROUP_COMMIT_TIME=0
                typeset WAL_GROUP_COMMIT_BATCH_SIZE=0

        elif [ $LOGGING_TYPE = "GROUP_WAL" ]; then
                typeset LOTUS_CHECKPOINT=1
                typeset WAL_GROUP_COMMIT_TIME=$EPOCH_LEN   # SiloR uses 40ms
                typeset WAL_GROUP_COMMIT_BATCH_SIZE=10

        elif [ $LOGGING_TYPE = "BLACKHOLE" ]; then
                typeset LOTUS_CHECKPOINT=0
                typeset WAL_GROUP_COMMIT_TIME=0
                typeset WAL_GROUP_COMMIT_BATCH_SIZE=0
        else
                print_usage
                exit -1
        fi

        run_exp_tatp $PROTOCOL $HOST_NUM $WORKER_NUM $KEYS $ZIPF_THETA $CROSS_RATIO $USE_CXL_TRANS $USE_OUTPUT_THREAD $CXL_TRANS_ENTRY_STRUCT_SIZE $CXL_TRANS_ENTRY_NUM $ENABLE_MIGRATION_OPTIMIZATION $MIGRATION_POLICY $WHEN_TO_MOVE_OUT $HW_CC_BUDGET $ENABLE_SCC $SCC_MECH $PRE_MIGRATE $TIME_TO_RUN $TIME_TO_WARMUP $LOG_PATH $LOTUS_CHECKPOINT $WAL_GROUP_COMMIT_TIME $WAL_GROUP_COMMIT_BATCH_SIZE $MODEL_CXL_SEARCH_OVERHEAD $GATHER_OUTPUT
        exit 0
elif [ $RUN_TYPE = "KILL" ]; then
        if [ $# != 2 ]; then
                print_usage
                exit -1
        fi

        typeset HOST_NUM=$2

        kill_prev_exps $HOST_NUM

        exit 0
elif [ $RUN_TYPE = "COMPILE" ]; then
        if [ $# != 1 ]; then
                print_usage
                exit -1
        fi

        # compile
        cd $SCRIPT_DIR/../
        mkdir -p build
        cd build
        cmake ..
        make -j

        exit 0
elif [ $RUN_TYPE = "COMPILE_SYNC" ]; then
        if [ $# != 2 ]; then
                print_usage
                exit -1
        fi

        typeset HOST_NUM=$2

        # compile
        cd $SCRIPT_DIR/../
        mkdir -p build
        cd build
        cmake ..
        make -j

        # sync
        sync_binaries $HOST_NUM

        exit 0
elif [ $RUN_TYPE = "CI" ]; then
        if [ $# != 3 ]; then
                print_usage
                exit -1
        fi

        typeset HOST_NUM=$2
        typeset WORKER_NUM=$3

        echo "CI under construction!"

        exit -1
elif [ $RUN_TYPE = "COLLECT_OUTPUTS" ]; then
        if [ $# != 2 ]; then
                print_usage
                exit -1
        fi

        typeset HOST_NUM=$2

        gather_other_output $HOST_NUM

        exit 0
else
        print_usage
        exit -1
fi
