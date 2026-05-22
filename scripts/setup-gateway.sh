#!/usr/bin/env bash
# setup-gateway.sh — runs on the GCP gateway VM at first boot
# Installs: Docker, pulls iii engine image, starts iii-engine + caller-worker
set -euo pipefail

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

# ── Clone repo (replace with your actual repo URL) ────────────────────────────
git clone https://github.com/YOUR_ORG/alchemyst-devops.git /opt/iii
cd /opt/iii

# ── Start only the engine and caller-worker on the gateway VM ─────────────────
docker compose up -d iii-engine caller-worker

echo "Gateway setup complete. API available on :3111"
