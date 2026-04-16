# One Repo, Two Clusters: The Multi-Cluster GitOps Journey

I've been running a Kubernetes stack on **Rackspace** for a while now — Grafana for dashboards, n8n for workflow automation, Qdrant as my vector database, and Vault for secrets management. All of it managed by FluxCD from a single Git repo. For under $20/month, it's been a rock-solid setup.

But recently I built a K3s homelab cluster called **Homelander**: three VMs (Jarvis, Edith, Karen) running on a Minisforum UM890 Pro with Proxmox as the hypervisor. If you're curious about that build, I wrote about the hardware and initial setup in a [previous post](./setup-homelabs.md).

The goal was simple: deploy the same apps to both clusters from the same Git repo. One source of truth, two environments. No duplicating manifests, no maintaining two separate stacks that slowly drift apart. How hard could it be?

Turns out, a lot of things that "just work" in a single-cluster setup break the moment you add a second cluster. Storage classes are different. Domain names are different. Ingress controllers are different. TLS certificate provisioning is fundamentally different. This post walks through every problem I hit and how Kustomize overlays solved each one.

---

## 1. Problem: Storage Classes Are Different

The first thing that broke was storage.

Rackspace provides an `ssd` storage class — it's their default block storage for Kubernetes. K3s, on the other hand, ships with `local-path` from Rancher's local-path provisioner, which writes directly to the node's filesystem. Completely different provisioners, completely different class names.

My existing HelmReleases all had `storageClassName: ssd` hardcoded in the values. Deploy that to K3s and the PVC sits in `Pending` forever, because there's no `ssd` storage class on that cluster. Kubernetes doesn't give you a helpful error here — the PVC just waits indefinitely for a provisioner that will never come.

### The Fix: Kustomize Base + Overlays

The solution is to pull the storage class out of the base manifest and patch it per cluster. Here's what the Qdrant HelmRelease looks like after the refactor.

**Base HelmRelease** (`apps/qdrant/base/helmrelease.yaml`) — no `storageClassName` at all:

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

**Rackspace patch** (`apps/qdrant/overlays/rackspace/helmrelease-patch.yaml`):

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: qdrant
  namespace: qdrant
spec:
  values:
    persistence:
      storageClassName: ssd
```

**Homelander patch** (`apps/qdrant/overlays/homelander/helmrelease-patch.yaml`):

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
```

Each overlay's `kustomization.yaml` pulls in the base and applies its patches:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
patches:
  - path: helmrelease-patch.yaml
  - path: ingress-patch.yaml
```

The directory structure for one app looks like this:

```
apps/qdrant/
  base/
    helmrelease.yaml
    helmrepository.yaml
    externalsecret.yaml
    ingress.yaml
    kustomization.yaml
  overlays/
    rackspace/
      helmrelease-patch.yaml
      ingress-patch.yaml
      kustomization.yaml
    homelander/
      helmrelease-patch.yaml
      ingress-patch.yaml
      kustomization.yaml
```

You can verify each overlay produces valid output with `kubectl kustomize`:

```bash
kubectl kustomize apps/qdrant/overlays/rackspace  # storageClassName: ssd
kubectl kustomize apps/qdrant/overlays/homelander  # storageClassName: local-path
```

---

## 2. Problem: Hostnames Don't Match

Same story, different field. My Rackspace ingresses use `qdrant.quybits.com`, but the homelab uses `*.homelander.local`. Hardcoding the hostname in the base Ingress means one cluster always gets the wrong domain.

### The Fix: Same Overlay Pattern

The base Ingress uses a placeholder hostname (`qdrant.example.com`) and each overlay patches it to the real domain.

**Base Ingress** (`apps/qdrant/base/ingress.yaml`):

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

The Rackspace overlay patches the host to `qdrant.quybits.com`. The homelander overlay patches it to `qdrant.homelander.local`. Same mechanics as the storage class patches — Kustomize's strategic merge patch replaces the hostname fields and leaves everything else untouched.

Notice that the base keeps `ingressClassName: nginx` and the `cert-manager.io/cluster-issuer: letsencrypt-prod` annotation. Those are the same on both clusters, so they belong in the base. Only the things that genuinely differ — hostname and TLS host — go in the overlays. This keeps the patches small and obvious.

---

## 3. Problem: Traefik vs. ingress-nginx

K3s ships with **Traefik** as the default ingress controller. My entire stack uses **ingress-nginx** with `ingressClassName: nginx`. Running both on the same cluster causes real headaches:

- **Port conflicts.** Both controllers want to bind ports 80 and 443. On a homelab with a single IP, that's a non-starter.
- **Debugging confusion.** When an ingress isn't working, you're never sure which controller is handling the request.
- **GitOps inconsistency.** If Rackspace uses nginx and homelander uses Traefik, I'd need different annotations per cluster — defeating the whole purpose.

### The Fix: Disable Traefik

I decided to standardize on ingress-nginx across both clusters. On Jarvis (the K3s server node), I disabled Traefik by editing the K3s systemd service file:

```bash
sudo nano /etc/systemd/system/k3s.service
```

Add `--disable=traefik` to the `ExecStart` line:

```bash
ExecStart=/usr/local/bin/k3s server \
  --disable=traefik \
  # ... other arguments
```

Then reload systemd and restart K3s:

```bash
sudo systemctl daemon-reload
sudo systemctl restart k3s
```

Verify that the Traefik pod is gone:

```bash
kubectl get pods -n kube-system
```

After that, ingress-nginx deploys via Flux the same way it does on Rackspace. No overlay needed — the ingress-nginx HelmRelease is identical on both clusters.

---

## 4. Problem: TLS Certificates

On Rackspace, TLS is easy. I have real domains (`*.quybits.com`), and a `ClusterIssuer` using Let's Encrypt ACME HTTP-01 handles certificate provisioning automatically:

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

On the homelab? Not a chance. HTTP-01 validation requires Let's Encrypt to reach my cluster over the public internet. My homelab domains are `*.homelander.local` — no public DNS knows about them, and no ACME server can validate them.

### The Fix: Self-Signed CA in cert-manager

cert-manager supports self-signed certificates natively. The setup is a three-resource chain:

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

The `selfsigned-bootstrap` issuer creates a root CA certificate with a 10-year duration (because I don't want to think about rotating a homelab CA anytime soon). That CA cert then backs a `ClusterIssuer` of type `CA` that actually signs the app certificates.

### The Naming Trick

Notice the CA issuer is named `letsencrypt-prod`. That's deliberate. Every Ingress in my repo has this annotation:

```yaml
annotations:
  cert-manager.io/cluster-issuer: letsencrypt-prod
```

On Rackspace, `letsencrypt-prod` points to the real ACME issuer. On homelander, `letsencrypt-prod` points to the self-signed CA issuer. **Same name, different implementation.** The apps don't need to know which cluster they're on.

This is also why `cert-manager-issuers` uses a different overlay approach. The resources are entirely different between clusters — there's nothing to patch. Each overlay provides its own complete `clusterissuer.yaml` rather than patching a shared base.

---

## 5. Problem: Infrastructure Components Too

It wasn't just the apps. **Vault** also hardcodes `storageClassName: ssd` and uses `vault.quybits.com` as its hostname. Same problem, same solution — I restructured Vault into `infrastructure/vault/base/` and `infrastructure/vault/overlays/` with per-cluster patches.

The pattern scales. Once you've done it for one app, every other app is just copy-paste-adjust. Grafana needs `storageClassName: ssd` on Rackspace for its dashboard database and `local-path` on homelander — same patch shape. n8n has the same story. Vault needs it for its Raft storage backend. They all follow the same `base/` + `overlays/` structure now, and the per-cluster patches are each about 10 lines of YAML.

---

## 6. The Cluster Entrypoints

So I have bases and overlays, but how does FluxCD know which overlay to use? That's where the cluster entrypoints come in.

Each cluster has its own directory under `clusters/`. Inside, there's a Flux `Kustomization` resource for every app, and its `path` field points to the correct overlay.

**Rackspace** (`clusters/rackspace/qdrant.yaml`):

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: qdrant
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 1m
  path: ./apps/qdrant/overlays/rackspace
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  dependsOn:
    - name: eso-store
    - name: cert-manager-issuers
    - name: ingress-nginx
  healthChecks:
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: qdrant
      namespace: qdrant
```

**Homelander** (`clusters/homelander/qdrant.yaml`):

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: qdrant
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 1m
  path: ./apps/qdrant/overlays/homelander
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  dependsOn:
    - name: eso-store
    - name: cert-manager-issuers
    - name: ingress-nginx
  healthChecks:
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: qdrant
      namespace: qdrant
```

The manifests are nearly identical — same `dependsOn`, same health checks, same source reference. The only difference is the `path` field: `./apps/qdrant/overlays/rackspace` vs. `./apps/qdrant/overlays/homelander`. That single line is what makes the whole multi-cluster setup work.

When you bootstrap Flux on a cluster, you point it at the cluster's directory:

```bash
flux bootstrap github \
  --owner=<your-org> \
  --repository=<your-repo> \
  --path=clusters/homelander
```

Flux reads the Kustomizations in that directory, each one points to the right overlay, and the cluster gets exactly the manifests it needs.

---

## 7. The Final Structure

Here's what the full repo tree looks like:

```
clusters/
  rackspace/
    cert-manager.yaml
    cert-manager-issuers.yaml
    external-secrets.yaml
    eso-store.yaml
    ingress-nginx.yaml
    namespaces.yaml
    grafana.yaml
    n8n.yaml
    qdrant.yaml
    vault.yaml
  homelander/
    cert-manager.yaml
    cert-manager-issuers.yaml
    external-secrets.yaml
    eso-store.yaml
    ingress-nginx.yaml
    namespaces.yaml
    grafana.yaml
    n8n.yaml
    qdrant.yaml
    vault.yaml

apps/
  grafana/
    base/
    overlays/rackspace/
    overlays/homelander/
  n8n/
    base/
    overlays/rackspace/
    overlays/homelander/
  qdrant/
    base/
    overlays/rackspace/
    overlays/homelander/

infrastructure/
  cert-manager/               # shared, no overlays
  cert-manager-issuers/
    base/
    overlays/rackspace/
    overlays/homelander/
  external-secrets/           # shared, no overlays
  eso-store/                  # shared, no overlays
  ingress-nginx/              # shared, no overlays
  vault/
    base/
    overlays/rackspace/
    overlays/homelander/
```

Here's the summary of what differs per cluster vs. what's shared:

| Component | Needs Overlays? | What Differs |
| :--- | :--- | :--- |
| **Grafana** | Yes | Storage class, hostname |
| **n8n** | Yes | Storage class, hostname |
| **Qdrant** | Yes | Storage class, hostname |
| **Vault** | Yes | Storage class, hostname |
| **cert-manager-issuers** | Yes | Entire resource (ACME vs. self-signed CA) |
| **cert-manager** | No | Identical on both clusters |
| **ingress-nginx** | No | Identical on both clusters |
| **external-secrets** | No | Identical on both clusters |
| **eso-store** | No | Identical on both clusters |
| **namespaces** | No | Identical on both clusters |

The shared components — cert-manager, ingress-nginx, External Secrets Operator, namespaces — need zero overlays. They deploy the same way everywhere. It's only the things with per-cluster configuration (storage, hostnames, TLS issuers) that need the base + overlay treatment.

---

## 8. Restructuring the Repo? Update Your Paths

One thing that tripped me up: if you restructure the repo — rename directories, move overlays around, change the cluster entrypoint path — **Flux doesn't magically follow along**. The bootstrap path is baked into the Flux Kustomization CRD (`gotk-sync.yaml`), and every app Kustomization has a hardcoded `path` pointing to its overlay directory.

If you change the structure, you have two options:

1. **Re-bootstrap.** Run `flux uninstall`, then re-run `flux bootstrap` with the new `--path`. Cleanest approach.

```bash
flux bootstrap github \
  --owner=${GITHUB_USER} \
  --repository=gitops-rackspace \
  --branch=main \
  --path=./clusters/rackspace \
  --personal --token-auth
```

2. **Update in-place.** Edit `gotk-sync.yaml` in your repo to reflect the new path, update every Kustomization CRD's `path` field, commit, and push. Then patch the live CRD on the cluster so it picks up the change immediately:


```bash
kubectl edit kustomization flux-system -n flux-system
# update spec.path to your new directory
```

```yaml
#clusters/rackspace/flux-system/gotk-sync.yaml

spec:
  path: ./clusters/rackspace  # ← this must match your new structure
```

Either way, don't forget to update the inner `path` fields too — every `.yaml` file in `clusters/<name>/` points to a specific overlay directory. If those paths are stale, Flux will fail to reconcile and you'll see `path not found` errors in `flux get kustomizations`.

---

## 9. What's Next

The repo structure is ready. The overlays are written. The next steps are all about making homelander operational:

- **Bootstrap Flux on homelander.** Point it at `clusters/homelander/` and let it reconcile everything.
- **Vault init and unsealing.** Vault needs to be initialized on the new cluster, unsealed, and configured with the right secrets.
- **DNS for `*.homelander.local`.** I need local DNS resolution so my browser can actually reach `grafana.homelander.local` and friends. Probably a simple dnsmasq or CoreDNS setup on my network.
- **More apps and GPU workloads.** The UM890 Pro has an OCuLink port for an eGPU. Once homelander is stable, I want to run local LLM inference and other AI workloads that would cost a fortune in the cloud.

The beauty of this setup is that adding a third cluster — another homelab node, a different cloud provider, whatever — is just another directory under `clusters/` and another set of overlays. The base manifests and the shared infrastructure stay untouched. The effort scales linearly with the number of things that differ, not the number of things you deploy.

One repo, two clusters, zero drift. That's the goal, and we're almost there.
