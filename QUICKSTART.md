# util-gitops — Quickstart

## Prerequisites

- Kubernetes cluster (Kind, RKE2, or any conformant cluster)
- `kubectl`, `helm`, `git` installed
- Domain resolving via dnsmasq (e.g., `*.gitops.lcl → <cluster-ip>`)

## 1. Create a Bare Kubernetes Cluster

These stripped scripts create a cluster with NO components installed (no CNI, no ingress, no cert-manager). Everything is managed by ArgoCD via the bootstrap.

**Kind (local dev):**
```bash
cd /home/oyex/wkspace/projs/util-gitops/bootstrap
./kind-create.sh
```

**RKE2 (on-prem):**
```bash
cd /home/oyex/wkspace/projs/util-gitops/bootstrap
./rke2-create.sh        # single-master
./rke2-create.sh ha     # high-availability
```

## 2. Configure

```bash
cd /home/oyex/wkspace/projs/util-gitops/bootstrap
cp config.env.example config.env
nano config.env
```

Key settings to change:
```bash
CLUSTER_TYPE=kind              # kind | rke2
DOMAIN=gitops.lcl                # your domain
GITEA_ADMIN_PASSWORD=<strong>  # Gitea admin password
KEYCLOAK_ADMIN_PASSWORD=<strong>
GITEA_DB_PASSWORD=<strong>
KEYCLOAK_DB_PASSWORD=<strong>
MINIO_ROOT_PASSWORD=<strong>
GRAFANA_ADMIN_PASSWORD=<strong>
```

## 3. Initialize Git Repo

```bash
cd /home/oyex/wkspace/projs/util-gitops
git init
git add -A
git commit -m "Initial commit"
```

## 4. Bootstrap

```bash
# All services
./bootstrap/bootstrap.sh --cluster kind

# Selected groups only
./bootstrap/bootstrap.sh --cluster kind --services storage,identity,devtools

# Core + monitoring only
./bootstrap/bootstrap.sh --cluster kind --services monitoring
```

**Service groups:**

| Group | Services |
|-------|----------|
| core | ArgoCD, CNI, MetalLB, cert-manager, kgateway, routes (always included) |
| storage | CNPG operator, MinIO |
| identity | Keycloak, OpenLDAP, OpenBao |
| devtools | Gitea, Gitea runner, VSCodium |
| monitoring | kube-prometheus-stack, Velero |
| ai | Ollama, Open WebUI |
| rancher | Rancher |
| forge4x | Forge4X root |

Bootstrap installs (in order):
1. Cilium CNI + MetalLB (Kind only)
2. cert-manager + kgateway
3. ArgoCD
4. CNPG operator + Gitea database
5. Gitea
6. Pushes this repo to Gitea
7. Activates selected service groups
8. Applies App of Apps — ArgoCD takes over

To add/remove services after bootstrap:
```bash
mv argocd/available/ug-ollama.yaml argocd/apps/       # activate
mv argocd/apps/ug-rancher.yaml argocd/available/      # deactivate
git add -A && git commit -m "Update services" && git push gitea main
```

## 5. Monitor

```bash
# Watch all apps sync
kubectl get applications -n argocd -w

# Get ArgoCD admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

## Service URLs

| Service | URL |
|---------|-----|
| ArgoCD | https://argocd.gitops.lcl |
| Gitea | https://gitea.gitops.lcl |
| Keycloak | https://keycloak.gitops.lcl |
| Grafana | https://grafana.gitops.lcl |
| Prometheus | https://prometheus.gitops.lcl |
| MinIO Console | https://minio.gitops.lcl |
| MinIO S3 API | https://minio-api.gitops.lcl |
| OpenBao (Vault) | https://vault.gitops.lcl |
| Open WebUI (LLM) | https://webui.gitops.lcl |
| VSCodium | https://vscodium.gitops.lcl |
| Rancher | https://rancher.gitops.lcl |

## Swapping Services

Alternative services live in `argocd/available/`. Move into `argocd/apps/` to activate:

```bash
# Switch from kgateway to Traefik
mv argocd/apps/ug-kgateway.yaml argocd/available/
mv argocd/available/ug-traefik.yaml argocd/apps/

# Switch from OpenBao to Vault CE
mv argocd/apps/ug-openbao.yaml argocd/available/
mv argocd/available/ug-vault.yaml argocd/apps/

# Switch from Gitea runner to GitHub ARC
mv argocd/apps/ug-gitea-runner.yaml argocd/available/
mv argocd/available/ug-arc.yaml argocd/apps/
mv argocd/available/ug-arc-runners.yaml argocd/apps/

# Commit and push — ArgoCD picks up changes automatically
git add -A && git commit -m "Swap services" && git push gitea main
```

## Backup & Restore

Velero runs segmented backups to MinIO:

| Schedule | Namespaces | Frequency | Retention |
|----------|------------|-----------|-----------|
| backup-identity | identity, secrets | Daily | 30 days |
| backup-devtools | devtools, cicd | Daily | 30 days |
| backup-storage | storage, cnpg-system | Daily | 30 days |
| backup-monitoring | monitoring | Daily | 15 days |
| backup-ai | ai | Weekly | 30 days |

```bash
# List backups
velero backup get

# Restore a specific namespace group
velero restore create --from-backup backup-identity-<timestamp>
```

## Teardown

```bash
./bootstrap/teardown.sh
# Or delete the cluster entirely:
kind delete cluster --name kind-clus
```

## Architecture

```
ArgoCD (App of Apps)
├── Wave 0: ArgoCD (self-managed), Cilium, MetalLB
├── Wave 1: cert-manager, kgateway
├── Wave 2: CNPG operator + DB clusters, Gateway API routes
├── Wave 3: Keycloak, OpenLDAP, OpenBao
├── Wave 4: Gitea, Gitea runner, MinIO
├── Wave 5: kube-prometheus-stack, Velero
├── Wave 6: Ollama, Open WebUI, Rancher, VSCodium
└── Wave 7: Forge4X (platform, mlops, lakehouse, gpu, observability, security)
```
