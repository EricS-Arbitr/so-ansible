# so_sensor Role

## Description
Installs a Security Onion **sensor** node, brings up the sensor end of the
mirror tunnel, and binds Suricata and Zeek to it. The sensor sees range traffic
only through that tunnel — the router copies frames into it with `tc mirred`
(see `vyos_mirror`), so if the tunnel is wrong the sensor is silently blind
while every service reports healthy.

## THE TUNNEL IS `gretap`, NOT `gre`
This is the single most consequential fact about the role.

`tc mirred` copies whole **Ethernet frames**. A plain `gre` tunnel is a layer-3
device: it presents `DLT_RAW`, delivering IP with no Ethernet header. Suricata
tolerates that, which is why alerting worked and hid the fault for 42 hours —
but Zeek's AF_PACKET plugin expects Ethernet and cannot parse a single frame.
Measured on the same interface and the same traffic:

```
zeek -i tun0              5390 pkts,   0.37% not processed,  583 conn records
zeek -i af_packet::tun0    841 pkts,    100% NOT PROCESSED,     0 conn records
```

The running workers use `af_packet::tun0`. `gretap` carries the Ethernet frame
end to end, so `tun0` is `DLT_EN10MB` and Zeek parses normally. The sensor
template and the router's `encapsulation` must agree — see PORTING_GUIDE 9.15c.

MTU is 1462: 1500 − 20 outer IP − 4 GRE − 14 inner Ethernet. Fourteen bytes less
than the layer-3 tunnel it replaced, because the frame now carries its own L2
header. SO's pillar asks for 9000, which a 1500-byte underlay cannot give.

## A Passive Sensor Must Not Generate Traffic
Mirrored packets arrive on the tunnel carrying **foreign destinations** — a
Splunk indexer, a DC, 8.8.4.4. The kernel treats them as routable, they fall
through SO's `-A FORWARD -j REJECT --reject-with icmp-host-prohibited`, and the
sensor emits an ICMP unreachable **to the original sender from its own
production IP**:

```
IP 172.16.9.40 > 172.16.3.5: ICMP host 172.16.9.20 unreachable - admin prohibited
```

A workstation mid-conversation with Splunk is told by a machine it never
contacted that Splunk is down. It also feeds back: those ICMPs egress the
production NIC, get mirrored, and return. The role injects a `DROP` matched on
the **input interface**, so it cannot affect anything but mirrored traffic, and
fails loudly if SO's anchor line has moved under an upgrade.

## Variable Definition Location
Range-wide values in **group_vars/all/main.yml**; tunnel endpoints and monitor
interface in **host_vars/&lt;sensor&gt;.yml**.

## Required Variables

### In group_vars/all/main.yml

| Variable | Required | Description |
|----------|----------|-------------|
| so_setup_type, so_address_type | Yes | Install type and addressing mode |
| so_msrv, so_msrv_ip | Yes | Manager hostname and IP for the grid join |

### In host_vars/&lt;sensor&gt;.yml

| Variable | Required | Description |
|----------|----------|-------------|
| so_hostname, so_role | Yes | Node identity |
| so_prod_nic, so_prod_ip, so_prod_netmask, so_prod_gateway, so_prod_dns | Yes | Production addressing |
| so_monitor_interface | Yes | Tunnel interface Suricata and Zeek bind (`BNICS`) |
| so_gre_remote_underlay | Yes | The **router's tunnel source address**, not its LAN address — PORTING_GUIDE 9.10b |
| so_gre_tunnel_local | Yes | Sensor's address inside the tunnel |
| so_gre_tunnel_prefix | Yes | Tunnel prefix length |

## Optional Variables

| Variable | Default | Description |
|----------|---------|-------------|
| so_sensor_force_cloud_mode | true | Stops SO hardcoding `INTERFACE=bond0`. Set false for stock behaviour |
| so_tun_forward_rule | `-A FORWARD -i {{ so_monitor_interface }} -j DROP` | The passive-sensor DROP described above |
| so_tun_forward_anchor | see defaults | SO rule the DROP is inserted before. Re-derive from the rendered ruleset if SO is upgraded |
| so_gre_anchor / so_gre_rule_block / so_gre_sources / so_gre_allowed_source | see defaults | INPUT accepts that let the GRE tunnel reach the sensor at all — SO's firewall drops it otherwise (PORTING_GUIDE 9.1) |
| so_sensor_netplan_tun | /etc/netplan/60-so-mirror-tun.yaml | Netplan drop-in, so the tunnel survives reboot |
| so_sensor_install_timeout / so_sensor_poll_interval | see defaults | Async install wait |

## Sequencing
The tunnel must exist **before** `so-setup` runs: the answer file sets `BNICS`
to the tunnel interface and `so-setup` validates it during install. The role
configures and raises the tunnel in the same play, ahead of the install.

## Verification the Role Performs
"UP" is not proof. On 2026-08-04 a tunnel was UP, PROMISC and carried a valid
/30 while RX sat at zero, because its remote pointed at the wrong router and the
kernel declined to decapsulate. The role therefore asserts the flag list as
whole tokens (`UP` without matching `LOWER_UP`), asserts the tunnel bound the
**correct** remote, and asserts the FORWARD drop is in the running ruleset.

## Privilege
Requires `become: true`, asserted in the first task.

## Depends On
`so_base`, and `vyos_mirror` on the router — the router end must be up before
the sensor sees traffic.

## Complete Example Configuration

### host_vars/so-sensor-corp.yml
```yaml
so_hostname: "so-sensor-corp"
so_role: "sensor"
so_prod_nic: "eth1"
so_prod_ip: "172.16.9.40"
so_prod_netmask: "255.255.255.0"
so_prod_gateway: "172.16.9.1"
so_prod_dns:
  - "172.16.2.7"
so_monitor_interface: "tun0"
so_gre_remote_underlay: "172.16.0.41"   # router's tunnel SOURCE address
so_gre_tunnel_local: "10.100.0.2"
so_gre_tunnel_prefix: 30
```
