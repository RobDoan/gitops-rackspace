# Cloudflare Tunnel for Homelander Cluster

**Status:** Design — approved, pending implementation plan
**Date:** 2026-04-21
**Scope:** Expose selected homelander-cluster services on the public internet via Cloudflare Tunnel, without opening any inbound ports on the home network. Routing uses the existing `ingress-nginx` controller. Only the homelander cluster is affected. Rackspace is unchanged.

## Goals

- Reach services like `https://n8n.lab.quybits.com` from any internet, with a real Cloudflare-issued TLS cert.
- No router port-forwarding, no public IP on the homelab.
- Keep the existing LAN path (`https://n8n.homelander.local`) working in parallel.
- All routing config in Git; Flux-managed like every other component in this repo.
- Secrets flow through Vault + External Secrets Operator, matching the rest of the repo.

## Non-goals

- Changing rackspace cluster networking (it stays on Let's Encrypt + public ingress).
- Moving LAN access off the self-signed CA.
- Per-service tunnel configuration (one wildcard rule covers everything).
- Installing a Cloudflare Tunnel operator or CRD-based controller.

## Architecture

```
Internet user → https://n8n.lab.quybits.com
   │
   ▼
Cloudflare edge (TLS terminated here, WAF/DDoS, real cert)
   │
   ▼   (outbound persistent QUIC connection — no inbound port needed)
cloudflared Deployment in homelander (namespace: cloudflared, 2 replicas)
   │
   ▼   HTTP (in-cluster)
ingress-nginx-controller.ingress-nginx.svc.cluster.local:80
   │   (Host: n8n.lab.quybits.com → matching Ingress rule)
   ▼
n8n Service → n8n Pod

LAN user → https://n8n.homelander.local
   │
   ▼
ingress-nginx on the LAN (self-signed TLS)
   ▼
n8n Service → n8n Pod
```

### Key decisions and why

| Decision | Why |
|---|---|
| Tunnel → ingress-nginx (one wildcard rule) | New services need zero cloudflared changes — just add a host to the app's Ingress. Matches the repo pattern. |
| HTTP (not HTTPS) from cloudflared to ingress-nginx | Cloudflare already terminated TLS at the edge. Doubling encryption inside the cluster adds CPU/cert hassle without security gain (the QUIC tunnel is the trust boundary). |
| Locally-managed tunnel (credentials.json + config in Git) | Routing config is reviewable and version-controlled. The alternative (token-based, remote-managed) hides routing in the Cloudflare dashboard and breaks the GitOps property the rest of this repo has. |
| No Cloudflare Tunnel operator | Only one wildcard rule exists — an operator's per-service automation is unnecessary surface area. |
| Two `cloudflared` replicas | HA: Cloudflare load-balances across tunnel connections. Single replica survives pod restarts but drops connections briefly. |
| `lab.quybits.com` subdomain (not a new zone) | `quybits.com` is already on Cloudflare DNS. Free plan; zero extra setup. |

## Repository layout

### New files

```
infrastructure/cloudflared/
├── kustomization.yaml
├── namespace.yaml
├── deployment.yaml
├── configmap.yaml
├── externalsecret.yaml
└── serviceaccount.yaml              # minimal, no RBAC needed

clusters/homelander/
└── cloudflared.yaml                 # Flux Kustomization → infrastructure/cloudflared

scripts/
└── cloudflared-bootstrap.sh         # one-time manual bootstrap, idempotent
```

### Modified files (homelander overlays only)

```
apps/n8n/overlays/homelander/
├── ingress-patch.yaml               # NEW: adds n8n.lab.quybits.com host
└── kustomization.yaml               # patches: list gets ingress-patch.yaml

apps/grafana/overlays/homelander/    # same shape
apps/qdrant/overlays/homelander/     # same shape
apps/royal-dispatch/overlays/homelander/  # only if it has an Ingress in homelander
```

### Vault layout

```
secret/cloudflared/
  tunnel-credentials   →  key: credentials.json
                          value: contents of <TUNNEL-UUID>.json from `cloudflared tunnel create`
```

## Component details

### `infrastructure/cloudflared/namespace.yaml`

Standalone `Namespace` named `cloudflared`. No labels required.

### `infrastructure/cloudflared/configmap.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloudflared-config
  namespace: cloudflared
data:
  config.yaml: |
    tunnel: <TUNNEL_UUID>                           # paste once, post-bootstrap
    credentials-file: /etc/cloudflared/creds/credentials.json
    metrics: 0.0.0.0:2000
    no-autoupdate: true

    ingress:
      - hostname: "*.lab.quybits.com"
        service: http://ingress-nginx-controller.ingress-nginx.svc.cluster.local:80
        originRequest:
          httpHostHeader: ""
          connectTimeout: 30s
          noHappyEyeballs: true
      - service: http_status:404
```

The `<TUNNEL_UUID>` placeholder is replaced by the user one time with the UUID printed by the bootstrap script. The exact Service DNS name for ingress-nginx should be verified during implementation (`kubectl -n ingress-nginx get svc` — name may be `ingress-nginx-controller` or slightly different depending on the Helm release values).

### `infrastructure/cloudflared/externalsecret.yaml`

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: cloudflared-credentials
  namespace: cloudflared
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: cloudflared-credentials
    creationPolicy: Owner
  data:
    - secretKey: credentials.json
      remoteRef:
        key: cloudflared/tunnel-credentials
        property: credentials.json
```

### `infrastructure/cloudflared/deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
  namespace: cloudflared
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate: { maxSurge: 1, maxUnavailable: 0 }
  selector:
    matchLabels: { app: cloudflared }
  template:
    metadata:
      labels: { app: cloudflared }
    spec:
      containers:
        - name: cloudflared
          image: cloudflare/cloudflared:2026.4.0   # pin; Renovate/manual bump
          args:
            - tunnel
            - --config
            - /etc/cloudflared/config/config.yaml
            - --metrics
            - 0.0.0.0:2000
            - run
          ports:
            - { name: metrics, containerPort: 2000 }
          livenessProbe:
            httpGet: { path: /ready, port: 2000 }
            initialDelaySeconds: 10
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet: { path: /ready, port: 2000 }
            periodSeconds: 5
          resources:
            requests: { cpu: 50m,  memory: 64Mi }
            limits:   { cpu: 500m, memory: 256Mi }
          volumeMounts:
            - { name: config, mountPath: /etc/cloudflared/config, readOnly: true }
            - { name: creds,  mountPath: /etc/cloudflared/creds,  readOnly: true }
      volumes:
        - name: config
          configMap: { name: cloudflared-config }
        - name: creds
          secret:    { secretName: cloudflared-credentials }
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector: { matchLabels: { app: cloudflared } }
```

The exact image tag should be verified against the latest stable `cloudflare/cloudflared` release at implementation time.

### `clusters/homelander/cloudflared.yaml`

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cloudflared
  namespace: flux-system
spec:
  interval: 10m
  path: ./infrastructure/cloudflared
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  dependsOn:
    - { name: external-secrets }
    - { name: eso-store }
    - { name: ingress-nginx }
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: cloudflared
      namespace: cloudflared
  timeout: 5m
```

The Flux Kustomization naming in `clusters/homelander/` follows the folder name (e.g., `n8n.yaml` → `name: n8n`). This spec matches that convention.

### Per-app Ingress patches

Pattern — each `apps/<name>/overlays/homelander/ingress-patch.yaml`:

```yaml
# strategic-merge patch; must match the Ingress name from base/
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: <app-name>
spec:
  rules:
    - host: <app>.homelander.local       # existing LAN host, kept
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: { name: <app>, port: { number: <port> } }
    - host: <app>.lab.quybits.com        # NEW public host
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: { name: <app>, port: { number: <port> } }
  # tls: unchanged — still only covers *.homelander.local
```

Wired into the overlay's `kustomization.yaml`:

```yaml
patches:
  - path: ingress-patch.yaml
    target: { kind: Ingress, name: <app-name> }
```

The exact base-Ingress name, service name, and port per app must be read from each `apps/<name>/base/` during implementation — do not assume.

### `scripts/cloudflared-bootstrap.sh`

Idempotent bash script wrapping the one-time manual steps. Requirements:

- `set -euo pipefail`.
- Refuses to run unless `kubectl config current-context` resolves to the homelander cluster (prevents running against rackspace by mistake).
- Installs `cloudflared` via Homebrew on macOS if missing.
- Runs `cloudflared tunnel login` only if `~/.cloudflared/cert.pem` does not exist.
- Creates the `homelander` tunnel only if `cloudflared tunnel list` does not already show it (idempotent).
- Ensures a **wildcard CNAME** `*.lab.quybits.com → <TUNNEL_UUID>.cfargotunnel.com` exists in the Cloudflare DNS zone. `cloudflared tunnel route dns` does not reliably accept wildcards across versions, so the script uses the Cloudflare API directly via `curl` + `CLOUDFLARE_API_TOKEN` (or prints clear instructions to add the CNAME manually in the dashboard if the token is not set). Idempotent: if the record already exists and matches, do nothing.
- Reads the per-tunnel `<UUID>.json` from `~/.cloudflared/` and writes it to Vault at `secret/cloudflared/tunnel-credentials` under key `credentials.json`. Uses the same unseal-key / root-token pattern seen in `scripts/vault-unseal.sh` and the repo's Vault usage.
- Prints the `TUNNEL_UUID` on stdout with clear instructions to paste it into `infrastructure/cloudflared/configmap.yaml`.
- Does **not** modify any file in the repo.

Vault path (`VAULT_PATH=secret/cloudflared/tunnel-credentials`) is a variable near the top of the script for easy change.

## Data flow

1. User runs `scripts/cloudflared-bootstrap.sh` once. Tunnel created, DNS CNAME created, credentials stored in Vault. UUID printed.
2. User pastes UUID into `infrastructure/cloudflared/configmap.yaml`, commits, pushes.
3. Flux reconciles `clusters/homelander/cloudflared.yaml`.
4. Namespace, ConfigMap, and ExternalSecret apply.
5. External Secrets Operator reads `secret/cloudflared/tunnel-credentials` from Vault and produces `Secret/cloudflared-credentials`.
6. Deployment pods start, mount ConfigMap + Secret, establish QUIC connections to Cloudflare.
7. Internet request to `n8n.lab.quybits.com` → Cloudflare edge → tunnel → `cloudflared` pod → `ingress-nginx-controller` svc → n8n pod.

## Secrets handling

- Bootstrap credentials (`cert.pem`) never leave the user's laptop.
- Per-tunnel credentials JSON is the narrowly-scoped secret that goes into Vault. Compromising it lets an attacker impersonate the `homelander` tunnel but not manage other tunnels or the Cloudflare account.
- The in-cluster `Secret` is owned by the ExternalSecret (`creationPolicy: Owner`) — if the ExternalSecret is deleted, the Secret is removed.

## Testing & validation

### Pre-merge (no cluster)

```bash
kubectl kustomize infrastructure/cloudflared
kubectl kustomize apps/n8n/overlays/homelander
kubectl kustomize apps/grafana/overlays/homelander
kubectl kustomize apps/qdrant/overlays/homelander
# royal-dispatch only if it has an ingress patch

kubeconform -strict -kubernetes-version 1.30.0 \
  <(kubectl kustomize infrastructure/cloudflared)
```

### Bootstrap

```bash
kubectx homelander
./scripts/cloudflared-bootstrap.sh

kubectl exec -n vault vault-0 -- \
  env VAULT_TOKEN=$(jq -r .root_token vault-init-homelander.json) \
  vault kv get secret/cloudflared/tunnel-credentials
```

### Post-Flux reconcile

```bash
flux reconcile kustomization cloudflared --with-source
flux get kustomization cloudflared                   # Ready=True
kubectl -n cloudflared get externalsecret            # SecretSynced=True
kubectl -n cloudflared get secret cloudflared-credentials
kubectl -n cloudflared get pods                      # 2/2 Running
kubectl -n cloudflared logs -l app=cloudflared --tail=50
#   expect: "Registered tunnel connection ... connIndex=0/1/2/3"
```

### End-to-end

```bash
dig +short n8n.lab.quybits.com            # CNAME to *.cfargotunnel.com
curl -I https://n8n.lab.quybits.com       # 200/302 with valid Cloudflare cert
curl -kI https://n8n.homelander.local     # LAN path still works (self-signed)
```

Browser check for each app: log in via the public URL, exercise interactive flows (especially n8n — editor uses websockets/long-lived connections).

### Failure modes

| Symptom | Likely cause | Where to look |
|---|---|---|
| 502 from Cloudflare | cloudflared can't reach ingress-nginx | `kubectl logs -n cloudflared`; verify svc DNS/port in ConfigMap |
| 530 / "no such host" | DNS record missing or wrong | Cloudflare DNS dashboard; re-run bootstrap step 4 |
| 404 from ingress-nginx | App Ingress missing the new host | `kubectl get ingress -n <ns> -o yaml` |
| cloudflared CrashLoopBackOff (auth error) | Secret not synced or UUID mismatch | `kubectl get externalsecret -n cloudflared`; verify `tunnel:` UUID |
| ExternalSecret `SecretSyncedError` | Vault path/key mismatch | `kubectl describe externalsecret -n cloudflared` |

## Rollback

- Revert the commit that adds `clusters/homelander/cloudflared.yaml` and the `infrastructure/cloudflared/` directory. Flux prunes the Namespace, Deployment, ConfigMap, ExternalSecret, and Secret (ESO `creationPolicy: Owner`).
- Revert each app's `ingress-patch.yaml` to remove the `*.lab.quybits.com` host.
- Optionally delete the tunnel from Cloudflare: `cloudflared tunnel delete homelander`. Safe to leave in place.

## Prerequisites (confirmed with user)

- `quybits.com` DNS is managed by Cloudflare — no delegation needed for `lab.quybits.com`.
- `ClusterSecretStore` `vault-backend` exists and is reachable (confirmed in `infrastructure/eso-store/`).
- `ingress-nginx` is installed and has an in-cluster `Service`. Exact Service name (`ingress-nginx-controller` per the convention) must be verified during implementation.
- User has Cloudflare account access for the `quybits.com` zone.
- Vault is unsealed and the unseal key / root token file (`vault-init-homelander.json`) is available on the machine running the bootstrap script.

## Open items deferred to implementation

- Exact `ingress-nginx` Service name and port — read from the homelander cluster.
- Per-app Ingress name / service / port — read from each `apps/<name>/base/`.
- `cloudflared` container image tag — pin to the latest stable at implementation time.
- Whether `royal-dispatch` has a homelander Ingress (and therefore needs a patch).
- Prometheus scrape config for cloudflared's `/metrics` (out of scope for this spec; noted because port 2000 is already exposed).
- How the bootstrap script obtains a Cloudflare API token (likely a user-scoped token with `Zone:DNS:Edit` on `quybits.com`). If absent at bootstrap time, the script should degrade gracefully to printing manual DNS instructions.
