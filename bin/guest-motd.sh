#!/bin/sh
# The login screen of a guest VM: the logo, then what this machine has and what is free right now.
cat /etc/trashcan-art.txt
row() { printf '  \033[1;38;5;51m%-10s\033[0m %s\n' "$1" "$2"; }
dim() { printf '\033[38;5;245m%s\033[0m' "$1"; }

node=$(hostname)
model=$(lscpu | sed -n 's/^Model name:[[:space:]]*//p' | head -1 | sed 's/(R)//g; s/(TM)//g; s/  */ /g')
cores=$(nproc)
mem_total=$(free -m | awk '/^Mem:/ {printf "%.1f GB", $2/1024}')
mem_free=$(free -m | awk '/^Mem:/ {printf "%.1f GB", $7/1024}')
disk_total=$(df -BM --output=size / | awk 'NR==2 {gsub("M","",$1); printf "%.0f GB", $1/1024}')
disk_free=$(df -BM --output=avail / | awk 'NR==2 {gsub("M","",$1); printf "%.0f GB", $1/1024}')
os=$(. /etc/os-release && echo "$PRETTY_NAME")

if c=$(sinfo -h -p cpu -o '%C' 2>/dev/null) && [ -n "$c" ]; then
  rest=${c#*/}; idle=${rest%%/*}
  state=$(sinfo -h -p cpu -o '%t' | head -1)
  limit=$(sinfo -h -p cpu -o '%l' | head -1)
  running=$(squeue -h -t R 2>/dev/null | wc -l)
  waiting=$(squeue -h -t PD 2>/dev/null | wc -l)
  queue="$idle of $cores cores idle  ·  $running running, $waiting waiting  ·  time limit $limit"
  sched="Slurm $(sinfo -V | awk '{print $2}')  ·  partition cpu  ·  node state: $state"
else
  queue="the scheduler is still starting, give it a minute and log in again"
  sched="Slurm (starting)"
fi

printf '\n'
row Node     "$node"
row CPU      "$cores cores  ·  $model"
row Memory   "$mem_total total  ·  $mem_free free"
row Disk     "$disk_total total  ·  $disk_free free"
row GPU      "none  ·  this cluster runs CPU jobs only"
row OS       "$os  ·  $(uname -r)"
row Scheduler "$sched"
row Queue    "$queue"
printf '\n'
row Submit   "sbatch example-job.sh"
row Watch    "squeue  ·  sinfo  ·  scancel <job id>"
printf '\n'
