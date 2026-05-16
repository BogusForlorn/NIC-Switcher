#!/usr/bin/env bash
# Safe OpenVPN wrapper for dual-NIC setup.
# Connects OpenVPN while protecting against redirect-gateway leakage
# and verifying AI/Copilot traffic still routes via wlan0.
#
# Usage:  ./vpn-connect.sh <config.ovpn> [extra openvpn args...]
#         ./vpn-connect.sh corp.ovpn
#         ./vpn-connect.sh corp.ovpn --auth-user-pass creds.txt
#         ./vpn-connect.sh --disconnect
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$DIR/state.json"
LOGDIR="$DIR/logs"
PIDFILE="$LOGDIR/vpn-dual-nic.pid"
LOGFILE="$LOGDIR/vpn-dual-nic.log"

red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m[*]\033[0m %s\n' "$*"; }

mkdir -p "$LOGDIR"
chmod 700 "$LOGDIR"

# --- disconnect mode ---
if [[ "${1:-}" == "--disconnect" || "${1:-}" == "-d" ]]; then
  if [[ ! -f "$PIDFILE" ]]; then
    red "No PID file found — OpenVPN may not be running via this wrapper."
    exit 1
  fi
  VPN_PID=$(cat "$PIDFILE")
  if [[ -d "/proc/$VPN_PID" ]] && grep -q openvpn "/proc/$VPN_PID/comm" 2>/dev/null; then
    info "killing OpenVPN (PID $VPN_PID)..."
    sudo kill "$VPN_PID"
    sleep 2
    if [[ -d "/proc/$VPN_PID" ]]; then
      info "still running — sending SIGKILL..."
      sudo kill -9 "$VPN_PID" 2>/dev/null || true
    fi
    rm -f "$PIDFILE"
    green "✓ OpenVPN disconnected."
  else
    red "PID $VPN_PID is not an OpenVPN process (stale PID file)."
    rm -f "$PIDFILE"
    exit 1
  fi
  exit 0
fi

# --- arg check ---
if [[ $# -lt 1 ]]; then
  red "Usage: $0 <config.ovpn> [extra openvpn args...]"
  red "       $0 --disconnect"
  exit 1
fi

OVPN_CONF="$1"
shift
EXTRA_ARGS=("$@")

if [[ ! -f "$OVPN_CONF" ]]; then
  red "File not found: $OVPN_CONF"
  exit 1
fi

# --- stale instance check ---
if [[ -f "$PIDFILE" ]]; then
  OLD_PID=$(cat "$PIDFILE")
  if [[ -d "/proc/$OLD_PID" ]] && grep -q openvpn "/proc/$OLD_PID/comm" 2>/dev/null; then
    red "OpenVPN already running (PID $OLD_PID). Disconnect first: $0 --disconnect"
    exit 1
  fi
  rm -f "$PIDFILE"
fi

# --- pre-flight: switch must be active ---
if [[ ! -f "$STATE" ]]; then
  red "dual-NIC switch is not active (no state.json). Run switch.sh first."
  exit 1
fi

# --- scan .ovpn config for dangerous local directives ---
info "scanning $OVPN_CONF for dangerous directives..."
DANGEROUS=false
while IFS= read -r line; do
  # Strip comments and leading whitespace, normalize multiple spaces
  clean=$(echo "$line" | sed 's/#.*//;s/;.*//;s/^[[:space:]]*//;s/[[:space:]]\+/ /g')
  [[ -z "$clean" ]] && continue
  case "$clean" in
    redirect-gateway*|--redirect-gateway*)
      red "  ✗ BLOCKED: '$clean' — would hijack all traffic through VPN"
      DANGEROUS=true
      ;;
    route\ 0.0.0.0*|route\ 128.0.0.0*)
      red "  ✗ BLOCKED: '$clean' — broad route would override wlan0 default"
      DANGEROUS=true
      ;;
    route-ipv6\ ::/0*|route-ipv6\ 2000::/3*|route-ipv6\ 2000::/4*|route-ipv6\ 3000::/4*)
      red "  ✗ BLOCKED: '$clean' — IPv6 default route hijack"
      DANGEROUS=true
      ;;
    config\ *)
      red "  ⚠ WARNING: '$clean' — includes another config (not scanned)"
      ;;
  esac
done < "$OVPN_CONF"
if $DANGEROUS; then
  red ""
  red "The .ovpn config contains directives that would leak AI traffic through the VPN."
  red "Remove them from the config, or ask the VPN admin for a split-tunnel config."
  red "Aborting."
  exit 1
fi
green "  ✓ config is clean"

# --- check for interactive auth requirement ---
# auth-user-pass WITHOUT a filename = interactive prompt (breaks daemon mode)
# auth-user-pass WITH a filename = reads from file (fine)
if grep -qE '^[[:space:]]*auth-user-pass[[:space:]]*$' "$OVPN_CONF" 2>/dev/null; then
  # Check if --auth-user-pass is passed via extra args (with a file after it)
  HAS_AUTH_FILE=false
  for idx in "${!EXTRA_ARGS[@]}"; do
    if [[ "${EXTRA_ARGS[$idx]}" == "--auth-user-pass" ]]; then
      # Next arg should be the credentials file
      next_idx=$((idx + 1))
      if [[ ${next_idx} -lt ${#EXTRA_ARGS[@]} && -f "${EXTRA_ARGS[$next_idx]}" ]]; then
        HAS_AUTH_FILE=true
      fi
      break
    fi
  done
  if ! $HAS_AUTH_FILE; then
    red "Config requires interactive auth (auth-user-pass without file)."
    red "OpenVPN runs as daemon and cannot prompt for credentials."
    red "Usage: $0 $OVPN_CONF --auth-user-pass /path/to/creds.txt"
    red "  (creds.txt: line 1 = username, line 2 = password)"
    exit 1
  fi
fi

# --- snapshot routes and interfaces before OpenVPN ---
info "pre-connect snapshot:"
WLAN_DEFAULT_BEFORE=$(ip -4 route show default dev wlan0 2>/dev/null | head -1)
if [[ -z "$WLAN_DEFAULT_BEFORE" ]]; then
  red "wlan0 has no default route — switch may not be active. Aborting."
  exit 1
fi
info "  default: $WLAN_DEFAULT_BEFORE"

COPILOT_DEV_BEFORE=$(ip route get 140.82.114.21 2>/dev/null | head -1 | grep -oP 'dev \K\w+' || echo "unknown")
info "  Copilot API (140.82.114.21) via: $COPILOT_DEV_BEFORE"

# Snapshot current interfaces to detect new tun
IFACES_BEFORE=$(ip -o link show 2>/dev/null | awk -F: '{print $2}' | tr -d ' ' | sort)

# --- build openvpn command with safety filters ---
OVPN_CMD=(
  sudo openvpn
  --config "$OVPN_CONF"
  --pull-filter ignore redirect-gateway
  --pull-filter ignore "route 0.0.0.0"
  --pull-filter ignore "route 128.0.0.0"
  --pull-filter ignore "redirect-gateway"
  --pull-filter ignore "route-ipv6 ::/0"
  --pull-filter ignore "route-ipv6 2000::/3"
  --script-security 1
  --daemon vpn-dual-nic
  --log "$LOGFILE"
  --writepid "$PIDFILE"
)

# Append any extra user args
if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
  OVPN_CMD+=("${EXTRA_ARGS[@]}")
fi

info "connecting OpenVPN..."
info "  config: $OVPN_CONF"
info "  safety: redirect-gateway BLOCKED, dangerous routes BLOCKED"
info "  log: $LOGFILE"

"${OVPN_CMD[@]}"

# --- wait for new tun interface to appear (before/after diff) ---
info "waiting for tunnel interface..."
TUN_IF=""
for i in $(seq 1 30); do
  IFACES_AFTER=$(ip -o link show 2>/dev/null | awk -F: '{print $2}' | tr -d ' ' | sort)
  NEW_IF=$(comm -13 <(echo "$IFACES_BEFORE") <(echo "$IFACES_AFTER") | grep -E '^(tun|tap|vpn)' | head -1)
  if [[ -n "$NEW_IF" ]]; then
    TUN_IF="$NEW_IF"
    break
  fi
  sleep 1
done

if [[ -z "$TUN_IF" ]]; then
  red "tunnel interface did not appear after 30s. Check $LOGFILE"
  red "Last 10 lines:"
  tail -10 "$LOGFILE" 2>/dev/null || true
  red "Killing OpenVPN..."
  sudo kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null || true
  rm -f "$PIDFILE"
  exit 1
fi

# Wait for routes to settle, then poll for IP assignment
info "tunnel $TUN_IF detected, waiting for routes..."
TUN_IP=""
for i in $(seq 1 10); do
  TUN_IP=$(ip -4 -o addr show dev "$TUN_IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
  [[ -n "$TUN_IP" ]] && break
  sleep 1
done
sleep 2

info "tunnel up: $TUN_IF (${TUN_IP:-no IP yet})"

# --- post-connect route verification ---
info "verifying routes..."
VERIFY_OK=true

# Check wlan0 still has default
WLAN_DEFAULT_AFTER=$(ip -4 route show default dev wlan0 2>/dev/null | head -1)
if [[ -z "$WLAN_DEFAULT_AFTER" ]]; then
  red "  ✗ wlan0 default route GONE — OpenVPN may have hijacked it!"
  VERIFY_OK=false
else
  green "  ✓ wlan0 default route intact"
fi

# Check for redirect-gateway routes (0.0.0.0/1, 128.0.0.0/1 via tun)
if ip route show 2>/dev/null | grep -qE "(0\.0\.0\.0/1|128\.0\.0\.0/1).*$TUN_IF"; then
  red "  ✗ redirect-gateway routes detected on $TUN_IF — AI traffic WILL LEAK!"
  red "    Killing OpenVPN to prevent leakage..."
  sudo kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null || true
  rm -f "$PIDFILE"
  red "    OpenVPN killed. The server is pushing redirect-gateway despite pull-filter."
  red "    Contact VPN admin for split-tunnel config."
  exit 1
fi
green "  ✓ no redirect-gateway routes (0.0.0.0/1, 128.0.0.0/1)"

# Check IPv6 default route hijack
if ip -6 route show 2>/dev/null | grep -qE "(::/0|2000::/3).*$TUN_IF"; then
  red "  ✗ IPv6 default route via $TUN_IF detected!"
  VERIFY_OK=false
else
  green "  ✓ no IPv6 default route hijack"
fi

# Verify Copilot/AI traffic still routes via wlan0
for check_ip in 140.82.114.21 1.1.1.1 8.8.8.8; do
  check_dev=$(ip route get "$check_ip" 2>/dev/null | head -1 | grep -oP 'dev \K\w+' || echo "unknown")
  if [[ "$check_dev" != "wlan0" ]]; then
    red "  ✗ $check_ip routes via $check_dev (expected wlan0)"
    VERIFY_OK=false
  else
    printf '  ✓ %s → %s\n' "$check_ip" "$check_dev"
  fi
done

# Verify VPN tunnel routes exist (10.x.x.x or whatever was pushed)
TUN_ROUTES=$(ip route show dev "$TUN_IF" 2>/dev/null | grep -v '^default' | head -5)
if [[ -n "$TUN_ROUTES" ]]; then
  info "VPN tunnel routes:"
  echo "$TUN_ROUTES" | sed 's/^/  /'
else
  info "no explicit VPN routes pushed (point-to-point tunnel only)"
fi

# Check eth0 guard is still active
if ! sudo iptables -L DUAL_NIC_GUARD -n &>/dev/null 2>&1; then
  red "  ✗ DUAL_NIC_GUARD iptables chain missing!"
  VERIFY_OK=false
else
  green "  ✓ eth0 iptables guard active"
fi

# Check for existing WireGuard VPN endpoint pins
for vpn_ep in $(python3 -c "import json; d=json.load(open('$STATE')); print(' '.join(d.get('vpn_pinned',[])))" 2>/dev/null || true); do
  [[ -z "$vpn_ep" ]] && continue
  vpn_dev=$(ip route get "$vpn_ep" 2>/dev/null | head -1 | grep -oP 'dev \K\w+' || echo "unknown")
  if [[ "$vpn_dev" == "eth0" ]]; then
    printf '  ✓ WireGuard pin %s → %s\n' "$vpn_ep" "$vpn_dev"
  else
    red "  ✗ WireGuard pin $vpn_ep routes via $vpn_dev (expected eth0)"
    VERIFY_OK=false
  fi
done

if ! $VERIFY_OK; then
  red ""
  red "ROUTE VERIFICATION FAILED — AI traffic may not be isolated!"
  red "Killing OpenVPN to prevent leakage..."
  sudo kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null || true
  rm -f "$PIDFILE"
  exit 1
fi

echo ""
green "✓ OpenVPN connected safely."
green "  Tunnel: $TUN_IF (${TUN_IP:-pending})"
green "  AI/Copilot traffic: wlan0 (verified)"
green "  Corp/VPN traffic: $TUN_IF → eth0 (encrypted)"
green ""
green "  To disconnect: $0 --disconnect"
green "  VPN log: $LOGFILE"
