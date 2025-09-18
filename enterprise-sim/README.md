# Enterprise Simulation Plan

This package simulates a multi‑region, zero‑trust, production‑style Istio setup on a single k3s (k3d) cluster. It is intentionally minimal — no extra app stacks — and focuses on platform patterns: regions, security defaults, a shared wildcard gateway, and platform‑driven routing so developers remain environment‑agnostic.

## Goals
- Simulate multi‑region topology via namespaces with region semantics.
- Enforce zero‑trust defaults: STRICT mTLS, minimal AuthZ, and baseline NetworkPolicies.
- Use a single wildcard TLS gateway for the environment; flattened hostnames.
- Platform‑driven routing (reconciler) from simple Service labels.
- Optional canary and failover helpers; observability checks.
- Keep developers unaware of Istio internals; they only expose a Service with minimal metadata.

## Folder Layout (planned)
- `enterprise-sim.sh` — CLI for cluster lifecycle, Istio install, policies, gateway, routing, and helpers.
- `manifests/`
  - `regions/` — `region-us.yaml`, `region-eu.yaml`, `region-ap.yaml`
  - `security/` — `mtls-peer-auth.yaml`, `authz-allow-ingress.yaml`, `baseline-netpol.yaml`
  - `gateway/` — `wildcard-gateway-template.yaml`
  - `routing/` — `virtualservice-template.yaml`, `destinationrule-template.yaml`
  - `egress/` — optional examples (not applied by default)

## Variables (to be used by the CLI)
- `K3S_INGRESS_DOMAIN` — e.g., `prod.butterflycluster.com`. If not set, the CLI warns and defaults to `localhost` for simple local testing.
- `TLS_SECRET_NAME` — wildcard TLS secret name (self‑signed default; LE optional).
- `GATEWAY_NAME` — default `${ENV}-sim-gateway`.
- Regions — default set: `us, eu, ap`.

## Milestones (staged, testable)

1) Scaffold
- Create `enterprise-sim/` with this README and placeholder files.
- Validate: folder exists and README describes the plan.

2) Cluster Up/Down
- Provision k3d/k3s with ports 80/443 mapped; disable Traefik.
- Commands: `up`, `down` in `enterprise-sim.sh`.
- Validate: `k3d cluster list`, `kubectl get nodes`.

3) TLS Setup
- Provide wildcard TLS for `*.${K3S_INGRESS_DOMAIN}`.
- Modes: self‑signed (default) or Let’s Encrypt via cert‑manager (Cloudflare DNS01) if credentials available.
- Validate: `kubectl -n istio-system get secret <tls>`. If LE: issuers/certificates Ready.

4) Istio Install
- Install Istio control plane and ingress gateway (default profile), ensure health.
- Validate: `kubectl -n istio-system get deploy istiod istio-ingressgateway`, rollout status, `istioctl version`.

5) Regions
- Create namespaces `region-us`, `region-eu`, `region-ap` with labels:
  - `istio-injection=enabled`
  - `compliance.region={us|eu|ap}`
- Validate: `kubectl get ns region-us -o jsonpath='{.metadata.labels}'`.

6) Zero‑Trust Policies
- Apply per‑region:
  - PeerAuthentication STRICT
  - Minimal AuthorizationPolicy allowing ingress via gateway
  - Baseline NetworkPolicy:
    - Egress allow to CoreDNS (UDP/TCP 53) in `kube-system`
    - Egress allow to `istiod` TCP 15012 in `istio-system`
    - Ingress allow from `istio=ingressgateway` in `istio-system`
    - Default‑deny otherwise
- Validate: resources present; busybox pod can resolve DNS; TCP 15012 reachable.

7) Wildcard Gateway
- Apply one shared Gateway in `istio-system`:
  - Hosts: `*.${K3S_INGRESS_DOMAIN}`
  - TLS: `credentialName: ${TLS_SECRET_NAME}`
  - HTTP→HTTPS redirect
- Validate: `kubectl -n istio-system get gateway`, ingress service ports; `curl -kI https://dummy.${K3S_INGRESS_DOMAIN}` → 404 until routes exist.

8) Route Reconciler
- Developer contract (on a Service):
  - `compliance.routing/enabled: "true"`
  - Optional: `compliance.routing/host: "<app>"`, `compliance.routing/port: "<port>"`
- Platform behavior:
  - Hostname = `<region>-<app>.${K3S_INGRESS_DOMAIN}` where `region` from namespace label and `app` from label or Service name.
  - Generate VirtualService bound to the wildcard Gateway, routing to the Service:port.
- Validate: create a labeled Service, run `routes reconcile`, confirm VS and connectivity.

9) Canary Helper
- Subsets by Deployment label `version: v1|v2`; set weights via `canary set <ns> <svc> <v1%> <v2%>`.
- Validate: deploy v1/v2, observe split traffic (logs/metrics).

10) Failover Helper
- Simulate cross‑region failover by shifting N% from one region’s service to another region’s service via VS updates.
- Validate: set 20% failover; confirm traffic reaches target region.

11) Status & Validate
- `status`: show cluster/gateway health, regions, eligible Services, VS counts.
- `validate`: CoreDNS endpoints, DNS resolution from a pod, xDS (15012) reachability, gateway hosts, `istioctl analyze` on routing.
- Validate: both commands provide actionable green/red checks and hints.

12) README Runbooks
- Finalize README with setup, DNS guidance (k3d maps 80/443 to host), developer contract, and troubleshooting:
  - 404 NR → host/gateway mismatch
  - 503 UF/NR → endpoints/subsets
  - DNS/xDS → NetworkPolicy or CoreDNS issues

## Developer Experience (DX) Contract
- Developers do not interact with Istio resources.
- They only expose a Kubernetes Service and add `compliance.routing/enabled=true` plus optional `host`/`port` metadata.
- Platform produces the environment‑aware route and enforces security and reliability defaults.

## Notes
- DNS for local k3d: point A records for `*.${K3S_INGRESS_DOMAIN}` to the host running k3d; 80/443 are port‑mapped to the ingress gateway.
- Let’s Encrypt via DNS‑01 is independent of A records; use Cloudflare credentials when available.
- Egress control is documented with examples; not applied by default in the initial milestones.
