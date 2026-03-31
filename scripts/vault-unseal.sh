#!/bin/bash
set -e

INIT_FILE="${1:-vault-init.json}"

if [[ ! -f "$INIT_FILE" ]]; then
  echo "Error: $INIT_FILE not found"
  echo "Usage: $0 [path-to-vault-init.json]"
  exit 1
fi

KEYS=$(jq -r '.unseal_keys_b64[]' "$INIT_FILE")
TOTAL=$(echo "$KEYS" | wc -l | tr -d ' ')
THRESHOLD=$(jq -r '.unseal_threshold // 2' "$INIT_FILE")

# Pick $THRESHOLD random unique indices (1-based)
INDICES=($(shuf -i 1-$TOTAL -n $THRESHOLD))

echo "Unsealing Vault using $THRESHOLD of $TOTAL keys (keys: ${INDICES[*]})..."

for i in "${INDICES[@]}"; do
  KEY=$(echo "$KEYS" | sed -n "${i}p")
  echo "Applying key $i..."
  kubectl exec -n vault vault-0 -- vault operator unseal "$KEY"
done

echo ""
echo "Done. Current Vault status:"
kubectl exec -n vault vault-0 -- vault status
