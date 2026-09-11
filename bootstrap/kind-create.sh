#!/bin/bash
# =============================================================================
# Stripped Kind cluster creator for util-gitops
# Creates a bare Kind cluster with NO components installed.
# All CNI, networking, ingress, and services are managed by ArgoCD via bootstrap.sh
#
# Usage: ./kind-create.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load config
if [[ -f "$SCRIPT_DIR/config.env" ]]; then
  set -a; source "$SCRIPT_DIR/config.env"; set +a
fi

KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.34.3}"
CLUSTER_NAME="${CLUSTER_NAME:-kind-clus}"

# GPU support (optional)
GPU_ENABLED="${GPU_ENABLED:-false}"

log() { echo "[$(date +"%H:%M:%S")] $1"; }

# Check for existing cluster
if docker inspect -f '{{.State.Running}}' "${CLUSTER_NAME}-control-plane" &>/dev/null || \
   kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "Cluster '${CLUSTER_NAME}' already exists."
  read -rp "Delete and recreate? (y/n): " resp
  if [[ "${resp,,}" == "y" ]]; then
    kind delete cluster --name "$CLUSTER_NAME"
  else
    echo "Skipping cluster creation."
    exit 0
  fi
fi

# GPU runtime check
if [[ "$GPU_ENABLED" == "true" ]]; then
  if ! docker info 2>/dev/null | grep -q "nvidia"; then
    echo "ERROR: GPU_ENABLED=true but NVIDIA Docker runtime not found."
    echo "Run: sudo nvidia-ctk runtime configure --runtime=docker --set-as-default"
    exit 1
  fi
  log "NVIDIA Docker runtime detected."
fi

# Generate GPU extra mounts if needed
generate_gpu_mounts() {
  if [[ "$GPU_ENABLED" == "true" ]]; then
    cat <<'GPUMOUNTS'
  extraMounts:
  - hostPath: /dev/null
    containerPath: /var/run/nvidia-container-devices/all
GPUMOUNTS
  fi
}

# Create cluster — bare, no CNI (disableDefaultCNI: true for Cilium)
log "Creating Kind cluster '${CLUSTER_NAME}'..."

cat <<EOF | kind create cluster --name="$CLUSTER_NAME" --image "$KIND_NODE_IMAGE" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true    # Cilium will be installed by ArgoCD
  kubeProxyMode: none        # Cilium replaces kube-proxy
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 80
    hostPort: 8880
    protocol: TCP
  - containerPort: 443
    hostPort: 8443
    protocol: TCP
  - containerPort: 8000
    hostPort: 8000
    protocol: TCP
  kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    apiServer:
      extraArgs:
        "service-account-issuer": "kubernetes.default.svc"
        "service-account-signing-key-file": "/etc/kubernetes/pki/sa.key"
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
- role: worker
$(generate_gpu_mounts)
- role: worker
$(generate_gpu_mounts)
EOF

kind get kubeconfig --name "$CLUSTER_NAME" > ~/.kube/config
log "Kind cluster '${CLUSTER_NAME}' created (bare — no CNI, no components)."

# Update CA certs on nodes
nodes=($(kubectl get nodes -o custom-columns=":metadata.name" --no-headers))
for node in "${nodes[@]}"; do
  docker exec "$node" update-ca-certificates 2>/dev/null || true
done

# GPU worker labeling
if [[ "$GPU_ENABLED" == "true" ]]; then
  log "Labeling GPU workers..."
  for worker in $(kind get nodes --name "$CLUSTER_NAME" | grep -- '-worker' | sort -V); do
    kubectl label node "$worker" kindclus.nvidia.com/gpu=true --overwrite
    docker exec "$worker" bash -c \
      'mkdir -p /usr/local/nvidia/lib64 && mount --bind /usr/lib/wsl/lib /usr/local/nvidia/lib64' 2>/dev/null || true
  done
  kubectl apply -f - <<'RTEOF'
apiVersion: node.k8s.io/v1
handler: nvidia
kind: RuntimeClass
metadata:
  name: nvidia
RTEOF
  log "GPU support configured."
fi

log ""
log "=== Bare cluster ready ==="
log "Nodes:"
kubectl get nodes
log ""
log "Next: ./bootstrap.sh --cluster kind"
