#!/usr/bin/env bash
# Add a temporary IPv4 host/subnet route during a dual-NIC session.
# Changes are recorded for revert.sh to remove.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$DIR/state.json"
MANUAL_STATE="$DIR/manual-routes.tsv"
MARK="dual-nic-manual"

usage() {
  cat <<'EOF'
Usage:
  sudo ./manual.sh --destination IP[/PREFIX] --interface IFACE [options]

Required:
  -d, --destination IP[/PREFIX]  IPv4 host or subnet to route
  -i, --interface IFACE         Output interface, for example eth0

Options:
  -g, --gateway IP              Next-hop gateway (auto-detected if omitted)
  -H, --hostname NAME           Add IP NAME to /etc/hosts (host IP only)
  -h, --help                    Show this help

Examples:
  sudo ./manual.sh -d 10.1.115.184 -i eth0 -H subdomain.xyz.com
  sudo ./manual.sh -d 10.1.115.0/24 -i eth0
  sudo ./manual.sh -d 172.20.0.0/16 -i eth0 -g 192.168.203.2
EOF
}

DEST=""
IFACE=""
GATEWAY=""
HOSTNAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--destination) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; DEST="$2"; shift 2 ;;
    -i|--interface)   [[ $# -ge 2 ]] || { usage >&2; exit 2; }; IFACE="$2"; shift 2 ;;
    -g|--gateway)     [[ $# -ge 2 ]] || { usage >&2; exit 2; }; GATEWAY="$2"; shift 2 ;;
    -H|--hostname)    [[ $# -ge 2 ]] || { usage >&2; exit 2; }; HOSTNAME="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { printf 'Run this command with sudo.\n' >&2; exit 1; }
[[ -f "$STATE" ]] || { printf 'switch.sh is not active (state.json missing).\n' >&2; exit 1; }
[[ -n "$DEST" && -n "$IFACE" ]] || { usage >&2; exit 2; }
[[ "$IFACE" =~ ^[[:alnum:]_.:-]+$ ]] || { printf 'Invalid interface name.\n' >&2; exit 2; }
ip link show dev "$IFACE" &>/dev/null || { printf 'Interface not found: %s\n' "$IFACE" >&2; exit 1; }

# Canonicalize and validate the destination. A bare address becomes /32.
DEST=$(python3 - "$DEST" <<'PY'
import ipaddress, sys
try:
    value = sys.argv[1]
    if "/" not in value:
        value += "/32"
    print(ipaddress.IPv4Network(value, strict=True))
except ValueError as exc:
    print(f"Invalid IPv4 host/subnet: {exc}", file=sys.stderr)
    raise SystemExit(2)
PY
)

PREFIX=${DEST#*/}
HOST_IP=${DEST%/*}
if [[ -n "$HOSTNAME" ]]; then
  [[ "$PREFIX" == "32" ]] || { printf -- '--hostname is valid only with a single IP (/32).\n' >&2; exit 2; }
  [[ "$HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || {
    printf 'Invalid hostname: %s\n' "$HOSTNAME" >&2; exit 2;
  }
fi

if [[ -n "$GATEWAY" ]]; then
  python3 - "$GATEWAY" <<'PY' >/dev/null
import ipaddress, sys
try:
    ipaddress.IPv4Address(sys.argv[1])
except ValueError as exc:
    print(f"Invalid IPv4 gateway: {exc}", file=sys.stderr)
    raise SystemExit(2)
PY
else
  # Prefer the gateway captured by switch.sh for its known interfaces.
  GATEWAY=$(python3 - "$STATE" "$IFACE" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
print(data.get(sys.argv[2], {}).get("gw", ""))
PY
  )
  if [[ -z "$GATEWAY" ]]; then
    GATEWAY=$(ip -4 route show default dev "$IFACE" | awk '/default/ {print $3; exit}')
  fi
fi

[[ -n "$GATEWAY" ]] || {
  printf 'No gateway found for %s; provide one with --gateway.\n' "$IFACE" >&2
  exit 1
}

# Deliberately use "add", not "replace": never overwrite a pre-existing route.
ip route add "$DEST" via "$GATEWAY" dev "$IFACE"
ROUTE_ADDED=true
FIREWALL_ADDED=false
HOST_ADDED=false
cleanup_failed_add() {
  if [[ "${HOST_ADDED:-false}" == true ]]; then
    [[ "$(tail -n 1 /etc/hosts 2>/dev/null)" == "$HOST_LINE" ]] && \
      sed -i '$d' /etc/hosts 2>/dev/null || true
  fi
  if [[ "${FIREWALL_ADDED:-false}" == true ]]; then
    iptables -D DUAL_NIC_GUARD -d "$DEST" \
      -m comment --comment "$MARK" -j ACCEPT 2>/dev/null || true
  fi
  if [[ "${ROUTE_ADDED:-false}" == true ]]; then
    ip route del "$DEST" via "$GATEWAY" dev "$IFACE" 2>/dev/null || true
  fi
}
trap cleanup_failed_add ERR

# If switch.sh guards this interface, permit the destination immediately before
# the chain's final catch-all REJECT. Earlier DNS rejection rules remain active.
if iptables -C OUTPUT -o "$IFACE" -m comment --comment dual-nic-switch \
    -j DUAL_NIC_GUARD &>/dev/null; then
  REJECT_LINE=$(iptables -L DUAL_NIC_GUARD -n --line-numbers \
    | awk '$2 == "REJECT" {line=$1} END {print line}')
  [[ -n "$REJECT_LINE" ]] || { printf 'Guard catch-all REJECT rule not found.\n' >&2; exit 1; }
  iptables -I DUAL_NIC_GUARD "$REJECT_LINE" -d "$DEST" \
    -m comment --comment "$MARK" -j ACCEPT
  FIREWALL_ADDED=true
fi

if [[ -n "$HOSTNAME" ]]; then
  HOST_LINE=$(printf '%s\t%s\t# %s' "$HOST_IP" "$HOSTNAME" "$MARK")
  printf '%s\n' "$HOST_LINE" >> /etc/hosts
  HOST_ADDED=true
fi

# Fields are validated to exclude tabs/newlines, making this safe to parse.
printf '%s\t%s\t%s\t%s\n' "$DEST" "$IFACE" "$GATEWAY" "$HOSTNAME" >> "$MANUAL_STATE"
chmod 600 "$MANUAL_STATE"
ROUTE_ADDED=false
trap - ERR

printf 'Added: %s via %s dev %s\n' "$DEST" "$GATEWAY" "$IFACE"
[[ -z "$HOSTNAME" ]] || printf 'Hosts: %s -> %s\n' "$HOSTNAME" "$HOST_IP"
ip route get "$HOST_IP" | head -1
