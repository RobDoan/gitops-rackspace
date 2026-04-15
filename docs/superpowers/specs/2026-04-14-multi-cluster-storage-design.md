# Design: Multi-Cluster Storage and App Configuration with Kustomize Overlays

## 1. Goal
Support multiple Kubernetes clusters (`rackspace` and `homelander`) with different infrastructure requirements (storage classes, ingress hostnames) while minimizing configuration duplication.

## 2. Architecture: App-Centric Overlays
We will move from a flat structure in `apps/` to a **Base + Overlays** pattern. This allows each application to define a common "base" and cluster-specific "overlays".

### Directory Structure
```text
apps/<app-name>/
├── base/
│   ├── kustomization.yaml
│   ├── helmrelease.yaml      # Common values, storageClass removed or default
│   ├── helmrepository.yaml   # Repository source
│   ├── externalsecret.yaml   # ExternalSecret definition
│   └── ingress.yaml          # Ingress template
└── overlays/
    ├── rackspace/
    │   ├── kustomization.yaml # Bases: ../../base; Patches: patches.yaml
    │   └── patches.yaml       # SSD storage, rackspace hostnames
    └── homelander/
        ├── kustomization.yaml # Bases: ../../base; Patches: patches.yaml
        └── patches.yaml       # local-path storage, homelander hostnames
```

## 3. Component Details

### Base (`apps/<app-name>/base/`)
- Contains all standard Flux and Kubernetes resources.
- `helmrelease.yaml`: Includes logic shared across all environments (e.g., replica counts, common env vars). Storage and Ingress hosts are omitted or set to common defaults.

### Overlays (`apps/<app-name>/overlays/<cluster-name>/`)
- `kustomization.yaml`: Uses `resources: ["../../base"]` to pull in common config.
- `patches.yaml`: Uses Kustomize JSON patches or strategic merge patches to override specific fields.

#### Example Patch for `homelander` (K3s local-path storage):
```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: qdrant
  namespace: qdrant
spec:
  values:
    persistence:
      storageClassName: local-path
    ingress:
      hosts:
        - host: qdrant.homelander.local
          paths:
            - path: /
              pathType: Prefix
```

## 4. Cluster-Level Configuration
The cluster definitions in `clusters/` will be updated to point to the specific overlay for that cluster.

- `clusters/rackspace/qdrant.yaml` -> `path: ./apps/qdrant/overlays/rackspace`
- `clusters/homelander/qdrant.yaml` -> `path: ./apps/qdrant/overlays/homelander`

## 5. Scope of Work
Refactor the following applications:
1. `qdrant`
2. `grafana`
3. `n8n`

Create the following cluster structure:
1. `clusters/homelander/` (mirrors `clusters/rackspace/` with cluster-specific adjustments)

## 6. Success Criteria
- Applications deploy successfully to both clusters.
- `rackspace` uses `ssd` storage and `*.quybits.com` hostnames.
- `homelander` uses `local-path` storage and `*.homelander.local` (or similar) hostnames.
- No direct duplication of HelmRelease logic across clusters.
