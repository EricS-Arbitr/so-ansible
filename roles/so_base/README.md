# so_base Role

## Description
Cross-cutting preparation for every Security Onion Linux node — manager, search
and sensor alike. Runs before `so_manager` / `so_search` / `so_sensor` and makes
the node capable of running `so-setup` at all: packages, proxy, source tree,
name resolution.

Idempotent, and safe to re-run against an installed node.

## Variable Definition Location
Range-wide values in **group_vars/all/main.yml**; per-node addressing in
**host_vars/&lt;node&gt;.yml**.

## Required Variables

### In group_vars/all/main.yml

| Variable | Required | Description |
|----------|----------|-------------|
| so_git_ref | Yes | Pinned SO commit. Also selects which tarball is fetched from the mirror, and stamps the extraction marker |
| so_source_tarball_url | Yes | Full URL of the source tarball on the mirror |
| so_mirror_host | Yes | Mirror address — the controller's management IP, reached over the management plane |
| so_upstream_proxy | Yes | Proxy `so-setup` uses for its own upstream package fetches |
| so_manager_ip | Yes | Manager's production IP. Used for the reachability assertion and `/etc/hosts` |
| so_subnet_security | Yes | Security subnet CIDR, added to `no_proxy` |

### In host_vars/&lt;node&gt;.yml

| Variable | Required | Description |
|----------|----------|-------------|
| so_hostname | Yes | Short hostname. `/etc/hosts` needs it for the grid join, and it must match what the answer file sets |
| so_prod_ip | Yes | Production-plane address |

## Optional Variables

| Variable | Default | Description |
|----------|---------|-------------|
| so_source_dest | /root/manager_setup/securityonion | Where the source tree is extracted. `so-setup` auto-detects this path |
| so_snapshot_files | so-setup, so-functions, so-variables, so-whiptail | Files overlaid on top of the extracted tarball |
| so_no_proxy_subnets | see defaults | Ranges excluded from proxying |

## What It Does

1. Writes the APT proxy **before the first apt call**, or `ubuntu.archive` is
   unreachable and everything after it fails.
2. Installs the baseline packages SO 2.4's network install needs on Ubuntu 22.04.
3. Fetches the pinned source tarball from the mirror and extracts it, guarded by
   a marker file that embeds the current `so_git_ref`. A plain
   "does `setup/so-setup` exist" check false-positives on the SimSpace Ubuntu
   image, which ships a legacy SO 2.3.300 tree at the same path — bumping
   `so_git_ref` therefore correctly forces a re-extract.
4. **Overlays the snapshotted `so-setup` and friends on top of the extracted
   tree.** The snapshot and the tarball are not alternatives: the snapshot wins
   so the answer-file mechanism stays deterministic regardless of upstream drift.
   Files live in `files/setup-automation-source/`, with `SOURCE_SHA.txt`
   recording the commit they were taken from — it must match `so_git_ref`.
5. Populates `/etc/hosts` for every peer node, including an IPv6 entry for the
   node's own hostname (PORTING_GUIDE 9.8b).
6. Asserts production-plane L3 reachability to the manager, **ICMP only and
   deliberately so** — this runs before `so-setup` has installed anything, so
   there are no salt ports to test yet. Do not read a pass as "this node can
   talk to the manager": SO's firewall accepts ICMP from everywhere while
   rejecting unpermitted TCP, so once SO is up a ping succeeds from hosts that
   cannot open a single port. Port-level proof belongs to the grid-join tasks.

## Privilege
Requires `become: true` from the calling play, asserted in the first task.

## Complete Example Configuration

### group_vars/all/main.yml
```yaml
so_git_ref: "55af7eb541f086c4e7d6d3182fb2bc4fbc2b9e21"
so_source_tarball_url: "{{ so_mirror_url }}/so-source/securityonion-{{ so_git_ref[:12] }}.tar.gz"
so_manager_ip: "172.16.9.30"
so_upstream_proxy: "http://10.255.240.1:3128"
so_subnet_security: "172.16.9.0/24"
```

### host_vars/so-manager.yml
```yaml
so_hostname: "so-manager"
so_prod_ip: "172.16.9.30"
```
