#!/bin/bash
# =============================================================================
# Stripped RKE2 cluster creator for util-gitops
# Deploys a bare RKE2 cluster with NO post-deployment components.
# All CNI (if Cilium), networking, ingress, and services are managed by
# ArgoCD via bootstrap.sh
#
# Usage:
#   ./rke2-create.sh          # Single-master
#   ./rke2-create.sh ha       # High-availability
#
# Prerequisites:
#   - Ansible installed on launcher node
#   - SSH key distributed to nodes (or will be done here)
#   - Host inventory configured
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RKE2_DIR="${SCRIPT_DIR}/../../k8s-cluster/rke2"

# Load config
if [[ -f "$SCRIPT_DIR/config.env" ]]; then
  set -a; source "$SCRIPT_DIR/config.env"; set +a
fi

RKE2_HA="${1:-sm}"
case "${RKE2_HA}" in
  sm|ha) ;;
  *) echo "Usage: $0 [ha|sm]" >&2; exit 1 ;;
esac

# Source common functions from k8s-cluster
source "${RKE2_DIR}/../commonFtns.sh"

PREFIX="${PREFIX:-kube}"
SUFFIX="${SUFFIX:-localdev}"
K8S_USER="${K8S_USER:-$USER}"
DOT_DOMAIN="${PREFIX}.${SUFFIX}"
DASH_DOMAIN=$(echo "$DOT_DOMAIN" | sed 's/[.]/-/g')
WORK_DIR="${WORK_DIR:-$HOME/workdir}"
CERTDIR="${CERTDIR:-$WORK_DIR/.certDir/$(echo "$DOT_DOMAIN" | sed 's/[.]/_/g')}"

# CNI: RKE2 bundles Canal (Calico+Flannel) by default.
# If Cilium is desired, set CNI=cilium — bootstrap.sh will install it.
CNI="${CNI:-calico}"

ROOT_USER="${ROOT_USER:-root}"
ROOT_PASS="${ROOT_PASS:-}"
SSH_KEY_TYPE=ed25519
SSH_KEY_FILE="${HOME}/.ssh/id_${SSH_KEY_TYPE}-rke2"

RKE2_REL="${RKE2_REL:-rke2r3}"
RKE2_VERSION="${RKE2_VERSION:-1.35.3}"

ANSIBLE_COMMON_ENV=(
  ANSIBLE_HOST_KEY_CHECKING=False
  ANSIBLE_LOCAL_TEMP=/tmp/ansible-local
  ANSIBLE_REMOTE_TMP=/tmp/ansible-remote
  ANSIBLE_SSH_CONTROL_PATH_DIR=/tmp/ansible-cp
)

if [ "${RKE2_HA}" = "ha" ]; then
  RKE2_INVENTORY="${RKE2_DIR}/host_inventory_ha.ini"
  RKE2_PLAYBOOK="${RKE2_DIR}/deploy_rke2_ha.yaml"
else
  RKE2_INVENTORY="${RKE2_DIR}/host_inventory_sm.ini"
  RKE2_PLAYBOOK="${RKE2_DIR}/deploy_rke2_sm.yaml"
fi

log() { echo "[$(date +"%H:%M:%S")] $1"; }

# -------------------------------------------------------------------------
# Step 1: SSH key setup
# -------------------------------------------------------------------------
log "=== SSH key setup ==="

if [ ! -f "${SSH_KEY_FILE}" ]; then
  ssh-keygen -t "${SSH_KEY_TYPE}" -f "${SSH_KEY_FILE}" -C "RKE2 cluster key" -N ""
fi

if [[ -n "${ROOT_PASS}" ]]; then
  log "Distributing SSH keys via Ansible..."
  env "${ANSIBLE_COMMON_ENV[@]}" \
  ansible-playbook \
    -i "${RKE2_INVENTORY}" \
    -u "${ROOT_USER}" \
    -e "ansible_password=${ROOT_PASS}" \
    -e "rke2_ssh_public_key_file=${SSH_KEY_FILE}.pub" \
    "${RKE2_DIR}/install_ssh_keys.yaml"
fi

eval "$(ssh-agent -s)"
ssh-add "${SSH_KEY_FILE}"

# -------------------------------------------------------------------------
# Step 2: Deploy bare RKE2 cluster (no post-deploy components)
# -------------------------------------------------------------------------
log "=== Deploying RKE2 cluster (${RKE2_HA}) ==="

local rke2_ver="v${RKE2_VERSION}+${RKE2_REL}"

env "${ANSIBLE_COMMON_ENV[@]}" \
ansible-playbook \
  -i "${RKE2_INVENTORY}" \
  -u "${ROOT_USER}" \
  --private-key "${SSH_KEY_FILE}" \
  -e "rke2_version=${rke2_ver}" \
  -e "rke2_image_mode=upstream" \
  -e "rke2_cni_override=${CNI}" \
  "${RKE2_PLAYBOOK}"

# -------------------------------------------------------------------------
# Step 3: Kubeconfig setup
# -------------------------------------------------------------------------
log "=== Setting up kubeconfig ==="

mkdir -p "/home/${K8S_USER}/.kube"
cp "${RKE2_DIR}/rke2-kubeconfig" "/home/${K8S_USER}/.kube/rke2.conf"
export KUBECONFIG="/home/${K8S_USER}/.kube/k8s.conf:/home/${K8S_USER}/.kube/rke2.conf"
merged_kubeconfig="$(mktemp)"
kubectl config view --flatten > "${merged_kubeconfig}" && cp "${merged_kubeconfig}" "/home/${K8S_USER}/.kube/config"
rm -f "${merged_kubeconfig}"
chown "${K8S_USER}:${K8S_USER}" "/home/${K8S_USER}/.kube/config"
chmod 600 "/home/${K8S_USER}/.kube/config"
export KUBECONFIG="/home/${K8S_USER}/.kube/config"

# -------------------------------------------------------------------------
# Step 4: Distribute TLS certs to workers
# -------------------------------------------------------------------------
if [ -f "${CERTDIR}/${DASH_DOMAIN}-tls.crt" ]; then
  log "Distributing TLS certs to worker nodes..."
  env "${ANSIBLE_COMMON_ENV[@]}" \
  ansible workers \
    -i "${RKE2_INVENTORY}" \
    -u "${ROOT_USER}" \
    --private-key "${SSH_KEY_FILE}" \
    -b \
    -m file \
    -a 'path=/etc/rancher/cert state=directory owner=root group=root mode=0755'

  for f in "${DASH_DOMAIN}-tls.crt" "${DASH_DOMAIN}-tls.key" "${DASH_DOMAIN}-ca.crt"; do
    local mode="0644"
    [[ "$f" == *".key" ]] && mode="0600"
    env "${ANSIBLE_COMMON_ENV[@]}" \
    ansible workers \
      -i "${RKE2_INVENTORY}" \
      -u "${ROOT_USER}" \
      --private-key "${SSH_KEY_FILE}" \
      -b \
      -m copy \
      -a "src=${CERTDIR}/${f} dest=/etc/rancher/cert/${f} owner=root group=root mode=${mode}"
  done
fi

# -------------------------------------------------------------------------
# Done
# -------------------------------------------------------------------------
log ""
log "=== Bare RKE2 cluster ready ==="
kubectl get nodes -o wide
log ""
log "Next: ./bootstrap.sh --cluster rke2"
