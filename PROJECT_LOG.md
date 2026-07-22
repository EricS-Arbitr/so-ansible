# PROJECT_LOG — so-ansible

Session-by-session narrative log. Complements git history + UPSTREAM_FIXES.md
with the "why we did it this way" context that doesn't fit in either.

---

## 2026-07-20 — Project bootstrap

Pivoted from airfield-range fuel-farm work to standing up so-ansible.

**Decisions locked** (see [[project_so_architecture_decisions]] memory + CLAUDE.md §3):
1. Ansible dual-homed on mgmt plane (10.255.240.157)
2. so-setup driven via answer files (positional arg, undocumented but stable)
3. Windows out of scope (DC/wks are placeholders)
4. Updates via ansible-hosted local mirror at http://10.255.240.157/
5. Traffic capture via VyOS GRE-mirror to sensor + Elastic Agent on endpoints (A+C)

**Blueprint fixes applied by user:**
- Ansible got a mgmt NIC at 10.255.240.157 (matches PowerPlant convention)
- Router-0 declared as `RC-VyOS-Router:1.1.0` (confirmed VyOS underneath, so
  GRE-mirror plan is viable)
- Router-0 interfaces marked `role: GATEWAY` on all four subnets
- Router-0 dual-homed with mgmt at 10.255.240.165 (position LAST)

**Blueprint issues still outstanding** (non-blocking):
- so-search has no explicit `hostname` field — will inherit VM name from
  platform. Acceptable.
- so-sensor-1 has no mirror NICs. Intentional per decision #5.

**Research:** dispatched general-purpose agent to reverse-engineer SO 2.4's
non-interactive install. Findings summarized in UPSTREAM_FIXES entry above.
Key wins:
- Answer-file mechanism DOES exist (bash-sourced, positional arg to so-setup)
- SO ships templates for our exact distributed-airgap topology
- Grid-member acceptance is AUTOMATIC via SOREMOTEPASS + remote salt-key -y -a
  — no SOC WebUI clicks or REST API needed

**Scaffolding created** (this session):
- ansible.cfg (vault password + explicit py3 + SSH pipelining)
- hosts (inventory groups: ansible_controller, net_vyos, so_{manager,search,sensor}, so_all, windows_placeholder)
- host_vars/{so-manager,so-search,so-sensor-1,router-0}.yml
- group_vars/{all,so_all,vault}.yml (vault UNENCRYPTED for now — encrypt before commit)
- requirements.yml (vyos.vyos, community.general, ansible.posix, community.docker, ansible.windows)
- site.yml + playbooks/{10-mirror,20-vyos,30-prereqs,40-manager,50-nodes,60-verify}.yml
- build_tarball.sh (adapted from airfield-range; tarball name = so_ab.tgz)
- deploy.sh (adapted; forks=8 given small inventory)
- CLAUDE.md + PROJECT_LOG.md + UPSTREAM_FIXES.md
- README.md (starter, pre-existing)

**Not yet done:**
- Copied `common` (from airfield-range) + `init` (from airfield-range). Skipped `hostname` — `range-development-ansible/roles/hostname/main.yml` is a Windows-only playbook fragment; `common/tasks/hostname.yml` handles Linux hostnames already.
- Snapshot SO 2.4.141 `distributed-airgap-*` templates into files/setup-automation-source/
- Author `so_apt_mirror`, `so_base`, `so_manager`, `so_search`, `so_sensor`, `vyos_mirror` roles
- Encrypt group_vars/vault.yml with ansible-vault
- git init + first commit

**Next session:** finalize role authoring in dependency order (`so_apt_mirror`
→ `vyos_mirror` → `so_base` → `so_manager` → `so_search`/`so_sensor`), then
verify_so.sh, then a range deploy dry-run.

---

## 2026-07-21 — All roles authored

Continued Phase 2: authored `so_base`, `vyos_mirror`, `so_manager`,
`so_search`, `so_sensor`. Build discovery clean (9 roles bundled).

**Plan-invalidating discovery:** SO 2.4 airgap-from-ISO is **CentOS-only**.
`so-setup iso` at line 87 exits immediately on non-CentOS. No
`distributed-airgap-ubuntu-*` template exists. Ubuntu targets must use
`so-setup network` + `distributed-net-ubuntu-*` templates + online repos.

**User decision:** pivot to network install via corp proxy (10.255.240.1:3128).
Simplest path; abandons decision #4's local mirror plan.

**Changes made:**
- Snapshotted `distributed-net-ubuntu-{manager,search,sensor}` at same pinned SHA
- `group_vars/all.yml`: dropped `so_iso_*`, added `so_setup_type: network`,
  `so_upstream_proxy`, `so_answer_template: distributed-net-ubuntu`
- `so_apt_mirror` scope reduced to serving SO source tarball only
- `so_base` sets system-wide proxy env + APT proxy so `so-setup network`
  reaches upstream via corp proxy
- All three SO node roles (`so_manager`, `so_search`, `so_sensor`) use
  `distributed-net-ubuntu-*` as their answer-file source template
- `so_sensor` brings up sensor-side GRE tunnel `tun0` (matches
  vyos_mirror's remote endpoint) via netplan `tunnels:` before so-setup
  runs (BNICS=tun0 needs the interface to exist during install)
- `vyos_mirror` authored: declarative GRE tunnel via `vyos.vyos.vyos_config`
  + imperative tc mirred script installed at VyOS postconfig hook

**Small technical fixes during authoring:**
- MNIC + MMASK now computed at deploy time from `ansible_facts` (was
  hardcoded ens192 + would have been wrong — mgmt is FIRST=ens192, prod
  NIC is ens224 on SimSpace VMware image)
- Answer file `SKIP_REBOOT=1` so Ansible controls the reboot cadence
- so-setup runs `async` + `poll: 0` (~30 min manager install would
  otherwise time out an SSH session)

**Not yet done:**
- verify_so.sh (still stubs in 60-verify.yml playbook)
- git commit + push
- ansible-vault encrypt group_vars/vault.yml
- range deploy dry-run
