# Hello World Compliance Demo Application

This is a sample Node.js application designed to demonstrate comprehensive compliance evidence collection using the Kubernetes platform handler.

## Application Overview

The application is a simple Express.js web server that provides:
- Basic "Hello World" JSON response at `/`
- Health check endpoint at `/health`
- Readiness check endpoint at `/ready`

## Compliance Features Demonstrated

This deployment showcases multiple compliance controls that can be collected as evidence:

### Security Controls
- **Pod Security Context**: Non-root user, read-only filesystem, dropped capabilities
- **Secrets Management**: Database credentials and API keys stored in Kubernetes Secrets
- **TLS/Encryption in Transit**: Platform-managed SSL termination and encryption
- **Encryption at Rest**: Encrypted storage class for persistent volumes
- **RBAC**: Least-privilege service account with minimal permissions
- **Network Segmentation**: NetworkPolicy restricting ingress/egress traffic

### Availability Controls
- **High Availability**: 3 replicas with anti-affinity rules
- **Auto-scaling**: HorizontalPodAutoscaler for CPU/memory-based scaling
- **Disruption Protection**: PodDisruptionBudget ensuring minimum availability
- **Health Monitoring**: Liveness and readiness probes
- **Resource Limits**: CPU/memory requests and limits defined

### Integrity Controls
- **Audit Logging**: Compliance labels for tracking changes
- **Immutable Configuration**: Read-only root filesystem and config
- **Change Control**: Deployment annotations for tracking updates
- **RBAC Audit**: Role bindings with audit labels

### Resilience Controls
- **Backup-ready Storage**: PersistentVolumeClaim for data persistence
- **Rolling Updates**: Deployment strategy for zero-downtime updates
- **Resource Quotas**: Namespace-level resource limits
- **Multi-zone Deployment**: Node affinity rules for distribution

## Deployment

To deploy this application:

```bash
# Deploy all resources with proper ordering
kubectl apply -k sample-app/k8s-manifests/
```

The Kustomize configuration handles:
- Correct resource ordering (namespace → RBAC → storage → config → deployment → ingress → network policy)
- Namespace scoping for all resources
- Single command deployment

## Platform Integration

This application is designed to be platform-agnostic:
- **SSL/TLS**: Handled automatically by the platform (wildcard certificates, SSL termination)
- **Domain routing**: Platform assigns domains and routes `/hello-world` path to the service
- **Security policies**: WAF and security headers applied at platform level
- **Application focus**: Only defines business logic routing and service configuration

## Evidence Collection

This deployment provides evidence for the following compliance matrix fields:
- Encryption at Rest (PVC with encrypted storage class)
- Encryption in Transit (Platform-managed SSL termination)
- Secrets Management (Kubernetes Secrets)
- Privileged Access Management (RBAC policies)
- Network Segmentation (NetworkPolicy)
- HA Topology (Multi-replica deployment with anti-affinity)
- Monitoring SLOs (Health checks and HPA metrics)
- Backup Policy (PVC configuration)

Each resource includes compliance-related labels and annotations that can be collected as evidence by the rule engine.
