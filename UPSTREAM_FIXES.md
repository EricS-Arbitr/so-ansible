# Upstream Fixes & Enhancements — so-ansible

Running log of issues, gaps, and workarounds discovered while building the
distributed Security Onion 2.4.x automation. Candidates for PRs to the SO
project, discussions with the SO Slack, or feedback to the SimSpace
platform team.

Per the [role-sourcing memory](../../.claude/projects/-Users-eric-starace-vCity/memory/project_airfield_role_sourcing.md):
when a fix is also needed in airfield-range or PowerPlant, re-copy it
explicitly and log there too (per the
[UPSTREAM_FIXES feedback memory](../../.claude/projects/-Users-eric-starace-vCity/memory/feedback_upstream_fixes_log.md)).

Severity key:
- **bug** — SO or platform malfunctions or produces incorrect results
- **gap** — missing functionality we have to work around
- **enhancement** — works but could be more robust or ergonomic
- **platform** — SimSpace platform-side issue

Format: `## YYYY-MM-DD · <severity> · <target>` followed by Symptom → Detection → Fix → Workaround.

---

## 2026-07-20 · gap · Security Onion 2.4 — `so-setup` non-interactive mode is undocumented + unsupported

**Symptom.** SO 2.4's `so-setup` installer is entirely interactive (whiptail
TUI). No `-f` / `--config` / `--answer-file` flag exists in the docs. This
blocks Ansible automation.

**Detection.** Reviewed `setup/so-setup` in the SO GitHub repo directly. The
script accepts two POSITIONAL args: `so-setup <iso|network|analyst>
<automation_filename>`. When the second arg matches a file under
`securityonion/setup/automation/`, the script `source`s it as bash and
sets an `automated=yes` flag that gates every whiptail prompt via
`if [ $automated == no ]`.

The SO project ships three ready-made answer files for exactly the
distributed-airgap topology we want:
`distributed-airgap-{manager,search,sensor}`. `README.txt` in that
directory: *"designed for internal Security Onion testing… support for
paying customers is limited to best effort."* SO discussion #8152
confirms: undocumented, unsupported, but functional.

**Fix (upstream).** Ask SO to promote the answer-file mechanism to a
supported feature with a documented schema. Alternative: publish the
bash-sourced variables as a stable schema in the docs.

**Workaround (overlay).** Template the three `distributed-airgap-*` files
via Jinja in `roles/so_{manager,search,sensor}/templates/`. Pin the SO
version and snapshot the source templates into
`so-ansible/files/setup-automation-source/` on each upgrade so we can
diff against them for schema drift. Invoke via
`sudo ~onion/SecurityOnion/setup/so-setup iso <rendered-filename>` after
symlinking the rendered file into `setup/automation/`.

**Related.** Grid-member auto-acceptance also flows through the answer
file (`SOREMOTEPASS1/2` + salt-key remote-invoke on manager) — no need
for a SOC WebUI acceptance step or REST call, contrary to what the
legacy walkthrough documented.

**Amendment (2026-07-20, same day).** Discovered when attempting to fetch
templates from tag `2.4.141-20250331`: the `setup/automation/` directory
DOES NOT EXIST in any tagged SO release. Verified by API-listing
`setup/` at tags 2.4.141, 2.4.150, 2.4.160, 2.4.170, 2.4.180, 2.4.190,
2.4.200, 2.4.211, 3.0.0, and 3.1.0 — all lack the `automation/`
subdirectory. At each tagged release, so-setup's second positional arg
is named `test_profile` (not `automation`) and only supports a
hardcoded set of internal-testing profile names that pre-set a small
number of variables (install_type, HOSTNAME, address_type=DHCP,
MSRVIP_OFFSET). It's NOT a general-purpose customer-facing answer-file
mechanism at any tagged version.

Only in `master` (unreleased) has the mechanism been generalized to
source arbitrary files from `setup/automation/` via `automated=yes`
gating of every whiptail prompt. Commit
`94c7dabd9ed97f134ceadfd00d0410665d898db7` (2026-07-20 HEAD) has both
the flexible mechanism AND the three `distributed-airgap-*` templates
we need.

**Workaround.** Pin `so_git_ref` in `group_vars/all.yml` to a specific
master SHA. On each SO node during install: `git clone --depth 1 -b
master <repo>` then `git checkout <so_git_ref>` then invoke `so-setup
iso <our-answer-file>`. Snapshot all four consumed files (the three
answer templates + `so-setup` + `so-functions` + `so-variables` +
`so-whiptail`) into `so-ansible/files/setup-automation-source/` and
verify at deploy-time via SHA compare — a silent upstream change to
`so-setup` between commits could shift what variables are read.

**Follow-up.** Open an issue on the SO repo asking that the
`setup/automation/` mechanism be included in the next tagged release
and its schema documented. Without upstream buy-in we're pinning to
un-tagged code indefinitely.

---

## 2026-07-21 · gap · Security Onion 2.4 airgap install is CentOS-only

**Symptom.** With snapshot templates for `distributed-airgap-{manager,search,sensor}`
staged and the plan of `so-setup iso <airgap-answer-file>` on Ubuntu 22.04,
the install would immediately abort.

**Detection.** Reading `setup/so-setup` lines 83-90 at pinned master SHA:
```
if [[ "$setup_type" == 'iso' ]]; then
    if [[ $is_centos ]]; then
        is_iso=true
    else
        echo "Only use 'so-setup iso' for an ISO install on CentOS. Please run 'so-setup network' instead."
        exit 1
    fi
fi
```

`so-setup iso` is guarded on CentOS/RHEL/Rocky. Ubuntu targets must use
`so-setup network`. Cross-referenced with the `setup/automation/`
directory listing at the same SHA: SO ships `distributed-airgap-*`
(CentOS-only), `distributed-iso-*` (CentOS-only), `distributed-net-centos-*`,
`distributed-net-ubuntu-*`, and `distributed-net-ubuntu-suricata-*`.
There is NO `distributed-airgap-ubuntu-*` or equivalent — airgap-from-ISO
is not a supported mode on Ubuntu 2.4.

**Root cause.** SO 2.4's airgap mode assumes an ISO with baked-in CentOS
packages that get exposed via `/etc/yum.repos.d/airgap_repo.repo`. Ubuntu
apt has no equivalent mechanism in SO's setup scripts.

**Impact.** Original plan (decision #4 in `[[project_so_architecture_decisions]]`:
airgap install using ansible-hosted ISO mirror) is incompatible with
decision to use base Ubuntu 22.04 images. Only three paths remained:
switch to Rocky, network-mode install via corp proxy, or build a real
local APT mirror.

**Chosen path** (per user 2026-07-21): **network install via corp proxy**.
Simpler; no blueprint change; abandons decision #4's local mirror in
favor of speed-to-working-deploy. Local mirror can be reintroduced later
by adding an apt-mirror role that pulls from packages.securityonion.net
+ Docker + Elastic apt repos.

**Fix (overlay, this project).**
- Snapshotted `distributed-net-ubuntu-{manager,search,sensor}` from same
  pinned master SHA into `files/setup-automation-source/` (alongside the
  distributed-airgap-* snapshots we already had — kept for reference).
- Updated group_vars/all.yml: dropped `so_iso_*` variables; added
  `so_setup_type: "network"`, `so_answer_template: "distributed-net-ubuntu"`,
  `so_upstream_proxy: "http://10.255.240.1:3128"`.
- Reduced so_apt_mirror role scope: no longer serves ISO; still serves
  the pinned SO source tarball (source snapshot is version-locked
  regardless of install mode).
- so_base role sets system-wide `HTTP_PROXY`/`HTTPS_PROXY` +
  `/etc/apt/apt.conf.d/95so-proxy` pointing at corp proxy so `so-setup
  network`'s upstream apt/curl calls succeed.

**Follow-up.** File a docs issue with SO asking for either (a) an Ubuntu
airgap mode or (b) explicit doc that airgap is CentOS-only + guidance
for Ubuntu airgap (via local APT mirror). Also: file a docs issue for
the walkthrough at `docs/Security Onion 2.4.X Deployment Overview_.docx`
— it references airgap on Ubuntu template implicitly and is misleading.
