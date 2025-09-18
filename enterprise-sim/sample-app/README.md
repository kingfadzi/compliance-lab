# Sample HTTPS Application for Istio Mesh

A minimal Python Flask HTTPS application designed for Sail Operator-managed Istio mesh in a compliance-oriented Kubernetes setup.

## Features

- **HTTPS Service**: Flask app with self-signed TLS certificates on port 443
- **Compliance Ready**: Security headers, non-root user, resource limits
- **Istio Compatible**: Works with Sail Operator and ambient mesh
- **Health Checks**: `/health`, `/ready`, and `/metrics` endpoints
- **Auto-Routing**: Compatible with `enterprise-sim.sh routes reconcile`

## Quick Deploy

### Deploy with `kubectl` + Kustomize (Recommended)

```bash
# 1. Review and edit the defaults in sample-app/.env
vi sample-app/.env

# (optional) export them for shell convenience
set -a && source sample-app/.env && set +a

# 2. Apply the full stack with kubectl's built-in Kustomize support
kubectl apply -k sample-app

# 3. (Optional) Trigger the enterprise routing reconciler if using auto-hosts
./enterprise-sim.sh routes reconcile
```

The app will be available at: `https://<region>-<route_host>.<ingress_domain>` using the values from `.env` (defaults to `https://us-hello.localhost`).

> `kubectl apply -k sample-app` creates a `sample-app-env` ConfigMap sourced from `.env`, so any change to that file will flow into both the pod environment variables and the Istio routing templates on the next apply.

### Preview or customize the manifests

```bash
# Diff the rendered resources before applying
kubectl kustomize sample-app | less

# Update a single value (e.g., switch namespace) then re-apply
# (edit sample-app/.env with your preferred editor)
kubectl apply -k sample-app

# Clean up
kubectl delete -k sample-app
```

## Application Endpoints

- `GET /` - Main application endpoint with request info
- `GET /health` - Health check for liveness probes
- `GET /ready` - Readiness check for readiness probes
- `GET /metrics` - Basic metrics endpoint

## Security Features

- **Non-root container**: Runs as user 1000
- **Security contexts**: Pod and container level restrictions
- **Resource limits**: Memory and CPU constraints
- **HTTPS only**: Self-signed TLS certificates
- **Security headers**: HSTS, CSP, XSS protection
- **Istio mTLS**: Service-to-service encryption

## Istio Configuration

- **VirtualService**: Routes external HTTPS traffic through mesh gateway
- **DestinationRule**: Enforces mTLS and load balancing policies
- **Compliance labels**: `compliance.routing/enabled=true` for auto-routing

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NAMESPACE` | `region-us` | Kubernetes namespace |
| `REGION` | `us` | Region identifier for routing |
| `APP_NAME` | `hello-app` | Application name |
| `ROUTE_HOST` | `hello` | Host label used for routing (`<region>-<route_host>`) |
| `K3S_INGRESS_DOMAIN` | `localhost` | Base domain for external access |
| `GATEWAY_NAME` | `dev-sim-gateway` | Istio gateway name |

## Testing

```bash
# Test health endpoint
kubectl exec -it deployment/$APP_NAME -- curl -k https://localhost:443/health

# Test external access (after gateway setup)
curl -k https://$REGION-$ROUTE_HOST.$K3S_INGRESS_DOMAIN/

# Check Istio configuration
kubectl get virtualservice,destinationrule -n $NAMESPACE
```

## Compliance Notes

- Uses `compliance.routing/*` labels for enterprise-sim integration
- Follows security best practices for containers
- Compatible with PeerAuthentication STRICT mTLS policies
- Includes monitoring and observability endpoints
