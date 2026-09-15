#!/usr/bin/env bash
# =============================================================================
# util-gitops bootstrap script
#
# Prerequisites:
#   - K8s cluster with CNI, MetalLB, cert-manager, Traefik (via kind_Run.sh)
#   - Gitea running in Docker (utilStack) at https://gitea.<domain>
#
# This script only installs:
#   1. ArgoCD on the K8s cluster
#   2. Registers the Gitea repo (Docker/external) with ArgoCD
#   3. Activates App of Apps — ArgoCD manages K8s workloads
#
# Usage:
#   ./bootstrap.sh                                 # All services
#   ./bootstrap.sh --services monitoring,ai        # Selected groups
#
# Service groups:
#   monitoring — kube-prometheus-stack, Velero
#   ai         — Ollama, Open WebUI
#   rancher    — Rancher
#   forge4x    — Forge4X root

#  kubectl create secret generic github-arc-token --namespace arc-runners  --from-literal=github_token='<your-PAT>'   
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
GITEA_DOMAIN="${GITEA_DOMAIN:-gitea.util.lcl}"
GITEA_URL="https://${GITEA_DOMAIN}"

_F4X_START_TIME=${_F4X_START_TIME:-$(date +%s)}
log()  { local _e=$(( $(date +%s) - _F4X_START_TIME )); tput setaf 2; echo "[$(date '+%H:%M:%S') +$((_e/60))m$((_e%60))s] $*"; tput sgr0 2>/dev/null; }
err()  { tput setaf 1; echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; tput sgr0 2>/dev/null; }
warn() { tput setaf 3; echo "[$(date '+%H:%M:%S')] WARN: $*"; tput sgr0 2>/dev/null; }
bold() { tput setaf 5 bold 2>/dev/null; echo "$*"; tput sgr0 2>/dev/null; }

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
      # Only move K8s workload apps, not Docker/infra services
      case "$(basename "$f")" in
        ug-monitoring*|ug-velero*|ug-ollama*|ug-open-webui*|ug-rancher*|ug-forge4x*)
          mv "$f" "$APPS_DIR/" ;;
      esac
    done
    return
  fi

  # Move all group apps to available/
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
}

# =============================================================================
# Pre-flight checks
# =============================================================================
log "=== Pre-flight checks ==="

if ! kubectl cluster-info &>/dev/null; then
  echo "ERROR: Cannot connect to K8s cluster. Run kind_Run.sh first."
  exit 1
fi
log "K8s cluster is accessible."

# Verify Gitea is reachable (Docker/utilStack)
log "Checking Gitea at ${GITEA_URL}..."
if ! curl -sk "${GITEA_URL}/api/v1/version" &>/dev/null; then
  log "WARNING: Gitea not reachable at ${GITEA_URL}"
  log "Make sure utilStack is running with Gitea deployed."
  log "Continuing anyway — ArgoCD will retry when Gitea is available."
fi

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
# Phase 2: Register Gitea repo + push + activate GitOps
# =============================================================================
log "=== Phase 2: Activate GitOps ==="

# Create/update repo in Gitea
log "Creating util-gitops repo in Gitea..."
GITEA_RESPONSE=$(curl -sk -w '\n%{http_code}' -X POST "${GITEA_URL}/api/v1/user/repos" \
  -H "Content-Type: application/json" \
  -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}" \
  -d '{"name":"util-gitops","auto_init":false,"private":false}')
GITEA_HTTP_CODE=$(echo "$GITEA_RESPONSE" | tail -1)
if [[ "$GITEA_HTTP_CODE" == "401" || "$GITEA_HTTP_CODE" == "403" ]]; then
  err "Gitea authentication failed (HTTP ${GITEA_HTTP_CODE}). Check GITEA_ADMIN_USER/GITEA_ADMIN_PASSWORD in config.env."
  exit 1
elif [[ "$GITEA_HTTP_CODE" == "409" ]]; then
  log "Gitea repo already exists, continuing."
elif [[ "$GITEA_HTTP_CODE" -ge 400 ]]; then
  err "Gitea repo creation failed (HTTP ${GITEA_HTTP_CODE}): $(echo "$GITEA_RESPONSE" | head -1)"
  exit 1
fi

# Activate selected service groups
log "Activating service groups: ${SERVICES}"
activate_services "$SERVICES"

# Update Gitea repo owner in all ArgoCD Application manifests
log "Setting Gitea repo owner to '${GITEA_ADMIN_USER}' in manifests..."
find "$REPO_DIR" -name '*.yaml' -exec \
  sed -i "s|${GITEA_DOMAIN}/[^/]*/util-gitops|${GITEA_DOMAIN}/${GITEA_ADMIN_USER}/util-gitops|g" {} +

# Commit and push
cd "$REPO_DIR"
git add -A 2>/dev/null || true
git commit -m "Activate services: ${SERVICES}" 2>/dev/null || true

GITEA_PUSH_URL="${GITEA_URL}/${GITEA_ADMIN_USER}/util-gitops.git"
git remote remove gitea 2>/dev/null || true
git remote add gitea "${GITEA_PUSH_URL}"
GIT_SSL_NO_VERIFY=1 git push -u gitea main 2>/dev/null || \
  GIT_SSL_NO_VERIFY=1 git push gitea main

# Register repo with ArgoCD
log "Registering Gitea repo with ArgoCD..."
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
  url: ${GITEA_URL}/${GITEA_ADMIN_USER}/util-gitops.git
  username: ${GITEA_ADMIN_USER}
  password: ${GITEA_ADMIN_PASSWORD}
  insecure: "true"
  type: git
EOF

# Apply ArgoCD projects
log "Applying ArgoCD projects..."
kubectl apply -f "${REPO_DIR}/argocd/projects/"

# Apply root Application
log "Applying root Application (App of Apps)..."
kubectl apply -f "${REPO_DIR}/argocd/apps/ug-root.yaml"

# =============================================================================
# Done
# =============================================================================
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "unknown")

log ""
bold "=== Bootstrap complete ==="
bold "ArgoCD UI:  https://argocd.${DOMAIN}"
log "            or: kubectl port-forward svc/argocd-server -n argocd 8080:443"
log "ArgoCD password: ${ARGOCD_PASS}"
log "Gitea (Docker): ${GITEA_URL}"
log ""
log "Active service groups: ${SERVICES}"
log "Monitor: kubectl get applications -n argocd"
log ""
log "To add/remove services:"
log "  mv argocd/available/ug-<service>.yaml argocd/apps/"
log "  git add -A && git commit -m 'Update' && GIT_SSL_NO_VERIFY=1 git push gitea main"
