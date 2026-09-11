# Forge4X Integration

The `ug-forge4x-root` Application points to the Forge4X deploy repo
(`f4x-dev-01-gitops`). ArgoCD discovers the Forge4X App of Apps tree
and manages all modules:

- f4x-tenancy (wave 0) — Capsule tenant framework
- f4x-platform (wave 1) — Kubeflow, OAuth2-proxy, Istio
- f4x-mlops (wave 2) — MLflow, Feast, Pipelines
- f4x-lakehouse (wave 3) — Iceberg, Superset
- f4x-gpu (wave 4) — GPU Operator, KAI Scheduler
- f4x-observability (wave 5) — Monitoring stack
- f4x-security (wave 6) — Keycloak realm, OPA

## Prerequisites

1. Push the Forge4X gitops repo to Gitea
2. Register it with ArgoCD: `argocd repo add <url>`
3. Update the `repoURL` in `argocd/apps/ug-forge4x-root.yaml`
