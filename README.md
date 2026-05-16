# dual-NIC

Airtight traffic isolation for on-site pentesting with AI/LLM tools.

Two NICs, two purposes: **eth0** connects to the corp/target intranet (where
AI traffic must be invisible), **wlan0** (USB WiFi → phone hotspot) carries
all internet/Copilot/LLM traffic. A network sniffer on the corp side will
never see a DNS query or TLS handshake to any AI provider.

## Network Topology

```
┌──────────────────────────────────────────────────────────────────┐
│  Kali VM (VMware guest)                                          │
│                                                                  │
│  eth0 ─── VMware NAT ─── Laptop ─── Corp Intranet               │
│    192.168.203.x/24                    10.x.x.x / etc            │
│    (targets, OpenVPN server)                                     │
│                                                                  │
│  wlan0 ── USB WiFi ── Phone Hotspot ── Public Internet           │
│    192.168.0.x/24                      ☁ GitHub/Copilot          │
│                                        ☁ Tailscale (SSH)         │
│                                                                  │
│  tailscale0 ── Tailscale mesh ── Remote server (100.104.9.121)   │
│    100.x.x.x        (underlay via wlan0)                         │
│                                                                  │
│  tun0 ── OpenVPN ── Corp internal (10.x.x.x)                    │
│    10.x.x.x         (server on local subnet via eth0)            │
└──────────────────────────────────────────────────────────────────┘
```

## Game-Day Flow

This is the step-by-step procedure for on-site engagements.

### Step 1: Boot & Connect Networks

```bash
# eth0 should auto-connect to corp network via VMware NAT
# Plug in USB WiFi, connect to phone hotspot
# Tailscale daemon starts on boot (tailscaled.service)
```

### Step 2: Activate Isolation

**Close all AI/Copilot tools first** — pre-existing TCP connections will
leave residual inbound retransmits visible on eth0 until they time out.

```bash
cd /home/kali/dual-NIC
sudo ./switch.sh
```

switch.sh will:
- Lock eth0 to local subnet only (iptables guard)
- Route all internet traffic via wlan0
- Block all DNS on eth0
- Tailscale reconnects automatically via wlan0

### Step 3: Verify

```bash
# Tailscale (remote server via wlan0)
tailscale status
ip route get 100.104.9.121        # → dev tailscale0 ✓
ssh user@100.104.9.121            # works via wlan0 ✓

# AI/Copilot (via wlan0)
ip route get 140.82.114.21        # → dev wlan0 ✓

# Corp subnet (via eth0)
ip route get 192.168.203.1        # → dev eth0 ✓

# Guard active
sudo iptables -vnL DUAL_NIC_GUARD
```

### Step 4: Start AI Tools

```bash
copilot
# or: agent, solve3, solve4, etc.
# Multiple concurrent sessions work fine
```

### Step 5: Connect Org VPN (when you receive the .ovpn config)

```bash
# If you received separate cert/key files, put them with the .ovpn:
chmod 600 *.key *.pem 2>/dev/null

# Connect with certificate/PEM auth:
./vpn-connect.sh corp.ovpn

# Connect with username/password auth:
echo 'myusername' > creds.txt
echo 'mypassword' >> creds.txt
chmod 600 creds.txt
./vpn-connect.sh corp.ovpn --auth-user-pass creds.txt

# Delete creds.txt after the competition!
```

Auth methods:
- **Certificate/PEM only** — `./vpn-connect.sh corp.ovpn` (certs referenced in .ovpn)
- **Username/password** — `./vpn-connect.sh corp.ovpn --auth-user-pass creds.txt`
- **Cert + password** — same as above, both work together

> If the .ovpn has bare `auth-user-pass` without a file, the script will
> refuse to start and tell you to create creds.txt.

vpn-connect.sh will:
- Scan the .ovpn for dangerous directives (redirect-gateway, broad routes)
- Block server-pushed redirect-gateway via pull-filter
- Wait for tunnel to come up
- Verify Copilot traffic still routes via wlan0
- **Auto-kill OpenVPN if ANY verification fails** (fail-closed)

### Step 6: Use Internal Targets

```bash
# SSH into internal servers through the VPN tunnel
ssh user@10.x.x.x                # → via tun0 (OpenVPN) ✓

# Copilot still works via wlan0 (unaffected)
# Remote server still works via Tailscale (unaffected)
```

### Step 7: Disconnect & Revert

```bash
# Disconnect OpenVPN first
./vpn-connect.sh --disconnect

# Revert networking to normal
sudo ./revert.sh
```

## Traffic Routing Summary

| Destination                     | Interface  | Path                              |
|---------------------------------|------------|-----------------------------------|
| `api.githubcopilot.com`         | wlan0      | Hotspot → internet                |
| `api.github.com`                | wlan0      | Hotspot → internet                |
| `1.1.1.1`, `8.8.8.8` (DNS)     | wlan0      | Hotspot → internet                |
| Remote server `100.104.9.121`   | tailscale0 | Underlay via wlan0 → Tailscale    |
| Corp subnet `192.168.203.x`    | eth0       | Direct, local subnet              |
| OpenVPN server `192.168.203.x` | eth0       | Direct, allowed by guard          |
| Internal targets `10.x.x.x`    | tun0       | Encrypted → OpenVPN server → eth0 |

## What `switch.sh` Does

1. **Pre-flight checks** — both `wlan0` and `eth0` must be UP with IPv4 +
   gateway. Refuses to run if either is missing.

2. **Internet verification** — pings `1.1.1.1` via wlan0 to confirm the
   hotspot actually has connectivity.

3. **VPN endpoint discovery** — auto-detects WireGuard and OpenVPN endpoints
   and pins them with `/32` host routes via eth0 so VPN tunnels survive the
   default route change. Also detects active OpenVPN connections via `ss`.

4. **NetworkManager lockdown**:
   - Sets `ipv4.never-default yes` on eth0 (prevents NM from re-adding
     eth0's default route on DHCP renewal or `nmcli dev reapply`).
   - Sets `ipv4.ignore-auto-dns yes` on eth0 (prevents corp DNS injection).
   - Sets `ipv4.route-metric 50` on wlan0 (ensures wlan0 wins default).
   - Snapshots all original NM properties to `state.json` for exact restore.

5. **Route cleanup** — removes all eth0 default routes (IPv4 + IPv6), adds
   `default via <wlan_gw> dev wlan0 metric 50`.

6. **`DUAL_NIC_GUARD` iptables chain** (OUTPUT on eth0):
   - **DHCP** — ACCEPT (ports 67/68 UDP, keeps eth0 lease alive)
   - **DNS** — REJECT all DNS traffic (UDP/TCP 53, DoT 853, mDNS 5353,
     LLMNR 5355). No resolver query for any AI domain ever touches eth0.
   - **Local subnet** — ACCEPT (corp/target traffic flows normally)
   - **VPN endpoint** — ACCEPT UDP+TCP to pinned VPN endpoints
   - **Everything else** — REJECT with `icmp-net-unreachable`
   - Same policy applied via `ip6tables` for IPv6 (permits ICMPv6 ND only)
   - All rules use REJECT (not DROP) — packets are killed *before* hitting
     the wire, invisible to network sniffers.

7. **Tailscale table 52 handling** — if Tailscale is running, pins VPN
   endpoints in routing table 52 to prevent Tailscale's policy routing
   from hijacking CGNAT-range endpoints.

8. **DNS sanitization** — removes corp nameservers from `/etc/resolv.conf`,
   backs up to `/etc/resolv.conf.dual-nic-bak`, marks immutable (`chattr +i`).

9. **Hard-fail verification** — checks routes, VPN pins, DNS resolution, and
   proxy env vars. Exits non-zero if anything is wrong.

## What `vpn-connect.sh` Does

Safe OpenVPN wrapper that prevents traffic leakage through the VPN tunnel.

```bash
./vpn-connect.sh <config.ovpn> [extra openvpn args...]
./vpn-connect.sh --disconnect
```

1. **Refuses to run** unless `switch.sh` is active.
2. **Scans .ovpn config** for dangerous directives:
   - `redirect-gateway` — would hijack all traffic through VPN
   - `route 0.0.0.0` / `route 128.0.0.0` — broad routes override wlan0
   - `route-ipv6 ::/0` / `route-ipv6 2000::/3` — IPv6 hijack
   - `config <file>` — warns about included configs (not scanned recursively)
3. **Blocks server pushes** via `--pull-filter ignore` for all dangerous options.
4. **Detects interactive auth** — refuses if `auth-user-pass` has no file
   (daemon mode can't prompt).
5. **Detects tunnel** via before/after interface diff (not hardcoded names).
6. **Post-connect verification**:
   - wlan0 default route intact
   - No redirect-gateway routes (0.0.0.0/1, 128.0.0.0/1)
   - No IPv6 default route hijack
   - Copilot IPs still route via wlan0
   - eth0 iptables guard still active
7. **Auto-kills OpenVPN** if any verification fails (fail-closed).

### OpenVPN Cert/Key Files

OpenVPN configs often reference external certificate files:

```
ca ca.crt
cert client.crt
key client.key
tls-auth ta.key 1
```

Or use inline certs (everything in one `.ovpn` file):

```
<ca>
-----BEGIN CERTIFICATE-----
...
</ca>
```

Both work. For external files:
- Put `.crt`, `.key`, `.pem` files in the same directory as the `.ovpn`
- Or use absolute paths in the config
- Lock permissions: `chmod 600 *.key *.pem`

## What `revert.sh` Does

1. Flushes and deletes `DUAL_NIC_GUARD` chain (iptables + ip6tables).
2. Restores `/etc/resolv.conf` from backup (removes `chattr +i` first).
3. Restores all NM properties from per-property snapshots in `state.json`
   (never-default, ignore-auto-dns, route-metric, dns — both IPv4 and IPv6).
4. Removes VPN pinned `/32` routes (main table + table 52).
5. Restores default routes (eth0 metric 100, wlan0 metric 600).
6. Archives `state.json` → `state.json.<timestamp>.bak`.

## Tailscale Setup

Tailscale is installed as a systemd service and starts on boot. It provides
SSH access to the remote server (100.104.9.121) via the Tailscale mesh,
with all traffic routed through wlan0 (phone hotspot).

### First-time Setup

```bash
sudo apt install tailscale
sudo systemctl enable --now tailscaled
sudo tailscale up \
  --accept-routes=false \
  --accept-dns=false \
  --ssh=false \
  --shields-up \
  --netfilter-mode=off
# Authenticate via the URL printed
```

Flags explained:
- `--accept-routes=false` — don't import subnet routes (avoids conflicts)
- `--accept-dns=false` — preserve DNS isolation from switch.sh
- `--ssh=false` — don't expose Kali as an SSH target
- `--shields-up` — block unsolicited inbound connections
- `--netfilter-mode=off` — don't add iptables rules (avoids conflict with guard)

### After switch.sh

Tailscale reconnects automatically via wlan0. The underlay (encrypted
Tailscale traffic to DERP relays / direct peers) follows the default route
which is now wlan0. Corp network never sees Tailscale traffic.

## Concurrent Copilot Sessions

Multiple concurrent Copilot CLI sessions work correctly when switched.
A previous bug caused sessions to fail with "transient API error" — this
was traced to NetworkManager re-adding eth0's default route during
`nmcli dev reapply`, causing traffic to route to eth0 where the iptables
guard REJECTed it. Fixed by setting `ipv4.never-default yes` on eth0
*before* any route changes.

### Validated Performance (4 concurrent sessions)

```
curl[1]: HTTP 200 in 203ms
curl[2]: HTTP 200 in 203ms
curl[3]: HTTP 200 in 203ms
curl[4]: HTTP 200 in 138ms
DNS resolution: 43-315ms (no 5s outliers)
```

## Packet-Level Validation Results

Validated with `test-switch.sh` capturing on both interfaces:

| Check                                      | Result |
|--------------------------------------------|--------|
| eth0 default route after switch            | ✅ None |
| wlan0 default route metric                 | ✅ 50   |
| Copilot API route via wlan0                | ✅ Confirmed |
| **Outbound TLS on eth0 after switch**      | **✅ ZERO** |
| **DNS on eth0 after switch**               | **✅ ZERO** |
| Outbound TLS on wlan0                      | ✅ 251 packets |
| DNS on wlan0                               | ✅ 126 packets |
| Concurrent HTTPS (4 sessions)              | ✅ All HTTP 200 |
| Concurrent DNS (5 lookups)                 | ✅ All resolved (62-100ms) |
| IPv6 probes on eth0                        | ✅ Blocked (9 REJECTs) |
| iptables guard catch-all REJECTs           | ✅ 1 packet |
| Revert + route restoration                 | ✅ Clean |

## Safety / Failure Modes

- **Already switched** — refuses if `state.json` exists. Run `revert.sh` first.
- **No wlan0 internet** — refuses. You'd otherwise lose connectivity entirely.
- **No eth0 connection** — refuses. No point scoping a missing network.
- **Tagged rules** — all iptables rules carry comment `dual-nic-switch`.
  `revert.sh` removes only those, leaving other firewall rules untouched.
- **resolv.conf protection** — backed up before modification, restored on
  revert. `chattr +i` prevents DHCP from overwriting during the session.
- **Hard-fail verification** — `switch.sh` exits non-zero if routes, VPN
  pins, or DNS are misconfigured after applying changes.
- **vpn-connect.sh fail-closed** — auto-kills OpenVPN if post-connect
  verification fails. No leakage possible.
- **Partial failure recovery** — `revert.sh` works even if `switch.sh`
  failed partway through (unconditionally removes chains, restores resolv.conf).

## Known Caveats

- **Corp DNS is blocked** — you cannot resolve corp hostnames via DNS while
  switched. Use IP addresses directly, or add entries to `/etc/hosts` before
  switching. VPN-pushed DNS servers (10.x.x.x) route through tun0, not eth0,
  but resolv.conf is locked — use `dig @10.x.x.1 hostname.corp.local` for
  manual lookups.
- **Proxy env vars** — if `HTTP_PROXY`/`HTTPS_PROXY` point to a corp proxy,
  AI traffic could tunnel through the local subnet. `switch.sh` warns if
  these are set. Unset them before using Copilot.
- **Docker/container traffic** — uses the FORWARD chain, not OUTPUT. The
  guard does not protect container egress. If running AI tools in containers,
  add FORWARD chain rules manually.
- **DHCP/NM drift** — during very long sessions, DHCP renewals or NM
  reconnects could theoretically alter routing. The `never-default` NM
  property prevents the most common case. Monitor with
  `ip route | grep default` periodically.
- **wlan0 drops** — if the hotspot disconnects, the iptables guard still
  blocks eth0 internet traffic (fail-closed). AI tools will fail rather
  than leak.
- **OpenVPN redirect-gateway** — if the org's .ovpn config or server pushes
  redirect-gateway, it would route all traffic through the VPN, including
  AI traffic. `vpn-connect.sh` blocks this with pull-filter and config
  scanning. Do NOT connect OpenVPN manually — always use the wrapper.

## Sanity-check While Switched

```bash
# Confirm eth0 is silent for all internet traffic
sudo tcpdump -ni eth0 'udp port 53 or tcp port 53 or tcp port 443 or tcp port 80'

# Confirm wlan0 is carrying AI traffic
sudo tcpdump -ni wlan0 'port 443'

# Check guard counters (DNS/catch-all should stay near zero)
sudo iptables -vnL DUAL_NIC_GUARD

# Verify route decisions
ip route get 140.82.114.21    # → wlan0 (Copilot)
ip route get 192.168.203.1    # → eth0 (corp)
ip route get 100.104.9.121    # → tailscale0 (remote server)
tailscale status              # → connected
```

## Files

| File              | Purpose                                              |
|-------------------|------------------------------------------------------|
| `switch.sh`       | Activates dual-NIC isolation                         |
| `revert.sh`       | Reverts to normal networking                         |
| `vpn-connect.sh`  | Safe OpenVPN wrapper (connect/disconnect)             |
| `test-switch.sh`  | Automated test: switch → capture → verify → revert   |
| `state.json`      | Runtime state (created by switch, consumed by revert) |
| `logs/`           | VPN connection logs (created by vpn-connect.sh)       |
| `README.md`       | This file                                            |

## Requires

- `sudo` (passwordless recommended, or you'll be prompted)
- `iptables` / `ip6tables` (legacy, not nftables — kali default)
- `ip` from iproute2
- `nmcli` (NetworkManager CLI)
- `python3` (for parsing state.json in revert.sh)
- `tailscale` (for remote server SSH access)
- `openvpn` (for org internal network access)
- `tcpdump` (for manual verification / test script)
