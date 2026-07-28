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

## 2026-07-28 (later) · bug · Grid-join retry re-invokes 30-45 min of so-setup + so-firewall rejects idempotent re-add

Two idempotency bugs surfaced on the FIRST fully-fresh site.yml deploy
after the 9710406 grid-join reorder.

**Symptom A.** Every re-attempt of the deploy re-invokes so-setup on
search + sensor (30-45 min each). The role's shell task uses
`creates: "{{ so_search_installed_marker }}"` which points at
`/opt/so/state/installed` — but 9710406 moved that marker write to
AFTER so-status verify. On a failed grid-join or verify, the marker
doesn't get written, and the next attempt re-runs so-setup from
scratch. 3 attempts × 30 min = 90+ min just on so-setup no-op'ing.

**Symptom B.** Grid-join first task fails on retry with rc=3:
```
sudo: /usr/sbin/so-firewall: WARNING - IP 172.16.5.15 already exists in hostgroup searchnode
```
`so-firewall includehost` is idempotent semantically but returns
non-zero on the "already exists" path, which ansible sees as a hard
failure by default.

**Fix.**
  A. Introduce a separate `so_search_setup_marker` /
     `so_sensor_setup_marker` at `/opt/so/state/setup-completed`,
     touched immediately after the `so-setup rc=0` check. The shell
     task's `creates:` points at this new marker instead of the final
     `installed` marker. Retries short-circuit past so-setup itself
     but still re-run grid-join + verify.
  B. Add `failed_when` to the `so-firewall includehost` task that
     accepts `'already exists' in fw_add.stderr` as OK:
     ```yaml
     failed_when:
       - fw_add.rc != 0
       - "'already exists' not in fw_add.stderr"
     ```

**Workaround.** None applied — attempted the fix directly.

## 2026-07-28 · KNOWN BUG (DEFERRED) · Sensor's tun0 does not receive decapped GRE packets from the mirror

**Symptom.** With the full stack running (11 sensor containers up,
suricata loaded with 67K ETOPEN rules), suricata reports 0 packets
captured on tun0. `tcpdump -i tun0` also sees 0 packets. Yet router-0
is transmitting mirrored GRE packets (tun0 TX counter increments per
ping), and `tcpdump -i eth1 -nn ip proto gre` on sensor captures the
GRE packets cleanly (14 packets for 5-ping test).

**Detection.** Sequence proved end-to-end:
  1. router-0 tc filter shows `mirred (Egress Mirror to device tun0)` on eth0/eth1/eth2 — ✓
  2. router-0 tun0 TX counter increments correctly per ping — ✓
  3. Sensor eth1 tcpdump captures GRE encapsulated packets from router — ✓
  4. Sensor tun0 kernel RX counter stays at 0 (or stops incrementing) — ✗
  5. `IpInUnknownProtos` counter in nstat shows 588 accumulated — kernel is seeing GRE packets but not routing them to tun0
  6. Suricata's AF_PACKET on tun0 sees 0 packets in stats.log

Attempted fixes that did NOT resolve:
  - `sysctl net.ipv4.conf.tun0.rp_filter=0`, `all.rp_filter=0`
  - `net.ipv4.ip_forward=1`, `tun0.accept_local=1`, `tun0.forwarding=1`
  - `ip link set tun0 down/up` bounce
  - `iptables -F` flush (briefly worked once with 12 packets captured — non-reproducible)
  - Recreated tun0 fresh via `ip tunnel del tun0 && ip tunnel add tun0 mode gre local ... remote ...`
  - Added `iptables -t raw -I PREROUTING -i eth1 -p gre -j NOTRACK`

Earlier in the same range (before the salt highstate re-pushed suricata
config), tun0 was decapping correctly and captured 22-54 packets in
similar tests. Something in the running state broke decap since.

**Fix.** UNKNOWN. Deferred to a dedicated session.

**Investigation avenues for next session:**
  - `dropwatch -l kas` to identify the exact kernel drop point
  - Compare `/proc/net/dev_snmp6` and `/proc/net/snmp` deltas around a ping
  - Try `gretap` (L2 GRE) instead of `gre` (L3) — router-0 side needs matching change
  - Check if `promiscuity: 15` on tun0 (very high) is masking multiple stale references
  - Check for netns leaks — `ip netns ls` + `ss --netlink` to find sockets bound to tun0
  - Bypass tun0 entirely — suricata binds directly to eth1 with a BPF filter on GRE-encapsulated payloads

**Workaround (this deploy).** None. Suricata is running with rules
loaded but sees no traffic — detection engine is effectively idle.
Alerting/hunting from wire traffic will not fire until this is fixed.
Splunk-based log detection (endpoint / DNS / etc.) remains unaffected.

## 2026-07-28 · gap · so-soc's suricataengine can't reach rules.emergingthreats.net from inside the container (no proxy env, embedded DNS misbehaves)

**Symptom.** Sensor's suricata logs show
`W: detect: No rule files match the pattern /etc/suricata/rules/all-rulesets.rules`
+ `W: detect: 1 rule files specified, but no rules were loaded!` The
rules directory (`/nsm/nids/rules/`, `/opt/so/rules/nids/`) is entirely
missing on both sensor and manager. Suricata is running but detecting
nothing.

**Detection.** Read `/opt/sensoroni/logs/sensoroni-server.log` inside
the so-soc container:
```
message":"failed to sync ruleset"
error":"failed to fetch ruleset: failed to download ruleset:
        Get \"https://rules.emergingthreats.net/open/suricata-7.0.3/emerging.rules.tar.gz\":
        dial tcp: lookup rules.emergingthreats.net on 127.0.0.11:53: server misbehaving"
```
Root causes stacked:
  1. so-soc container has NO proxy env vars (`docker exec so-soc env |
     grep -i proxy` returns nothing).
  2. Docker's embedded DNS at 127.0.0.11 can't resolve external hosts
     without upstream DNS or proxy.
  3. Even the per-ruleset `proxyURL` field in soc.json's
     `server.modules.suricataengine.rulesetSources[]` is left empty by
     so-setup.
Also affects: elastalertengine's Sigma rules from github.com + the AI
summary repos + playbooks repo (all fail with the same
"server misbehaving" DNS error).

**Fix (this repo).** Ship the ETOPEN tarball with our so-ansible
tarball and serve it from our existing nginx mirror instead of fetching
from rules.emergingthreats.net. Three moving parts:
  1. `rules/emerging.rules.tar.gz` at repo root — pre-downloaded on the
     developer Mac (has internet). `build_tarball.sh` includes `rules/`
     alongside `files/` if present.
  2. `so_apt_mirror` role — copies the bundled tarball into
     `/var/www/so-mirror/so-source/emerging.rules.tar.gz`, generates
     the `.md5` sibling SOC verifies via, smoke-tests both URLs return
     200.
  3. `so_manager` role — after so-status verify, patches
     `/opt/so/conf/soc/soc.json` to swap
     `https://rules.emergingthreats.net/open/suricata-7.0.3/emerging.rules.tar.gz`
     (+ `.md5`) with `http://{{ so_mirror_url }}/so-source/emerging.rules.tar.gz`
     and restarts so-soc so the running suricataengine picks up the new
     source. From-container fetches to the mirror IP work without proxy
     because URL uses direct IP (no DNS lookup) + docker uses SNAT via
     the host's default route to reach the ansible controller.

**Deferred.** Sigma rules and AI summaries still won't fetch — they're
git-clones against github.com. Options for later: (a) mirror those git
repos too (git http backend on our nginx or gitea), (b) inject
HTTP_PROXY env into the so-soc container definition in salt state,
(c) leave sigma/AI disabled if not needed.

**Workaround (pre-fix).** None applied on the current range — this
fix supersedes the workaround entirely.

## 2026-07-27 (later) · bug · Grid-join tasks ran BEFORE reboot on first fresh deploy; salt-key wasn't yet pending, so-minion no-op'd

**Symptom.** First fully-fresh site.yml deploy: manager came up 14/14
containers green. Search + sensor's roles reported no failures but on
inspection had 0 containers running, so-status was still the 62-byte
stub, salt-keys sat in `Unaccepted Keys`, and per-minion pillars were
missing. The manager-side firewall entries for both nodes WERE
correctly populated (iptables INPUT ACCEPT rules on 4505/4506 for
both IPs), proving the earlier grid-join steps had run.

**Detection.** The role ordering was:
```
1. so-setup (async) → rc=0
2. Write installed marker
3. Grid-join: firewall includehost
4. Grid-join: salt-call state.apply firewall
5. Grid-join: so-minion -o=add    ← race: minion may not have submitted key yet
6. Grid-join: state.highstate --async
7. Reboot                          ← minion restarts here, THEN submits key
8. so-status verify (retry loop)
```
Step 5 ran BEFORE step 7. Immediately after so-setup completed the
salt-minion service was in some intermediate state; the minion's fresh
key hadn't yet been submitted to master when so-minion -o=add fired.
so-minion exited with `does not match any unaccepted keys` — our
`failed_when` idempotency shortcut caught that as "not really a
failure" (was intended for the re-run case where the key was already
accepted) and marked the task OK. Pillar generation was silently
skipped. Step 6's state.highstate --async also fired against a
non-existent minion. Step 7's reboot restarted salt-minion which
finally submitted its key — but nobody would accept it now.
Step 2's marker meant subsequent site.yml retries short-circuited via
the idempotency probe.

**Fix.** Two-part reorder in both `so_search` and `so_sensor`:
  1. Move reboot BEFORE grid-join tasks so salt-minion is definitely
     up + has submitted its key.
  2. Add an explicit `wait_for_key` step: `salt-key --list=unaccepted`
     polled 30 × 10s until the joining node's key appears.
  3. Then run firewall + so-minion + highstate (with the key
     guaranteed present).
  4. Move the installed marker to AFTER `so-status verify` passes so
     failed runs actually re-run grid-join instead of short-circuiting.

**Workaround (this deploy).** Ran the 4 recovery steps manually: `so-minion -o=add`
for both nodes + `salt state.highstate --async` for both + `sed` on sensor's
pillar bond0→tun0 + a second highstate on sensor to pick up the tun0 change.

## 2026-07-27 (later) · bug · 60-verify cluster health task fails on search node — so-elasticsearch-query is manager-only

**Symptom.** 60-verify `SO search cluster health` task fails with
`sudo: so-elasticsearch-query: command not found`.

**Detection.** `/usr/sbin/so-elasticsearch-query` is installed by
manager-side salt states only. Search nodes get elasticsearch itself
(the container) but not the wrapper CLI script. Cluster health is a
whole-cluster metric so querying it from any node (including the
manager) returns the same result — no reason to require search.

**Fix.** Change `hosts: so_search` → `hosts: so_manager` in the
elastic-cluster-health play in [playbooks/60-verify.yml](playbooks/60-verify.yml).

**Workaround (this deploy).** Not needed — 60-verify's own second play
(SOC WebUI etc. on manager) confirmed cluster is up.

## 2026-07-27 · gap · SO's grid-join handshake is incomplete: firewall + per-minion pillar + first highstate all left to the operator

**Symptom.** so_search's role reports `so-setup rc=0` on the joining node
(`Successfully completed setup!` in `/root/so-setup.log`), then reboots,
then hits the so-status verify loop — which fails 8×15s with
`Installation failed - so-status not available`. Salt-minion on the
joiner is active and connected but authentication times out; salt-key on
the manager side shows only its own key accepted; no `docker` binary on
the joiner; the file `/usr/sbin/so-status` is a 62-byte stub that just
echoes the failure message and exits 100.

**Detection.** so-setup's join step signals the manager via SOREMOTEPASS
to prime the salt-key + generate per-minion pillar +
open the firewall. Verified 2026-07-27 that on our platform this handshake
does NOT complete for either search or sensor. Three separate breakages
were required to bring so-search green after `so-setup rc=0`:
  1. Manager's so-firewall soc_firewall.sls pillar only lists `analyst`
     and `manager` hostgroups. Salt master's TCP 4505/4506 is gated by
     the `searchnode` + `sensor` hostgroups (per
     `/opt/so/saltstack/default/salt/firewall/defaults.yaml`). The
     joining node's IP was in NEITHER group → iptables silently drops
     salt-minion's outbound auth → 10-second retry loop forever.
  2. Manager's `/opt/so/saltstack/local/pillar/minions/` only contained
     `so-manager_manager.sls`. Running `state.highstate` on a joining
     node compiled to
     `Specified SLS 'minions.<id>' in environment 'base' is not
     available on the salt master`. Fix: `/usr/sbin/so-minion -o=add
     -m=<minion_id>` accepts the key and generates both the standard
     and `adv_` pillar files.
  3. The `so-status` stub script gets replaced by the real 183-line
     Python script only after a highstate installs the manager-side
     packages. Even after the key + pillar were fixed, the joiner
     needed an explicit `state.highstate` push before so-status
     returned real output.

**Fix.** Bake three delegated tasks into so_search and so_sensor roles
that run on the manager after the joining node's `so-setup rc=0`:
  1. `so-firewall includehost <group> {{ so_prod_ip }}` where group is
     `searchnode` or `sensor`
  2. `salt-call state.apply firewall` (async — may queue behind the
     15-min highstate scheduler)
  3. `so-minion -o=add -m={{ inventory_hostname }}_{{ so_role }}`
  4. `salt {{ minion_id }} state.highstate --async` — fire-and-forget;
     the role's own so-status verify polls until done

Also bump the so-status verify retry loop from `8 × 15s = 2min` to
`40 × 30s = 20min` on both roles to cover the ~10-15 min highstate
convergence window.

**Workaround (this deploy).** Ran the 4 delegated steps manually via
ad-hoc ansible against the manager: `so-firewall includehost` +
`salt-call state.apply firewall` + `so-minion -o=add` + `salt state.highstate`
for each of search + sensor. Baked-in version lands in the same commit
as this entry.

## 2026-07-27 · bug · sensor per-minion pillar defaults to `interface: bond0`, wrong for GRE-mirror deployments

**Symptom.** After the manual grid-join for so-sensor-1, all 11 sensor
containers came up and so-status reported green — but `tcpdump -i tun0`
saw zero packets. Suricata's logs showed engine started + threads
created + rules reloaded, no capture activity.

**Detection.** The per-minion pillar
`/opt/so/saltstack/local/pillar/minions/so-sensor-1_sensor.sls`
(generated by `so-minion -o=add`) contained `sensor: interface: 'bond0'`.
The value is copied verbatim from
`/opt/so/saltstack/default/salt/sensor/defaults.yaml`. But on our
SimSpace platform the sensor has no bond0 members — it's an empty,
DOWN, promiscuous placeholder interface. The real monitor NIC is `tun0`,
the GRE endpoint fed by router-0's tc-mirror rules. Suricata + Zeek
were binding to a phantom interface.

**Fix.** Bake an `ansible.builtin.replace` task into so_sensor role
(delegated to manager, runs after `so-minion -o=add`):
```yaml
- ansible.builtin.replace:
    path: /opt/so/saltstack/local/pillar/minions/{{ inventory_hostname }}_{{ so_role }}.sls
    regexp: "^(\\s*interface:\\s*)'bond0'"
    replace: "\\1'{{ so_monitor_interface }}'"
```
Idempotent — only fires if `bond0` is still in the pillar.

**Workaround (this deploy).** Ad-hoc `sed -i "s/interface: 'bond0'/interface: 'tun0'/"` on the manager's pillar file + a second highstate push.

## 2026-07-27 · bug · 60-verify sensor pcap check produces false-negative on an idle range

**Symptom.** Phase 60 verify's `SO sensor pcap flow rate` task reports
`0 packets captured` even when the GRE mirror is fully functional
(proven separately: 54 packets in 20 s with generated ping traffic).

**Detection.** The task ran a 5-sec passive tcpdump on `tun0`. Router-0
mirrors eth0/eth1/eth2 (Operations/Engineering/Services subnets) into
tun0 → sensor. On this dev range those subnets have Windows placeholder
VMs that are idle when we don't actively drive them, so a 5-sec window
frequently catches nothing. The task's `changed_when: false` meant it
silently reported 0 without failing — worse than a false negative,
because the operator can't tell whether the mirror is broken or the
range is quiet.

**Fix.** Two edits to [playbooks/60-verify.yml](playbooks/60-verify.yml):
  1. Precede the tcpdump with a delegated background task that pings
     each mirrored subnet's router gateway (`172.16.8.1`, `172.16.6.1`,
     `172.16.7.1` — always reachable) from the manager. `async: 30,
     poll: 0` so it fires and returns immediately.
  2. Bump the tcpdump window to 15 sec (covers the ping burst + any
     background chatter) and add `failed_when: "'0 packets captured'
     in pcap_out.stdout"` so the check actually fails on true zero.

**Workaround (this deploy).** Ran manual `tcpdump -i tun0 -c 100 -nn` for
20 sec in parallel with `ping -c 5 172.16.8.5` from manager → captured
54 packets. Proved mirror works; verify task was just badly designed.

## 2026-07-24 · platform · SimSpace platform netplan gives SO nodes a /32 IP with no reachable default gateway, so peer connectivity fails

**Symptom.** so_search's so-setup exits early on `Checking manager
connectivity` — log shows "Could not reach so-manager" 60 s in.
Search node then falls through to a partial install (salt-minion up,
but docker/so-status never install) and the role's `so-status` verify
fails with `Installation failed - so-status not available`. Manager
never sees search's salt-key.

**Detection.** On any SO node (verified on so-search):
```
$ ip -4 addr show eth1
3: eth1: inet 172.16.5.15/32 scope global eth1
$ ip route
10.255.240.0/20 dev eth0 proto kernel scope link src 10.255.240.101
$ cat /etc/netplan/99-netcfg-vmware.yaml
network:
  ethernets:
    eth1:
      addresses:
        - 172.16.5.15/32
      routes:
        - to: default
          via: 172.16.5.1
```
The netplan config *declares* a default gateway at 172.16.5.1, but the
kernel drops the default route because it has no way to reach
172.16.5.1: the /32 address on eth1 puts nothing else on that subnet,
so the gateway is off-link. No `on-link: true` in the netplan config
either.  `ping 172.16.5.10 → Network is unreachable`.

**Fix.** Add an explicit `scope: link` route for the whole security
subnet on the prod NIC via a netplan drop-in. This is technically
correct here — every SO peer is on the same L2 broadcast domain, so
ARP for any 172.16.5.x resolves on eth1. Also fixes the default
gateway indirectly: once 172.16.5.0/24 is on-link, 172.16.5.1 becomes
reachable and netplan's default route installs.

**Workaround.** Baked into `roles/so_base/tasks/main.yml` as a
`copy: /etc/netplan/60-so-onlink.yaml` + `netplan apply` + verify-ping
to the manager. Applied to running search/sensor/manager via
`ip route add 172.16.5.0/24 dev eth1 scope link` (non-persistent — the
baked netplan drop-in takes over on next `netplan apply`/reboot).

## 2026-07-23 · bug · Python-based salt state probes fail against loopback because no_proxy CIDR notation is ignored

**Symptom.** Manager deploy hits Phase 40 verify (highstate + so-status)
and hangs. `state.apply kratos` runs to `wait_for_kratos` sub-state
(`http.wait_for_successful_query` against `http://so-manager:4434/`)
which retries for 300 s and fails with "Statuses [200, 301, 302, 404]
were not found." Meanwhile `curl -sk --noproxy '*' http://127.0.0.1:4434/`
returns 307 immediately — kratos is healthy. Manual `curl http://127.0.0.1:4434/`
(no `--noproxy`) returns 503 with a Squid error page as the body.

**Detection.** `/etc/environment` (rendered by so_base) contained
`no_proxy="localhost,127.0.0.0/8,10.255.240.0/20,..."`. curl honors
CIDR notation for no_proxy; **Python's urllib/requests do not** —
they only match against literal hostnames and `.domain` suffixes.
Salt's `http.query` uses Python, so `127.0.0.1:4434` was still routed
through the corp Squid at `10.255.240.1:3128`, which returned 503 for
the unroutable-from-its-perspective loopback address.

**Fix.** Amend `no_proxy` / `NO_PROXY` to include explicit hostnames
in addition to CIDR: `127.0.0.1` (explicit IP) plus every SO node's
short and .localdomain hostname. Both curl (CIDR) and Python (literal
names) then bypass the proxy for loopback + peer nodes.

**Workaround.** Baked into `roles/so_base/templates/environment.j2`
via a `{% for h in groups['so_all'] %}` loop appending
`,{{ h }},{{ h }}.localdomain`. Applied to running manager via `sed`
+ `systemctl restart salt-minion` to pick up new env before proceeding.

## 2026-07-23 · bug · so-kratos crash-loops on first start because /nsm/kratos/db/db.sqlite is pre-created as root:root

**Symptom.** so-kratos container listed as "Up" in `docker ps` but
`docker logs so-kratos` shows endless `chown: changing ownership of
'/kratos-data/db.sqlite': Operation not permitted` (dozens of lines,
one per restart). `docker exec so-kratos ls -la /kratos-data/` shows
`db.sqlite` owned by root:root, 0 bytes. `/opt/so/log/kratos/kratos-migrate.log`
shows `attempt to write a readonly database` on every start.

**Detection.** so-kratos container's entrypoint (`/start-kratos.sh`)
runs as UID 928 (kratos user, non-root — set by USER directive in
the SO dockerfile). Sequence is: (1) `kratos migrate sql`, (2)
`chown kratos:kratos db.sqlite`, (3) `chmod 600 db.sqlite`, (4)
`kratos serve`. `chown` from non-root fails EPERM; but that's cosmetic.
The real problem: `db.sqlite` was pre-created by an earlier SO init
step (probably a salt state's `file.managed` or a docker volume
initializer) as root:root, so migrate can't write to it as UID 928
→ migrate exits non-zero → container restarts before `serve` → loop.

**Fix.** Pre-chown `/nsm/kratos/db/` and (if it exists) `db.sqlite`
to UID:GID 928 in the so_base role, before the kratos container ever
runs. On a fresh install the file doesn't exist yet, so we create
the parent dir with the right ownership and let kratos create the
file itself (which then inherits parent-dir group semantics correctly).
On a broken install (like this one — root-owned empty db.sqlite from
a prior failed run), pre-chown re-owns it to 928:928 so kratos can
write.

**Workaround.** Baked into `roles/so_base/tasks/main.yml` as a
`when: so_role == 'manager'`-guarded stanza after the docker daemon
proxy config. Applied to running manager via `sudo chown 928:928
/nsm/kratos/db/db.sqlite && sudo chmod 600 ... && docker restart
so-kratos`; kratos migrated 663 schemas successfully and started
serving on 4433/4434.

## 2026-07-22 (later) · gap · SO's `master` branch is 2.3.300 (legacy); 2.4 development is on `2.4/main` and has NO answer-file mechanism

**Symptom.** Phase 40 fails partway through so-setup: whiptail dialog
shows "Security Onion Setup - 2.3.300" (not 2.4). Log at
/root/so-setup.log shows so-setup gathering management IP + repeated
`RTNETLINK answers: Network is unreachable` before whiptail fails to
open a terminal.

**Detection.** Reading the VERSION file at pinned SHA:
```
$ curl -fsSL "https://raw.githubusercontent.com/Security-Onion-Solutions/securityonion/master/VERSION"
2.3.300
```

Cross-check branches:
```
2.3/main    ← legacy 2.3
2.4/main    ← current 2.4 stable (2.4.211)
2.4/dev     ← 2.4 development
master      ← ALSO 2.3.300 (aliased to 2.3/main historically)
```

The 2-week-old subagent research report referenced "master" and I
misread it as "current 2.4 development." It was factually correct that
master has the setup/automation/ answer-file mechanism — but master IS
2.3.300, not 2.4.

Verification: none of `2.4/main`, `2.4/dev`, or any tagged 2.4.x
release has `setup/automation/`. The `test_profile` positional arg on
those branches is limited to internal SO CI hardcoded profiles, not a
customer-facing mechanism.

**Root cause.** SO project's 2.4 development discarded the automation-
file mechanism (whether intentionally or not, unclear). Non-interactive
2.4 install is unsupported.

**Fix (upstream).** SO project should either backport the automation-
file mechanism into 2.4/main or explicitly document a supported way to
run so-setup non-interactively. Without either, every deployer of SO 2.4
at scale writes their own pexpect wrapper.

**Fix (overlay, this project).**
1. Re-snapshot `so-setup`, `so-functions`, `so-variables`, `so-whiptail`
   from `2.4/main` HEAD (SHA `55af7eb541f086c4e7d6d3182fb2bc4fbc2b9e21`
   at 2026-07-22) into `roles/so_base/files/setup-automation-source/`.
2. Drop the `distributed-*` templates from that directory — they only
   exist on 2.3.300's master and don't apply to 2.4.
3. Update `so_git_ref` in `group_vars/all/main.yml` to the 2.4/main
   HEAD SHA + `so_git_branch: "2.4/main"`.
4. Stub `so_manager`, `so_search`, `so_sensor` roles with `fail:` tasks
   until a pexpect wrapper implementation lands in a follow-up session.
5. Fix `so_base` idempotency: the pre-baked SO 2.3.300 install at
   `/root/manager_setup/securityonion/` on the SimSpace RDP_Ubuntu_Desktop
   image false-positived our old "does setup/so-setup exist" check.
   Replaced with a marker file `.so-ansible-pinned-<sha[:12]>` that
   embeds the pinned SHA, so a bump forces re-extract.

**Follow-up.** Author a pexpect Python script per role that drives
whiptail prompt-by-prompt with answers rendered from Jinja +
group_vars + host_vars + vault. Snapshot exact prompt text for schema
diffing on SO version bumps. Estimated 8-12 hours role rewrite;
scheduled for the next session.

**Related.** UPSTREAM_FIXES 2026-07-20 (undocumented so-setup non-
interactive mode), 2026-07-21 (Ubuntu can't do airgap SO 2.4), and
2026-07-22 (jammy hack of so-functions) are all superseded by this
finding. The whole "use master's automation mechanism" plan was
predicated on master being 2.4-in-progress; it isn't.

---

## 2026-07-22 · bug · Security Onion master's `setup/so-functions` doesn't accept Ubuntu 22.04 (jammy)

**Symptom.** Phase 40 (so_manager) invokes `so-setup network so-ansible-manager`
which exits with rc=1 in 0.2 s. Log at `/root/so-setup.log` on so-manager:
```
Getting started...
We do not support your current version of Ubuntu.
```

**Detection.** `grep 'do not support' /root/manager_setup/securityonion/setup/so-functions`
shows the reject block:
```
elif [ -f /etc/os-release ]; then
    OS=ubuntu
    if grep -q "UBUNTU_CODENAME=bionic" /etc/os-release; then
        OSVER=bionic
    elif grep -q "UBUNTU_CODENAME=focal" /etc/os-release; then
        OSVER=focal
    else
        echo "We do not support your current version of Ubuntu."
        exit 1
    fi
```

master's `so-functions` (SHA `94c7dabd...` from 2026-07-20) only accepts
bionic (18.04) + focal (20.04). Our blueprint image is
`RDP_Ubuntu_Desktop_22.04.5:1.1.0` → jammy → hard reject.

**Root cause.** SO master's `setup/` dir is INCONSISTENT with itself:
- `setup/automation/distributed-net-ubuntu-{manager,search,sensor}` templates
  clearly target Ubuntu network install
- `setup/so-functions`'s OS detection hasn't been updated to accept jammy yet

Cross-referenced with tagged releases: every tag from 2.4.180 through
2.4.211 DOES accept jammy in `so-functions` (adds `elif
UBUNTU_CODENAME=jammy → OSVER=jammy; UBVER=22.04`). But those tags LACK
`setup/automation/` → no answer-file mechanism. Dead end either way.

Downstream complication: `OSVER` is used in salt apt repo URL:
```
echo "deb https://repo.securityonion.net/file/securityonion-repo/ubuntu/$ubuntu_version/amd64/salt3004.2/ $OSVER main" > /etc/apt/sources.list.d/saltstack.list
```
Setting OSVER=jammy would produce a repo URL for jammy salt packages that
doesn't exist. Setting OSVER=focal produces the working URL but pulls
focal-targeted salt 3004.2 packages onto a jammy kernel/glibc.

**Fix (upstream).** SO project should reconcile the setup/automation/ vs
setup/so-functions inconsistency at master. Either backport the jammy
detection block into master OR promote the automation mechanism into a
tagged release.

**Workaround (overlay).** Patched `so-functions` in
`roles/so_base/files/setup-automation-source/so-functions` to add:
```
elif grep -q "UBUNTU_CODENAME=jammy" /etc/os-release; then
    OSVER=focal
```
Fakes jammy AS focal so downstream conditionals + repo URL still match.
Cost: salt 3004.2 focal-targeted packages may fail glibc/kernel compat
on jammy. If so, the setup log will show the exact package install
failure and we can decide next steps (install newer salt manually, or
petition SimSpace for a focal base image).

**Follow-up.** After a first Phase-40 attempt reveals whether salt
install survives the version mismatch, either (a) mark this workaround
stable, or (b) escalate to switching the base image to Ubuntu Server
20.04 (focal — native SO 2.4 support with no patches) or Rocky (fully
airgap-capable per the 2026-07-21 finding).

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

---

## 2026-07-21 (later) · gap · airfield-range `common` + range-development-ansible `init` roles unusable for so-ansible

**Symptom.** First live dry-run of phase 10 (mirror) failed on the
ansible controller itself with `'network_interfaces' is undefined`.
Attempts 2 + 3 same error → deploy loop exhausted.

**Root cause.** The airfield-range `common` role was copied per the
role-sourcing policy but its Linux task file
(`roles/common/tasks/linux.yml`) is a full NetworkManager reconfig
driven by a `network_interfaces` host_vars dict of the form:
```
network_interfaces:
  - name: Ethernet0
    ipv4: {type: static, address: ..., netmask: ..., gateway: ...}
    dns: [...]
```

so-ansible host_vars use flat scalar fields (`so_prod_ip`,
`so_prod_prefix`, `so_prod_gateway`, `so_prod_dns`) — no
`network_interfaces` dict. The common role's first `loop:
"{{ network_interfaces }}"` blows up with the "undefined" error.

Even if we defined the dict, running `common` is the wrong play here:
1. On the ansible controller (`10-mirror.yml`), the box is up + working;
   reconfiguring its NetworkManager + tearing down systemd-networkd +
   forcing a reboot mid-deploy is asking for a broken controller.
2. On SO nodes (`30-prereqs.yml`), `so-setup network` does its OWN
   netplan write for the MNIC based on the answer file's MIP/MMASK/
   MGATEWAY/MDNS. Running common's netplan writes before so-setup
   would conflict.

Also discovered same session: `range-development-ansible`'s `init`
role is Windows-only (`win_ping` + `wait_for_connection` targeting
Windows). Blindly copied per role-sourcing policy but no Linux value.

**Fix (overlay).** Dropped `common`, `init`, `handlers` (dep of common)
from `roles/` entirely. Removed the corresponding role references from
`playbooks/10-mirror.yml` and `playbooks/30-prereqs.yml`. so_base is
now the single source of Linux prep for SO nodes:
- apt prereqs
- proxy env + APT proxy
- /etc/hosts peer entries
- SO source tarball fetch + snapshotted so-setup overlay
- UFW disabled

The ansible controller runs ONLY `so_apt_mirror` (no baseline reconfig).

**Follow-up.** Role-sourcing memory (`project_airfield_role_sourcing`)
implies "copy every used role from PowerPlant/airfield-range". Should
amend the memory: **only if the role's schema matches this project's
host_vars conventions and its behavior is appropriate for the target
lifecycle**. Blindly copying can produce silent breakage (common's
Linux path requires a dict we don't use; init is Windows-only). Better
default: prefer targeted mini-roles authored in-project.

**Related.** `common` still has a `hostname.yml` sub-task file (per
`common/tasks/hostname.yml`) that IS reusable — just sets `hostname`
from `inventory_hostname`. If we ever need explicit hostname
management (SO's HOSTNAME answer var covers this today), pull out
that sub-task standalone rather than importing all of common.

---

## 2026-07-22 · gap · so_apt_mirror missing APT proxy config on ansible controller

**Symptom.** Second live dry-run: phase 10 failed on the ansible
controller with `Failed to update apt cache: unknown reason` at
`so_apt_mirror : Install nginx + git`.

**Root cause.** The RC_NG_Ansible SimSpace image doesn't ship with an
apt proxy pre-configured — only shell env vars (`http_proxy`,
`https_proxy`) in `/etc/environment`. Ansible's `apt` module's
`update_cache: yes` invokes `apt-get update` which does NOT read
those env vars; apt reads its own config from `/etc/apt/apt.conf.d/`.
Without an `Acquire::http::Proxy` directive, apt tries to reach
`archive.ubuntu.com` directly through the mgmt plane (no route to
external) and fails silently — Ansible surfaces the generic
"unknown reason" wrapper.

Notably, `so_base` already has this exact fix for SO nodes (writes
`/etc/apt/apt.conf.d/95so-proxy` with `Acquire::http::Proxy
"{{ so_upstream_proxy }}"`). `so_apt_mirror` was missing the same task
because I incorrectly assumed the controller's apt was pre-configured.

**Fix (overlay).** Prepend an `apt.conf.d/95so-proxy` copy task to
`so_apt_mirror`, using `so_mirror_proxy` (same value as
`so_upstream_proxy`) so `apt-get update` can reach ubuntu.archive
through the range's mgmt-plane HTTP proxy. Task runs before the first
`apt` module call, so no chicken-and-egg.

**Follow-up.** Ask the platform team to bake `/etc/apt/apt.conf.d/95proxy`
into the RC_NG_Ansible base image (alongside the existing shell env
vars). Every project that uses this image hits the same first-run
"apt update fails" trap and has to solve it in role code.

**Amendment (2026-07-22, same day).** APT proxy conf landed correctly but
apt still failed with "unknown reason". Direct `sudo apt-get update`
revealed the actual error: RC_NG_Ansible ships with stale
`apt.puppet.com` + `apt.puppetlabs.com` sources whose signing keys have
expired (`EXPKEYSIG 4528B6CD9E61EF26 Puppet, Inc. Release Key`).
`apt-get update` succeeds fetching ubuntu.archive + security.ubuntu.com
but returns a non-zero overall exit code because of the puppet-repo
signature failures. Ansible's `apt` module treats any non-zero from
`apt-get update` as fatal, hence the misleading "unknown reason"
wrapper.

**Amended fix (overlay).** Split into two tasks:
1. `ansible.builtin.shell: apt-get update 2>&1 | tail -3` with
   `failed_when: false` — swallows the puppet signature error.
2. `ansible.builtin.apt: ... update_cache: no` — installs using the
   cache that step 1 refreshed (ubuntu.archive contents are all fresh).

Applied to both `so_apt_mirror` (ansible controller) and `so_base` (SO
nodes) since the same trap will bite if the SO Ubuntu base image ships
similar stale third-party sources.

**Additional follow-up.** Ask the platform team to either (a) refresh
the Puppet signing key + repo state in RC_NG_Ansible, or (b) drop the
Puppet repos entirely if nothing on the image needs them. Every project
inherits the stale sources and either fails hard (like we did) or has
to work around them in role code.
