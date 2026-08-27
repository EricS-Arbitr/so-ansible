# elastic_agent Role

## Description
Installs the Elastic Agent on range endpoints and enrols them into Security
Onion's Fleet, giving SO endpoint telemetry alongside the network traffic the
sensors capture. Handles Windows and Linux from one entry point.

Installers are fetched from the controller's mirror, not the internet — the
range has no egress.

## Variable Definition Location
Range-wide values in **group_vars/all/main.yml**. The role's defaults derive
most of what it needs from inventory and rarely need overriding.

## Required Variables

### In group_vars/all/main.yml

| Variable | Required | Description |
|----------|----------|-------------|
| so_mirror_host | Yes | Controller mirror the installers are pulled from |
| so_agent_installer_windows | Yes | Windows installer filename staged under `{{ so_mirror_root }}/agents/` |
| so_agent_installer_linux | Yes | Linux installer filename, same location |

## Optional Variables

| Variable | Default | Description |
|----------|---------|-------------|
| so_fleet_host | manager's `so_prod_ip`, from inventory | Fleet server endpoints enrol against |
| so_agent_mirror_url | `http://{{ so_mirror_host }}/agents` | Where installers are fetched |
| so_agent_install_args | "" | Extra installer arguments |
| so_agent_windows_dir | `C:\Windows\Temp\so-agent` | Windows staging directory |
| so_agent_linux_dir | /opt/so-agent | Linux staging directory |
| so_agent_windows_service | Elastic Agent | Service name checked after install |
| so_agent_linux_service | elastic-agent | Service name checked after install |

## Prerequisites
The endpoint's subnet must be permitted to reach Fleet on the manager. The
`75-endpoint.yml` playbook does this before enrolling; running the role on its
own against a subnet the manager does not permit will install an agent that
never registers.

## Verification
Enrolment is confirmed **from Fleet**, not from the endpoint. An agent that
installed and started is not the same as an agent Fleet knows about — the
service can run happily while registration silently failed, which is precisely
the state the Fleet-side check exists to catch.

## Complete Example Configuration

### group_vars/all/main.yml
```yaml
so_mirror_host: "10.255.240.157"   # controller mgmt IP
so_agent_installer_windows: "so-elastic-agent_windows_amd64"
so_agent_installer_linux:   "so-elastic-agent_linux_amd64"
```

### Invocation
```
ansible-playbook -i hosts playbooks/75-endpoint.yml
```
