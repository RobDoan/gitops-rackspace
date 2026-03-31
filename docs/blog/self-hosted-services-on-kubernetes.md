# Self-Hosting n8n, Grafana, Vault, and Qdrant on Kubernetes with GitOps

I recently went through the process of deploying four self-hosted services on a managed Kubernetes cluster using a fully GitOps-driven approach. This post documents the decisions I made, why I made them, and the real debugging problems I ran into along the way — including a subtle FluxCD race condition that took some digging to understand.

---

## What We're Building

The goal: deploy four open-source services on a single-node Rackspace Kubernetes cluster, reachable via HTTPS at custom subdomains under `quybits.com`, with secrets managed centrally and everything declared in Git.

| Service | Purpose |
|---------|---------|
| **n8n** | Workflow automation |
| **Grafana** | Observability dashboards |
| **Vault** | Central secret store |
| **Qdrant** | Vector database |

---

## Architecture Decisions

Before writing a single YAML file, I had to answer a set of design questions. Here's what I considered for each.

---

### GitOps Tooling: FluxCD vs ArgoCD

Both FluxCD and ArgoCD are mature GitOps tools for Kubernetes, but they have different philosophies.

**ArgoCD** has a rich UI and supports multi-cluster management well. It's opinionated about application structure and works best when you adopt its Application/ApplicationSet model. For teams with multiple clusters and a need for visual dashboards, it's excellent.

**FluxCD** is purely CLI/declarative. It has no built-in UI and follows the Kubernetes-native approach — everything is a CRD. It natively supports Helm, Kustomize, and OCI sources without wrapping them in an Application abstraction.

**Why FluxCD:** For a small single-cluster project, ArgoCD's UI is overhead rather than value. FluxCD composes directly on top of Helm and Kustomize without adding an extra abstraction layer. It's also lighter on cluster resources. The tradeoff is that debugging requires knowing `kubectl` and `flux` CLI well — there's no dashboard to look at. For a solo operator comfortable with the terminal, that's acceptable.

---

### Package Management: Helm + Kustomize vs Pure Helm vs Pure Kustomize

**Pure Helm** would mean writing umbrella charts or using upstream charts as-is. It works well but customizing values per environment requires either value file overrides or chart forking.

**Pure Kustomize** means managing all YAML manually. You get full control but lose access to the ecosystem of upstream Helm charts.

**Helm + Kustomize** lets you pull upstream Helm charts unchanged and use Kustomize patches to handle cluster-specific customization. FluxCD's `HelmRelease` CRD manages Helm chart lifecycle, and Kustomize `Kustomization` CRDs handle ordering and dependencies.

**Why Helm + Kustomize:** All four target services (n8n, Grafana, Vault, Qdrant) have maintained Helm charts. Re-implementing their Kubernetes manifests from scratch would be wasteful. Kustomize handles the overlay layer without requiring chart forking.

---

### Secret Management: Vault + External Secrets Operator vs Kubernetes Secrets vs Sealed Secrets

This was the most consequential decision because it affects every other service.

**Plain Kubernetes Secrets** are base64-encoded, not encrypted at rest by default, and end up in Git if you're not careful. Not suitable for anything beyond a demo.

**Sealed Secrets** (Bitnami) encrypts secrets with a cluster-specific key and stores the sealed form in Git. It's simpler than Vault but secrets are cluster-bound — if you lose the sealing key, you lose the secrets. It also doesn't support dynamic secrets or fine-grained access policies.

**Vault + External Secrets Operator (ESO)** is more complex to set up, but gives you:
- A single place to manage all secrets across services
- Fine-grained access policies per application (n8n can only read its own secrets)
- AppRole authentication so ESO never exposes the root token to workloads
- The ability to rotate secrets without redeploying applications

**Why Vault + ESO:** Even for a small project, having Vault as the canonical secrets source means you only ever update a secret in one place. The ESO `ExternalSecret` CRDs in Git describe *which* secrets to sync, not the secret values themselves — so Git never sees a plaintext credential. The operational overhead of initializing and unsealing Vault is a one-time cost.

**Note on simplicity:** If you want something simpler with less operational overhead, Sealed Secrets is a reasonable choice for a small project where you control the cluster lifecycle. Vault shines when you have multiple applications, need auditing, or plan to rotate credentials regularly.

---

### Ingress: NGINX vs Traefik vs HAProxy

**Traefik** is popular for its automatic Let's Encrypt integration and dynamic configuration from Kubernetes annotations. It's excellent for smaller setups where you want minimal config.

**HAProxy Ingress** is tuned for high-throughput and low-latency scenarios. For a small project it's overspecified.

**NGINX Ingress Controller** is the most widely deployed Kubernetes ingress. It's well-documented, has broad compatibility with cert-manager, and its behavior is predictable and well-understood.

**Why NGINX:** Traefik's built-in ACME is convenient but couples TLS management to the ingress controller. Using cert-manager separately gives finer control over certificate issuance and is the standard approach in the FluxCD ecosystem. NGINX + cert-manager is the most documented combination, which matters when debugging. For a small project, Traefik would be equally valid — the main reason to choose NGINX is ecosystem familiarity.

---

### TLS: cert-manager with Let's Encrypt HTTP-01

cert-manager automates TLS certificate issuance and renewal from Let's Encrypt. HTTP-01 challenge validation requires the ACME server to reach `http://<domain>/.well-known/acme-challenge/...` — which means your ingress must be publicly accessible on port 80.

DNS-01 challenge (an alternative) validates via DNS TXT records and works for wildcard certs and private clusters, but requires API access to your DNS provider.

**Why HTTP-01:** The domains are publicly accessible, no wildcard certs are needed, and HTTP-01 requires no DNS provider API credentials to manage. Simpler.

---

### Storage: Rackspace Cloud Block Storage (Cinder)

The cluster runs on Rackspace, which provides OpenStack Cinder-backed block storage via the `ssd` StorageClass. This maps to Rackspace's SSD cloud block storage volumes.

One important constraint discovered during deployment: **Rackspace Cinder requires PVC sizes between 5 GiB and 20 GiB.** Requesting 2 GiB fails silently with a `BadRequest` from the Cinder API. All PVCs must be sized to at least 5 GiB.

---

## Repository Structure

The GitOps repository is organized around FluxCD's two-layer model:

```
.
├── clusters/
│   └── rackspace/           # Flux Kustomization CRs — one per component
│       ├── kustomization.yaml
│       ├── cert-manager.yaml
│       ├── cert-manager-issuers.yaml   # separate from cert-manager (see below)
│       ├── vault.yaml
│       ├── eso-store.yaml
│       ├── grafana.yaml
│       ├── n8n.yaml
│       └── qdrant.yaml
├── infrastructure/          # Helm charts for platform components
│   ├── cert-manager/
│   ├── cert-manager-issuers/
│   ├── vault/
│   └── eso-store/
└── apps/                    # Helm charts for application services
    ├── grafana/
    ├── n8n/
    └── qdrant/
```

Infrastructure components use `dependsOn` to enforce ordering:

```
namespaces
  └── cert-manager
        └── cert-manager-issuers
              └── vault, ingress-nginx, external-secrets
                    └── eso-store
                          └── grafana, n8n, qdrant
```

---

## Debugging: The cert-manager CRD Race Condition

This was the most interesting problem encountered during deployment. Here's the exact sequence of events and how it was diagnosed.

### The Symptom

After bootstrapping Flux and pushing the initial configuration, running `flux get kustomizations` showed:

```
cert-manager    False   ClusterIssuer/letsencrypt-prod dry-run failed:
                        no matches for kind "ClusterIssuer" in version "cert-manager.io/v1"
```

The cert-manager Kustomization was failing before the HelmRelease could even be applied.

### Understanding the Root Cause

FluxCD's kustomize-controller performs a **server-side dry-run of all resources in a Kustomization before applying any of them**. If any resource fails the dry-run, the entire Kustomization is rejected — including the HelmRelease that would have installed the CRD.

The original `infrastructure/cert-manager/` directory contained both:
- `helmrelease.yaml` — installs cert-manager (which registers the `ClusterIssuer` CRD)
- `clusterissuer.yaml` — creates a `ClusterIssuer` resource (requires the CRD to exist)

This creates a chicken-and-egg problem:
1. Flux dry-runs all resources in the Kustomization
2. The dry-run fails because `ClusterIssuer` CRD doesn't exist yet
3. The Kustomization is rejected — including the HelmRelease
4. cert-manager is never installed
5. The CRD never gets registered
6. The cycle repeats

### The Fix

Split the `ClusterIssuer` into a separate Flux Kustomization with an explicit `dependsOn: cert-manager`:

**Before (broken):**
```
infrastructure/cert-manager/
├── helmrepository.yaml
├── helmrelease.yaml
└── clusterissuer.yaml     ← causes dry-run failure
```

**After (fixed):**
```
infrastructure/cert-manager/
├── helmrepository.yaml
└── helmrelease.yaml

infrastructure/cert-manager-issuers/     ← new directory
└── clusterissuer.yaml
```

And in `clusters/rackspace/`, a new Flux Kustomization CR:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cert-manager-issuers
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 1m
  path: ./infrastructure/cert-manager-issuers
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  dependsOn:
    - name: cert-manager   # only runs after cert-manager HelmRelease is Ready
```

With `dependsOn`, FluxCD waits for cert-manager's HelmRelease to reach `Ready=True` — which means the CRD is registered — before attempting to apply the `ClusterIssuer`.

### Verification Steps

After pushing the fix:

```bash
# 1. Force Flux to pick up the new commit
flux reconcile source git flux-system

# 2. Check Kustomization status
flux get kustomizations

# 3. Verify the CRDs are installed
kubectl get crds | grep cert-manager.io

# 4. Verify ClusterIssuer was created
kubectl get clusterissuer letsencrypt-prod
```

---

## Other Issues Encountered

### cert-manager HelmRelease Install Loop

**Problem:** The `startupapicheck` post-install Job timed out in 5 minutes, causing Helm to uninstall and retry in a loop. Each uninstall removed the CRDs.

**Fix:** Disable `startupapicheck` (it's a health check, not required for function) and increase the HelmRelease timeout:

```yaml
spec:
  timeout: 15m
  values:
    crds:
      enabled: true
    startupapicheck:
      enabled: false
```

Note: `crds.enabled: true` is also required — cert-manager v1.15+ moved CRD installation to a chart value rather than relying on the Helm `crds/` directory. Without this, CRDs are never created even after a successful Helm install.

---

### External Secrets API Version: v1beta1 → v1

**Problem:** After external-secrets v0.20, the `v1beta1` API version was dropped (`served: false`). All resources using `apiVersion: external-secrets.io/v1beta1` failed with:

```
no matches for kind "ClusterSecretStore" in version "external-secrets.io/v1beta1"
```

**Fix:** Update all External Secrets resources to `apiVersion: external-secrets.io/v1`.

Additionally, the `ClusterSecretStore` AppRole auth schema changed between versions:

```yaml
# v1beta1 (old — broken)
auth:
  appRole:
    roleId:
      key: roleId
      name: vault-approle-credentials

# v1 (new — correct)
auth:
  appRole:
    roleRef:
      key: roleId
      name: vault-approle-credentials
```

The field was renamed from `roleId` (SecretKeySelector) to `roleRef` in the v1 schema.

---

### n8n Chart: OCI Registry and Schema Changes

**Problem 1:** The 8gears Helm repository URL (`https://8gears.container-registry.com/chartrepo/library`) returns an HTML page instead of a valid Helm `index.yaml`. The registry is Harbor-based and only serves charts via OCI.

**Fix:** Use `type: oci` in the HelmRepository:

```yaml
spec:
  type: oci
  url: oci://8gears.container-registry.com/library
```

**Problem 2:** The n8n chart v0.25.2 changed the `extraEnv` schema from a list of env var objects to a key-value map:

```yaml
# Old schema (broken with v0.25.2)
extraEnv:
  - name: WEBHOOK_URL
    value: "https://n8n.quybits.com/"
  - name: N8N_ENCRYPTION_KEY
    valueFrom:
      secretKeyRef:
        name: n8n-secrets
        key: encryption-key

# New schema (v0.25.2+)
extraEnv:
  WEBHOOK_URL: "https://n8n.quybits.com/"
extraEnvSecrets:
  N8N_ENCRYPTION_KEY:
    name: n8n-secrets
    key: encryption-key
```

The Helm error `env[name=0].name: expected string, got &value.valueUnstructured{Value:0}` was the signal — the list indices (0, 1, 2) were being interpreted as the `name` field.

---

### Rackspace PVC Minimum Size

**Problem:** Grafana's default PVC size (`2Gi`) was rejected by Rackspace Cinder:

```
'size' parameter must be between 5 and 20
```

**Fix:** Set all PVCs to at least `5Gi`. Rackspace Cloud Block Storage enforces a 5 GiB minimum per volume.

---

## Bootstrap Sequence

After all components are deployed, Vault requires a one-time manual initialization:

```bash
# 1. Initialize Vault (run once, save output securely)
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=3 \
  -key-threshold=2 \
  -format=json > vault-init.json

# 2. Unseal (need 2 of 3 keys — use the unseal script)
./scripts/vault-unseal.sh vault-init.json

# 3. Create the root token secret for the bootstrap job
kubectl create secret generic vault-root-token \
  -n vault \
  --from-literal=token=$(jq -r '.root_token' vault-init.json)

# 4. Run the bootstrap job
kubectl apply -f infrastructure/vault/bootstrap-job.yaml
kubectl logs -n vault job/vault-bootstrap -f
```

The bootstrap job:
- Enables KV v2 secrets engine at `secret/`
- Enables AppRole authentication
- Creates read-only policies scoped per application
- Generates AppRole credentials and writes them as a K8s secret in the `external-secrets` namespace
- Seeds placeholder secrets for each app (`changeme` values — update before going live)

After the job completes, External Secrets Operator reads the AppRole credentials, connects to Vault, and syncs secrets into each application namespace. Once the secrets exist, the application pods start successfully.

---

## Lessons Learned

1. **FluxCD dry-runs all resources before applying any.** CRDs and the resources that use them must be in separate Kustomizations with explicit `dependsOn`.

2. **Helm chart versions matter more than you think.** Lock chart versions or at least constrain minor versions (`>=7.0.0 <8.0.0`) and read the changelog when bumping.

3. **Check CRD `served` versions.** When an operator drops a beta API, all existing resources using that version silently fail. `kubectl get crd <name> -o jsonpath='{.spec.versions[*]}'` shows which versions are still served.

4. **Rackspace Cinder has a 5 GiB minimum PVC size.** The error message is buried in a `BadRequest` from the Cinder API — easy to miss if you're only watching pod events.

5. **OCI Helm registries are different from HTTP Helm repos.** The `type: oci` field in `HelmRepository` changes how Flux interacts with the registry. The chart URL in the `HelmRelease` stays the same — only the repository spec changes.

6. **Keep `vault-init.json` out of Git.** The file contains unseal keys and the root token. Add it to `.gitignore` immediately after generating it.
