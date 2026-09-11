#!/usr/bin/env bash
# =============================================================================
# util-gitops teardown — removes ArgoCD-managed resources then ArgoCD itself
# =============================================================================

set -euo pipefail

log() { echo "[$(date +"%H:%M:%S")] $1"; }

log "=== Teardown ==="

# Delete root application (cascading delete removes all child apps)
log "Deleting root Application (cascading)..."
kubectl delete application ug-root -n argocd --cascade=foreground 2>/dev/null || true

log "Waiting for child applications to terminate..."
sleep 30

# Remove ArgoCD
log "Uninstalling ArgoCD..."
helm uninstall argocd -n argocd 2>/dev/null || true
kubectl delete namespace argocd 2>/dev/null || true

# Remove Traefik
log "Uninstalling Traefik..."
helm uninstall traefik -n traefik 2>/dev/null || true
kubectl delete namespace traefik 2>/dev/null || true

# Remove cert-manager
log "Uninstalling cert-manager..."
helm uninstall cert-manager -n cert-manager 2>/dev/null || true
kubectl delete namespace cert-manager 2>/dev/null || true

# Remove MetalLB
log "Uninstalling MetalLB..."
helm uninstall metallb -n metallb-system 2>/dev/null || true
kubectl delete namespace metallb-system 2>/dev/null || true

log "=== Teardown complete ==="
log "CNI (Cilium) left in place — removing it would break the cluster."
log "To fully reset, delete the Kind/RKE2 cluster."
