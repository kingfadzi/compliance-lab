# Configuration Guide

## Environment Variable Loading

The scripts load configuration in this order:

### compliance-lab.sh (k3s cluster management)
1. `config/compliance-lab.{environment}` - Environment-specific k3s config (e.g., `config/compliance-lab.local`, `config/compliance-lab.staging`)

### rancher.sh (Rancher container management)
1. `config/rancher.{environment}` - Environment-specific Rancher API and container configuration

## Configuration Files

### For k3s clusters (compliance-lab.sh):
- `config/compliance-lab.local` - Local environment k3s configuration (set K3S_INGRESS_DOMAIN)
- `config/compliance-lab.dev` - Development environment configuration (set K3S_INGRESS_DOMAIN)
- `config/compliance-lab.staging` - Staging environment configuration (set K3S_INGRESS_DOMAIN)
- `config/compliance-lab.prod` - Production environment configuration (set K3S_INGRESS_DOMAIN)

### For Rancher management (rancher.sh):
- `config/rancher.local` - Local environment Rancher configuration
- `config/rancher.dev` - Development environment Rancher configuration
- `config/rancher.staging` - Staging environment Rancher configuration
- `config/rancher.prod` - Production environment Rancher configuration

## Environment Detection

The script auto-detects environment based on:
- Configuration files (`config/compliance-lab.local`, `config/compliance-lab.dev`, `config/compliance-lab.staging`, `config/compliance-lab.prod`)
- Hostname patterns (`*.local`, `dev-*`, `staging-*`)

## Manifests

All YAML templates are in `manifests/`:
- `cluster-issuers-template.yaml` - Let's Encrypt staging/prod issuers
- `wildcard-certificate-template.yaml` - SSL certificate request
- `istio-gateway-template.yaml` - Istio Gateway configuration
- `keycloak-virtualservice-template.yaml` - Keycloak routing
- `openebs-storageclass.yaml` - Default storage class

Variables are substituted using `envsubst`.