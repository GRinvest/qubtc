
#!/usr/bin/env bash
set -euo pipefail

IMAGE="grinvest/quminer:latest"
POOL="qubitcoin.luckypool.io:8611"
WALLET="bc1qzr9djjayqcu8pezlgrdjt7fawtes8wakj05d2g.$HOSTNAME"
ALGO="qhash"
THREADS=1
GPU_LIST=$(nvidia-smi --query-gpu=index --format=csv,noheader)
NUM_CORES=$(nproc)
MAX_CPU=$((NUM_CORES - 1))

DEBIAN_FRONTEND=noninteractive

pkg_install_debian() { apt-get update; apt-get install -y --no-install-recommends "$@"; }

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    if [[ -f /etc/debian_version || -f /etc/lsb-release ]]; then
      echo "[*] Устанавливаю Docker..."
      pkg_install_debian curl gnupg lsb-release apt-transport-https software-properties-common iptables git
      update-alternatives --set iptables /usr/sbin/iptables-legacy || true
      update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy || true
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release; echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
      apt-get update
      pkg_install_debian docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      systemctl enable --now docker
    else
      echo "[!] Сам ставь Docker — ОС не Debian/Ubuntu"; exit 1
    fi
  fi
  timeout 20 bash -c 'until docker info >/dev/null 2>&1; do sleep 1; done' || { echo "[!] Docker не поднялся"; exit 1; }
}

ensure_nvidia_toolkit() {
  if ! docker info 2>/dev/null | grep -q "Runtimes:.*nvidia"; then
    echo "[*] Ставлю NVIDIA Container Toolkit..."
    pkg_install_debian curl gpg
    rm -f /etc/apt/sources.list.d/nvidia-container-toolkit.list /etc/apt/sources.list.d/nvidia-docker.list /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    distribution=$(. /etc/os-release; echo $ID$VERSION_ID)
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list \
      | sed 's#deb #deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] #' \
      > /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update
    pkg_install_debian nvidia-container-toolkit
    systemctl restart docker
  fi
}

pin_taskset_all_threads() {
  local pid="$1" cpus="$2"
  taskset -pc "$cpus" "$pid" >/dev/null 2>&1 || true
  for t in /proc/"$pid"/task/*; do
    tid=${t##*/}
    taskset -pc "$cpus" "$tid" >/dev/null 2>&1 || true
  done
}

wait_and_pin() {
  local cname="$1" cpus="$2" tries=30
  while (( tries-- > 0 )); do
    pid=$(docker inspect --format '{{.State.Pid}}' "$cname" 2>/dev/null || echo "")
    [[ -z "$pid" || "$pid" == "0" ]] && { sleep 1; continue; }
    [[ -d /proc/$pid/task ]] || { sleep 1; continue; }
    pin_taskset_all_threads "$pid" "$cpus"
    echo "[*] $cname → CPUs $cpus"
    return 0
  done
  echo "[!] Не удалось проставить affinity для $cname"
  return 1
}

# --- MAIN ---
ensure_docker
ensure_nvidia_toolkit

command -v taskset >/dev/null 2>&1 || pkg_install_debian util-linux
command -v nvidia-smi >/dev/null 2>&1 || { echo "[!] nvidia-smi нет"; exit 1; }

docker pull "$IMAGE"

for GPU_ID in $GPU_LIST; do
  CORE=$(( GPU_ID % NUM_CORES ))  # как у тебя было
  NAME="qubit${GPU_ID}"

  # Пересоздаём, если есть
  docker rm -f "$NAME" >/dev/null 2>&1 || true

  docker run --rm \
    --gpus "device=${GPU_ID}" \
    --name "$NAME" \
    -e CPU_CORE="$CORE" \
    -e POOL="$POOL" \
    -e WALLET="$WALLET" \
    -e ALGO="$ALGO" \
    -e THREADS="$THREADS" \
    "$IMAGE"
done

echo "=== Containers started ==="
sleep 5

# Три ядра на карту, как просил (i*3 ... i*3+2). Корректируем, если вылезаем за MAX_CPU.
for i in $GPU_LIST; do
  cid="qubit$i"
  cpu_start=$(( i * 3 ))
  cpu_end=$(( cpu_start + 2 ))

  if (( cpu_start > MAX_CPU )); then
    # если старт ушёл за предел — жёстко сдвигаем в конец
    cpu_start=$(( MAX_CPU - 2 ))
    (( cpu_start < 0 )) && cpu_start=0
    cpu_end=$MAX_CPU
  elif (( cpu_end > MAX_CPU )); then
    cpu_end=$MAX_CPU
  fi

  cpus="$cpu_start-$cpu_end"
  echo "[*] pin $cid → $cpus"
  wait_and_pin "$cid" "$cpus" || true
done

docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
echo "=== DONE ==="
