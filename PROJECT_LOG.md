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
