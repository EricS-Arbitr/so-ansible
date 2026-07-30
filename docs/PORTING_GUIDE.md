# so-ansible — Porting Guide

**Purpose.** Deploy a distributed Security Onion 2.4.x cluster (manager +
search + sensor) unattended via Ansible into an arbitrary virtual range.

This document is the handoff for doing that in a range **other than** the
scaled-down dev range this project was built in. It assumes you have the
repo and are pointing it at a new blueprint.

Read §9 before your first deploy in a new range. Everything in it is a
failure that cost hours to diagnose and will silently recur.

---

## 1. What this project actually delivers

A `site.yml` that takes fresh VMs to a working, verified SO grid:

| Phase | Playbook | Does |
|---|---|---|
| 00 | `00-setup.yml` | Windows init + adapter rename, `common` baseline on Windows + Linux |
| 10 | `10-mirror.yml` | nginx on the controller serving the pinned SO source + ETOPEN rules |
| 20 | `20-vyos.yml` | Router GRE tunnel + `tc mirred` mirror rules |
| 30 | `30-prereqs.yml` | `so_base` on all SO nodes (proxy, packages, hosts, SO source, docker proxy) |
| 40 | `40-manager.yml` | `so-setup` MANAGER — **must complete before 50** |
| 50 | `50-nodes.yml` | `so-setup` SEARCH + SENSOR, grid-join, firewall |
| 60 | `60-verify.yml` | so-status, Elastic cluster health, sensor pcap flow |

Plus `verify_so.sh` — a standalone 26-check health script.

**End state:** manager with SOC WebUI, search node in a green Elasticsearch
cluster, sensor running Suricata + Zeek against a GRE-mirrored feed.

---

## 2. Porting checklist

Work top to bottom. Each step has a section below.

1. [ ] Confirm the range meets the **topology contract** (§3)
2. [ ] Build the **inventory** with the required groups (§4)
3. [ ] Write **host_vars** for every SO node, the router, every Windows host (§5)
4. [ ] Update **group_vars/all/main.yml** subnets, manager IP, proxy, mirror (§5)
5. [ ] Populate the **vault** (§5.4)
6. [ ] Confirm **collections** install (§6)
7. [ ] Recreate `/home/simspace/.vault_pass` on the controller, contents `simspace1` — **it does not persist between range spin-ups**
8. [ ] `./build_tarball.sh`, commit, push — the controller deploys from the tarball, not a git pull
9. [ ] `sudo ./deploy.sh` — **budget for all three attempts** (see below)
10. [ ] `sudo ./verify_so.sh -v` — expect 26/26

### A fresh range is not a single-pass deploy

Validated 2026-07-29: a from-scratch range succeeded on **attempt 3 of 3**.
That is `deploy.sh`'s retry design working as intended, not a fault. The
manager must complete before search and sensor can join it, grid-join
involves reboots, and salt highstates take 5–15 minutes to settle. Plan on
the better part of a working session, not twenty minutes.

If it fails on attempt 3, that is a real failure worth investigating —
anything before that is normal sequencing.

---

## 3. Topology contract

What the range **must** provide. These are load-bearing; the automation
will fail or silently misbehave without them.

### 3.1 Hosts

| Role | Count | Image family | Notes |
|---|---|---|---|
| Ansible controller | 1 | `RC_NG_Ansible` | Dual-homed: mgmt + an in-game NIC. Also the package mirror. |
| SO manager | 1 | Ubuntu 22.04 (jammy) | 16 vCPU / 32 GB in dev. Salt master + all manager containers. |
| SO search | 1+ | Ubuntu 22.04 | Elasticsearch data node. |
| SO sensor | 1+ | Ubuntu 22.04 | Suricata + Zeek. Needs the mirrored feed. |
| Router | 1 | VyOS | Must be the gateway for every monitored subnet. |
| Windows hosts | 0+ | Win10 / Server 2022 | Optional; baseline only (no AD). |

**Ubuntu 22.04 only.** SO's `so-functions` gates on OS version; we patch it
to accept jammy (see §9.12). Other Ubuntu releases are untested here.

### 3.2 Networking

- **A management plane** every host is reachable on. Ansible connects via
  `ansible_host` = the mgmt IP, never the in-game IP.
- **Mgmt NIC must be first** (`position: FIRST` in a SimSpace blueprint).
  Everything assumes NIC0 = mgmt (`eth0` / `Ethernet0`), NIC1 = production.
- **A security/SOC subnet** holding manager, search and sensor. They must
  reach each other on their production IPs.
- **An egress proxy** for package fetches. SO pulls from
  `packages.securityonion.net`, Docker, Elastic and Ubuntu repos. There is
  no airgap path on Ubuntu (§9.13).
- **Monitored subnets** whose traffic you want captured, each gatewayed by
  the router.

### 3.3 What the range does NOT need to provide

- Mirror/SPAN NICs on the sensor — we build a GRE tunnel instead (§7.3).
- DNS — the SO nodes use `/etc/hosts` entries written by `so_base`.
- NTP — nothing reaches it (§9.14). This has consequences; read that entry.

---

## 4. Inventory contract

Required group names. The playbooks reference these literally.

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

[windows]          # 00-setup.yml targets this
DC01
ops-wks-01

[linux]            # 00-setup.yml targets this
so-manager
so-search
so-sensor-1
```

### Rules

- **`so_manager` must contain exactly one host.** Roles reference
  `groups['so_manager'][0]` for every delegated grid-join task.
- **`[linux]` must NOT contain the controller.** `common` performs a
  systemd-networkd → NetworkManager cutover, overwrites netplan, and
  reboots. Doing that to the box running the play severs the run.
- **`[linux]` must NOT contain the VyOS router.** The apt / NetworkManager
  tasks fail outright on VyOS.
- Multiple search/sensor nodes are supported by the role design (each joins
  the manager independently) but **have never been tested** — dev ran 1+1.

---

## 5. Variable contract

### 5.1 host_vars — SO nodes (required, per host)

```yaml
ansible_host: "10.255.240.100"        # mgmt IP — how Ansible connects
ansible_user: "simspace"
ansible_python_interpreter: "/usr/bin/python3"

so_role: "manager"                    # manager | searchnode | sensor
so_hostname: "so-manager"             # becomes the OS hostname + salt minion id prefix
so_prod_ip: "172.16.5.10"             # in-game IP on the security subnet
so_prod_prefix: 24
so_prod_gateway: "172.16.5.1"
so_prod_dns:
  - "10.255.240.157"

network_interfaces:                   # consumed by the `common` role
  - name: "eth0"
    ipv4: { type: "ethernet", address: "10.255.240.100", netmask: "255.255.240.0", gateway: "" }
  - name: "eth1"
    ipv4: { type: "ethernet", address: "172.16.5.10", netmask: "255.255.255.0", gateway: "172.16.5.1" }
    dns: ["10.255.240.157"]
```

**`so_role` values are not arbitrary** — they become the salt minion id
(`<so_hostname>_<so_role>`) and must match what `so-setup` registers.
Verified working: `manager`, `searchnode`, `sensor`.

### 5.2 host_vars — sensor extras (required)

```yaml
so_gre_tunnel_local: "10.100.0.2"     # sensor end of the GRE tunnel
so_gre_tunnel_remote: "10.100.0.1"    # router end
so_gre_tunnel_prefix: 30
so_monitor_interface: "tun0"          # what Suricata/Zeek bind to
```

The tunnel addresses are arbitrary internal /30s — they only need to be
unused in the range and to match the router's `vyos_gre_*` values.

### 5.3 host_vars — router (required)

```yaml
ansible_host: "10.255.240.165"
ansible_user: "vyos"
ansible_password: "{{ vault_vyos_password }}"
ansible_network_os: "vyos.vyos.vyos"
# Do NOT set ansible_connection here — vyos_mirror uses two plays with
# different connection types and host_vars would override both.

vyos_mirror_source_interfaces:        # interfaces to MIRROR
  - eth0
  - eth1
  - eth2

vyos_gre_source_ip: "172.16.5.1"      # router's IP on the SO subnet
vyos_gre_remote_ip: "172.16.5.20"     # sensor's production IP
vyos_gre_local_addr: "10.100.0.1"
vyos_gre_remote_addr: "10.100.0.2"
vyos_gre_tunnel_prefix: 30
```

**Verify the interface-to-subnet mapping on the live router** with
`show interfaces` before trusting the blueprint. On the dev range the
blueprint order did not match VyOS's `ethN` numbering, and the mirror was
silently pointed at the wrong interfaces for a while (§9.9).

Do **not** mirror the SO subnet itself — it is pure noise and creates a
feedback path.

### 5.4 group_vars/all/main.yml — per-range

```yaml
so_subnet_security:    "172.16.5.0/24"
so_subnet_operations:  "172.16.8.0/24"
so_subnet_engineering: "172.16.6.0/24"
so_subnet_services:    "172.16.7.0/24"

so_allow_subnets:                      # who may reach the SOC WebUI
  - "{{ so_subnet_security }}"
  - "10.255.240.0/20"

so_manager_ip:       "172.16.5.10"
so_manager_hostname: "so-manager"

so_mirror_host:      "10.255.240.157"  # the controller's mgmt IP
so_upstream_proxy:   "http://10.255.240.1:3128"
```

The `so_subnet_*` names are dev-range specific. For a different range,
rename them to match its subnets and update every reference — they are used
in `so_allow_subnets` and in the manager answer file's `ALLOW_CIDR`.

### 5.5 Vault (`group_vars/all/vault.yml`)

| Key | Used for |
|---|---|
| `vault_so_web_password` | SOC WebUI admin login |
| `vault_so_remote_password` | `SOREMOTEPASS` — search/sensor join the manager |
| `vault_so_simspace_password` | SSH to the SO Ubuntu nodes (**short** form) |
| `vault_simspace_password` | WinRM to Windows hosts (**long** form) |
| `vault_vyos_password` | VyOS |

**The Ubuntu and Windows SimSpace images use different passwords.** Keep the
two variables distinct; collapsing them breaks one platform or the other.

Manage with `./vault-tools.sh {view,edit,rekey,check}`.

**Dev vault password: `simspace1`** (rekeyed 2026-07-29). The password file
lives at `/home/simspace/.vault_pass` on the controller and `./.vault_pass`
locally; both are gitignored. It does **not** survive a range spin-up —
recreating it is checklist step 7, and forgetting it is the single most
common first-deploy failure. Rotate before any customer range.

### 5.6 Fixed — do not change when porting

| Variable | Why |
|---|---|
| `so_git_ref` / `so_git_branch` | Pinned SO source. Changing it is an upgrade (§10). |
| `so_setup_type: network` | The only working install mode on Ubuntu (§9.13). |
| `so_gre_anchor` / `so_gre_rule_block` | Firewall override internals (§9.1). |
| `so_sensor_force_cloud_mode: true` | Makes `BNICS` work (§9.2). |
| `so_address_type: STATIC` | Skips DHCP in so-setup. |

### 5.7 Dead variables — ignore

`so_interwebs` and `so_docker_range` in `group_vars/so_all.yml` are
declared but referenced by nothing. Leftovers from the abandoned airgap
plan. Do not build on them.

Also stale: the header comment in `group_vars/all/main.yml` describing
decisions #2 and #4 (preseed files, local ISO mirror). Both were superseded;
the file's actual values are correct, only the prose is out of date.

### 5.8 Computed at runtime — never set by hand

`so_prod_nic` and `so_prod_netmask` are derived by `set_fact` in each role
from `so_prod_ip` / `so_prod_prefix` and gathered facts.

---

## 6. Collections

`requirements.yml` must install cleanly before anything else. `deploy.sh`
does this via the proxy. Required:

`vyos.vyos`, `community.general`, `ansible.posix`, `community.docker`,
`ansible.windows`, `community.windows`, `ansible.netcommon`

The last two are needed by the copied `common` role — `win_psmodule` /
`win_power_plan`, and the `ipaddr` filter respectively.

---

## 7. How the pieces work

### 7.1 Roles

**Authored here:** `so_apt_mirror`, `so_base`, `so_manager`, `so_search`,
`so_sensor`, `vyos_mirror`.

**Copied** from `airfield-range/roles/` per the COPY-don't-reference policy:
`common`, `init`, `handlers`. `handlers` is a hard dependency of `common`
(declared in its `meta/main.yml`); copying `common` alone fails at load.

### 7.2 The install flow per SO node

1. `so_base` — proxy config, baseline packages, `/etc/hosts` for peers,
   extract the pinned SO source, docker daemon proxy, disable UFW.
2. Render an answer file to `/root/so-answers.env`.
3. Run `so-setup network`, which bash-sources that file. `TESTING=true`
   suppresses every whiptail prompt.
4. Verify — **not by exit code** (§9.3).
5. Grid-join: open the firewall, delete any stale salt key, reboot, wait
   for the key, accept it, generate the per-minion pillar, kick a highstate.
6. Wait for `so-status`, then write the installed marker.

### 7.3 Traffic capture

The platform provides no mirror NICs, so:

```
monitored subnets → router-0 (tc mirred, egress mirror)
                  → GRE tunnel tun0
                  → sensor tun0 (kernel decap)
                  → Suricata + Zeek
```

Both `tc` rules and the tunnel are idempotent and fingerprinted; the router
script re-applies on boot via VyOS's postconfig hook.

---

## 8. Verification

```bash
cd /etc/ansible && sudo ./verify_so.sh -v
```

26 checks across six sections. **26/26 is the expected result** — treat any
failure as real, but confirm the check itself is sound before believing it
(§9.15).

Phase 60 in `site.yml` covers the same ground more briefly and gates the
deploy.

---

## 9. Gotchas that will silently break a new range

Ordered by how much time each cost. Every one is already fixed in the repo —
this section exists so you recognise the symptom if it recurs, and so you
know what to preserve when porting.

### 9.1 SO's firewall drops the GRE mirror
**Symptom:** sensor `tun0` receives zero packets; everything else green.
**Cause:** every rule SO's firewall can generate carries a mandatory
`--dport`, and GRE is portless — no hostgroup/portgroup combination can
express proto 47. Unmatched traffic hits SO's `LOGGING` chain, which is
log-then-DROP. For locally-destined packets INPUT runs **before** protocol
demux, so packets die before `ip_gre` ever sees them.
**Fix:** `so_sensor` derives an override of `firewall/iptables.jinja` into
`local/salt/` at deploy time, injecting one ACCEPT before the LOGGING jump.
Never add it with raw `iptables` — `iptables_restore` re-runs every
highstate (~15 min) and wipes it.

### 9.2 `BNICS` is not the monitor interface
**Symptom:** so-setup logs `Interface set to bond0`; sensor captures nothing.
**Cause:** `BNICS` means "NICs to enslave into bond0". Off-cloud,
`generate_interface_vars()` hardcodes `INTERFACE='bond0'`. A GRE tunnel
cannot be enslaved into a bond, so this can never work for us.
**Fix:** `so_sensor` touches `/etc/SOCLOUD`, which flips `detect_cloud()`
and makes SO take the cloud path: `INTERFACE=${BNICS[0]}`, an ethernet NM
connection instead of a bond, and no slave enslavement.

### 9.3 `so-setup` exits 0 on failure
**Symptom:** setup "succeeds", node is broken.
**Cause:** SO logs `WARNING: Errors detected during setup` and returns 0.
**Fix:** trust SO's own signals — `/root/failure` (marker) and
`/root/errors.log`. All three roles check these. Also re-probe for
`/etc/salt/minion` afterward.

### 9.4 Guards that block their own remediation
Three separate instances occurred, all self-inflicted:
- a `creates:` marker that blessed itself (a satisfied `creates:` returns
  rc=0 **with** `skipped: true`, so the rc check cannot tell success from
  skip);
- a probe for `/etc/salt/minion_id`, a file this SO version never writes;
- `meta: end_host` making an installed node immune to **any** newly added task.

**Rule:** lifetime invariants (firewall rules, config overrides, drift
correction) go **before** the idempotency probe; only expensive one-time
install work goes after. Gate skips on positive proof of the end state,
never on an exit code or a marker the same code path writes.

### 9.5 The master rejects a regenerated minion key
**Symptom:** grid-join times out; `salt-key --list=unaccepted` is empty;
`salt-minion` exits `77/NOPERM`.
**Cause:** so-setup regenerates the keypair on every reinstall. The master
still holds the old key, so the new one lands in **Denied**.
**Fix:** `salt-key -d <minion_id> -y` on the master before reboot. Note
`salt-key -a` alone does **not** fix a Denied key — it must be deleted.

### 9.6 Salt binaries vs SO helpers
`/usr/sbin` holds SO's own scripts (`so-firewall`, `so-minion`,
`so-status`). Salt's binaries (`salt-call`, `salt-key`) are in `/usr/bin`.
Hardcoding the wrong prefix produces `command not found` inside a retry
loop that hides it for minutes.

### 9.7 Highstate scheduler collisions
The manager runs a highstate every 15 minutes with `maxrunning: 1`. Any
delegated `state.apply` can collide. Every such task retries 20 × 30s.

### 9.8 `/etc/hosts`, not DNS, and no_proxy needs names
Python's `urllib` does not parse CIDRs in `no_proxy` — only literal names.
`so_base` writes explicit per-host entries plus `127.0.0.1`. Without this,
salt's internal HTTP probes go out through the corp proxy and time out.

### 9.9 Verify the router's interface mapping on the live device
Blueprint NIC order did not match VyOS `ethN` numbering on the dev range.
Check `show interfaces` before setting `vyos_mirror_source_interfaces`.

### 9.10 Traffic generators must target hosts, not gateways
A ping to the router's own `.1` address is locally delivered and **never
egresses the mirrored interface**, so it generates no mirrorable traffic.
Target hosts *on* the monitored subnets. Unreachable targets are fine — the
router still ARPs out that interface, and ARP is mirrored.

### 9.11 Windows clients: RTC-as-local-time breaks the SOC login
**Symptom:** "This login form has expired", looping forever, InPrivate
included, with no server-side error.
**Cause:** SOC's login page is JS; it compares kratos's `expires_at` against
the **browser's** clock. The platform RTC holds UTC and Linux reads it
correctly, but Windows treats it as local time — producing a whole-timezone
offset. With a 60-minute flow lifespan, every flow is born expired.
**Fix (client side):** `RealTimeIsUniversal=1` or set the timezone to UTC.
Worth automating in `common` for any range with Windows analysts.

### 9.12 SO rejects Ubuntu jammy
`so-functions` gates on OS version. We patch the snapshot to accept jammy
by presenting it as focal. Preserved in
`roles/so_base/files/setup-automation-source/`.

### 9.13 There is no airgap path on Ubuntu
`so-setup iso` is CentOS/Rocky/RHEL only — it exits with a message telling
you to use `network`. Any `INTERWEBS=AIRGAP` is wrong here. All package
fetches go through the proxy.

### 9.14 Nothing configures time, and no NTP is reachable
UDP/123 does not traverse the corp proxy, so `System clock synchronized: no`
is normal. The Linux hosts agree only because they read the same UTC RTC.
This is fine until something compares clocks across platforms — see §9.11.

### 9.15 A check that cannot fail is not a check
Three verifications in this project were themselves the bug: a traffic
generator that produced nothing mirrorable, 13 `verify_so.sh` checks made
structurally impossible by `--one-line` plus anchored regexes, and a
plaintext-vault guard short-circuited to always-pass by `[ -f missing ] &&`.
Each actively misdirected debugging for hours.
**When a check and a subsystem fail together, confirm the check is sound
before treating it as evidence.**

### 9.16 Ad-hoc `ansible` on the controller needs `sudo`
The tarball extracts as root, so `group_vars/all/vault.yml` is root-owned.
`deploy.sh` works only because it is run with sudo.

---

## 10. Upgrading Security Onion

1. Pick the new commit on `2.4/main`; set `so_git_ref` + update
   `SOURCE_SHA.txt`.
2. Re-snapshot `so-setup`, `so-functions`, `so-variables`, `so-whiptail`,
   `so-common` into `roles/so_base/files/setup-automation-source/`.
3. **Diff them.** Specifically re-check:
   - `generate_interface_vars()` — still `is_cloud` gated? (§9.2)
   - `detect_cloud()` — still reads `/etc/SOCLOUD`?
   - `add_interface_bond0()` — still `if ! [[ $is_cloud ]]`?
   - the jammy gate in `so-functions` (§9.12)
4. Confirm `firewall/iptables.jinja` still contains
   `-A INPUT -j LOGGING`. The role fails loudly if not, but it is better to
   know before a deploy than during one.
5. Re-check the answer-file variable names against the new source.
6. Full deploy into a scratch range before touching a customer range.

`so_base`'s marker embeds the pinned SHA, so bumping `so_git_ref` forces a
re-extract automatically.

---

## 11. Known limitations

- **Single manager assumed** — `groups['so_manager'][0]` throughout.
- **Multi-search / multi-sensor untested** — should work by design.
- **`common` re-run hazard** — it does an NM cutover, netplan overwrite and
  reboot. Safe in fresh-build order; risky against a live grid. Consider
  restricting `00-setup` to fresh builds.
- **No AD** — Windows hosts get baseline config only.
- **sigma rules + AI summaries** don't fetch — they git-clone github.com,
  which the proxy doesn't carry. ETOPEN rules are served from our mirror.
- **`so-setup` "Could not reach so-manager"** — a 60s timeout during setup,
  treated as non-fatal by SO, still unexplained. Has not blocked anything.
- The `so_manager` hardening from the 2026-07-29 audit is **committed but
  unexercised** — it only fires when so-setup genuinely fails.

---

## 12. Where else to look

| File | Contains |
|---|---|
| `CLAUDE.md` | Owner decisions, conventions, repo layout |
| `UPSTREAM_FIXES.md` | Every issue with Symptom → Detection → Fix → **Status**, plus an open-items table |
| `PROJECT_LOG.md` | Narrative history (stale after 2026-07-22; UPSTREAM_FIXES took over) |
| `verify_so.sh` | The 26-check health script |
| `blueprints/so_arbitr_dev.yml` | The reference range topology |

`UPSTREAM_FIXES.md` is the single most useful file when something breaks —
every entry carries a status, and anything not marked VERIFIED has not been
proven on a real deploy.
