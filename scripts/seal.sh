#!/usr/bin/env bash
# Seal a secret for an environment with the cluster's Sealed Secrets controller key. The output is safe to commit.
#   scripts/seal.sh oci search search-api-secrets HSS_ADMIN_KEY=<value>
#   scripts/seal.sh oci forecast forecast-api-secrets DFP_API_KEYS=<key1,key2>
set -euo pipefail
cd "$(dirname "$0")/.."
ENV_NAME="$1"; NS="$2"; NAME="$3"; shift 3
mkdir -p "envs/$ENV_NAME/secrets"
kubectl create secret generic "$NAME" -n "$NS" --dry-run=client -o yaml "${@/#/--from-literal=}" \
  | kubeseal --controller-name sealed-secrets-controller --controller-namespace kube-system --format yaml \
  > "envs/$ENV_NAME/secrets/$NAME.yaml"
echo "wrote envs/$ENV_NAME/secrets/$NAME.yaml (add it to the chart's extra manifests or apply it alongside)"
