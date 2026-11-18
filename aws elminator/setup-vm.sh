#!/usr/bin/env bash
# One-shot prep for the Ubuntu VM: AWS CLI v2 + helpers, then start Floci.
set -euo pipefail
cd "$(dirname "$0")"

sudo apt-get update -qq
sudo apt-get install -y -qq unzip curl python3 >/dev/null

if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "$USER"
  echo ">> Docker installed. Log out/in (or run 'newgrp docker') and re-run this script."; exit 0
fi

if ! aws --version 2>/dev/null | grep -q 'aws-cli/2'; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  arch=$(uname -m)   # x86_64 or aarch64
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" -o "$tmp/awscliv2.zip"
  unzip -q "$tmp/awscliv2.zip" -d "$tmp"
  sudo "$tmp/aws/install" --update
fi
aws --version

docker compose up -d
echo ">> Waiting for Floci..."
for i in $(seq 1 30); do curl -sf -o /dev/null http://localhost:4566/ && break; sleep 2; done
docker ps --filter name=floci --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

IP=$(hostname -I | awk '{print $1}')
cat <<EOF

Floci is running.
  From this VM:      export AWS_ENDPOINT_URL=http://localhost:4566 AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1
  From Windows host: http://$IP:4566   (console, if the UI sidecar is running: http://$IP:4500)
Next:  ./test-all.sh        (add --heavy for RDS/Redis/OpenSearch/EKS/ECS tasks/EC2 instances)
EOF
