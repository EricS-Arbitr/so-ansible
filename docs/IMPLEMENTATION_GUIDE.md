# Deploying Security Onion in Your Range

A build guide for adding a distributed Security Onion 2.4 deployment to a cyber
range using this project's Ansible roles. It assumes you know Ansible and your
own range, and nothing about this project.

Work through it in order. Sections 1–3 are decisions and prerequisites, 4–9 are
the build, 10 is verification.

---

## 1. What you get

A distributed Security Onion grid — one manager, one or more search nodes, one
or more sensors — fed by a GRE tunnel that mirrors router traffic, with
optional Elastic Agent enrolment for endpoints.

| Component | Role | What it does |
|-----------|------|--------------|
| Controller mirror | `so_apt_mirror` | Serves SO install artifacts over HTTP so the SO nodes need no internet |
| Router mirror | `vyos_mirror` | Copies traffic from selected interfaces into a `gretap` tunnel |
| All SO nodes | `so_base` | Packages, proxy, source tree, `/etc/hosts` |
| Manager | `so_manager` | Runs `so-setup`, owns the grid |
| Search node | `so_search` | Joins the manager, stores and searches data |
| Sensor | `so_sensor` | Terminates the mirror tunnel, runs Suricata and Zeek |
| Endpoints | `elastic_agent` | Enrols Windows/Linux hosts into SO's Fleet |

---

## 2. What your range must provide

**Hosts**

- One Ansible controller, Ubuntu, dual-homed (management + production).
- SO nodes on **Ubuntu 22.04**. SO 2.4 rejects other Ubuntu releases outright.
  Size them per Security Onion's own guidance; the roles do not tune hardware.
- At least one VyOS router carrying the traffic you want captured.
- Optionally, Windows/Linux endpoints for agent enrolment.

**Networking**

- Every host reachable by Ansible on a management interface.
- SO nodes on a shared production subnet with the manager routable from
  search and sensor nodes.
- The router must reach the sensor's production IP, and vice versa — the GRE
  tunnel runs between them.

**Egress — read this carefully**

- The **SO nodes need none**. They fetch everything from the controller's
  mirror.
- The **controller needs HTTPS to GitHub, once**, through a management-plane
  proxy. `so_apt_mirror` clones the Security Onion source at a pinned commit.
  Without it the mirror cannot be built and nothing installs.
  If your range has no proxy, pre-seed
  `{{ so_mirror_root }}/so-source/securityonion-<sha12>.tar.gz` by hand; the
  role skips the clone when that file exists.
- **SOC's detection content wants the internet continuously** and cannot be
  fully satisfied offline. Expect recurring failures in SOC's own logs for
  rule/AI-summary updates. This is cosmetic for detection on data you feed it.

**An in-game DNS resolver.** SO nodes must point at a resolver on the
production plane, not a management address. See §6.

---

## 3. Decide your topology first

Write these down before touching a file. Everything else derives from them.

| Decision | Notes |
|----------|-------|
| Manager / search / sensor hostnames and production IPs | Hostnames become part of the salt minion ID |
| Which subnets you want captured | Each becomes mirrored interfaces on a router |
| Which router interfaces face those subnets | Verify on the live device, not the blueprint |
| A spare /30 for each GRE tunnel | Any unused range; router and sensor ends must agree |
| Which subnets may reach the SOC WebUI | Becomes `ALLOW_CIDR` |
| Your in-game DNS server address | |

**Do not mirror the SO nodes' own subnet.** It is noise, and sensor traffic
being mirrored back to the sensor creates a feedback path.

---

## 4. Install collections

```
ansible-galaxy collection install -r requirements.yml
```

`vyos.vyos`, `ansible.netcommon`, `ansible.posix`, `community.general`,
`community.docker`, `ansible.windows`, `community.windows`. The Windows and
`netcommon` ones are needed even in a Linux-only build — the shared `common`
role and the `ipaddr` filter depend on them.

---

## 5. Inventory

Group names are referenced literally by the playbooks. These are not
suggestions.

```ini
[ansible_controller]
ansible ansible_connection=local

[net_vyos]
router-0

[so_manager]
so-manager

[so_search]
so-search

[so_sensor]
so-sensor-1

[so_all:children]
so_manager
so_search
so_sensor

# Only if you are enrolling endpoints
[windows]
[linux]
```

Rules:

- `so_manager` must contain **exactly one** host. Search and sensor nodes join
  it by address taken from this group.
- Multiple search and sensor nodes are fine. Add them to their groups.
- **Do not put the controller or the router in `[linux]`.** The `common` role
  performs a network-stack cutover and reboot; running it on the controller
  severs the play mid-flight, and on VyOS its apt tasks fail outright.

---

## 6. group_vars/all/main.yml

```yaml
# --- Subnets -------------------------------------------------------------
so_subnet_security:  "172.16.9.0/24"      # where the SO nodes live
so_allow_subnets:                          # who may reach the SOC WebUI
  - "{{ so_subnet_security }}"
  - "10.255.240.0/20"

# --- Manager -------------------------------------------------------------
so_manager_ip:       "172.16.9.30"
so_manager_hostname: "so-manager"
so_msrv:             "so-manager"          # what search/sensor join
so_msrv_ip:          "172.16.9.30"

# --- Controller mirror ---------------------------------------------------
so_mirror_host:      "10.255.240.157"      # controller's MANAGEMENT address
so_mirror_root:      /var/www/so-mirror
so_mirror_url:       "http://{{ so_mirror_host }}:{{ so_mirror_port }}"
so_upstream_proxy:   "http://10.255.240.1:3128"

# --- Security Onion version ----------------------------------------------
so_git_repo: "https://github.com/Security-Onion-Solutions/securityonion.git"
so_git_ref:  "55af7eb541f086c4e7d6d3182fb2bc4fbc2b9e21"
so_bundled_rules_filename: "emerging.rules.tar.gz"

# --- Install shape -------------------------------------------------------
so_setup_type:     "DISTRIBUTED"
so_address_type:   "STATIC"
so_web_user:       "onion@yourrange.local"
so_nids:           "SURICATA"
so_rule_set:       "ETOPEN"

# --- Endpoint enrolment (only if using 75-endpoint.yml) ------------------
so_agent_installer_windows: "so-elastic-agent_windows_amd64"
so_agent_installer_linux:   "so-elastic-agent_linux_amd64"
so_defend_exclusions: []
```

`so_mirror_host` is the controller's **management** address. The SO nodes are
dual-homed and reach the mirror over the management plane; the controller has
no production presence.

`so_mirror_root` belongs here, not in the role's defaults — the endpoint
playbook stages installers into that path without including `so_apt_mirror`,
and a role default would resolve to nothing there.

`so_git_ref` must match `SOURCE_SHA.txt` in
`roles/so_base/files/setup-automation-source/`. The role overlays those
snapshotted scripts on top of the cloned source; a mismatch means you are
overlaying one version's scripts onto another's tree.

---

## 7. Vault

```
./vault-tools.sh edit
```

| Key | Used for |
|-----|----------|
| `vault_so_web_password` | SOC WebUI login |
| `vault_so_remote_password` | `SOREMOTEPASS` — how search and sensor nodes join |
| `vault_so_simspace_password` | SSH to the SO Ubuntu nodes |
| `vault_simspace_password` | WinRM to Windows hosts |
| `vault_vyos_password` | VyOS |

Set your own passwords. **Do not reuse this repo's development values in
anything that matters.**

The vault password file lives at `/home/simspace/.vault_pass` on the controller
and `./.vault_pass` locally, both gitignored. **It does not survive a range
rebuild** — recreating it is the most common first-deploy failure.

`vault_so_remote_password` is what makes grid membership automatic. Without it
the search and sensor installs stall waiting for someone to accept them in the
SOC web UI.

---

## 8. host_vars

### Every SO node

```yaml
ansible_host: "10.255.240.100"          # management IP — how Ansible connects
ansible_user: "simspace"
ansible_python_interpreter: "/usr/bin/python3"

so_role:     "manager"                  # manager | searchnode | sensor
so_hostname: "so-manager"
so_prod_ip:      "172.16.9.30"
so_prod_prefix:  24
so_prod_netmask: "255.255.255.0"
so_prod_gateway: "172.16.9.1"
so_prod_nic:     "eth1"
so_prod_dns:                            # IN-GAME resolver, never management
  - "172.16.2.7"

network_interfaces:                     # consumed by the `common` role
  - name: "eth0"
    ipv4: { type: "ethernet", address: "10.255.240.100", netmask: "255.255.240.0", gateway: "" }
  - name: "eth1"
    ipv4: { type: "ethernet", address: "172.16.9.30", netmask: "255.255.255.0", gateway: "172.16.9.1" }
    dns: ["172.16.2.7"]
```

`so_role` values are not free-form. Use `manager`, `searchnode`, or `sensor` —
they become the salt minion ID and must match what `so-setup` registers.

`so_prod_dns` must be a production-plane resolver. Pointing it at the
management plane is tempting because the controller is reachable and already
serves the mirror, but it sends in-game resolution out-of-band. It will not
appear broken: `so_base` writes `/etc/hosts` entries for every peer, so the
grid installs and runs fine with a DNS value that answers nothing — until
something outside `/etc/hosts` needs resolving, and then it fails somewhere
that looks unrelated.

### Sensors, additionally

```yaml
so_monitor_interface:   "tun0"          # what Suricata and Zeek bind
so_gre_tunnel_local:    "10.100.0.2"    # sensor's address inside the tunnel
so_gre_tunnel_prefix:   30
so_gre_remote_underlay: "172.16.0.41"   # the ROUTER'S TUNNEL SOURCE address
```

`so_gre_remote_underlay` is the router's **tunnel source**, which is often not
the router's address on the sensor's subnet. Getting this wrong produces a
tunnel that comes up, shows UP and PROMISC, holds a valid address, and carries
zero packets — the kernel declines to decapsulate and reports nothing.

### The router

```yaml
ansible_host:       "10.255.240.165"
ansible_user:       "vyos"
ansible_password:   "{{ vault_vyos_password }}"
ansible_network_os: "vyos.vyos.vyos"
# Do NOT set ansible_connection here. The mirror role uses two plays with
# different connection types and a host_vars entry overrides both.

vyos_mirror_source_interfaces:          # interfaces to mirror
  - eth1
  - eth2
vyos_gre_source_ip:     "172.16.0.41"   # must equal the sensor's so_gre_remote_underlay
vyos_gre_remote_ip:     "172.16.9.40"   # sensor's production IP
vyos_gre_local_addr:    "10.100.0.1"    # router's address inside the tunnel
vyos_gre_tunnel_prefix: 30
```

**Verify the interface-to-subnet mapping on the live router** with
`show interfaces` before trusting your blueprint. Blueprint NIC order does not
reliably match VyOS's `ethN` numbering, and a mirror pointed at the wrong
interfaces produces no error — just no traffic.

---

## 9. Deploy

```
./deploy.sh
```

Three attempts: full run, then failed hosts only, then a full run again. The
retries are not superstition — several steps depend on state another host
reaches asynchronously, and a first-run failure is often just ordering.

Expect roughly:

| Phase | Duration |
|-------|----------|
| Mirror (first run — clones SO source) | 5–15 min |
| Router mirror | under a minute |
| Node prerequisites | 5 min |
| Manager install | **20–30 min** |
| Each search/sensor install | 5–10 min |

Run it detached — losing your session mid-install is worse than waiting.

To run a single phase:

```
ansible-playbook -i hosts playbooks/40-manager.yml
```

---

## 10. Verify

```
./verify_so.sh
```

Checks management reachability, the mirror, the router's tunnel and mirror
filters, and each node's `so-status`, Elastic cluster membership, and — on
sensors — that packets are actually arriving on the tunnel.

**Confirm the sensor is seeing traffic, not merely that services are running.**
The single most common silent failure is a healthy-looking sensor receiving
nothing:

```
sudo tcpdump -i tun0 -c 20        # packets arriving?
sudo so-status                    # Suricata and Zeek running?
```

Zeek producing zero connection logs while Suricata alerts normally means the
tunnel is carrying the wrong frame type. Both ends must be `gretap`.

---

## 11. Optional: endpoint enrolment

```
ansible-playbook -i hosts playbooks/75-endpoint.yml
```

Stages the Elastic Agent installers on the mirror, permits your endpoint
subnets to reach Fleet on the manager, installs and enrols agents, then
verifies enrolment **from Fleet** — an agent whose service is running is not
the same as an agent Fleet knows about.

Not imported by `site.yml`: building the grid and enrolling endpoints are
separate decisions.

---

## 12. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Deploy fails immediately, vault errors | `.vault_pass` missing after a range rebuild | Recreate it on the controller |
| `so_apt_mirror` fails cloning | No proxy egress to GitHub | Fix the proxy, or pre-seed the source tarball |
| Roles fail on permission errors partway through | Play is missing `become: true` | Every role here requires it; each asserts it in its first task |
| Manager install "succeeds" but nothing works | `so-setup` **exits 0 on failure** | Judge by `/opt/so/state/installed` and `so-status`, never by return code |
| Manager install dies partway, repeatably | `async:` timeout shorter than the install | Raise `so_manager_install_timeout` |
| Search/sensor install hangs at the join | `SOREMOTEPASS` not set | Set `vault_so_remote_password` |
| Node cannot reach salt on 4505/4506 | Manager's firewall does not list it | Re-run the node's play; it re-asserts the manager-side entry |
| Sensor healthy, Suricata alerting, **Zeek has zero connection logs** | Tunnel is `gre`, not `gretap` | Both ends must be `gretap`; Zeek's AF_PACKET needs Ethernet frames |
| Tunnel UP, PROMISC, valid address, zero packets | `so_gre_remote_underlay` points at the wrong router address | Use the router's tunnel **source** address |
| Mirror configured but only some traffic captured | Some source interfaces absent on the device | Check `show interfaces`; the tc script skips missing ones |
| Sensor emits ICMP unreachables to hosts across the range | Mirrored traffic being forwarded | The FORWARD drop is missing — check `so_tun_forward_anchor` still matches SO's ruleset |
| Windows hosts on a subnet suddenly unreachable off-subnet, gateway still pings | Forged gateway ARP entry — it answers ICMP | `Remove-NetNeighbor -IPAddress <gateway>`; compare against the router's real MAC |
| SOC logs constant failures fetching rules | No internet, by design | Cosmetic; detection on ingested data is unaffected |

---

## 13. Where else to look

- `roles/<role>/README.md` — per-role variables and behaviour.
- `docs/PORTING_GUIDE.md` — the same ground with the full history, measurements
  and rationale behind each decision. Read it when this guide tells you to do
  something and you want to know why, or when something fails in a way this
  guide does not cover.
