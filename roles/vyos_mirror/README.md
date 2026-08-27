# vyos_mirror Role

## Description
The router end of the traffic-capture path. Builds a `gretap` tunnel to the
sensor and mirrors selected interfaces into it with `tc mirred`, giving Security
Onion a copy of range traffic without a physical SPAN port.

Two mechanisms, because one is not enough.

## Why Two Mechanisms

**Declarative — the tunnel.** Configured through `vyos.vyos.vyos_config`, so it
lives in the router's running config and survives reboot.

**Imperative — the mirror.** VyOS's `set interfaces ethernet ethX mirror ingress
<iface>` accepts only local physical interfaces, not tunnel interfaces, so
"mirror this interface into a GRE tunnel" cannot be expressed declaratively.
The role installs a script at VyOS's post-config-bootup hook and applies raw
`tc` rules, guarded by a marker file.

## ENCAPSULATION IS `gretap`
`tc mirred` copies whole Ethernet frames. A layer-3 `gre` tunnel presents
`DLT_RAW` and Zeek's AF_PACKET plugin cannot parse a single frame from it —
Suricata tolerates it, which is exactly why the fault stayed hidden while
alerting looked healthy. `gretap` is a layer-2 tunnel and carries the frame
intact. The sensor's netplan `mode:` must match. PORTING_GUIDE 9.15c.

## Variable Definition Location
All of these are per-router and belong in **host_vars/&lt;router&gt;.yml**.

Do **not** set `ansible_connection` there: the role uses two plays with
different connection types, and a host_vars entry would override both.

## Required Variables

### In host_vars/&lt;router&gt;.yml

| Variable | Required | Description |
|----------|----------|-------------|
| vyos_mirror_source_interfaces | Yes | Physical interfaces to mirror. Verify against the live device — blueprint NIC order does not reliably match `ethN` (PORTING_GUIDE 9.9) |
| vyos_gre_source_ip | Yes | Router's tunnel source. The sensor's `so_gre_remote_underlay` must be **this**, not the router's LAN address |
| vyos_gre_remote_ip | Yes | Sensor's underlay address |
| vyos_gre_local_addr | Yes | Router's address inside the tunnel |
| vyos_gre_tunnel_prefix | Yes | Tunnel prefix length |

## Optional Variables

| Variable | Default | Description |
|----------|---------|-------------|
| vyos_gre_tunnel_iface | tun0 | Tunnel interface name |
| vyos_mirror_exclude_cidrs | see defaults | Traffic excluded from mirroring — keeps the mirror from carrying its own tunnel |
| vyos_mirror_script_path | see defaults | Where the tc script is installed |
| vyos_mirror_marker | see defaults | Idempotency marker |

## Verification the Role Performs
Filters are verified on **every** source interface, not just the first. Checking
one and reporting success claims the mirror is configured when it may be
configured on a fifth of the interfaces — one range mirrors five. The script
SKIPs an interface that is absent on the device, so a silent partial mirror is a
real outcome, and the sensor's own packet check would still pass on traffic from
the one working link.

## Complete Example Configuration

### host_vars/pp-internal-router.yml
```yaml
vyos_mirror_source_interfaces:
  - eth1
  - eth2
vyos_gre_source_ip:    "172.16.0.41"
vyos_gre_remote_ip:    "172.16.9.40"
vyos_gre_local_addr:   "10.100.0.1"
vyos_gre_tunnel_prefix: 30
```
