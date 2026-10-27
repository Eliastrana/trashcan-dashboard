#!/bin/sh
# The login screen of a guest VM: the logo, then what this machine has and what is free right now.
cat /etc/trashcan-art.txt
row() { printf '  \033[1;38;5;51m%-10s\033[0m %s\n' "$1" "$2"; }

model=$(lscpu | sed -n 's/^Model name:[[:space:]]*//p' | head -1 | sed 's/(R)//g; s/(TM)//g; s/  */ /g')
cores=$(nproc)
mem_total=$(free -m | awk '/^Mem:/ {printf "%.1f GB", $2/1024}')
mem_free=$(free -m | awk '/^Mem:/ {printf "%.1f GB", $7/1024}')
disk_total=$(df -BM --output=size / | awk 'NR==2 {gsub("M","",$1); printf "%.0f GB", $1/1024}')
disk_free=$(df -BM --output=avail / | awk 'NR==2 {gsub("M","",$1); printf "%.0f GB", $1/1024}')

printf '\n'
row CPU    "$cores cores  ·  $model"
row Memory "$mem_total total  ·  $mem_free free"
row Disk   "$disk_total total  ·  $disk_free free"
row GPU    "none  ·  this cluster runs CPU jobs only"
printf '\n'
