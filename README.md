# so-ansible

Ansible roles and playbooks that deploy a **distributed Security Onion 2.4**
grid into a cyber range: manager, search node(s) and sensor(s), fed by a
`gretap` tunnel that mirrors router traffic, with optional Elastic Agent
enrolment for endpoints.

The SO nodes need no internet. Everything they install comes from an HTTP
mirror stood up on the Ansible controller.

---

## Adding this to a range?

**Read [docs/IMPLEMENTATION_GUIDE.md](docs/IMPLEMENTATION_GUIDE.md) first.** It
is a step-by-step build guide that assumes no knowledge of this project —
prerequisites, inventory, variables, deploy, verify, and a symptom-to-fix
table. Everything below is orientation; that document is the procedure.

---

## Documentation

| Document | Read it when |
|---|---|
| [docs/IMPLEMENTATION_GUIDE.md](docs/IMPLEMENTATION_GUIDE.md) | **Start here.** Adding Security Onion to a range — step by step, no prior knowledge assumed. |
| `roles/<role>/README.md` | Variables and behaviour for one role. |
| [UPSTREAM_FIXES.md](UPSTREAM_FIXES.md) | Something broke. Every issue with Symptom → Detection → Fix → Status. |
| [PROJECT_LOG.md](PROJECT_LOG.md) | What changed when, and why. |

---

## Roles

| Role | Runs on | Purpose |
|---|---|---|
| `so_apt_mirror` | controller | HTTP mirror of SO install artifacts. Clones the SO source at a pinned commit |
| `vyos_mirror` | router | `gretap` tunnel + `tc mirred` rules copying traffic to the sensor |
| `so_base` | all SO nodes | Packages, proxy, source tree, `/etc/hosts`. Runs before the tier roles |
| `so_manager` | manager | Runs `so-setup`, owns the grid |
| `so_search` | search nodes | Joins the manager, stores and searches |
| `so_sensor` | sensors | Terminates the mirror tunnel, runs Suricata and Zeek |
| `elastic_agent` | endpoints | Installs and enrols agents into SO's Fleet |
| `common`, `init`, `handlers` | all | Copied from the range repos, not authored here |

**Every role requires `become: true` from the calling play** and asserts it in
its first task.

## Playbooks

`site.yml` imports these in order; each depends on the one before.

| Playbook | What it does |
|---|---|
| `00-setup.yml` | Baseline host setup (`init` + `common`) |
| `10-mirror.yml` | Controller mirror |
| `20-vyos.yml` | Router tunnel + traffic mirror |
| `30-prereqs.yml` | `so_base` on every SO node |
| `40-manager.yml` | Manager install — 20–30 minutes |
| `50-nodes.yml` | Search and sensor installs |
| `60-verify.yml` | End-to-end checks |
| `75-endpoint.yml` | Elastic Agent enrolment. **Not** imported by `site.yml` — run it explicitly when a range wants endpoint telemetry |

---

## Commands

```
ansible-galaxy collection install -r requirements.yml   # first time only
sudo ./deploy.sh                                        # full deploy, 3 attempts
sudo ./verify_so.sh -v                                  # health check, verbose
./vault-tools.sh {view,edit,encrypt,decrypt,rekey,check}  # secrets
./build_tarball.sh                                      # package for a range
./pull-tarball.sh                                       # refresh /etc/ansible on the controller
```

Run a single phase:

```
ansible-playbook -i hosts playbooks/40-manager.yml
```

`verify_so.sh` prints its own totals. **The number that matters is Fail: 0** —
the check count moves as checks are added, so treat a changed total as
information rather than a problem, and any failure as a real finding.

---

## Repository layout

```
site.yml                 deploy sequence — imports playbooks/ in order
playbooks/               one file per phase
roles/                   see the role table above; each has a README
group_vars/all/          main.yml (range values) + vault.yml (secrets)
host_vars/               per-node addressing, tunnel endpoints, router interfaces
hosts                    inventory — group names are referenced literally
rules/                   ETOPEN ruleset shipped to the mirror
blueprints/              range blueprint for the development environment
docs/                    implementation and porting guides
```

## Requirements

- Ansible controller: Ubuntu, dual-homed, **HTTPS egress to GitHub once** via a
  management-plane proxy (the mirror clones the SO source; the SO nodes
  themselves need no egress).
- SO nodes: **Ubuntu 22.04**. SO 2.4 rejects other releases.
- A VyOS router carrying the traffic to be captured.
- Collections per `requirements.yml`.
- A vault password at `/home/simspace/.vault_pass` on the controller. **It does
  not survive a range rebuild** — recreating it is the most common first-deploy
  failure.
