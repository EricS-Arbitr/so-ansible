# so_search Role

## Description
Installs a Security Onion **search node** and joins it to the manager's grid.
Structurally close to `so_manager`, with three differences that matter: it
installs as a search node, it auto-joins using `MSRV` + `MSRVIP` +
`SOREMOTEPASS`, and it carries no SOC web credentials — those exist on the
manager only. Install is roughly 5–10 minutes rather than 20–30.

Kept as its own role rather than a parameterised `so_manager` so per-role
divergence (heap tuning, disk layout) stays trivial to add.

## Variable Definition Location
Range-wide values in **group_vars/all/main.yml**, the join secret in
**group_vars/all/vault.yml**, addressing in **host_vars/&lt;node&gt;.yml**.

## Required Variables

### In group_vars/all/main.yml

| Variable | Required | Description |
|----------|----------|-------------|
| so_setup_type | Yes | Install type passed to `so-setup` |
| so_address_type | Yes | STATIC for this range |
| so_msrv | Yes | Manager's hostname — what the node joins |
| so_msrv_ip | Yes | Manager's production IP |

### In group_vars/all/vault.yml

| Variable | Required | Description |
|----------|----------|-------------|
| so_remote_password | Yes | SOREMOTEPASS1/2. Combined with salt-key remote-invoke this makes grid acceptance automatic — without it the join stalls waiting for a manual SOC WebUI click |

### In host_vars/&lt;node&gt;.yml

| Variable | Required | Description |
|----------|----------|-------------|
| so_hostname | Yes | HOSTNAME in the answer file |
| so_role | Yes | Node role |
| so_prod_ip, so_prod_netmask, so_prod_gateway | Yes | Production addressing |
| so_prod_nic | Yes | Production interface |
| so_prod_dns | Yes | DNS servers |

## Optional Variables

| Variable | Default | Description |
|----------|---------|-------------|
| so_search_install_timeout | see defaults | Async wait for `so-setup` |
| so_search_poll_interval | see defaults | Completion poll interval |
| so_search_answer_name | see defaults | Answer-file name |
| so_search_setup_log / so_search_setup_marker / so_search_installed_marker | see defaults | Log and idempotency markers |

## Ordering
Runs after `40-manager.yml`, and the manager must be genuinely up — the join
step reaches the manager during install, so "the manager play finished" is not
sufficient, `so-status` green is.

## Lifetime Invariants
This node's entry in the **manager's** firewall is manager-side state, not
node-side, and it is asserted **above** the already-installed probe. The node
being installed says nothing about whether the manager still lists it: a rebuilt
manager, a restored pillar or a hand-edited hostgroup all leave an installed
node permanently unable to reach salt on 4505/4506. With the check below the
probe, a re-run could never repair that — the play ended at the probe first
(PORTING_GUIDE 9.4).

Cheap on re-runs: `so-firewall includehost` reports "already exists" and is not
`changed`, so the expensive apply is skipped.

## Privilege
Requires `become: true`, asserted in the first task.

## Complete Example Configuration

### host_vars/so-search.yml
```yaml
so_hostname: "so-search"
so_role: "search"
so_prod_nic: "eth1"
so_prod_ip: "172.16.9.35"
so_prod_netmask: "255.255.255.0"
so_prod_gateway: "172.16.9.1"
so_prod_dns:
  - "172.16.2.7"
```
