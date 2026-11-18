#!/usr/bin/env bash
# Full reset: wipes all emulated AWS resources AND the side containers Floci spawned
# (Lambda runtimes, ECR registry, RDS, Redis, web console...), then starts fresh.
set -u
cd "$(dirname "$0")"

docker compose down
leftovers=$(docker ps -a --filter "name=floci-" -q)
[ -n "$leftovers" ] && docker rm -f $leftovers >/dev/null && echo "Removed $(echo "$leftovers" | wc -l) leftover Floci container(s)"
docker network rm floci-net >/dev/null 2>&1 || true
docker compose up -d

for i in $(seq 1 30); do curl -sf -o /dev/null http://localhost:4566/ && break; sleep 2; done
IP=$(hostname -I | awk '{print $1}')
echo
echo "Floci is fresh. Console: open http://$IP:4566 and click 'Open Floci UI' (then http://$IP:4500)"
