# Cloudflare Tunnel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose homelander cluster services on `*.lab.quybits.com` via Cloudflare Tunnel, routed through `ingress-nginx`, with credentials managed in Vault and synced via External Secrets Operator. No router port-forwarding, no public IP. Existing `*.homelander.local` LAN access remains intact.

**Architecture:** A `cloudflared` Deployment in the `cloudflared` namespace establishes outbound QUIC tunnels to Cloudflare's edge. A single wildcard ingress rule routes `*.lab.quybits.com` to the in-cluster `ingress-nginx-controller` Service via plain HTTP (TLS terminates at the Cloudflare edge). Each app's homelander overlay `Ingress` patch is extended to add a second host (`<app>.lab.quybits.com`) alongside the existing LAN host.

**Tech Stack:** Kubernetes (K3s), Flux CD v2.8, Kustomize, Cloudflare Tunnel (`cloudflared`), HashiCorp Vault, External Secrets Operator, ingress-nginx, bash.

**Spec:** `docs/superpowers/specs/2026-04-21-cloudflare-tunnel-design.md`

---

## File Structure

### Created files

| Path | Responsibility |
|---|---|
| `infrastructure/cloudflared/namespace.yaml` | Defines the `cloudflared` Namespace |
| `infrastructure/cloudflared/configmap.yaml` | Tunnel routing config (single wildcard rule → ingress-nginx) |
| `infrastructure/cloudflared/externalsecret.yaml` | ESO resource pulling tunnel credentials from Vault |
| `infrastructure/cloudflared/deployment.yaml` | `cloudflared` Deployment (2 replicas) |
| `infrastructure/cloudflared/kustomization.yaml` | Kustomize entrypoint listing the four resources above |
| `clusters/homelander/cloudflared.yaml` | Flux Kustomization wiring `infrastructure/cloudflared` into the homelander cluster |
| `scripts/cloudflared-bootstrap.sh` | Idempotent bootstrap: creates tunnel, wildcard CNAME, stores credentials in Vault, prints UUID |

### Modified files

| Path | Change |
|---|---|
| `apps/n8n/overlays/homelander/ingress-patch.yaml` | Add second host `n8n.lab.quybits.com` |
| `apps/grafana/overlays/homelander/ingress-patch.yaml` | Add second host `grafana.lab.quybits.com` |
| `apps/qdrant/overlays/homelander/ingress-patch.yaml` | Add second host `qdrant.lab.quybits.com` |
| `apps/royal-dispatch/overlays/homelander/ingress-patch.yaml` | Add second host on each of the four Ingresses (frontend, frontend-api, admin, admin-api) |

### Verified facts (read from repo at plan-time)

- `ClusterSecretStore` name: `vault-backend` (in `infrastructure/eso-store/`)
- ingress-nginx Service: `ingress-nginx-controller` in namespace `ingress-nginx` (standard chart name; `fullnameOverride` is not set in the HelmRelease)
- Flux Kustomizations in `clusters/homelander/` are named after the folder/app they manage (no prefix); they use `interval: 10m`, `retryInterval: 1m`, `prune: true`, and `dependsOn` lists the bare names of other Kustomizations
- All app overlays already follow the pattern: `kustomization.yaml` uses `patches:` with `path:` entries; `target:` is omitted because the patch file's `metadata.name` + `kind` already identify the resource
- Existing `ingress-patch.yaml` files replace only `metadata.{name,namespace}`, `spec.tls`, and `spec.rules` (strategic-merge replacement of the list)
- Royal-dispatch has 4 Ingresses (`royal-dispatch-frontend`, `royal-dispatch-frontend-api`, `royal-dispatch-admin`, `royal-dispatch-admin-api`) on 2 hostnames (`royal-dispatch.homelander.local`, `royal-dispatch-admin.homelander.local`)

---

## Task 1: Create the cloudflared namespace and Kustomize skeleton

**Files:**
- Create: `infrastructure/cloudflared/namespace.yaml`
- Create: `infrastructure/cloudflared/kustomization.yaml`

- [ ] **Step 1: Create the namespace file**

Create `infrastructure/cloudflared/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cloudflared
```

- [ ] **Step 2: Create the kustomization entrypoint**

Create `infrastructure/cloudflared/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - configmap.yaml
  - externalsecret.yaml
  - deployment.yaml
```

(The other three files are added in subsequent tasks; we list them here so each later task's "verify" step is `kubectl kustomize` and we don't have to remember to come back.)

- [ ] **Step 3: Verify kustomize fails cleanly (expected — files don't exist yet)**

Run:
```bash
kubectl kustomize infrastructure/cloudflared
```

Expected: error mentioning the missing `configmap.yaml` / `externalsecret.yaml` / `deployment.yaml`. This confirms the kustomization file is parsed and references the right paths.

- [ ] **Step 4: Do NOT commit yet** — wait until Task 4 produces a buildable kustomization. (Avoids landing a broken intermediate state on `main`.)

---

## Task 2: Add the cloudflared ConfigMap (routing config)

**Files:**
- Create: `infrastructure/cloudflared/configmap.yaml`

- [ ] **Step 1: Write the ConfigMap**

Create `infrastructure/cloudflared/configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloudflared-config
  namespace: cloudflared
data:
  config.yaml: |
    tunnel: REPLACE_WITH_TUNNEL_UUID
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

The literal string `REPLACE_WITH_TUNNEL_UUID` is a sentinel. The bootstrap script (Task 8) will refuse to consider the cluster live until this string has been replaced by a real UUID. We deliberately do NOT use `<…>` brackets here because YAML treats them as plain text but a human grepping for `REPLACE_` won't miss the placeholder.

- [ ] **Step 2: No standalone verification** — kustomize will still fail until Tasks 3 and 4 land. Move on.

---

## Task 3: Add the ExternalSecret pulling credentials from Vault

**Files:**
- Create: `infrastructure/cloudflared/externalsecret.yaml`

- [ ] **Step 1: Write the ExternalSecret**

Create `infrastructure/cloudflared/externalsecret.yaml`:

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

- [ ] **Step 2: Sanity-check the API version against what's installed**

Run:
```bash
kubectx homelander
kubectl get crd externalsecrets.external-secrets.io -o jsonpath='{.spec.versions[*].name}'
```

Expected: a string that **includes** `v1beta1`. If only `v1` appears, change `apiVersion: external-secrets.io/v1beta1` to `external-secrets.io/v1` in the file. Cross-check with another working ExternalSecret (`grep -r "external-secrets.io/" apps/ | head -3`) and use whatever version that file uses.

- [ ] **Step 3: No standalone verification** — kustomize still incomplete. Move on.

---

## Task 4: Add the cloudflared Deployment

**Files:**
- Create: `infrastructure/cloudflared/deployment.yaml`

- [ ] **Step 1: Look up the latest stable cloudflared image tag**

Run:
```bash
curl -s https://api.github.com/repos/cloudflare/cloudflared/releases/latest | jq -r '.tag_name'
```

Expected: a date-style tag like `2026.4.0`. Use this exact tag in Step 2.

If the call rate-limits, manually browse https://github.com/cloudflare/cloudflared/releases and pick the latest non-prerelease tag.

- [ ] **Step 2: Write the Deployment**

Create `infrastructure/cloudflared/deployment.yaml` (substitute `<TAG>` with the value from Step 1):

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
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: cloudflared
  template:
    metadata:
      labels:
        app: cloudflared
    spec:
      containers:
        - name: cloudflared
          image: cloudflare/cloudflared:<TAG>
          args:
            - tunnel
            - --config
            - /etc/cloudflared/config/config.yaml
            - --metrics
            - 0.0.0.0:2000
            - run
          ports:
            - name: metrics
              containerPort: 2000
          livenessProbe:
            httpGet:
              path: /ready
              port: 2000
            initialDelaySeconds: 10
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /ready
              port: 2000
            periodSeconds: 5
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 256Mi
          volumeMounts:
            - name: config
              mountPath: /etc/cloudflared/config
              readOnly: true
            - name: creds
              mountPath: /etc/cloudflared/creds
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: cloudflared-config
        - name: creds
          secret:
            secretName: cloudflared-credentials
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: cloudflared
```

- [ ] **Step 3: Build the kustomization end-to-end**

Run:
```bash
kubectl kustomize infrastructure/cloudflared
```

Expected: clean YAML output containing `Namespace`, `ConfigMap`, `ExternalSecret`, and `Deployment` resources, and no errors. The output should mention `REPLACE_WITH_TUNNEL_UUID` exactly once (in the ConfigMap).

- [ ] **Step 4: Validate manifests with kubeconform (optional but cheap)**

Run:
```bash
kubectl kustomize infrastructure/cloudflared | kubeconform -strict -summary -kubernetes-version 1.30.0 -ignore-missing-schemas
```

Expected: `Summary: ... 0 errors`. The `-ignore-missing-schemas` flag covers the `ExternalSecret` CRD (no public schema in the catalog).

If `kubeconform` is not installed, skip this step — `kubectl kustomize` succeeding is sufficient.

- [ ] **Step 5: Commit**

```bash
git add infrastructure/cloudflared
git commit -m "feat(cloudflared): add namespace, config, deployment and externalsecret manifests"
```

---

## Task 5: Wire cloudflared into Flux for the homelander cluster

**Files:**
- Create: `clusters/homelander/cloudflared.yaml`

- [ ] **Step 1: Write the Flux Kustomization**

Create `clusters/homelander/cloudflared.yaml`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cloudflared
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 1m
  path: ./infrastructure/cloudflared
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  dependsOn:
    - name: external-secrets
    - name: eso-store
    - name: ingress-nginx
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: cloudflared
      namespace: cloudflared
  timeout: 5m
```

- [ ] **Step 2: Verify the cluster's top-level kustomization picks it up automatically**

Run:
```bash
cat clusters/homelander/kustomization.yaml
```

Expected: a `Kustomization` that either explicitly lists per-app YAML files OR uses no `resources:` (in which case it picks up every `*.yaml` in the directory). If it lists files explicitly, add `- cloudflared.yaml` to the list. If it's a directory glob, no edit needed.

- [ ] **Step 3: If the cluster kustomization needed editing, update it**

Edit `clusters/homelander/kustomization.yaml` to include `cloudflared.yaml` in the resources list. Otherwise skip this step.

- [ ] **Step 4: Build the cluster kustomization to verify**

Run:
```bash
kubectl kustomize clusters/homelander | grep -E "name: cloudflared$" -A1
```

Expected: at least one match showing `name: cloudflared` (the Flux Kustomization).

- [ ] **Step 5: Commit**

```bash
git add clusters/homelander
git commit -m "feat(homelander): add Flux Kustomization for cloudflared"
```

---

## Task 6: Update n8n homelander Ingress to add the public host

**Files:**
- Modify: `apps/n8n/overlays/homelander/ingress-patch.yaml`

- [ ] **Step 1: Read the current patch**

Run:
```bash
cat apps/n8n/overlays/homelander/ingress-patch.yaml
```

Expected (matches what was read at plan-time):
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: n8n
  namespace: n8n
spec:
  tls:
    - hosts:
        - n8n.homelander.local
      secretName: n8n-tls
  rules:
    - host: n8n.homelander.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: n8n
                port:
                  number: 80
```

- [ ] **Step 2: Replace the file with both hosts**

Overwrite `apps/n8n/overlays/homelander/ingress-patch.yaml` with:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: n8n
  namespace: n8n
spec:
  tls:
    - hosts:
        - n8n.homelander.local
      secretName: n8n-tls
  rules:
    - host: n8n.homelander.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: n8n
                port:
                  number: 80
    - host: n8n.lab.quybits.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: n8n
                port:
                  number: 80
```

The `tls:` section deliberately does NOT include `n8n.lab.quybits.com` — Cloudflare terminates TLS at its edge, so the cluster does not need a cert for that hostname.

- [ ] **Step 3: Build the overlay**

Run:
```bash
kubectl kustomize apps/n8n/overlays/homelander | grep -A1 "host:"
```

Expected: two `host:` lines, one for `n8n.homelander.local` and one for `n8n.lab.quybits.com`.

- [ ] **Step 4: Commit**

```bash
git add apps/n8n/overlays/homelander/ingress-patch.yaml
git commit -m "feat(n8n): expose n8n.lab.quybits.com via cloudflared (homelander)"
```

---

## Task 7: Update grafana, qdrant, royal-dispatch overlays the same way

**Files:**
- Modify: `apps/grafana/overlays/homelander/ingress-patch.yaml`
- Modify: `apps/qdrant/overlays/homelander/ingress-patch.yaml`
- Modify: `apps/royal-dispatch/overlays/homelander/ingress-patch.yaml`

- [ ] **Step 1: Update grafana**

Overwrite `apps/grafana/overlays/homelander/ingress-patch.yaml` with:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: grafana
spec:
  tls:
    - hosts:
        - grafana.homelander.local
      secretName: grafana-tls
  rules:
    - host: grafana.homelander.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: grafana
                port:
                  number: 80
    - host: grafana.lab.quybits.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: grafana
                port:
                  number: 80
```

Verify:
```bash
kubectl kustomize apps/grafana/overlays/homelander | grep -A1 "host:"
```
Expected: `grafana.homelander.local` and `grafana.lab.quybits.com`.

- [ ] **Step 2: Update qdrant** (note: port `6333`, not `80`)

Overwrite `apps/qdrant/overlays/homelander/ingress-patch.yaml` with:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: qdrant
  namespace: qdrant
spec:
  tls:
    - hosts:
        - qdrant.homelander.local
      secretName: qdrant-tls
  rules:
    - host: qdrant.homelander.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: qdrant
                port:
                  number: 6333
    - host: qdrant.lab.quybits.com
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

Verify:
```bash
kubectl kustomize apps/qdrant/overlays/homelander | grep -A1 "host:"
```
Expected: `qdrant.homelander.local` and `qdrant.lab.quybits.com`.

- [ ] **Step 3: Update royal-dispatch (4 Ingresses, 2 hostnames)**

Overwrite `apps/royal-dispatch/overlays/homelander/ingress-patch.yaml` with:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: royal-dispatch-frontend
  namespace: royal-dispatch
spec:
  tls:
    - hosts:
        - royal-dispatch.homelander.local
      secretName: royal-dispatch-frontend-tls
  rules:
    - host: royal-dispatch.homelander.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend
                port:
                  number: 3000
    - host: royal-dispatch.lab.quybits.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend
                port:
                  number: 3000
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: royal-dispatch-frontend-api
  namespace: royal-dispatch
spec:
  tls:
    - hosts:
        - royal-dispatch.homelander.local
      secretName: royal-dispatch-frontend-tls
  rules:
    - host: royal-dispatch.homelander.local
      http:
        paths:
          - path: /api/(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: backend
                port:
                  number: 8000
    - host: royal-dispatch.lab.quybits.com
      http:
        paths:
          - path: /api/(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: backend
                port:
                  number: 8000
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: royal-dispatch-admin
  namespace: royal-dispatch
spec:
  tls:
    - hosts:
        - royal-dispatch-admin.homelander.local
      secretName: royal-dispatch-admin-tls
  rules:
    - host: royal-dispatch-admin.homelander.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: admin
                port:
                  number: 3001
    - host: royal-dispatch-admin.lab.quybits.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: admin
                port:
                  number: 3001
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: royal-dispatch-admin-api
  namespace: royal-dispatch
spec:
  tls:
    - hosts:
        - royal-dispatch-admin.homelander.local
      secretName: royal-dispatch-admin-tls
  rules:
    - host: royal-dispatch-admin.homelander.local
      http:
        paths:
          - path: /api/(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: backend
                port:
                  number: 8000
    - host: royal-dispatch-admin.lab.quybits.com
      http:
        paths:
          - path: /api/(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: backend
                port:
                  number: 8000
```

Verify:
```bash
kubectl kustomize apps/royal-dispatch/overlays/homelander | grep -c "host:"
```
Expected: `8` (four Ingresses × two hosts each).

- [ ] **Step 4: Commit**

```bash
git add apps/grafana/overlays/homelander/ingress-patch.yaml \
        apps/qdrant/overlays/homelander/ingress-patch.yaml \
        apps/royal-dispatch/overlays/homelander/ingress-patch.yaml
git commit -m "feat(apps): expose grafana/qdrant/royal-dispatch on *.lab.quybits.com via cloudflared"
```

---

## Task 8: Write the bootstrap script

**Files:**
- Create: `scripts/cloudflared-bootstrap.sh`

This script is run **once on the user's laptop** before the Flux Kustomization can become healthy. It is idempotent — re-running is safe.

- [ ] **Step 1: Create the script file**

Create `scripts/cloudflared-bootstrap.sh` with:

```bash
#!/usr/bin/env bash
# cloudflared-bootstrap.sh — one-time setup for the homelander Cloudflare Tunnel.
#
# Idempotent: safe to re-run.
# Required env (one of these paths must exist):
#   CF_API_TOKEN — Cloudflare API token with Zone:DNS:Edit on quybits.com.
#                  If absent, the DNS step is skipped and instructions are printed.
#
# Reads:  $HOME/.cloudflared/cert.pem (created via `cloudflared tunnel login`)
#         $HOME/.cloudflared/<UUID>.json (created via `cloudflared tunnel create`)
#         vault-init-homelander.json (root-token source, repo root)
# Writes: Vault path secret/cloudflared/tunnel-credentials (key: credentials.json)
# Prints: TUNNEL_UUID — the value to paste into infrastructure/cloudflared/configmap.yaml

set -euo pipefail

TUNNEL_NAME="homelander"
DNS_HOSTNAME="*.lab.quybits.com"
ZONE_NAME="quybits.com"
EXPECTED_CONTEXT="homelander"
VAULT_PATH="secret/cloudflared/tunnel-credentials"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VAULT_INIT_FILE="${SCRIPT_DIR}/vault-init-homelander.json"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
err() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Preflight: kube context must be homelander ---
current_ctx="$(kubectl config current-context 2>/dev/null || true)"
if [[ "$current_ctx" != "$EXPECTED_CONTEXT" ]]; then
  err "kubectl current-context is '$current_ctx', expected '$EXPECTED_CONTEXT'. Run 'kubectx $EXPECTED_CONTEXT' and retry."
fi

# --- Preflight: cloudflared CLI ---
if ! command -v cloudflared >/dev/null 2>&1; then
  log "cloudflared CLI not found — installing via Homebrew"
  if ! command -v brew >/dev/null 2>&1; then
    err "Homebrew not installed. Install cloudflared manually: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
  fi
  brew install cloudflared
fi

# --- Preflight: jq (used to extract token + parse cloudflared output) ---
if ! command -v jq >/dev/null 2>&1; then
  err "jq is required. Install with: brew install jq"
fi

# --- Preflight: vault-init-homelander.json exists ---
if [[ ! -f "$VAULT_INIT_FILE" ]]; then
  err "$VAULT_INIT_FILE not found. Cannot read Vault root token."
fi

# --- Step 1: cloudflared tunnel login (if needed) ---
if [[ ! -f "$HOME/.cloudflared/cert.pem" ]]; then
  log "Authenticating to Cloudflare (browser will open)"
  cloudflared tunnel login
else
  log "Cloudflare cert.pem present — skipping login"
fi

# --- Step 2: Create tunnel if it doesn't exist ---
existing_uuid="$(cloudflared tunnel list --output json | jq -r --arg n "$TUNNEL_NAME" '.[] | select(.name == $n) | .id' || true)"
if [[ -n "$existing_uuid" && "$existing_uuid" != "null" ]]; then
  log "Tunnel '$TUNNEL_NAME' already exists (UUID: $existing_uuid)"
  TUNNEL_UUID="$existing_uuid"
else
  log "Creating tunnel '$TUNNEL_NAME'"
  cloudflared tunnel create "$TUNNEL_NAME"
  TUNNEL_UUID="$(cloudflared tunnel list --output json | jq -r --arg n "$TUNNEL_NAME" '.[] | select(.name == $n) | .id')"
  if [[ -z "$TUNNEL_UUID" || "$TUNNEL_UUID" == "null" ]]; then
    err "Tunnel created but UUID could not be read"
  fi
fi

CRED_FILE="$HOME/.cloudflared/${TUNNEL_UUID}.json"
if [[ ! -f "$CRED_FILE" ]]; then
  err "Credentials file $CRED_FILE not found. Re-run after deleting the tunnel via the Cloudflare dashboard, or copy the file from wherever the tunnel was originally created."
fi

# --- Step 3: Wildcard DNS CNAME via Cloudflare API (or print manual instructions) ---
TARGET="${TUNNEL_UUID}.cfargotunnel.com"
if [[ -n "${CF_API_TOKEN:-}" ]]; then
  log "Ensuring DNS record: $DNS_HOSTNAME CNAME $TARGET (proxied)"

  zone_id="$(curl -fsSL -H "Authorization: Bearer $CF_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones?name=${ZONE_NAME}" \
    | jq -r '.result[0].id')"
  if [[ -z "$zone_id" || "$zone_id" == "null" ]]; then
    err "Could not resolve zone ID for $ZONE_NAME. Check CF_API_TOKEN scope (Zone:Read on $ZONE_NAME)."
  fi

  existing_record="$(curl -fsSL -H "Authorization: Bearer $CF_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=CNAME&name=${DNS_HOSTNAME}" \
    | jq -r '.result[0]')"

  if [[ "$existing_record" != "null" ]]; then
    existing_target="$(echo "$existing_record" | jq -r '.content')"
    record_id="$(echo "$existing_record" | jq -r '.id')"
    if [[ "$existing_target" == "$TARGET" ]]; then
      log "DNS record already correct — skipping"
    else
      log "Updating existing DNS record (was: $existing_target)"
      curl -fsSL -X PUT \
        -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
        "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" \
        -d "{\"type\":\"CNAME\",\"name\":\"${DNS_HOSTNAME}\",\"content\":\"${TARGET}\",\"proxied\":true}" \
        > /dev/null
    fi
  else
    log "Creating new DNS record"
    curl -fsSL -X POST \
      -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
      "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
      -d "{\"type\":\"CNAME\",\"name\":\"${DNS_HOSTNAME}\",\"content\":\"${TARGET}\",\"proxied\":true}" \
      > /dev/null
  fi
else
  log "CF_API_TOKEN not set — skipping automated DNS"
  cat <<EOF

  >>> MANUAL STEP REQUIRED <<<
  In the Cloudflare dashboard for zone $ZONE_NAME, add a DNS record:
    Type:    CNAME
    Name:    *.lab
    Target:  $TARGET
    Proxy:   Proxied (orange cloud, ON)

EOF
fi

# --- Step 4: Store credentials.json in Vault ---
log "Storing credentials in Vault at $VAULT_PATH"
ROOT_TOKEN="$(jq -r '.root_token' "$VAULT_INIT_FILE")"
if [[ -z "$ROOT_TOKEN" || "$ROOT_TOKEN" == "null" ]]; then
  err "root_token not found in $VAULT_INIT_FILE"
fi

# `vault kv put` reads from stdin via @-, but kubectl exec doesn't pipe well.
# Workaround: copy the file into the pod, write from there, then delete.
TMP_NAME="cloudflared-creds-$(date +%s).json"
kubectl -n vault cp "$CRED_FILE" "vault-0:/tmp/${TMP_NAME}"
kubectl -n vault exec vault-0 -- env VAULT_TOKEN="$ROOT_TOKEN" \
  vault kv put "$VAULT_PATH" "credentials.json=@/tmp/${TMP_NAME}" >/dev/null
kubectl -n vault exec vault-0 -- rm "/tmp/${TMP_NAME}"

# --- Step 5: Print the UUID for the user ---
cat <<EOF

==========================================================================
  Bootstrap complete.

  TUNNEL_UUID: $TUNNEL_UUID

  NEXT STEP (one-time, manual):
    1. Open infrastructure/cloudflared/configmap.yaml
    2. Replace the literal string:
         REPLACE_WITH_TUNNEL_UUID
       with:
         $TUNNEL_UUID
    3. Commit and push. Flux will reconcile within ~10 minutes
       (or run: flux reconcile kustomization cloudflared --with-source)

==========================================================================
EOF
```

- [ ] **Step 2: Make it executable**

Run:
```bash
chmod +x scripts/cloudflared-bootstrap.sh
```

- [ ] **Step 3: Lint with shellcheck (if available)**

Run:
```bash
shellcheck scripts/cloudflared-bootstrap.sh || true
```

Expected: zero or only style-level warnings (SC2086 word-splitting on intentionally unquoted strings is acceptable; nothing here looks like a real bug). If shellcheck flags a real issue (undefined variable, command substitution failure handling), fix it inline.

If shellcheck is not installed, skip — `set -euo pipefail` provides most of the safety.

- [ ] **Step 4: Bash syntax check (always run)**

Run:
```bash
bash -n scripts/cloudflared-bootstrap.sh
```

Expected: no output (clean parse).

- [ ] **Step 5: Commit**

```bash
git add scripts/cloudflared-bootstrap.sh
git commit -m "feat(scripts): add idempotent cloudflared bootstrap script"
```

---

## Task 9: Run the bootstrap (one-time, manual, on user's laptop)

This task is **not run by an agent** — it requires browser interaction (Cloudflare login) and a Cloudflare API token the user holds. Mark steps complete as you do them.

- [ ] **Step 1: Create a Cloudflare API token (skip if you already have one)**

Go to https://dash.cloudflare.com/profile/api-tokens, click "Create Token", use the "Edit zone DNS" template, scope it to the `quybits.com` zone, and copy the resulting token.

- [ ] **Step 2: Export the token and run the bootstrap**

```bash
kubectx homelander
export CF_API_TOKEN="<paste-token-here>"
./scripts/cloudflared-bootstrap.sh
```

Expected output ends with:
```
TUNNEL_UUID: <some-uuid>
```

- [ ] **Step 3: Paste the UUID into the ConfigMap**

Edit `infrastructure/cloudflared/configmap.yaml` and replace the literal string `REPLACE_WITH_TUNNEL_UUID` with the UUID from Step 2.

Verify:
```bash
grep -c "REPLACE_WITH_TUNNEL_UUID" infrastructure/cloudflared/configmap.yaml
```
Expected: `0`.

```bash
grep "tunnel:" infrastructure/cloudflared/configmap.yaml
```
Expected: a line like `    tunnel: 12345678-aaaa-bbbb-cccc-deadbeef0001`.

- [ ] **Step 4: Verify Vault has the secret**

```bash
kubectl exec -n vault vault-0 -- \
  env VAULT_TOKEN="$(jq -r .root_token vault-init-homelander.json)" \
  vault kv get secret/cloudflared/tunnel-credentials
```

Expected: a key `credentials.json` with a JSON blob value containing `AccountTag`, `TunnelID`, `TunnelSecret`.

- [ ] **Step 5: Commit the UUID**

```bash
git add infrastructure/cloudflared/configmap.yaml
git commit -m "chore(cloudflared): pin tunnel UUID after bootstrap"
git push
```

---

## Task 10: Verify Flux applies cleanly and the tunnel comes up

- [ ] **Step 1: Force Flux reconciliation**

```bash
flux reconcile kustomization flux-system --with-source
flux reconcile kustomization cloudflared --with-source
```

- [ ] **Step 2: Wait for the Kustomization to report healthy**

```bash
flux get kustomization cloudflared
```

Expected: `READY=True`, `STATUS` mentions a successful apply revision. May take up to 5 minutes (the `timeout: 5m` from Task 5).

- [ ] **Step 3: Verify ExternalSecret synced**

```bash
kubectl -n cloudflared get externalsecret cloudflared-credentials
```

Expected: `STATUS=SecretSynced`, `READY=True`.

If `STATUS=SecretSyncedError`, run `kubectl describe externalsecret -n cloudflared cloudflared-credentials` and look at the `Events:` and `Status:` blocks. Most likely cause: the Vault path or property name doesn't match exactly. Fix the path in `externalsecret.yaml` (or re-run the bootstrap if Vault doesn't actually have the data).

- [ ] **Step 4: Verify the in-cluster Secret exists with the credentials**

```bash
kubectl -n cloudflared get secret cloudflared-credentials -o jsonpath='{.data.credentials\.json}' | base64 -d | jq 'keys'
```

Expected: a JSON array containing at least `"AccountTag"`, `"TunnelID"`, `"TunnelSecret"`.

- [ ] **Step 5: Verify the cloudflared pods are running**

```bash
kubectl -n cloudflared get pods -l app=cloudflared
```

Expected: 2 pods, `STATUS=Running`, `READY=1/1`.

- [ ] **Step 6: Verify the tunnel actually connected**

```bash
kubectl -n cloudflared logs -l app=cloudflared --tail=50 --prefix=true
```

Expected: lines like `Registered tunnel connection ... connIndex=0` (and 1, 2, 3) for each pod. If you see `error="Unauthorized"` or similar, the credentials in the Secret don't match the tunnel UUID in the ConfigMap — re-check that the UUID you pasted in Task 9 Step 3 matches the one printed by the bootstrap script.

---

## Task 11: End-to-end verification of public access

- [ ] **Step 1: Check DNS resolves to Cloudflare**

```bash
dig +short n8n.lab.quybits.com
```

Expected: one or more IPv4 addresses in Cloudflare's range (usually 104.x or 172.67.x). If you see a non-Cloudflare IP, the wildcard CNAME is wrong — check the Cloudflare dashboard.

- [ ] **Step 2: HTTPS works with a real cert**

```bash
curl -sSI https://n8n.lab.quybits.com | head -5
```

Expected: a response line like `HTTP/2 200` or `HTTP/2 302`. No `curl: (...)` errors. No `-k` needed (real Cloudflare-signed cert).

- [ ] **Step 3: Spot-check the other apps**

```bash
for h in grafana.lab.quybits.com qdrant.lab.quybits.com royal-dispatch.lab.quybits.com royal-dispatch-admin.lab.quybits.com; do
  printf "%-40s " "$h"
  curl -sSI "https://$h" -o /dev/null -w "%{http_code}\n" || echo "FAIL"
done
```

Expected: each line ends with `200`, `302`, `401`, or `404` from the app itself (anything < 500 means the path through Cloudflare → cloudflared → ingress-nginx → the service is intact). A `502` means cloudflared can't reach ingress-nginx; a `530` means DNS/tunnel is misrouted.

- [ ] **Step 4: Verify LAN path still works**

```bash
curl -kSI https://n8n.homelander.local | head -3
```

Expected: same `HTTP/2 200`/`302` as before. The `-k` is still required because LAN traffic uses the self-signed CA.

- [ ] **Step 5: Browser test n8n end-to-end**

Open `https://n8n.lab.quybits.com` in a browser. Log in. Open the editor (uses websockets — important to verify since long-lived connections are easy to break with proxy misconfiguration).

If the editor loads and saves a workflow, the tunnel is fully functional.

- [ ] **Step 6: Update README with the new URLs**

Edit `README.md` to add a short section listing the public URLs for the homelander cluster:

```markdown
### Homelander — Public URLs (via Cloudflare Tunnel)

| Service | LAN | Public |
|---|---|---|
| n8n | https://n8n.homelander.local | https://n8n.lab.quybits.com |
| grafana | https://grafana.homelander.local | https://grafana.lab.quybits.com |
| qdrant | https://qdrant.homelander.local | https://qdrant.lab.quybits.com |
| royal-dispatch | https://royal-dispatch.homelander.local | https://royal-dispatch.lab.quybits.com |
| royal-dispatch admin | https://royal-dispatch-admin.homelander.local | https://royal-dispatch-admin.lab.quybits.com |
```

Place the section after the existing cluster table near the top of the README.

Commit:
```bash
git add README.md
git commit -m "docs: add homelander public URLs via cloudflared"
git push
```

---

## Self-review (against spec)

Verified after writing the plan:

- ✅ Spec section "Architecture" → Tasks 1–4 (manifests) + Task 5 (Flux) + Task 7 (per-app hosts).
- ✅ Spec section "Repository layout / New files" → Tasks 1–4 (4 files in `infrastructure/cloudflared/`), Task 5 (`clusters/homelander/cloudflared.yaml`), Task 8 (`scripts/cloudflared-bootstrap.sh`).
- ✅ Spec section "Repository layout / Modified files" → Tasks 6 + 7.
- ✅ Spec section "Bootstrap script requirements" (idempotent, kube-context check, brew install fallback, login if no cert.pem, tunnel-create idempotent, wildcard DNS via API with fallback, Vault write, no repo mutation, prints UUID) → Task 8 covers each requirement explicitly.
- ✅ Spec section "Data flow" → Tasks 9 + 10 walk through it operationally.
- ✅ Spec section "Testing & validation / Pre-merge" → Tasks 4, 6, 7 verification steps run `kubectl kustomize`.
- ✅ Spec section "Testing & validation / Post-Flux reconcile" → Task 10.
- ✅ Spec section "Testing & validation / End-to-end" → Task 11.
- ✅ Spec section "Open items / ingress-nginx Service name" → resolved at plan-time (`ingress-nginx-controller.ingress-nginx.svc.cluster.local`); used directly in Task 2.
- ✅ Spec section "Open items / per-app Ingress name/service/port" → resolved at plan-time; concrete values in Tasks 6 and 7.
- ✅ Spec section "Open items / cloudflared image tag" → Task 4 Step 1 fetches the latest tag at execution time.
- ✅ Spec section "Open items / royal-dispatch has a homelander Ingress" → resolved at plan-time (yes, 4 of them); Task 7 Step 3.
- ✅ Spec section "Open items / Cloudflare API token" → Task 8 (`CF_API_TOKEN` env var with graceful manual fallback) + Task 9 Step 1.
- ✅ All file paths are absolute relative to the repo root, no placeholders left in any code block (`REPLACE_WITH_TUNNEL_UUID` is intentional and explicitly removed in Task 9 Step 3 with a verification command).
- ✅ Type/name consistency: `cloudflared-credentials` (Secret), `cloudflared-config` (ConfigMap), `app: cloudflared` (label), `cloudflared` (Deployment + Flux Kustomization + Namespace), `ingress-nginx-controller.ingress-nginx.svc.cluster.local:80` — used identically across all tasks.
