#!/usr/bin/env bash
set -Eeuo pipefail

# Refresh helpers only; do not source .env, stop containers or reset Git.
[[ "$(id -u)" -eq 0 ]] || { echo "Run as root (sudo -i)." >&2; exit 1; }
export INSTALL_DIR="${INSTALL_DIR:-/opt/ar-io-node}"
if [[ ! -f "$INSTALL_DIR/.env" ]]; then
  echo "No .env in $INSTALL_DIR. For an older path, set INSTALL_DIR explicitly." >&2
  exit 1
fi
TMP_INSTALLER="$(mktemp)"
trap 'rm -f -- "$TMP_INSTALLER"' EXIT
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/Vevivo/ar-io-gateway-installer/main/install-gateway.sh \
  -o "$TMP_INSTALLER"
[[ -s "$TMP_INSTALLER" ]] || { echo "Installer download was empty." >&2; exit 1; }
bash -n "$TMP_INSTALLER"
bash "$TMP_INSTALLER" --refresh-helpers
