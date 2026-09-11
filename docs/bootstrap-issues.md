# Bootstrap Issues & Fixes

Issues encountered during the first bootstrap runs on Kind (WSL2) and the fixes applied.

## 1. MetalLB subnet detection: IPv6 prefix leaked into IPv4

**Symptom:** `Detected Kind subnet: 64172.21.255.200` — invalid IP  
**Cause:** Docker outputs IPv6 and IPv4 subnets concatenated without separator  
**Fix:** Added space in Go template (`{{.Subnet}} {{end}}`) + `grep -oE` for IPv4 only  
**File:** `bootstrap/bootstrap.sh`

## 2. MetalLB webhook denied IPAddressPool creation

**Symptom:** `admission webhook "ipaddresspoolvalidationwebhook.metallb.io" denied the request`  
**Cause:** IPAddressPool applied before MetalLB controller pod was fully ready  
**Fix:** Added `kubectl wait` for controller pod + 10s buffer before applying CRs  
**File:** `bootstrap/bootstrap.sh`

## 3. cert-manager `installCRDs` deprecation warning

**Symptom:** `WARNING: installCRDs is deprecated, use crds.enabled instead`  
**Cause:** Chart renamed the values key  
**Fix:** Changed `installCRDs: true` to `crds: { enabled: true }`  
**File:** `infra/base/cert-manager/values.yaml`

## 4. CNPG secret type conflict

**Symptom:** `The Secret "gitea-db-credentials" is invalid: type: Invalid value: "kubernetes.io/basic-auth": field is immutable`  
**Cause:** Bootstrap creates secret as `Opaque`, CNPG cluster YAML defined `kubernetes.io/basic-auth`  
**Fix:** Changed CNPG cluster YAMLs to use `type: Opaque`  
**Files:** `platform/storage/cnpg/clusters/gitea-db.yaml`, `keycloak-db.yaml`

## 5. ArgoCD repo-server CrashLoopBackOff

**Symptom:** `Liveness probe failed: connection timed out` on port 8084  
**Cause:** ArgoCD Helm chart creates NetworkPolicies that block kubelet health probes from host network  
**Fix:** Added `global.networkPolicy.create: false` to ArgoCD values  
**File:** `argocd/values/argocd-values.yaml`

## 6. ArgoCD probe timeouts on Kind/WSL2

**Symptom:** Repo-server repeatedly killed by liveness probe  
**Cause:** Default 1s probe timeout too short for resource-constrained Kind on WSL2  
**Fix:** Increased to 5s timeout, 30s period, 5 failure threshold  
**File:** `argocd/values/argocd-values.yaml`

## 7. Gitea admin username mismatch

**Symptom:** `invalid username, password or token` when creating repo via API  
**Cause:** Gitea Helm chart creates admin as `gitea_admin`, bootstrap assumed `admin`  
**Fix:** Bootstrap auto-detects actual admin username via `gitea admin user list`  
**File:** `bootstrap/bootstrap.sh`

## 8. Gitea API unreachable during bootstrap

**Symptom:** `curl: (7) Failed to connect to gitea.gitops.lcl`  
**Cause:** Gateway has no external IP yet / DNS not configured during bootstrap  
**Fix:** Use `kubectl port-forward svc/gitea-http 3000:3000` during bootstrap  
**File:** `bootstrap/bootstrap.sh`

## 9. Gitea DB password authentication failed

**Symptom:** `pq: password authentication failed for user "gitea" (28P01)`  
**Cause:** CNPG `bootstrap.initdb.secret` sets superuser password, but the app user (`gitea`) gets a randomly generated password  
**Fix:** Added `SSL_MODE: disable` to Gitea values, manual `ALTER ROLE` to sync password. Removed `managed.roles` from CNPG cluster CRD to prevent reconciliation conflicts  
**Files:** `platform/devtools/gitea/values.yaml`, `platform/storage/cnpg/clusters/gitea-db.yaml`

## 10. Gateway stuck at `<pending>` — no external IP

**Symptom:** `util-gateway LoadBalancer <pending>`  
**Cause:** IPAddressPool was never created (failed in issues #1 and #2)  
**Fix:** Fixed subnet detection and webhook wait, applied IPAddressPool manually  
**File:** `bootstrap/bootstrap.sh`, `infra/overlays/kind/metallb-config/ipaddresspool.yaml`

## 11. DNS not resolving `*.gitops.lcl`

**Symptom:** `server can't find argocd.gitops.lcl: NXDOMAIN`  
**Cause:** No dnsmasq config for the `gitops.lcl` domain  
**Fix:** Added dnsmasq wildcard entry: `address=/gitops.lcl/172.21.255.200`  
**Manual:** `echo "address=/gitops.lcl/172.21.255.200" | sudo tee /etc/dnsmasq.d/gitops-lcl.conf`

## 12. Gitea values duplicate YAML key

**Symptom:** First `gitea:` config block silently overwritten by second  
**Cause:** Two `gitea:` top-level keys in values.yaml  
**Fix:** Merged into single `gitea:` block with all sub-keys  
**File:** `platform/devtools/gitea/values.yaml`

## 13. Cilium agents stuck in Init:Error

**Symptom:** `dial tcp 10.96.0.1:443: i/o timeout` — Cilium can't reach API server  
**Cause:** `kubeProxyReplacement: true` disables kube-proxy, but Cilium needs the API server IP to bootstrap (can't use service IP without kube-proxy)  
**Fix:** Auto-detect control-plane container IP, pass via `--set k8sServiceHost=<IP> --set k8sServicePort=6443`  
**Files:** `bootstrap/bootstrap.sh`, `infra/overlays/kind/cilium-values.yaml`

## Prevention

These issues are now fixed in the codebase. A fresh `kind-create.sh` + `bootstrap.sh` should work without manual intervention. Key lessons:

- **Always wait for webhooks** before applying CRs that use validating/mutating webhooks
- **Disable NetworkPolicies** in dev/Kind clusters unless explicitly needed
- **Auto-detect** cluster-specific values (subnet, control-plane IP, admin username) rather than hardcoding
- **CNPG password management** is nuanced — the bootstrap secret sets the owner during `initdb`, but subsequent password changes should go through CNPG's managed roles or be set via `ALTER ROLE` post-init
