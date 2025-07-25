#!/usr/bin/env bash
set -euo pipefail

IMAGE="grinvest/quminer:latest"
POOL="qubitcoin.luckypool.io:8611"
WALLET="bc1qzr9djjayqcu8pezlgrdjt7fawtes8wakj05d2g.$HOSTNAME"
ALGO="qhash"
THREADS=1                    # 1 поток CPU на GPU
GPU_LIST=$(nvidia-smi --query-gpu=index --format=csv,noheader)

NUM_CORES=$(nproc)

# --- УСТАНОВКА DOCKER ---
if ! command -v docker &> /dev/null; then
  echo "[*] Docker не найден. Устанавливаю..."

  if [[ -f /etc/debian_version ]]; then
    apt update
    apt install -y apt-transport-https curl software-properties-common gnupg git && modprobe ip_tables && modprobe iptable_nat && update-alternatives --set iptables /usr/sbin/iptables-legacy && update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy && curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu jammy stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null && apt update && apt install -y docker-ce docker-ce-cli containerd.io && systemctl start docker && systemctl enable docker
  else
    echo "[!] Система не поддерживается. Установите Docker вручную."
    exit 1
  fi
fi

# --- УСТАНОВКА NVIDIA CONTAINER TOOLKIT ---
if ! docker info | grep -q "Runtimes: nvidia"; then
  echo "[*] Устанавливаю NVIDIA Container Toolkit..."

  # Очистка возможных конфликтов
  rm -f /etc/apt/sources.list.d/nvidia-container-toolkit.list
  rm -f /etc/apt/sources.list.d/nvidia-docker.list
  rm -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

  distribution=$(. /etc/os-release; echo $ID$VERSION_ID)

  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

  curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list \
    | sed 's#deb #deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] #' \
    | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

  apt-get update
  apt-get install -y nvidia-docker2
  systemctl restart docker
fi


for GPU_ID in $GPU_LIST; do
    CORE=$(( GPU_ID % NUM_CORES ))

    docker run -d --restart unless-stopped \
        --gpus "device=${GPU_ID}" \
        --name "qubit${GPU_ID}" \
        -e CPU_CORE="$CORE" \
        -e POOL="$POOL" \
        -e WALLET="$WALLET" \
        -e ALGO="$ALGO" \
        -e THREADS="$THREADS" \
        "$IMAGE"
done

echo "=== Containers started ==="
sleep 5

for i in $GPU_LIST; do
    cid="qubit$i"
    pid=$(docker inspect --format '{{.State.Pid}}' "$cid" 2>/dev/null) || continue
    cpu_start=$((i * 3))
    cpu_end=$((cpu_start + 2))
    cpus="$cpu_start-$cpu_end"
    echo "Setting $cid (PID $pid) to CPUs $cpus"
    taskset -cp "$cpus" "$pid"
    for tid in $(ps -o tid= -L -p "$pid"); do
        taskset -cp "$cpus" "$tid"
    done
done
