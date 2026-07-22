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

---

## 2026-07-21 (later) — verify_so.sh + vault encryption

- **verify_so.sh** authored (mirrors airfield-range's verify_fuel_farm.sh
  pattern). Six sections: reachability, mirror, router GRE + tc, manager
  (so-status + Elastic cluster health + SOC WebUI + salt-key accepted),
  search (data node in Elastic), sensor (tun0 UP + promisc + Suricata +
  Zeek + tcpdump-on-tun0 smoke test).
- **Vault workflow** set up: encrypted `group_vars/vault.yml` with
  ansible-vault (dev password: `so-ansible-dev`; distributed out-of-band
  for real deploys). `.vault_pass` at repo root (gitignored) or
  `/home/simspace/.vault_pass` on the controller. Helper script
  `vault-tools.sh` wraps common ops (edit/view/encrypt/decrypt/rekey/check).
- **Deploy-time guard**: `deploy.sh` refuses to run if `vault.yml` isn't
  encrypted (starts with `$ANSIBLE_VAULT;1.1;AES256`). Prevents a
  fresh-clone-and-forget mistake from shipping plaintext creds.
- CLAUDE.md gained §11 (vault workflow) + §12 (verification).

**Ready for a range deploy dry-run.** No further scaffolding blockers.

---

## 2026-07-22 — Deploy iteration + branch discovery

Ran phases 10 + 20 + 30 through many failure/fix cycles (see git log
between commits ef127dc and 6e24202). Everything through Phase 30
went green: mirror serving SO source, router-0 GRE tunnel with tc
mirror to tun0, all 3 SO nodes prepped with baseline packages + proxy
+ /etc/hosts + snapshotted so-setup overlay + UFW down.

Phase 40 (so_manager) failed in a way that forced a major replan:
whiptail dialog said "Security Onion Setup - 2.3.300". Investigation
revealed my `master` snapshot IS 2.3.300 (legacy); real SO 2.4 lives
on `2.4/main` (currently 2.4.211) or `2.4/dev`. The
`setup/automation/` answer-file mechanism only exists at 2.3.300 —
2.4 branches have NO non-interactive install path.

**User chose:** switch to SO 2.4/main + pexpect wrapper driving the
whiptail TUI. Substantial engineering (~8-12 hours) scheduled for
next session.

**Block A landed this session (commit TBD):**
- Re-snapshotted so-setup + so-functions + so-variables + so-whiptail
  from 2.4/main HEAD (`55af7eb541f086c4e7d6d3182fb2bc4fbc2b9e21`) into
  `roles/so_base/files/setup-automation-source/`.
- Dropped `distributed-*` templates (master-only, don't apply to 2.4).
- Updated `so_git_ref` + added `so_git_branch: "2.4/main"` in
  `group_vars/all/main.yml`.
- Stubbed `so_manager`, `so_search`, `so_sensor` tasks with `fail:`
  tasks referencing this log entry.
- Fixed `so_base` idempotency: SimSpace RDP_Ubuntu_Desktop pre-bakes
  a legacy 2.3.300 install at `/root/manager_setup/`; my old
  file-existence check was false-positiving. Replaced with marker
  file `.so-ansible-pinned-<sha[:12]>` that embeds the pinned SHA,
  so bumping so_git_ref forces re-extract + wipe of stale source.
- UPSTREAM_FIXES.md gained the branch-discovery entry.

**Block B (next session):** pexpect wrapper for so_manager (biggest),
then so_search + so_sensor (smaller, same pattern). Preserve the
existing group_vars + host_vars answer values — those transfer
cleanly from bash-var-assignment to Python-dict.
