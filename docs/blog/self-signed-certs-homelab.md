# Self-Signed Certs, One Ingress, Zero App Changes: TLS on a Homelab K3s Cluster

Running two Kubernetes clusters in parallel — one on Rackspace (cloud) and one on a K3s homelab — sounds straightforward until you realize how many small things differ between them. Storage classes, domain names, TLS certificates... the list adds up fast.

This post covers the decisions I made to keep my GitOps manifests working across both clusters without any app-level changes, focusing on the ingress controller choice and the self-signed certificate setup for my homelab.

---

## 1. Why Disable Traefik on K3s

K3s ships with **Traefik** as the default ingress controller. That's great if you're starting from scratch, but my entire stack — Grafana, n8n, Qdrant, Vault — already has Ingress manifests written for **ingress-nginx** with `ingressClassName: nginx`.

Running both Traefik and ingress-nginx on the same cluster causes real problems:

* **Port conflicts.** Both want to bind ports 80 and 443 on the LoadBalancer. On a homelab with a single IP, that's a non-starter.
* **Inconsistency.** Debugging an ingress issue is hard enough without wondering which controller is handling the request.
* **GitOps simplicity.** One ingress controller across all clusters means the same annotations and class names work everywhere.

Disabling Traefik is a one-liner. On the server node (Jarvis in my case), edit the K3s config:

```yaml
# /etc/rancher/k3s/config.yaml
disable:
  - traefik
```

Then restart K3s:

```bash
sudo systemctl restart k3s
```

After that, deploy ingress-nginx through your usual Flux/Helm setup and you're back in business.

---

## 2. The Certificate Problem

On Rackspace, TLS is easy. I have real domains (`*.quybits.com`), cert-manager is installed, and a `ClusterIssuer` using Let's Encrypt ACME HTTP-01 handles everything:

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

On the homelab? Not so much. HTTP-01 validation requires Let's Encrypt to reach your cluster over the public internet. My homelab domains are `*.homelander.local` — a private domain that no DNS server on the internet knows about, and no ACME server can validate.

You could set up DNS-01 with a real domain and a supported DNS provider, but that felt like overkill for a homelab. **Self-signed certificates are the correct solution here.** The browsers will show a warning, sure, but for internal tools that only I access over Tailscale, that's perfectly fine.

---

## 3. How Self-Signed CA Works in cert-manager

cert-manager supports self-signed certificates natively. The setup is a chain of three resources, each building on the previous one:

### Step 1: The Bootstrap Issuer

First, you create a `ClusterIssuer` of type `SelfSigned`. This issuer can only do one thing: create self-signed certificates. We use it to bootstrap our root CA.

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-bootstrap
spec:
  selfSigned: {}
```

### Step 2: The Root CA Certificate

Next, you create a `Certificate` that uses the bootstrap issuer to generate a root CA. This is the certificate that will sign everything else. I gave it a 10-year duration because I don't want to think about rotating a homelab CA anytime soon.

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: homelander-ca
  namespace: cert-manager
spec:
  isCA: true
  duration: 87600h  # 10 years
  commonName: homelander-ca
  secretName: homelander-ca-key-pair
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned-bootstrap
    kind: ClusterIssuer
    group: cert-manager.io
```

### Step 3: The CA Issuer

Finally, you create a `ClusterIssuer` of type `CA` that references the root CA's secret. This is the issuer that will actually sign your app certificates.

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  ca:
    secretName: homelander-ca-key-pair
```

Wait — why is it called `letsencrypt-prod`? That brings us to the best part.

---

## 4. The Naming Trick

Every Ingress in my repo has this annotation in the base manifest:

```yaml
annotations:
  cert-manager.io/cluster-issuer: letsencrypt-prod
```

On Rackspace, `letsencrypt-prod` points to the real ACME issuer. On homelander, `letsencrypt-prod` points to the self-signed CA issuer. **Same name, different implementation.**

This means the apps don't need to know which cluster they're on. The Ingress asks for a cert from `letsencrypt-prod`, and the cluster-specific issuer handles it. No patches, no conditionals, no overlay for the annotation. It just works.

---

## 5. The Full Picture: Base + Overlay Kustomize Pattern

This naming trick is part of a larger pattern. Every app in the repo follows the same structure:

```
apps/qdrant/
  base/
    helmrelease.yaml        # Chart config (no storage class)
    ingress.yaml            # ingressClassName: nginx, issuer: letsencrypt-prod
    kustomization.yaml
  overlays/
    rackspace/
      helmrelease-patch.yaml  # storageClassName: ssd
      ingress-patch.yaml      # host: qdrant.quybits.com
    homelander/
      helmrelease-patch.yaml  # storageClassName: local-path
      ingress-patch.yaml      # host: qdrant.homelander.local
```

The **base** defines everything that's common: the Helm chart, the ingress annotations, the service ports. The **overlays** patch only what differs per cluster:

| What changes | Rackspace | Homelander |
| :--- | :--- | :--- |
| **Storage class** | `ssd` | `local-path` |
| **Hostnames** | `*.quybits.com` | `*.homelander.local` |
| **Cert issuer** | Let's Encrypt (ACME) | Self-signed CA |
| **Issuer name** | `letsencrypt-prod` | `letsencrypt-prod` |

That last row is the point. The issuer name is identical, so the base Ingress manifest needs zero per-cluster patches for TLS. The only things the overlays handle are the hostname and storage class.

---

## 6. Conclusion

The setup boils down to a few key decisions:

1. **One ingress controller** (ingress-nginx) across all clusters. Disable K3s's built-in Traefik.
2. **Self-signed CA** on the homelab via cert-manager's three-resource chain. Real Let's Encrypt certs in production.
3. **Same issuer name** (`letsencrypt-prod`) on both clusters so app manifests don't need to care.
4. **Kustomize base + overlays** to handle the things that genuinely differ: storage, hostnames.

Self-signed for homelab, real certs for production, zero app changes. GitOps makes multi-cluster manageable — even when one cluster lives in the cloud and the other lives under your desk.
