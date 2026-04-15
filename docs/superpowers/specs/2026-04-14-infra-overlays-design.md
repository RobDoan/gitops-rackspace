# Design: Infrastructure Overlays for Multi-Cluster Support

## 1. Goal

Extend the base + overlay pattern (already applied to apps) to infrastructure components that have cluster-specific configuration: **Vault** and **cert-manager-issuers**. Also disable K3s's default Traefik ingress on homelander so ingress-nginx is the sole ingress controller across both clusters.

## 2. Scope

### In scope
- Vault: base + overlays (storageClass, ingress hostname)
- cert-manager-issuers: overlays with entirely different ClusterIssuer resources per cluster
- Disable Traefik on K3s homelander cluster
- Update cluster Kustomization paths for vault and cert-manager-issuers
- Blog post explaining self-signed certs and Traefik decision

### Out of scope
- ingress-nginx (already cluster-agnostic)
- cert-manager operator (same across clusters)
- external-secrets / eso-store (same in-cluster Vault pattern)
- App overlays (already complete)

## 3. Traefik Disable

K3s ships Traefik as the default ingress controller. All existing Ingress manifests use `ingressClassName: nginx`. Running both controllers causes port conflicts on 80/443.

**Action:** Add `disable: [traefik]` to `/etc/rancher/k3s/config.yaml` on the server node (jarvis), then restart K3s. Agent nodes need no changes. This is a manual step, not managed by Flux.

## 4. Vault — Base + Overlays

### Directory Structure
```
infrastructure/vault/
├── base/
│   ├── kustomization.yaml
│   ├── helmrepository.yaml
│   ├── helmrelease.yaml        # storageClass removed, placeholder hostname
│   ├── ingress.yaml            # vault.example.com placeholder
│   ├── bootstrap-rbac.yaml
│   └── bootstrap-job.yaml
└── overlays/
    ├── rackspace/
    │   ├── kustomization.yaml
    │   ├── helmrelease-patch.yaml   # storageClass: ssd
    │   └── ingress-patch.yaml       # vault.quybits.com
    └── homelander/
        ├── kustomization.yaml
        ├── helmrelease-patch.yaml   # storageClass: local-path
        └── ingress-patch.yaml       # vault.homelander.local
```

### Base HelmRelease changes
- Remove `storageClass: ssd` from `server.dataStorage`
- Ingress base uses `vault.example.com` as placeholder

### Overlay patches
- Rackspace: `storageClass: ssd`, hostname `vault.quybits.com`
- Homelander: `storageClass: local-path`, hostname `vault.homelander.local`

## 5. cert-manager-issuers — Overlay-Only

Rackspace and homelander need entirely different ClusterIssuer resources (not just patched fields), so each overlay provides its own issuer file.

### Directory Structure
```
infrastructure/cert-manager-issuers/
├── base/
│   └── kustomization.yaml          # empty, no shared resources
└── overlays/
    ├── rackspace/
    │   ├── kustomization.yaml
    │   └── clusterissuer.yaml       # Let's Encrypt ACME HTTP-01
    └── homelander/
        ├── kustomization.yaml
        └── clusterissuer.yaml       # Self-signed CA chain
```

### Rackspace ClusterIssuer
Existing Let's Encrypt prod issuer, unchanged.

### Homelander ClusterIssuer — Self-Signed CA Chain
Three resources in one file:
1. **selfsigned-bootstrap** ClusterIssuer — bootstraps the CA certificate
2. **homelander-ca** Certificate — root CA cert (10-year duration, in cert-manager namespace)
3. **letsencrypt-prod** ClusterIssuer (CA type) — issues app certs using the root CA

The CA issuer is deliberately named `letsencrypt-prod` so all existing Ingress annotations (`cert-manager.io/cluster-issuer: letsencrypt-prod`) work without app-level changes.

## 6. Cluster Path Updates

| Cluster | Component | New path |
|---------|-----------|----------|
| rackspace | vault | `./infrastructure/vault/overlays/rackspace` |
| rackspace | cert-manager-issuers | `./infrastructure/cert-manager-issuers/overlays/rackspace` |
| homelander | vault | `./infrastructure/vault/overlays/homelander` |
| homelander | cert-manager-issuers | `./infrastructure/cert-manager-issuers/overlays/homelander` |

## 7. Blog Post

File: `docs/blog/self-signed-certs-homelab.md`

Covers:
- Why disable Traefik on K3s (controller conflicts, consistency)
- What self-signed certs are, when to use them
- How cert-manager CA chain works (bootstrap → CA cert → CA issuer)
- The naming trick for cluster-agnostic apps
- Practical homelab context

## 8. Success Criteria

- `kustomize build` succeeds for all vault and cert-manager-issuers overlays
- Rackspace cluster paths updated, existing deployment unaffected
- Homelander cluster paths point to homelander overlays
- Apps require zero changes (verified by existing overlay builds still passing)
- Blog post committed
