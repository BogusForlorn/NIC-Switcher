#!/usr/bin/env bash
# dual-NIC switch: wlan0 = internet (Copilot), eth0 = corp/target only.
# Auto-detects subnets from `ip addr`. Refuses to run if wlan0 lacks internet.
# Saves prior state to ./state.json so revert.sh can restore exactly.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$DIR/state.json"
MARK="dual-nic-switch"

red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m[*]\033[0m %s\n' "$*"; }

# 1. Sanity: are we already switched?
if [[ -f "$STATE" ]]; then
  red "state.json exists — already switched (or revert failed). Run revert.sh first."
  exit 1
fi

# 2. Both NICs must exist and be UP
for IF in wlan0 eth0; do
  if ! ip link show "$IF" &>/dev/null; then
    red "Interface $IF not present. Plug in / enable it first."
    exit 1
  fi
  STATE_UP=$(ip link show "$IF" | grep -oP 'state \K\w+')
  if [[ "$STATE_UP" != "UP" ]]; then
    red "Interface $IF is $STATE_UP, not UP. Bring it up first."
    exit 1
  fi
done

# 3. Extract IP + subnet for each NIC
read_iface () {
  local iface="$1"
  local line cidr ip subnet gw
  line=$(ip -4 -o addr show dev "$iface" | head -1 || true)
  if [[ -z "$line" ]]; then
    red "$iface has no IPv4 address. Connect it to its network first."
    exit 1
  fi
  cidr=$(awk '{print $4}' <<<"$line")
  ip=${cidr%/*}
  # subnet (network/mask) computed via `ipcalc -n` if avail, else from `ip route`
  subnet=$(ip -4 route show dev "$iface" scope link | awk '{print $1}' | head -1)
  gw=$(ip -4 route show dev "$iface" | awk '/default/ {print $3; exit}')
  echo "$ip|$subnet|$gw"
}

WLAN_INFO=$(read_iface wlan0)
ETH_INFO=$(read_iface eth0)
WLAN_IP=$(cut -d'|' -f1 <<<"$WLAN_INFO")
WLAN_SUBNET=$(cut -d'|' -f2 <<<"$WLAN_INFO")
WLAN_GW=$(cut -d'|' -f3 <<<"$WLAN_INFO")
ETH_IP=$(cut -d'|' -f1 <<<"$ETH_INFO")
ETH_SUBNET=$(cut -d'|' -f2 <<<"$ETH_INFO")
ETH_GW=$(cut -d'|' -f3 <<<"$ETH_INFO")

if [[ -z "$WLAN_GW" ]]; then
  red "wlan0 has no gateway visible — connect to the hotspot first."
  exit 1
fi
if [[ -z "$ETH_GW" ]]; then
  red "eth0 has no gateway visible — connect to the corp/target network first."
  exit 1
fi

info "wlan0: ip=$WLAN_IP  subnet=$WLAN_SUBNET  gw=$WLAN_GW"
info "eth0:  ip=$ETH_IP   subnet=$ETH_SUBNET   gw=$ETH_GW"

# 4. Verify wlan0 actually reaches the internet (force source via -I)
info "testing wlan0 internet reachability..."
if ! ping -I wlan0 -c 2 -W 2 1.1.1.1 &>/dev/null; then
  red "wlan0 cannot reach 1.1.1.1 — check hotspot. Aborting."
  exit 1
fi
green "wlan0 has internet. proceeding."

# 5. Discover VPN/tunnel endpoints that route via eth0 (need pinning).
#    Must happen BEFORE we snapshot routes or change anything.
VPN_PINNED=()
for tun_if in $(ip -o link show type wireguard 2>/dev/null | awk -F: '{print $2}' | tr -d ' '); do
  while IFS= read -r ep_line; do
    ep_ip=$(echo "$ep_line" | awk '{print $2}' | cut -d: -f1)
    [[ -z "$ep_ip" ]] && continue
    route_dev=$(ip route get "$ep_ip" 2>/dev/null | grep -oP 'dev \K\w+' | head -1)
    if [[ "$route_dev" == "eth0" ]]; then
      VPN_PINNED+=("$ep_ip")
    fi
  done < <(sudo wg show "$tun_if" endpoints 2>/dev/null)
done
# Also check for OpenVPN / any POINTOPOINT interface with a remote endpoint
for tun_if in $(ip -o link show | awk '/POINTOPOINT/ && !/wireguard/' | awk -F: '{print $2}' | tr -d ' '); do
  remote=$(ip -4 addr show dev "$tun_if" 2>/dev/null | awk '/peer/ {print $4}' | cut -d/ -f1)
  [[ -z "$remote" ]] && continue
  route_dev=$(ip route get "$remote" 2>/dev/null | grep -oP 'dev \K\w+' | head -1)
  if [[ "$route_dev" == "eth0" ]]; then
    VPN_PINNED+=("$remote")
  fi
done
# Detect active OpenVPN connections via ss (gets the REAL server endpoint IP,
# not the tunnel peer). Also catches any process with "vpn" in its name.
for conn_ip in $(ss -tunp 2>/dev/null | grep -iE 'openvpn|vpn' | \
    awk '{print $5}' | grep -oP '[\d.]+(?=:\d+)' | sort -u); do
  [[ -z "$conn_ip" ]] && continue
  printf '%s\n' "${VPN_PINNED[@]}" 2>/dev/null | grep -qx "$conn_ip" && continue
  route_dev=$(ip route get "$conn_ip" 2>/dev/null | grep -oP 'dev \K\w+' | head -1)
  if [[ "$route_dev" == "eth0" ]]; then
    VPN_PINNED+=("$conn_ip")
    info "  detected OpenVPN server endpoint: $conn_ip (via eth0)"
  fi
done

# 6a. Discover NM connection names + snapshot their properties (before state.json)
ETH0_CON=""
WLAN0_CON=""
NM_ETH0_NEVER_DEFAULT=""
NM_ETH0_IPV6_NEVER_DEFAULT=""
NM_ETH0_IGNORE_AUTO_DNS=""
NM_ETH0_IPV6_IGNORE_AUTO_DNS=""
NM_ETH0_DNS=""
NM_ETH0_ROUTE_METRIC=""
NM_WLAN0_NEVER_DEFAULT=""
NM_WLAN0_IPV6_NEVER_DEFAULT=""
NM_WLAN0_ROUTE_METRIC=""
NM_WLAN0_IPV6_ROUTE_METRIC=""
NM_WLAN0_DNS=""
NM_WLAN0_IGNORE_AUTO_DNS=""

if command -v nmcli &>/dev/null; then
  ETH0_CON=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | awk -F: '$2=="eth0"{print $1; exit}')
  WLAN0_CON=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | awk -F: '$2=="wlan0"{print $1; exit}')
  if [[ -n "$ETH0_CON" ]]; then
    NM_ETH0_NEVER_DEFAULT=$(nmcli -g ipv4.never-default con show "$ETH0_CON" 2>/dev/null || true)
    NM_ETH0_IPV6_NEVER_DEFAULT=$(nmcli -g ipv6.never-default con show "$ETH0_CON" 2>/dev/null || true)
    NM_ETH0_IGNORE_AUTO_DNS=$(nmcli -g ipv4.ignore-auto-dns con show "$ETH0_CON" 2>/dev/null || true)
    NM_ETH0_IPV6_IGNORE_AUTO_DNS=$(nmcli -g ipv6.ignore-auto-dns con show "$ETH0_CON" 2>/dev/null || true)
    NM_ETH0_DNS=$(nmcli -g ipv4.dns con show "$ETH0_CON" 2>/dev/null || true)
    NM_ETH0_ROUTE_METRIC=$(nmcli -g ipv4.route-metric con show "$ETH0_CON" 2>/dev/null || true)
    info "  eth0 NM snap: never-default=$NM_ETH0_NEVER_DEFAULT ignore-dns=$NM_ETH0_IGNORE_AUTO_DNS metric=$NM_ETH0_ROUTE_METRIC"
  fi
  if [[ -n "$WLAN0_CON" ]]; then
    NM_WLAN0_NEVER_DEFAULT=$(nmcli -g ipv4.never-default con show "$WLAN0_CON" 2>/dev/null || true)
    NM_WLAN0_IPV6_NEVER_DEFAULT=$(nmcli -g ipv6.never-default con show "$WLAN0_CON" 2>/dev/null || true)
    NM_WLAN0_ROUTE_METRIC=$(nmcli -g ipv4.route-metric con show "$WLAN0_CON" 2>/dev/null || true)
    NM_WLAN0_IPV6_ROUTE_METRIC=$(nmcli -g ipv6.route-metric con show "$WLAN0_CON" 2>/dev/null || true)
    NM_WLAN0_DNS=$(nmcli -g ipv4.dns con show "$WLAN0_CON" 2>/dev/null || true)
    NM_WLAN0_IGNORE_AUTO_DNS=$(nmcli -g ipv4.ignore-auto-dns con show "$WLAN0_CON" 2>/dev/null || true)
    info "  wlan0 NM snap: never-default=$NM_WLAN0_NEVER_DEFAULT metric=$NM_WLAN0_ROUTE_METRIC dns=$NM_WLAN0_DNS"
  fi
fi

# 6b. Snapshot current routing state to JSON for clean revert
info "snapshotting current routing state → $STATE"
{
  echo '{'
  echo "  \"wlan0\": {\"ip\": \"$WLAN_IP\", \"subnet\": \"$WLAN_SUBNET\", \"gw\": \"$WLAN_GW\"},"
  echo "  \"eth0\":  {\"ip\": \"$ETH_IP\",  \"subnet\": \"$ETH_SUBNET\",  \"gw\": \"$ETH_GW\"},"
  echo "  \"guard_chain\": \"DUAL_NIC_GUARD\","
  echo "  \"resolv_backup\": \"/etc/resolv.conf.dual-nic-bak\","
  echo "  \"vpn_pinned\": [$(printf '"%s",' "${VPN_PINNED[@]}" | sed 's/,$//')],"
  echo "  \"nm_eth0_con\": \"$ETH0_CON\","
  echo "  \"nm_wlan0_con\": \"$WLAN0_CON\","
  echo "  \"nm_eth0\": {"
  echo "    \"never_default\": \"$NM_ETH0_NEVER_DEFAULT\","
  echo "    \"ipv6_never_default\": \"$NM_ETH0_IPV6_NEVER_DEFAULT\","
  echo "    \"ignore_auto_dns\": \"$NM_ETH0_IGNORE_AUTO_DNS\","
  echo "    \"ipv6_ignore_auto_dns\": \"$NM_ETH0_IPV6_IGNORE_AUTO_DNS\","
  echo "    \"dns\": \"$NM_ETH0_DNS\","
  echo "    \"route_metric\": \"$NM_ETH0_ROUTE_METRIC\""
  echo "  },"
  echo "  \"nm_wlan0\": {"
  echo "    \"never_default\": \"$NM_WLAN0_NEVER_DEFAULT\","
  echo "    \"ipv6_never_default\": \"$NM_WLAN0_IPV6_NEVER_DEFAULT\","
  echo "    \"route_metric\": \"$NM_WLAN0_ROUTE_METRIC\","
  echo "    \"ipv6_route_metric\": \"$NM_WLAN0_IPV6_ROUTE_METRIC\","
  echo "    \"dns\": \"$NM_WLAN0_DNS\","
  echo "    \"ignore_auto_dns\": \"$NM_WLAN0_IGNORE_AUTO_DNS\""
  echo "  },"
  echo "  \"original_routes\": ["
  ip -4 route show | sed 's/"/\\"/g' | awk '{printf "    \"%s\",\n", $0}' | sed '$ s/,$//'
  echo "  ],"
  echo "  \"switched_at\": \"$(date -Iseconds)\""
  echo '}'
} > "$STATE"

# 7. NM reapply happens next — VPN pinning moved to after step 7b
#    to prevent nmcli dev reapply from removing the /32 routes.
[[ ${#VPN_PINNED[@]} -eq 0 ]] && info "no VPN/tunnel endpoints needed pinning"

# 7b. Tell NetworkManager to stop adding a default route on eth0.
#     This MUST happen BEFORE manual route changes — otherwise
#     `nmcli dev reapply` later will re-add eth0's default and undo
#     our work (root cause of the concurrent-session bottleneck).
#     NM connections already discovered in step 6a.
info "configuring NetworkManager route ownership..."
if command -v nmcli &>/dev/null; then
  # eth0: never install a default route, strip DNS
  if [[ -n "$ETH0_CON" ]]; then
    info "  eth0: never-default=yes, ignore-auto-dns=yes"
    sudo nmcli con mod "$ETH0_CON" ipv4.never-default yes 2>/dev/null || true
    sudo nmcli con mod "$ETH0_CON" ipv6.never-default yes 2>/dev/null || true
    sudo nmcli con mod "$ETH0_CON" ipv4.ignore-auto-dns yes 2>/dev/null || true
    sudo nmcli con mod "$ETH0_CON" ipv6.ignore-auto-dns yes 2>/dev/null || true
    sudo nmcli con mod "$ETH0_CON" ipv4.dns "" 2>/dev/null || true
    sudo nmcli dev reapply eth0 2>/dev/null || true
  fi

  # wlan0: low metric so it wins default route, ensure DNS flows here
  if [[ -n "$WLAN0_CON" ]]; then
    info "  wlan0: route-metric=50, dns=8.8.8.8,1.1.1.1"
    sudo nmcli con mod "$WLAN0_CON" ipv4.never-default no 2>/dev/null || true
    sudo nmcli con mod "$WLAN0_CON" ipv6.never-default no 2>/dev/null || true
    sudo nmcli con mod "$WLAN0_CON" ipv4.route-metric 50 2>/dev/null || true
    sudo nmcli con mod "$WLAN0_CON" ipv6.route-metric 50 2>/dev/null || true
    sudo nmcli con mod "$WLAN0_CON" ipv4.dns "8.8.8.8 1.1.1.1" 2>/dev/null || true
    sudo nmcli con mod "$WLAN0_CON" ipv4.ignore-auto-dns no 2>/dev/null || true
    sudo nmcli dev reapply wlan0 2>/dev/null || true
  fi
fi

# 7c. Pin VPN endpoints to eth0 AFTER NM reapply (reapply can wipe /32 routes).
for vpn_ep in "${VPN_PINNED[@]}"; do
  info "pinning VPN endpoint $vpn_ep → eth0 via $ETH_GW"
  sudo ip route replace "$vpn_ep/32" via "$ETH_GW" dev eth0 2>/dev/null || \
    sudo ip route add "$vpn_ep/32" via "$ETH_GW" dev eth0 2>/dev/null || true
done

# 7c-ii. If Tailscale is running, also pin VPN endpoints in table 52
#        to prevent Tailscale's policy routing from hijacking CGNAT-range
#        VPN endpoints (100.64.0.0/10 overlap).
TS_ACTIVE=false
if ip link show tailscale0 &>/dev/null 2>&1; then
  TS_ACTIVE=true
elif ip rule show 2>/dev/null | grep -q 'lookup 52'; then
  TS_ACTIVE=true
elif ip route show table 52 2>/dev/null | grep -q .; then
  TS_ACTIVE=true
fi
if $TS_ACTIVE; then
  info "Tailscale detected — pinning VPN endpoints in table 52..."
  for vpn_ep in "${VPN_PINNED[@]}"; do
    sudo ip route replace "$vpn_ep/32" via "$ETH_GW" dev eth0 table 52 2>/dev/null || true
    info "  table 52: $vpn_ep → eth0"
  done
fi

# 7d. Clean up any remaining eth0 default routes (safety net after NM reapply)
info "removing any remaining eth0 default routes..."
while ip -4 route show default dev eth0 2>/dev/null | grep -q '.'; do
  sudo ip -4 route del default dev eth0 2>/dev/null || break
done
# Ensure wlan0 has a default route (NM should have added one, but be sure)
if ! ip -4 route show default dev wlan0 2>/dev/null | grep -q '.'; then
  info "adding wlan0 default route (metric 50)..."
  sudo ip -4 route add default via "$WLAN_GW" dev wlan0 metric 50
fi

# 7d. Airtight eth0 egress lockdown — ONLY local-subnet traffic allowed.
#    No DNS, no internet, no AI/LLM traffic can ever leave via eth0.
#    iptables OUTPUT catches packets BEFORE they hit the wire, so a
#    rejected query is invisible to any network sniffer.
info "installing eth0 egress lockdown (iptables + ip6tables)..."

# -- IPv4 guard chain --
sudo iptables -N DUAL_NIC_GUARD 2>/dev/null || sudo iptables -F DUAL_NIC_GUARD
# Insert jump at TOP of OUTPUT so no prior rule can bypass the guard
while sudo iptables -D OUTPUT -o eth0 -m comment --comment "$MARK" -j DUAL_NIC_GUARD 2>/dev/null; do :; done
sudo iptables -I OUTPUT 1 -o eth0 -m comment --comment "$MARK" -j DUAL_NIC_GUARD

# Allow DHCP client → server (so eth0 keeps its lease)
sudo iptables -A DUAL_NIC_GUARD -p udp --sport 68 --dport 67 \
  -m comment --comment "$MARK" -j ACCEPT
# Block ALL name-resolution protocols — nothing resolves over eth0
sudo iptables -A DUAL_NIC_GUARD -p udp --dport 53 \
  -m comment --comment "$MARK" -j REJECT
sudo iptables -A DUAL_NIC_GUARD -p tcp --dport 53 \
  -m comment --comment "$MARK" -j REJECT
sudo iptables -A DUAL_NIC_GUARD -p tcp --dport 853 \
  -m comment --comment "$MARK" -j REJECT
sudo iptables -A DUAL_NIC_GUARD -p udp --dport 5353 \
  -m comment --comment "$MARK" -j REJECT
sudo iptables -A DUAL_NIC_GUARD -p udp --dport 5355 \
  -m comment --comment "$MARK" -j REJECT
# Allow non-DNS traffic to eth0's local subnet (corp/target)
sudo iptables -A DUAL_NIC_GUARD -d "$ETH_SUBNET" \
  -m comment --comment "$MARK" -j ACCEPT
# Allow pinned VPN endpoints (UDP + TCP — WireGuard uses UDP, OpenVPN may use either)
for vpn_ep in "${VPN_PINNED[@]}"; do
  sudo iptables -A DUAL_NIC_GUARD -p udp -d "$vpn_ep/32" \
    -m comment --comment "$MARK" -j ACCEPT
  sudo iptables -A DUAL_NIC_GUARD -p tcp -d "$vpn_ep/32" \
    -m comment --comment "$MARK" -j ACCEPT
done
# REJECT everything else — internet-bound traffic never leaves eth0
sudo iptables -A DUAL_NIC_GUARD \
  -m comment --comment "$MARK" -j REJECT --reject-with icmp-net-unreachable

# -- IPv6 guard chain --
sudo ip6tables -N DUAL_NIC_GUARD 2>/dev/null || sudo ip6tables -F DUAL_NIC_GUARD
while sudo ip6tables -D OUTPUT -o eth0 -m comment --comment "$MARK" -j DUAL_NIC_GUARD 2>/dev/null; do :; done
sudo ip6tables -I OUTPUT 1 -o eth0 -m comment --comment "$MARK" -j DUAL_NIC_GUARD

sudo ip6tables -A DUAL_NIC_GUARD -p udp --sport 546 --dport 547 \
  -m comment --comment "$MARK" -j ACCEPT
sudo ip6tables -A DUAL_NIC_GUARD -p udp --dport 53 \
  -m comment --comment "$MARK" -j REJECT
sudo ip6tables -A DUAL_NIC_GUARD -p tcp --dport 53 \
  -m comment --comment "$MARK" -j REJECT
# Allow only ICMPv6 neighbor discovery (required for IPv6 on the link)
sudo ip6tables -A DUAL_NIC_GUARD -p ipv6-icmp --icmpv6-type neighbor-solicitation \
  -m comment --comment "$MARK" -j ACCEPT
sudo ip6tables -A DUAL_NIC_GUARD -p ipv6-icmp --icmpv6-type neighbor-advertisement \
  -m comment --comment "$MARK" -j ACCEPT
sudo ip6tables -A DUAL_NIC_GUARD \
  -m comment --comment "$MARK" -j REJECT

# 8. Lock down DNS resolver.
#    Layer 1: resolv.conf — remove eth0-routed nameservers
#    Layer 2: NetworkManager — already handled in step 7b (before route changes)
#    Layer 3: iptables (already done above) — safety net
info "sanitizing DNS (resolv.conf)..."
RESOLV_BAK="/etc/resolv.conf.dual-nic-bak"
sudo cp /etc/resolv.conf "$RESOLV_BAK"
REMOVED_NS=()
while IFS= read -r ns; do
  route_dev=$(ip route get "$ns" 2>/dev/null | grep -oP 'dev \K\w+' | head -1)
  if [[ "$route_dev" == "eth0" ]]; then
    info "  removing nameserver $ns (routes via eth0)"
    sudo sed -i "/^nameserver[[:space:]]\+${ns}$/d" /etc/resolv.conf
    REMOVED_NS+=("$ns")
  fi
done < <(awk '/^nameserver/{print $2}' /etc/resolv.conf | grep -v ':')
# Ensure at least one nameserver remains
if ! grep -q '^nameserver' /etc/resolv.conf; then
  info "  no nameservers left — adding 8.8.8.8 (routed via wlan0)"
  echo "nameserver 8.8.8.8" | sudo tee -a /etc/resolv.conf >/dev/null
fi
# Prevent DHCP / NetworkManager from re-adding eth0 DNS during session
sudo chattr +i /etc/resolv.conf 2>/dev/null || true
# resolvectl (if systemd-resolved is active)
if command -v resolvectl &>/dev/null && systemctl is-active systemd-resolved &>/dev/null; then
  info "  configuring systemd-resolved: eth0=no-dns, wlan0=primary"
  sudo resolvectl dns eth0 '' 2>/dev/null || true
  sudo resolvectl domain eth0 '~local' 2>/dev/null || true
  sudo resolvectl dns wlan0 8.8.8.8 1.1.1.1 2>/dev/null || true
  sudo resolvectl default-route eth0 false 2>/dev/null || true
  sudo resolvectl default-route wlan0 true 2>/dev/null || true
fi

# 9. Hard-fail verification — do NOT claim success if routing is wrong
info "verification:"

ROUTE_OK=true
for check_ip in 1.1.1.1 8.8.8.8 140.82.114.21; do
  check_dev=$(ip route get "$check_ip" 2>/dev/null | head -1 | grep -oP 'dev \K\w+')
  if [[ "$check_dev" != "wlan0" ]]; then
    red "  ✗ ROUTE FAIL: $check_ip routes via $check_dev (expected wlan0)"
    ROUTE_OK=false
  else
    printf '  → %s via: %s ✓\n' "$check_ip" "$check_dev"
  fi
done

ETH_TEST_IP=$(echo "$ETH_SUBNET" | sed 's|/.*||' | awk -F. '{printf "%s.%s.%s.1", $1,$2,$3}')
printf '  → %s (corp subnet)               via: %s\n' "$ETH_TEST_IP" \
  "$(ip route get "$ETH_TEST_IP" | head -1 | grep -oP 'dev \K\w+')"
# VPN endpoint verification — must route via eth0, not wlan0
for vpn_ep in "${VPN_PINNED[@]}"; do
  vpn_dev=$(ip route get "$vpn_ep" 2>/dev/null | head -1 | grep -oP 'dev \K\w+')
  if [[ "$vpn_dev" != "eth0" ]]; then
    red "  ✗ VPN ROUTE FAIL: $vpn_ep routes via $vpn_dev (expected eth0)"
    ROUTE_OK=false
  else
    printf '  → %s (VPN endpoint, pinned)      via: %s ✓\n' "$vpn_ep" "$vpn_dev"
  fi
done

# Verify no eth0 default route remains
if ip -4 route show default dev eth0 2>/dev/null | grep -q '.'; then
  red "  ✗ ROUTE FAIL: eth0 still has a default route!"
  ROUTE_OK=false
fi

# DNS leak test — verify each removed nameserver is truly blocked
DNS_LEAK=false
for ns in "${REMOVED_NS[@]}"; do
  if command -v dig &>/dev/null && \
     dig +short +timeout=1 +tries=1 @"$ns" google.com 2>/dev/null | grep -q '.'; then
    red "  ✗ DNS LEAK: query to $ns got through eth0!"
    DNS_LEAK=true
  fi
done
$DNS_LEAK || green "  ✓ DNS blocked on eth0 (all eth0 nameservers rejected)"

# Internet leak test
if ping -I eth0 -c 1 -W 1 1.1.1.1 &>/dev/null; then
  red "  ✗ LEAK: eth0 can still reach the internet!"
  ROUTE_OK=false
else
  green "  ✓ eth0 internet egress blocked"
fi

# Proxy env var check — these can tunnel AI traffic through local subnet
PROXY_LEAK=false
for pvar in HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy; do
  if [[ -n "${!pvar:-}" ]]; then
    red "  ✗ PROXY LEAK RISK: $pvar=${!pvar} — AI traffic could bypass eth0 guard via proxy"
    PROXY_LEAK=true
  fi
done
$PROXY_LEAK && red "  ⚠ Unset proxy vars before using Copilot: unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy"

# Show guard chain for manual audit
info "eth0 guard rules:"
sudo iptables -vnL DUAL_NIC_GUARD 2>/dev/null | sed 's/^/  /'

# HARD FAIL if routing is wrong — the iptables guard prevents leakage,
# but Copilot won't work if traffic routes to eth0 and gets rejected.
if ! $ROUTE_OK; then
  red "ROUTING VERIFICATION FAILED — internet traffic is NOT routing via wlan0."
  red "The iptables guard prevents leakage, but Copilot will not work."
  red "Debug: check 'ip route show' and 'nmcli con show' for conflicting routes."
  exit 1
fi

green "✓ switched. Internet/Copilot via wlan0 only."
green "  eth0 locked down: no DNS, no internet — local subnet only."
green "  Run /home/kali/dual-NIC/revert.sh to restore."
echo ""
info "⚠ If connecting OpenVPN after this, add to your .ovpn config:"
info "    pull-filter ignore redirect-gateway"
info "    pull-filter ignore \"route 0.0.0.0\""
info "    pull-filter ignore \"route 128.0.0.0\""
info "  Then verify after connecting: ip route get 140.82.114.21 (must say wlan0)"
