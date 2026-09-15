# Which Kubernetes identity is the API server seeing?
kubectl auth whoami

# Include username, UID, groups and OIDC attributes
kubectl auth whoami -o yaml




# List everything you are authorised to do in a namespace
kubectl auth can-i --list -n tenant-a

# Test individual operations
kubectl auth can-i get pods -n tenant-a
kubectl auth can-i create deployments.apps -n tenant-a
kubectl auth can-i delete pods -n tenant-a
kubectl auth can-i get nodes



# Read pod logs
kubectl auth can-i get pods --subresource=log -n tenant-a

# Execute commands inside pods
kubectl auth can-i create pods --subresource=exec -n tenant-a

# Scale deployments
kubectl auth can-i update deployments.apps --subresource=scale -n tenant-a


#Check broad administrative access:
kubectl auth can-i '*' '*' --all-namespaces

# Test another user or service account:
kubectl auth can-i create pods --as=adura@example.com -n tenant-a

kubectl auth can-i list pods --as=system:serviceaccount:forge4x-system:forge4x-ui -n tenant-a

# You must have Kubernetes impersonation permission to use --as. Kubernetes can-i reference

# For scripts, use --quiet and the exit code:
if kubectl auth can-i create deployments -n tenant-a --quiet; then
    echo "Allowed"
else
    echo "Denied"
fi




# 2. Configure the Kubernetes API server
# For Kubernetes 1.34+, use the stable structured authentication configuration.

# /etc/kubernetes/authentication-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AuthenticationConfiguration

jwt:
  - issuer:
      url: https://sso.forge4x.example/realms/forge4x
      audiences:
        - forge4x-prod-k8s

    claimMappings:
      username:
        claim: preferred_username
        prefix: "oidc:"

      groups:
        claim: groups
        prefix: "oidc:"

      uid:
        claim: sub

    userValidationRules:
      - expression: "!user.username.startsWith('system:')"
        message: "OIDC username cannot use the reserved system prefix"

      - expression: "user.groups.all(group, !group.startsWith('system:'))"
        message: "OIDC groups cannot use the reserved system prefix"

Mount this file into every API-server instance and add:

--authentication-config=/etc/kubernetes/authentication-config.yaml







# 1. Groups referenced by Kubernetes RBAC
# This lists all group names used in RoleBinding and ClusterRoleBinding resources:
kubectl get rolebindings,clusterrolebindings -A -o jsonpath='{range .items[*]}{range .subjects[?(@.kind=="Group")]}{.name}{"\n"}{end}{end}' | sort -u



# To show each group together with its binding and granted role, using jq:
kubectl get rolebindings,clusterrolebindings -A -o json |
jq -r '
  .items[] as $binding
  | ($binding.subjects // [])[]
  | select(.kind == "Group")
  | [
      ($binding.metadata.namespace // "cluster-wide"),
      $binding.kind,
      $binding.metadata.name,
      .name,
      $binding.roleRef.name
    ]
  | @tsv
' |
sort -u

# The columns are:
scope    binding-kind    binding-name    group    role


# 2. Groups assigned to your current OIDC identity
kubectl auth whoami

# Groups only:
kubectl auth whoami -o jsonpath='{range .status.userInfo.groups[*]}{.}{"\n"}{end}'

# Example:
oidc:tenant-acme-developers
oidc:tenant-acme-viewers
system:authenticated

