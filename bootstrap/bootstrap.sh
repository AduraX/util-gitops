#!/usr/bin/env bash
# =============================================================================
# util-gitops bootstrap script
#
# Assumes infrastructure (CNI, MetalLB, cert-manager, Traefik) is already
# installed by kind_Run.sh or rke2ClusterInstall.sh.
#
# This script only installs:
#   1. ArgoCD
#   2. CNPG operator + Gitea database
#   3. Gitea (for hosting this gitops repo)
#   4. Pushes this repo to Gitea
#   5. Activates App of Apps — ArgoCD manages everything else
#
# Usage:
#   ./bootstrap.sh                                         # All services
#   ./bootstrap.sh --services storage,identity,devtools    # Selected groups
#
# Service groups:
#   storage    — CNPG, MinIO
#   identity   — Keycloak, OpenLDAP, OpenBao/Vault
#   devtools   — Gitea, Gitea runner/ARC, VSCodium
#   monitoring — kube-prometheus-stack, Velero
#   ai         — Ollama, Open WebUI
#   rancher    — Rancher
#   forge4x    — Forge4X root
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# Load config
if [[ -f "$SCRIPT_DIR/config.env" ]]; then
  set -a; source "$SCRIPT_DIR/config.env"; set +a
else
  echo "ERROR: config.env not found. Copy config.env.example to config.env and configure."
  exit 1
fi

# Parse arguments
SERVICES="all"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --services) SERVICES="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

DOMAIN="${DOMAIN:-gitops.lcl}"

log() { echo "[$(date +"%H:%M:%S")] $1"; }

wait_ready() {
  local ns="$1" label="$2" timeout="${3:-120}"
  log "Waiting for pods with label ${label} in ${ns}..."
  kubectl wait --timeout="${timeout}s" --for=condition=ready pods -l "$label" -n "$ns" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Service group management
# ---------------------------------------------------------------------------
declare -A SERVICE_GROUPS
SERVICE_GROUPS=(
  [storage]="ug-cnpg.yaml ug-cnpg-clusters.yaml ug-minio.yaml"
  [identity]="ug-keycloak.yaml ug-openldap.yaml ug-openbao.yaml"
  [devtools]="ug-gitea.yaml ug-gitea-runner.yaml ug-vscodium.yaml"
  [monitoring]="ug-monitoring.yaml ug-velero.yaml"
  [ai]="ug-ollama.yaml ug-open-webui.yaml"
  [rancher]="ug-rancher.yaml"
  [forge4x]="ug-forge4x-root.yaml"
)

APPS_DIR="${REPO_DIR}/argocd/apps"
AVAILABLE_DIR="${REPO_DIR}/argocd/available"

activate_services() {
  local selected="$1"
  mkdir -p "$AVAILABLE_DIR"

  if [[ "$selected" == "all" ]]; then
    for f in "$AVAILABLE_DIR"/ug-*.yaml; do
      [[ -f "$f" ]] && mv "$f" "$APPS_DIR/"
    done
    return
  fi

  # Move all non-core group apps to available/
  for group in "${!SERVICE_GROUPS[@]}"; do
    for app in ${SERVICE_GROUPS[$group]}; do
      [[ -f "$APPS_DIR/$app" ]] && mv "$APPS_DIR/$app" "$AVAILABLE_DIR/"
    done
  done

  # Move selected groups back to apps/
  IFS=',' read -ra SELECTED <<< "$selected"
  for group in "${SELECTED[@]}"; do
    group=$(echo "$group" | tr -d ' ')
    if [[ -z "${SERVICE_GROUPS[$group]+x}" ]]; then
      log "WARNING: Unknown service group '${group}' — skipping"
      continue
    fi
    for app in ${SERVICE_GROUPS[$group]}; do
      [[ -f "$AVAILABLE_DIR/$app" ]] && mv "$AVAILABLE_DIR/$app" "$APPS_DIR/"
    done
  done

  log "Active service groups: ${selected}"
  log "Active apps:"
  ls "$APPS_DIR"/ug-*.yaml 2>/dev/null | xargs -n1 basename | sed 's/^/  /'
}

# =============================================================================
# Pre-flight checks
# =============================================================================
log "=== Pre-flight checks ==="

# Verify cluster is accessible
if ! kubectl cluster-info &>/dev/null; then
  echo "ERROR: Cannot connect to Kubernetes cluster. Run kind_Run.sh first."
  exit 1
fi

# Verify infra is running
for component in cilium traefik cert-manager; do
  if ! kubectl get pods -A -l "app.kubernetes.io/name=${component}" 2>/dev/null | grep -q Running; then
    log "WARNING: ${component} not found or not running"
  fi
done
log "Cluster is ready."

# =============================================================================
# Phase 1: ArgoCD
# =============================================================================
log "=== Phase 1: ArgoCD ==="

if ! helm status argocd -n argocd &>/dev/null; then
  log "Installing ArgoCD..."
  helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
  helm repo update
  kubectl create namespace argocd 2>/dev/null || true
  helm install argocd argo/argo-cd -n argocd \
    -f "${REPO_DIR}/argocd/values/argocd-values.yaml"
  wait_ready argocd "app.kubernetes.io/name=argocd-server" 180

  ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" 2>/dev/null | base64 -d)
  log "ArgoCD ready — admin password: ${ARGOCD_PASS}"
else
  log "ArgoCD already installed, skipping."
fi

# =============================================================================
# Phase 2: CNPG + Gitea
# =============================================================================
log "=== Phase 2: CNPG + Gitea ==="

# Install CNPG operator
if ! helm status cnpg -n cnpg-system &>/dev/null; then
  log "Installing CNPG operator..."
  helm repo add cnpg https://cloudnative-pg.github.io/charts 2>/dev/null || true
  helm repo update
  kubectl create namespace cnpg-system 2>/dev/null || true
  helm install cnpg cnpg/cloudnative-pg -n cnpg-system
  wait_ready cnpg-system "app.kubernetes.io/name=cloudnative-pg" 120
else
  log "CNPG already installed, skipping."
fi

# Create Gitea database
kubectl create namespace storage 2>/dev/null || true
kubectl create secret generic gitea-db-credentials -n storage \
  --from-literal=username=gitea \
  --from-literal=password="${GITEA_DB_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${REPO_DIR}/platform/storage/cnpg/clusters/gitea-db.yaml"
log "Waiting for Gitea database cluster..."
for i in $(seq 1 60); do
  if kubectl get cluster gitea-db -n storage -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then
    log "Gitea database ready."
    break
  fi
  sleep 5
done

# Sync the DB password (CNPG may have set a different one)
kubectl exec -n storage gitea-db-1 -- psql -U postgres \
  -c "ALTER USER gitea WITH PASSWORD '${GITEA_DB_PASSWORD}';" 2>/dev/null || true

# Install Gitea
if ! helm status gitea -n devtools &>/dev/null; then
  log "Installing Gitea..."
  helm repo add gitea https://dl.gitea.com/charts/ 2>/dev/null || true
  helm repo update
  kubectl create namespace devtools 2>/dev/null || true
  helm install gitea gitea/gitea -n devtools \
    -f "${REPO_DIR}/platform/devtools/gitea/values.yaml" \
    --set gitea.admin.password="${GITEA_ADMIN_PASSWORD}" \
    --set gitea.config.database.PASSWD="${GITEA_DB_PASSWORD}"
  wait_ready devtools "app.kubernetes.io/name=gitea" 300
else
  log "Gitea already installed, skipping."
fi

# =============================================================================
# Phase 3: Push gitops repo to Gitea + activate ArgoCD
# =============================================================================
log "=== Phase 3: Activate GitOps ==="

# Port-forward to Gitea
log "Setting up port-forward to Gitea..."
kubectl -n devtools port-forward svc/gitea-http 3000:3000 &>/dev/null &
PF_PID=$!
sleep 3

GITEA_LOCAL="http://localhost:3000"
log "Waiting for Gitea API..."
for i in $(seq 1 30); do
  if curl -s "${GITEA_LOCAL}/api/v1/version" &>/dev/null; then break; fi
  sleep 3
done

# Detect Gitea admin username
GITEA_ACTUAL_USER=$(kubectl exec -n devtools deploy/gitea -- \
  gitea admin user list --admin 2>/dev/null | awk 'NR==2{print $2}')
GITEA_ACTUAL_USER="${GITEA_ACTUAL_USER:-${GITEA_ADMIN_USER}}"
log "Gitea admin user: ${GITEA_ACTUAL_USER}"

# Create repo in Gitea
log "Creating util-gitops repo in Gitea..."
curl -s -X POST "${GITEA_LOCAL}/api/v1/user/repos" \
  -H "Content-Type: application/json" \
  -u "${GITEA_ACTUAL_USER}:${GITEA_ADMIN_PASSWORD}" \
  -d '{"name":"util-gitops","auto_init":false,"private":false}' || true

# Activate selected service groups
log "Activating service groups: ${SERVICES}"
activate_services "$SERVICES"

# Commit and push
cd "$REPO_DIR"
git add -A 2>/dev/null || true
git commit -m "Activate services: ${SERVICES}" 2>/dev/null || true

GITEA_PUSH_URL="http://${GITEA_ACTUAL_USER}:${GITEA_ADMIN_PASSWORD}@localhost:3000/${GITEA_ACTUAL_USER}/util-gitops.git"
git remote remove gitea 2>/dev/null || true
git remote add gitea "$GITEA_PUSH_URL"
git push -u gitea main 2>/dev/null || git push gitea main

# Set remote to internal URL (for ArgoCD refs)
GITEA_INTERNAL="http://gitea-http.devtools.svc.cluster.local:3000"
git remote set-url gitea "${GITEA_INTERNAL}/${GITEA_ACTUAL_USER}/util-gitops.git"

# Register repo with ArgoCD (using internal URL)
log "Registering repo with ArgoCD..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: gitea-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  url: ${GITEA_INTERNAL}/${GITEA_ACTUAL_USER}/util-gitops.git
  username: ${GITEA_ACTUAL_USER}
  password: ${GITEA_ADMIN_PASSWORD}
  insecure: "true"
  type: git
EOF

# Clean up port-forward
kill $PF_PID 2>/dev/null || true

# Apply ArgoCD projects
log "Applying ArgoCD projects..."
kubectl apply -f "${REPO_DIR}/argocd/projects/"

# Apply root Application
log "Applying root Application (App of Apps)..."
kubectl apply -f "${REPO_DIR}/argocd/apps/ug-root.yaml"

# Patch root app to use internal Gitea URL
kubectl patch app ug-root -n argocd --type json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/source/repoURL\",\"value\":\"${GITEA_INTERNAL}/${GITEA_ACTUAL_USER}/util-gitops.git\"}]" 2>/dev/null || true

# =============================================================================
# Done
# =============================================================================
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "unknown")

log ""
log "=== Bootstrap complete ==="
log "ArgoCD UI:  kubectl port-forward svc/argocd-server -n argocd 8080:443"
log "            then open http://localhost:8080"
log "ArgoCD password: ${ARGOCD_PASS}"
log "Gitea:      https://gitea.${DOMAIN}"
log ""
log "Active service groups: ${SERVICES}"
log "ArgoCD will now discover and sync all child applications."
log "Monitor progress: kubectl get applications -n argocd"
log ""
log "To add/remove services later:"
log "  mv argocd/available/ug-<service>.yaml argocd/apps/    # activate"
log "  mv argocd/apps/ug-<service>.yaml argocd/available/    # deactivate"
log "  git add -A && git commit -m 'Update services' && git push gitea main"
