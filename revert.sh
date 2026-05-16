#!/usr/bin/env bash
# Revert dual-NIC switch. Restores the default route to whatever was
# captured in state.json (eth0 / VMware NAT under normal conditions),
# and removes the iptables guard rules.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$DIR/state.json"
MARK="dual-nic-switch"

red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m[*]\033[0m %s\n' "$*"; }

if [[ ! -f "$STATE" ]]; then
  red "$STATE not found — nothing to revert (or already reverted)."
  exit 1
fi

ETH_GW=$(python3 -c "import json; print(json.load(open('$STATE'))['eth0']['gw'])")
WLAN_GW=$(python3 -c "import json; print(json.load(open('$STATE'))['wlan0']['gw'])")
VPN_PINNED=$(python3 -c "import json; d=json.load(open('$STATE')); print(' '.join(d.get('vpn_pinned',[])))" 2>/dev/null || true)
info "captured: eth0_gw=$ETH_GW wlan0_gw=$WLAN_GW vpn_pinned=$VPN_PINNED"

# 1. Remove iptables/ip6tables guard chain
info "removing eth0 egress lockdown..."

# IPv4: remove jump rule(s), flush & delete chain
while sudo iptables -D OUTPUT -o eth0 -m comment --comment "$MARK" -j DUAL_NIC_GUARD 2>/dev/null; do :; done
sudo iptables -F DUAL_NIC_GUARD 2>/dev/null || true
sudo iptables -X DUAL_NIC_GUARD 2>/dev/null || true

# IPv6: same
while sudo ip6tables -D OUTPUT -o eth0 -m comment --comment "$MARK" -j DUAL_NIC_GUARD 2>/dev/null; do :; done
sudo ip6tables -F DUAL_NIC_GUARD 2>/dev/null || true
sudo ip6tables -X DUAL_NIC_GUARD 2>/dev/null || true

# Clean up legacy per-IP rules (from older script versions)
mapfile -t LINES < <(sudo iptables -L OUTPUT -n --line-numbers 2>/dev/null \
  | awk -v mark="$MARK" '$0 ~ mark {print $1}' | sort -rn)
for ln in "${LINES[@]}"; do
  sudo iptables -D OUTPUT "$ln" 2>/dev/null || true
done

# 1b. Restore DNS at all levels
sudo chattr -i /etc/resolv.conf 2>/dev/null || true
if [[ -f /etc/resolv.conf.dual-nic-bak ]]; then
  info "restoring /etc/resolv.conf from backup..."
  sudo cp /etc/resolv.conf.dual-nic-bak /etc/resolv.conf
  sudo rm -f /etc/resolv.conf.dual-nic-bak
fi

# Restore NetworkManager settings from state.json snapshots
if command -v nmcli &>/dev/null; then
  ETH0_CON=$(python3 -c "import json; print(json.load(open('$STATE')).get('nm_eth0_con',''))" 2>/dev/null || true)
  WLAN0_CON=$(python3 -c "import json; print(json.load(open('$STATE')).get('nm_wlan0_con',''))" 2>/dev/null || true)

  # Fallback: discover active connections if state.json didn't have them
  [[ -z "$ETH0_CON" ]] && ETH0_CON=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | awk -F: '$2=="eth0"{print $1; exit}')
  [[ -z "$WLAN0_CON" ]] && WLAN0_CON=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | awk -F: '$2=="wlan0"{print $1; exit}')

  if [[ -n "$ETH0_CON" ]]; then
    info "restoring NM settings on eth0 connection '$ETH0_CON'..."
    # Read original values from state.json
    E_ND=$(python3 -c "import json; print(json.load(open('$STATE')).get('nm_eth0',{}).get('never_default','no'))" 2>/dev/null || echo "no")
    E_IND6=$(python3 -c "import json; print(json.load(open('$STATE')).get('nm_eth0',{}).get('ipv6_never_default','no'))" 2>/dev/null || echo "no")
    E_IAD=$(python3 -c "import json; print(json.load(open('$STATE')).get('nm_eth0',{}).get('ignore_auto_dns','no'))" 2>/dev/null || echo "no")
    E_IAD6=$(python3 -c "import json; print(json.load(open('$STATE')).get('nm_eth0',{}).get('ipv6_ignore_auto_dns','no'))" 2>/dev/null || echo "no")
    E_DNS=$(python3 -c "import json; print(json.load(open('$STATE')).get('nm_eth0',{}).get('dns',''))" 2>/dev/null || echo "")
    E_RM=$(python3 -c "import json; print(json.load(open('$STATE')).get('nm_eth0',{}).get('route_metric',''))" 2>/dev/null || echo "")
    sudo nmcli con mod "$ETH0_CON" ipv4.never-default "$E_ND" 2>/dev/null || true
    sudo nmcli con mod "$ETH0_CON" ipv6.never-default "$E_IND6" 2>/dev/null || true
    sudo nmcli con mod "$ETH0_CON" ipv4.ignore-auto-dns "$E_IAD" 2>/dev/null || true
    sudo nmcli con mod "$ETH0_CON" ipv6.ignore-auto-dns "$E_IAD6" 2>/dev/null || true
    sudo nmcli con mod "$ETH0_CON" ipv4.dns "$E_DNS" 2>/dev/null || true
    [[ -n "$E_RM" ]] && sudo nmcli con mod "$ETH0_CON" ipv4.route-metric "$E_RM" 2>/dev/null || true
    sudo nmcli dev reapply eth0 2>/dev/null || true
  fi
  if [[ -n "$WLAN0_CON" ]]; then
    info "restoring NM settings on wlan0 connection '$WLAN0_CON'..."
    W_ND=$(python3 -c "import json; print(json.load(open('$STATE')).get('nm_wlan0',{}).get('never_default','no'))" 2>/dev/null || echo "no")
    W_IND6=$(python3 -c "import json; print(json.load(open('$STATE')).get('nm_wlan0',{}).get('ipv6_never_default','no'))" 2>/dev/null || echo "no")
    W_RM=$(python3 -c "import json; print(json.load(open('$STATE')).get('nm_wlan0',{}).get('route_metric',''))" 2>/dev/null || echo "")
    W_RM6=$(python3 -c "import json; print(json.load(open('$STATE')).get('nm_wlan0',{}).get('ipv6_route_metric',''))" 2>/dev/null || echo "")
    W_DNS=$(python3 -c "import json; print(json.load(open('$STATE')).get('nm_wlan0',{}).get('dns',''))" 2>/dev/null || echo "")
    W_IAD=$(python3 -c "import json; print(json.load(open('$STATE')).get('nm_wlan0',{}).get('ignore_auto_dns','no'))" 2>/dev/null || echo "no")
    sudo nmcli con mod "$WLAN0_CON" ipv4.never-default "$W_ND" 2>/dev/null || true
    sudo nmcli con mod "$WLAN0_CON" ipv6.never-default "$W_IND6" 2>/dev/null || true
    [[ -n "$W_RM" ]] && sudo nmcli con mod "$WLAN0_CON" ipv4.route-metric "$W_RM" 2>/dev/null || true
    [[ -n "$W_RM6" ]] && sudo nmcli con mod "$WLAN0_CON" ipv6.route-metric "$W_RM6" 2>/dev/null || true
    sudo nmcli con mod "$WLAN0_CON" ipv4.dns "$W_DNS" 2>/dev/null || true
    sudo nmcli con mod "$WLAN0_CON" ipv4.ignore-auto-dns "$W_IAD" 2>/dev/null || true
    sudo nmcli dev reapply wlan0 2>/dev/null || true
  fi
fi
# Restore systemd-resolved if active
if command -v resolvectl &>/dev/null && systemctl is-active systemd-resolved &>/dev/null; then
  sudo resolvectl revert eth0 2>/dev/null || true
  sudo resolvectl revert wlan0 2>/dev/null || true
fi

# 1c. Remove pinned VPN endpoint routes (no longer needed once default is back)
for vpn_ep in $VPN_PINNED; do
  sudo ip route del "$vpn_ep/32" via "$ETH_GW" dev eth0 2>/dev/null || true
  sudo ip route del "$vpn_ep/32" via "$ETH_GW" dev eth0 table 52 2>/dev/null || true
done

# 2. Remove all default routes, restore eth0 default with original metric
info "removing current default routes..."
while [[ -n "$(ip -4 route show default)" ]]; do
  sudo ip -4 route del default || break
done

info "restoring default via eth0 ($ETH_GW)..."
sudo ip -4 route add default via "$ETH_GW" dev eth0 metric 100

# 3. Optional: also re-add wlan0 default at higher metric (matches default
#    NetworkManager behaviour where two connections coexist with eth0 winning)
info "re-adding wlan0 default at higher metric (600) for fallback..."
sudo ip -4 route add default via "$WLAN_GW" dev wlan0 metric 600 2>/dev/null || true

# 4. Verification
info "verification:"
printf '  → 1.1.1.1                 via: %s\n' "$(ip route get 1.1.1.1 | head -1 | grep -oP 'dev \K\w+')"
printf '  → api.githubcopilot.com   via: %s\n' "$(ip route get 140.82.114.21 | head -1 | grep -oP 'dev \K\w+')"

# 5. Archive state.json so it doesn't block re-running switch
mv "$STATE" "$STATE.$(date +%s).bak"

green "✓ reverted. Default route is back on eth0 (VMware NAT / normal)."
green "  state file archived → $STATE.*.bak"
