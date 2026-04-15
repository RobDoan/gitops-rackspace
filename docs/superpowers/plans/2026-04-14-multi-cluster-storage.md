# Multi-Cluster Storage and App Configuration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor Qdrant, Grafana, and n8n into a Base + Overlays structure to support `rackspace` (SSD storage) and `homelander` (local-path storage) clusters.

**Architecture:** App-Centric Overlays using Kustomize. Each app will have a `base/` directory for common config and `overlays/` for cluster-specific patches.

**Tech Stack:** FluxCD, Kustomize, Kubernetes.

---

### Task 1: Refactor Qdrant to Base + Overlays

**Files:**
- Create: `apps/qdrant/base/kustomization.yaml`, `apps/qdrant/overlays/rackspace/kustomization.yaml`, `apps/qdrant/overlays/rackspace/patches.yaml`, `apps/qdrant/overlays/homelander/kustomization.yaml`, `apps/qdrant/overlays/homelander/patches.yaml`
- Modify: `apps/qdrant/base/helmrelease.yaml`, `apps/qdrant/base/ingress.yaml`
- Delete: `apps/qdrant/*.yaml` (after moving to base)

- [ ] **Step 1: Move existing Qdrant files to base**

```bash
mkdir -p apps/qdrant/base
mv apps/qdrant/*.yaml apps/qdrant/base/
```

- [ ] **Step 2: Update base HelmRelease and Ingress**
Remove cluster-specific storage and hostnames.

`apps/qdrant/base/helmrelease.yaml`:
```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: qdrant
  namespace: qdrant
spec:
  interval: 30m
  timeout: 5m
  chart:
    spec:
      chart: qdrant
      version: ">=0.9.0 <2.0.0"
      sourceRef:
        kind: HelmRepository
        name: qdrant
        namespace: flux-system
  install:
    remediation:
      retries: 3
  values:
    replicaCount: 1
    persistence:
      accessModes:
        - ReadWriteOnce
      size: 20Gi
    extraEnvVars:
      - name: QDRANT__SERVICE__API_KEY
        valueFrom:
          secretKeyRef:
            name: qdrant-secrets
            key: api-key
```

`apps/qdrant/base/ingress.yaml`:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: qdrant
  namespace: qdrant
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - qdrant.example.com
      secretName: qdrant-tls
  rules:
    - host: qdrant.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: qdrant
                port:
                  number: 6333
```

- [ ] **Step 3: Create Rackspace overlay**

`apps/qdrant/overlays/rackspace/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
patches:
  - path: patches.yaml
    target:
      kind: HelmRelease
      name: qdrant
  - path: patches.yaml
    target:
      kind: Ingress
      name: qdrant
```

`apps/qdrant/overlays/rackspace/patches.yaml`:
```yaml
- op: add
  path: /spec/values/persistence/storageClassName
  value: ssd
- op: replace
  path: /spec/tls/0/hosts/0
  value: qdrant.quybits.com
- op: replace
  path: /spec/rules/0/host
  value: qdrant.quybits.com
```

- [ ] **Step 4: Create Homelander overlay**

`apps/qdrant/overlays/homelander/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
patches:
  - path: patches.yaml
    target:
      kind: HelmRelease
      name: qdrant
  - path: patches.yaml
    target:
      kind: Ingress
      name: qdrant
```

`apps/qdrant/overlays/homelander/patches.yaml`:
```yaml
- op: add
  path: /spec/values/persistence/storageClassName
  value: local-path
- op: replace
  path: /spec/tls/0/hosts/0
  value: qdrant.homelander.local
- op: replace
  path: /spec/rules/0/host
  value: qdrant.homelander.local
```

- [ ] **Step 5: Run Kustomize build to verify**
Run: `kustomize build apps/qdrant/overlays/rackspace` and `kustomize build apps/qdrant/overlays/homelander`
Expected: Output contains correct storageClassName and hostnames for each cluster.

- [ ] **Step 6: Commit**

```bash
git add apps/qdrant
git commit -m "refactor: move qdrant to base/overlay structure"
```

---

### Task 2: Refactor Grafana to Base + Overlays

**Files:**
- Create: `apps/grafana/base/kustomization.yaml`, `apps/grafana/overlays/rackspace/kustomization.yaml`, `apps/grafana/overlays/rackspace/patches.yaml`, `apps/grafana/overlays/homelander/kustomization.yaml`, `apps/grafana/overlays/homelander/patches.yaml`
- Modify: `apps/grafana/base/helmrelease.yaml`, `apps/grafana/base/ingress.yaml`
- Delete: `apps/grafana/*.yaml`

- [ ] **Step 1: Move existing Grafana files to base**
```bash
mkdir -p apps/grafana/base
mv apps/grafana/*.yaml apps/grafana/base/
```

- [ ] **Step 2: Update base HelmRelease and Ingress**
Strip SSD and hostname.

`apps/grafana/base/helmrelease.yaml`:
```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: grafana
  namespace: grafana
spec:
  interval: 30m
  timeout: 5m
  chart:
    spec:
      chart: grafana
      version: ">=7.0.0 <8.0.0"
      sourceRef:
        kind: HelmRepository
        name: grafana
        namespace: flux-system
  install:
    remediation:
      retries: 3
  values:
    persistence:
      enabled: true
      size: 5Gi
    admin:
      existingSecret: grafana-secrets
      userKey: admin-user
      passwordKey: admin-password
    grafana.ini:
      server:
        root_url: "https://grafana.example.com"
```

- [ ] **Step 3: Create overlays (Rackspace & Homelander)**
Repeat the pattern from Task 1, patching `storageClassName` and hostnames.

- [ ] **Step 4: Verify and Commit**
```bash
git add apps/grafana
git commit -m "refactor: move grafana to base/overlay structure"
```

---

### Task 3: Refactor n8n to Base + Overlays

**Files:**
- Create: `apps/n8n/base/kustomization.yaml`, `apps/n8n/overlays/rackspace/kustomization.yaml`, `apps/n8n/overlays/rackspace/patches.yaml`, `apps/n8n/overlays/homelander/kustomization.yaml`, `apps/n8n/overlays/homelander/patches.yaml`
- Modify: `apps/n8n/base/helmrelease.yaml`, `apps/n8n/base/ingress.yaml`

- [ ] **Step 1: Refactor n8n following the same pattern**
Ensure `extraEnv.WEBHOOK_URL` and `N8N_EDITOR_BASE_URL` are patched in `HelmRelease`.

---

### Task 4: Setup Homelander Cluster and Update Rackspace

**Files:**
- Create: `clusters/homelander/` (copy from rackspace, update paths)
- Modify: `clusters/rackspace/qdrant.yaml`, `clusters/rackspace/grafana.yaml`, `clusters/rackspace/n8n.yaml`

- [ ] **Step 1: Update Rackspace cluster to point to overlays**
Update `path` in `qdrant.yaml`, `grafana.yaml`, and `n8n.yaml`.

Example `clusters/rackspace/qdrant.yaml`:
```yaml
spec:
  path: ./apps/qdrant/overlays/rackspace
```

- [ ] **Step 2: Create Homelander cluster directory**
```bash
cp -r clusters/rackspace clusters/homelander
```

- [ ] **Step 3: Update Homelander paths to point to overlays**
Update `path: ./apps/.../overlays/homelander` in all app yaml files in `clusters/homelander/`.

- [ ] **Step 4: Final verification and commit**
Check all cluster files.
```bash
git add clusters
git commit -m "feat: setup homelander cluster and update rackspace to use app overlays"
```
