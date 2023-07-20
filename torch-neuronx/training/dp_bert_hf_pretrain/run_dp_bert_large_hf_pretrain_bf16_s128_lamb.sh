#!/usr/bin/env bash
set -o pipefail

pip3 list | grep -e neuron > run_installed_neuron_pkgs.txt
#apt list | grep neuron >> run_installed_neuron_pkgs.txt

export NEURON_RT_EXEC_TIMEOUT=600
export NEURON_RT_STOCHASTIC_ROUNDING_SEED=0
export TF_GRPC_DEFAULT_OPTIONS=grpc.keepalive_time_ms=60000,grpc.keepalive_timeout_ms=14400000,grpc.http2.max_pings_without_data=0,grpc.http2.min_ping_interval_without_data_ms=600000

IMDS_TOKEN=`curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"`
INSTANCEID=`curl -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" -v http://169.254.169.254/latest/meta-data/instance-id`
WORLD_SIZE_JOB=1
RANK_NODE=0
MAX_STEPS=7032
BATCH_SIZE=16
GRAD_ACCUM_USTEPS=128 #keep the GBS=64k to benchmark over GPU
NUM_NEURONCORES=32
DISTRIBUTED_ARGS="--nproc_per_node $NUM_NEURONCORES"
OUTPUT_DIR=output
OPT=LAMB
LOG_FILE=log_ph1_bf16
if [ ! -z "$NEURON_EXTRACT_GRAPHS_ONLY" ]; then
   LOG_FILE=${LOG_FILE}_compile
fi

if [ ! -z "$SLURM_NTASKS" ]; then
    export FI_EFA_USE_DEVICE_RDMA=1
    export FI_PROVIDER=efa
    export FI_EFA_FORK_SAFE=1
    export BUCKET_CAP_MB=512
    export XLA_TRANSFER_SEED_ASYNC=1
    WORLD_SIZE_JOB=$SLURM_NTASKS
    RANK_NODE=$SLURM_NODEID
    MASTER_ADDR=(`scontrol show hostnames $SLURM_JOB_NODELIST`)
    MASTER_PORT=2022
    GRAD_ACCUM_USTEPS=$(($GRAD_ACCUM_USTEPS/$WORLD_SIZE_JOB))
    DISTRIBUTED_ARGS="--nproc_per_node $NUM_NEURONCORES --nnodes $WORLD_SIZE_JOB --node_rank $RANK_NODE --master_addr $MASTER_ADDR --master_port $MASTER_PORT"
    echo $DISTRIBUTED_ARGS
    OUTPUT_DIR=output_$SLURM_JOB_ID
    LOG_FILE=${LOG_FILE}_${RANK_NODE}_${WORLD_SIZE_JOB}
    CACHE_DIR=$HOME/neuron_cache/bert/`hostname`
    export NEURON_CC_FLAGS="--cache_dir=$CACHE_DIR"
    export TRANSFORMERS_CACHE=$HOME/hf_cache/`hostname`/hub
    # HF ver > 4.22: Move cache ahead of time to prevent multiple workers moving at the same time
    python -c "import transformers.utils as utils; utils.move_cache()"
fi

HOST=`hostname`
echo "Hostname: $HOST (instance ID: $INSTANCEID)"

steps_this_run=$MAX_STEPS
if [ ! -z "$NEURON_EXTRACT_GRAPHS_ONLY" ]; then
    steps_this_run=5
fi

update_test_variables=../../load_test_variables.sh
if [ -e $update_test_variables ]; then
    . ./$update_test_variables $@ || echo "Unable to find test env."
fi
mkdir -p $OUTPUT_DIR
if [ -z "$json" ]; then json="$OUTPUT_DIR/results.json" && rm -f $json; fi

sudo sysctl -w net.ipv4.ip_local_reserved_ports=48620 || exit 1
XLA_DOWNCAST_BF16=1 torchrun $DISTRIBUTED_ARGS dp_bert_large_hf_pretrain_hdf5.py --optimizer $OPT --lr 6e-3 --output_dir $OUTPUT_DIR --max_steps $MAX_STEPS --steps_this_run $steps_this_run --metrics_file $json --batch_size=$BATCH_SIZE --grad_accum_usteps=$GRAD_ACCUM_USTEPS |& tee $OUTPUT_DIR/$LOG_FILE &
wait %1

ret_val=$?
if [ $ret_val -eq 0 ]; then
    success=1
else
    success=0
fi

if [ -z "$NEURON_EXTRACT_GRAPHS_ONLY" ]; then
    dump_to_s3_update_json_scr=../../dump_to_s3_update_test_json.sh
    if [ -e $dump_to_s3_update_json_scr ]; then
        $dump_to_s3_update_json_scr $@ --key=inference_success --value=$success || echo "Unable to update test result JSON."
    else
        echo "WARNING: Script $dump_to_s3_update_json_scr not found. Not updating test result JSON."
    fi
fi

# copy final checkpoint for ph2
if [ -e $OUTPUT_DIR/ckpt_$MAX_STEPS.pt ]; then cp -f $OUTPUT_DIR/ckpt_$MAX_STEPS.pt ../; fi

exit $ret_val