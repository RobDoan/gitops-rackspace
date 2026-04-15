# Design: Multi-Cluster Journey Blog Post

## 1. Goal

Write a standalone, tutorial-style blog post for homelab enthusiasts who already have one cluster and want to add a second. Covers the full journey of making one GitOps repo deploy to two clusters with different infrastructure.

## 2. Target Audience

Homelab enthusiasts with Kubernetes experience who want to add a second cluster (cloud + homelab, or two homelabs) and need a practical guide for handling the differences.

## 3. Format

- Standalone (no required reading of other posts)
- Problem-driven: each section starts with the friction, then shows the solution
- First-person, conversational tone matching existing blog posts
- Real YAML and terminal output throughout
- ~2000-2500 words

## 4. File

`docs/blog/multi-cluster-gitops-journey.md`

## 5. Structure

### Section 1: The Starting Point

Brief recap of the two clusters for readers who haven't read previous posts:

- Rackspace: cloud cluster, FluxCD, runs Grafana/n8n/Qdrant/Vault
- Homelander: K3s homelab, 3 nodes (jarvis/edith/karen), Proxmox
- Goal: deploy the same apps to both from one Git repo

No detailed setup instructions (that's the other posts). Just enough context.

### Section 2: Problem 1 — Storage Classes

- Show `kubectl get storageclass` on both clusters: `ssd` vs `local-path`
- Show the existing HelmRelease with `storageClass: ssd` hardcoded
- This won't deploy on K3s — the StorageClass doesn't exist
- Solution: Kustomize base + overlays
- Walk through Qdrant end-to-end: base HelmRelease (no storageClass), rackspace patch (ssd), homelander patch (local-path)
- Include the full directory tree for one app
- Show `kubectl kustomize` output for both overlays

### Section 3: Problem 2 — Hostnames

- Ingresses hardcode `qdrant.quybits.com`
- Homelander uses `*.homelander.local`
- Same overlay pattern: base Ingress with placeholder, strategic merge patches per cluster
- Show the ingress patch YAML
- Brief: this follows the same pattern, so don't belabor it

### Section 4: Problem 3 — Traefik vs ingress-nginx

- K3s ships Traefik. All existing manifests use `ingressClassName: nginx`.
- Running both: port 80/443 conflicts, debugging confusion
- Decision: disable Traefik, use ingress-nginx everywhere for consistency
- Show `/etc/rancher/k3s/config.yaml` change and restart command
- ingress-nginx deploys via Flux, no overlay needed (cluster-agnostic)

### Section 5: Problem 4 — TLS Certificates

- Let's Encrypt HTTP-01 needs public domain + reachable endpoint
- `*.homelander.local` can't be validated
- Solution: self-signed CA in cert-manager
- The three-resource chain: bootstrap issuer → CA cert → CA issuer
- Full YAML for all three resources
- The naming trick: CA issuer named `letsencrypt-prod` so apps don't need to know which cluster they're on
- This is the one piece where the overlays contain completely different resources, not just patches

### Section 6: Problem 5 — Infrastructure Too

- Vault also hardcodes `storageClass: ssd` and `vault.quybits.com`
- Same base + overlay treatment as apps
- Brief section: shows the pattern scales to infrastructure, not just apps

### Section 7: The Cluster Entrypoints

- How FluxCD knows which overlay to use
- `clusters/rackspace/qdrant.yaml` has `path: ./apps/qdrant/overlays/rackspace`
- `clusters/homelander/qdrant.yaml` has `path: ./apps/qdrant/overlays/homelander`
- When you bootstrap Flux on a cluster, you point it at its cluster directory
- Show the Flux Kustomization YAML with the path field

### Section 8: The Final Structure

- Full repo tree showing apps/, infrastructure/, clusters/
- The "aha moment" summary table: what differs per cluster vs what's shared
- Everything that's shared (ingress-nginx, cert-manager operator, ESO, namespaces) needs zero overlays

### Section 9: What's Next

- Bootstrapping Flux on homelander
- Vault initialization and unsealing
- DNS for `*.homelander.local` (local DNS or /etc/hosts)
- Possible future: more apps, GPU workloads on homelab

## 6. Success Criteria

- Reader with one cluster can follow the decisions and apply to their own second cluster
- All YAML is real (from the actual repo), not pseudocode
- Self-contained: no required reading of other posts
- Matches tone of existing blog posts (setup-homelabs.md)
