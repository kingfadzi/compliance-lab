#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
CLUSTER_NAME="compliance-lab"
RANCHER_NAME="rancher"
# This domain is used for services inside the k3s cluster, like Keycloak.
# The external Rancher instance will have its own separate URL.
K3S_INGRESS_DOMAIN="dev.butterflycluster.com"

# --- Cloudflare Configuration (for Let's Encrypt DNS-01 challenges) ---
# Use environment variables if set, otherwise default to empty
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
CLOUDFLARE_EMAIL="${CLOUDFLARE_EMAIL:-}"

# --- MinIO Credentials (used for Velero S3 backend) ---
MINIO_ACCESS_KEY="myaccesskey"
MINIO_SECRET_KEY="mysecretkey"

# --- Cleanup behavior (tunable via env) ---
# When true, automatically prune docker artifacts during teardown.
AUTO_DOCKER_PRUNE=${AUTO_DOCKER_PRUNE:-false}
# When true (and pruning), also prune volumes (more aggressive space reclaim).
PRUNE_DOCKER_VOLUMES=${PRUNE_DOCKER_VOLUMES:-false}
# When true, purge Rancher filesystem state under /var/lib/rancher during cleanup.
AUTO_RANCHER_PURGE=${AUTO_RANCHER_PURGE:-false}
# Path to Rancher state directory on host
RANCHER_DIR=${RANCHER_DIR:-/var/lib/rancher}

# --- SSL Configuration behavior (tunable via env) ---
# When true, SSL setup must succeed or the script fails.
# When false, SSL setup failures are warned but script continues.
REQUIRE_SSL=${REQUIRE_SSL:-true}

# --- Local SSL Certificate Paths ---
# Used for the external Rancher Docker container
CERT_DIR="/etc/ssl"
CERT_FILE="$CERT_DIR/butterflycluster_com.crt.pem"
KEY_FILE="$CERT_DIR/butterflycluster_com.key.pem"
CA_FILE="$CERT_DIR/butterflycluster_com.ca-bundle"

# --- Rancher API Details ---
# Configuration is loaded from rancher.env file.
# Run './compliance-lab.sh configure' to set these values.
RANCHER_URL=""
RANCHER_BEARER_TOKEN=""


# --- Helper Functions ---

load_config() {
  if [ -f "rancher.env" ]; then
    source "rancher.env"
  fi
}

ensure_rancher_available() {
  # Ensure Rancher container is up and API is reachable at RANCHER_URL
  local url="${RANCHER_URL}"
  if [ -z "$url" ]; then
    echo "ERROR: RANCHER_URL not set. Run './compliance-lab.sh configure' first."
    exit 1
  fi

  echo ">>> Ensuring Rancher is running at: ${url}"
  if ! docker ps -q -f name=^/${RANCHER_NAME}$ >/dev/null; then
    echo ">>> Rancher container not running; attempting to start it..."
    rancher_up
  fi

  echo ">>> Waiting for Rancher API to become reachable..."
  local tries=0
  local max_tries=60
  local status
  while [ $tries -lt $max_tries ]; do
    status=$(curl -sk -o /dev/null -w "%{http_code}" "${url}/v3-public" || true)
    if [ "$status" = "200" ]; then
      echo ">>> Rancher API is reachable."
      return 0
    fi
    tries=$((tries+1))
    sleep 5
  done
  echo "ERROR: Rancher API not reachable at ${url} after $((5*max_tries))s."
  exit 1
}

check_config() {
  if [ -z "$RANCHER_URL" ] || [ -z "$RANCHER_BEARER_TOKEN" ] || [[ "$RANCHER_URL" == *"your-rancher-url"* ]]; then
    echo "ERROR: Rancher API details are not configured."
    echo "Please run './compliance-lab.sh configure' first."
    exit 1
  fi
}

check_deps() {
  echo ">>> Checking for dependencies..."
  local missing=0
  for cmd in docker k3d kubectl helm istioctl velero curl jq; do
    if ! command -v "$cmd" &> /dev/null; then
      echo "ERROR: '$cmd' command not found. Please install it (try: ./setup-deps.sh)."
      missing=1
    fi
  done
  if [ "$missing" -eq 1 ]; then
    exit 1
  fi
}

validate_cloudflare_credentials() {
  local cf_email="$1"
  local cf_token="$2"
  local cf_zone_id="$3"

  echo ">>> Validating Cloudflare API credentials..."

  # Test API token validity by fetching zone info
  local api_response
  local http_status

  api_response=$(curl -s -w "\n%{http_code}" -X GET "https://api.cloudflare.com/client/v4/zones/${cf_zone_id}" \
    -H "Authorization: Bearer ${cf_token}" \
    -H "Content-Type: application/json" 2>/dev/null)

  http_status=$(echo "$api_response" | tail -n1)
  api_response=$(echo "$api_response" | head -n -1)

  if [ "$http_status" != "200" ]; then
    echo "ERROR: Cloudflare API validation failed (HTTP $http_status)"
    if [ -n "$api_response" ]; then
      echo "Response: $api_response"
    fi
    return 1
  fi

  # Check if we have DNS edit permissions
  local zone_name
  zone_name=$(echo "$api_response" | jq -r '.result.name // empty' 2>/dev/null)

  if [ -z "$zone_name" ]; then
    echo "ERROR: Failed to retrieve zone information from Cloudflare API"
    return 1
  fi

  echo ">>> Cloudflare credentials validated successfully for zone: $zone_name"
  return 0
}

cleanup_failed_ssl_setup() {
  echo ">>> Cleaning up failed SSL setup..."
  kubectl delete secret cloudflare-api-token-secret -n cert-manager --ignore-not-found=true
  kubectl delete clusterissuer letsencrypt-staging --ignore-not-found=true
  kubectl delete clusterissuer letsencrypt-prod --ignore-not-found=true
  echo ">>> SSL setup cleanup completed"
}

# --- Configuration Management ---

configure_cloudflare() {
  echo "--- Cloudflare Configuration for SSL Certificates ---"
  echo "This configures Cloudflare API access for Let's Encrypt DNS-01 challenges."
  echo

  # Use environment variables as defaults if available
  local default_email="${CLOUDFLARE_EMAIL:-}"
  local default_token="${CLOUDFLARE_API_TOKEN:-}"

  if [ -n "$default_email" ]; then
    read -p "Enter your Cloudflare email address [$default_email]: " cf_email || true
  else
    read -p "Enter your Cloudflare email address: " cf_email || true
  fi
  cf_email=${cf_email:-$default_email}

  if [ -n "$default_token" ]; then
    read -sp "Enter your Cloudflare API token (Zone:DNS:Edit permission required) [***hidden***]: " cf_token || true
  else
    read -sp "Enter your Cloudflare API token (Zone:DNS:Edit permission required): " cf_token || true
  fi
  echo
  cf_token=${cf_token:-$default_token}

  local default_zone_id="${CLOUDFLARE_ZONE_ID:-}"
  if [ -n "$default_zone_id" ]; then
    read -p "Enter your Cloudflare Zone ID [$default_zone_id]: " cf_zone_id || true
  else
    read -p "Enter your Cloudflare Zone ID: " cf_zone_id || true
  fi
  cf_zone_id=${cf_zone_id:-$default_zone_id}

  if [ -z "$cf_email" ] || [ -z "$cf_token" ] || [ -z "$cf_zone_id" ]; then
    echo "Cloudflare email, API token, and Zone ID cannot be empty."
    return 1
  fi

  CLOUDFLARE_EMAIL="$cf_email"
  CLOUDFLARE_API_TOKEN="$cf_token"
  CLOUDFLARE_ZONE_ID="$cf_zone_id"

  echo "Cloudflare configuration set successfully."
}

configure_all() {
  configure_cloudflare
  configure_rancher
}

configure_rancher() {
  echo "--- Rancher API Configuration ---"
  local default_url
  default_url="${RANCHER_URL:-https://charon.butterflycluster.com:8443}"

  read -p "Enter your Rancher URL [${default_url}]: " url || true
  url=${url:-$default_url}

  read -p "Admin username [admin]: " username || true
  username=${username:-admin}

  read -sp "Admin password: " password || true
  echo

  if [ -z "$url" ] || [ -z "$username" ] || [ -z "$password" ]; then
    echo "URL, username, and password cannot be empty. Configuration failed."
    exit 1
  fi

  echo ">>> Checking Rancher API reachability..."
  api_status=$(curl -sk -m 10 -o /dev/null -w "%{http_code}" "${url}/v3-public" || true)
  if [ -z "$api_status" ] || [ "$api_status" = "000" ]; then
    echo "ERROR: Unable to reach Rancher at ${url}. Ensure Rancher is running and accessible."
    exit 1
  fi

  # If an existing bearer token is present and valid, reuse it
  if [ -n "${RANCHER_BEARER_TOKEN:-}" ]; then
    echo ">>> Validating existing API token..."
    validate_status=$(curl -sk -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${RANCHER_BEARER_TOKEN}" "${url}/v3" || true)
    if [ "$validate_status" = "200" ]; then
      echo ">>> Existing token is valid. Updating rancher.env with current settings."
      cat > rancher.env << EOL
# Rancher API Configuration
export RANCHER_URL="${url}"
export RANCHER_BEARER_TOKEN="${RANCHER_BEARER_TOKEN}"

# SSL certificates on the host (used by the Rancher container)
export CERT_DIR="/etc/ssl"
export CERT_FILE="/etc/ssl/butterflycluster_com.crt.pem"
export KEY_FILE="/etc/ssl/butterflycluster_com.key.pem"
export CA_FILE="/etc/ssl/butterflycluster_com.ca-bundle"

# Cloudflare Configuration (for Let's Encrypt DNS-01 challenges)
export CLOUDFLARE_EMAIL="${CLOUDFLARE_EMAIL}"
export CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN}"
export CLOUDFLARE_ZONE_ID="${CLOUDFLARE_ZONE_ID}"
EOL
      echo "Configuration saved successfully to rancher.env."
      return
    else
      echo ">>> Existing token is invalid or expired. Generating a new one..."
    fi
  fi

  echo ">>> Authenticating to Rancher..."
  # Login to obtain a session token for API calls
  if ! LOGIN_JSON=$(curl -s -k -X POST "${url}/v3-public/localProviders/local?action=login" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"${username}\",\"password\":\"${password}\"}"); then
    echo "ERROR: Failed to reach Rancher login endpoint."
    exit 1
  fi

  LOGIN_BEARER=$(echo "$LOGIN_JSON" | jq -r '.token // empty')
  if [ -z "$LOGIN_BEARER" ] || [ "$LOGIN_BEARER" = "null" ]; then
    echo "ERROR: Failed to authenticate to Rancher. Check URL and credentials."
    echo "Response: $(echo "$LOGIN_JSON" | jq -c '.')"
    exit 1
  fi

  echo ">>> Ensuring Rancher server-url is set..."
  SET_URL_STATUS=$(curl -s -k -o /dev/null -w "%{http_code}" -X PUT "${url}/v3/settings/server-url" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${LOGIN_BEARER}" \
    -d "{\"name\":\"server-url\",\"value\":\"${url}\"}")
  if [ "$SET_URL_STATUS" -ge 200 ] && [ "$SET_URL_STATUS" -lt 300 ]; then
    echo ">>> server-url set to ${url}"
  else
    echo "WARNING: Failed to set server-url (HTTP ${SET_URL_STATUS}). Continuing."
  fi

  echo ">>> Creating a long-lived API token..."
  # Try to find an existing token by name and reuse only if secret is available (usually not retrievable later)
  local token_name
  token_name="compliance-lab-$(date +%s)"

  if ! CREATE_JSON=$(curl -s -k -X POST "${url}/v3/token" \
    -H "Authorization: Bearer ${LOGIN_BEARER}" \
    -H 'Content-Type: application/json' \
    -d "{\"type\":\"token\",\"name\":\"${token_name}\",\"ttl\":0}"); then
    echo "ERROR: Failed to create API token."
    exit 1
  fi

  TOKEN_ID=$(echo "$CREATE_JSON" | jq -r '.id // empty')
  TOKEN_SECRET=$(echo "$CREATE_JSON" | jq -r '.token // empty')
  if [ -z "$TOKEN_ID" ] || [ -z "$TOKEN_SECRET" ] || [ "$TOKEN_ID" = "null" ] || [ "$TOKEN_SECRET" = "null" ]; then
    echo "ERROR: Failed to create API token."
    echo "Response: $(echo "$CREATE_JSON" | jq -c '.')"
    exit 1
  fi
  NEW_BEARER="${TOKEN_ID}:${TOKEN_SECRET}"

  echo "Saving configuration to rancher.env..."
  cat > rancher.env << EOL
# Rancher API Configuration
export RANCHER_URL="${url}"
export RANCHER_BEARER_TOKEN="${NEW_BEARER}"

# SSL certificates on the host (used by the Rancher container)
export CERT_DIR="/etc/ssl"
export CERT_FILE="/etc/ssl/butterflycluster_com.crt.pem"
export KEY_FILE="/etc/ssl/butterflycluster_com.key.pem"
export CA_FILE="/etc/ssl/butterflycluster_com.ca-bundle"

# Cloudflare Configuration (for Let's Encrypt DNS-01 challenges)
export CLOUDFLARE_EMAIL="${CLOUDFLARE_EMAIL}"
export CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN}"
export CLOUDFLARE_ZONE_ID="${CLOUDFLARE_ZONE_ID}"
EOL
  echo "Configuration saved successfully to rancher.env."
}

# --- Cluster Health Checks ---

check_node_pressure() {
  echo ">>> Checking node conditions..."
  NODE_DISK_PRESSURE="false"
  NODE_MEM_PRESSURE="false"
  if kubectl get nodes -o json | jq -e '.items[].status.conditions[] | select(.type=="DiskPressure" and .status=="True")' >/dev/null 2>&1; then
    NODE_DISK_PRESSURE="true"
    echo "WARNING: One or more nodes report DiskPressure. Consider freeing disk space on the host (e.g., prune images, clean /var)."
  fi
  if kubectl get nodes -o json | jq -e '.items[].status.conditions[] | select(.type=="MemoryPressure" and .status=="True")' >/dev/null 2>&1; then
    NODE_MEM_PRESSURE="true"
    echo "WARNING: One or more nodes report MemoryPressure. Components may fail to schedule."
  fi
}

# --- Teardown Cleanup Helpers ---

prompt_yes_no() {
  local prompt="$1"; shift || true
  local default_answer="$1"; shift || true
  local answer
  read -r -p "$prompt ${default_answer:+[$default_answer]} " answer || true
  answer=${answer:-$default_answer}
  case "$answer" in
    y|Y|yes|YES) return 0;;
    *) return 1;;
  esac
}

cleanup_docker() {
  local prune_volumes_flag="$1"; shift || true
  # Determine whether we need sudo for Docker
  local DOCKER_CMD="docker"
  if ! docker info >/dev/null 2>&1; then
    if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then
      DOCKER_CMD="sudo docker"
      echo ">>> Using sudo for Docker commands."
    fi
  fi

  echo ">>> Docker disk usage before cleanup:"
  ${DOCKER_CMD} system df || true

  echo ">>> Pruning stopped containers, dangling images, and unused networks..."
  ${DOCKER_CMD} system prune -af || true

  if [ "$prune_volumes_flag" = "true" ]; then
    echo ">>> Pruning unused Docker volumes (aggressive) ..."
    ${DOCKER_CMD} volume prune -f || true
  fi

  # Optionally remove Rancher images explicitly if still present
  if ${DOCKER_CMD} images 'rancher/rancher*' -q | grep -q .; then
    echo ">>> Removing Rancher images..."
    ${DOCKER_CMD} images 'rancher/rancher*' -q | xargs -r ${DOCKER_CMD} rmi -f || true
  fi

  echo ">>> Docker disk usage after cleanup:"
  ${DOCKER_CMD} system df || true
}

# --- General Cleanup Command ---

cleanup() {
  echo ">>> Cleanup helper"
  echo "This will prune Docker images, containers, and networks."
  echo "Optionally, it can also prune unused Docker volumes (more aggressive)."

  if [ "$AUTO_DOCKER_PRUNE" = "true" ]; then
    cleanup_docker "$PRUNE_DOCKER_VOLUMES"
  else
    if prompt_yes_no ">>> Run Docker prune to free space now?" "y"; then
      local prune_vols="false"
      if prompt_yes_no ">>> Also prune volumes?" "n"; then
        prune_vols="true"
      fi
      cleanup_docker "$prune_vols"
    else
      echo ">>> Skipped Docker prune."
    fi
  fi

  echo
  echo "Additionally, you may purge Rancher data at '$RANCHER_DIR'."
  cleanup_rancher_fs
}

# --- Rancher filesystem cleanup (/var/lib/rancher) ---

_need_sudo_for_path() {
  local path="$1"
  [ -w "$path" ] && echo "" && return 0
  if command -v sudo >/dev/null 2>&1; then
    echo "sudo"
    return 0
  fi
  echo "" # fallback, may fail without sudo
}

_show_dir_size() {
  local path="$1"
  local SUDO="$(_need_sudo_for_path "$path")"
  ${SUDO} du -sh "$path" 2>/dev/null || echo "(no access to size for $path)"
}

cleanup_rancher_fs() {
  local path="${RANCHER_DIR}"
  if [ ! -d "$path" ]; then
    echo ">>> Rancher directory '$path' not found; skipping."
    return
  fi

  echo ">>> Rancher dir before cleanup: $path"
  _show_dir_size "$path"

  local proceed="false"
  if [ "$AUTO_RANCHER_PURGE" = "true" ]; then
    proceed="true"
  else
    echo "WARNING: This will delete contents under '$path'."
    echo "         Do this only if you don't need any Rancher/k3s data on this host."
    if prompt_yes_no ">>> Purge contents of $path now?" "n"; then
      proceed="true"
    fi
  fi

  if [ "$proceed" = "true" ]; then
    local SUDO="$(_need_sudo_for_path "$path")"
    echo ">>> Purging contents of $path ..."
    # Remove all children but not the directory itself; handles dotfiles safely
    ${SUDO} find "$path" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    sync || true
    echo ">>> Rancher dir after cleanup:"
    _show_dir_size "$path"
  else
    echo ">>> Skipped purging $path."
  fi
}

# --- Rancher Container Management ---

rancher_up() {
  echo ">>> Starting Rancher container..."
  if [ "$(docker ps -q -f name=^/${RANCHER_NAME}$)" ]; then
    echo "Rancher container is already running."
    echo "Access it at: ${RANCHER_URL:-https://localhost:8443}"
    return
  fi
  if [ "$(docker ps -aq -f status=exited -f name=^/${RANCHER_NAME}$)" ]; then
    echo "Removing existing stopped Rancher container."
    docker rm "$RANCHER_NAME"
  fi

  echo "Starting new Rancher container named '$RANCHER_NAME'..."
  docker run -d --restart=unless-stopped \
    -p 8080:80 -p 8443:443 \
    -v "${CERT_FILE}":/etc/rancher/ssl/cert.pem:ro \
    -v "${KEY_FILE}":/etc/rancher/ssl/key.pem:ro \
    -v "${CA_FILE}":/etc/rancher/ssl/cacerts.pem:ro \
    --privileged \
    --name "$RANCHER_NAME" \
    rancher/rancher:latest

  echo "Rancher container started. It may take a few minutes to become available."
  echo "Access it at: ${RANCHER_URL:-https://localhost:8443}"
}

rancher_down() {
  echo ">>> Stopping and removing Rancher container..."
  if [ ! "$(docker ps -aq -f name=^/${RANCHER_NAME}$)" ]; then
    echo "Rancher container not found."
    return
  fi
  docker stop "$RANCHER_NAME"
  docker rm "$RANCHER_NAME"
  echo "Rancher container removed."

  # Optional cleanup
  if [ "$AUTO_DOCKER_PRUNE" = "true" ]; then
    cleanup_docker "$PRUNE_DOCKER_VOLUMES"
  else
    if prompt_yes_no ">>> Run Docker prune to free space now?" "n"; then
      cleanup_docker "$(prompt_yes_no ">>> Also prune volumes?" "n" && echo true || echo false)"
    fi
  fi

  # Optional Rancher filesystem purge
  cleanup_rancher_fs
}

rancher_reset() {
  rancher_down
  rancher_up
}

# --- K3s Cluster Management ---

register_cluster() {
  check_config
  echo ">>> Registering cluster with Rancher..."

  ensure_rancher_available

  echo ">>> Validating Rancher API and token..."
  STATUS=$(curl -s -k -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${RANCHER_BEARER_TOKEN}" "${RANCHER_URL}/v3" || true)
  if [ "$STATUS" != "200" ]; then
    echo "ERROR: Rancher API not reachable or token invalid. HTTP ${STATUS}"
    echo "Hint: re-run './compliance-lab.sh configure' or check RANCHER_URL in rancher.env"
    exit 1
  fi

  echo "Creating cluster in Rancher..."
  TMPRESP=$(mktemp)
  HTTP_STATUS=$(curl -s -k -o "$TMPRESP" -w "%{http_code}" -X POST "${RANCHER_URL}/v3/clusters" \
    -H "Authorization: Bearer ${RANCHER_BEARER_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "{\"type\":\"cluster\",\"name\":\"${CLUSTER_NAME}\"}")
  CLUSTER_ID=$(cat "$TMPRESP" | jq -r '.id // empty')

  if [ "$HTTP_STATUS" -lt 200 ] || [ "$HTTP_STATUS" -ge 300 ] || [ -z "$CLUSTER_ID" ]; then
    echo "ERROR: Failed to create cluster in Rancher. HTTP ${HTTP_STATUS}"
    echo "Response: $(cat "$TMPRESP" | jq -c '.')"
    rm -f "$TMPRESP"
    exit 1
  fi
  rm -f "$TMPRESP"
  echo "Cluster object created with ID: ${CLUSTER_ID}"

  echo "Waiting for cluster object to be ready in Rancher..."
  for i in $(seq 1 12); do
    CLUSTER_STATE=$(curl -s -k -H "Authorization: Bearer ${RANCHER_BEARER_TOKEN}" "${RANCHER_URL}/v3/clusters/${CLUSTER_ID}" | jq -r '.state // empty')
    if [ "$CLUSTER_STATE" != "provisioning" ] && [ -n "$CLUSTER_STATE" ]; then
      echo "Cluster state is now '${CLUSTER_STATE}'. Proceeding."
      break
    fi
    if [ $i -eq 12 ]; then
       echo "ERROR: Cluster '${CLUSTER_NAME}' did not become ready in Rancher after 60s."
       exit 1
    fi
    echo "Waiting for cluster to finish provisioning... (${i}/12)"
    sleep 5
  done

  echo "Generating registration token..."
  # Create a token resource, then poll until manifestUrl is populated
  TMP_TOKEN_RESP=$(mktemp)
  TOKEN_HTTP=$(curl -s -k -o "$TMP_TOKEN_RESP" -w "%{http_code}" -X POST "${RANCHER_URL}/v3/clusterregistrationtokens" \
    -H "Authorization: Bearer ${RANCHER_BEARER_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "{\"type\":\"clusterRegistrationToken\",\"clusterId\":\"${CLUSTER_ID}\"}")
  if [ "$TOKEN_HTTP" -lt 200 ] || [ "$TOKEN_HTTP" -ge 300 ]; then
    echo "ERROR: Failed to create cluster registration token. HTTP ${TOKEN_HTTP}"
    echo "Response: $(cat "$TMP_TOKEN_RESP" | jq -c '.')"
    rm -f "$TMP_TOKEN_RESP"
    exit 1
  fi
  TOKEN_ID=$(cat "$TMP_TOKEN_RESP" | jq -r '.id // empty')
  rm -f "$TMP_TOKEN_RESP"

  # Poll for manifestUrl up to 5 minutes
  MANIFEST_URL=""
  for i in $(seq 1 60); do
    # Try by ID first if we have it
    if [ -n "$TOKEN_ID" ]; then
      POLL_JSON=$(curl -s -k -H "Authorization: Bearer ${RANCHER_BEARER_TOKEN}" "${RANCHER_URL}/v3/clusterregistrationtokens/${TOKEN_ID}")
      MANIFEST_URL=$(echo "$POLL_JSON" | jq -r '.manifestUrl // empty')
    fi
    # Fallback: list tokens by clusterId and take the first with manifestUrl
    if [ -z "$MANIFEST_URL" ]; then
      LIST_JSON=$(curl -s -k -H "Authorization: Bearer ${RANCHER_BEARER_TOKEN}" "${RANCHER_URL}/v3/clusterregistrationtokens?clusterId=${CLUSTER_ID}")
      MANIFEST_URL=$(echo "$LIST_JSON" | jq -r '.data[] | select(.manifestUrl != null) | .manifestUrl' | head -n1)
    fi

    if [ -n "$MANIFEST_URL" ]; then
      break
    fi
    echo "Waiting for manifest URL... (${i}/60)"
    sleep 5
  done

  if [ -z "$MANIFEST_URL" ]; then
    echo "ERROR: Failed to generate registration token (manifestUrl not ready)."
    exit 1
  fi
  echo "Registration manifest URL obtained."

  echo "Applying registration manifest to cluster..."
  # Some environments use a private CA for Rancher; download with -k and pipe to kubectl
  if ! curl -skL "${MANIFEST_URL}" | kubectl apply -f -; then
    echo "ERROR: Failed to apply registration manifest."
    echo "Tried to fetch with TLS skip-verify due to potential private CA."
    echo "Manifest URL: ${MANIFEST_URL}"
    exit 1
  fi
  echo "Cluster registration initiated. It may take a few minutes for the cluster to become active in Rancher."
}

deregister_cluster() {
  check_config
  echo ">>> Deregistering cluster from Rancher..."

  echo "Finding cluster ID for '${CLUSTER_NAME}'..."
  CLUSTER_ID=$(curl -s -k -X GET "${RANCHER_URL}/v3/clusters?name=${CLUSTER_NAME}" \
    -H "Authorization: Bearer ${RANCHER_BEARER_TOKEN}" \
    -H 'Content-Type: application/json' | jq -r '.data[0].id')

  if [ -z "$CLUSTER_ID" ] || [ "$CLUSTER_ID" == "null" ]; then
    echo "WARNING: Cluster '${CLUSTER_NAME}' not found in Rancher. Skipping."
    return
  fi
  echo "Found cluster ID: ${CLUSTER_ID}"

  echo "Deleting cluster from Rancher..."
  DELETE_STATUS=$(curl -s -k -X DELETE "${RANCHER_URL}/v3/clusters/${CLUSTER_ID}" \
    -H "Authorization: Bearer ${RANCHER_BEARER_TOKEN}" \
    -o /dev/null -w "%{http_code}")

  if [ "$DELETE_STATUS" -ge 200 ] && [ "$DELETE_STATUS" -lt 300 ]; then
    echo "Cluster deregistration successful."
  else
    echo "WARNING: Failed to deregister cluster from Rancher. HTTP status: ${DELETE_STATUS}"
  fi
}

create_cluster() {
  echo ">>> Creating k3d cluster: $CLUSTER_NAME"
  k3d cluster create "$CLUSTER_NAME" --agents 1 --port '80:80@loadbalancer' --port '443:443@loadbalancer' --k3s-arg "--disable=traefik@server:0" --wait
  export KUBECONFIG=$(k3d kubeconfig write "$CLUSTER_NAME")

  echo ">>> Installing OpenEBS LocalPV Hostpath..."
  kubectl apply -f https://raw.githubusercontent.com/openebs/dynamic-localpv-provisioner/develop/deploy/kubectl/openebs-operator-lite.yaml
  # Wait for the LocalPV provisioner to be ready before creating the StorageClass
  kubectl wait --for=condition=available --timeout=300s deployment/openebs-localpv-provisioner -n openebs || true

  echo ">>> Creating OpenEBS hostpath StorageClass..."
  kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: openebs-hostpath
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: openebs.io/local
parameters:
  StorageType: "hostpath"
  BasePath: "/var/openebs/local"
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
EOF

  echo ">>> Installing cert-manager..."
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
  kubectl wait --for=condition=available --timeout=300s deployment/cert-manager-webhook -n cert-manager

  echo ">>> Configuring SSL certificates with Let's Encrypt and Cloudflare..."
  if [ -z "${CLOUDFLARE_API_TOKEN:-}" ] || [ -z "${CLOUDFLARE_EMAIL:-}" ] || [ -z "${CLOUDFLARE_ZONE_ID:-}" ]; then
    if [ "$REQUIRE_SSL" = "true" ]; then
      echo "ERROR: Cloudflare credentials (API Token, Email, Zone ID) not configured and REQUIRE_SSL=true"
      echo "Run './compliance-lab.sh configure' to set up Cloudflare integration."
      exit 1
    else
      echo "WARNING: Cloudflare credentials (API Token, Email, Zone ID) not configured. SSL certificates will not be automatically issued."
      echo "Run './compliance-lab.sh configure' to set up Cloudflare integration."
    fi
  else
    # Validate Cloudflare credentials before proceeding
    if ! validate_cloudflare_credentials "${CLOUDFLARE_EMAIL}" "${CLOUDFLARE_API_TOKEN}" "${CLOUDFLARE_ZONE_ID}"; then
      if [ "$REQUIRE_SSL" = "true" ]; then
        echo "ERROR: Cloudflare credential validation failed and REQUIRE_SSL=true"
        exit 1
      else
        echo "WARNING: Cloudflare credential validation failed. Continuing without SSL setup."
        echo "Fix your credentials and run './compliance-lab.sh configure' to retry."
      fi
    else
      echo ">>> Creating Cloudflare credentials secret..."
      if ! kubectl create secret generic cloudflare-api-token-secret -n cert-manager \
        --from-literal=api-token="${CLOUDFLARE_API_TOKEN}" --dry-run=client -o yaml | kubectl apply -f -; then
        echo "ERROR: Failed to create Cloudflare credentials secret"
        if [ "$REQUIRE_SSL" = "true" ]; then
          cleanup_failed_ssl_setup
          exit 1
        else
          echo "WARNING: Continuing without SSL setup"
        fi
      else
        echo ">>> Applying ClusterIssuer manifest..."
        # Create temporary file to debug YAML structure
        TEMP_MANIFEST=$(mktemp)
        cat > "$TEMP_MANIFEST" <<EOF
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: "${CLOUDFLARE_EMAIL}"
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
    - dns01:
        cloudflare:
          apiTokenSecretRef:
            name: cloudflare-api-token-secret
            key: api-token
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: "${CLOUDFLARE_EMAIL}"
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - dns01:
        cloudflare:
          apiTokenSecretRef:
            name: cloudflare-api-token-secret
            key: api-token
EOF
        echo ">>> Generated ClusterIssuer manifest:"
        cat "$TEMP_MANIFEST"
        echo ">>> Applying manifest..."
        if ! kubectl apply -f "$TEMP_MANIFEST"; then
          echo "ERROR: Failed to apply ClusterIssuer manifest"
          rm -f "$TEMP_MANIFEST"
          if [ "$REQUIRE_SSL" = "true" ]; then
            cleanup_failed_ssl_setup
            exit 1
          else
            echo "WARNING: Continuing without SSL setup"
          fi
        else
          # Wait for ClusterIssuer to be ready
          echo "Waiting for ClusterIssuer to be ready..."
          if ! kubectl wait --for=condition=Ready clusterissuer/letsencrypt-prod --timeout=300s; then
            echo "ERROR: ClusterIssuer did not become ready within 5 minutes"
            if [ "$REQUIRE_SSL" = "true" ]; then
              cleanup_failed_ssl_setup
              exit 1
            else
              echo "WARNING: SSL setup may not work properly. Continuing anyway."
            fi
          else
            echo "Cloudflare ClusterIssuer configured successfully. Wildcard certificate will be applied after Istio installation."
          fi
        fi
      fi
    fi
  fi

  echo ">>> Skipping MinIO installation (temporarily disabled for debugging)"
  # echo ">>> Installing MinIO (single instance)..."
  # kubectl create ns minio || true
  # helm repo add minio https://charts.min.io/
  # helm upgrade --install minio minio/minio -n minio \
  #   --set mode=standalone \
  #   --set replicas=1 \
  #   --set auth.rootUser=${MINIO_ACCESS_KEY} \
  #   --set auth.rootPassword=${MINIO_SECRET_KEY} \
  #   --set defaultBuckets="velero" \
  #   --set persistence.enabled=true \
  #   --set persistence.size=5Gi \
  #   --set resources.requests.memory=512Mi \
  #   --set resources.requests.cpu=250m
  # kubectl wait --for=condition=available --timeout=300s deployment/minio -n minio
  # kubectl wait --for=condition=ready --timeout=300s pod -l app=minio -n minio

  echo ">>> Skipping Velero installation (disabled due to MinIO dependency)"
  # echo ">>> Installing Velero..."
  # # Ensure MinIO credentials file exists for Velero's AWS plugin
  # mkdir -p ./manifests
  # if [ ! -f ./manifests/minio-credentials ]; then
  #   cat > ./manifests/minio-credentials <<EOF
  # [default]
  # aws_access_key_id = ${MINIO_ACCESS_KEY}
  # aws_secret_access_key = ${MINIO_SECRET_KEY}
  # EOF
  #   chmod 600 ./manifests/minio-credentials || true
  # fi
  # velero install \
  #   --provider aws \
  #   --plugins velero/velero-plugin-for-aws:v1.8.0 \
  #   --bucket velero \
  #   --secret-file ./manifests/minio-credentials \
  #   --use-volume-snapshots=false \
  #   --backup-location-config region=minio,s3ForcePathStyle=true,s3Url=http://minio.minio.svc.cluster.local:9000

  echo ">>> Prechecking Istio..."
  istioctl x precheck || true

  echo ">>> Installing Istio (tuned for k3d)..."
  cat <<'EOF' | istioctl install -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  profile: demo
  components:
    pilot:
      k8s:
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
    ingressGateways:
    - name: istio-ingressgateway
      enabled: true
      k8s:
        resources:
          requests:
            cpu: 50m
            memory: 128Mi
        hpaSpec:
          minReplicas: 1
          maxReplicas: 1
    egressGateways:
    - name: istio-egressgateway
      enabled: true
      k8s:
        resources:
          requests:
            cpu: 50m
            memory: 128Mi
        hpaSpec:
          minReplicas: 1
          maxReplicas: 1
EOF

  echo ">>> Waiting for Istio control plane and gateways..."
  kubectl -n istio-system rollout status deploy/istiod --timeout=600s || true
  kubectl -n istio-system rollout status deploy/istio-ingressgateway --timeout=600s || true
  kubectl -n istio-system rollout status deploy/istio-egressgateway --timeout=600s || true

  echo ">>> Configuring Istio Gateway for SSL termination..."
  kubectl apply -f manifests/istio-gateway.yaml

  # Apply wildcard certificate now that istio-system namespace exists
  if [ -n "$CLOUDFLARE_API_TOKEN" ] && [ -n "$CLOUDFLARE_EMAIL" ]; then
    echo ">>> Requesting wildcard SSL certificate..."
    kubectl apply -f manifests/wildcard-certificate.yaml
    echo "Wildcard certificate requested. It may take a few minutes to be issued."
    echo "Check status with: kubectl get certificate -n istio-system"
  fi

  echo ">>> Skipping Keycloak installation (temporarily disabled for debugging)"
  # echo ">>> Installing Keycloak..."
  # helm repo add codecentric https://codecentric.github.io/helm-charts
  # helm upgrade --install keycloak codecentric/keycloakx -n keycloak --create-namespace \
  #   --set replicas=1 \
  #   --set ingress.enabled=true \
  #   --set ingress.hosts[0].host=keycloak.$K3S_INGRESS_DOMAIN \
  #   --set ingress.hosts[0].paths[0].path=/ \
  #   --set args='{start-dev}'

  # echo ">>> Applying Keycloak VirtualService..."
  # kubectl apply -f manifests/keycloak-virtualservice.yaml

  echo ">>> Skipping Vault installation (temporarily disabled for debugging)"
  # echo ">>> Installing Vault..."
  # helm repo add hashicorp https://helm.releases.hashicorp.com
  # helm upgrade --install vault hashicorp/vault -n vault --create-namespace \
  #   --set server.dev.enabled=true

  echo ">>> Skipping ELK installation (temporarily disabled for debugging)"
  # echo ">>> Installing ELK (minimal, tuned for k3d)..."
  # helm repo add elastic https://helm.elastic.co
  # check_node_pressure
  # ELASTIC_TOLERATIONS_ARGS=()
  # if [ "${NODE_DISK_PRESSURE}" = "true" ] && [ "${ALLOW_TAINTED_NODES:-}" = "true" ]; then
  #   echo ">>> Allowing scheduling on DiskPressure nodes for Elasticsearch (override)."
  #   ELASTIC_TOLERATIONS_ARGS+=(
  #     --set tolerations[0].key=node.kubernetes.io/disk-pressure \
  #     --set tolerations[0].operator=Exists \
  #     --set tolerations[0].effect=NoSchedule
  #   )
  # fi
  # helm upgrade --install elasticsearch elastic/elasticsearch -n elk --create-namespace \
  #   --set replicas=1 \
  #   --set resources.requests.cpu=200m \
  #   --set resources.requests.memory=512Mi \
  #   --set resources.limits.memory=1Gi \
  #   --set esJavaOpts="-Xms512m -Xmx512m" \
  #   --set persistence.enabled=false \
  #   ${ELASTIC_TOLERATIONS_ARGS[@]} \
  #   --wait --timeout 10m
  # helm upgrade --install kibana elastic/kibana -n elk \
  #   --set replicas=1 \
  #   --set resources.requests.cpu=100m \
  #   --set resources.requests.memory=256Mi \
  #   --wait --timeout 10m

  # echo ">>> Waiting for ELK pods to become Ready..."
  # kubectl -n elk wait --for=condition=ready pod --all --timeout=600s || true

  # echo ">>> Installing Fluent Bit..."
  # helm repo add fluent https://fluent.github.io/helm-charts
  # helm upgrade --install fluent-bit fluent/fluent-bit -n logging --create-namespace \
  #   --set backend.type=es \
  #   --set backend.es.host=elasticsearch-master.elk.svc.cluster.local

  echo ">>> Skipping Prometheus Operator installation (temporarily disabled for debugging)"
  # echo ">>> Installing Prometheus Operator (minimal)..."
  # helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  # helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack -n monitoring --create-namespace \
  #   --set prometheus.prometheusSpec.replicas=1 \
  #   --set prometheus.prometheusSpec.resources.requests.cpu=250m \
  #   --set prometheus.prometheusSpec.resources.requests.memory=512Mi \
  #   --set prometheus.prometheusSpec.retention=7d \
  #   --set alertmanager.alertmanagerSpec.replicas=1 \
  #   --set alertmanager.alertmanagerSpec.resources.requests.cpu=100m \
  #   --set alertmanager.alertmanagerSpec.resources.requests.memory=128Mi \
  #   --set grafana.replicas=1 \
  #   --set grafana.resources.requests.cpu=100m \
  #   --set grafana.resources.requests.memory=128Mi

  echo ">>> Skipping compliance manifests (temporarily disabled for debugging)"
  # echo ">>> Applying compliance manifests..."
  # kubectl apply -f manifests/compliance-system.yaml
  # kubectl apply -f manifests/compliance-test.yaml

  echo ">>> Skipping Rancher cluster registration (temporarily disabled for debugging)"
  # register_cluster

  echo ">>> Cluster ready!"
  echo
  echo "=== SSL Certificate Configuration ==="
  if [ -n "$CLOUDFLARE_API_TOKEN" ] && [ -n "$CLOUDFLARE_EMAIL" ]; then
    echo "✓ Wildcard SSL certificate configured for *.dev.butterflycluster.com"
    echo "  Certificate will be stored as: istio-system/dev-wildcard-tls"
    echo "  Check certificate status: kubectl get certificate -n istio-system"
    echo
    echo "📋 DNS Configuration Required:"
    echo "  Make sure these DNS records point to your cluster's ingress IP:"
    echo "  - *.dev.butterflycluster.com -> [your-cluster-ingress-ip]"
    echo "  - keycloak.dev.butterflycluster.com -> [your-cluster-ingress-ip]"
    echo
    echo "🔗 Access Applications:"
    echo "  - Keycloak: https://keycloak.dev.butterflycluster.com"
    echo "  - Add more apps with VirtualServices referencing 'istio-system/dev-wildcard-gateway'"
  else
    echo "⚠️  SSL certificates not configured. Run './compliance-lab.sh configure' to set up Cloudflare."
  fi
}

destroy_cluster() {
  deregister_cluster
  echo ">>> Deleting k3d cluster..."
  k3d cluster delete "$CLUSTER_NAME" || true
  echo ">>> Cluster removed."

  # Optional cleanup
  if [ "$AUTO_DOCKER_PRUNE" = "true" ]; then
    cleanup_docker "$PRUNE_DOCKER_VOLUMES"
  else
    if prompt_yes_no ">>> Run Docker prune to free space now?" "n"; then
      cleanup_docker "$(prompt_yes_no ">>> Also prune volumes?" "n" && echo true || echo false)"
    fi
  fi

  # Optional Rancher filesystem purge
  cleanup_rancher_fs

  echo ">>> Cleanup complete."
}

# --- Main Logic ---

load_config
check_deps

case "${1:-}" in
  up) create_cluster ;; 
  down) destroy_cluster ;; 
  reset) 
    destroy_cluster 
    create_cluster 
    ;; 
  rancher-up) rancher_up ;; 
  rancher-down) rancher_down ;; 
  rancher-reset) rancher_reset ;; 
  configure) configure_all ;;
  configure-cloudflare) configure_cloudflare ;; 
  cleanup) cleanup ;;
  *) 
    echo "Usage: $0 {up|down|reset|rancher-up|rancher-down|rancher-reset|configure|cleanup}"
    echo
    echo "SSL Certificate Features:"
    echo "  • Automatic wildcard SSL certificates for *.dev.butterflycluster.com"
    echo "  • Let's Encrypt integration with Cloudflare DNS-01 challenges"
    echo "  • Istio Gateway configured for HTTPS termination"
    echo "  • Run 'configure' command to set up Cloudflare API credentials"
    echo
    echo "SSL Configuration options:"
    echo "  REQUIRE_SSL=true                 Fail if SSL setup fails (default: true)"
    echo "  REQUIRE_SSL=false                Warn but continue if SSL setup fails"
    echo
    echo "Teardown cleanup options:"
    echo "  AUTO_DOCKER_PRUNE=true           Auto-prune Docker on teardown"
    echo "  PRUNE_DOCKER_VOLUMES=true        Also prune Docker volumes (aggressive)"
    echo "  AUTO_RANCHER_PURGE=true          Purge contents of $RANCHER_DIR during cleanup"
    echo "  RANCHER_DIR=/var/lib/rancher     Path to Rancher data on host"
    exit 1 
    ;; 
esac
