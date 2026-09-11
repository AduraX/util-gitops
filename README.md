# util-gitops: GitOps Implementation Plan

## Context

GitOps repo for Kubernetes application workloads managed by ArgoCD.

**Architecture**: Infrastructure services (Gitea, Keycloak, OpenLDAP, MinIO) run in Docker via utilStack — like external services (GitHub, EntraID, AWS S3). ArgoCD on K8s manages only application workloads, monitoring, AI, and Forge4X.

| Layer | Where | Services |
|-------|-------|----------|
| External (utilStack/Docker) | Docker Compose | Gitea, Keycloak, OpenLDAP, MinIO, PostgreSQL |
| Infra (kind_Run.sh) | K8s imperatively | Cilium, MetalLB, cert-manager, Traefik |
| Apps (ArgoCD) | K8s declaratively | Monitoring, Velero, Ollama, Open WebUI, Rancher, Forge4X |

**K8s-agnostic design** — works on Kind, RKE2, or any conformant cluster.

## Directory Structure

```
/home/oyex/wkspace/projs/util-gitops/
├── README.md
├── bootstrap/
│   ├── bootstrap.sh              # Imperative: K8s → ArgoCD → Gitea → push repo → activate
│   ├── teardown.sh
│   └── config.env.example        # Environment-specific vars (domain, IPs, passwords)
├── argocd/
│   ├── projects/
│   │   ├── ug-root.yaml          # Restrictive (only Application CRDs in argocd ns)
│   │   ├── ug-infra.yaml         # Permissive (all resources, all namespaces)
│   │   └── ug-forge4x.yaml       # Forge4X deploy repo access
│   ├── apps/                     # Root app scans this directory
│   │   ├── ug-root.yaml          # App of Apps root
│   │   ├── ug-argocd.yaml        # ArgoCD self-manages (wave 0)
│   │   ├── ug-cert-manager.yaml  # Wave 1
│   │   ├── ug-traefik.yaml       # Wave 1
│   │   ├── ug-cnpg.yaml          # Wave 2 (CNPG operator)
│   │   ├── ug-cnpg-clusters.yaml # Wave 2 (directory-type, DB cluster CRDs)
│   │   ├── ug-keycloak.yaml      # Wave 3
│   │   ├── ug-openldap.yaml      # Wave 3
│   │   ├── ug-openbao.yaml       # Wave 3 (secrets — default, swap with vault)
│   │   ├── ug-gitea.yaml         # Wave 4
│   │   ├── ug-gitea-runner.yaml  # Wave 4 (CI/CD — default, swap with ARC)
│   │   ├── ug-minio.yaml         # Wave 4
│   │   ├── ug-monitoring.yaml    # Wave 5 (kube-prometheus-stack)
│   │   ├── ug-ollama.yaml        # Wave 6
│   │   ├── ug-open-webui.yaml    # Wave 6
│   │   ├── ug-rancher.yaml       # Wave 6
│   │   ├── ug-vscodium.yaml      # Wave 6 (directory-type, raw manifests)
│   │   ├── ug-routes.yaml        # Wave 2 (directory-type, Gateway API HTTPRoutes)
│   │   └── ug-forge4x-root.yaml  # Wave 7 (points to Forge4X deploy repo)
│   ├── available/                # Inactive alternatives — move into apps/ to activate
│   │   ├── ug-vault.yaml         # Wave 3 (swap for ug-openbao.yaml)
│   │   ├── ug-arc.yaml           # Wave 4 (swap for ug-gitea-runner.yaml)
│   │   └── ug-arc-runners.yaml   # Wave 4 (directory-type, RunnerScaleSet CRDs)
│   └── values/
│       └── argocd-values.yaml    # ArgoCD Helm values (Keycloak OIDC, dex disabled)
├── infra/
│   ├── base/                     # Cluster-agnostic infra
│   │   ├── cert-manager/
│   │   │   ├── values.yaml
│   │   │   └── config/           # ClusterIssuer CR
│   │   └── traefik/values.yaml   # Gateway API mode (portable)
│   └── overlays/                 # Cluster-specific infra
│       ├── kind/
│       │   ├── cilium-values.yaml        # VXLAN mode for Kind
│       │   ├── metallb-values.yaml
│       │   ├── metallb-config/           # IPAddressPool (Docker subnet)
│       │   ├── traefik-values.yaml       # NodePort overrides for Kind
│       │   └── apps/                     # Kind-specific child apps
│       │       ├── ug-cilium.yaml
│       │       └── ug-metallb.yaml
│       └── rke2/
│           ├── metallb-values.yaml       # Real network range
│           ├── metallb-config/
│           ├── traefik-values.yaml       # LoadBalancer type
│           └── apps/
│               └── ug-metallb.yaml
├── platform/                     # Portable platform services (any K8s)
│   ├── storage/
│   │   ├── cnpg/
│   │   │   ├── values.yaml           # CNPG operator Helm values
│   │   │   └── clusters/             # CNPG Cluster CRDs (gitea-db, keycloak-db)
│   │   │       ├── gitea-db.yaml
│   │   │       └── keycloak-db.yaml
│   │   └── minio/values.yaml
│   ├── identity/
│   │   ├── keycloak/values.yaml
│   │   └── openldap/values.yaml
│   ├── secrets/
│   │   ├── openbao/values.yaml       # OpenBao (OSS Vault fork, MPL-2.0)
│   │   └── vault/values.yaml         # HashiCorp Vault CE (BSL)
│   ├── cicd/
│   │   ├── gitea-runner/values.yaml        # Gitea Act Runner (Helm or raw manifests)
│   │   ├── arc/values.yaml                 # GitHub ARC controller
│   │   └── arc-runners/                    # RunnerScaleSet CRDs per repo/org
│   │       └── default-runner.yaml
│   ├── devtools/
│   │   ├── gitea/values.yaml
│   │   └── vscodium/
│   │       ├── deployment.yaml
│   │       ├── service.yaml
│   │       └── httproute.yaml
│   ├── monitoring/
│   │   └── kube-prometheus-stack/values.yaml
│   └── ai/
│       ├── ollama/values.yaml
│       └── open-webui/values.yaml
├── forge4x/
│   └── README.md                 # Documents Forge4X integration
└── gateway-api/
    └── routes/                   # HTTPRoutes for all services
        ├── argocd-route.yaml
        ├── gitea-route.yaml
        ├── keycloak-route.yaml
        ├── grafana-route.yaml
        ├── minio-route.yaml
        ├── openbao-route.yaml
        ├── vault-route.yaml
        ├── webui-route.yaml
        └── ...
```

**Key design decisions**:

- `infra/base/` contains cluster-agnostic components (cert-manager, gateway). `infra/overlays/<cluster>/` contains cluster-specific components (CNI, LB, port mappings). The bootstrap script selects the overlay based on the target cluster. `platform/` is fully portable — identical across Kind, RKE2, EKS, etc.

- **Pick-one services**: Where competing tools serve the same role, enable one by including its ArgoCD Application CRD in `argocd/apps/` and keeping the other excluded. The child app YAML files for optional/alternative services live in `argocd/available/` — copy into `argocd/apps/` to activate:

  | Role | Default (in apps/) | Alternative (in available/) |
  |------|----------|----------|
  | API Gateway | kgateway (Envoy) | Traefik |
  | Secrets management | OpenBao (OSS) | Vault CE (BSL) |
  | CI/CD runners | Gitea Actions runner | GitHub ARC |

  To switch, move the active app out of `argocd/apps/` and move the alternative in from `argocd/available/`.

## Bootstrap Sequence

ArgoCD is installed first, then everything else is ArgoCD-managed. The bootstrap script accepts a `--cluster` flag (`kind`, `rke2`, etc.) to select the overlay:

```
bootstrap.sh --cluster kind     # or rke2, eks, etc.

1. K8s cluster exists (created externally by kind_Run.sh, rke2 ansible, etc.)
2. Imperative bootstrap:
   a. Detect cluster type, load overlay config
   b. helm install CNI (cilium for Kind, skip if RKE2 bundles its own)
   c. helm install metallb (if needed) + apply IPAddressPool from overlay
   d. helm install cert-manager + apply ClusterIssuer
   e. helm install traefik (with overlay-specific values merged)
   f. helm install argocd (reuse install_argocd() pattern from commonFtns.sh)
   g. helm install postgresql (for Gitea DB)
   h. helm install gitea
   i. Create Gitea repo "util-gitops" via API, push this repo
   j. argocd repo add (register Gitea repo with ArgoCD)
   k. kubectl apply projects + overlay-specific apps + ug-root.yaml
   l. ArgoCD takes over — adopts all imperatively installed services
```

RKE2 ships with its own CNI and ingress — the overlay skips those. Kind needs Cilium + MetalLB. The platform apps are identical regardless.

## Child App Pattern (Multi-Source for Helm + Values)

Each child app uses ArgoCD multi-source to pull the Helm chart from upstream and values from the gitops repo:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ug-<service>
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "<N>"
spec:
  project: ug-infra
  sources:
    - repoURL: <helm-chart-repo>
      chart: <chart-name>
      targetRevision: <version>
      helm:
        releaseName: <service>
        valueFiles:
          - $values/<path>/values.yaml
    - repoURL: <gitea-gitops-repo>
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: <namespace>
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
      - CreateNamespace=true
```

## Helm Charts Reference

| Service | Chart | Repo | Namespace |
|---------|-------|------|-----------|
| Cilium | cilium/cilium | https://helm.cilium.io/ | kube-system |
| MetalLB | metallb/metallb | https://metallb.github.io/metallb | metallb-system |
| cert-manager | jetstack/cert-manager | https://charts.jetstack.io | cert-manager |
| kgateway | kgateway/kgateway | oci://cr.kgateway.dev/kgateway-dev/charts | kgateway-system |
| Traefik | traefik/traefik | https://traefik.github.io/charts | traefik |
| ArgoCD | argo/argo-cd | https://argoproj.github.io/argo-helm | argocd |
| CNPG Operator | cloudnative-pg/cloudnative-pg | https://cloudnative-pg.github.io/charts | cnpg-system |
| Keycloak | bitnami/keycloak | https://charts.bitnami.com/bitnami | identity |
| OpenLDAP | helm-openldap/openldap-stack-ha | https://jp-gouin.github.io/helm-openldap/ | identity |
| Gitea | gitea/gitea | https://dl.gitea.com/charts/ | devtools |
| Gitea Runner | gitea/act-runner | https://dl.gitea.com/charts/ | cicd |
| ARC Controller | actions-runner-controller-charts/gha-runner-scale-set-controller | https://actions-runner-controller.github.io/actions-runner-controller | arc-systems |
| ARC Runners | actions-runner-controller-charts/gha-runner-scale-set | https://actions-runner-controller.github.io/actions-runner-controller | arc-runners |
| MinIO | minio/minio | https://charts.min.io/ | storage |
| kube-prometheus-stack | prometheus-community/kube-prometheus-stack | https://prometheus-community.github.io/helm-charts | monitoring |
| Ollama | ollama-helm/ollama | https://otwld.github.io/ollama-helm/ | ai |
| Open WebUI | open-webui/open-webui | https://helm.openwebui.com/ | open-webui |
| OpenBao | openbao/openbao | https://openbao.github.io/openbao-helm | secrets |
| Vault CE | hashicorp/vault | https://helm.releases.hashicorp.com | secrets |
| Rancher | rancher-stable/rancher | https://releases.rancher.com/server-charts/stable | cattle-system |

## Forge4X Integration

`ug-forge4x-root.yaml` (wave 7) points to the existing Forge4X deploy repo (`f4x-dev-01-gitops`). ArgoCD discovers the Forge4X App of Apps tree and manages all Forge4X modules (platform, mlops, lakehouse, gpu, observability, security, tenancy).

## Key Files to Reuse

- `/home/oyex/wkspace/projs/k8s-cluster/commonFtns.sh` — `install_argocd()`, `install_cilium()`, `install_certmanager()`, `install_traefik()`, `install_metallb()` for bootstrap
- `/home/oyex/wkspace/projs/k8s-cluster/custom-traefik-values.yaml` — Traefik Gateway API values
- `/home/oyex/wkspace/Akesan4X/Forge4X/argocd/f4x-application.yaml.tpl` — ignoreDifferences patterns
- `/home/oyex/wkspace/Akesan4X/Forge4X/argocd/projects/` — AppProject patterns

## Implementation Order

1. Create repo structure + README
2. Bootstrap script (bootstrap.sh --cluster kind/rke2 + teardown.sh)
3. ArgoCD projects + root app
4. Infra overlays: Kind (Cilium + MetalLB) and RKE2 (MetalLB only)
5. Infra base: cert-manager + Traefik child apps + values
6. Wave 2: PostgreSQL child app + values
7. Wave 3: Keycloak + OpenLDAP child apps + values
8. Wave 4: Gitea + MinIO child apps + values
9. Wave 5: kube-prometheus-stack child app + values
10. Wave 6: Ollama + Open WebUI + Rancher + VSCodium
11. Wave 7: Forge4X integration
12. Gateway API HTTPRoutes
13. Test on fresh Kind cluster
14. Test on RKE2 cluster

## Verification

1. `bootstrap.sh` completes without errors on a fresh Kind cluster
2. `kubectl get applications -n argocd` shows all apps synced/healthy
3. All services accessible via `https://<service>.gitops.lcl`
4. ArgoCD UI at `https://argocd.gitops.lcl` shows full app tree
5. Forge4X modules visible in ArgoCD dashboard
