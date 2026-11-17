# 0011: A fine-grained GitHub token for Renovate

## Status

Accepted (2026-11-17)

## Context

Renovate runs as a CronJob in the cluster and needs a GitHub token to read the repositories and to open branches and pull requests. Since it was set up, it used a classic personal access token (`renovate-pi`). A classic token works with broad scopes: this one could write to every repository I own, and it never expired.

The token is stored in a SOPS-encrypted Secret (`renovate-container-env`, key `RENOVATE_TOKEN`), so it can't be read from Git. But it is also an environment variable in every Renovate pod, and it is decrypted on my laptop whenever I edit the Secret. A leak from any of those places would have given write access to all my repositories, with no end date.

Renovate only works on four repositories: `pi-cluster`, `pvc-backup`, `cluster-status` and `publicendpoint-operator`.

## Decision

Replace the classic token with a fine-grained token, `renovate-pi-cluster`, limited in three ways:

- **Repositories:** only the four above.
- **Permissions:** only the ones Renovate's documentation lists for a fine-grained token:
  - Contents, Pull requests, Issues, Commit statuses and Workflows: read and write
  - Dependabot alerts: read-only
  - Metadata: read-only (GitHub adds it to every token)
- **Expiry:** one year, until 2027-11-17.

The new token goes into the same Secret, so the CronJob doesn't change. Values under `data:` are base64, so the token is encoded first (`printf %s`, not `echo`, so no newline ends up in it).

The switch was done in this order, so I could go back at any step:

1. Create the fine-grained token.
2. Replace the value in the Secret, through a pull request.
3. Check that the Secret in the cluster starts with `github_pat_` (a classic token starts with `ghp_`).
4. Start a Job from the CronJob by hand and check that it went through all four repositories without errors.
5. Only then revoke the classic token.

## Consequences

- A leaked token now gives access to four repositories, with only the permissions Renovate uses, for at most a year. The classic token is revoked.
- The token has to be renewed every year. A calendar reminder is set for a week before it expires. If I miss it, Renovate stops opening pull requests; nothing in the cluster breaks.
- A new repository for Renovate has to be added to the token too. Otherwise Renovate can't see it.
- Fine-grained tokens can't use GitHub's Checks API. That only matters if Renovate merges pull requests by itself. I merge by hand through the protected `main` ([0009](0009-ci-github-actions.md)), and the repositories are public, so Renovate can still read the check results.
- Alternatives considered:
  - A GitHub App, which Renovate recommends. Its tokens are short-lived and created on demand, but it needs an app registration, a private key in the cluster and a step that creates the tokens. For one person and four repositories that is more moving parts than the risk justifies. It is the next step if the setup grows.
  - Keeping a classic token with fewer scopes. Classic scopes can't be limited to selected repositories, so a leak would still reach all of them.
