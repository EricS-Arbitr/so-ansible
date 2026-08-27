# so_apt_mirror Role

## Description
Stands up an HTTP mirror on the Ansible controller itself that serves every
artifact the Security Onion nodes need during install. **The SO nodes never
reach the internet** — they pull everything from this mirror over the management
plane.

Two sources fill it, and they are not the same kind of thing:

| Artifact | Where it comes from |
|----------|---------------------|
| SO source tree | **`git clone` of `so_git_repo` from GitHub**, `depth: 1` at `so_git_ref`, tarred into `so-source/securityonion-<sha12>.tar.gz` |
| ETOPEN ruleset | Copied from `/etc/ansible/rules/emerging.rules.tar.gz` — the so-ansible tarball's own top-level `rules/` directory |
| Elastic Agent installers | Staged by `playbooks/75-endpoint.yml`, not by this role |

## THE CONTROLLER NEEDS EGRESS TO GITHUB
This is the single external dependency in an otherwise sealed build, and it is
easy to miss because everything downstream of it looks airgapped.

The clone runs through `so_mirror_proxy` (the management-plane proxy) and is
gated on a `stat` of the target tarball, so it happens **once per pinned SHA**
and never again. But on a fresh range with no working proxy, `so_apt_mirror`
fails and every SO node fails behind it — `so_base` fetches the source from this
mirror, so nothing installs.

If a target range genuinely has no proxy, pre-seed
`{{ so_mirror_root }}/so-source/securityonion-<sha12>.tar.gz` by hand before
running the role. The `stat` guard will then skip the clone entirely.

Note that `roles/so_apt_mirror/files/` does **not** exist and is not how any of
this works. An empty directory of that name lingered in the working tree until
2026-08-27; git never tracked it, and no task ever read it.

**There is no ISO.** The role served a Security Onion airgap ISO until
2026-07-21. `so-setup iso` is CentOS/Rocky/RHEL only and exits on Ubuntu telling
you to use `network`, so the ISO was pure weight. Any `so_iso_*` variable you
find referenced is dead — see PORTING_GUIDE 9.13.

## Variable Definition Location
Range-wide values go in **group_vars/all/main.yml**. Only tuning lives in this
role's `defaults/main.yml`.

## Required Variables

### In group_vars/all/main.yml

| Variable | Required | Description |
|----------|----------|-------------|
| so_mirror_host | Yes | Address the SO nodes fetch from — the controller's **management** address (`ansible_host`). The nodes are dual-homed and reach the mirror over the management plane; the controller has no production-plane presence |
| so_mirror_root | Yes | Filesystem root nginx serves. Defined here rather than in role defaults because `75-endpoint.yml` stages installers into it *without* including this role, and a role default is role-scoped |
| so_mirror_url | Yes | Full base URL the nodes use, `http://{{ so_mirror_host }}:{{ so_mirror_port }}` |
| so_git_repo | Yes | Security Onion source repository |
| so_git_ref | Yes | Pinned commit SHA. The tarball name embeds `so_git_ref[:12]`, so changing this changes what every node fetches |
| so_upstream_proxy | Yes | Management-plane proxy for the controller's own fetches. The nodes never use it |
| so_bundled_rules_filename | Yes | ETOPEN ruleset filename shipped in the tarball under `rules/` |
| so_airgap_repos | Yes | Repository list staged for the manager's airgap pillar |
| so_airgap_etopen_dest | Yes | Where the manager expects the ETOPEN ruleset to land |
| so_airgap_build_dir | Yes | Scratch directory used while assembling the airgap payload |

## Optional Variables

| Variable | Default | Description |
|----------|---------|-------------|
| so_mirror_port | 80 | Port nginx binds |
| so_mirror_proxy | (unset) | Proxy for the mirror's own git clone, when it differs from `so_upstream_proxy` |
| so_bundled_rules_src | see defaults | Path to the ruleset inside the extracted tarball |

## Paths Served

| URL | Filesystem | Purpose |
|-----|------------|---------|
| `/so-source/securityonion-{{ so_git_ref[:12] }}.tar.gz` | `{{ so_mirror_root }}/so-source/` | SO source at the pinned SHA |
| `/agents/...` | `{{ so_mirror_root }}/agents/` | Elastic Agent installers, staged by `75-endpoint.yml` |

No authentication — this is a range-internal mirror on an isolated network. If
that ever stops being true, gate it at the firewall rather than adding basic
auth the nodes would then have to carry.

## Privilege
Requires `become: true` from the calling play. The role asserts this in its
first task and fails immediately if run unprivileged, rather than failing on a
permission error partway through in a task that looks unrelated.

## Idempotency
The source tarball is only cloned and packed when the file for the pinned SHA is
absent. nginx config changes notify a reload rather than a restart.

## Complete Example Configuration

### group_vars/all/main.yml
```yaml
so_mirror_host: "10.255.240.157"   # controller mgmt IP
so_mirror_root: /var/www/so-mirror
so_mirror_url: "http://{{ so_mirror_host }}"
so_git_repo: "https://github.com/Security-Onion-Solutions/securityonion.git"
so_git_ref: "55af7eb541f086c4e7d6d3182fb2bc4fbc2b9e21"
so_upstream_proxy: "http://10.255.240.1:3128"
so_bundled_rules_filename: "emerging.rules.tar.gz"
```
