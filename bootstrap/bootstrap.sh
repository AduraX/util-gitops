#!/usr/bin/env bash
# =============================================================================
# util-gitops bootstrap script
# Imperatively installs the minimum components needed for ArgoCD to take over.
#
# Usage:
#   ./bootstrap.sh --cluster kind                          # All services
#   ./bootstrap.sh --cluster kind --services all           # Same as above
#   ./bootstrap.sh --cluster kind --services core,identity # Selected groups
#
# Service groups:
#   core       — ArgoCD, CNI, MetalLB, cert-manager, kgateway, routes (always included)
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
CLUSTER_TYPE="${CLUSTER_TYPE:-kind}"
SERVICES="all"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster) CLUSTER_TYPE="$2"; shift 2 ;;
    --services) SERVICES="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Service group → ArgoCD app file mapping
# "core" apps are always active and never moved out.
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

# Move all non-core apps to available/, then move selected groups back to apps/
activate_services() {
  local selected="$1"
  mkdir -p "$AVAILABLE_DIR"

  if [[ "$selected" == "all" ]]; then
    # Move everything from available/ back to apps/
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
      echo "WARNING: Unknown service group '${group}' — skipping"
      continue
    fi
    for app in ${SERVICE_GROUPS[$group]}; do
      [[ -f "$AVAILABLE_DIR/$app" ]] && mv "$AVAILABLE_DIR/$app" "$APPS_DIR/"
    done
  done

  log "Active service groups: core $(echo "$selected" | tr ',' ' ')"
  log "Active apps:"
  ls "$APPS_DIR"/ug-*.yaml 2>/dev/null | xargs -n1 basename | sed 's/^/  /'
}

# Check if a service group is active
group_active() {
  local group="$1"
  [[ "$SERVICES" == "all" ]] && return 0
  echo ",$SERVICES," | grep -q ",$group,"
}

DOMAIN="${DOMAIN:-gitops.lcl}"
OVERLAY_DIR="${REPO_DIR}/infra/overlays/${CLUSTER_TYPE}"

if [[ ! -d "$OVERLAY_DIR" ]]; then
  echo "ERROR: No overlay found for cluster type '${CLUSTER_TYPE}' at ${OVERLAY_DIR}"
  exit 1
fi

log() { echo "[$(date +"%H:%M:%S")] $1"; }

wait_ready() {
  local ns="$1" label="$2" timeout="${3:-120}"
  log "Waiting for pods with label ${label} in ${ns}..."
  kubectl wait --timeout="${timeout}s" --for=condition=ready pods -l "$label" -n "$ns" 2>/dev/null || true
}

# =============================================================================
# Phase 1: CNI + Networking (cluster-specific)
# =============================================================================
log "=== Phase 1: CNI + Networking (${CLUSTER_TYPE}) ==="

if [[ "$CLUSTER_TYPE" == "kind" ]]; then
  # Cilium
  if ! helm status cilium -n kube-system &>/dev/null; then
    log "Installing Cilium..."
    helm repo add cilium https://helm.cilium.io/ && helm repo update

    # Auto-detect control-plane IP for kube-proxy replacement
    CP_IP=$(docker inspect kind-clus-control-plane -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null | head -1)
    log "Control-plane IP for Cilium: ${CP_IP}"

    helm install cilium cilium/cilium -n kube-system \
      -f "${OVERLAY_DIR}/cilium-values.yaml" \
      --set k8sServiceHost="${CP_IP}" \
      --set k8sServicePort=6443
    wait_ready kube-system "app.kubernetes.io/name=cilium-agent" 180
  else
    log "Cilium already installed, skipping."
  fi
fi

# MetalLB (both Kind and RKE2 may need it)
if [[ -f "${OVERLAY_DIR}/metallb-values.yaml" ]]; then
  if ! helm status metallb -n metallb-system &>/dev/null; then
    log "Installing MetalLB..."
    helm repo add metallb https://metallb.github.io/metallb && helm repo update
    kubectl create namespace metallb-system 2>/dev/null || true
    helm install metallb metallb/metallb -n metallb-system \
      -f "${OVERLAY_DIR}/metallb-values.yaml"
    wait_ready metallb-system "app.kubernetes.io/name=metallb" 120

    # Wait for MetalLB webhook to be ready before applying CRs
    log "Waiting for MetalLB webhook..."
    kubectl wait --timeout=120s --for=condition=ready pods -l app.kubernetes.io/component=controller -n metallb-system 2>/dev/null || true
    sleep 10

    # Auto-detect Kind Docker network IPv4 range
    if [[ "$CLUSTER_TYPE" == "kind" ]]; then
      SUBNET=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' | head -1)
      if [[ -n "$SUBNET" ]]; then
        BASE=$(echo "$SUBNET" | cut -d'/' -f1 | cut -d'.' -f1-2)
        log "Detected Kind subnet: ${SUBNET}, using ${BASE}.255.200-${BASE}.255.250"
        cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
    - ${BASE}.255.200-${BASE}.255.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - kind-pool
EOF
      fi
    else
      log "Applying MetalLB config from overlay..."
      kubectl apply -f "${OVERLAY_DIR}/metallb-config/"
    fi
  else
    log "MetalLB already installed, skipping."
  fi
fi

# =============================================================================
# Phase 2: cert-manager + API Gateway
# =============================================================================
log "=== Phase 2: cert-manager + API Gateway ==="

if ! helm status cert-manager -n cert-manager &>/dev/null; then
  log "Installing cert-manager..."
  helm repo add jetstack https://charts.jetstack.io && helm repo update
  kubectl create namespace cert-manager 2>/dev/null || true
  helm install cert-manager jetstack/cert-manager -n cert-manager \
    -f "${REPO_DIR}/infra/base/cert-manager/values.yaml"
  wait_ready cert-manager "app.kubernetes.io/name=cert-manager" 120
  log "Applying ClusterIssuer..."
  kubectl apply -f "${REPO_DIR}/infra/base/cert-manager/config/"
else
  log "cert-manager already installed, skipping."
fi

# Install Gateway API CRDs (required by kgateway)
log "Installing Gateway API CRDs..."
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml 2>/dev/null || true

# Detect which gateway to install (kgateway default, traefik alternative)
if [[ -f "${REPO_DIR}/argocd/apps/ug-kgateway.yaml" ]]; then
  if ! helm status kgateway -n kgateway-system &>/dev/null; then
    log "Installing kgateway (Envoy Gateway API)..."
    kubectl create namespace kgateway-system 2>/dev/null || true
    helm upgrade -i kgateway-crds oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds \
      -n kgateway-system
    helm upgrade -i kgateway oci://cr.kgateway.dev/kgateway-dev/charts/kgateway \
      -n kgateway-system \
      -f "${REPO_DIR}/infra/base/kgateway/values.yaml"
    wait_ready kgateway-system "app.kubernetes.io/name=kgateway" 120
    log "Applying Gateway resource..."
    kubectl apply -f "${REPO_DIR}/infra/base/kgateway/gateway.yaml"
  else
    log "kgateway already installed, skipping."
  fi
elif [[ -f "${REPO_DIR}/argocd/apps/ug-traefik.yaml" ]]; then
  if ! helm status traefik -n traefik &>/dev/null; then
    log "Installing Traefik..."
    helm repo add traefik https://traefik.github.io/charts && helm repo update
    kubectl create namespace traefik 2>/dev/null || true
    TRAEFIK_VALUES=("-f" "${REPO_DIR}/infra/base/traefik/values.yaml")
    if [[ -f "${OVERLAY_DIR}/traefik-values.yaml" ]]; then
      TRAEFIK_VALUES+=("-f" "${OVERLAY_DIR}/traefik-values.yaml")
    fi
    helm install traefik traefik/traefik -n traefik "${TRAEFIK_VALUES[@]}"
    wait_ready traefik "app.kubernetes.io/name=traefik" 120
  else
    log "Traefik already installed, skipping."
  fi
fi

# =============================================================================
# Phase 3: ArgoCD
# =============================================================================
log "=== Phase 3: ArgoCD ==="

if ! helm status argocd -n argocd &>/dev/null; then
  log "Installing ArgoCD..."
  helm repo add argo https://argoproj.github.io/argo-helm && helm repo update
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
# Phase 4: Gitea (for hosting this gitops repo)
# =============================================================================
log "=== Phase 4: PostgreSQL (CNPG) + Gitea ==="

# Install CNPG operator
if ! helm status cnpg -n cnpg-system &>/dev/null; then
  log "Installing CNPG operator..."
  helm repo add cnpg https://cloudnative-pg.github.io/charts && helm repo update
  kubectl create namespace cnpg-system 2>/dev/null || true
  helm install cnpg cnpg/cloudnative-pg -n cnpg-system
  wait_ready cnpg-system "app.kubernetes.io/name=cloudnative-pg" 120
fi

# Create Gitea database
kubectl create namespace storage 2>/dev/null || true
kubectl create secret generic gitea-db-credentials -n storage \
  --from-literal=username=gitea \
  --from-literal=password="${GITEA_DB_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${REPO_DIR}/platform/storage/cnpg/clusters/gitea-db.yaml"
log "Waiting for Gitea database cluster..."
sleep 30
kubectl wait --timeout=180s --for=condition=ready cluster/gitea-db -n storage 2>/dev/null || true

# Install Gitea
if ! helm status gitea -n devtools &>/dev/null; then
  log "Installing Gitea..."
  helm repo add gitea https://dl.gitea.com/charts/ && helm repo update
  kubectl create namespace devtools 2>/dev/null || true
  helm install gitea gitea/gitea -n devtools \
    -f "${REPO_DIR}/platform/devtools/gitea/values.yaml" \
    --set gitea.admin.password="${GITEA_ADMIN_PASSWORD}" \
    --set gitea.config.database.PASSWD="${GITEA_DB_PASSWORD}"
  wait_ready devtools "app.kubernetes.io/name=gitea" 180
else
  log "Gitea already installed, skipping."
fi

# =============================================================================
# Phase 5: Push gitops repo to Gitea + activate ArgoCD
# =============================================================================
log "=== Phase 5: Activate GitOps ==="

# Port-forward to Gitea (gateway may not have external IP yet)
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

# Detect Gitea admin username (Helm chart may use gitea_admin instead of admin)
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

# Push this repo via port-forward
cd "$REPO_DIR"
GITEA_PUSH_URL="http://${GITEA_ACTUAL_USER}:${GITEA_ADMIN_PASSWORD}@localhost:3000/${GITEA_ACTUAL_USER}/util-gitops.git"
git remote remove gitea 2>/dev/null || true
git remote add gitea "$GITEA_PUSH_URL"
git push -u gitea main 2>/dev/null || git push gitea main

# Update remote to use domain URL (for future pushes after gateway is up)
GITEA_URL="https://gitea.${DOMAIN}"
git remote set-url gitea "${GITEA_URL}/${GITEA_ACTUAL_USER}/util-gitops.git"

# Register repo with ArgoCD
log "Registering repo with ArgoCD..."
kubectl -n argocd exec deploy/argocd-server -- \
  argocd repo add "${GITEA_URL}/${GITEA_ACTUAL_USER}/util-gitops.git" \
    --username "${GITEA_ACTUAL_USER}" --password "${GITEA_ADMIN_PASSWORD}" \
    --insecure-skip-server-verification 2>/dev/null || true

# Clean up port-forward
kill $PF_PID 2>/dev/null || true

# Activate selected service groups (moves apps in/out of argocd/apps/)
log "Activating service groups: ${SERVICES}"
activate_services "$SERVICES"

# Apply ArgoCD projects
log "Applying ArgoCD projects..."
kubectl apply -f "${REPO_DIR}/argocd/projects/"

# Apply overlay-specific apps (Cilium, MetalLB for Kind)
if [[ -d "${OVERLAY_DIR}/apps/" ]]; then
  log "Applying overlay apps for ${CLUSTER_TYPE}..."
  kubectl apply -f "${OVERLAY_DIR}/apps/"
fi

# Apply root Application — ArgoCD takes over from here
log "Applying root Application (App of Apps)..."
kubectl apply -f "${REPO_DIR}/argocd/apps/ug-root.yaml"

# =============================================================================
# Done
# =============================================================================
log ""
log "=== Bootstrap complete ==="
log "ArgoCD UI:  https://argocd.${DOMAIN}"
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
