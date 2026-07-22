# CLAUDE.md — so-ansible

Distributed Security Onion 2.4.x deployment via Ansible. Standalone dev
project; roles port into airfield-range + PowerPlant once proven.

Authority order for design decisions: **owner decisions (§3) → SO source of
truth (§6) → CLAUDE.md → per-role README**.

---

## 1. Project purpose

Automate a distributed Security Onion (SO) 2.4.x deploy — 1 manager, 1
search, 1 sensor — on a scaled-down 4-subnet range. Second SIEM stack
Arbitr offers customers alongside Splunk. Once stable here, the roles
merge into `airfield-range/roles/` and `PowerPlant/ss-pp-ab/roles/` per
the role-sourcing policy (COPY, don't reference).

Blueprint: `blueprints/so_arbitr_dev.yml` (ARBITR_SO_DEV).

## 2. Scope

**In:** distributed SO stack (manager/search/sensor), local update mirror,
VyOS GRE-mirror for wire capture, Elastic Agent enrollment for endpoint
telemetry, verification.

**Out** (explicitly, until user re-scopes):
- Windows AD promotion, user creation, workstation join. The DC01 +
  ops-wks-01 + eng-wks-01 in the blueprint are placeholders for future
  monitoring targets, not provisioned by this project. When we need AD
  later, copy from `airfield-range/roles/{dcpromo,create_users,domain_member}`.
- Splunk (that's [[project_siem_choice]]).
- Wazuh (never propose it).

## 3. Owner decisions (authoritative — applied throughout)

Confirmed 2026-07-20 via AskUserQuestion (see [[project_so_architecture_decisions]] memory).

| # | Decision | Effect |
|---|---|---|
| 1 | **Ansible dual-homed on 10.255.240.0/20** | Second NIC on ansible VM at `10.255.240.157` (matches PowerPlant/airfield-range convention). Ansible connects to hosts via `ansible_host` = mgmt IP. |
| 2 | **`so-setup` driven by answer files (positional arg, master only)** | Per SO source (`setup/so-setup`): `so-setup <iso\|network\|analyst> <automation_filename>` where the file lives in `securityonion/setup/automation/` and is bash-sourced. **CRITICAL:** verified 2026-07-20 that the `automation/` directory does NOT exist in any tagged SO release (2.4.141 through 3.1.0). The mechanism is master-only. We pin `so_git_ref` to a specific master SHA + snapshot the answer templates + `so-setup` + supporting scripts into `files/setup-automation-source/`. See UPSTREAM_FIXES.md · 2026-07-20 amendment. |
| 3 | **Windows out of scope** | See §2. |
| 4 | **~~Updates via ansible-hosted local mirror~~ → network install via corp proxy** | Original plan was airgap-from-ISO. Discovered 2026-07-21 that airgap SO 2.4 is CentOS-only. Pivoted (per user): SO nodes use `so-setup network` and reach upstream repos via `so_upstream_proxy` = `http://10.255.240.1:3128`. `so_apt_mirror` scope reduced to serving just the pinned SO source tarball. See UPSTREAM_FIXES.md · 2026-07-21. |
| 5 | **Traffic capture = VyOS GRE-mirror + Elastic Agent** | New platform doesn't support mirror NICs. router-0 (VyOS) sets up GRE tunnel to so-sensor-1 + tc mirred rules on Operations/Engineering/Services interfaces. Suricata + Zeek on sensor bind to `tun0`. Elastic Agent on Windows hosts complements wire visibility with endpoint telemetry. |

## 4. Network layout (dev range)

From `blueprints/so_arbitr_dev.yml`:

| Subnet | CIDR | Members | Gateway |
|---|---|---|---|
| Operations | 172.16.8.0/24 | ops-wks-01 `.5` | router-0 `.1` |
| Engineering | 172.16.6.0/24 | eng-wks-01 `.11` | router-0 `.1` |
| Services | 172.16.7.0/24 | DC01 `.7` | router-0 `.1` |
| security | 172.16.5.0/24 | so-manager `.10`, so-search `.15`, so-sensor-1 `.20` | router-0 `.1` |
| control-10 | 10.10.0.0/16 | ansible `.10.10` (control NIC) | — |
| Mgmt plane | 10.255.240.0/20 | ansible `.157`, so-* `.100/.101/.102`, DC01 `.121`, wks `.120/.122`, router-0 `.165` | platform |

Router-0 is `RC-VyOS-Router:1.1.0` — GATEWAY role on all four subnets;
dual-homed with `.165` on mgmt plane. VyOS ansible target uses
`ansible_connection: network_cli`.

## 5. Roles (copied vs authored)

**Copied** (per role-sourcing policy): none currently. Attempted 2026-07-21
to copy `common`, `init`, `handlers` from airfield-range — all three
proved unusable (common expects a `network_interfaces` dict schema we
don't use + does NM/netplan surgery that conflicts with `so-setup
network`; init is Windows-only). See UPSTREAM_FIXES.md · 2026-07-21
(later) entry. If we later need hostname/NM/apt tasks, pull the
narrowest possible sub-task into a purpose-built role rather than
importing wholesale.

**Authored here** (SO-specific):
- `so_apt_mirror` — nginx :80 serving SO ISO on ansible controller
- `so_base` — cross-cutting SO node prep (pull ISO from mirror, mount at
  `/nsm/repo/`, /etc/hosts entries for other SO nodes)
- `so_manager` — render `distributed-airgap-manager` answer file from
  templates, invoke `so-setup iso <answers>`, verify manager green
- `so_search` — render `distributed-airgap-search`, join manager
- `so_sensor` — render `distributed-airgap-sensor` with `BNICS=tun0`,
  join manager
- `vyos_mirror` — GRE tunnel + `tc mirred` rules on router-0 (uses
  `vyos_mirror_source_interfaces` list from host_vars)
- `elastic_agent` — Windows/Linux enrollment via `elastic-agent install
  --url=https://<mgr>:8220 --enrollment-token=<vault>`

## 6. SO source of truth

- Main repo: https://github.com/Security-Onion-Solutions/securityonion
- Answer-file templates (bash-sourced by `so-setup`):
  https://github.com/Security-Onion-Solutions/securityonion/tree/master/setup/automation
  — files `distributed-airgap-{manager,search,sensor}` are the canonical
  starting point for our Jinja templates. **Pin SO version + re-diff on
  upgrade** — the answer-file mechanism is undocumented and could shift.

## 7. Repository layout

```
so-ansible/
├── CLAUDE.md
├── PROJECT_LOG.md
├── UPSTREAM_FIXES.md
├── README.md
├── ansible.cfg                # vault password + explicit python3
├── hosts                      # groups: ansible_controller, net_vyos,
│                              #         so_manager, so_search, so_sensor,
│                              #         so_all, windows_placeholder
├── requirements.yml           # vyos.vyos, community.general, ansible.posix,
│                              # community.docker, ansible.windows
├── site.yml                   # imports 10→60 phase playbooks in order
├── group_vars/
│   ├── all.yml                # SO version pin, mirror URL, subnets
│   ├── so_all.yml             # answer-file variables (INTERWEBS, NIDS, ...)
│   └── vault.yml              # WEBPASSWD, SOREMOTEPASS (ansible-vault encrypted)
├── host_vars/
│   ├── so-manager.yml         # mgmt IP + prod IP + so_role: manager
│   ├── so-search.yml          # mgmt IP + prod IP + so_role: searchnode
│   ├── so-sensor-1.yml        # + GRE tunnel addresses + so_monitor_interface
│   └── router-0.yml           # VyOS: mgmt IP + mirror source list
├── playbooks/
│   ├── 10-mirror.yml          # ansible controller = local mirror (nginx + ISO)
│   ├── 20-vyos.yml            # router-0 GRE tunnel + tc mirror rules
│   ├── 30-prereqs.yml         # common + init + hostname + so_base on so_all
│   ├── 40-manager.yml         # so_manager (must succeed before 50)
│   ├── 50-nodes.yml           # so_search + so_sensor (parallel, join manager)
│   └── 60-verify.yml          # so-status + cluster health + pcap flow check
├── roles/                     # (initially empty except copied common/init/hostname)
├── blueprints/
│   └── so_arbitr_dev.yml      # authoritative range topology
├── docs/
│   └── Security Onion 2.4.X Deployment Overview_.docx  # legacy walkthrough
├── build_tarball.sh
├── deploy.sh
└── verify_so.sh               # (to be written alongside so_manager role)
```

## 8. Conventions

- **Rebuild tarball before every commit** (per `[[feedback_tarball_commit_policy]]`).
  `./build_tarball.sh` produces `so_ab.tgz`; commit the tarball with the
  code change. Controller deploys from tarball, not git pull.
- **Log every workaround** in `UPSTREAM_FIXES.md` the same turn it lands
  (per `[[feedback_upstream_fixes_log]]`).
- **No hardcoded secrets in tasks/templates.** All secrets via
  `group_vars/vault.yml` (ansible-vault encrypted).
- **Never bypass so-setup by editing SO's own files** unless there's no
  alternative. If we do, document it in UPSTREAM_FIXES + open an issue
  in the SO repo.
- **Preserve `distributed-net-ubuntu-*` answer-file variable names verbatim.**
  so-setup is bash-sourcing — a typo silently skips the value and the
  TUI reappears. Compare rendered answer files against
  `so-ansible/files/setup-automation-source/` snapshots on each SO upgrade.

## 11. Vault + secrets workflow

`group_vars/vault.yml` is ansible-vault encrypted. Password file location
(matches `ansible.cfg`'s `vault_password_file` setting):
- **Controller:** `/home/simspace/.vault_pass` (mode 600, contents = password)
- **Local dev (Mac):** `./.vault_pass` in the repo root (gitignored)

**Password distribution.** The dev vault password is distributed out-of-band
(Slack DM / 1Password / similar). NOT committed anywhere in this repo.
Rotate the password before any customer-range deploy.

**Common operations** (via `vault-tools.sh`):
```bash
./vault-tools.sh check      # is vault.yml encrypted?
./vault-tools.sh view       # print decrypted contents
./vault-tools.sh edit       # decrypt → $EDITOR → re-encrypt (atomic)
./vault-tools.sh rekey      # rotate the password
./vault-tools.sh encrypt    # first-time encrypt (for a plaintext vault.yml)
./vault-tools.sh decrypt    # dev-only escape hatch; DO NOT commit
```

**Deploy-time guard.** `deploy.sh` refuses to run if `vault.yml` doesn't
start with `$ANSIBLE_VAULT;1.1;AES256`. Prevents a checkout-and-forget
mistake from shipping plaintext creds.

**Current placeholders** (rotate for real deploys):
- `vault_so_web_password` — SOC WebUI admin login
- `vault_so_remote_password` — SOREMOTEPASS for search/sensor to join manager
- `vault_simspace_password` — SSH fallback for the simspace user on fresh VMs

## 12. Verification

`verify_so.sh` is the deploy-side sanity check. Six sections:

1. Inventory reachability (mgmt-plane ping across every host)
2. Ansible controller (nginx :80 + SO source tarball reachable)
3. router-0 (GRE tunnel + tc mirror rules per source interface)
4. so-manager (so-status + Elastic cluster health + SOC WebUI + salt-key)
5. so-search (so-status + is a data node in Elastic cluster)
6. so-sensor-1 (so-status + Suricata + Zeek + tun0 promiscuous + tcpdump smoke)

```bash
cd /etc/ansible && ./verify_so.sh          # summary
cd /etc/ansible && ./verify_so.sh -v       # verbose on fails
```
The tcpdump-on-tun0 check at the end is the money-shot — packets there
means the whole chain (GRE mirror → kernel decap → Suricata/Zeek input)
is intact.

## 9. Deploy sequence

```bash
# On ansible controller:
cd /etc/ansible
./deploy.sh                              # full build + all phases
ansible-playbook site.yml --tags mirror  # (once tags are added) just re-stage the mirror
ansible-playbook playbooks/40-manager.yml --limit so-manager
```

Phases (from site.yml):
1. `10-mirror` — nginx + ISO on ansible controller
2. `20-vyos` — GRE tunnel + tc mirror rules on router-0
3. `30-prereqs` — common/init/hostname/so_base on all SO Linux nodes
4. `40-manager` — so_manager (must complete before phase 5)
5. `50-nodes` — so_search + so_sensor parallel (join manager)
6. `60-verify` — so-status, cluster health, pcap flow rate

## 10. Open items (TODO)

- **so-setup answer-file variable schema verification** — snapshot the
  three `distributed-airgap-*` templates from SO 2.4.141 tag (not master)
  into `files/setup-automation-source/` so we render against exactly the
  variables SO expects at our pinned version.
- **so_apt_mirror role** — ISO staging + nginx config
- **vyos_mirror role** — GRE + tc mirred idempotent implementation
- **so_manager/search/sensor roles** — answer-file templates + so-setup invocation
- **verify_so.sh** — end-to-end health checks (mirrored on airfield-range's `verify_fuel_farm.sh`)
- **elastic_agent role** — WHEN we bring Windows into scope
- **Merge back to airfield-range/PowerPlant** — post-MVP
