# 0009: Repository checks with GitHub Actions

## Status

Accepted (2026-11-11), updated 2026-11-12 (secrets check, protected `main`)

## Context

Flux applies whatever is on `main`. Until now, the first thing to read a change was Flux itself, on the live cluster. A mistake in a manifest showed up as a Kustomization that was not Ready, and because Flux applies a Kustomization all or nothing, one broken file blocked every other change in the same path.

My most common mistakes are YAML ones: a missing dash that turns a list into a map, a wrong indentation, a typo in a file name in `kustomization.yaml`.

The node has 4 GB of RAM, and memory is what runs out first. One Renovate run (about 600Mi) was already enough to set off a memory alert.

## Decision

A GitHub Actions workflow, `.github/workflows/check.yaml`, runs `scripts/check.sh` on every pull request, on every push to `main`, and by hand. I run the same script on my laptop before pushing.

Changes reach `main` only through a pull request whose check is green. The `protect-main` ruleset requires a pull request (with no approvals, since I can't approve my own) and the status check `apps`, and still blocks force pushes and deletions. The bypass list is empty. In GitOps, merging is deploying: whatever lands on `main`, Flux applies.

I start small, with the apps (`apps/staging`), where I change things most often:

- **yamllint** on `apps/` with a repository config (`.yamllint.yaml`): line length and document start markers are off, sequences may be indented or not, and SOPS files keep SOPS's own indentation.
- **kustomize build** of `apps/staging`, which fails on a missing or misspelled file in a `kustomization.yaml`.
- **kubeconform** in strict mode on the rendered output, against the Kubernetes 1.35.5 schemas (the cluster's version). Secrets are skipped because SOPS adds fields the schema doesn't know, and `PublicEndpoint` because it is my own CRD.
- **Secrets encrypted**, for the whole repository, not only `apps/`: every tracked `*.sops.yaml` file (except the SOPS config `.sops.yaml`) must contain the `sops:` block that SOPS adds when it encrypts a file.

Tool versions are pinned in the workflow; each run installs them on a fresh runner.

## Consequences

- I tested it on a copy of the repository. A missing dash and a misspelled file name in a `kustomization.yaml` turn it red.
- A secret file that was never encrypted turns it red too (tested with an unencrypted copy of a manifest named `*.sops.yaml`).
- Not caught yet: a YAML file that exists but is not listed in its `kustomization.yaml`, an app removed from `apps/staging/kustomization.yaml`, and a single plaintext value added to a file that is otherwise encrypted. The infrastructure and monitoring manifests are not linted or validated yet either. The gate is only as good as what it checks.
- kubeconform checks structure, not meaning. A wrong port or a value copied from another app still passes, as long as it has the right type.
- Nothing runs in the cluster, so CI costs no memory on the node. CI depends on GitHub, which Flux already depends on.
- A red check now blocks the merge, so a broken change can't reach Flux. Every change, mine and Renovate's, goes through a pull request; `gh pr merge --squash --auto` merges it as soon as the check is green.
- If GitHub Actions itself is down, nothing can be merged. The way out is to switch the rule off in the ruleset settings for that time, on purpose and visibly.
- When k3s is upgraded, the Kubernetes version in `scripts/check.sh` changes in the same commit.
- Alternatives considered:
  - Forgejo Actions with a runner in the cluster would keep CI on my own hardware, but the runner and a container per job need memory the node does not have, and Forgejo holds no repositories.
  - Checking only with `flux diff` before each push depends on me remembering to do it, and needs access to the cluster.
