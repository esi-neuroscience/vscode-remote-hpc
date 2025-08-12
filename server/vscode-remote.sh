#!/usr/bin/env bash
#
# Script for connecting to SLURMed VS Code Remote sessions
#
# Copyright © 2025 Ernst Strüngmann Institute (ESI) for Neuroscience
# in Cooperation with Max Planck Society
# Copyright © 2025  Gert Mertes
#
# SPDX-License-Identifier: MIT
#

TIMEOUT=300
if [[ "${HOSTNAME}" == "esi-sv"* ]]; then
    SBATCH_DEFAULTS="-p 8GBL"
elif [[ "${HOSTNAME}" == "bic-sv"* ]]; then
    SBATCH_DEFAULTS="-p 8GBSx86 -c 1 --mem-per-cpu 7500MB"
else
    echo "WARNING: Unknown HPC environment ${HOSTNAME} - falling back to SLURM defaults"
    SBATCH_DEFAULTS="-q ni -t 12:00:00 --mem=32G -c 8"
fi

function usage ()
{
    echo "Usage : $0 [command]

    General commands:
    list      List running vscode-remote jobs
    cancel    Cancels running vscode-remote jobs
    help      Display this message

    Job command (see usage below):
    connect   Connect to compute node

    You should _NOT_ manually call the script with 'connect'.
    They should be used in the ProxyCommand in your ~/.ssh/config file, for example:
        Host vscode-remote
            User <username>
            IdentityFile ~/.ssh/vscode-remote
            ProxyCommand ssh <headnode> \"~/bin/vscode-remote connect\"
            StrictHostKeyChecking no  

    "
} 

function query_slurm () {
    # only list states that can result in a running job
    list=($(/usr/bin/squeue --me --states=R,PD,S,CF,RF,RH,RQ -h -O JobId:" ",Name:" ",State:" ",NodeList:" " | grep $JOB_NAME))

    if [ ! ${#list[@]} -eq 0 ]; then
        JOB_ID=${list[0]}
        JOB_FULLNAME=${list[1]}
        JOB_STATE=${list[2]}
        JOB_NODE=${list[3]}

        split=(${JOB_FULLNAME//%/ })
        JOB_PORT=${split[1]}

        >&2 echo "Job is $JOB_STATE ( id: $JOB_ID, name: $JOB_FULLNAME${JOB_NODE:+, node: $JOB_NODE} )" 
    else
        JOB_ID=""
        JOB_FULLNAME=""
        JOB_STATE=""
        JOB_NODE=""
        JOB_PORT=""
    fi
}

function cleanup () {
    if [ ! -z "${JOB_SUBMIT_ID}" ]; then
        scancel $JOB_SUBMIT_ID
        >&2 echo "Cancelled pending job $JOB_SUBMIT_ID"
    fi
}

function timeout () {
    if (( $(date +%s)-START > TIMEOUT )); then 
        >&2 echo "Timeout, exiting..."
        cleanup
        exit 1
    fi
}

function cancel () {
    query_slurm > /dev/null 2>&1
    if [ -z "${JOB_ID}" ]; then
        echo "No running job found"
        return 0;
    fi
    while [ ! -z "${JOB_ID}" ]; do
        echo "Cancelling running job $JOB_ID on $JOB_NODE"
        scancel $JOB_ID
        timeout
        sleep 2
        query_slurm > /dev/null 2>&1
    done
}

function list () {
    width=$((${#JOB_NAME} + 11))
    echo "$(/usr/bin/squeue --me -O JobId,Partition,Name:$width,State,TimeUsed,TimeLimit,NodeList | grep -E "JOBID|$JOB_NAME")"
}

function start_slurm() {
    PORT=$(shuf -i 60001-63000 -n 1)
    list=($(/usr/bin/sbatch -J $JOB_NAME%$PORT $SBATCH_PARAM $SCRIPT_DIR/vscode-remote-job.sh $PORT))
    JOB_SUBMIT_ID=${list[3]}
    >&2 echo "Submitted new $JOB_NAME job (id: $JOB_SUBMIT_ID)"
}

function start() {
    query_slurm

    if [ ! -z "${JOB_STATE}" ]; then
        echo "A vscode-remote-hpc job is already running. Please run '$0 cancel' first"
        exit 1
    fi

    if [ ! -z "$1" ]; then
        SBATCH_PARAM="-p $1"
    else
        SBATCH_PARAM="${SBATCH_DEFAULTS}"
    fi
    echo "Starting job using sbatch parameters ${SBATCH_PARAM}"
    start_slurm
}

function connect () {
    query_slurm

    if [ -z "${JOB_STATE}" ]; then
        SBATCH_PARAM="${SBATCH_DEFAULTS}"
        start_slurm
    fi

    while [ ! "$JOB_STATE" == "RUNNING" ]; do
        timeout
        tstart=$SECONDS
        elapsed=0
        # Sleep 5 seconds (w/o spawning a subprocess)
        while [ "${elapsed}" -lt 5 ]; do
            elapsed=$((SECONDS - $tstart))
            >&2 echo -n "Waiting ${elapsed} seconds..."
            >&2 echo -e "\r\033[0K"
        done
        query_slurm
    done

    >&2 echo "Connecting to $JOB_NODE"

    while ! nc -z $JOB_NODE $JOB_PORT; do
        timeout
        tstart=$SECONDS
        elapsed=0
        # Sleep 1 second (w/o spawning a subprocess)
        while [ "${elapsed}" -lt 1 ]; do
            elapsed=$((SECONDS - $tstart))
            >&2 echo -n "Waiting ${elapsed} seconds..."
            >&2 echo -e "\r\033[0K"
        done
    done

    nc $JOB_NODE $JOB_PORT
}

if [ ! -z "$1" ]; then
    JOB_NAME=vscode-remote
    SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
    START=$(date +%s)
    trap "cleanup && exit 1" INT TERM
    case $1 in
        list)    list ;;
        cancel)  cancel ;;
        start)   start "$2" ;;
        connect) connect ;;
        help)    usage ;;
        *)  echo -e "Command '$1' does not exist" >&2
            usage; exit 1 ;;
    esac  
    exit 0
else
    usage
    exit 0
fi
