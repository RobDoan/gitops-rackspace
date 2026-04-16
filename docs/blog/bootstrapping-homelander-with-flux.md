# Bootstrapping Homelander with Flux: Every Problem I Hit and How I Fixed It

After building out the [multi-cluster GitOps repo structure](./multi-cluster-gitops-journey.md), it was time to actually bootstrap Flux on the homelander cluster. The overlays were written, the base manifests were tested, and I expected a clean `flux bootstrap` followed by a working cluster. Instead, I spent an evening debugging a chain of failures — each one caused by the previous one, and none of them obvious from the error messages alone.

This post documents every issue I hit, in the order I hit them, and how I fixed each one.

---

## 1. GitHub Token Permissions

The very first `flux bootstrap` command failed immediately:

```
GET https://api.github.com/repos/RobDoan/gitops-rackspace/keys: 403
Resource not accessible by personal access token
```

Flux needs to create deploy keys on the GitHub repo. My personal access token didn't have the right permissions.

### The Fix

For a **fine-grained token**, you need:
- **Administration**: Read and write (for deploy keys)
- **Contents**: Read and write

For a **classic token**, the full `repo` scope must be checked.

After updating the token:

```bash
export GITHUB_TOKEN=<updated-token>
```

---

## 2. SSH Authentication Failure

Even with the correct token permissions, the next error was:

```
ssh: handshake failed: ssh: unable to authenticate,
attempted methods [none publickey], no supported methods remain
```

Flux defaults to SSH for cloning the Git repository. The deploy key setup was failing silently, and the SSH handshake couldn't authenticate.

### The Fix

Switch to HTTPS with the `--token-auth` flag:

```bash
flux bootstrap github \
  --owner=${GITHUB_USER} \
  --repository=gitops-rackspace \
  --branch=main \
  --path=./clusters/homelander \
  --personal --token-auth
```

This tells Flux to clone over HTTPS using the `GITHUB_TOKEN` instead of SSH deploy keys. Bootstrap completed successfully after this.

---

## 3. PVCs Stuck Pending — Storage Class Mismatch

After bootstrap, most kustomizations applied, but several HelmReleases failed. The first clue was Vault:

```bash
kubectl get pvc -n vault
# NAME           STATUS    STORAGECLASS   AGE
# data-vault-0   Pending   ssd            5h
```

The homelander cluster only has the `local-path` storage class (K3s default). There is no `ssd` class — that's a Rackspace thing. The PVC sat in `Pending` forever, waiting for a provisioner that would never come.

But here's the confusing part: the homelander overlay **correctly** specifies `storageClass: local-path`. So why was the PVC using `ssd`?

It turned out this was a **previous bootstrap attempt** that had pointed to the wrong overlay. The PVCs were created with `ssd`, and since **PVC specs are immutable after creation**, even after fixing the overlay path, Helm couldn't update the `storageClassName` field:

```
PersistentVolumeClaim "grafana" is invalid: spec: Forbidden:
spec is immutable after creation except resources.requests
```

### The Fix

Delete the stale PVCs and let them be recreated with the correct storage class:

```bash
# Vault (StatefulSet — need to delete pod too)
kubectl delete pvc data-vault-0 -n vault
kubectl delete pod vault-0 -n vault

# Qdrant (also a StatefulSet)
kubectl delete pvc qdrant-storage-qdrant-0 -n qdrant
kubectl delete pod qdrant-0 -n qdrant

# Grafana (Deployment — PVC just needs deleting)
kubectl delete pvc grafana -n grafana
```

After deletion, the pods recreated with the correct `local-path` storage class and the PVCs bound successfully.

---

## 4. The Cascade: Vault Down Breaks Everything

This was the most time-consuming issue to untangle, because the symptoms appeared in Grafana, Qdrant, and n8n — but the root cause was Vault.

The dependency chain:

```
Vault (Pending) 
  → ClusterSecretStore "vault-backend" (InvalidProviderConfig)
    → ExternalSecrets can't fetch secrets
      → Grafana, Qdrant, n8n missing credentials
        → Pods fail to start or operate correctly
```

The `ClusterSecretStore` error was:

```
cannot get Kubernetes secret "vault-approle-credentials"
from namespace "external-secrets": secrets not found
```

This made sense — the `vault-bootstrap` job creates the AppRole credentials, but it couldn't run because Vault itself was stuck on the `ssd` PVC.

### The Fix

Fix Vault first. Everything else follows:

1. Delete the Vault PVC (as shown above)
2. Initialize and unseal Vault:
   ```bash
   kubectl exec -n vault vault-0 -- vault operator init \
     -key-shares=1 -key-threshold=1 -format=json > vault-init-homelander.json
   kubectl exec -n vault vault-0 -- vault operator unseal <key>
   ```
3. Create the root token secret and run the bootstrap job:
   ```bash
   kubectl create secret generic vault-root-token -n vault \
     --from-literal=token=<root-token>
   kubectl delete job vault-bootstrap -n vault --ignore-not-found
   flux reconcile kustomization vault
   ```
4. The bootstrap job enables the KV engine, configures AppRole auth, and creates the `vault-approle-credentials` secret in the `external-secrets` namespace.
5. Once the secret exists, the `ClusterSecretStore` becomes `Valid` and `Ready`.
6. ExternalSecrets start syncing, and the apps get their credentials.

---

## 5. Helm Release Cached Failures

Even after fixing the PVCs and Vault, Grafana's HelmRelease was stuck showing the old error:

```
Helm upgrade failed: PersistentVolumeClaim "grafana" is invalid: spec: Forbidden
```

The PVC was already gone, but Helm's release history still contained the failed revision. Flux kept retrying the upgrade against the broken history and failing.

Suspending and resuming the HelmRelease didn't help — Helm's internal state was corrupted.

### The Fix

Clear the Helm release history and let Flux do a fresh install:

```bash
# Delete all Helm release secrets for Grafana
kubectl delete secret -n grafana -l owner=helm,name=grafana

# Delete the stuck pod
kubectl delete pod -n grafana -l app.kubernetes.io/name=grafana --force

# Force Flux to reconcile — it will do a fresh install
flux reconcile helmrelease grafana -n grafana --force
```

This worked. Helm treated it as a new install, created the PVC with the correct `local-path` storage class, and the pod came up healthy.

---

## 6. Cleanup Script

After going through this process, I wrote a cleanup script (`scripts/flux-cleanup.sh`) to make it easy to tear down and retry:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Step 1: Uninstall Flux
flux uninstall --silent

# Step 2: Delete flux-system namespace
kubectl delete namespace flux-system --timeout=60s

# Step 3: Delete all pods (excluding kube-system, with confirmation)
read -r -p "Delete all pods in all namespaces? [y/N]: " response
if [[ "$response" =~ ^[Yy]$ ]]; then
  for ns in $(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}'); do
    [[ "$ns" == "kube-system" ]] && continue
    kubectl delete pods --all -n "$ns" --grace-period=30
  done
fi
```

And updated the Vault unseal script (`scripts/vault-unseal.sh`) to support both clusters:

```bash
# Unseal only
./scripts/vault-unseal.sh rackspace
./scripts/vault-unseal.sh homelander

# Unseal + full bootstrap (AppRole, KV engine, placeholder secrets)
./scripts/vault-unseal.sh homelander --bootstrap
```

---

## Key Takeaways

1. **PVCs are immutable.** If you bootstrap with the wrong storage class, you can't just fix the overlay and reconcile. You have to delete the PVC and let it be recreated. This is the single most common issue when switching between clusters or overlays.

2. **Understand your dependency chain.** When multiple things fail at once, find the root cause. In my case, every failure traced back to Vault being down. Fixing Vault fixed everything downstream.

3. **Helm release history can get corrupted.** When a Helm upgrade fails and the underlying resource is fixed, Helm may still refuse to retry. Deleting the release secrets (`sh.helm.release.v1.<name>.v*`) forces a clean install.

4. **Use `--token-auth` for Flux bootstrap.** SSH deploy keys require the `Administration` permission on the repo, which fine-grained tokens handle awkwardly. HTTPS with `--token-auth` is simpler and avoids the SSH handshake issues entirely.

5. **Each Vault instance needs its own init.** You can't reuse `vault-init.json` across clusters. Each Vault has unique encryption keys generated at initialization time.

6. **Script your recovery path.** After manually fixing things once, write it down. The cleanup script and multi-cluster unseal script saved time on subsequent attempts.
