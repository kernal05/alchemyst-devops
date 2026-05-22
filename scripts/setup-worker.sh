#!/usr/bin/env bash
# setup-worker.sh — runs on inference VM at first boot
# Template variables: worker_dir, iii_engine_ip
set -euo pipefail

WORKER_DIR="${worker_dir}"
III_ENGINE_IP="${iii_engine_ip}"

# ── Install Docker ────────────────────────────────────────────────────────────
apt-get update -qq
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# ── Clone repo ─────────────────────────────────────────────────────────────────
git clone https://github.com/YOUR_ORG/alchemyst-devops.git /opt/iii
cd /opt/iii

# ── Build and run just the inference worker ────────────────────────────────────
docker build -t inference-worker ./workers/inference-worker
docker run -d \
  --name inference-worker \
  --restart unless-stopped \
  -e III_URL="ws://$III_ENGINE_IP:49134" \
  --memory=8g \
  --cpus=4 \
  inference-worker

echo "Inference worker started, connected to iii-engine at $III_ENGINE_IP"
