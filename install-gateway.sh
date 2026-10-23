#!/usr/bin/env bash
set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

INSTALL_DIR="${INSTALL_DIR:-/opt/ar-io-node}"
HELPER_BIN_DIR="${HELPER_BIN_DIR:-/usr/local/bin}"
ARIO_RELEASE="r85"
ARIO_COMMIT="6c7006d530355c8f07240e28bebac5c9f6c71b7d"
REPORT_DATA_SINK="turbo"
DOMAIN="${ARNS_ROOT_HOST:-${DOMAIN:-}}"
AR_IO_WALLET="${AR_IO_WALLET:-${ARIO_WALLET:-}}"
OBSERVER_WALLET="${OBSERVER_WALLET:-}"
GRAPHQL_HOST="${GRAPHQL_HOST:-turbo-gateway.com}"
GRAPHQL_PORT="${GRAPHQL_PORT:-443}"
START_HEIGHT="${START_HEIGHT:-1800000}"
SOLANA_RPC_URL="${SOLANA_RPC_URL:-https://api.mainnet-beta.solana.com}"
GATEWAY_TEST_TX="3lyxgbgEvqNSvJrTX2J7CfRychUD5KClFhhVLyTPNCQ"
ENABLE_EPOCH_CRANKING="false"

ARIO_CORE_PROGRAM_ID="73YoECm6NKXpVRoe5f1Q9BcP5DJGPFUjnFy6AxBE5Nvh"
ARIO_GAR_PROGRAM_ID="89fNiiwgpFSPHKuqfNUkgYTYjtAJAhyqHjXmgXeppGpf"
ARIO_ARNS_PROGRAM_ID="2yCUx5edFvUrkibYaUa2ZXWyx9kuJkS8CwyzsgHPWdZZ"
ARIO_ANT_PROGRAM_ID="2MWexMHfMhGJwMHv9Qm9YAVCqjUFUJwDJAysW4oCUGk5"

X402_ENABLED="false"
X402_NETWORK="base"
X402_WALLET_ADDRESS=""
X402_FACILITATOR_URL="https://facilitator.x402.rs"
X402_PER_BYTE_PRICE="0.0000000001"
X402_MIN_PRICE="0.001"
X402_MAX_PRICE="1.00"
X402_CAPACITY_MULTIPLIER="10"
X402_APP_NAME=""
X402_APP_LOGO=""
X402_CDP_CLIENT_KEY=""
CDP_API_KEY_ID=""
CDP_SECRET_VALUE=""
CHUNK_GET_BASE64_SIZE_BYTES="368640"
RATE_LIMITER_TYPE="redis"
RATE_LIMITER_REDIS_ENDPOINT="redis://redis:6379"
RATE_LIMITER_IP_BUCKET="100000"
RATE_LIMITER_IP_REFILL="20"
RATE_LIMITER_RESOURCE_BUCKET="1000000"
RATE_LIMITER_RESOURCE_REFILL="100"
RATE_LIMITER_IP_ALLOWLIST=""
RATE_LIMITER_ARNS_ALLOWLIST=""
EXTRA_REDIS_FLAGS="--save 300 10 --appendonly yes --appendfsync everysec"
ENABLE_DEBUG_LOGS="false"

log() { printf "%b\n" "${CYAN}==>${NC} $*"; }
ok() { printf "%b\n" "${GREEN}OK${NC} $*"; }
warn() { printf "%b\n" "${YELLOW}WARN${NC} $*" >&2; }
die() { printf "%b\n" "${RED}ERROR${NC} $*" >&2; exit 1; }

prompt() {
  local label="$1"
  local default="${2:-}"
  local value
  if [[ -n "$default" ]]; then
    printf "%s [%s]: " "$label" "$default" >&2
    read -r value
    printf "%s" "${value:-$default}"
  else
    printf "%s: " "$label" >&2
    read -r value
    printf "%s" "$value"
  fi
}

secret_prompt() {
  local value
  printf "%s: " "$1" >&2
  read -r -s value
  printf "\n" >&2
  printf "%s" "${value:-${2:-}}"
}

validate_install_dir() {
  [[ "$INSTALL_DIR" =~ ^/[a-zA-Z0-9_./-]+$ && "$INSTALL_DIR" != / && "$INSTALL_DIR" != *'/../'* ]] || die "Use an absolute installation path without spaces or shell characters."
}

validate_domain() {
  local label
  [[ ${#1} -le 253 && "$1" == *.* && "$1" != *..* ]] || die "Enter a DNS hostname, for example gateway.example.com."
  local -a labels
  IFS=. read -r -a labels <<< "$1"
  for label in "${labels[@]}"; do
    [[ ${#label} -le 63 && "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "Invalid DNS hostname."
  done
  [[ "$1" != *. ]] || die "Remove the trailing dot from the hostname."
}

validate_wallet_address() {
  [[ "$1" =~ ^[1-9A-HJ-NP-Za-km-z]{32,44}$ ]] || die "Enter a Solana public wallet address (base58)."
}

# Read a value as data; never source .env as shell code.
read_env_value() {
  python3 - "$INSTALL_DIR/.env" "$1" <<'PY'
import re, sys
value = ''
for line in open(sys.argv[1], encoding='utf-8'):
    match = re.match(r'^\s*(?:export\s+)?' + re.escape(sys.argv[2]) + r'\s*=(.*)$', line)
    if match:
        value = match[1].strip()
        quoted = re.match(r'''^(['"])((?:\\.|(?!\1).)*)\1\s*(?:#.*)?$''', value)
        if quoted:
            value = quoted[2].replace('\\' + quoted[1], quoted[1])
        else:
            value = re.split(r'\s+#', value, maxsplit=1)[0].rstrip()
print(value, end='')
PY
}

dotenv_literal() {
  local value="${1//\'/\\\'}"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "Use a single-line configuration value."
  printf "'%s'" "$value"
}

save_installer() {
  mkdir -p "$INSTALL_DIR/.installer"
  chmod 700 "$INSTALL_DIR/.installer"
  # Serialize functions, not /dev/fd: bash <(wget ...) is a non-seekable stream.
  # Only non-secret constants are stored. Runtime .env is read on each update.
  local saved
  saved="$(mktemp "$INSTALL_DIR/.installer/install.XXXXXX")"
  {
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
    declare -p RED GREEN YELLOW CYAN BOLD NC INSTALL_DIR HELPER_BIN_DIR ARIO_RELEASE ARIO_COMMIT GATEWAY_TEST_TX
    declare -f log ok warn die require_root validate_install_dir validate_domain read_env_value \
      save_installer refresh_helpers migrate_env upgrade_gateway validate_key_file \
      validate_observer_config convert_key_material clone_node write_helpers
    printf '\nrequire_root\nvalidate_install_dir\n'
    printf 'case "${1:---upgrade}" in\n  --upgrade) upgrade_gateway ;;\n  --refresh-helpers) refresh_helpers ;;\n  *) die "Use --upgrade or --refresh-helpers." ;;\nesac\n'
  } > "$saved"
  chmod 700 "$saved"
  mv "$saved" "$INSTALL_DIR/.installer/install-gateway.sh"
}

refresh_helpers() {
  [[ -f "$INSTALL_DIR/.env" ]] || die "No .env found in $INSTALL_DIR."
  DOMAIN="$(read_env_value ARNS_ROOT_HOST)"
  validate_domain "$DOMAIN"
  save_installer
  write_helpers
  ok "Helper commands refreshed. Gateway services and .env were not changed."
}

migrate_env() {
  log "Adding missing R85 settings; preserving existing configuration"
  python3 - "$INSTALL_DIR/.env" <<'PY'
import datetime, os, pathlib, re, shutil
import sys
path = pathlib.Path(sys.argv[1])
original = path.read_bytes().decode('utf-8')
values = {}
for line in original.splitlines():
    m = re.match(r'^\s*(?:export\s+)?([A-Z0-9_]+)\s*=(.*)$', line)
    if m:
        v = m[2].strip()
        quoted = re.match(r'''^(['"])((?:\\.|(?!\1).)*)\1\s*(?:#.*)?$''', v)
        if quoted:
            v = quoted[2].replace('\\' + quoted[1], quoted[1])
        else:
            v = re.split(r'\s+#', v, maxsplit=1)[0].rstrip()
        values[m[1]] = v
if (values.get('RUN_OBSERVER') or 'true').lower() != 'true':
    raise SystemExit('RUN_OBSERVER is disabled. Set it to true for this observer-required installer, then rerun.')
if (values.get('SUBMIT_CONTRACT_INTERACTIONS') or 'true').lower() != 'true':
    raise SystemExit('SUBMIT_CONTRACT_INTERACTIONS is disabled. Enable it deliberately before continuing.')
additions = {}
def add(key, value):
    if not values.get(key):
        additions[key] = value
add('RUN_OBSERVER', 'true')
add('SUBMIT_CONTRACT_INTERACTIONS', 'true')
add('REPORT_DATA_SINK', 'turbo')
for key in ('CORE_LOG_LEVEL', 'OBSERVER_LOG_LEVEL'):
    if values.get(key):
        continue
    level = values.get('LOG_LEVEL') or 'info'
    if level not in ('error', 'warn', 'info', 'http', 'verbose', 'debug', 'silly'):
        raise SystemExit('Review LOG_LEVEL before migrating to CORE_LOG_LEVEL/OBSERVER_LOG_LEVEL.')
    add(key, level)
if 'ARNS_CACHE_TTL_MS' in values and 'ARNS_CACHE_TTL_SECONDS' not in values:
    try:
        ttl = int(values['ARNS_CACHE_TTL_MS'])
        if ttl < 0 or ttl % 1000:
            raise ValueError()
    except ValueError:
        raise SystemExit('ARNS_CACHE_TTL_MS must be a non-negative whole number of seconds; review it first.')
    add('ARNS_CACHE_TTL_SECONDS', str(ttl // 1000))
upload_keys = ('SOLANA_UPLOAD_KEYPAIR_PATH','SOLANA_UPLOAD_PRIVATE_KEY','ARWEAVE_UPLOAD_KEY_FILE','ARWEAVE_UPLOAD_JWK','ETHEREUM_UPLOAD_PRIVATE_KEY_FILE','ETHEREUM_UPLOAD_PRIVATE_KEY')
if (values.get('REPORT_DATA_SINK') or 'turbo') == 'turbo' and not any(values.get(k) for k in upload_keys):
    if values.get('OBSERVER_KEYPAIR_PATH') and not values.get('OBSERVER_PRIVATE_KEY'):
        add('SOLANA_UPLOAD_KEYPAIR_PATH', '${OBSERVER_KEYPAIR_PATH}')
    elif values.get('OBSERVER_PRIVATE_KEY') and not values.get('OBSERVER_KEYPAIR_PATH'):
        add('SOLANA_UPLOAD_PRIVATE_KEY', '${OBSERVER_PRIVATE_KEY}')
if not additions:
    print('Required R85 settings already present.')
    raise SystemExit(0)
os.umask(0o077)
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
backup = path.with_name('.env.backup.' + stamp)
shutil.copyfile(path, backup)
backup.chmod(0o600)
tmp = path.with_name('.env.r85.' + stamp)
tmp.write_bytes((original + '\n# R85 compatibility additions\n' + ''.join(f'{k}={v}\n' for k,v in additions.items())).encode('utf-8'))
tmp.chmod(0o600)
os.replace(tmp, path)
print('Added: ' + ', '.join(additions) + '. Original .env backed up.')
PY
}

upgrade_gateway() {
  [[ -f "$INSTALL_DIR/.env" ]] || die "No installation found. Run without --upgrade for a new gateway."
  [[ ! -f "$INSTALL_DIR/.installer/setup-pending" ]] || die "Setup is incomplete. Rerun the original installation command to finish DNS/HTTPS setup."
  command -v python3 >/dev/null || die "Install python3 before updating."
  docker compose version >/dev/null
  clone_node
  migrate_env
  DOMAIN="$(read_env_value ARNS_ROOT_HOST)"
  validate_domain "$DOMAIN"
  validate_observer_config
  save_installer
  write_helpers
  docker compose config --quiet
  docker compose pull
  docker compose up -d
  docker compose ps
  ok "R85 applied. Existing .env values, keyfiles, databases and TLS configuration retained."
  echo "Run gateway-check. For an older nginx configuration, see the R85 header-buffer note in the README."
}

resume_gateway() {
  log "Finishing the interrupted installation with the existing .env"
  clone_node
  DOMAIN="$(read_env_value ARNS_ROOT_HOST)"
  AR_IO_WALLET="$(read_env_value AR_IO_WALLET)"
  OBSERVER_WALLET="$(read_env_value OBSERVER_WALLET)"
  validate_domain "$DOMAIN"
  validate_wallet_address "$AR_IO_WALLET"
  validate_wallet_address "$OBSERVER_WALLET"
  configure_wallet "main/operator" "$AR_IO_WALLET"
  if [[ "$OBSERVER_WALLET" != "$AR_IO_WALLET" ]]; then
    configure_wallet "observer" "$OBSERVER_WALLET"
  fi
  save_installer
  start_gateway
  configure_firewall_ssl_nginx
  write_helpers
  rm -f "$INSTALL_DIR/.installer/setup-pending"
  finish
}

validate_key_file() {
  [[ -f "$1" && ! -L "$1" ]] || die "Missing keyfile or unexpected symlink: $1"
  python3 - "$1" <<'PY' || die "Expected a 64-byte Solana JSON keypair. Import a seed/private key through the fresh installer first."
import json, sys
a = json.load(open(sys.argv[1], encoding='utf-8'))
if not isinstance(a, list) or len(a) != 64 or not all(type(n) is int and 0 <= n <= 255 for n in a):
    raise SystemExit(1)
PY
  convert_key_material - "$2" < "$1" >/dev/null || die "Keyfile does not match the configured public address: $1"
}

validate_observer_config() {
  local config values status=0
  config="$(mktemp)"
  values="$(mktemp)"
  chmod 600 "$config" "$values"
  docker compose config --format json > "$config" || status=$?
  if [[ "$status" -ne 0 ]]; then
    rm -f "$config" "$values"
    die "Compose configuration is invalid. Services were not started."
  fi
  # Read the effective configuration, including custom mounts; keep secrets off stdout.
  python3 - "$config" > "$values" <<'PY' || status=$?
import json, pathlib, sys
c = json.load(open(sys.argv[1], encoding='utf-8'))
o = c['services']['observer']; e = o['environment']
expected_images = {
    'core': 'ghcr.io/ar-io/ar-io-core:27b668f978a7a28009097d6df4f19fffe4e3af04',
    'envoy': 'ghcr.io/ar-io/ar-io-envoy:9a28d6538aca7fb88d96c862062b13a0ed0fce69',
    'observer': 'ghcr.io/ar-io/ar-io-observer:c5e98ddcf567598358fa73a0852b6be2cbbd42c4',
}
for name, expected in expected_images.items():
    if c['services'][name].get('image') != expected:
        raise SystemExit(name + ': image override is not the verified R85 image. Review the override first.')
for key in ('RUN_OBSERVER', 'SUBMIT_CONTRACT_INTERACTIONS'):
    if str(e.get(key, '')).lower() != 'true':
        raise SystemExit(key + ' must be true.')
if e.get('REPORT_DATA_SINK') != 'turbo':
    raise SystemExit('This installer validates Turbo/Solana report uploads. Existing non-Turbo settings were preserved; configure/verify that custom uploader before starting manually.')
if any(e.get(k) for k in ('ARWEAVE_UPLOAD_KEY_FILE', 'ARWEAVE_UPLOAD_JWK', 'ETHEREUM_UPLOAD_PRIVATE_KEY_FILE', 'ETHEREUM_UPLOAD_PRIVATE_KEY')):
    raise SystemExit('Existing alternate-chain upload credentials need a manual configuration review; no keys were replaced.')
def host_path(p):
    for v in sorted(o.get('volumes', []), key=lambda v: len(v.get('target', '')), reverse=True):
        target = v.get('target', '').rstrip('/')
        if target and (p == target or p.startswith(target + '/')):
            if v.get('type') != 'bind':
                raise SystemExit('Keypair is inside a volume that cannot be validated on the host.')
            base = pathlib.Path(v['source']).resolve()
            if p == target:
                return str(base)
            file = (base / p[len(target)+1:]).resolve()
            if not file.is_relative_to(base):
                break
            return str(file)
    raise SystemExit('Keypair path is not inside a configured bind mount.')
result = []
for role, address in (('SOLANA', 'AR_IO_WALLET'), ('OBSERVER', 'OBSERVER_WALLET'), ('SOLANA_UPLOAD', None)):
    file, inline = e.get(role + '_KEYPAIR_PATH', ''), e.get(role + '_PRIVATE_KEY', '')
    if bool(file) == bool(inline):
        raise SystemExit(role + ': configure exactly one keypair file or private key.')
    if inline:
        alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
        n = 0
        for ch in inline:
            if ch not in alphabet:
                raise SystemExit(role + ': inline key must be a base58 64-byte export.')
            n = n * 58 + alphabet.index(ch)
        length = (n.bit_length() + 7) // 8 + len(inline) - len(inline.lstrip('1'))
        if length != 64:
            raise SystemExit(role + ': inline key must be 64 bytes; import seeds using the installer.')
    public = c['services']['core']['environment'].get(address, '') if role == 'SOLANA' else e.get(address, '') if address else ''
    if address and not public:
        raise SystemExit(address + ' is required.')
    result += [host_path(file) if file else '', inline, public]
sys.stdout.write('\0'.join(result) + '\0')
PY
  if [[ "$status" -ne 0 ]]; then
    rm -f "$config" "$values"
    die "Observer configuration validation failed. Services were not started."
  fi
  local -a fields
  mapfile -d '' -t fields < "$values"
  rm -f "$config" "$values"
  local i
  for i in 0 3 6; do
    if [[ -n "${fields[i]}" ]]; then
      validate_key_file "${fields[i]}" "${fields[i+2]}"
    else
      printf '%s' "${fields[i+1]}" | convert_key_material - "${fields[i+2]}" >/dev/null || die "Invalid inline Solana key or public address mismatch."
    fi
  done
  unset fields
  ok "Operator, observer and report upload keys verified."
}

confirm() {
  local label="$1"
  local default="${2:-n}"
  local suffix="[y/N]"
  local value
  [[ "$default" == "y" ]] && suffix="[Y/n]"
  printf "%s %s: " "$label" "$suffix" >&2
  read -r value
  value="${value:-$default}"
  value="$(printf "%s" "$value" | tr '[:upper:]' '[:lower:]')"
  [[ "$value" == "y" || "$value" == "yes" || "$value" == "e" || "$value" == "evet" ]]
}

normalize_domain() {
  local raw="$1"
  raw="${raw#http://}"
  raw="${raw#https://}"
  raw="${raw%%/*}"
  raw="${raw%%:*}"
  printf "%s" "$raw" | tr '[:upper:]' '[:lower:]'
}

is_evm_address() {
  [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]
}

normalize_solana_rpc_url() {
  local value="$1"
  if [[ "$value" =~ ^[0-9a-fA-F-]{32,}$ ]]; then
    warn "That looks like a Helius API key, not a full RPC URL. Expanding it to the Helius mainnet endpoint."
    printf "https://mainnet.helius-rpc.com/?api-key=%s" "$value"
    return
  fi
  printf "%s" "$value"
}

validate_solana_rpc_url() {
  local value="$1"
  [[ "$value" != *[[:space:]\$\'\"\#]* ]] || die "RPC URL contains whitespace or unsupported dotenv characters. URL-encode those characters."
  [[ "$value" =~ ^https?:// ]] || die "Solana RPC URL must start with https:// or http://. Example: https://mainnet.helius-rpc.com/?api-key=YOUR_KEY"
  if [[ "$value" == *"api-mainnet.helius-rpc.com"* || "$value" == *"/v0/transactions"* || "$value" == *"/v0/addresses"* ]]; then
    die "This is a Helius Enhanced API URL, not a Solana RPC URL. Use the RPCs panel URL: https://mainnet.helius-rpc.com/?api-key=YOUR_KEY"
  fi
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Please run as root: sudo bash install-gateway.sh"
}

header() {
  clear || true
  cat <<'EOF'
░  ░░░░  ░░        ░░  ░░░░  ░░        ░░  ░░░░  ░░░      ░░
▒  ▒▒▒▒  ▒▒  ▒▒▒▒▒▒▒▒  ▒▒▒▒  ▒▒▒▒▒  ▒▒▒▒▒  ▒▒▒▒  ▒▒  ▒▒▒▒  ▒
▓▓  ▓▓  ▓▓▓      ▓▓▓▓▓  ▓▓  ▓▓▓▓▓▓  ▓▓▓▓▓▓  ▓▓  ▓▓▓  ▓▓▓▓  ▓
███    ████  ██████████    ███████  ███████    ████  ████  █
████  █████        █████  █████        █████  ██████      ██

      Welcome to the First Permanent Cloud Network
        --- AR.IO Gateway Installer by Vevivo ---

                Solana-era production setup
EOF
  echo
  echo "This installer sets up:"
  echo "  - official ar-io-node R85 (fixed release)"
  echo "  - Docker Compose services"
  echo "  - nginx reverse proxy"
  echo "  - wildcard SSL with Certbot DNS challenge"
  echo "  - Solana operator and observer keyfile placement"
  echo "  - optional x402 USDC data egress payments"
  echo "  - helper commands: gateway-check, logs, status, update"
  echo
  echo "It does NOT register or change your gateway on the platform."
  echo
}

collect_config() {
  log "[1/8] Configuration"

  DOMAIN="$(normalize_domain "$(prompt "Gateway domain" "$DOMAIN")")"
  validate_domain "$DOMAIN"

  AR_IO_WALLET="$(prompt "Main Solana gateway wallet address" "$AR_IO_WALLET")"
  validate_wallet_address "$AR_IO_WALLET"

  if [[ -z "$OBSERVER_WALLET" ]]; then
    OBSERVER_WALLET="$AR_IO_WALLET"
  fi
  OBSERVER_WALLET="$(prompt "Observer Solana wallet address, Enter = same as main wallet" "$OBSERVER_WALLET")"
  validate_wallet_address "$OBSERVER_WALLET"
  if [[ "$OBSERVER_WALLET" == "$AR_IO_WALLET" ]]; then
    echo "Observer wallet: same as main Solana gateway wallet."
  else
    echo "Observer wallet: ${OBSERVER_WALLET}"
  fi

  echo "GRAPHQL_HOST: ${GRAPHQL_HOST}"
  echo "START_HEIGHT: ${START_HEIGHT}"

  echo
  warn "Public Solana RPC is rate-limited. For reward reliability, use Helius, Triton, QuickNode, or another premium RPC if you have one."
  warn "For Helius, copy the RPC URL from the left RPCs panel: https://mainnet.helius-rpc.com/?api-key=..."
  warn "Do not use Enhanced Solana APIs URLs such as /v0/transactions."
  SOLANA_RPC_URL="$(secret_prompt "Solana RPC URL (hidden), Enter = keep configured/default RPC" "$SOLANA_RPC_URL")"
  SOLANA_RPC_URL="$(normalize_solana_rpc_url "$SOLANA_RPC_URL")"
  validate_solana_rpc_url "$SOLANA_RPC_URL"

  REPORT_DATA_SINK="turbo"
  echo "Observer reports use Turbo credits on the observer's Solana address."
  echo "Fund this address with SOL and Turbo credits; registration/staking follows setup."

  echo
  warn "The main/operator Solana keypair is required even when epoch cranking is off."
  warn "Epoch cranking is optional. If enabled, it spends a small amount of SOL from the main/operator wallet."
  if confirm "Enable optional epoch cranking with the main Solana wallet" "n"; then
    ENABLE_EPOCH_CRANKING="true"
  fi

  if confirm "Enable optional x402 USDC data egress payments" "n"; then
    X402_ENABLED="true"
    echo
    echo "x402 mainnet defaults will be used. You need an EVM/Base USDC receiver wallet."
    RATE_LIMITER_TYPE="$(prompt "Rate limiter type" "$RATE_LIMITER_TYPE")"
    [[ "$RATE_LIMITER_TYPE" == "redis" || "$RATE_LIMITER_TYPE" == "memory" ]] || die "Rate limiter type must be redis or memory."
    if [[ "$RATE_LIMITER_TYPE" == "redis" ]]; then
      RATE_LIMITER_REDIS_ENDPOINT="$(prompt "Redis endpoint" "$RATE_LIMITER_REDIS_ENDPOINT")"
      EXTRA_REDIS_FLAGS="$(prompt "Redis persistence flags" "$EXTRA_REDIS_FLAGS")"
    fi
    RATE_LIMITER_IP_BUCKET="$(prompt "RATE_LIMITER_IP_TOKENS_PER_BUCKET" "$RATE_LIMITER_IP_BUCKET")"
    RATE_LIMITER_IP_REFILL="$(prompt "RATE_LIMITER_IP_REFILL_PER_SEC" "$RATE_LIMITER_IP_REFILL")"
    RATE_LIMITER_RESOURCE_BUCKET="$(prompt "RATE_LIMITER_RESOURCE_TOKENS_PER_BUCKET" "$RATE_LIMITER_RESOURCE_BUCKET")"
    RATE_LIMITER_RESOURCE_REFILL="$(prompt "RATE_LIMITER_RESOURCE_REFILL_PER_SEC" "$RATE_LIMITER_RESOURCE_REFILL")"

    X402_NETWORK="$(prompt "x402 network: base for mainnet, base-sepolia for testnet" "$X402_NETWORK")"
    [[ "$X402_NETWORK" == "base" || "$X402_NETWORK" == "base-sepolia" ]] || die "x402 network must be base or base-sepolia."
    if [[ "$X402_NETWORK" == "base-sepolia" && "$X402_FACILITATOR_URL" == "https://facilitator.x402.rs" ]]; then
      X402_FACILITATOR_URL="https://x402.org/facilitator"
    fi
    X402_WALLET_ADDRESS="$(prompt "x402 EVM/Base USDC receiver wallet address" "$X402_WALLET_ADDRESS")"
    is_evm_address "$X402_WALLET_ADDRESS" || die "x402 requires a valid EVM/Base address like 0x..."
    X402_FACILITATOR_URL="$(prompt "x402 facilitator URL" "$X402_FACILITATOR_URL")"
    X402_PER_BYTE_PRICE="$(prompt "x402 per-byte price" "$X402_PER_BYTE_PRICE")"
    X402_MIN_PRICE="$(prompt "x402 min price" "$X402_MIN_PRICE")"
    X402_MAX_PRICE="$(prompt "x402 max price" "$X402_MAX_PRICE")"
    X402_CAPACITY_MULTIPLIER="$(prompt "x402 capacity multiplier" "$X402_CAPACITY_MULTIPLIER")"

    X402_APP_NAME="$(prompt "Paywall app name" "${DOMAIN:-My ar.io Gateway}")"
    X402_APP_LOGO="$(prompt "Paywall app logo URL, blank allowed" "")"
    CHUNK_GET_BASE64_SIZE_BYTES="$(prompt "CHUNK_GET_BASE64_SIZE_BYTES" "$CHUNK_GET_BASE64_SIZE_BYTES")"
    RATE_LIMITER_IP_ALLOWLIST="$(prompt "IP/CIDR allowlist, comma-separated, blank allowed" "")"
    RATE_LIMITER_ARNS_ALLOWLIST="$(prompt "ArNS allowlist, comma-separated, blank allowed" "")"

    if confirm "Enable core and observer debug logging" "n"; then
      ENABLE_DEBUG_LOGS="true"
    fi

    if confirm "Use optional Coinbase facilitator credentials (overrides the facilitator URL)" "n"; then
      CDP_API_KEY_ID="$(prompt "CDP_API_KEY_ID" "")"
      X402_CDP_CLIENT_KEY="$(prompt "Optional public paywall/onramp client key" "")"
      printf "Paste CDP API secret key (hidden, blank to skip): " >&2
      read -r -s CDP_SECRET_VALUE
      printf "\n" >&2
    fi
  fi
}

install_packages() {
  log "[2/8] Installing base packages"
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl openssh-server git certbot nginx sqlite3 build-essential \
    ca-certificates gnupg jq ufw lsb-release openssl dnsutils python3
  systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || true
}

install_docker() {
  log "[3/8] Installing Docker"
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker and Docker Compose are already installed."
    systemctl enable --now docker >/dev/null 2>&1 || true
    return
  fi

  install -m 0755 -d /etc/apt/keyrings
  . /etc/os-release
  local distro="${ID:-ubuntu}"
  local codename="${VERSION_CODENAME:-}"
  [[ -n "$codename" ]] || codename="$(lsb_release -cs)"
  curl -fsSL "https://download.docker.com/linux/${distro}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${distro} ${codename} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

clone_node() {
  log "[4/8] Installing official ar-io-node ${ARIO_RELEASE}"
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    cd "$INSTALL_DIR"
    local origin
    origin="$(git remote get-url origin)"
    [[ "$origin" == "https://github.com/ar-io/ar-io-node" || "$origin" == "https://github.com/ar-io/ar-io-node.git" ]] || die "This directory is not the official ar-io-node checkout."
    git diff --quiet && git diff --cached --quiet || die "Tracked files have local changes. Preserve/review them before updating; nothing was reset."
    git fetch origin "refs/tags/${ARIO_RELEASE}"
    [[ "$(git rev-parse 'FETCH_HEAD^{commit}')" == "$ARIO_COMMIT" ]] || die "R85 commit verification failed."
    git merge-base --is-ancestor HEAD "$ARIO_COMMIT" || die "This checkout is newer than R85 or diverged. Refusing to downgrade/reset it."
    git checkout --detach "$ARIO_COMMIT"
  else
    [[ ! -e "$INSTALL_DIR" ]] || die "Installation directory already exists without an official Git checkout."
    mkdir -p "$(dirname "$INSTALL_DIR")"
    git clone --branch "$ARIO_RELEASE" https://github.com/ar-io/ar-io-node "$INSTALL_DIR"
    cd "$INSTALL_DIR"
  fi
  [[ "$(git rev-parse HEAD)" == "$ARIO_COMMIT" ]] || die "Unexpected upstream commit; services were not started."
}

write_env() {
  log "[6/8] Writing .env"
  cd "$INSTALL_DIR"
  [[ ! -e .env ]] || die ".env already exists. Use --upgrade to preserve existing settings."
  local admin_key log_level="info"
  admin_key="$(openssl rand -hex 32)"
  [[ "$ENABLE_DEBUG_LOGS" == "true" ]] && log_level="debug"

  umask 077
  cat > .env <<EOF
# Generated by Vevivo ar.io gateway installer
NODE_ENV=production
CORE_LOG_LEVEL=${log_level}
OBSERVER_LOG_LEVEL=${log_level}
ADMIN_API_KEY=${admin_key}

GRAPHQL_HOST=${GRAPHQL_HOST}
GRAPHQL_PORT=${GRAPHQL_PORT}
START_HEIGHT=${START_HEIGHT}
START_WRITERS=true

RUN_OBSERVER=true
ARNS_ROOT_HOST=${DOMAIN}
AR_IO_WALLET=${AR_IO_WALLET}
OBSERVER_WALLET=${OBSERVER_WALLET}
SOLANA_RPC_URL=${SOLANA_RPC_URL}
SOLANA_KEYPAIR_PATH=/app/wallets/${AR_IO_WALLET}.json
OBSERVER_KEYPAIR_PATH=/app/wallets/${OBSERVER_WALLET}.json
SOLANA_UPLOAD_KEYPAIR_PATH=/app/wallets/${OBSERVER_WALLET}.json
REPORT_DATA_SINK=turbo
SUBMIT_CONTRACT_INTERACTIONS=true
ENABLE_EPOCH_CRANKING=${ENABLE_EPOCH_CRANKING}

ARIO_CORE_PROGRAM_ID=${ARIO_CORE_PROGRAM_ID}
ARIO_GAR_PROGRAM_ID=${ARIO_GAR_PROGRAM_ID}
ARIO_ARNS_PROGRAM_ID=${ARIO_ARNS_PROGRAM_ID}
ARIO_ANT_PROGRAM_ID=${ARIO_ANT_PROGRAM_ID}

SANDBOX_PROTOCOL=https
HTTPSIG_ENABLED=true
HTTPSIG_BIND_REQUEST=true

ARNS_RESOLVER_PRIORITY_ORDER=on-demand,gateway
ARNS_COMPOSITE_RESOLVER_TIMEOUT_MS=3000
ARNS_CACHE_TTL_SECONDS=3600
TRUSTED_GATEWAYS_REQUEST_TIMEOUT_MS=10000
GRAPHQL_ON_DEMAND_RESOLUTION_ENABLED=true
GRAPHQL_ON_DEMAND_RESOLUTION_TIMEOUT_MS=5000
GRAPHQL_ON_DEMAND_RESOLUTION_MAX_CONCURRENT=1
PEER_HEDGE_DELAY_MS=500
PEER_MAX_HEDGED_REQUESTS=2
BUNDLE_REPAIR_RETRY_INTERVAL_SECONDS=60
BUNDLE_REPAIR_RETRY_BATCH_SIZE=100
CACHE_NOT_FOUND_MAX_AGE=60
CACHE_APEX_MAX_AGE=3600
GRAPHQL_RESOLVER_DEADLINE_MS=12000
BUNDLE_DATA_ITEM_DRAIN_BATCH=100
DATA_ITEM_INDEXER_QUEUE_SIZE=500000
ANS104_DATA_INDEXER_QUEUE_SIZE=500000

RUN_AUTOHEAL=true
EOF

  if [[ "$X402_ENABLED" == "true" ]]; then
    mkdir -p secrets
    chmod 700 secrets
    if [[ -n "$CDP_SECRET_VALUE" ]]; then
      printf "%s" "$CDP_SECRET_VALUE" > secrets/cdp_secret_key
      chmod 600 secrets/cdp_secret_key
      unset CDP_SECRET_VALUE
    fi

    cat >> .env <<EOF

# x402 mainnet configuration. x402 requires the rate limiter.
ENABLE_RATE_LIMITER=true
RATE_LIMITER_TYPE=${RATE_LIMITER_TYPE}
RATE_LIMITER_IP_TOKENS_PER_BUCKET=${RATE_LIMITER_IP_BUCKET}
RATE_LIMITER_IP_REFILL_PER_SEC=${RATE_LIMITER_IP_REFILL}
RATE_LIMITER_RESOURCE_TOKENS_PER_BUCKET=${RATE_LIMITER_RESOURCE_BUCKET}
RATE_LIMITER_RESOURCE_REFILL_PER_SEC=${RATE_LIMITER_RESOURCE_REFILL}

ENABLE_X_402_USDC_DATA_EGRESS=true
X_402_USDC_NETWORK=${X402_NETWORK}
X_402_USDC_WALLET_ADDRESS=${X402_WALLET_ADDRESS}
X_402_USDC_FACILITATOR_URL=${X402_FACILITATOR_URL}
X_402_USDC_PER_BYTE_PRICE=${X402_PER_BYTE_PRICE}
X_402_USDC_DATA_EGRESS_MIN_PRICE=${X402_MIN_PRICE}
X_402_USDC_DATA_EGRESS_MAX_PRICE=${X402_MAX_PRICE}
X_402_RATE_LIMIT_CAPACITY_MULTIPLIER=${X402_CAPACITY_MULTIPLIER}
X_402_APP_NAME=$(dotenv_literal "$X402_APP_NAME")
X_402_APP_LOGO=$(dotenv_literal "$X402_APP_LOGO")
CHUNK_GET_BASE64_SIZE_BYTES=${CHUNK_GET_BASE64_SIZE_BYTES}
EOF

    if [[ "$RATE_LIMITER_TYPE" == "redis" ]]; then
      {
        printf "RATE_LIMITER_REDIS_ENDPOINT=%s\n" "$RATE_LIMITER_REDIS_ENDPOINT"
        printf "EXTRA_REDIS_FLAGS=%s\n" "$EXTRA_REDIS_FLAGS"
      } >> .env
    fi
    [[ -n "$RATE_LIMITER_IP_ALLOWLIST" ]] && printf "RATE_LIMITER_IPS_AND_CIDRS_ALLOWLIST=%s\n" "$RATE_LIMITER_IP_ALLOWLIST" >> .env
    [[ -n "$RATE_LIMITER_ARNS_ALLOWLIST" ]] && printf "RATE_LIMITER_ARNS_ALLOWLIST=%s\n" "$RATE_LIMITER_ARNS_ALLOWLIST" >> .env
    [[ -n "$CDP_API_KEY_ID" ]] && printf "CDP_API_KEY_ID=%s\n" "$CDP_API_KEY_ID" >> .env
    [[ -n "$X402_CDP_CLIENT_KEY" ]] && printf "X_402_CDP_CLIENT_KEY=%s\n" "$X402_CDP_CLIENT_KEY" >> .env
    [[ -f secrets/cdp_secret_key ]] && printf "CDP_API_KEY_SECRET_FILE=/app/secrets/cdp_secret_key\n" >> .env
  else
    cat >> .env <<EOF

ENABLE_RATE_LIMITER=false
ENABLE_X_402_USDC_DATA_EGRESS=false
EOF
  fi

  chmod 600 .env
  ok ".env written at ${INSTALL_DIR}/.env"
}

convert_key_material() {
  local target="$1"
  local expected_wallet="$2"
  local converter
  converter="$(mktemp)"

  cat > "$converter" <<'PY'
import hashlib
import hmac
import json
import os
import sys
import unicodedata

ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
P = 2**255 - 19
L = 2**252 + 27742317777372353535851937790883648493

def inv(x):
    return pow(x, P - 2, P)

D = (-121665 * inv(121666)) % P
I = pow(2, (P - 1) // 4, P)

def xrecover(y):
    xx = (y * y - 1) * inv(D * y * y + 1)
    x = pow(xx, (P + 3) // 8, P)
    if (x * x - xx) % P != 0:
        x = (x * I) % P
    if x % 2 != 0:
        x = P - x
    return x

BY = (4 * inv(5)) % P
BX = xrecover(BY)
B = (BX, BY)

def edwards_add(p1, p2):
    x1, y1 = p1
    x2, y2 = p2
    denom_x = inv(1 + D * x1 * x2 * y1 * y2)
    denom_y = inv(1 - D * x1 * x2 * y1 * y2)
    x3 = (x1 * y2 + x2 * y1) * denom_x
    y3 = (y1 * y2 + x1 * x2) * denom_y
    return (x3 % P, y3 % P)

def scalarmult(point, scalar):
    result = (0, 1)
    addend = point
    while scalar:
        if scalar & 1:
            result = edwards_add(result, addend)
        addend = edwards_add(addend, addend)
        scalar >>= 1
    return result

def encode_point(point):
    x, y = point
    value = y | ((x & 1) << 255)
    return value.to_bytes(32, "little")

def public_from_seed(seed):
    digest = hashlib.sha512(seed).digest()
    scalar = int.from_bytes(digest[:32], "little")
    scalar &= (1 << 254) - 8
    scalar |= (1 << 254)
    return encode_point(scalarmult(B, scalar))

def bip39_seed(mnemonic, passphrase=""):
    mnemonic = unicodedata.normalize("NFKD", mnemonic.strip())
    salt = "mnemonic" + unicodedata.normalize("NFKD", passphrase)
    return hashlib.pbkdf2_hmac(
        "sha512",
        mnemonic.encode("utf-8"),
        salt.encode("utf-8"),
        2048,
        dklen=64,
    )

def slip10_master(seed):
    digest = hmac.new(b"ed25519 seed", seed, hashlib.sha512).digest()
    return digest[:32], digest[32:]

def slip10_child(key, chain_code, index):
    hardened = index | 0x80000000
    data = b"\x00" + key + hardened.to_bytes(4, "big")
    digest = hmac.new(chain_code, data, hashlib.sha512).digest()
    return digest[:32], digest[32:]

def derive_path(seed, path):
    if not path.startswith("m/"):
        raise ValueError("path must start with m/")
    key, chain = slip10_master(seed)
    for part in path[2:].split("/"):
        if not part:
            continue
        if not part.endswith("'"):
            raise ValueError("only hardened ed25519 derivation path components are supported")
        index = int(part[:-1])
        key, chain = slip10_child(key, chain, index)
    return key

def b58decode(text):
    value = 0
    for char in text:
        value *= 58
        index = ALPHABET.find(char)
        if index == -1:
            raise ValueError("invalid base58 character")
        value += index
    raw = value.to_bytes((value.bit_length() + 7) // 8, "big") if value else b""
    pad = 0
    for char in text:
        if char == "1":
            pad += 1
        else:
            break
    return b"\0" * pad + raw

def b58encode(raw):
    value = int.from_bytes(raw, "big")
    output = ""
    while value:
        value, rem = divmod(value, 58)
        output = ALPHABET[rem] + output
    pad = 0
    for byte in raw:
        if byte == 0:
            pad += 1
        else:
            break
    return "1" * pad + (output or "")

def parse_material(text):
    stripped = text.strip()
    if not stripped:
        raise ValueError("empty key material")
    if stripped.startswith("["):
        arr = json.loads(stripped)
        if not isinstance(arr, list) or not all(type(x) is int for x in arr):
            raise ValueError("JSON keypair must be an array of numbers")
        raw = bytes(arr)
    elif len(stripped.split()) in (12, 15, 18, 21, 24):
        seed = bip39_seed(" ".join(stripped.split()))
        expected = os.environ.get("EXPECTED_WALLET", "")
        candidates = []
        for index in range(20):
            candidates.append((f"m/44'/501'/{index}'/0'", derive_path(seed, f"m/44'/501'/{index}'/0'")))
            candidates.append((f"m/44'/501'/{index}'", derive_path(seed, f"m/44'/501'/{index}'")))
            candidates.append((f"m/501'/{index}'/0'/0'", derive_path(seed, f"m/501'/{index}'/0'/0'")))
        if expected:
            for path, child_seed in candidates:
                secret = child_seed + public_from_seed(child_seed)
                if b58encode(secret[32:]) == expected:
                    print(f"matched mnemonic derivation path: {path}", file=sys.stderr)
                    return secret
            raise ValueError(
                "mnemonic did not derive the expected wallet address in the common Phantom paths. "
                "Export the private key for the exact Phantom account and use that instead."
            )
        child_seed = candidates[0][1]
        return child_seed + public_from_seed(child_seed)
    else:
        raw = b58decode("".join(stripped.split()))

    if len(raw) == 64:
        seed = raw[:32]
        pub = raw[32:]
        derived = public_from_seed(seed)
        if pub != derived:
            raise ValueError("64-byte secret key public half does not match derived public key")
        return raw
    if len(raw) == 32:
        return raw + public_from_seed(raw)
    raise ValueError(f"expected 32 or 64 bytes, got {len(raw)} bytes")

def main():
    target = sys.argv[1]
    expected_wallet = sys.argv[2]
    if expected_wallet:
        os.environ["EXPECTED_WALLET"] = expected_wallet
    material = sys.stdin.read()
    secret = parse_material(material)
    address = b58encode(secret[32:])
    if expected_wallet and address != expected_wallet:
        raise SystemExit(
            f"key belongs to {address}, but the configured wallet is {expected_wallet}"
        )
    if target == '-':
        print(address)
        return
    os.umask(0o077)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with open(target, "w", encoding="utf-8") as handle:
        json.dump(list(secret), handle)
        handle.write("\n")
    os.chmod(target, 0o600)
    print(f"saved Solana keypair JSON for {address}")

if __name__ == "__main__":
    main()
PY

  local status=0
  python3 "$converter" "$target" "$expected_wallet" || status=$?
  rm -f "$converter"
  return "$status"
}

try_convert_key_material() {
  local target="$1"
  local expected_wallet="$2"
  convert_key_material "$target" "$expected_wallet"
}

configure_wallet() {
  local role_label="$1"
  local wallet_address="$2"
  log "[5/8] ${role_label} Solana keyfile"
  cd "$INSTALL_DIR"
  mkdir -p wallets
  chmod 700 wallets
  local target="wallets/${wallet_address}.json"

  if [[ -f "$target" ]]; then
    validate_key_file "${INSTALL_DIR}/${target}" "$wallet_address"
    chmod 600 "$target"
    ok "Existing keyfile verified: ${INSTALL_DIR}/${target}"
    return
  fi

  echo "The ${role_label} expects a Solana keypair JSON file here:"
  echo "  ${INSTALL_DIR}/${target}"
  echo
  echo "Paste or enter ONE key material value. The installer detects the format automatically:"
  echo "  - existing JSON file path on this server, like /root/id.json"
  echo "  - Solana keypair JSON array, like [192,15,...,17]"
  echo "  - Phantom/Solana seed phrase words"
  echo "  - exported Solana private key/base58"
  echo
  echo "Key material input is hidden. It is never written to the command history."
  echo "The derived public address must match: ${wallet_address}"
  echo "Use this only on your own secure terminal."
  echo

  while true; do
    local key_material
    key_material="$(secret_prompt "Key material or JSON file path for ${wallet_address}" "")"

    if [[ "${key_material,,}" == "skip" ]]; then
      die "Observer setup requires valid keys. Installation stopped before services start."
    fi

    if [[ -n "$key_material" ]]; then
      if [[ -f "$key_material" ]]; then
        if try_convert_key_material "${INSTALL_DIR}/${target}" "$wallet_address" < "$key_material"; then
          ok "Keyfile installed: ${INSTALL_DIR}/${target}"
          return
        fi
        warn "That file did not contain key material for ${wallet_address}, or it was not valid."
      else
        if printf "%s" "$key_material" | try_convert_key_material "${INSTALL_DIR}/${target}" "$wallet_address"; then
          ok "Keyfile installed: ${INSTALL_DIR}/${target}"
          return
        fi
        if [[ "$key_material" == /* || "$key_material" == ./* || "$key_material" == *.json ]]; then
          warn "Keypair file not found or invalid: ${key_material}"
        else
          warn "That key material did not derive ${wallet_address}, or it was not valid."
        fi
      fi

      confirm "Try the ${role_label} keyfile step again" "y" && continue
      die "No valid keyfile; services were not started."
    fi

    warn "Please paste a single-line export, or enter the path to a JSON file."

  done
}

start_gateway() {
  log "[7/8] Starting gateway"
  cd "$INSTALL_DIR"
  validate_observer_config
  docker compose config --quiet
  docker compose pull
  docker compose up -d
}

configure_firewall_ssl_nginx() {
  log "[8/8] Firewall, SSL, nginx"
  ufw allow OpenSSH >/dev/null || true
  ufw allow 80/tcp >/dev/null || true
  ufw allow 443/tcp >/dev/null || true
  ufw --force enable >/dev/null || true

  echo
  echo "Certbot will ask you to create DNS TXT records for:"
  echo "  _acme-challenge.${DOMAIN}"
  echo "Add the value at your DNS provider, wait for it to propagate, then press Enter in Certbot."
  echo

  if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    ok "Existing Let's Encrypt certificate found for ${DOMAIN}."
  else
    certbot certonly \
      --manual \
      --preferred-challenges dns \
      --agree-tos \
      --register-unsafely-without-email \
      -d "${DOMAIN}" \
      -d "*.${DOMAIN}"
  fi

  cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} *.${DOMAIN};

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${DOMAIN} *.${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    client_max_body_size 250m;
    # R85 signed/tagged responses can exceed nginx's default header buffer.
    proxy_buffer_size 32k;
    proxy_buffers 8 32k;
    proxy_busy_buffers_size 64k;
    proxy_connect_timeout 75s;
    proxy_send_timeout 300s;
    proxy_read_timeout 300s;

    location / {
        proxy_pass http://localhost:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header X-AR-IO-Origin \$http_x_ar_io_origin;
        proxy_set_header X-AR-IO-Origin-Node-Release \$http_x_ar_io_origin_node_release;
        proxy_set_header X-AR-IO-Hops \$http_x_ar_io_hops;
    }
}
EOF

  nginx -t
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl reload-or-restart nginx
  ok "nginx configured for https://${DOMAIN}"
}

write_helpers() {
  log "Creating helper commands"

  mkdir -p "$HELPER_BIN_DIR"
  mkdir -p "$INSTALL_DIR/.installer"
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    declare -p INSTALL_DIR
    declare -f read_env_value
    printf 'read_env_value "$1"\n'
  } > "$INSTALL_DIR/.installer/read-env.sh"
  chmod 700 "$INSTALL_DIR/.installer/read-env.sh"
  cat > ${HELPER_BIN_DIR}/gateway-update <<EOF
#!/usr/bin/env bash
set -euo pipefail
export INSTALL_DIR="${INSTALL_DIR}"
exec bash "${INSTALL_DIR}/.installer/install-gateway.sh" --upgrade
EOF

  cat > ${HELPER_BIN_DIR}/gateway-restart <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd ${INSTALL_DIR}
docker compose up -d --force-recreate
docker compose ps
EOF

  cat > ${HELPER_BIN_DIR}/gateway-logs <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd ${INSTALL_DIR}
docker compose logs -f --tail=120 core observer envoy
EOF

  cat > ${HELPER_BIN_DIR}/gateway-status <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd ${INSTALL_DIR}
echo "=== Docker services ==="
docker compose ps
echo
echo "=== Resources ==="
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}"
echo
echo "=== Disk ==="
df -h ${INSTALL_DIR}
EOF

  cat > ${HELPER_BIN_DIR}/gateway-check <<EOF
#!/usr/bin/env bash
set -euo pipefail
DOMAIN="${DOMAIN}"
TX="${GATEWAY_TEST_TX}"
failures=0
TMP="\$(mktemp -d)"
trap 'rm -rf -- "\$TMP"' EXIT

echo "=== Public core health ==="
if curl -fsS --connect-timeout 10 --max-time 30 "https://\${DOMAIN}/ar-io/healthcheck" -o "\$TMP/core.json" && jq -e '.status == "ok"' "\$TMP/core.json" >/dev/null; then
  echo "Core health: OK"
else
  echo "Core health: FAILED or not ready"
  failures=1
fi

echo "=== Public observer health ==="
if curl -fsS --connect-timeout 10 --max-time 30 "https://\${DOMAIN}/ar-io/observer/healthcheck" -o "\$TMP/observer.json" && jq -e '(.uptime | type == "number") and (.uptime >= 0) and (.date | type == "string")' "\$TMP/observer.json" >/dev/null; then
  echo "Observer health: OK (report submission is checked separately)"
else
  echo "Observer health: FAILED or not ready"
  failures=1
fi

echo "=== 1984 content test ==="
HTTP="\$(curl -sS --connect-timeout 10 --max-time 45 --max-filesize 1048576 -o "\$TMP/content" -w '%{http_code}' "https://\${DOMAIN}/\${TX}" || true)"
if [[ "\$HTTP" == 200 && "\$(cat "\$TMP/content" 2>/dev/null)" == 1984 ]]; then
  echo "Content: OK"
else
  echo "Content: FAILED or not ready (HTTP \$HTTP)"
  failures=1
fi

echo "=== Gateway identity ==="
if ! curl -fsS --connect-timeout 10 --max-time 30 "https://\${DOMAIN}/ar-io/info" | jq -e '{release,wallet,programIds}'; then
  failures=1
fi

echo "=== Current observer report ==="
HTTP="\$(curl -sS --connect-timeout 10 --max-time 30 --max-filesize 10485760 -o "\$TMP/report" -w '%{http_code}' "https://\${DOMAIN}/ar-io/observer/reports/current" || true)"
if [[ "\$HTTP" == 202 ]]; then
  echo "Report pending. Check registration, balances and prescribed observation cycles; this is not proof of reward eligibility."
elif [[ "\$HTTP" == 200 ]] && jq -e 'type == "object" and (.message? != "Report pending")' "\$TMP/report" >/dev/null; then
  echo "Current report available. Verify submission/performance in the gateway portal."
else
  echo "Report endpoint: FAILED (HTTP \$HTTP). Run gateway-observer-check."
  failures=1
fi
cd "${INSTALL_DIR}"
docker compose ps
exit "\$failures"
EOF

  cat > ${HELPER_BIN_DIR}/gateway-x402-check <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd ${INSTALL_DIR}
get_env() {
  local key="\$1"
  bash "${INSTALL_DIR}/.installer/read-env.sh" "\$key"
}
echo "=== x402 / rate limiter env ==="
docker compose exec core env | grep -E "^(ENABLE_RATE_LIMITER|RATE_LIMITER|ENABLE_X_402|X_402)" | sort || true
echo
echo "=== x402 / rate limiter metrics ==="
curl -fsS http://localhost:3000/ar-io/__gateway_metrics | grep -Ei "rate_limit|token|x402|payment" || true
echo
echo "=== facilitator connectivity ==="
FACILITATOR_URL="\$(get_env X_402_USDC_FACILITATOR_URL)"
FACILITATOR_URL="\${FACILITATOR_URL:-https://facilitator.x402.rs}"
curl -I --max-time 20 "\${FACILITATOR_URL}" || true
echo
echo "=== payment logs ==="
docker compose logs core --tail=300 | grep -Ei "x402|payment|rate limit" || true
EOF

  cat > ${HELPER_BIN_DIR}/gateway-enable-x402 <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd ${INSTALL_DIR}

prompt() {
  local label="\$1"
  local default="\${2:-}"
  local value
  if [[ -n "\$default" ]]; then
    read -r -p "\${label} [\${default}]: " value
    printf "%s" "\${value:-\$default}"
  else
    read -r -p "\${label}: " value
    printf "%s" "\$value"
  fi
}

confirm() {
  local label="\$1"
  local default="\${2:-n}"
  local suffix="[y/N]"
  local value
  [[ "\$default" == "y" ]] && suffix="[Y/n]"
  read -r -p "\${label} \${suffix}: " value
  value="\${value:-\$default}"
  [[ "\$value" =~ ^[Yy]$ ]]
}

get_env() {
  local key="\$1"
  bash "${INSTALL_DIR}/.installer/read-env.sh" "\$key"
}

is_evm_address() {
  [[ "\$1" =~ ^0x[0-9a-fA-F]{40}$ ]]
}

[[ -f .env ]] || { echo ".env not found in ${INSTALL_DIR}"; exit 1; }

echo "x402 post-install setup"
echo "This only configures x402/rate limiter values. It does not reinstall your gateway."
echo

RATE_LIMITER_TYPE="\$(prompt "Rate limiter type" "\$(get_env RATE_LIMITER_TYPE)")"
RATE_LIMITER_TYPE="\${RATE_LIMITER_TYPE:-redis}"
if [[ "\$RATE_LIMITER_TYPE" != "redis" && "\$RATE_LIMITER_TYPE" != "memory" ]]; then
  echo "Rate limiter type must be redis or memory."
  exit 1
fi

RATE_LIMITER_REDIS_ENDPOINT="\$(prompt "Redis endpoint" "\$(get_env RATE_LIMITER_REDIS_ENDPOINT)")"
RATE_LIMITER_REDIS_ENDPOINT="\${RATE_LIMITER_REDIS_ENDPOINT:-redis://redis:6379}"
EXTRA_REDIS_FLAGS="\$(prompt "Redis persistence flags" "\$(get_env EXTRA_REDIS_FLAGS)")"
EXTRA_REDIS_FLAGS="\${EXTRA_REDIS_FLAGS:---save 300 10 --appendonly yes --appendfsync everysec}"

RATE_LIMITER_IP_BUCKET="\$(prompt "RATE_LIMITER_IP_TOKENS_PER_BUCKET" "\$(get_env RATE_LIMITER_IP_TOKENS_PER_BUCKET)")"
RATE_LIMITER_IP_BUCKET="\${RATE_LIMITER_IP_BUCKET:-100000}"
RATE_LIMITER_IP_REFILL="\$(prompt "RATE_LIMITER_IP_REFILL_PER_SEC" "\$(get_env RATE_LIMITER_IP_REFILL_PER_SEC)")"
RATE_LIMITER_IP_REFILL="\${RATE_LIMITER_IP_REFILL:-20}"
RATE_LIMITER_RESOURCE_BUCKET="\$(prompt "RATE_LIMITER_RESOURCE_TOKENS_PER_BUCKET" "\$(get_env RATE_LIMITER_RESOURCE_TOKENS_PER_BUCKET)")"
RATE_LIMITER_RESOURCE_BUCKET="\${RATE_LIMITER_RESOURCE_BUCKET:-1000000}"
RATE_LIMITER_RESOURCE_REFILL="\$(prompt "RATE_LIMITER_RESOURCE_REFILL_PER_SEC" "\$(get_env RATE_LIMITER_RESOURCE_REFILL_PER_SEC)")"
RATE_LIMITER_RESOURCE_REFILL="\${RATE_LIMITER_RESOURCE_REFILL:-100}"

X402_NETWORK="\$(prompt "x402 network: base for mainnet, base-sepolia for testnet" "\$(get_env X_402_USDC_NETWORK)")"
X402_NETWORK="\${X402_NETWORK:-base}"
if [[ "\$X402_NETWORK" != "base" && "\$X402_NETWORK" != "base-sepolia" ]]; then
  echo "x402 network must be base or base-sepolia."
  exit 1
fi

X402_FACILITATOR_DEFAULT="https://facilitator.x402.rs"
[[ "\$X402_NETWORK" == "base-sepolia" ]] && X402_FACILITATOR_DEFAULT="https://x402.org/facilitator"

while true; do
  X402_WALLET_ADDRESS="\$(prompt "x402 EVM/Base USDC receiver wallet address" "\$(get_env X_402_USDC_WALLET_ADDRESS)")"
  if is_evm_address "\$X402_WALLET_ADDRESS"; then
    break
  fi
  echo "Please enter a valid EVM/Base wallet address like 0x..."
done

X402_FACILITATOR_URL="\$(prompt "x402 facilitator URL" "\$(get_env X_402_USDC_FACILITATOR_URL)")"
X402_FACILITATOR_URL="\${X402_FACILITATOR_URL:-\$X402_FACILITATOR_DEFAULT}"
X402_PER_BYTE_PRICE="\$(prompt "x402 per-byte price" "\$(get_env X_402_USDC_PER_BYTE_PRICE)")"
X402_PER_BYTE_PRICE="\${X402_PER_BYTE_PRICE:-0.0000000001}"
X402_MIN_PRICE="\$(prompt "x402 min price" "\$(get_env X_402_USDC_DATA_EGRESS_MIN_PRICE)")"
X402_MIN_PRICE="\${X402_MIN_PRICE:-0.001}"
X402_MAX_PRICE="\$(prompt "x402 max price" "\$(get_env X_402_USDC_DATA_EGRESS_MAX_PRICE)")"
X402_MAX_PRICE="\${X402_MAX_PRICE:-1.00}"
X402_CAPACITY_MULTIPLIER="\$(prompt "x402 capacity multiplier" "\$(get_env X_402_RATE_LIMIT_CAPACITY_MULTIPLIER)")"
X402_CAPACITY_MULTIPLIER="\${X402_CAPACITY_MULTIPLIER:-10}"

ARNS_ROOT_HOST="\$(get_env ARNS_ROOT_HOST)"
X402_APP_NAME="\$(prompt "Paywall app name" "\$(get_env X_402_APP_NAME)")"
X402_APP_NAME="\${X402_APP_NAME:-\${ARNS_ROOT_HOST:-My ar.io Gateway}}"
X402_APP_LOGO="\$(prompt "Paywall app logo URL, blank allowed" "\$(get_env X_402_APP_LOGO)")"
CHUNK_GET_BASE64_SIZE_BYTES="\$(prompt "CHUNK_GET_BASE64_SIZE_BYTES" "\$(get_env CHUNK_GET_BASE64_SIZE_BYTES)")"
CHUNK_GET_BASE64_SIZE_BYTES="\${CHUNK_GET_BASE64_SIZE_BYTES:-368640}"
RATE_LIMITER_IP_ALLOWLIST="\$(prompt "IP/CIDR allowlist, comma-separated, blank allowed" "\$(get_env RATE_LIMITER_IPS_AND_CIDRS_ALLOWLIST)")"
RATE_LIMITER_ARNS_ALLOWLIST="\$(prompt "ArNS allowlist, comma-separated, blank allowed" "\$(get_env RATE_LIMITER_ARNS_ALLOWLIST)")"

EXISTING_CDP_API_KEY_ID="\$(get_env CDP_API_KEY_ID)"
EXISTING_X402_CDP_CLIENT_KEY="\$(get_env X_402_CDP_CLIENT_KEY)"
EXISTING_CDP_SECRET_FILE="\$(get_env CDP_API_KEY_SECRET_FILE)"
CDP_API_KEY_ID="\$EXISTING_CDP_API_KEY_ID"
X402_CDP_CLIENT_KEY="\$EXISTING_X402_CDP_CLIENT_KEY"
CDP_SECRET_VALUE=""

if confirm "Use optional Coinbase facilitator credentials (overrides the facilitator URL)" "n"; then
  CDP_API_KEY_ID="\$(prompt "CDP_API_KEY_ID" "\$EXISTING_CDP_API_KEY_ID")"
  X402_CDP_CLIENT_KEY="\$(prompt "Optional public paywall/onramp client key" "\$EXISTING_X402_CDP_CLIENT_KEY")"
  printf "Paste CDP API secret key (hidden, blank to keep existing/skip): " >&2
  read -r -s CDP_SECRET_VALUE
  printf "\\n" >&2
fi

cp .env ".env.backup.\$(date +%Y%m%d-%H%M%S)"
TMP_ENV="\$(mktemp)"
grep -Ev '^(ENABLE_RATE_LIMITER|RATE_LIMITER_TYPE|RATE_LIMITER_REDIS_ENDPOINT|RATE_LIMITER_IP_TOKENS_PER_BUCKET|RATE_LIMITER_IP_REFILL_PER_SEC|RATE_LIMITER_RESOURCE_TOKENS_PER_BUCKET|RATE_LIMITER_RESOURCE_REFILL_PER_SEC|EXTRA_REDIS_FLAGS|ENABLE_X_402_USDC_DATA_EGRESS|X_402_USDC_NETWORK|X_402_USDC_WALLET_ADDRESS|X_402_USDC_FACILITATOR_URL|X_402_USDC_PER_BYTE_PRICE|X_402_USDC_DATA_EGRESS_MIN_PRICE|X_402_USDC_DATA_EGRESS_MAX_PRICE|X_402_RATE_LIMIT_CAPACITY_MULTIPLIER|X_402_APP_NAME|X_402_APP_LOGO|CHUNK_GET_BASE64_SIZE_BYTES|RATE_LIMITER_IPS_AND_CIDRS_ALLOWLIST|RATE_LIMITER_ARNS_ALLOWLIST|CDP_API_KEY_ID|CDP_API_KEY_SECRET_FILE|X_402_CDP_CLIENT_KEY)=' .env > "\$TMP_ENV" || true

cat >> "\$TMP_ENV" <<X402ENV

# x402 configuration added by gateway-enable-x402
ENABLE_RATE_LIMITER=true
RATE_LIMITER_TYPE=\${RATE_LIMITER_TYPE}
RATE_LIMITER_IP_TOKENS_PER_BUCKET=\${RATE_LIMITER_IP_BUCKET}
RATE_LIMITER_IP_REFILL_PER_SEC=\${RATE_LIMITER_IP_REFILL}
RATE_LIMITER_RESOURCE_TOKENS_PER_BUCKET=\${RATE_LIMITER_RESOURCE_BUCKET}
RATE_LIMITER_RESOURCE_REFILL_PER_SEC=\${RATE_LIMITER_RESOURCE_REFILL}
ENABLE_X_402_USDC_DATA_EGRESS=true
X_402_USDC_NETWORK=\${X402_NETWORK}
X_402_USDC_WALLET_ADDRESS=\${X402_WALLET_ADDRESS}
X_402_USDC_FACILITATOR_URL=\${X402_FACILITATOR_URL}
X_402_USDC_PER_BYTE_PRICE=\${X402_PER_BYTE_PRICE}
X_402_USDC_DATA_EGRESS_MIN_PRICE=\${X402_MIN_PRICE}
X_402_USDC_DATA_EGRESS_MAX_PRICE=\${X402_MAX_PRICE}
X_402_RATE_LIMIT_CAPACITY_MULTIPLIER=\${X402_CAPACITY_MULTIPLIER}
X_402_APP_NAME=\${X402_APP_NAME}
X_402_APP_LOGO=\${X402_APP_LOGO}
CHUNK_GET_BASE64_SIZE_BYTES=\${CHUNK_GET_BASE64_SIZE_BYTES}
X402ENV

if [[ "\$RATE_LIMITER_TYPE" == "redis" ]]; then
  {
    printf "RATE_LIMITER_REDIS_ENDPOINT=%s\\n" "\$RATE_LIMITER_REDIS_ENDPOINT"
    printf "EXTRA_REDIS_FLAGS=%s\\n" "\$EXTRA_REDIS_FLAGS"
  } >> "\$TMP_ENV"
fi
[[ -n "\$RATE_LIMITER_IP_ALLOWLIST" ]] && printf "RATE_LIMITER_IPS_AND_CIDRS_ALLOWLIST=%s\\n" "\$RATE_LIMITER_IP_ALLOWLIST" >> "\$TMP_ENV"
[[ -n "\$RATE_LIMITER_ARNS_ALLOWLIST" ]] && printf "RATE_LIMITER_ARNS_ALLOWLIST=%s\\n" "\$RATE_LIMITER_ARNS_ALLOWLIST" >> "\$TMP_ENV"
[[ -n "\$CDP_API_KEY_ID" ]] && printf "CDP_API_KEY_ID=%s\\n" "\$CDP_API_KEY_ID" >> "\$TMP_ENV"
[[ -n "\$X402_CDP_CLIENT_KEY" ]] && printf "X_402_CDP_CLIENT_KEY=%s\\n" "\$X402_CDP_CLIENT_KEY" >> "\$TMP_ENV"

if [[ -n "\$CDP_SECRET_VALUE" ]]; then
  mkdir -p secrets
  chmod 700 secrets
  printf "%s" "\$CDP_SECRET_VALUE" > secrets/cdp_secret_key
  chmod 600 secrets/cdp_secret_key
  printf "CDP_API_KEY_SECRET_FILE=/app/secrets/cdp_secret_key\\n" >> "\$TMP_ENV"
elif [[ -n "\$EXISTING_CDP_SECRET_FILE" ]]; then
  printf "CDP_API_KEY_SECRET_FILE=%s\\n" "\$EXISTING_CDP_SECRET_FILE" >> "\$TMP_ENV"
elif [[ -f secrets/cdp_secret_key ]]; then
  printf "CDP_API_KEY_SECRET_FILE=/app/secrets/cdp_secret_key\\n" >> "\$TMP_ENV"
fi
unset CDP_SECRET_VALUE

mv "\$TMP_ENV" .env
chmod 600 .env

echo
echo "x402 env written. Restarting gateway services..."
if [[ "\$RATE_LIMITER_TYPE" == "redis" ]]; then
  docker compose up -d --force-recreate redis core envoy
else
  docker compose up -d --force-recreate core envoy
fi

echo
gateway-x402-check || true
EOF

  cat > ${HELPER_BIN_DIR}/gateway-balance <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd ${INSTALL_DIR}
get_env() {
  local key="\$1"
  bash "${INSTALL_DIR}/.installer/read-env.sh" "\$key"
}

DEFAULT_WALLET="\$(get_env OBSERVER_WALLET)"
WALLET="\${1:-\${DEFAULT_WALLET}}"
RPC="\$(get_env SOLANA_RPC_URL)"
RPC="\${RPC:-https://api.mainnet-beta.solana.com}"
[[ "\${WALLET}" =~ ^[1-9A-HJ-NP-Za-km-z]{32,44}$ ]] || { echo "A valid Solana public wallet address is required." >&2; exit 1; }

echo "=== Solana balance ==="
echo "wallet: \${WALLET}"
echo "rpc: configured (URL hidden)"

if [[ "\${RPC}" == *"api-mainnet.helius-rpc.com"* || "\${RPC}" == *"/v0/transactions"* || "\${RPC}" == *"/v0/addresses"* ]]; then
  echo "Wrong Helius URL: this is an Enhanced API endpoint, not a Solana JSON-RPC endpoint."
  echo "Use the Helius RPCs panel URL instead: https://mainnet.helius-rpc.com/?api-key=YOUR_KEY"
  exit 1
fi

if command -v solana >/dev/null 2>&1; then
  solana balance "\${WALLET}" --url "\${RPC}"
  exit 0
fi

curl -fsS --connect-timeout 10 --max-time 30 "\${RPC}" \\
  -H "content-type: application/json" \\
  -d "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":1,\\"method\\":\\"getBalance\\",\\"params\\":[\\"\${WALLET}\\"]}" \\
  | jq -er '
      if type != "object" then
        error("balance lookup failed: RPC did not return a Solana JSON-RPC object. Check SOLANA_RPC_URL.")
      elif (.error != null) then
        error("balance lookup failed: " + (.error.message // "RPC error" | tostring))
      elif (.result.value? | type == "number") and (.result.value >= 0) then
        "balance: " + ((.result.value / 1000000000) | tostring) + " SOL"
      else
        error("balance lookup failed: unknown RPC response. Check SOLANA_RPC_URL.")
      end
    '
EOF

  cat > ${HELPER_BIN_DIR}/gateway-observer-check <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd ${INSTALL_DIR}
get_env() {
  local key="\$1"
  bash "${INSTALL_DIR}/.installer/read-env.sh" "\$key"
}

echo "=== observer env ==="
grep -E '^(ENABLE_EPOCH_CRANKING|SOLANA_KEYPAIR_PATH|OBSERVER_KEYPAIR_PATH|AR_IO_WALLET|OBSERVER_WALLET|SOLANA_UPLOAD_KEYPAIR_PATH|REPORT_DATA_SINK|SUBMIT_CONTRACT_INTERACTIONS)' .env \
  | sed -E 's#api-key=[^& ]+#api-key=***#' || true
echo

echo "=== key files ==="
OBSERVER_KEYPAIR_PATH="\$(get_env OBSERVER_KEYPAIR_PATH)"
SOLANA_KEYPAIR_PATH="\$(get_env SOLANA_KEYPAIR_PATH)"
if [[ -n "\${OBSERVER_KEYPAIR_PATH:-}" ]]; then
  HOST_OBSERVER_KEY="${INSTALL_DIR}\${OBSERVER_KEYPAIR_PATH#/app}"
  [[ -f "\${HOST_OBSERVER_KEY}" ]] && echo "observer key: OK \${HOST_OBSERVER_KEY}" || echo "observer key: MISSING \${HOST_OBSERVER_KEY}"
fi
if [[ -n "\${SOLANA_KEYPAIR_PATH:-}" ]]; then
  HOST_SOLANA_KEY="${INSTALL_DIR}\${SOLANA_KEYPAIR_PATH#/app}"
  [[ -f "\${HOST_SOLANA_KEY}" ]] && echo "operator key: OK \${HOST_SOLANA_KEY}" || echo "operator key: MISSING \${HOST_SOLANA_KEY}"
fi
echo

echo "=== observer report endpoint ==="
if ! curl -fsS "http://localhost:5050/ar-io/observer/reports/current" | jq .; then
  ARNS_ROOT_HOST="\$(get_env ARNS_ROOT_HOST)"
  if [[ -n "\${ARNS_ROOT_HOST:-}" ]]; then
    echo "localhost:5050 unavailable; trying gateway domain..."
    curl -fsS "https://\${ARNS_ROOT_HOST}/ar-io/observer/reports/current" | jq . || true
  else
    echo "localhost:5050 unavailable and ARNS_ROOT_HOST is not set."
  fi
fi
echo

echo "=== observer status ==="
docker compose ps observer
echo

echo "=== observer recent warnings/errors ==="
docker compose logs observer --tail=250 2>/dev/null | grep -Ei 'error|warn|epoch|pda|crank|prescribe|report|wallet|solana|signature|transaction' || true
echo

if docker compose logs observer --tail=400 2>/dev/null | grep -qEi 'Epoch [0-9]+ PDA not found|has prescribe_epoch run yet'; then
  echo "Diagnosis: observer config and key loading may be OK, but the epoch PDA is missing on-chain."
  echo "This usually leaves /ar-io/observer/reports/current at Report pending until the ar.io Solana epoch is prescribed/cranked."
  echo "Keep the gateway running, watch for an ar.io-node update, and share this output with ar.io support if it persists."
fi
EOF

  cat > ${HELPER_BIN_DIR}/gateway-help <<'EOF'
#!/usr/bin/env bash
cat <<'HELP'
ar.io Gateway helper commands

gateway-check           Run public gateway, /ar-io/info, observer report, and Docker checks
gateway-status          Show Docker services, resource usage, and disk usage
gateway-logs            Follow core, observer, and envoy logs
gateway-update          Apply verified R85; preserve .env, wallets and databases
gateway-restart         Recreate services without deleting volumes
gateway-balance         Check observer Solana wallet SOL balance
gateway-observer-check  Diagnose observer key/env/report/epoch issues
gateway-x402-check      Check x402/rate limiter env, metrics, facilitator, and logs
gateway-enable-x402     Configure x402 later without reinstalling the gateway
gateway-renew-cert      Renew wildcard SSL certificate with manual DNS challenge

Typical follow-up:
  gateway-check
  gateway-status
  gateway-observer-check

Enable x402 later:
  gateway-enable-x402
HELP
EOF

  cat > ${HELPER_BIN_DIR}/gateway-renew-cert <<EOF
#!/usr/bin/env bash
set -euo pipefail
certbot certonly --manual --preferred-challenges dns --agree-tos --register-unsafely-without-email -d ${DOMAIN} -d "*.${DOMAIN}"
nginx -t
systemctl reload-or-restart nginx
EOF

  chmod +x ${HELPER_BIN_DIR}/gateway-update \
    ${HELPER_BIN_DIR}/gateway-restart \
    ${HELPER_BIN_DIR}/gateway-logs \
    ${HELPER_BIN_DIR}/gateway-status \
    ${HELPER_BIN_DIR}/gateway-check \
    ${HELPER_BIN_DIR}/gateway-x402-check \
    ${HELPER_BIN_DIR}/gateway-enable-x402 \
    ${HELPER_BIN_DIR}/gateway-balance \
    ${HELPER_BIN_DIR}/gateway-observer-check \
    ${HELPER_BIN_DIR}/gateway-help \
    ${HELPER_BIN_DIR}/gateway-renew-cert
}

finish() {
  echo
  echo -e "${GREEN}R85 installation finished. Network registration is a separate step.${NC}"
  echo "Gateway URL: https://${DOMAIN}"
  echo
  echo "Useful commands:"
  echo "  gateway-check"
  echo "  gateway-status"
  echo "  gateway-logs"
  echo "  gateway-update"
  echo "  gateway-restart"
  echo "  gateway-x402-check"
  echo "  gateway-enable-x402"
  echo "  gateway-balance"
  echo "  gateway-observer-check"
  echo "  gateway-help"
  echo "  gateway-renew-cert"
  echo
  echo "Important:"
  echo "  Register/stake at https://gateways.ar.io and keep the observer funded with SOL."
  echo "  Report uploads use Turbo credits: https://console.ar.io/topup"
  echo "  Keep this observer address unique to this gateway. Rewards are not guaranteed."
  echo "  Wildcard certificates need manual renewal: gateway-renew-cert"
  echo "  Solana mode requires the operator keyfile:"
  echo "  ${INSTALL_DIR}/wallets/${AR_IO_WALLET}.json"
  if [[ "$OBSERVER_WALLET" != "$AR_IO_WALLET" ]]; then
    echo "  Observer reports also require the observer keyfile:"
    echo "  ${INSTALL_DIR}/wallets/${OBSERVER_WALLET}.json"
  fi
  echo
  if ! ${HELPER_BIN_DIR}/gateway-check; then
    warn "Services were installed, but public checks are not all passing yet. Run gateway-check after startup; inspect gateway-logs if failures persist."
  fi
}

main() {
  require_root
  validate_install_dir
  case "${1:-}" in
    --refresh-helpers) refresh_helpers; return ;;
    --upgrade) upgrade_gateway; return ;;
    "") ;;
    *) die "Usage: bash install-gateway.sh [--upgrade|--refresh-helpers]" ;;
  esac
  if [[ -f "$INSTALL_DIR/.env" ]]; then
    if [[ -f "$INSTALL_DIR/.installer/setup-pending" ]]; then
      resume_gateway
    else
      upgrade_gateway
    fi
    return
  fi
  header
  collect_config
  install_packages
  install_docker
  clone_node
  configure_wallet "main/operator" "$AR_IO_WALLET"
  if [[ "$OBSERVER_WALLET" == "$AR_IO_WALLET" ]]; then
    ok "Observer wallet matches main/operator wallet; reusing the same keyfile."
  else
    configure_wallet "observer" "$OBSERVER_WALLET"
  fi
  mkdir -p "$INSTALL_DIR/.installer"
  touch "$INSTALL_DIR/.installer/setup-pending"
  write_env
  save_installer
  start_gateway
  configure_firewall_ssl_nginx
  write_helpers
  rm -f "$INSTALL_DIR/.installer/setup-pending"
  finish
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
