#!/usr/bin/env bash
# Disposable GitHub-hosted runner only. No production host, wallet or DNS required.
set -Eeuo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_OS:-} == Linux ]] || {
  echo 'This test runs only on a disposable Linux GitHub Actions runner.' >&2; exit 1;
}
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BASE="$RUNNER_TEMP/ario-smoke"
NODE="$BASE/node"
PROJECT="ario-smoke-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
mkdir -p "$BASE/artifacts"
[[ ! -e "$NODE" ]] || { echo 'Refusing to reuse an existing smoke directory.' >&2; exit 1; }

# The always() step runs this again if the main step times out. Every command is
# restricted to this run's Compose project and its disposable data mount.
printf '#!/usr/bin/env bash\nset -eu\n' > "$BASE/cleanup.sh"
printf 'if [ -f %q ]; then timeout 45s docker compose -p %q -f %q down --volumes --remove-orphans --timeout 10; fi\n' \
  "$BASE/runtime.json" "$PROJECT" "$BASE/runtime.json" >> "$BASE/cleanup.sh"
printf 'if mountpoint -q %q; then sudo umount %q; fi\n' "$NODE/data" "$NODE/data" >> "$BASE/cleanup.sh"
chmod 700 "$BASE/cleanup.sh"
cleanup() {
  local code=$?
  trap - EXIT TERM INT
  python3 "$REPO/tests/smoke_r85.py" collect "$BASE" "$PROJECT" "$code" || true
  bash "$BASE/cleanup.sh" || code=1
  exit "$code"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

python3 - "$BASE" <<'PY'
import shutil, sys
if shutil.disk_usage(sys.argv[1]).free < 8 * 1024**3:
    raise SystemExit('At least 8 GiB free disk is required before pulling images.')
PY
timeout 120s git clone --depth 1 --branch r85 https://github.com/ar-io/ar-io-node "$NODE"
test "$(git -C "$NODE" rev-parse HEAD)" = 6c7006d530355c8f07240e28bebac5c9f6c71b7d
mkdir -p "$NODE/data" "$NODE/wallets" "$NODE/secrets"
# An actual hard cap for all test database/cache/report writes. The cap is shared,
# not multiplied by the number of database bind mounts.
sudo mount -t tmpfs -o size=1G,nosuid,nodev tmpfs "$NODE/data"
python3 "$REPO/tests/smoke_r85.py" keys "$BASE"
read -r OPERATOR OBSERVER < "$BASE/addresses.txt"
env -i PATH="$PATH" HOME="$HOME" LANG=C.UTF-8 \
  INSTALL_DIR="$NODE" DOMAIN=smoke.invalid AR_IO_WALLET="$OPERATOR" OBSERVER_WALLET="$OBSERVER" \
  bash -c 'source "$1"; write_env; cd "$INSTALL_DIR"; validate_observer_config; docker compose config --format json > "$2"' \
  bash "$REPO/install-gateway.sh" "$BASE/production-config.json"
python3 "$REPO/tests/smoke_r85.py" prepare "$BASE" "$PROJECT"

# This generated Compose file contains only four services. Neither index-swarm,
# index-export, torrent engines, autoheal nor other optional services can start.
timeout 480s docker compose -p "$PROJECT" -f "$BASE/runtime.json" pull
python3 - "$BASE" <<'PY'
import shutil, sys
if shutil.disk_usage(sys.argv[1]).free < 2 * 1024**3:
    raise SystemExit('Insufficient free disk after image pull.')
PY
timeout 60s docker compose -p "$PROJECT" -f "$BASE/runtime.json" up -d --no-build --no-deps redis core observer envoy
python3 "$REPO/tests/smoke_r85.py" check "$BASE" "$PROJECT"
