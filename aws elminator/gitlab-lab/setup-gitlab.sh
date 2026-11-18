#!/usr/bin/env bash
# Bootstraps the whole CI lab in one go:
#   1. GitLab CE + Runner containers (joined to floci-net)
#   2. root access token, instance runner (docker executor)
#   3. group "floci-lab" with projects floci-infra and floci-app, code pushed
# Re-runnable: skips what already exists.
set -euo pipefail
cd "$(dirname "$0")"
LAB_DIR=$(pwd)

c_info() { echo -e "\033[36m>> $*\033[0m"; }
c_ok()   { echo -e "\033[32m✔ $*\033[0m"; }
die()    { echo -e "\033[31m✘ $*\033[0m"; exit 1; }

command -v docker >/dev/null || die "docker not found"
command -v git >/dev/null    || sudo apt-get install -y -qq git
command -v curl >/dev/null   || sudo apt-get install -y -qq curl
command -v python3 >/dev/null || die "python3 not found"

# ---------- .env (VM IP + root password, generated once) ----------
if [ ! -f .env ]; then
  VM_IP=$(hostname -I | awk '{print $1}')
  PASS="Lab-$(openssl rand -hex 7)"
  printf 'VM_IP=%s\nGITLAB_ROOT_PASSWORD=%s\n' "$VM_IP" "$PASS" > .env
  chmod 600 .env
fi
set -a; . ./.env; set +a
CUR_IP=$(hostname -I | awk '{print $1}')
[ "$CUR_IP" = "$VM_IP" ] || echo -e "\033[33m!! VM IP changed ($VM_IP -> $CUR_IP). Edit VM_IP in gitlab-lab/.env and run: docker compose up -d\033[0m"
GL="http://localhost:8929"

# ---------- Floci + network ----------
if ! docker network inspect floci-net >/dev/null 2>&1; then
  c_info "Starting Floci first (creates floci-net)"
  (cd .. && docker compose up -d)
fi

# ---------- GitLab ----------
c_info "Starting GitLab CE + Runner (first start takes 3-6 minutes)"
docker compose up -d
printf "   waiting for GitLab"
for i in $(seq 1 180); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$GL/users/sign_in" || true)
  [ "$code" = 200 ] && break
  printf "."; sleep 5
done; echo
[ "$code" = 200 ] || die "GitLab did not come up. Check: docker logs gitlab --tail 50"
c_ok "GitLab is up at http://$VM_IP:8929"

# ---------- root personal access token ----------
if [ ! -s .root-token ]; then
  c_info "Creating root API token (takes ~1 min)"
  TOKEN="glpat-lab$(openssl rand -hex 10)"
  docker exec gitlab gitlab-rails runner "
    u = User.find_by_username('root')
    t = u.personal_access_tokens.create!(scopes: ['api','write_repository'], name: 'lab-bootstrap', expires_at: 365.days.from_now)
    t.set_token('$TOKEN'); t.save!
  " >/dev/null
  echo "$TOKEN" > .root-token; chmod 600 .root-token
fi
TOKEN=$(cat .root-token)
api() { curl -sf -H "PRIVATE-TOKEN: $TOKEN" "$@"; }
api "$GL/api/v4/user" >/dev/null || die "Token rejected. Delete gitlab-lab/.root-token and re-run."
c_ok "API token ready"

# ---------- instance runner ----------
if ! docker exec gitlab-runner grep -q '^\[\[runners\]\]' /etc/gitlab-runner/config.toml 2>/dev/null; then
  c_info "Registering instance runner (docker executor on floci-net)"
  RTOKEN=$(api -X POST "$GL/api/v4/user/runners" \
    --data "runner_type=instance_type" --data "description=floci-lab-runner" \
    --data "tag_list=docker,floci" --data "run_untagged=true" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])')
  docker exec gitlab-runner gitlab-runner register --non-interactive \
    --url "http://gitlab:8929" --clone-url "http://gitlab:8929" --token "$RTOKEN" \
    --executor docker --docker-image "alpine:3.20" \
    --docker-network-mode floci-net --docker-pull-policy if-not-present \
    --docker-volumes /cache >/dev/null
  docker exec gitlab-runner sed -i 's/^concurrent = .*/concurrent = 2/' /etc/gitlab-runner/config.toml
  docker restart gitlab-runner >/dev/null
fi
c_ok "Runner registered"

# ---------- group + projects ----------
GID=$(api "$GL/api/v4/groups/floci-lab" 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])' 2>/dev/null || true)
if [ -z "$GID" ]; then
  GID=$(api -X POST "$GL/api/v4/groups" --data "name=floci-lab" --data "path=floci-lab" --data "visibility=private" \
        | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
fi
c_ok "Group floci-lab (id $GID)"

push_project() {
  local name=$1 src="$LAB_DIR/projects/$1" pushopt=${2:-}
  if ! api "$GL/api/v4/projects/floci-lab%2F$name" >/dev/null 2>&1; then
    api -X POST "$GL/api/v4/projects" --data "name=$name" --data "namespace_id=$GID" \
        --data "initialize_with_readme=false" --data "visibility=private" >/dev/null
    c_info "Created project $name"
  fi
  local tmp; tmp=$(mktemp -d)
  cp -a "$src/." "$tmp/"
  ( cd "$tmp"
    git init -q -b main
    git -c user.name="Lab Admin" -c user.email="admin@lab.local" add -A
    git -c user.name="Lab Admin" -c user.email="admin@lab.local" commit -qm "Initial commit from setup-gitlab.sh"
    git push -q -f $pushopt "http://root:${TOKEN}@localhost:8929/floci-lab/$name.git" main 2>&1 | grep -v '^remote:' || true )
  rm -rf "$tmp"
  c_ok "Pushed $name -> http://$VM_IP:8929/floci-lab/$name"
}

# App first WITHOUT a pipeline (-o ci.skip): it needs the infra to exist.
# The infra pipeline triggers the app pipeline after apply + verify.
push_project floci-app "-o ci.skip"
push_project floci-infra

cat <<EOF

=====================================================================
 GitLab:   http://$VM_IP:8929        user: root   password: $GITLAB_ROOT_PASSWORD
 Projects: http://$VM_IP:8929/floci-lab
 Floci:    http://$VM_IP:4566        Console: http://$VM_IP:4500
=====================================================================
Next:
 1. Open floci-infra -> Build -> Pipelines. Pushing started a pipeline.
 2. When 'plan' finishes, press ▶ on 'apply' (manual approval gate).
 3. After 'verify' passes, it triggers floci-app's pipeline automatically.
 4. Watch floci-app: unit tests -> build -> deploy -> integration tests.
 5. See the resources in the Floci console.
EOF
