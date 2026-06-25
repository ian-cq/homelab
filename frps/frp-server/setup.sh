#!/usr/bin/env bash
set -euo pipefail

FRP_VERSION="${FRP_VERSION:-0.69.1}"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/frp"
SERVICE_USER="frp"

# Detect architecture
ARCH=$(uname -m)
case "${ARCH}" in
  x86_64)  ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  armv7l)  ARCH="arm" ;;
  *)
    echo "error: unsupported architecture: ${ARCH}"
    exit 1
    ;;
esac

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
TARBALL="frp_${FRP_VERSION}_${OS}_${ARCH}.tar.gz"
URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${TARBALL}"

echo "==> installing frps v${FRP_VERSION} (${OS}/${ARCH})"

# Download and extract
TMPDIR=$(mktemp -d)
trap 'rm -rf "${TMPDIR}"' EXIT

curl -fsSL "${URL}" -o "${TMPDIR}/${TARBALL}"
tar -xzf "${TMPDIR}/${TARBALL}" -C "${TMPDIR}"

# Install binary
sudo install -m 0755 "${TMPDIR}/frp_${FRP_VERSION}_${OS}_${ARCH}/frps" "${INSTALL_DIR}/frps"
echo "==> installed ${INSTALL_DIR}/frps"

# Create service user (no login shell, no home directory)
if ! id "${SERVICE_USER}" &>/dev/null; then
  sudo useradd -r -s /usr/sbin/nologin -M "${SERVICE_USER}"
  echo "==> created system user: ${SERVICE_USER}"
else
  echo "==> user ${SERVICE_USER} already exists"
fi

# Create config directory
sudo mkdir -p "${CONFIG_DIR}"
sudo chown "${SERVICE_USER}:${SERVICE_USER}" "${CONFIG_DIR}"
sudo chmod 750 "${CONFIG_DIR}"
echo "==> created ${CONFIG_DIR}"

# UFW firewall rules
if command -v ufw &>/dev/null; then
  echo "==> configuring ufw"
  sudo ufw allow 22/tcp comment "SSH"
  sudo ufw allow 80/tcp comment "nginx-redirect HTTP->HTTPS"
  sudo ufw allow 7000/tcp comment "FRP bind port"
  sudo ufw allow 2222/tcp comment "FRP TCP proxy (SSH)"
  sudo ufw --force enable
  echo "==> ufw rules applied"
else
  echo "==> ufw not found, skipping firewall setup"
fi

echo "==> setup complete"
echo "    next: make install"
