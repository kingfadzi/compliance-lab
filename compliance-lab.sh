#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
# Default cluster name (can be overridden by config files)
CLUSTER_NAME="${CLUSTER_NAME:-compliance-lab}"

# --- Environment Detection and Domain Configuration ---
detect_environment() {
  local hostname=$(hostname 2>/dev/null || echo "unknown")

  # Check for environment-specific config files first
  if [ -f "config/compliance-lab.local" ]; then
    echo "local"
  elif [ -f "config/compliance-lab.dev" ]; then
    echo "dev"
  elif [ -f "config/compliance-lab.staging" ]; then
    echo "staging"
  elif [ -f "config/compliance-lab.prod" ]; then
    echo "prod"
  # Fallback to hostname detection
  elif [[ "$hostname" =~ ^(localhost|.*\.local)$ ]]; then
    echo "local"
  elif [[ "$hostname" =~ dev ]]; then
    echo "dev"
  elif [[ "$hostname" =~ (stage|staging) ]]; then
    echo "staging"
  elif [[ "$hostname" =~ (prod|production) ]]; then
    echo "prod"
  else
    echo "dev"
  fi
}

set_ingress_domain() {
  local env="$1"
  # Set default domain only if not already configured
  if [ -z "${K3S_INGRESS_DOMAIN:-}" ]; then
    K3S_INGRESS_DOMAIN="${env}.example.com"
  fi
}

# Initialize environment and domain
DETECTED_ENV=$(detect_environment)
set_ingress_domain "$DETECTED_ENV"

# Load environment-specific config file
[ -f "config/compliance-lab.${DETECTED_ENV}" ] && source "config/compliance-lab.${DETECTED_ENV}" || true

# Apply any overrides from config files
CLUSTER_NAME="${CLUSTER_NAME:-compliance-lab}"

# Export domain for template substitution
export K3S_INGRESS_DOMAIN

# Set production certificates based on environment
USE_PROD_CERTS=false
if [ "$DETECTED_ENV" = "prod" ]; then
  USE_PROD_CERTS=true
fi

# Allow config file override
if [ "${USE_PROD_CERTS:-}" = "true" ]; then
  USE_PROD_CERTS=true
fi

# --- SSL Configuration ---
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
CLOUDFLARE_EMAIL="${CLOUDFLARE_EMAIL:-}"
CLOUDFLARE_ZONE_ID="${CLOUDFLARE_ZONE_ID:-}"

# Export Cloudflare variables for template substitution
export CLOUDFLARE_API_TOKEN
export CLOUDFLARE_EMAIL
export CLOUDFLARE_ZONE_ID

# --- Rancher Configuration (Optional) ---
RANCHER_URL="${RANCHER_URL:-}"
RANCHER_BEARER_TOKEN="${RANCHER_BEARER_TOKEN:-}"

# --- Helper Functions ---

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

log() {
  echo ">>> $1"
}


check_deps() {
  log "Checking dependencies..."
  local missing=()
  for cmd in k3d kubectl helm istioctl velero curl jq; do
    command -v "$cmd" >/dev/null || missing+=("$cmd")
  done
  [ ${#missing[@]} -eq 0 ] || fail "Missing dependencies: ${missing[*]}. Run ./setup-deps.sh"
}

check_cloudflare_config() {
  [ -n "$CLOUDFLARE_API_TOKEN" ] && [ -n "$CLOUDFLARE_EMAIL" ] && [ -n "$CLOUDFLARE_ZONE_ID" ] || {
    fail "Cloudflare not configured. Run: ./compliance-lab.sh configure"
  }
}

cert_is_valid() {
  local ns="$1" secret="$2"
  kubectl -n "$ns" get secret "$secret" >/dev/null 2>&1 || return 1

  local cert_data
  cert_data=$(kubectl -n "$ns" get secret "$secret" -o jsonpath='{.data.tls\.crt}' 2>/dev/null) || return 1

  local tmp=$(mktemp)
  echo "$cert_data" | base64 -d > "$tmp"

  # Check if cert is valid for at least 7 days
  if openssl x509 -checkend 604800 -noout -in "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    return 0
  else
    rm -f "$tmp"
    return 1
  fi
}

backup_certificate() {
  local ns="$1" secret="$2"
  local backup_dir="./cluster-state"
  local backup_file="$backup_dir/${secret}.yaml"

  mkdir -p "$backup_dir"

  if kubectl -n "$ns" get secret "$secret" >/dev/null 2>&1; then
    kubectl -n "$ns" get secret "$secret" -o yaml > "$backup_file"
    log "Certificate backed up: $secret"
  fi
}

restore_certificate() {
  local ns="$1" secret="$2"
  local backup_dir="./cluster-state"
  local backup_file="$backup_dir/${secret}.yaml"

  if [ -f "$backup_file" ]; then
    # Ensure namespace exists
    kubectl create namespace "$ns" >/dev/null 2>&1 || true

    # Restore certificate secret
    kubectl apply -f "$backup_file" >/dev/null 2>&1

    # Verify restoration was successful
    if kubectl -n "$ns" get secret "$secret" >/dev/null 2>&1; then
      log "Certificate restored from backup: $secret"
      return 0
    fi
  fi

  return 1
}

cert_is_valid_from_backup() {
  local ns="$1" secret="$2"
  local backup_dir="./cluster-state"
  local backup_file="$backup_dir/${secret}.yaml"

  [ -f "$backup_file" ] || return 1

  # Extract certificate data from backup file
  local cert_data
  cert_data=$(grep 'tls.crt:' "$backup_file" | cut -d' ' -f4) || return 1

  local tmp=$(mktemp)
  echo "$cert_data" | base64 -d > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }

  # Check if cert is valid for at least 7 days
  if openssl x509 -checkend 604800 -noout -in "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    return 0
  else
    rm -f "$tmp"
    return 1
  fi
}

apply_manifest_template() {
  local template="$1"
  local output=$(mktemp)

  # Simple variable substitution
  envsubst < "manifests/$template" > "$output"
  kubectl apply -f "$output" || fail "Failed to apply $template"
  rm -f "$output"
}

wait_for_certificate() {
  local ns="$1" cert_name="$2" timeout="${3:-300}"

  log "Waiting for certificate $cert_name to be ready (timeout ${timeout}s)..."

  local start=$(date +%s)
  local last_status=""
  local check_count=0

  while true; do
    check_count=$((check_count + 1))
    local now=$(date +%s)
    local elapsed=$((now - start))

    # Check if certificate is ready
    if kubectl -n "$ns" get certificate "$cert_name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True"; then
      log "Certificate $cert_name is ready"
      return 0
    fi

    # Show status every 30 seconds or on first check
    if [ $((check_count % 6)) -eq 1 ]; then
      echo ">>> Certificate status (${elapsed}s elapsed):"

      # Show certificate conditions (with connectivity check)
      local conditions
      if kubectl cluster-info >/dev/null 2>&1; then
        conditions=$(kubectl -n "$ns" get certificate "$cert_name" -o jsonpath='{.status.conditions[*].type}:{.status.conditions[*].status}:{.status.conditions[*].message}' 2>/dev/null || echo "")
        if [ -n "$conditions" ]; then
          echo "    Conditions: $conditions"
        else
          echo "    Conditions: (certificate not found or no status yet)"
        fi
      else
        echo "    Conditions: (cluster connectivity issue - retrying...)"
      fi

      # Show any recent events
      echo "    Recent events:"
      kubectl get events -n "$ns" --field-selector involvedObject.name="$cert_name" --sort-by='.lastTimestamp' --no-headers 2>/dev/null | tail -3 | sed 's/^/      /' || echo "      (no events found)"

      # Show certificate request status if exists
      local cr_name
      cr_name=$(kubectl -n "$ns" get certificate "$cert_name" -o jsonpath='{.spec.secretName}' 2>/dev/null)
      if [ -n "$cr_name" ]; then
        local cr_ready
        cr_ready=$(kubectl -n "$ns" get certificaterequests -l "cert-manager.io/certificate-name=$cert_name" -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [ -n "$cr_ready" ]; then
          echo "    Certificate Request: $cr_ready"
        fi
      fi
      echo
    fi

    # Check timeout
    if [ "$elapsed" -ge "$timeout" ]; then
      echo ">>> Certificate creation failed. Full details:"
      kubectl -n "$ns" describe certificate "$cert_name" || true
      echo ">>> Related events:"
      kubectl get events -n "$ns" --field-selector involvedObject.name="$cert_name" --sort-by='.lastTimestamp' || true
      fail "Certificate $cert_name not ready after ${timeout}s"
    fi

    sleep 5
  done
}

configure_ssl() {
  check_cloudflare_config

  # Ensure kubectl is working and cluster is accessible
  log "Verifying cluster connectivity..."
  kubectl cluster-info >/dev/null 2>&1 || fail "Cluster is not accessible. Check kubectl configuration."

  # Ensure istio-system namespace exists (should be created by Istio installation)
  log "Verifying istio-system namespace exists..."
  kubectl get namespace istio-system >/dev/null 2>&1 || \
    fail "istio-system namespace not found. Istio must be installed first."

  log "Creating Cloudflare credentials secret..."
  kubectl create secret generic cloudflare-api-token-secret -n cert-manager \
    --from-literal=api-token="$CLOUDFLARE_API_TOKEN" --dry-run=client -o yaml | kubectl apply -f - || \
    fail "Failed to create Cloudflare credentials"

  log "Applying ClusterIssuers..."
  apply_manifest_template "cluster-issuers-template.yaml"

  # Wait for issuer to be ready
  local issuer_name="letsencrypt-staging"
  if [ "$USE_PROD_CERTS" = "true" ]; then
    issuer_name="letsencrypt-prod"
  fi

  log "Waiting for ClusterIssuer $issuer_name to be ready..."
  kubectl wait --for=condition=Ready "clusterissuer/$issuer_name" --timeout=120s || \
    fail "ClusterIssuer $issuer_name not ready"

  # Check if we can reuse existing certificate (in cluster or from backup)
  local cert_name="${DETECTED_ENV}-wildcard-cert"
  local tls_secret="${DETECTED_ENV}-wildcard-tls"

  # First check if certificate exists in cluster and is valid
  if cert_is_valid "istio-system" "$tls_secret"; then
    log "Reusing valid certificate from cluster: $tls_secret"
    # Backup existing certificate in case cluster gets reset
    backup_certificate "istio-system" "$tls_secret"
    return 0
  fi

  # If not in cluster, try to restore from backup
  if cert_is_valid_from_backup "istio-system" "$tls_secret"; then
    if restore_certificate "istio-system" "$tls_secret"; then
      log "Reusing valid certificate from backup: $tls_secret"
      return 0
    fi
  fi

  log "Requesting new wildcard certificate for *.${K3S_INGRESS_DOMAIN}..."

  # Validate domain is configured
  if [ -z "$K3S_INGRESS_DOMAIN" ]; then
    fail "K3S_INGRESS_DOMAIN is not set. Please configure it in config/compliance-lab.${DETECTED_ENV}"
  fi

  log "Creating certificate for domain: $K3S_INGRESS_DOMAIN"

  # Set issuer for certificate
  export SSL_ISSUER_NAME="letsencrypt-staging"
  if [ "$USE_PROD_CERTS" = "true" ]; then
    export SSL_ISSUER_NAME="letsencrypt-prod"
  fi

  export CERT_NAME="$cert_name"
  export TLS_SECRET_NAME="$tls_secret"

  apply_manifest_template "wildcard-certificate-template.yaml"
  wait_for_certificate "istio-system" "$cert_name" 600

  # Back up the newly created certificate for future cluster resets
  backup_certificate "istio-system" "$tls_secret"
}

configure_networking() {
  log "Configuring Istio Gateway and basic networking..."

  export GATEWAY_NAME="${DETECTED_ENV}-wildcard-gateway"
  export TLS_SECRET_NAME="${DETECTED_ENV}-wildcard-tls"

  # Create keycloak namespace before applying VirtualService
  kubectl create namespace keycloak || true

  apply_manifest_template "istio-gateway-template.yaml"
  apply_manifest_template "keycloak-virtualservice-template.yaml"
}

configure_service_routing() {
  log "Configuring service routing..."

  # Apply VirtualServices for services that are now deployed
  apply_manifest_template "monitoring-virtualservices-template.yaml"
  apply_manifest_template "minio-virtualservice-template.yaml"
  apply_manifest_template "compliance-test-virtualservice-template.yaml"
}

# --- Main Functions ---

create_cluster() {
  log "Creating k3s cluster: $CLUSTER_NAME"
  log "Environment: $DETECTED_ENV"
  log "Domain: $K3S_INGRESS_DOMAIN"
  log "Certificates: $([ "$USE_PROD_CERTS" = "true" ] && echo "Production" || echo "Staging")"

  # Create k3d cluster
  k3d cluster create "$CLUSTER_NAME" \
    --agents 1 \
    --port '80:80@loadbalancer' \
    --port '443:443@loadbalancer' \
    --k3s-arg "--disable=traefik@server:0" \
    --wait || fail "Failed to create k3d cluster"

  export KUBECONFIG=$(k3d kubeconfig write "$CLUSTER_NAME")

  # Install storage
  log "Installing OpenEBS LocalPV..."
  kubectl apply -f https://raw.githubusercontent.com/openebs/dynamic-localpv-provisioner/develop/deploy/kubectl/openebs-operator-lite.yaml
  kubectl wait --for=condition=available --timeout=300s deployment/openebs-localpv-provisioner -n openebs || \
    fail "OpenEBS installation failed"

  kubectl apply -f manifests/openebs-storageclass.yaml || fail "Failed to create StorageClass"

  # Install cert-manager
  log "Installing cert-manager..."
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.18.2/cert-manager.yaml
  kubectl wait --for=condition=available --timeout=300s deployment/cert-manager-webhook -n cert-manager || \
    fail "cert-manager installation failed"

  # Configure cert-manager to use external DNS servers for propagation checks
  log "Configuring cert-manager DNS settings..."
  kubectl patch deployment cert-manager -n cert-manager --type='json' -p='[
    {
      "op": "replace",
      "path": "/spec/template/spec/containers/0/args",
      "value": [
        "--v=2",
        "--cluster-resource-namespace=$(POD_NAMESPACE)",
        "--leader-election-namespace=kube-system",
        "--acme-http01-solver-image=quay.io/jetstack/cert-manager-acmesolver:v1.13.0",
        "--max-concurrent-challenges=60",
        "--dns01-recursive-nameservers=1.1.1.1:53,8.8.8.8:53",
        "--dns01-recursive-nameservers-only"
      ]
    }
  ]'
  kubectl rollout status deployment/cert-manager -n cert-manager || \
    fail "cert-manager DNS configuration failed"

  # Install Istio
  log "Installing Istio..."
  istioctl install --set profile=demo -y || fail "Istio installation failed"
  kubectl -n istio-system rollout status deploy/istiod --timeout=300s || fail "Istio rollout failed"

  # Configure SSL certificates (after Istio creates istio-system namespace)
  configure_ssl

  # Configure networking
  configure_networking

  # Install other components
  install_components

  # Configure service routing now that all services are deployed
  configure_service_routing

  log "Cluster ready!"
  show_cluster_info
}

install_components() {
  log "Installing MinIO..."
  kubectl create ns minio || true
  helm repo add minio https://charts.min.io/ || true
  helm upgrade --install minio minio/minio -n minio \
    --set mode=standalone \
    --set replicas=1 \
    --set auth.rootUser=myaccesskey \
    --set auth.rootPassword=mysecretkey \
    --set defaultBuckets="velero" \
    --set resources.requests.memory=512Mi \
    --set resources.limits.memory=1Gi \
    --wait --timeout=300s || fail "MinIO installation failed"

  log "Installing Velero..."
  mkdir -p ./manifests
  cat > ./manifests/minio-credentials <<EOF
[default]
aws_access_key_id = myaccesskey
aws_secret_access_key = mysecretkey
EOF
  velero install \
    --provider aws \
    --plugins velero/velero-plugin-for-aws:v1.8.0 \
    --bucket velero \
    --secret-file ./manifests/minio-credentials \
    --use-volume-snapshots=false \
    --backup-location-config region=minio,s3ForcePathStyle=true,s3Url=http://minio.minio.svc.cluster.local:9000 || \
    fail "Velero installation failed"

  log "Installing Keycloak..."
  kubectl create namespace keycloak || true
  kubectl apply -f manifests/keycloak-deployment.yaml || fail "Keycloak installation failed"

  # Wait for Keycloak deployment to be ready
  kubectl wait --for=condition=available --timeout=600s deployment/keycloak -n keycloak || \
    fail "Keycloak deployment failed to become ready"

  log "Installing monitoring stack..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
  helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack -n monitoring --create-namespace \
    --set prometheus.prometheusSpec.replicas=1 \
    --set prometheus.prometheusSpec.resources.requests.cpu=250m \
    --set prometheus.prometheusSpec.resources.requests.memory=512Mi \
    --set prometheus.prometheusSpec.resources.limits.memory=1Gi \
    --set prometheus.prometheusSpec.resources.limits.cpu=1000m \
    --set grafana.replicas=1 \
    --set grafana.resources.requests.memory=128Mi \
    --set grafana.resources.requests.cpu=100m \
    --set grafana.resources.limits.memory=256Mi \
    --set grafana.resources.limits.cpu=500m \
    --set alertmanager.alertmanagerSpec.resources.requests.memory=128Mi \
    --set alertmanager.alertmanagerSpec.resources.limits.memory=256Mi \
    --wait --timeout=600s || fail "Monitoring stack installation failed"

  kubectl apply -f manifests/compliance-system.yaml || true
  kubectl apply -f manifests/compliance-test.yaml || true
}

show_cluster_info() {
  echo
  echo "=== Environment Configuration ==="
  echo "🌍 Environment: $DETECTED_ENV"
  echo "🌐 Domain: $K3S_INGRESS_DOMAIN"
  echo "🔒 Certificates: $([ "$USE_PROD_CERTS" = "true" ] && echo "Production (Let's Encrypt)" || echo "Staging (Let's Encrypt)")"
  echo
  echo "🔗 Applications:"
  echo "  - Test App: https://app.${K3S_INGRESS_DOMAIN}"
  echo "    └── Echo server for compliance testing"
  echo "  - Keycloak: https://keycloak.${K3S_INGRESS_DOMAIN}"
  echo "    └── Admin: admin/admin"
  echo "  - Grafana: https://grafana.${K3S_INGRESS_DOMAIN}"
  echo "    └── Admin: admin/prom-operator"
  echo "  - Prometheus: https://prometheus.${K3S_INGRESS_DOMAIN}"
  echo "    └── Metrics and alerting"
  echo "  - AlertManager: https://alertmanager.${K3S_INGRESS_DOMAIN}"
  echo "    └── Alert management"
  echo "  - MinIO S3 API: https://minio.${K3S_INGRESS_DOMAIN}"
  echo "    └── Access: myaccesskey/mysecretkey"
  echo "  - MinIO Console: https://minio-console.${K3S_INGRESS_DOMAIN}"
  echo "    └── Web UI for MinIO management"
  echo
  echo "📋 DNS Setup Required:"
  echo "  *.${K3S_INGRESS_DOMAIN} -> $(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo '[cluster-ip]')"
  echo
  echo "💡 Certificate Management:"
  echo "  Current: istio-system/${DETECTED_ENV}-wildcard-tls"
  echo "  Check: kubectl get certificate -n istio-system"
  echo "  Renew: Delete secret and run 'up' again"
}

destroy_cluster() {
  log "Destroying cluster: $CLUSTER_NAME"
  k3d cluster delete "$CLUSTER_NAME" || true
  log "Cluster destroyed"
}

register_cluster() {
  # Rancher configuration is loaded from the main compliance-lab config file
  if [ -z "$RANCHER_URL" ] || [ -z "$RANCHER_BEARER_TOKEN" ]; then
    log "Rancher not configured in config/compliance-lab.${DETECTED_ENV}"
    log "Set RANCHER_URL and RANCHER_BEARER_TOKEN to enable registration"
    return 0
  fi

  log "Registering cluster with Rancher..."

  # Simple registration - create cluster and apply manifest
  local cluster_json
  cluster_json=$(curl -sk -X POST "$RANCHER_URL/v3/clusters" \
    -H "Authorization: Bearer $RANCHER_BEARER_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"cluster\",\"name\":\"$CLUSTER_NAME\"}")

  local cluster_id
  cluster_id=$(echo "$cluster_json" | jq -r '.id // empty')
  [ -n "$cluster_id" ] || fail "Failed to create cluster in Rancher"

  log "Created cluster: $cluster_id"

  # Get registration manifest and apply
  local token_json
  token_json=$(curl -sk -X POST "$RANCHER_URL/v3/clusterregistrationtokens" \
    -H "Authorization: Bearer $RANCHER_BEARER_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"clusterRegistrationToken\",\"clusterId\":\"$cluster_id\"}")

  local token_id
  token_id=$(echo "$token_json" | jq -r '.id // empty')
  [ -n "$token_id" ] || fail "Failed to create registration token"

  # Wait for manifest URL
  local manifest_url=""
  for i in {1..30}; do
    local token_data
    token_data=$(curl -sk "$RANCHER_URL/v3/clusterregistrationtokens/$token_id" \
      -H "Authorization: Bearer $RANCHER_BEARER_TOKEN")
    manifest_url=$(echo "$token_data" | jq -r '.manifestUrl // empty')
    [ -n "$manifest_url" ] && break
    sleep 5
  done

  [ -n "$manifest_url" ] || fail "Registration manifest not ready"

  log "Applying registration manifest..."
  curl -skL "$manifest_url" | kubectl apply -f - || fail "Failed to apply registration manifest"

  log "Cluster registered with Rancher successfully"
}

deregister_cluster() {
  # Rancher configuration is loaded from the main compliance-lab config file
  if [ -z "$RANCHER_URL" ] || [ -z "$RANCHER_BEARER_TOKEN" ]; then
    log "Rancher not configured in config/compliance-lab.${DETECTED_ENV}"
    log "Set RANCHER_URL and RANCHER_BEARER_TOKEN to enable deregistration"
    return 0
  fi

  log "Deregistering cluster from Rancher..."

  # Remove cattle-system namespace and Rancher agent
  kubectl delete namespace cattle-system --ignore-not-found=true || true
  kubectl delete namespace cattle-fleet-system --ignore-not-found=true || true

  # Find cluster by name in Rancher and delete it
  local clusters_json
  clusters_json=$(curl -sk -X GET "$RANCHER_URL/v3/clusters" \
    -H "Authorization: Bearer $RANCHER_BEARER_TOKEN") || {
    log "Warning: Could not retrieve clusters from Rancher API"
    return 0
  }

  local cluster_id
  cluster_id=$(echo "$clusters_json" | jq -r ".data[] | select(.name==\"$CLUSTER_NAME\") | .id" | head -1)

  if [ -n "$cluster_id" ] && [ "$cluster_id" != "null" ]; then
    log "Removing cluster '$CLUSTER_NAME' (ID: $cluster_id) from Rancher..."
    curl -sk -X DELETE "$RANCHER_URL/v3/clusters/$cluster_id" \
      -H "Authorization: Bearer $RANCHER_BEARER_TOKEN" || {
      log "Warning: Failed to delete cluster from Rancher API"
    }
    log "Cluster deregistered from Rancher successfully"
  else
    log "Cluster '$CLUSTER_NAME' not found in Rancher"
  fi
}

configure_cloudflare() {
  echo "--- Cloudflare Configuration ---"
  echo

  read -p "Cloudflare email: " cf_email
  read -sp "Cloudflare API token: " cf_token
  echo
  read -p "Cloudflare Zone ID: " cf_zone_id

  [ -n "$cf_email" ] && [ -n "$cf_token" ] && [ -n "$cf_zone_id" ] || fail "All fields required"

  cat > config/compliance-lab.env <<EOF
# Compliance Lab k3s Cluster Configuration

# Cloudflare Configuration (Required for SSL certificates)
export CLOUDFLARE_EMAIL="$cf_email"
export CLOUDFLARE_API_TOKEN="$cf_token"
export CLOUDFLARE_ZONE_ID="$cf_zone_id"
EOF

  log "Configuration saved to config/compliance-lab.env"
}

# --- Main Logic ---

check_deps

case "${1:-}" in
  up)
    shift
    create_cluster "$@"
    ;;
  down)
    destroy_cluster
    ;;
  reset)
    destroy_cluster
    create_cluster
    ;;
  register)
    register_cluster
    ;;
  deregister)
    deregister_cluster
    ;;
  configure)
    configure_cloudflare
    ;;
  *)
    echo "Usage: $0 {up|down|reset|register|deregister|configure}"
    echo
    echo "Commands:"
    echo "  up                   Create cluster (auto prod certs for prod env)"
    echo "  down                 Delete cluster"
    echo "  reset               Recreate cluster"
    echo "  register            Register with Rancher (optional)"
    echo "  deregister          Remove from Rancher (optional)"
    echo "  configure           Setup Cloudflare credentials"
    echo
    echo "Environment Control:"
    echo "  Create config/compliance-lab.local    # Configure K3S_INGRESS_DOMAIN"
    echo "  Create config/compliance-lab.staging  # Configure K3S_INGRESS_DOMAIN"
    echo
    echo "Examples:"
    echo "  $0 up                      # Staging certs (local/dev/staging env)"
    echo "  # Production certs automatically used with config/compliance-lab.prod"
    exit 1
    ;;
esac