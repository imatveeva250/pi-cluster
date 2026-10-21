# PublicEndpoint operator

- Status: Accepted
- Date: 2026-10-21

## Context

Two applications are reachable from the internet through Cloudflare tunnels. Nothing in the
cluster checked whether they are actually reachable from outside: a broken tunnel, DNS record
or application would go unnoticed. Each application should declare its own public endpoint, so
the check is added and removed together with the application.

## Decisions

### 1. A custom resource and an own operator

A `PublicEndpoint` custom resource declares a URL to check. An operator, written in this
project, checks each one on a schedule and writes the result into the resource's status.
Source: `imatveeva250/publicendpoint-operator` (MIT).

- Each application declares its endpoint in its own folder; deleting the application deletes
  the check.
- Results are visible with `kubectl get publicendpoints -A`, without a separate dashboard.

Alternative considered: Prometheus blackbox exporter with probe targets in its configuration.
It is an established tool, but targets live in one central configuration instead of next to
each application, and results are only visible through Prometheus.

### 2. API design

- Group `homelab.matveeva.dev`, version `v1alpha1`, namespaced.
- Spec: `url` (required, must start with `https://`) and `intervalSeconds` (30 to 3600,
  default 60). Validation is done by the API server, so invalid objects are never stored.
  Accepting only `https` URLs keeps the operator from being used to probe internal addresses.
- Status: `reachable`, `httpStatus`, `latencyMs`, `lastChecked`, `message`. A status code
  below 400 counts as reachable; redirects are followed.
- Status is a subresource: writes to the object cannot change status, and the operator writes
  status without touching spec.
- Every field has a description, so `kubectl explain publicendpoint` documents the API.

### 3. Implementation

- Python with kopf. A timer looks at each object every 10 seconds and checks it only when
  `lastChecked` is older than its interval. The decision is made from the object's own state,
  so a restart loses nothing.
- kopf keeps its own bookkeeping in annotations, because the schema prunes unknown status
  fields.
- kopf adds a finalizer to each object. Deleting a `PublicEndpoint` therefore waits until the
  operator is running.

### 4. Placement and ordering

The CRD and the operator are part of `infrastructure-controllers`. The `apps` Kustomization
depends on it, so the CRD exists before any `PublicEndpoint` object is applied.

### 5. Permissions

The operator runs as its own ServiceAccount with a ClusterRole limited to:

- `publicendpoints`: list, watch, patch (finalizers and annotations)
- `publicendpoints/status`: patch
- `events`: create
- `customresourcedefinitions`: list, watch (read-only; kopf observes available resource types)

It cannot read Secrets, list Pods, or create or delete `PublicEndpoint` objects; verified with
`kubectl auth can-i`. RBAC works per resource, not per field, so the patch permission needed
for finalizers would also allow changes to spec; the operator does not make them.

### 6. Deployment

- One replica with `strategy: Recreate`. The operator runs without coordination between
  instances, so two copies must never run at the same time.
- Liveness probe on kopf's built-in health endpoint. No readiness probe: the operator has no
  Service and receives no traffic.
- Runs as UID 10001, `runAsNonRoot`, read-only root filesystem, no privilege escalation, all
  capabilities dropped. Memory requests and limits from the first deployment.
- Image built by GitHub Actions on an arm64 runner and published to GHCR with version tags
  only; release tags are protected against changes.

## Consequences

- Each public endpoint is checked through the same path a visitor uses, including the tunnel.
- If the operator is down, statuses stop updating; `lastChecked` shows how old a result is.
- Deleting a `PublicEndpoint`, or a namespace containing one, waits for the operator. If the
  operator is permanently gone, the finalizer has to be removed by hand.
- One more image to release and keep up to date.
