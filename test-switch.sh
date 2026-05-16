#!/usr/bin/env bash
# Automated test: switch → diagnose → concurrent sessions → revert
# All output saved to ./test-results.log so nothing is lost if sessions drop.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$DIR/test-results.log"
PCAP_ETH0="$DIR/capture-eth0.pcap"
PCAP_WLAN0="$DIR/capture-wlan0.pcap"

ts() { date '+%H:%M:%S'; }
log() { printf '[%s] %s\n' "$(ts)" "$*" | tee -a "$LOG"; }
sep() { printf '\n%s\n' "======== $1 ========" | tee -a "$LOG"; }

: > "$LOG"
log "test-switch.sh starting"

cleanup() {
  log "cleanup: killing captures..."
  [[ -n "${TCPDUMP_ETH0_PID:-}" ]] && kill "$TCPDUMP_ETH0_PID" 2>/dev/null && wait "$TCPDUMP_ETH0_PID" 2>/dev/null
  [[ -n "${TCPDUMP_WLAN0_PID:-}" ]] && kill "$TCPDUMP_WLAN0_PID" 2>/dev/null && wait "$TCPDUMP_WLAN0_PID" 2>/dev/null
  log "cleanup done"
}
trap cleanup EXIT

# ─── PRE-SWITCH BASELINE ───
sep "1. PRE-SWITCH BASELINE"
log "routes:"
ip route show 2>&1 | tee -a "$LOG"
log "ipv6 routes:"
ip -6 route show 2>&1 | tee -a "$LOG"
log "resolv.conf:"
cat /etc/resolv.conf 2>&1 | tee -a "$LOG"
log "NM dns config:"
nmcli dev show 2>&1 | grep -E 'GENERAL.DEVICE|IP4.DNS|IP6.DNS' | tee -a "$LOG"
log "NM dns= setting:"
NetworkManager --print-config 2>&1 | grep -i '^dns=' | tee -a "$LOG" || echo "(not found)" | tee -a "$LOG"
log "anything listening on port 53?"
ss -lntup 2>&1 | grep -E ':(53|5353)\b' | tee -a "$LOG" || echo "(nothing)" | tee -a "$LOG"

# ─── START PACKET CAPTURES ───
sep "2. STARTING PACKET CAPTURES"
sudo tcpdump -ni eth0 -w "$PCAP_ETH0" 'udp port 53 or tcp port 53 or tcp port 443 or tcp port 80' &
TCPDUMP_ETH0_PID=$!
sudo tcpdump -ni wlan0 -w "$PCAP_WLAN0" 'port 53 or port 443' &
TCPDUMP_WLAN0_PID=$!
sleep 1
log "captures started: eth0=$TCPDUMP_ETH0_PID wlan0=$TCPDUMP_WLAN0_PID"

# ─── SWITCH ───
sep "3. RUNNING switch.sh"
"$DIR/switch.sh" 2>&1 | tee -a "$LOG"
SWITCH_RC=${PIPESTATUS[0]}
log "switch.sh exit code: $SWITCH_RC"
if [[ "$SWITCH_RC" -ne 0 ]]; then
  log "ABORT: switch.sh failed"
  exit 1
fi
sleep 2

# ─── POST-SWITCH DIAGNOSTICS ───
sep "4. POST-SWITCH DIAGNOSTICS"

log "--- IPv4 routes ---"
ip route show 2>&1 | tee -a "$LOG"

log "--- CRITICAL: eth0 default route check ---"
if ip -4 route show default dev eth0 2>/dev/null | grep -q '.'; then
  log "✗ FAIL: eth0 still has a default route!"
else
  log "✓ PASS: eth0 has NO default route"
fi

log "--- CRITICAL: wlan0 default route check ---"
if ip -4 route show default dev wlan0 2>/dev/null | grep -q '.'; then
  log "✓ PASS: wlan0 has a default route"
else
  log "✗ FAIL: wlan0 has NO default route!"
fi

log "--- NM never-default check ---"
ETH0_NM_CON=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | awk -F: '$2=="eth0"{print $1; exit}')
if [[ -n "$ETH0_NM_CON" ]]; then
  nmcli -g ipv4.never-default,ipv6.never-default con show "$ETH0_NM_CON" 2>&1 | tee -a "$LOG"
fi

log "--- IPv6 default route (CRITICAL CHECK) ---"
ip -6 route show default 2>&1 | tee -a "$LOG"
IPV6_DEF=$(ip -6 route show default 2>/dev/null)
if echo "$IPV6_DEF" | grep -q 'eth0'; then
  log "⚠ WARNING: IPv6 default route still goes through eth0!"
else
  log "✓ IPv6 default route does NOT use eth0"
fi

log "--- resolv.conf after switch ---"
cat /etc/resolv.conf 2>&1 | tee -a "$LOG"

log "--- iptables guard counters (before tests) ---"
sudo iptables -vnL DUAL_NIC_GUARD 2>&1 | tee -a "$LOG"
sudo ip6tables -vnL DUAL_NIC_GUARD 2>&1 | tee -a "$LOG"

log "--- DNS resolution timing ---"
for host in api.githubcopilot.com api.github.com copilot-proxy.githubusercontent.com; do
  log "  resolving $host..."
  { time getent hosts "$host" ; } 2>&1 | tee -a "$LOG"
done

log "--- IPv6 AAAA lookup test ---"
dig AAAA api.githubcopilot.com +short +timeout=2 +tries=1 2>&1 | tee -a "$LOG"
log "  route to AAAA (if any):"
AAAA=$(dig AAAA api.githubcopilot.com +short +timeout=2 +tries=1 2>/dev/null | head -1)
if [[ -n "$AAAA" ]]; then
  ip -6 route get "$AAAA" 2>&1 | tee -a "$LOG"
fi

log "--- route to Copilot API ---"
ip route get 140.82.114.21 2>&1 | tee -a "$LOG"

log "--- wlan0 link stats (before concurrency test) ---"
ip -s link show wlan0 2>&1 | tee -a "$LOG"

# ─── CONCURRENT SESSION TEST ───
sep "5. CONCURRENT CURL TEST (4 parallel HTTPS to Copilot API)"

log "launching 4 concurrent curl requests to api.github.com..."
CURL_PIDS=()
CURL_RESULTS="$DIR/.curl-results"
: > "$CURL_RESULTS"
for i in 1 2 3 4; do
  (
    START=$(date +%s%N)
    RESULT=$(curl -4 -s -o /dev/null -w '%{http_code} %{time_total}s %{time_namelookup}s-dns %{time_connect}s-tcp' \
      --connect-timeout 15 --max-time 30 \
      https://api.github.com/ 2>&1)
    END=$(date +%s%N)
    ELAPSED=$(( (END - START) / 1000000 ))
    HTTP_CODE=$(echo "$RESULT" | awk '{print $1}')
    echo "  curl[$i]: ${RESULT} (${ELAPSED}ms total wall)" >> "$LOG"
    echo "  curl[$i]: ${RESULT} (${ELAPSED}ms total wall)"
    echo "$HTTP_CODE" >> "$CURL_RESULTS"
  ) &
  CURL_PIDS+=($!)
done
for pid in "${CURL_PIDS[@]}"; do wait "$pid" 2>/dev/null; done
CURL_OK=$(grep -c '^[23]' "$CURL_RESULTS" 2>/dev/null || echo "0")
CURL_FAIL=$(grep -c '^0' "$CURL_RESULTS" 2>/dev/null || echo "0")
CURL_OK=$(echo "$CURL_OK" | tr -d '[:space:]')
CURL_FAIL=$(echo "$CURL_FAIL" | tr -d '[:space:]')
log "all 4 curls complete: $CURL_OK succeeded, $CURL_FAIL failed (HTTP 000)"
if [[ "$CURL_FAIL" -gt 0 ]]; then
  log "✗ FAIL: $CURL_FAIL curl(s) got HTTP 000 — routing to wlan0 is broken"
else
  log "✓ PASS: all curls got valid HTTP responses via wlan0"
fi
rm -f "$CURL_RESULTS"

log "--- wlan0 link stats (after concurrency test) ---"
ip -s link show wlan0 2>&1 | tee -a "$LOG"

log "--- iptables guard counters (after tests) ---"
sudo iptables -vnL DUAL_NIC_GUARD 2>&1 | tee -a "$LOG"
sudo ip6tables -vnL DUAL_NIC_GUARD 2>&1 | tee -a "$LOG"

# ─── PARALLEL DNS TEST ───
sep "6. PARALLEL DNS RESOLUTION TEST (5 concurrent)"
log "launching 5 concurrent DNS lookups..."
DNS_PIDS=()
for i in 1 2 3 4 5; do
  (
    RESULT=$( { time getent hosts api.githubcopilot.com ; } 2>&1 )
    echo "  dns[$i]: $RESULT" >> "$LOG"
    echo "  dns[$i]: $RESULT"
  ) &
  DNS_PIDS+=($!)
done
for pid in "${DNS_PIDS[@]}"; do wait "$pid" 2>/dev/null; done
log "all 5 DNS lookups complete"

# ─── REVERT ───
sep "7. REVERTING"
"$DIR/revert.sh" 2>&1 | tee -a "$LOG"
log "revert.sh exit code: ${PIPESTATUS[0]}"
sleep 1

# ─── STOP CAPTURES ───
sep "8. STOPPING CAPTURES + ANALYSIS"
kill "$TCPDUMP_ETH0_PID" 2>/dev/null; wait "$TCPDUMP_ETH0_PID" 2>/dev/null || true
kill "$TCPDUMP_WLAN0_PID" 2>/dev/null; wait "$TCPDUMP_WLAN0_PID" 2>/dev/null || true
unset TCPDUMP_ETH0_PID TCPDUMP_WLAN0_PID

sleep 1
log "--- eth0 capture summary (should be EMPTY for DNS/HTTPS) ---"
if [[ ! -f "$PCAP_ETH0" ]]; then
  log "✗ FAIL: eth0 pcap file missing — tcpdump failed to capture!"
  ETH0_DNS="-1"
  ETH0_TLS="-1"
else
  sudo tcpdump -r "$PCAP_ETH0" -n 2>&1 | head -30 | tee -a "$LOG"
  ETH0_DNS=$(sudo tcpdump -r "$PCAP_ETH0" -n 'port 53' 2>/dev/null | wc -l)
  ETH0_TLS=$(sudo tcpdump -r "$PCAP_ETH0" -n 'port 443' 2>/dev/null | wc -l)
fi
log "eth0 packets: DNS=$ETH0_DNS  TLS=$ETH0_TLS"
if [[ "$ETH0_DNS" -eq 0 && "$ETH0_TLS" -eq 0 ]]; then
  log "✓ PASS: zero DNS/TLS leakage on eth0"
elif [[ "$ETH0_DNS" -eq -1 ]]; then
  log "✗ FAIL: cannot verify — eth0 capture was missing"
else
  log "✗ FAIL: DNS=$ETH0_DNS TLS=$ETH0_TLS packets leaked on eth0!"
fi

log "--- wlan0 capture summary (should show DNS + TLS) ---"
WLAN0_DNS=$(sudo tcpdump -r "$PCAP_WLAN0" -n 'port 53' 2>/dev/null | wc -l)
WLAN0_TLS=$(sudo tcpdump -r "$PCAP_WLAN0" -n 'port 443' 2>/dev/null | wc -l)
log "wlan0 packets: DNS=$WLAN0_DNS  TLS=$WLAN0_TLS"

sep "DONE"
log "full results saved to $LOG"
log "pcaps saved to $PCAP_ETH0 and $PCAP_WLAN0"
