#!/usr/bin/env bash
set -euo pipefail

# Enterprise Simulation CLI
# Milestones covered: cluster lifecycle, TLS (self-signed), Istio install, regions, zero-trust policies, wildcard gateway.

CLUSTER_NAME=${CLUSTER_NAME:-enterprise-sim}

log() { echo ">>> $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing dependency: $1"
}

check_deps_basic() { need k3d; need kubectl; need jq; }

check_deps_helm() { need helm; }

need_envsubst() { command -v envsubst >/dev/null 2>&1 || fail "Missing dependency: envsubst"; }

require_domain() {
  if [ -z "${K3S_INGRESS_DOMAIN:-}" ]; then
    K3S_INGRESS_DOMAIN=localhost
    export K3S_INGRESS_DOMAIN
    echo "WARN: K3S_INGRESS_DOMAIN not set; defaulting to 'localhost' for local testing" >&2
  fi
}

derive_env_defaults() {
  : "${ENVIRONMENT:=}"
  if [ -z "$ENVIRONMENT" ]; then
    case "${K3S_INGRESS_DOMAIN:-}" in
      prod.*|*.prod.*|prod) ENVIRONMENT=prod ;;
      staging.*|*.staging.*|stage|staging) ENVIRONMENT=staging ;;
      dev.*|*.dev.*|dev) ENVIRONMENT=dev ;;
      local.*|*.local.*|local) ENVIRONMENT=local ;;
      *) ENVIRONMENT=dev ;;
    esac
  fi
  : "${TLS_SECRET_NAME:=${ENVIRONMENT}-wildcard-tls}"
  : "${GATEWAY_NAME:=${ENVIRONMENT}-sim-gateway}"
}

cluster_exists() {
  k3d cluster list -o json | jq -e ".[] | select(.name==\"$CLUSTER_NAME\")" >/dev/null 2>&1
}

cmd_up() {
  check_deps_basic
  log "Creating k3d cluster: $CLUSTER_NAME"
  if cluster_exists; then
    log "Cluster already exists. Skipping create."
  else
    k3d cluster create "$CLUSTER_NAME" \
      --agents 1 \
      --port '80:80@loadbalancer' \
      --port '443:443@loadbalancer' \
      --k3s-arg '--disable=traefik@server:0' \
      --wait
  fi

  # Write kubeconfig and print hint
  local kubeconfig
  kubeconfig=$(k3d kubeconfig write "$CLUSTER_NAME")
  log "Kubeconfig written to: $kubeconfig"
  echo "Export it in your shell to use kubectl:"
  echo "  export KUBECONFIG=$kubeconfig"

  # Quick sanity
  log "Cluster nodes:"
  kubectl get nodes -o wide || true
}

cmd_down() {
  check_deps_basic
  log "Deleting k3d cluster: $CLUSTER_NAME"
  k3d cluster delete "$CLUSTER_NAME" || true
}

cmd_status() {
  need k3d
  log "k3d clusters:"
  k3d cluster list || true
  if command -v kubectl >/dev/null 2>&1; then
    echo
    log "Kubernetes nodes (if KUBECONFIG set):"
    kubectl get nodes -o wide || true
  fi
}

cmd_tls_up() {
  check_deps_basic
  require_domain
  derive_env_defaults

  log "Ensuring istio-system namespace exists"
  kubectl create namespace istio-system >/dev/null 2>&1 || true

  log "Creating self-signed wildcard TLS secret: $TLS_SECRET_NAME for *.${K3S_INGRESS_DOMAIN}"
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT
  openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
    -keyout "$tmpdir/tls.key" -out "$tmpdir/tls.crt" \
    -subj "/CN=*.${K3S_INGRESS_DOMAIN}" \
    -addext "subjectAltName = DNS:*.${K3S_INGRESS_DOMAIN}, DNS:${K3S_INGRESS_DOMAIN}" >/dev/null 2>&1 || \
    fail "OpenSSL failed to create self-signed cert"

  kubectl -n istio-system create secret tls "$TLS_SECRET_NAME" \
    --key "$tmpdir/tls.key" --cert "$tmpdir/tls.crt" \
    --dry-run=client -o yaml | kubectl apply -f -

  log "TLS secret ready: istio-system/$TLS_SECRET_NAME"
}

cmd_sail_up() {
  check_deps_basic
  check_deps_helm
  log "Installing Sail Operator using Helm"

  # Add Sail Operator Helm repository
  log "Adding Sail Operator Helm repository"
  helm repo add sailoperator https://istio-ecosystem.github.io/sail-operator >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1

  # Create namespace for Sail Operator
  log "Creating sail-operator namespace"
  kubectl create namespace sail-operator >/dev/null 2>&1 || true

  # Install Sail Operator
  log "Installing Sail Operator via Helm"
  helm upgrade --install sail-operator sailoperator/sail-operator \
    --namespace sail-operator \
    --wait --timeout=300s

  # Wait for operator deployment to be ready
  log "Waiting for Sail Operator deployment"
  kubectl -n sail-operator rollout status deploy/sail-operator --timeout=300s

  log "Sail Operator installed successfully"
}

cmd_istio_up() {
  check_deps_basic
  log "Applying Istio mesh configuration via CRD manifest"

  # Check if Sail Operator is running
  if ! kubectl -n sail-operator get deploy sail-operator >/dev/null 2>&1; then
    fail "Sail Operator not found. Run 'sail up' first to install the operator."
  fi

  # Apply Istio CRD manifest
  manifest_file="$(dirname "$0")/manifests/istio/istio-ambient.yaml"
  if [ ! -f "$manifest_file" ]; then
    fail "Istio manifest not found: $manifest_file"
  fi

  log "Applying Istio manifest: $manifest_file"
  kubectl apply -f "$manifest_file"

  log "Waiting for Istio control plane and ingress"
  kubectl -n istio-system rollout status deploy/istiod --timeout=300s
  kubectl -n istio-system rollout status deploy/istio-ingressgateway --timeout=300s
  log "Istio mesh deployed via Sail Operator"
}

ensure_region_ns() {
  local ns=$1 region=$2
  kubectl get ns "$ns" >/dev/null 2>&1 || kubectl create ns "$ns"
  kubectl label ns "$ns" istio-injection=enabled --overwrite
  kubectl label ns "$ns" compliance.region="$region" --overwrite
}

apply_region_policies() {
  local ns=$1
  # If Istio CRDs are missing, skip policy application gracefully
  if ! kubectl get crd peerauthentications.security.istio.io >/dev/null 2>&1; then
    echo "WARN: Istio CRDs not found. Skipping mTLS/AuthZ policies in namespace ${ns}. Run 'istio up' first." >&2
    return 0
  fi
  # STRICT mTLS
  cat <<EOF | kubectl apply -f -
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: ${ns}
spec:
  mtls:
    mode: STRICT
EOF

  # Minimal allow policy for ingress (can be refined as needed)
  cat <<EOF | kubectl apply -f -
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: allow-ingress
  namespace: ${ns}
spec:
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces: ["istio-system"]
EOF

  # Baseline NetworkPolicy
  cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: baseline-istio-access
  namespace: ${ns}
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: istio-system
      podSelector:
        matchLabels:
          istio: ingressgateway
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: istio-system
    ports:
    - protocol: TCP
      port: 15012
EOF
}

cmd_regions_up() {
  check_deps_basic
  log "Creating region namespaces and applying zero-trust policies (if Istio installed)"
  ensure_region_ns region-us us
  ensure_region_ns region-eu eu
  ensure_region_ns region-ap ap

  apply_region_policies region-us
  apply_region_policies region-eu
  apply_region_policies region-ap

  log "Regions ready: region-us, region-eu, region-ap"
}

cmd_gateway_up() {
  check_deps_basic
  require_domain
  derive_env_defaults

  log "Applying wildcard gateway ${GATEWAY_NAME} for *.${K3S_INGRESS_DOMAIN} using TLS secret ${TLS_SECRET_NAME}"
  TMPFILE=$(mktemp)
  export GATEWAY_NAME K3S_INGRESS_DOMAIN TLS_SECRET_NAME
  envsubst < "$(dirname "$0")/manifests/gateway/wildcard-gateway-template.yaml" > "$TMPFILE"
  kubectl apply -f "$TMPFILE"
  rm -f "$TMPFILE"

  kubectl -n istio-system get gateway "$GATEWAY_NAME" -o yaml >/dev/null
  log "Gateway applied: istio-system/${GATEWAY_NAME}"
}

print_check() { # args: status msg
  local status=$1; shift
  if [ "$status" = OK ]; then
    echo "[ OK ] $*"
  else
    echo "[FAIL] $*" >&2
  fi
}

cmd_validate() {
  check_deps_basic
  derive_env_defaults
  require_domain

  local ok=0

  echo "== Cluster =="
  if kubectl cluster-info >/dev/null 2>&1; then
    print_check OK "kubectl can reach the cluster"
  else
    print_check FAIL "kubectl cannot reach the cluster (set KUBECONFIG?)"; ok=1
  fi
  kubectl get nodes -o wide || true

  echo "\n== Istio Control Plane =="
  if kubectl -n istio-system get deploy istiod >/dev/null 2>&1; then
    print_check OK "istiod deployment exists"
    kubectl -n istio-system rollout status deploy/istiod --timeout=1s >/dev/null 2>&1 && \
      print_check OK "istiod rollout ready" || print_check FAIL "istiod not ready"
  else
    print_check FAIL "istiod deployment not found"; ok=1
  fi
  if kubectl -n istio-system get deploy istio-ingressgateway >/dev/null 2>&1; then
    print_check OK "istio-ingressgateway deployment exists"
    kubectl -n istio-system rollout status deploy/istio-ingressgateway --timeout=1s >/dev/null 2>&1 && \
      print_check OK "ingressgateway rollout ready" || print_check FAIL "ingressgateway not ready"
  else
    print_check FAIL "istio-ingressgateway deployment not found"; ok=1
  fi

  echo "\n== TLS Secret =="
  if kubectl -n istio-system get secret "$TLS_SECRET_NAME" >/dev/null 2>&1; then
    print_check OK "TLS secret present: istio-system/$TLS_SECRET_NAME"
  else
    print_check FAIL "TLS secret missing: istio-system/$TLS_SECRET_NAME"; ok=1
  fi

  echo "\n== Regions & Policies =="
  for ns in region-us:us region-eu:eu region-ap:ap; do
    rns=${ns%:*}; r=${ns#*:}
    if kubectl get ns "$rns" >/dev/null 2>&1; then
      print_check OK "namespace exists: $rns"
      lbl=$(kubectl get ns "$rns" -o jsonpath='{.metadata.labels.compliance\.region}' 2>/dev/null || echo "")
      [ "$lbl" = "$r" ] && print_check OK "$rns labeled compliance.region=$r" || print_check FAIL "$rns missing compliance.region=$r" && ok=1
      kubectl -n "$rns" get peerauthentication default >/dev/null 2>&1 && \
        print_check OK "$rns PeerAuthentication present" || { print_check FAIL "$rns PeerAuthentication missing"; ok=1; }
      kubectl -n "$rns" get authorizationpolicy allow-ingress >/dev/null 2>&1 && \
        print_check OK "$rns AuthorizationPolicy allow-ingress present" || { print_check FAIL "$rns AuthorizationPolicy missing"; ok=1; }
      kubectl -n "$rns" get netpol baseline-istio-access >/dev/null 2>&1 && \
        print_check OK "$rns NetworkPolicy baseline-istio-access present" || { print_check FAIL "$rns NetworkPolicy missing"; ok=1; }
    else
      print_check FAIL "namespace missing: $rns"; ok=1
    fi
  done

  echo "\n== Gateway =="
  if kubectl -n istio-system get gateway "$GATEWAY_NAME" >/dev/null 2>&1; then
    print_check OK "Gateway present: istio-system/$GATEWAY_NAME (hosts *.${K3S_INGRESS_DOMAIN})"
  else
    print_check FAIL "Gateway missing: istio-system/$GATEWAY_NAME"; ok=1
  fi
  kubectl -n istio-system get svc istio-ingressgateway -o wide || true

  echo
  if [ $ok -eq 0 ]; then
    echo "All core checks passed. You can now add routes or deploy sample services."
    exit 0
  else
    echo "Some checks failed. See messages above." >&2
    exit 1
  fi
}

cmd_routes_reconcile() {
  check_deps_basic
  need_envsubst
  derive_env_defaults
  require_domain

  echo "== Reconciling routes from Services (compliance.routing/enabled=true) =="

  # Build a map of namespace -> region
  ns_json=$(kubectl get ns -o json)
  # shellcheck disable=SC2016
  ns_map=$(echo "$ns_json" | jq -r '.items[] | "\(.metadata.name)=\(.metadata.labels["compliance.region"] // "")"')

  # Get all labeled services across namespaces
  svcs_json=$(kubectl get svc -A -l compliance.routing/enabled=true -o json)
  count=$(echo "$svcs_json" | jq '.items | length')
  if [ "$count" -eq 0 ]; then
    echo "No Services found with label compliance.routing/enabled=true. Nothing to do."
    return 0
  fi

  tmpl="$(dirname "$0")/manifests/routing/virtualservice-template.yaml"
  [ -f "$tmpl" ] || fail "Template not found: $tmpl"

  changed=0
  echo "$svcs_json" | jq -c '.items[]' | while read -r item; do
    ns=$(echo "$item" | jq -r '.metadata.namespace')
    name=$(echo "$item" | jq -r '.metadata.name')

    # Determine region from namespace labels
    region=$(echo "$ns_map" | awk -F= -v n="$ns" '$1==n{print $2}')
    if [ -z "$region" ] || [ "$region" = "null" ]; then
      echo "WARN: Namespace $ns has no compliance.region label; skipping Service $ns/$name" >&2
      continue
    fi

    # Determine app host component
    app_host=$(echo "$item" | jq -r '.metadata.labels["compliance.routing/host"] // .metadata.annotations["compliance.routing/host"] // .metadata.name')

    # Determine service port to route to
    lbl_port=$(echo "$item" | jq -r '.metadata.labels["compliance.routing/port"] // .metadata.annotations["compliance.routing/port"] // ""')
    if [ -n "$lbl_port" ] && [ "$lbl_port" != "null" ]; then
      svc_port="$lbl_port"
    else
      svc_port=$(echo "$item" | jq -r '.spec.ports[0].port // empty')
    fi
    if [ -z "$svc_port" ] || [ "$svc_port" = "null" ]; then
      echo "WARN: Could not determine Service port for $ns/$name; skipping" >&2
      continue
    fi

    VS_NAME="route-${name}"
    VS_NAMESPACE="$ns"
    SVC_HOST="$name"
    SVC_PORT="$svc_port"
    VS_HOST="${region}-${app_host}.${K3S_INGRESS_DOMAIN}"

    export VS_NAME VS_NAMESPACE SVC_HOST SVC_PORT VS_HOST K3S_INGRESS_DOMAIN GATEWAY_NAME

    tmp=$(mktemp)
    envsubst < "$tmpl" > "$tmp"
    if kubectl apply -f "$tmp" >/dev/null; then
      echo "Applied/updated VirtualService: $VS_NAMESPACE/$VS_NAME (host: $VS_HOST -> $SVC_HOST:$SVC_PORT)"
      changed=$((changed+1))
    else
      echo "ERROR: Failed to apply VirtualService for $ns/$name" >&2
    fi
    rm -f "$tmp"
  done

  echo "Reconciliation complete."
}

usage() {
  cat <<EOF
Usage: $0 <command>

Commands:
  up          Create k3d cluster with ports 80/443 mapped (Traefik disabled)
  down        Delete the k3d cluster
  status      Show cluster and node status (if KUBECONFIG set)
  sail up     Install Sail Operator for declarative Istio management
  istio up    Deploy Istio mesh via CRD manifest (requires Sail Operator)
  tls up      Create self-signed wildcard TLS secret in istio-system
  regions up  Create region namespaces and apply zero-trust policies
  gateway up  Apply wildcard HTTPS gateway using TLS secret
  routes reconcile  Auto-generate VirtualServices from labeled Services
  validate    Validate all components are running correctly

Typical workflow:
  1. $0 up                    # Create cluster
  2. $0 sail up               # Install Sail Operator
  3. $0 istio up              # Deploy Istio mesh declaratively
  4. $0 tls up                # Setup TLS certificates
  5. $0 regions up            # Create region namespaces
  6. $0 gateway up            # Setup wildcard gateway
  7. Deploy apps with compliance.routing/enabled=true labels
  8. $0 routes reconcile      # Auto-generate routes

Env vars:
  CLUSTER_NAME        Cluster name (default: enterprise-sim)
  K3S_INGRESS_DOMAIN  Base domain for gateway hosts (required for tls/gateway)
  TLS_SECRET_NAME     TLS secret name (default: <ENV>-wildcard-tls)
  GATEWAY_NAME        Gateway name (default: <ENV>-sim-gateway)
  ENVIRONMENT         Environment hint for defaults (dev|staging|prod|local)

Dependencies:
  - k3d, kubectl, jq (basic operations)
  - helm (for Sail Operator installation)
  - envsubst (for templating)

Notes:
  - After 'up', export KUBECONFIG from the path printed to use kubectl.
  - Istio is now managed declaratively via Sail Operator, no istioctl required.
  - All mesh configuration is in manifests/istio/istio-ambient.yaml
EOF
}

main() {
  case "${1:-}" in
    up) shift; cmd_up "$@" ;;
    down) shift; cmd_down "$@" ;;
    status) shift; cmd_status "$@" ;;
    tls) shift; case "${1:-}" in up) shift; cmd_tls_up "$@" ;; *) usage ;; esac ;;
    sail) shift; case "${1:-}" in up) shift; cmd_sail_up "$@" ;; *) usage ;; esac ;;
    istio) shift; case "${1:-}" in up) shift; cmd_istio_up "$@" ;; *) usage ;; esac ;;
    regions) shift; case "${1:-}" in up) shift; cmd_regions_up "$@" ;; *) usage ;; esac ;;
    gateway) shift; case "${1:-}" in up) shift; cmd_gateway_up "$@" ;; *) usage ;; esac ;;
    routes) shift; case "${1:-}" in reconcile) shift; cmd_routes_reconcile "$@" ;; *) usage ;; esac ;;
    validate) shift; cmd_validate "$@" ;;
    -h|--help|help|*) usage ;;
  esac
}

main "$@"
