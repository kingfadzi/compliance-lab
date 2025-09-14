#!/usr/bin/env bash
set -euo pipefail

# setup-deps.sh
# Installs required CLI tools: kubectl, istioctl, velero, jq
# Supported OS: macOS (Homebrew), Debian/Ubuntu, RHEL/CentOS/Fedora, openSUSE

REQUIRED=(kubectl istioctl velero jq)

SUDO=""
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "This script may need root privileges. Install 'sudo' or run as root."
  fi
fi

have_cmd() { command -v "$1" >/dev/null 2>&1; }

os_id=""
os_like=""
if [ "$(uname -s)" = "Darwin" ]; then
  os_id="darwin"
else
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    os_id="${ID:-}"
    os_like="${ID_LIKE:-}"
  fi
fi

pkg_install() {
  case "$os_id" in
    darwin)
      if ! have_cmd brew; then
        echo "Homebrew not found. Install it from https://brew.sh and re-run."
        return 1
      fi
      brew install "$@"
      ;;
    ubuntu|debian)
      $SUDO apt-get update -y
      $SUDO apt-get install -y "$@"
      ;;
    rhel|centos)
      if have_cmd dnf; then
        $SUDO dnf install -y "$@"
      else
        $SUDO yum install -y "$@"
      fi
      ;;
    fedora)
      $SUDO dnf install -y "$@"
      ;;
    opensuse*|sles)
      $SUDO zypper --non-interactive install "$@"
      ;;
    *)
      echo "Unknown distro. Skipping package-manager install for: $*"
      return 1
      ;;
  esac
}

detect_arch() {
  local uarch
  uarch=$(uname -m)
  case "$uarch" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    *) echo "$uarch" ;;
  esac
}

install_jq() {
  if have_cmd jq; then return 0; fi
  echo "Installing jq..."
  if pkg_install jq; then return 0; fi

  # Fallback to static binary
  local arch os url
  arch=$(detect_arch)
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  url="https://github.com/stedolan/jq/releases/download/jq-1.6/jq-${os}${arch:+-${arch}}"
  if curl -fsSL "$url" -o /tmp/jq; then
    chmod +x /tmp/jq
    $SUDO mv /tmp/jq /usr/local/bin/jq
  else
    echo "Failed to download jq binary from $url"
    return 1
  fi
}

install_kubectl() {
  if have_cmd kubectl; then return 0; fi
  echo "Installing kubectl..."
  local os arch ver url
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(detect_arch)
  ver=${KUBECTL_VERSION:-$(curl -fsSL https://dl.k8s.io/release/stable.txt)}
  url="https://dl.k8s.io/release/${ver}/bin/${os}/${arch}/kubectl"
  curl -fsSL "$url" -o /tmp/kubectl
  chmod +x /tmp/kubectl
  $SUDO mv /tmp/kubectl /usr/local/bin/kubectl
}

install_istioctl() {
  if have_cmd istioctl; then return 0; fi
  echo "Installing istioctl..."
  local tmpdir istio_dir
  tmpdir=$(mktemp -d)
  (cd "$tmpdir" && curl -fsSL https://istio.io/downloadIstio | ${ISTIO_VERSION:+ISTIO_VERSION=$ISTIO_VERSION} sh -)
  istio_dir=$(find "$tmpdir" -maxdepth 1 -type d -name "istio-*" | head -n1)
  if [ -z "$istio_dir" ] || [ ! -f "$istio_dir/bin/istioctl" ]; then
    echo "Failed to download istioctl"
    return 1
  fi
  $SUDO mv "$istio_dir/bin/istioctl" /usr/local/bin/istioctl
  rm -rf "$tmpdir"
}

install_velero() {
  if have_cmd velero; then return 0; fi
  echo "Installing velero..."
  local ver arch os url tmpdir tarball dirbin
  ver=${VELERO_VERSION:-latest}
  if [ "$ver" = "latest" ]; then
    ver=$(curl -fsSL https://api.github.com/repos/vmware-tanzu/velero/releases/latest | jq -r .tag_name || true)
    ver=${ver:-v1.13.2}
  fi
  arch=$(detect_arch)
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  url="https://github.com/vmware-tanzu/velero/releases/download/${ver}/velero-${ver}-${os}-${arch}.tar.gz"
  tmpdir=$(mktemp -d)
  tarball="$tmpdir/velero.tgz"
  curl -fsSL "$url" -o "$tarball"
  tar -C "$tmpdir" -xzf "$tarball"
  dirbin=$(find "$tmpdir" -maxdepth 2 -type f -name velero | head -n1)
  if [ -z "$dirbin" ]; then
    echo "Failed to extract velero from $url"
    return 1
  fi
  $SUDO mv "$dirbin" /usr/local/bin/velero
  chmod +x /usr/local/bin/velero
  rm -rf "$tmpdir"
}

main() {
  echo ">>> Installing required tools: ${REQUIRED[*]}"

  # Ensure curl, tar, jq available for installer logic
  if ! have_cmd curl; then
    echo "Installing curl (needed by this script)..."
    pkg_install curl || { echo "Please install 'curl' manually and re-run."; exit 1; }
  fi
  if ! have_cmd tar; then
    echo "Installing tar (needed by this script)..."
    pkg_install tar || { echo "Please install 'tar' manually and re-run."; exit 1; }
  fi

  # Install each tool if missing
  install_jq || true
  install_kubectl || true
  install_istioctl || true
  install_velero || true

  echo ">>> Verification:"
  for c in "${REQUIRED[@]}"; do
    if have_cmd "$c"; then
      printf "  - %s: %s\n" "$c" "$(command -v "$c")"
    else
      printf "  - %s: NOT INSTALLED\n" "$c"
    fi
  done

  echo ">>> Done. If any tools show as NOT INSTALLED, please install them manually."
}

main "$@"

