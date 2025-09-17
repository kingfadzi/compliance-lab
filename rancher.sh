#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
RANCHER_NAME="${RANCHER_NAME:-rancher}"

# --- Cleanup behavior (tunable via env) ---
# When true, automatically prune docker artifacts during teardown.
AUTO_DOCKER_PRUNE=${AUTO_DOCKER_PRUNE:-false}
# When true (and pruning), also prune volumes (more aggressive space reclaim).
PRUNE_DOCKER_VOLUMES=${PRUNE_DOCKER_VOLUMES:-false}
# When true, purge Rancher filesystem state under /var/lib/rancher during cleanup.
AUTO_RANCHER_PURGE=${AUTO_RANCHER_PURGE:-false}
# Path to Rancher state directory on host
RANCHER_DIR=${RANCHER_DIR:-/var/lib/rancher}

# --- Local SSL Certificate Paths ---
# Used for the external Rancher Docker container
CERT_DIR="${CERT_DIR:-/etc/ssl}"
CERT_FILE="${CERT_FILE:-$CERT_DIR/butterflycluster_com.crt.pem}"
KEY_FILE="${KEY_FILE:-$CERT_DIR/butterflycluster_com.key.pem}"
CA_FILE="${CA_FILE:-$CERT_DIR/butterflycluster_com.ca-bundle}"

# --- Rancher API Details ---
# Configuration is loaded from rancher.env file.
# Run './rancher.sh configure' to set these values.
RANCHER_URL=""
RANCHER_BEARER_TOKEN=""

# --- Helper Functions ---

detect_environment() {
  local hostname=$(hostname 2>/dev/null || echo "unknown")

  # Check for environment-specific config files first
  if [ -f "config/rancher.local" ]; then
    echo "local"
  elif [ -f "config/rancher.dev" ]; then
    echo "dev"
  elif [ -f "config/rancher.staging" ]; then
    echo "staging"
  elif [ -f "config/rancher.prod" ]; then
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

load_config() {
  local env=$(detect_environment)
  if [ -f "config/rancher.${env}" ]; then
    source "config/rancher.${env}"
  fi
}

ensure_rancher_available() {
  # Ensure Rancher container is up and API is reachable at RANCHER_URL
  local url="${RANCHER_URL}"
  if [ -z "$url" ]; then
    echo "ERROR: RANCHER_URL not set. Run './rancher.sh configure' first."
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
    echo "Please run './rancher.sh configure' first."
    exit 1
  fi
}

check_deps() {
  echo ">>> Checking for dependencies..."
  local missing=0
  for cmd in docker curl jq; do
    if ! command -v "$cmd" &> /dev/null; then
      echo "ERROR: '$cmd' command not found. Please install it."
      missing=1
    fi
  done
  if [ "$missing" -eq 1 ]; then
    exit 1
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

# --- Configuration Management ---

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
      local env=$(detect_environment)
      echo ">>> Existing token is valid. Updating config/rancher.${env} with current settings."
      mkdir -p config
      cat > config/rancher.${env} << EOL
# Rancher API Configuration
export RANCHER_URL="${url}"
export RANCHER_BEARER_TOKEN="${RANCHER_BEARER_TOKEN}"

# SSL certificates on the host (used by the Rancher container)
export CERT_DIR="${CERT_DIR}"
export CERT_FILE="${CERT_FILE}"
export KEY_FILE="${KEY_FILE}"
export CA_FILE="${CA_FILE}"
EOL
      echo "Configuration saved successfully to config/rancher.${env}."
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
  token_name="rancher-$(date +%s)"

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

  local env=$(detect_environment)
  echo "Saving configuration to config/rancher.${env}..."
  mkdir -p config
  cat > config/rancher.${env} << EOL
# Rancher API Configuration
export RANCHER_URL="${url}"
export RANCHER_BEARER_TOKEN="${NEW_BEARER}"

# SSL certificates on the host (used by the Rancher container)
export CERT_DIR="${CERT_DIR}"
export CERT_FILE="${CERT_FILE}"
export KEY_FILE="${KEY_FILE}"
export CA_FILE="${CA_FILE}"
EOL
  echo "Configuration saved successfully to config/rancher.${env}."
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

# --- K3s Cluster Registration ---

register_cluster() {
  local cluster_name="${1:-compliance-lab}"
  check_config
  echo ">>> Registering cluster '$cluster_name' with Rancher..."

  ensure_rancher_available

  echo ">>> Validating Rancher API and token..."
  STATUS=$(curl -s -k -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${RANCHER_BEARER_TOKEN}" "${RANCHER_URL}/v3" || true)
  if [ "$STATUS" != "200" ]; then
    echo "ERROR: Rancher API not reachable or token invalid. HTTP ${STATUS}"
    echo "Hint: re-run './rancher.sh configure' or check RANCHER_URL in config/rancher.{environment}"
    exit 1
  fi

  echo "Creating cluster in Rancher..."
  TMPRESP=$(mktemp)
  HTTP_STATUS=$(curl -s -k -o "$TMPRESP" -w "%{http_code}" -X POST "${RANCHER_URL}/v3/clusters" \
    -H "Authorization: Bearer ${RANCHER_BEARER_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "{\"type\":\"cluster\",\"name\":\"${cluster_name}\"}")
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
       echo "ERROR: Cluster '${cluster_name}' did not become ready in Rancher after 60s."
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
  echo "Registration manifest URL obtained: ${MANIFEST_URL}"
  echo ""
  echo "To register your cluster, run:"
  echo "  curl -skL \"${MANIFEST_URL}\" | kubectl apply -f -"
  echo ""
  echo "Or if you have kubectl configured for your cluster:"
  if command -v kubectl &> /dev/null; then
    echo ">>> Applying registration manifest to cluster..."
    if ! curl -skL "${MANIFEST_URL}" | kubectl apply -f -; then
      echo "ERROR: Failed to apply registration manifest."
      echo "Tried to fetch with TLS skip-verify due to potential private CA."
      echo "Manifest URL: ${MANIFEST_URL}"
      exit 1
    fi
    echo "Cluster registration initiated. It may take a few minutes for the cluster to become active in Rancher."
  fi

  # Clean up docker resources after registration
  echo ">>> Cleaning up Docker resources..."
  if [ "$AUTO_DOCKER_PRUNE" = "true" ]; then
    cleanup_docker "$PRUNE_DOCKER_VOLUMES"
  else
    if prompt_yes_no ">>> Run Docker prune to free space after registration?" "n"; then
      local prune_vols="false"
      if prompt_yes_no ">>> Also prune volumes?" "n"; then
        prune_vols="true"
      fi
      cleanup_docker "$prune_vols"
    else
      echo ">>> Skipped Docker cleanup."
    fi
  fi
}

deregister_cluster() {
  local cluster_name="${1:-compliance-lab}"
  check_config
  echo ">>> Deregistering cluster '$cluster_name' from Rancher..."

  echo "Finding cluster ID for '${cluster_name}'..."
  CLUSTER_ID=$(curl -s -k -X GET "${RANCHER_URL}/v3/clusters?name=${cluster_name}" \
    -H "Authorization: Bearer ${RANCHER_BEARER_TOKEN}" \
    -H 'Content-Type: application/json' | jq -r '.data[0].id')

  if [ -z "$CLUSTER_ID" ] || [ "$CLUSTER_ID" == "null" ]; then
    echo "WARNING: Cluster '${cluster_name}' not found in Rancher. Skipping."
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

# --- Main Logic ---

load_config
check_deps

case "${1:-}" in
  up) rancher_up ;;
  down) rancher_down ;;
  reset) rancher_reset ;;
  configure) configure_rancher ;;
  cleanup) cleanup ;;
  register) register_cluster "${2:-compliance-lab}" ;;
  deregister) deregister_cluster "${2:-compliance-lab}" ;;
  *)
    echo "Usage: $0 {up|down|reset|configure|cleanup|register [cluster-name]|deregister [cluster-name]}"
    echo
    echo "Rancher Management:"
    echo "  up                    Start Rancher container"
    echo "  down                  Stop and remove Rancher container"
    echo "  reset                 Restart Rancher container"
    echo "  configure             Configure Rancher API credentials"
    echo "  cleanup               Clean up Docker resources and Rancher data"
    echo
    echo "Cluster Registration:"
    echo "  register [name]       Register cluster with Rancher (default: compliance-lab)"
    echo "  deregister [name]     Deregister cluster from Rancher (default: compliance-lab)"
    echo
    echo "Environment Variables:"
    echo "  AUTO_DOCKER_PRUNE=true        Auto-prune Docker on teardown"
    echo "  PRUNE_DOCKER_VOLUMES=true     Also prune Docker volumes (aggressive)"
    echo "  AUTO_RANCHER_PURGE=true       Purge contents of $RANCHER_DIR during cleanup"
    echo "  RANCHER_DIR=/var/lib/rancher  Path to Rancher data on host"
    exit 1
    ;;
esac