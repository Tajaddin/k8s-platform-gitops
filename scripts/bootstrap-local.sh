#!/usr/bin/env bash
# Local platform from zero: a k3d cluster (k3s in Docker) with the search data mounted, a git daemon that
# serves this repository to the cluster (so GitOps works without pushing anywhere), Argo CD, and the root
# application. After this, every change is a commit pushed to the local remote and a sync.
#   scripts/bootstrap-local.sh
#   scripts/bootstrap-local.sh push      # only push the current main to the local git daemon (after a commit)
set -euo pipefail
cd "$(dirname "$0")/.."
CLUSTER="${CLUSTER:-portfolio}"
ARGOCD_VERSION="${ARGOCD_VERSION:-8.3.0}"           # chart version (Argo CD 3.1)
HSS_DATA="${HSS_DATA:-G:/Github Projects/hybrid-search-service/data}"
GIT_DIR="${GIT_DIR:-$PWD/data/git}"

push_local() {
  mkdir -p "$GIT_DIR"
  [ -d "$GIT_DIR/k8s-platform-gitops.git" ] || git init --bare -q "$GIT_DIR/k8s-platform-gitops.git"
  if ! docker ps --format '{{.Names}}' | grep -q '^gitops-daemon$'; then
    docker rm -f gitops-daemon >/dev/null 2>&1 || true
    # alpine/git lacks git-daemon; a plain Alpine with the two packages is the smallest image that has it
    MSYS_NO_PATHCONV=1 docker run -d --name gitops-daemon -p 9418:9418 -v "$GIT_DIR:/repos" alpine:3.21 \
      sh -c "apk add --no-cache git git-daemon >/dev/null && exec git daemon --base-path=/repos --export-all --reuseaddr --verbose --enable=receive-pack" >/dev/null
  fi
  git remote get-url local >/dev/null 2>&1 || git remote add local "$GIT_DIR/k8s-platform-gitops.git"
  git -c user.name="Tajaddin Gafarov" -c user.email="gafarovtajaddin@gmail.com" push -q local HEAD:main --force
  echo "pushed $(git rev-parse --short HEAD) to the local git daemon (git://host.k3d.internal:9418/k8s-platform-gitops.git)"
}

if [ "${1:-}" = "push" ]; then push_local; exit 0; fi

if ! k3d cluster list 2>/dev/null | grep -q "^$CLUSTER "; then
  echo "== k3d cluster $CLUSTER"
  k3d cluster create "$CLUSTER" --servers 1 --agents 1 --api-port 127.0.0.1:6550 \
    -p "8180:80@loadbalancer" -p "8443:443@loadbalancer" \
    --k3s-arg "--disable=traefik@server:0" \
    --volume "$HSS_DATA/prepared:/mnt/hss-prepared@all" \
    --volume "$HSS_DATA/models:/mnt/hss-models@all" --wait
fi
kubectl config use-context "k3d-$CLUSTER" >/dev/null
# OpenSearch needs vm.max_map_count >= 262144 on the node; pod-security baseline forbids a privileged init container,
# so it is a node setting (cloud-init on OCI). Docker Desktop's VM already ships 1048576; fail loudly if not.
MMC=$(docker exec "k3d-$CLUSTER-agent-0" sysctl -n vm.max_map_count)
[ "$MMC" -ge 262144 ] || { echo "vm.max_map_count=$MMC on the node; raise it in the Docker VM (sysctl -w vm.max_map_count=262144)"; exit 1; }

echo "== local images into the cluster (built by the P6 and P8 repos)"
for img in dfp/api:local hss/api:local hss/ui:local; do
  if docker image inspect "$img" >/dev/null 2>&1; then k3d image import "$img" -c "$CLUSTER" >/dev/null && echo "imported $img"; else echo "missing $img (build it in its repo)"; fi
done

echo "== this repository, served to the cluster"
push_local

echo "== Argo CD"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install argocd argo/argo-cd --version "$ARGOCD_VERSION" -n argocd --create-namespace \
  -f platform/argocd/values.yaml --wait --timeout 10m
kubectl -n argocd rollout status deploy/argocd-server --timeout=5m

echo "== root application (app of apps) for env local"
sed "s#__REPO_URL__#git://host.k3d.internal:9418/k8s-platform-gitops.git#g; s#__ENV__#local#g" platform/argocd/root-app.yaml | kubectl apply -f -

echo
echo "Argo CD UI: kubectl -n argocd port-forward svc/argocd-server 8081:80  (user admin)"
echo "password:   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo "Ingress:    https://search.localtest.me:8443, https://forecast.localtest.me:8443, https://grafana.localtest.me:8443 (platform CA, so the browser warns; http on 8180 redirects)"
