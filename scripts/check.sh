#!/usr/bin/env bash
# Checks the apps before Flux sees them. CI runs this on every push; I run it before pushing.
# Needs: yamllint, kustomize, kubeconform.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

echo "== yamllint"
yamllint --strict apps/

echo "== kustomize build + kubeconform"
# Skipped: Secret (sops adds fields the schema doesn't know) and
# PublicEndpoint (my own CRD, not in the Kubernetes schemas).
kustomize build apps/staging |
  kubeconform -strict -summary -kubernetes-version 1.35.5 -skip Secret,PublicEndpoint

echo "== secrets encrypted"
# Whole repo, not only apps/: secrets also live in infrastructure/ and monitoring/.
# .sops.yaml at the repo root is the SOPS config, not a secret.
for f in $(git ls-files '*.sops.yaml' | grep -v '^\.sops\.yaml$'); do
  grep -q '^sops:' "$f" || {
    echo "not encrypted: $f"
    exit 1
  }
done

echo "== all checks passed"
