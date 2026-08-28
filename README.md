# so-ansible
Ansible roles, playbooks, and helper scripts to deploy a distributed Security Onion deployment via ansible


## Documentation

| Document | Read it when |
|---|---|
| [docs/IMPLEMENTATION_GUIDE.md](docs/IMPLEMENTATION_GUIDE.md) | **Start here.** Adding Security Onion to a range — step by step, assumes no knowledge of this project. |
| [docs/PORTING_GUIDE.md](docs/PORTING_GUIDE.md) | You want the reasoning, measurements and failure history behind a rule, or hit something the build guide does not cover. |
| `roles/<role>/README.md` | Variables and behaviour for one role. |
| [CLAUDE.md](CLAUDE.md) | Working in this repo — owner decisions, conventions, layout. |
| [UPSTREAM_FIXES.md](UPSTREAM_FIXES.md) | Something broke. Every issue with Symptom → Detection → Fix → Status. |

Deploy: `sudo ./deploy.sh` · Verify: `sudo ./verify_so.sh -v` (expect 26/26)
