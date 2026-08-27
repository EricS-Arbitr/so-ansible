# so_manager Role

## Description
Installs the Security Onion **manager** node. Renders the
`distributed-net-ubuntu-manager` answer file from inventory, runs
`so-setup network`, waits out the 20–30 minute install, reboots under Ansible's
control, and verifies the grid came up. Optionally applies Elastic Defend
exclusions afterwards.

Everything else in the grid joins *this* node, so it must complete before
`so_search` or `so_sensor` run.

## Variable Definition Location
Range-wide values in **group_vars/all/main.yml**, secrets in
**group_vars/all/vault.yml**, addressing in **host_vars/so-manager.yml**.

## Required Variables

### In group_vars/all/main.yml

| Variable | Required | Description |
|----------|----------|-------------|
| so_setup_type | Yes | Install type passed to `so-setup` |
| so_address_type | Yes | STATIC or DHCP; the range is static |
| so_web_user | Yes | SOC web login |
| so_web_access_type | Yes | How SOC is exposed |
| so_nids | Yes | NIDS engine (Suricata) |
| so_rule_set | Yes | Ruleset selection — ETOPEN for this range |
| so_zeek_version | Yes | Zeek version SO installs |
| so_manager_adv | Yes | Advanced-mode flag in the answer file |
| so_subnet_security | Yes | Grid subnet permitted to reach the manager |
| so_mirror_url / so_mirror_root | Yes | Mirror the airgap payload is staged from |
| so_airgap_repos, so_airgap_etopen_dest, so_airgap_pillar_file | Yes | Airgap pillar wiring |
| so_bundled_rules_filename | Yes | ETOPEN ruleset filename |

### In group_vars/all/vault.yml

| Variable | Required | Description |
|----------|----------|-------------|
| so_web_password | Yes | SOC web password (WEBPASSWD1/2) |
| so_remote_password | Yes | SOREMOTEPASS1/2 — what makes grid acceptance automatic instead of a manual SOC click |

### In host_vars/so-manager.yml

| Variable | Required | Description |
|----------|----------|-------------|
| so_hostname | Yes | HOSTNAME in the answer file |
| so_prod_ip, so_prod_prefix, so_prod_netmask, so_prod_gateway | Yes | MIP / MMASK / MGATEWAY |
| so_prod_nic | Yes | Production interface name |
| so_prod_dns | Yes | DNS servers, comma-joined into MDNS |

## Optional Variables

| Variable | Default | Description |
|----------|---------|-------------|
| so_defend_exclusions | `[]` | Elastic Defend exclusions. Empty means the feature is off — the include is gated on length |
| so_defend_filters_src / so_defend_filters_out | see group_vars | Where custom filters are read from and written to |
| so_manager_install_timeout | see defaults | Async wait for `so-setup` |
| so_manager_poll_interval | see defaults | How often completion is polled |
| so_manager_answer_name | see defaults | Answer-file name under `setup/automation/` |
| so_manager_setup_log / so_manager_setup_marker / so_manager_installed_marker | see defaults | Log and idempotency markers |

## Flow

1. Assert privilege, then probe whether SO is already installed. If it is, the
   role ends early — but note the **lifetime invariants placed above that probe**
   deliberately, so an already-installed node can still have manager-side state
   repaired on a re-run.
2. Stage the airgap payload and pillar from the mirror.
3. Render the answer file into `setup/automation/`.
4. Run `so-setup network <name>` with `async`, because the install far outlives
   any reasonable SSH timeout. **A too-short `async:` destroys the install** —
   see PORTING_GUIDE 9.7b.
5. Poll for completion, reboot under Ansible control, wait for reconnection.
6. Verify with `so-status`, asserting on an exact value rather than a substring
   (PORTING_GUIDE 9.15b).
7. Apply Defend exclusions if any are defined.

## Gotchas
`so-setup` **exits 0 on failure** (PORTING_GUIDE 9.3), so its return code proves
nothing. Completion is judged by marker and status, never by rc.

## Privilege
Requires `become: true`, asserted in the first task.

## Complete Example Configuration

### host_vars/so-manager.yml
```yaml
so_hostname: "so-manager"
so_prod_nic: "eth1"
so_prod_ip: "172.16.9.30"
so_prod_prefix: 24
so_prod_netmask: "255.255.255.0"
so_prod_gateway: "172.16.9.1"
so_prod_dns:
  - "172.16.2.7"
```
