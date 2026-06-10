#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

SCRIPT_NAME="$(basename "$0")"

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

die() {
  printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Install sing-box with two Shadowsocks inbounds:
  direct port -> VPS public IP
  warp port   -> Cloudflare WARP via sing-box WireGuard endpoint

Usage:
  bash install-sing-box-ss-warp.sh

Common environment variables:
  DIRECT_PORT=55221
  WARP_PORT=36243
  SS_METHOD=2022-blake3-aes-256-gcm
  DIRECT_METHOD=$SS_METHOD
  WARP_METHOD=$SS_METHOD
  DIRECT_PASSWORD=<generated if empty>
  WARP_PASSWORD=<generated if empty>
  SERVER_IP=<auto-detected if empty>
  WGCF_DIR=/root/sing-box-wgcf
  WG_ENDPOINT=162.159.192.1:2408
  FORCE_WARP_REGISTER=0
  RUN_VERIFY=1
  DISABLE_WARP_SVC=1
  INSTALL_UNATTENDED_UPGRADES=1

Credentials are written to:
  /root/sing-box-ss-warp.txt
EOF
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "run as root"
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/}"
  s="${s//$'\r'/}"
  printf '%s' "$s"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

random_password() {
  openssl rand -base64 32 | tr -d '\n'
}

install_dependencies() {
  log "installing base dependencies"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl gpg openssl python3
}

install_sing_box() {
  if [ "${SKIP_SING_BOX_INSTALL:-0}" = "1" ] && command -v sing-box >/dev/null 2>&1; then
    log "SKIP_SING_BOX_INSTALL=1, keeping existing sing-box"
    return
  fi

  log "installing sing-box from SagerNet APT repository"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL "${SING_BOX_GPG_URL:-https://sing-box.app/gpg.key}" -o /etc/apt/keyrings/sagernet.asc

  cat > /etc/apt/sources.list.d/sagernet.sources <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y sing-box
}

install_wgcf() {
  if [ "${SKIP_WGCF_INSTALL:-0}" = "1" ] && command -v wgcf >/dev/null 2>&1; then
    log "SKIP_WGCF_INSTALL=1, keeping existing wgcf"
    return
  fi

  local version="${WGCF_VERSION:-v2.2.31}"
  local version_no_v="${version#v}"
  local url="${WGCF_URL:-https://github.com/ViRb3/wgcf/releases/download/${version}/wgcf_${version_no_v}_linux_amd64}"
  local tmp
  tmp="$(mktemp)"

  log "installing wgcf ${version}"
  curl -fsSL --retry 3 --connect-timeout 20 "$url" -o "$tmp"

  if [ -n "${WGCF_SHA256:-}" ]; then
    printf '%s  %s\n' "$WGCF_SHA256" "$tmp" | sha256sum -c -
  fi

  install -o root -g root -m 0755 "$tmp" /usr/local/bin/wgcf
  rm -f "$tmp"
}

generate_warp_profile() {
  local wgcf_dir="$1"
  local force="${FORCE_WARP_REGISTER:-0}"

  install -d -m 0700 "$wgcf_dir"
  cd "$wgcf_dir"

  if [ "$force" = "1" ] && [ -f wgcf-account.toml ]; then
    local backup="wgcf-backup-$(date +%Y%m%d-%H%M%S)"
    install -d -m 0700 "$backup"
    cp -a wgcf-account.toml "$backup/" 2>/dev/null || true
    cp -a wgcf-profile.conf "$backup/" 2>/dev/null || true
    rm -f wgcf-account.toml wgcf-profile.conf
    log "backed up old wgcf files to ${wgcf_dir}/${backup}"
  fi

  if [ ! -f wgcf-account.toml ]; then
    log "registering a new Cloudflare WARP WireGuard account"
    /usr/local/bin/wgcf register --accept-tos --name "${WGCF_NAME:-$(hostname -s)-sing-box}"
  else
    log "reusing existing wgcf-account.toml"
  fi

  log "generating WireGuard profile"
  /usr/local/bin/wgcf generate --profile wgcf-profile.conf
  chmod 0600 wgcf-account.toml wgcf-profile.conf
}

profile_value() {
  local key="$1"
  local file="$2"
  awk -F '=' -v wanted="$key" '
    $1 ~ "^[[:space:]]*" wanted "[[:space:]]*$" {
      sub(/^[[:space:]]*/, "", $2)
      sub(/[[:space:]]*$/, "", $2)
      print $2
      exit
    }
  ' "$file"
}

csv_to_json_array() {
  local raw="$1"
  local out=""
  local item
  IFS=',' read -r -a parts <<< "$raw"
  for item in "${parts[@]}"; do
    item="$(trim "$item")"
    [ -n "$item" ] || continue
    if [ -n "$out" ]; then
      out+=", "
    fi
    out+="\"$(json_escape "$item")\""
  done
  [ -n "$out" ] || die "empty WireGuard address list"
  printf '%s' "$out"
}

split_endpoint() {
  local endpoint="$1"
  ENDPOINT_HOST="${endpoint%:*}"
  ENDPOINT_PORT="${endpoint##*:}"
  ENDPOINT_HOST="${ENDPOINT_HOST#[}"
  ENDPOINT_HOST="${ENDPOINT_HOST%]}"
}

write_sing_box_config() {
  local profile="$1"
  local config_path="$2"
  local direct_port="$3"
  local warp_port="$4"
  local direct_method="$5"
  local warp_method="$6"
  local direct_password="$7"
  local warp_password="$8"

  local wg_private_key wg_address_raw wg_address_json wg_public_key wg_endpoint_raw
  wg_private_key="$(profile_value PrivateKey "$profile")"
  wg_address_raw="$(profile_value Address "$profile")"
  wg_public_key="$(profile_value PublicKey "$profile")"
  wg_endpoint_raw="$(profile_value Endpoint "$profile")"

  [ -n "$wg_private_key" ] || die "missing PrivateKey in $profile"
  [ -n "$wg_address_raw" ] || die "missing Address in $profile"
  [ -n "$wg_public_key" ] || die "missing PublicKey in $profile"
  [ -n "$wg_endpoint_raw" ] || die "missing Endpoint in $profile"

  local endpoint="${WG_ENDPOINT:-$wg_endpoint_raw}"
  if [ "$endpoint" = "engage.cloudflareclient.com:2408" ]; then
    endpoint="162.159.192.1:2408"
  fi
  split_endpoint "$endpoint"
  valid_port "$ENDPOINT_PORT" || die "invalid WARP endpoint port: $ENDPOINT_PORT"

  wg_address_json="$(csv_to_json_array "$wg_address_raw")"

  install -d -m 0755 /etc/sing-box /var/lib/sing-box

  local candidate backup group
  candidate="$(mktemp)"
  backup=""
  group="root"
  if getent group sing-box >/dev/null 2>&1; then
    group="sing-box"
  fi

  cat > "$candidate" <<EOF
{
  "log": {
    "level": "${LOG_LEVEL:-info}",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-direct",
      "listen": "0.0.0.0",
      "listen_port": ${direct_port},
      "network": ["tcp", "udp"],
      "method": "$(json_escape "$direct_method")",
      "password": "$(json_escape "$direct_password")"
    },
    {
      "type": "shadowsocks",
      "tag": "ss-warp",
      "listen": "0.0.0.0",
      "listen_port": ${warp_port},
      "network": ["tcp", "udp"],
      "method": "$(json_escape "$warp_method")",
      "password": "$(json_escape "$warp_password")"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "warp-wg",
      "system": false,
      "name": "warp-wg",
      "mtu": ${WG_MTU:-1280},
      "address": [${wg_address_json}],
      "private_key": "$(json_escape "$wg_private_key")",
      "peers": [
        {
          "address": "$(json_escape "$ENDPOINT_HOST")",
          "port": ${ENDPOINT_PORT},
          "public_key": "$(json_escape "$wg_public_key")",
          "allowed_ips": ["0.0.0.0/0", "::/0"]
        }
      ]
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": "ss-direct",
        "action": "route",
        "outbound": "direct"
      },
      {
        "inbound": "ss-warp",
        "action": "route",
        "outbound": "warp-wg"
      }
    ],
    "final": "direct"
  }
}
EOF

  log "checking sing-box config"
  sing-box check -D /var/lib/sing-box -c "$candidate"

  if [ -f "$config_path" ]; then
    backup="${config_path}.bak-$(date +%Y%m%d-%H%M%S)"
    cp -a "$config_path" "$backup"
    log "backed up existing config to $backup"
  fi

  install -o root -g "$group" -m 0640 "$candidate" "$config_path"
  rm -f "$candidate"

  if ! systemctl enable --now sing-box; then
    [ -n "$backup" ] && cp -a "$backup" "$config_path"
    systemctl restart sing-box >/dev/null 2>&1 || true
    die "failed to enable/start sing-box"
  fi

  if ! systemctl restart sing-box; then
    [ -n "$backup" ] && cp -a "$backup" "$config_path"
    systemctl restart sing-box >/dev/null 2>&1 || true
    die "failed to restart sing-box"
  fi

  sleep 2
  systemctl is-active --quiet sing-box || die "sing-box is not active after restart"
}

configure_ufw() {
  local direct_port="$1"
  local warp_port="$2"

  if ! command -v ufw >/dev/null 2>&1; then
    log "ufw not installed, skipping firewall changes"
    return
  fi

  if ! ufw status | grep -q '^Status: active'; then
    log "ufw not active, skipping firewall changes"
    return
  fi

  log "allowing Shadowsocks ports in ufw"
  ufw allow "${direct_port}/tcp"
  ufw allow "${direct_port}/udp"
  ufw allow "${warp_port}/tcp"
  ufw allow "${warp_port}/udp"
}

configure_unattended_upgrades() {
  if [ "${INSTALL_UNATTENDED_UPGRADES:-1}" != "1" ]; then
    log "INSTALL_UNATTENDED_UPGRADES!=1, skipping unattended-upgrades"
    return
  fi

  log "configuring unattended-upgrades"
  DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades apt-listchanges

  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

  cat > /etc/apt/apt.conf.d/52unattended-upgrades-third-party <<'EOF'
Unattended-Upgrade::Origins-Pattern:: "origin=sagernet_apt_fury_io,label=sagernet_apt_fury_io";
EOF
}

disable_warp_svc() {
  if [ "${DISABLE_WARP_SVC:-1}" != "1" ]; then
    return
  fi

  if systemctl list-unit-files warp-svc.service >/dev/null 2>&1; then
    log "disabling unused warp-svc"
    systemctl disable --now warp-svc >/dev/null 2>&1 || true
  fi
}

ss_uri() {
  local name="$1"
  local server="$2"
  local port="$3"
  local method="$4"
  local password="$5"
  local userinfo
  userinfo="$(printf '%s' "${method}:${password}" | base64 | tr -d '\n=' | tr '+/' '-_')"
  printf 'ss://%s@%s:%s#%s\n' "$userinfo" "$server" "$port" "$name"
}

write_credentials() {
  local path="$1"
  local server="$2"
  local direct_port="$3"
  local warp_port="$4"
  local direct_method="$5"
  local warp_method="$6"
  local direct_password="$7"
  local warp_password="$8"

  cat > "$path" <<EOF
server=${server}
direct_method=${direct_method}
direct_port=${direct_port}
direct_password=${direct_password}
warp_method=${warp_method}
warp_port=${warp_port}
warp_password=${warp_password}
warp_transport=sing-box-wireguard-endpoint
warp_udp=true

direct_uri=$(ss_uri ss-direct "$server" "$direct_port" "$direct_method" "$direct_password")
warp_uri=$(ss_uri ss-warp "$server" "$warp_port" "$warp_method" "$warp_password")
EOF
  chmod 0600 "$path"
}

wait_for_tcp_listener() {
  local port="$1"
  local i
  for i in $(seq 1 60); do
    if ss -H -tlpen | grep -q "127.0.0.1:${port}\b"; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

verify_one_path() {
  local name="$1"
  local ss_port="$2"
  local method="$3"
  local password="$4"
  local local_port="$5"
  local dir="$6"

  cat > "${dir}/${name}.json" <<EOF
{
  "log": {"level": "error"},
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks-in",
      "listen": "127.0.0.1",
      "listen_port": ${local_port}
    }
  ],
  "outbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-out",
      "server": "127.0.0.1",
      "server_port": ${ss_port},
      "method": "$(json_escape "$method")",
      "password": "$(json_escape "$password")"
    }
  ],
  "route": {"final": "ss-out"}
}
EOF

  sing-box check -D "$dir" -c "${dir}/${name}.json" >/dev/null
  sing-box run -D "$dir" -c "${dir}/${name}.json" > "${dir}/${name}.log" 2>&1 &
  local pid=$!

  cleanup_client() {
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" 2>/dev/null || true
  }

  if ! wait_for_tcp_listener "$local_port"; then
    cat "${dir}/${name}.log" >&2 || true
    cleanup_client
    die "${name} verification client did not start"
  fi

  local ip
  if ! ip="$(curl -4fsS --socks5-hostname "127.0.0.1:${local_port}" --max-time 30 https://api.ipify.org)"; then
    cleanup_client
    die "${name} TCP verification failed"
  fi
  printf '%s_tcp_ip=%s\n' "$name" "$ip"

  if ! python3 - "$name" "$local_port" <<'PY'
import random
import socket
import struct
import sys

label = sys.argv[1]
socks_port = int(sys.argv[2])
qid = random.randrange(65536)
qname = b''.join(bytes([len(p)]) + p.encode() for p in 'example.com'.split('.')) + b'\x00'
payload = struct.pack('!HHHHHH', qid, 0x0100, 1, 0, 0, 0) + qname + struct.pack('!HH', 1, 1)

tcp = socket.create_connection(('127.0.0.1', socks_port), timeout=5)
tcp.settimeout(5)
tcp.sendall(b'\x05\x01\x00')
if tcp.recv(2) != b'\x05\x00':
    raise SystemExit(f'{label}: socks auth failed')
tcp.sendall(b'\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00')
rep = tcp.recv(10)
if len(rep) < 10 or rep[1] != 0:
    raise SystemExit(f'{label}: udp associate failed: {rep.hex()}')
relay_host = socket.inet_ntoa(rep[4:8])
relay_port = struct.unpack('!H', rep[8:10])[0]
if relay_host == '0.0.0.0':
    relay_host = '127.0.0.1'

udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
udp.settimeout(10)
udp.sendto(
    b'\x00\x00\x00\x01' + socket.inet_aton('1.1.1.1') + struct.pack('!H', 53) + payload,
    (relay_host, relay_port),
)
data, _ = udp.recvfrom(2048)
dns = data[10:] if data.startswith(b'\x00\x00\x00') else data
ok = len(dns) >= 12 and struct.unpack('!H', dns[:2])[0] == qid and (dns[3] & 0x80)
if not ok:
    raise SystemExit(f'{label}: invalid udp dns response length={len(data)}')
print(f'{label}_udp_dns=ok')
PY
  then
    cleanup_client
    die "${name} UDP verification failed"
  fi

  cleanup_client
}

run_verification() {
  if [ "${RUN_VERIFY:-1}" != "1" ]; then
    log "RUN_VERIFY!=1, skipping verification"
    return
  fi

  local direct_port="$1"
  local warp_port="$2"
  local direct_method="$3"
  local warp_method="$4"
  local direct_password="$5"
  local warp_password="$6"
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN

  log "verifying direct and WARP paths"
  verify_one_path direct "$direct_port" "$direct_method" "$direct_password" 19081 "$dir"
  verify_one_path warp "$warp_port" "$warp_method" "$warp_password" 19082 "$dir"
}

detect_server_ip() {
  if [ -n "${SERVER_IP:-}" ]; then
    printf '%s' "$SERVER_IP"
    return
  fi

  local ip
  ip="$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  if [ -z "$ip" ]; then
    ip="$(hostname -I | awk '{print $1}')"
  fi
  [ -n "$ip" ] || die "cannot determine SERVER_IP; set SERVER_IP=x.x.x.x"
  printf '%s' "$ip"
}

main() {
  case "${1:-}" in
    -h|--help)
      usage
      exit 0
      ;;
    "")
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac

  need_root
  need_cmd apt-get
  need_cmd systemctl

  local direct_port="${DIRECT_PORT:-55221}"
  local warp_port="${WARP_PORT:-36243}"
  valid_port "$direct_port" || die "invalid DIRECT_PORT: $direct_port"
  valid_port "$warp_port" || die "invalid WARP_PORT: $warp_port"
  [ "$direct_port" != "$warp_port" ] || die "DIRECT_PORT and WARP_PORT must differ"

  local method="${SS_METHOD:-2022-blake3-aes-256-gcm}"
  local direct_method="${DIRECT_METHOD:-$method}"
  local warp_method="${WARP_METHOD:-$method}"
  local direct_password="${DIRECT_PASSWORD:-}"
  local warp_password="${WARP_PASSWORD:-}"
  local wgcf_dir="${WGCF_DIR:-/root/sing-box-wgcf}"
  local config_path="${SING_BOX_CONFIG:-/etc/sing-box/config.json}"
  local creds_path="${CREDS_PATH:-/root/sing-box-ss-warp.txt}"

  install_dependencies
  need_cmd openssl
  need_cmd curl
  need_cmd python3

  if [ -z "$direct_password" ]; then
    direct_password="$(random_password)"
  fi
  if [ -z "$warp_password" ]; then
    warp_password="$(random_password)"
  fi

  install_sing_box
  install_wgcf
  generate_warp_profile "$wgcf_dir"

  write_sing_box_config \
    "${wgcf_dir}/wgcf-profile.conf" \
    "$config_path" \
    "$direct_port" \
    "$warp_port" \
    "$direct_method" \
    "$warp_method" \
    "$direct_password" \
    "$warp_password"

  configure_ufw "$direct_port" "$warp_port"
  configure_unattended_upgrades
  disable_warp_svc

  local server_ip
  server_ip="$(detect_server_ip)"
  write_credentials \
    "$creds_path" \
    "$server_ip" \
    "$direct_port" \
    "$warp_port" \
    "$direct_method" \
    "$warp_method" \
    "$direct_password" \
    "$warp_password"

  run_verification "$direct_port" "$warp_port" "$direct_method" "$warp_method" "$direct_password" "$warp_password"

  log "done"
  printf '\nCredentials saved to: %s\n\n' "$creds_path"
  sed 's/^\(.*password=\).*/\1<redacted>/' "$creds_path"
  printf '\nFull credentials are in %s\n' "$creds_path"
}

main "$@"
