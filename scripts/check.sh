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
kustomize build apps/staging \
  | kubeconform -strict -summary -kubernetes-version 1.35.5 -skip Secret,PublicEndpoint

echo "== all checks passed"
