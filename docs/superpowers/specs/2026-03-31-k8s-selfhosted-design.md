# K8s Self-Hosted Services Design
**Date:** 2026-03-31
**Cluster:** Rackspace Kubernetes Engine (RKE)
**Domain:** quybits.com

## Services

| Service | Purpose | Namespace |
|---|---|---|
| n8n | Workflow automation | `n8n` |
| Grafana | Monitoring & dashboards | `grafana` |
| Vault | Secrets management | `vault` |
| Qdrant | Vector database | `qdrant` |

## Architecture Overview

Per-service namespaces with FluxCD GitOps delivery. Helm charts rendered via FluxCD `HelmRelease` resources with Kustomize post-rendering patches for environment-specific overrides. Vault serves as the central secret store; External Secrets Operator (ESO) syncs secrets into each service namespace. All services exposed via NGINX Ingress with TLS from cert-manager (Let's Encrypt).

## Repository Structure

```
rackspace/
├── clusters/
│   └── rackspace/
│       ├── flux-system/          # FluxCD bootstrap output
│       └── kustomization.yaml    # root Flux Kustomization
├── infrastructure/
│   ├── cert-manager/             # HelmRelease + ClusterIssuer
│   ├── ingress-nginx/            # HelmRelease
│   ├── external-secrets/         # HelmRelease (ESO)
│   └── vault/                    # HelmRelease + init Job + ESO ClusterSecretStore
├── apps/
│   ├── n8n/                      # HelmRelease + Kustomize patches + Ingress
│   ├── grafana/                  # HelmRelease + Kustomize patches + Ingress
│   └── qdrant/                   # HelmRelease + Kustomize patches + Ingress
└── namespaces/                   # Namespace manifests for all services
```

Each service directory contains: `helmrelease.yaml`, `values.yaml`, `kustomization.yaml`, and Kustomize patches.

## FluxCD Bootstrap Order

Strict `dependsOn` chain enforced by FluxCD `Kustomization` resources:

```
flux-system
    └── infrastructure/cert-manager          (no deps)
    └── infrastructure/ingress-nginx          (no deps)
    └── infrastructure/external-secrets       (no deps)
    └── infrastructure/vault                  (dependsOn: external-secrets)
    └── infrastructure/eso-clustersecretstore (dependsOn: vault)
    └── apps/grafana                          (dependsOn: eso-clustersecretstore)
    └── apps/qdrant                           (dependsOn: eso-clustersecretstore)
    └── apps/n8n                              (dependsOn: eso-clustersecretstore, qdrant)
```

## Helm Charts

| Service | Chart | Helm Repo |
|---|---|---|
| cert-manager | `cert-manager` | `https://charts.jetstack.io` |
| ingress-nginx | `ingress-nginx` | `https://kubernetes.github.io/ingress-nginx` |
| external-secrets | `external-secrets` | `https://charts.external-secrets.io` |
| vault | `vault` | `https://helm.releases.hashicorp.com` |
| grafana | `grafana` | `https://grafana.github.io/helm-charts` |
| qdrant | `qdrant` | `https://qdrant.github.io/qdrant-helm` |
| n8n | `n8n` | `https://8gears.container-registry.com/chartrepo/library` |

## Persistent Storage

StorageClass: `ssd` (Rackspace Cloud Block Storage, $0.06/GB/month).
Set explicitly via Kustomize patch on all PVCs.

| Service | PVC size | Access mode | Notes |
|---|---|---|---|
| vault | 10Gi | ReadWriteOnce | Raft integrated storage |
| qdrant | 20Gi | ReadWriteOnce | Vector data, latency-sensitive |
| n8n | 5Gi | ReadWriteOnce | Workflow data + SQLite |
| grafana | 2Gi | ReadWriteOnce | Dashboard state |

Vault uses Raft integrated storage (no external Consul/etcd required). Single-node; expandable to HA later.

## Ingress & TLS

NGINX Ingress Controller + cert-manager with Let's Encrypt production ACME (HTTP-01 challenge).

| Service | Hostname |
|---|---|
| n8n | `n8n.quybits.com` |
| grafana | `grafana.quybits.com` |
| vault | `vault.quybits.com` |
| qdrant | `qdrant.quybits.com` |

Each `Ingress` resource annotated with `cert-manager.io/cluster-issuer: letsencrypt-prod`. cert-manager auto-provisions and renews TLS certs as K8s `Secret` resources. No IP restriction applied initially.

## Secrets Flow

```
Vault (AppRole auth)
    └── ClusterSecretStore (ESO, cluster-wide)
            ├── ExternalSecret → n8n namespace    → Secret: n8n-secrets
            ├── ExternalSecret → grafana namespace → Secret: grafana-secrets
            └── ExternalSecret → qdrant namespace  → Secret: qdrant-secrets
```

**Vault secret paths:**

| Service | Vault KV path | Contents |
|---|---|---|
| n8n | `secret/n8n` | encryption key |
| grafana | `secret/grafana` | admin password |
| qdrant | `secret/qdrant` | API key |

## Vault Bootstrap Sequence

Vault requires a one-time manual bootstrap before ESO can function:

1. Flux deploys Vault `HelmRelease` (Raft mode, `ssd` PVC)
2. Operator runs: `vault operator init` → save unseal keys + root token securely
3. Operator runs: `vault operator unseal` (3x with threshold keys)
4. A K8s `Job` in `infrastructure/vault/` is triggered manually after unseal. The Job polls `GET /v1/sys/health` until Vault returns unsealed (HTTP 200), then:
   - Enables KV v2 secrets engine at `secret/`
   - Creates AppRole auth method
   - Creates policies scoped per service
   - Seeds initial secret values at each KV path
   - Writes the AppRole `role-id` and `secret-id` as a K8s `Secret` in the `external-secrets` namespace for ESO to consume
5. ESO `ClusterSecretStore` becomes healthy (references the AppRole K8s Secret)
6. `ExternalSecret` resources sync → K8s Secrets created in each namespace
7. App `HelmRelease` resources (which `dependsOn` ESO store) deploy successfully

## Delivery

**FluxCD** manages all resources declaratively from this git repository. Changes to any manifest are reconciled automatically. Flux bootstrap targets the `clusters/rackspace/` directory.
