# Infrastructure Overlays Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add base + overlay structure to Vault and cert-manager-issuers infrastructure, disable Traefik on K3s, and write a blog post explaining self-signed certs and the Traefik decision.

**Architecture:** Infrastructure components with cluster-specific config get the same base/overlay Kustomize pattern already used by apps. cert-manager-issuers uses overlay-only (no shared base resources) since the two clusters need entirely different ClusterIssuer resources. Vault uses standard base + patch overlays.

**Tech Stack:** FluxCD, Kustomize, cert-manager, HashiCorp Vault, K3s.

---

### Task 1: Refactor Vault to Base + Overlays

**Files:**

- Create: `infrastructure/vault/base/kustomization.yaml`
- Move to base: `infrastructure/vault/helmrepository.yaml`, `infrastructure/vault/helmrelease.yaml`, `infrastructure/vault/ingress.yaml`, `infrastructure/vault/bootstrap-rbac.yaml`, `infrastructure/vault/bootstrap-job.yaml`
- Modify: `infrastructure/vault/base/helmrelease.yaml` (strip storageClass)
- Modify: `infrastructure/vault/base/ingress.yaml` (placeholder hostname)
- Create: `infrastructure/vault/overlays/rackspace/kustomization.yaml`
- Create: `infrastructure/vault/overlays/rackspace/helmrelease-patch.yaml`
- Create: `infrastructure/vault/overlays/rackspace/ingress-patch.yaml`
- Create: `infrastructure/vault/overlays/homelander/kustomization.yaml`
- Create: `infrastructure/vault/overlays/homelander/helmrelease-patch.yaml`
- Create: `infrastructure/vault/overlays/homelander/ingress-patch.yaml`

- [ ] **Step 1: Move existing Vault files to base**

```bash
mkdir -p infrastructure/vault/base infrastructure/vault/overlays/rackspace infrastructure/vault/overlays/homelander
mv infrastructure/vault/helmrepository.yaml infrastructure/vault/helmrelease.yaml infrastructure/vault/ingress.yaml infrastructure/vault/bootstrap-rbac.yaml infrastructure/vault/bootstrap-job.yaml infrastructure/vault/base/
mv infrastructure/vault/kustomization.yaml infrastructure/vault/base/kustomization.yaml
```

- [ ] **Step 2: Update base kustomization.yaml to include bootstrap-job**

The existing kustomization.yaml does not include `bootstrap-job.yaml`. Add it.

`infrastructure/vault/base/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - helmrepository.yaml
  - helmrelease.yaml
  - bootstrap-rbac.yaml
  - bootstrap-job.yaml
  - ingress.yaml
```

- [ ] **Step 3: Strip cluster-specific values from base HelmRelease**

In `infrastructure/vault/base/helmrelease.yaml`, remove the `storageClass: ssd` line (line 47). The field `storageClass` under `server.dataStorage` should be removed, keeping the rest of `dataStorage` intact.

Before:

```yaml
      dataStorage:
        enabled: true
        size: 10Gi
        storageClass: ssd
        accessMode: ReadWriteOnce
```

After:

```yaml
      dataStorage:
        enabled: true
        size: 10Gi
        accessMode: ReadWriteOnce
```

- [ ] **Step 4: Set placeholder hostname in base Ingress**

In `infrastructure/vault/base/ingress.yaml`, replace all occurrences of `vault.quybits.com` with `vault.example.com`.

- [ ] **Step 5: Create Rackspace overlay**

`infrastructure/vault/overlays/rackspace/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
patches:
  - path: helmrelease-patch.yaml
  - path: ingress-patch.yaml
```

`infrastructure/vault/overlays/rackspace/helmrelease-patch.yaml`:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: vault
  namespace: vault
spec:
  values:
    server:
      dataStorage:
        storageClass: ssd
```

`infrastructure/vault/overlays/rackspace/ingress-patch.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: vault
  namespace: vault
spec:
  tls:
    - hosts:
        - vault.quybits.com
      secretName: vault-tls
  rules:
    - host: vault.quybits.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: vault-ui
                port:
                  number: 8200
```

- [ ] **Step 6: Create Homelander overlay**

`infrastructure/vault/overlays/homelander/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
patches:
  - path: helmrelease-patch.yaml
  - path: ingress-patch.yaml
```

`infrastructure/vault/overlays/homelander/helmrelease-patch.yaml`:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: vault
  namespace: vault
spec:
  values:
    server:
      dataStorage:
        storageClass: local-path
```

`infrastructure/vault/overlays/homelander/ingress-patch.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: vault
  namespace: vault
spec:
  tls:
    - hosts:
        - vault.homelander.local
      secretName: vault-tls
  rules:
    - host: vault.homelander.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: vault-ui
                port:
                  number: 8200
```

- [ ] **Step 7: Verify with kustomize build**

Run: `kubectl kustomize infrastructure/vault/overlays/rackspace`

Expected: Output contains `storageClass: ssd` and `vault.quybits.com`.

Run: `kubectl kustomize infrastructure/vault/overlays/homelander`

Expected: Output contains `storageClass: local-path` and `vault.homelander.local`.

- [ ] **Step 8: Commit**

```bash
git add infrastructure/vault
git commit -m "refactor: move vault to base/overlay structure for multi-cluster"
```

---

### Task 2: Refactor cert-manager-issuers to Overlays

**Files:**

- Create: `infrastructure/cert-manager-issuers/base/kustomization.yaml`
- Create: `infrastructure/cert-manager-issuers/overlays/rackspace/kustomization.yaml`
- Move: `infrastructure/cert-manager-issuers/clusterissuer.yaml` → `infrastructure/cert-manager-issuers/overlays/rackspace/clusterissuer.yaml`
- Create: `infrastructure/cert-manager-issuers/overlays/homelander/kustomization.yaml`
- Create: `infrastructure/cert-manager-issuers/overlays/homelander/clusterissuer.yaml`
- Delete: `infrastructure/cert-manager-issuers/kustomization.yaml` (replaced by base)

- [ ] **Step 1: Create directory structure and move files**

```bash
mkdir -p infrastructure/cert-manager-issuers/base infrastructure/cert-manager-issuers/overlays/rackspace infrastructure/cert-manager-issuers/overlays/homelander
mv infrastructure/cert-manager-issuers/clusterissuer.yaml infrastructure/cert-manager-issuers/overlays/rackspace/clusterissuer.yaml
rm infrastructure/cert-manager-issuers/kustomization.yaml
```

- [ ] **Step 2: Create empty base kustomization**

`infrastructure/cert-manager-issuers/base/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
```

- [ ] **Step 3: Create Rackspace overlay kustomization**

`infrastructure/cert-manager-issuers/overlays/rackspace/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
  - clusterissuer.yaml
```

The `clusterissuer.yaml` was already moved here in Step 1. Its contents (Let's Encrypt ACME HTTP-01) remain unchanged:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@quybits.com
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
```

- [ ] **Step 4: Create Homelander overlay with self-signed CA chain**

`infrastructure/cert-manager-issuers/overlays/homelander/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
  - clusterissuer.yaml
```

`infrastructure/cert-manager-issuers/overlays/homelander/clusterissuer.yaml`:

```yaml
# Step 1: Bootstrap issuer (self-signed, only used to create the CA cert)
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-bootstrap
spec:
  selfSigned: {}
---
# Step 2: Root CA certificate (issued by the bootstrap issuer, 10-year duration)
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: homelander-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: homelander-ca
  secretName: homelander-ca-secret
  duration: 87600h
  renewBefore: 8760h
  issuerRef:
    name: selfsigned-bootstrap
    kind: ClusterIssuer
    group: cert-manager.io
---
# Step 3: CA issuer that signs all app certs using the root CA.
# Named "letsencrypt-prod" so existing Ingress annotations work unchanged.
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  ca:
    secretName: homelander-ca-secret
```

- [ ] **Step 5: Verify with kustomize build**

Run: `kubectl kustomize infrastructure/cert-manager-issuers/overlays/rackspace`

Expected: Output contains `letsencrypt-prod` ClusterIssuer with `acme` spec.

Run: `kubectl kustomize infrastructure/cert-manager-issuers/overlays/homelander`

Expected: Output contains `selfsigned-bootstrap` ClusterIssuer, `homelander-ca` Certificate, and `letsencrypt-prod` ClusterIssuer with `ca` spec.

- [ ] **Step 6: Commit**

```bash
git add infrastructure/cert-manager-issuers
git commit -m "refactor: move cert-manager-issuers to overlay structure with self-signed CA for homelander"
```

---

### Task 3: Update Cluster Kustomization Paths

**Files:**

- Modify: `clusters/rackspace/vault.yaml`
- Modify: `clusters/rackspace/cert-manager-issuers.yaml`
- Modify: `clusters/homelander/vault.yaml`
- Modify: `clusters/homelander/cert-manager-issuers.yaml`

- [ ] **Step 1: Update rackspace cluster paths**

In `clusters/rackspace/vault.yaml`, change:

```yaml
  path: ./infrastructure/vault
```

to:

```yaml
  path: ./infrastructure/vault/overlays/rackspace
```

In `clusters/rackspace/cert-manager-issuers.yaml`, change:

```yaml
  path: ./infrastructure/cert-manager-issuers
```

to:

```yaml
  path: ./infrastructure/cert-manager-issuers/overlays/rackspace
```

- [ ] **Step 2: Update homelander cluster paths**

In `clusters/homelander/vault.yaml`, change:

```yaml
  path: ./infrastructure/vault
```

to:

```yaml
  path: ./infrastructure/vault/overlays/homelander
```

In `clusters/homelander/cert-manager-issuers.yaml`, change:

```yaml
  path: ./infrastructure/cert-manager-issuers
```

to:

```yaml
  path: ./infrastructure/cert-manager-issuers/overlays/homelander
```

- [ ] **Step 3: Verify all cluster kustomizations build**

Run: `kubectl kustomize clusters/rackspace`

Expected: Builds without errors, contains rackspace-specific vault and issuer config.

Run: `kubectl kustomize clusters/homelander`

Expected: Builds without errors, contains homelander-specific vault and issuer config.

- [ ] **Step 4: Commit**

```bash
git add clusters/rackspace/vault.yaml clusters/rackspace/cert-manager-issuers.yaml clusters/homelander/vault.yaml clusters/homelander/cert-manager-issuers.yaml
git commit -m "feat: update cluster paths to use infrastructure overlays"
```

---

### Task 4: Write Blog Post

**Files:**

- Create: `docs/blog/self-signed-certs-homelab.md`

- [ ] **Step 1: Write the blog post**

`docs/blog/self-signed-certs-homelab.md`:

The blog post should cover these sections:

1. **Introduction** — Running multiple K8s clusters (cloud + homelab) with shared GitOps config
2. **Why Disable Traefik on K3s** — K3s ships Traefik by default; our manifests use ingress-nginx; running both causes port 80/443 conflicts; consistency across clusters means one ingress controller; how to disable it (`/etc/rancher/k3s/config.yaml`)
3. **The Certificate Problem** — Let's Encrypt needs public domains and reachable HTTP endpoints; `.homelander.local` is private; self-signed certs are the right answer for homelab
4. **How Self-Signed CA Works in cert-manager** — The three-resource chain: bootstrap issuer → CA certificate → CA issuer; why the CA issuer is named `letsencrypt-prod` (apps stay cluster-agnostic)
5. **The Full Picture** — Base + overlay pattern lets apps deploy unchanged to both clusters; only infrastructure differs
6. **Conclusion** — Self-signed certs for homelab, real certs for production, zero app changes

- [ ] **Step 2: Commit**

```bash
git add docs/blog/self-signed-certs-homelab.md
git commit -m "docs: add blog post on self-signed certs and traefik for homelab k8s"
```
