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

Format: `## YYYY-MM-DD · <severity> · <target>` followed by Symptom →
Detection → Fix → Workaround → **Status**.

**Status key** (convention added 2026-07-28). Every entry carries exactly one:
- **PROPOSED** — fix is written + committed but has not yet been exercised
  on a deploy. Not trustworthy yet.
- **VERIFIED** — fix confirmed working, with the evidence named (which
  deploy run, which task output). This is the only status that counts as done.
- **OPEN** — root cause not yet determined, or deliberately deferred.
- **SUPERSEDED** — replaced by a later entry; kept for history.

### Status 2026-07-28 ~23:57 — PHASE 50 COMPLETE

so-sensor-1 **joined the grid**. It cleared so-setup, stale-key deletion,
salt-key acceptance, per-minion pillar generation and `so-status` verify.
Entries (later 3) through (later 8) are all effectively closed on the
live range.

`site.yml` now reaches **phase 60 verify** and fails on exactly one
check: the 15-second tcpdump on `tun0` returns `0 packets captured`. That
is the (2026-07-28) tun0 decap bug — now the sole blocker.

Note the earlier decap evidence must be **re-gathered, not trusted**: it
was collected while Suricata was bound to a dead `bond0` and before
`INTERFACE=tun0` reached the pillar. This failure is a raw `tcpdump` on
`tun0` though, independent of Suricata, so the kernel-level symptom is
confirmed to persist.

**New suspect introduced by the (later 7) fix:** with `/etc/SOCLOUD` set,
`configure_network_sensor()` now runs
`nmcli con add ifname tun0 con-name tun0 type ethernet ipv4.method
disabled ethernet.mtu 9000` against `tun0`. NetworkManager taking
ownership of a GRE device — and trying to force MTU 9000 on a 1476-MTU
tunnel — could plausibly disturb the tunnel's GRE parameters. Verify
`ip -d link show tun0` still reports `gre remote 172.16.5.1 local
172.16.5.20` before pursuing deeper kernel theories.

### Open / unverified items (the short list)

Everything not listed here is VERIFIED. Update this table in the same
turn you change any entry's status.

| Date | Item | Status |
|---|---|---|
| 2026-07-28 | so-setup "Could not reach so-manager" (60s timeout, non-fatal) | OPEN |
| 2026-07-28 | What originally created `setup-completed` on a node where so-setup never ran | OPEN (harmless now) |
| 2026-07-28 | so-soc sigma rules + AI summaries can't git-clone github.com | OPEN (sub-item) |
| 2026-07-22 | `platform_proxy` role adoption (tech debt, CLAUDE.md §5) | OPEN (deferred) |
| 2026-07-28 (later 5) | Ad-hoc `ansible` needs `sudo` (vault perms) | OPEN (documented) |

**Everything else is VERIFIED.** Full stack green 2026-07-29:
`site.yml` reports `Success on attempt 1` with zero failed tasks, and
`verify_so.sh` reports **26/26 pass, 0 fail** across all six sections.

---|---|---|
| 2026-07-28 (later 6) | NetworkManager eth0 profile mismatch | VERIFIED (fixed by later 7) |
| 2026-07-29 (later 11) | 60-verify pinged gateway IPs — generated no mirrorable traffic | PROPOSED |
| 2026-07-29 (later 10) | Injected rule concatenated; restore silently skipped | PROPOSED |
| 2026-07-29 (later 9) | `end_host` probe makes installed nodes immune to new tasks | PROPOSED |
| 2026-07-28 (later 8) | Master rejects regenerated minion key (Denied) | VERIFIED (diagnosis); role fix PROPOSED |
| 2026-07-28 (later 8b) | Our guard probed `/etc/salt/minion_id`, which never exists | PROPOSED |
| 2026-07-28 (later 6) | so-setup exits 0 on failure; use /root/failure | PROPOSED (guard) |
| 2026-07-28 (later 7) | `BNICS=tun0` ignored; so-setup binds bond0 | VERIFIED |
| 2026-07-28 (later 6) | so-setup "Could not reach so-manager" (non-fatal) | OPEN |
| 2026-07-28 (later 5) | Ad-hoc `ansible` needs `sudo` (vault perms) | OPEN (documented) |
| 2026-07-28 (later 4) | so-setup never ran on sensor; self-blessing marker | VERIFIED |
| 2026-07-28 (later 3) | Grid-join `salt-key` hardcoded to wrong path | VERIFIED |
| 2026-07-28 | Sensor `tun0` decap — root cause CONFIRMED (SO firewall drops GRE); durable fix pending | OPEN (fix design) |
| 2026-07-28 | so-soc sigma rules + AI summaries still can't git-clone github.com | OPEN (sub-item) |
| 2026-07-22 | `platform_proxy` role adoption (tech debt, CLAUDE.md §5) | OPEN (deferred) |

---

## 2026-07-29 (later 12) · bug · verify_so.sh reported 13/26 failures on a fully healthy stack — the checks could not pass

**Symptom.** `./verify_so.sh -v` against the green stack: 13 pass, 13
fail. But **every failing check displayed correct data** — `so-status`
returning "ready to make your adversaries cry", cluster health `green`,
`salt-minion` `active`, nginx `active`.

**Root cause #1 — `--one-line` vs anchored patterns.** `check_sh` ran
`ansible ... --one-line`, which collapses output to:
```
ansible | CHANGED | rc=0 | (stdout) active
```
then grepped it with anchored expectations like `^active$`,
`^(green|yellow)$`, `^200$`. Those can never match a line beginning with
`ansible | CHANGED`. **Structurally impossible to pass**, regardless of
system health. Fixed by dropping `--one-line` and stripping ansible's
header line before matching.

**Five more real bugs found in the same pass:**
  2. **`so-status` expectation was never right** — expects `STATUS: OK`;
     SO actually prints `✔ This onion is ready to make your adversaries
     cry!`. Now matches `adversaries cry|STATUS: OK`. (3 occurrences.)
  3. **SOC WebUI expected 200/302** but 307 is the correct kratos redirect
     — documented in the 2026-07-23 notes, never reflected in the check.
  4. **Tarball glob** `ls .../*.tar.gz | head -1` returns
     `emerging.rules.tar.gz` alphabetically, then expects
     `securityonion-*`. Now globs `securityonion-*.tar.gz` directly.
  5. **VyOS reachability** used `vyos_command` over the default ssh
     connection → *"Connection type ssh is not valid for this module"*.
     `probe_group` now takes extra args and passes `-c network_cli`.
     host_vars deliberately does not pin `ansible_connection` (it would
     override play-level settings in vyos_mirror), so ad-hoc must supply it.
  6. **`tc` checks used the WRONG interfaces** — looped `eth1 eth2 eth3`,
     but the mirrored set is `eth0 eth1 eth2` (eth3 is the security subnet,
     eth4 is mgmt). It tested one interface that is deliberately not
     mirrored and skipped one that is. Also `tc` is not on VyOS's
     non-interactive PATH → now `sudo /sbin/tc`.
  7. **salt-key check** matched `so-search.*so-sensor-1` across lines,
     which only worked by accident under `--one-line`. Now pipes through
     `tr '\n' ' '`.

**Lesson (second time today).** This is the same failure mode as
(later 11)'s traffic generator: a verification that cannot pass, or that
fails for reasons unrelated to what it claims to verify. Both actively
misdirected debugging. `verify_so.sh` had never been run against a fully
healthy stack, so its expectations had never once been exercised against
reality — they were written from assumption and inherited every wrong
guess.

**Status.** VERIFIED — re-run 2026-07-29: **26/26 pass, 0 fail**, "All
checks passed." Every section green including the three `tc mirred` rules
on the correct interfaces (eth0/eth1/eth2) and `tun0` receiving mirrored
packets.

## 2026-07-29 (later 11) · bug · 60-verify's traffic generator pinged the ROUTER's gateway IPs, which produces no mirrorable traffic at all

**Symptom.** With the GRE firewall fix confirmed working (`ok=43`, the
syntax check, proto-47 verify and report all passing), the phase-60 pcap
check STILL reported `0 packets captured` on `tun0`.

**Root cause — the test was wrong, not the system.** The generator did:
```bash
for gw in 172.16.8.1 172.16.6.1 172.16.7.1; do ping -c 6 ... "$gw" & done
```
Those are **router-0's own interface addresses**. A packet addressed to
the router is *locally delivered* on the interface it arrives on (eth3,
security) — it never egresses eth0/eth1/eth2, which is where the
`tc filter ... action mirred egress mirror dev tun0` rules live. So the
"traffic generator" generated exactly zero mirrorable packets.

The task's own comment had the right principle — "what matters is router-0
having outbound traffic on eth0/eth1/eth2 to mirror" — but the chosen
targets defeated it, and the trailing note "Uses gateway .1 IPs (router
itself) — always reachable" optimized for reachability over correctness.

**Why this mattered so much.** This check has been failing since
2026-07-27 and was read as evidence of a broken mirror. It **masked the
real GRE firewall bug for several deploy cycles**, and even after that bug
was found and fixed, it kept failing and looked like the fix hadn't
worked. Two separate defects producing one identical symptom.

**Fix.** Target host addresses ON the mirrored subnets instead, hoisted
into a `so_verify_mirror_targets` play var:
`172.16.8.5` (ops-wks-01), `172.16.6.11` (eng-wks-01), `172.16.7.7` (DC01).
Unresponsive targets are fine — the router still ARPs out the mirrored
interface, and ARP frames are mirrored too (confirmed: `gre-proto-0x806`
observed encapsulated on the wire). Also raised the burst to
`-c 10 -i 0.5` so it comfortably fills the 15s capture window.

**Lesson.** A verification that can fail for reasons unrelated to what it
claims to verify is worse than no verification — it actively misdirects.
This one asserted "GRE mirror is delivering" while testing a path that
never touched the mirror.

**Status.** VERIFIED — deploy run 2026-07-29, `Success on attempt 1`.
The pcap check passed with **48 packets captured** on `tun0`, including
`ARP, Reply 172.16.6.11 is-at 00:50:56:a8:d9:b9` — proof the mirrored
subnets are the ones being exercised.

## 2026-07-29 (later 10) · bug · Injected GRE rule concatenated onto the previous line; `iptables-restore` silently skipped

**Symptom.** The GRE tasks ran, `salt-call state.apply firewall` reported
`changed`, and the verification still found no proto-47 rule in
`iptables -S INPUT`.

**Detection.** `/etc/iptables/rules.v4` line 35 on the sensor:
```
-A INPUT -p icmp -j ACCEPT-A INPUT -s 172.16.5.1 -p gre -j ACCEPT
```
Two rules on ONE line. Invalid syntax → `iptables-restore --test` fails →
`init.sls`'s `onlyif` skips the restore → salt reports success because the
*file* changed, while the running ruleset never updated.

**Root cause — two whitespace rules compounding, both ours:**
  1. **Ansible templates with `trim_blocks=True`**, which ate the newline
     immediately after `{% endraw %}` in the `so_gre_rule_block` default —
     putting the literal `{%- if %}` guard and the rule on the same line.
  2. **Salt's `{%-`** then stripped the newline BEFORE it, gluing the
     result onto the preceding `-A INPUT -p icmp -j ACCEPT`.

Writing Jinja that is rendered by Ansible and *then* rendered again by
Salt means two independent whitespace-control regimes apply in sequence.
That is a bad place to be clever.

**Fix.** Drop the Jinja from the injected text entirely — emit a plain
`-A INPUT -s <gw> -p gre -j ACCEPT\n`. The anchor already begins its own
line, so prefixing directly is correct with no whitespace control at all.

**Consequence — role guard dropped.** Manager and search nodes now also
receive the ACCEPT, since they render the same template. Deliberate: it is
a no-op there (no GRE tunnel, so the kernel drops proto 47 at demux) and
it buys immunity from the Jinja-in-Jinja fragility. Still
source-restricted to the router's mirror endpoint, not `0.0.0.0/0`.

**Also added.** An explicit `iptables-restore --test /etc/iptables/rules.v4`
task. `init.sls` skipping its restore is a SILENT failure by design, so
without this a malformed ruleset shows up only as a mysterious "rule not
present" — which is exactly the detour this bug caused.

**`file_roots` confirmed correct** during this investigation:
```
file_roots:
  base:
    - /opt/so/saltstack/local/salt
    - /opt/so/saltstack/default/salt
```
The override mechanism was sound; only the injected text was wrong.

**Status.** VERIFIED — deploy run 2026-07-29. so-sensor-1 reached
`ok=45 changed=3 failed=0`; the syntax check, the proto-47 verify and the
pcap check all passed.

## 2026-07-29 (later 9) · bug · Role's `meta: end_host` idempotency probe makes an installed node unreachable by ANY new task

**Symptom.** The GRE firewall fix was committed, deployed, and silently
did nothing. so-sensor-1 showed `ok=36 changed=0` — the exact same task
count as the run before the fix existed — and the pcap check still
reported `0 packets captured`.

**Root cause.** `so_sensor/tasks/main.yml` opens with:
```yaml
- name: Idempotency probe
  ansible.builtin.stat:
    path: "{{ so_sensor_installed_marker }}"
  register: so_installed

- name: End play early if SO is already installed
  ansible.builtin.meta: end_host
  when: so_installed.stat.exists
```
`/opt/so/state/installed` exists once a node has completed successfully,
so the role ends the host immediately. **Any task appended to the role
can never reach an already-installed node.** The fix was in the tarball,
on the controller, and never executed.

**This is the third variant of the same family tonight** — a guard that
blocks its own remediation:
  1. (later 4) `creates:` marker that blessed itself and skipped the only
     task that could repair the node.
  2. (later 8b) `minion_id` probe that could never be satisfied, so the
     skip decision was permanently false.
  3. (later 9) `end_host` probe that makes installed nodes immune to new
     tasks entirely.

**Fix.** Move the GRE firewall block ABOVE the idempotency probe, with a
header comment explaining why it must stay there. Added a grid-member
check (`/etc/salt/pki/minion/minion_master.pub`) so the `salt-call
state.apply firewall` nudge is skipped on a fresh sensor, where it would
run before grid-join and fail — a fresh node needs no nudge anyway,
because the manager-side override is written before its first highstate.

**General lesson for this repo.** `meta: end_host` is a blunt instrument.
Anything that must hold true for the *lifetime* of a node — firewall
invariants, config overrides, drift correction — belongs BEFORE the
idempotency probe. Only the expensive one-time install work belongs after
it. Worth auditing `so_search` and `so_manager` for tasks that are
silently unreachable on installed nodes.

**Status.** VERIFIED — deploy run 2026-07-29. The GRE firewall tasks
executed on an already-installed node (task count rose 36 → 45), which is
exactly what the `end_host` move was for.

## 2026-07-28 (later 8) · bug · salt-minion lands in `failed` state; `/etc/salt/minion_id` never written; so-setup flags `StreamClosedException`

**Symptom.** so-setup runs to completion (reaches `Verifying setup`) and
exits 0, but writes `/root/failure`. `/root/errors.log` contains only:
```
[ERROR   ] Encountered StreamClosedException
```

**Detection.** Deploy run 2026-07-28 ~22:53-22:55, so-sensor-1.

**State of the node afterward:**
  - `systemctl is-active salt-minion` → **`failed`** (rc=3)
  - `/etc/salt/` contains `grains`, `minion`, `minion.d/`, `pki/`,
    `minion.dpkg-dist` — but **no `minion_id`**, despite so-setup logging
    `MINION_ID = so-sensor-1_sensor`
  - Consequently no key is ever presented to the master, which is the
    original grid-join symptom from (later 4)

**The two exception hits are ONE error.** `grep -n StreamClosed
/root/sosetup.log` returns lines 30 and 977:
  - **Line 30** is the real occurrence, inside the *cleanup* phase —
    right after `Old setup detected. Preparing for reinstallation.` /
    `Putting system in state to run setup again` / `no crontab for root`,
    during a `salt-call` applying `ca/remove.sls`. It is immediately
    followed by `result: True`.
  - **Line 977** is SO's end-of-run `--------- ERRORS ---------` summary
    re-printing the same captured error.
So the exception is an artifact of the **reinstall path** on a node that
had a previous install, not a second independent failure.

**ROOT CAUSE CONFIRMED.** `journalctl -u salt-minion` shows the same
cycle on all three start attempts (22:47, 22:51, 22:55):
```
[INFO    ] Setting up the Salt Minion "so-sensor-1_sensor"
[INFO    ] Generating keys: /etc/salt/pki/minion
[CRITICAL] The Salt Master has rejected this minion's public key!
To repair this issue, delete the public key for this minion on the Salt
Master and restart this minion.
salt-minion.service: Main process exited, code=exited, status=77/NOPERM
```
so-setup **regenerates the minion keypair on every (re)install**. The
master still held the OLD public key for `so-sensor-1_sensor`, so it
rejected the new one. The minion exits before ever presenting a key to
the Unaccepted queue — which is precisely why the (later 4) grid-join
wait loop saw an empty list. Same root cause, one layer down.

**Correction — `minion_id` was a red herring.** This SO version never
writes `/etc/salt/minion_id`; it sets the id inside `/etc/salt/minion`
(`id: 'so-sensor-1_sensor'`). The minion was identifying correctly all
along.

This exposed a **defect in our own (later 4)/(later 6) guard**: it probed
`/etc/salt/minion_id` as proof of a successful install. That file never
exists, so `so_setup_can_skip` was permanently false — every attempt
would have re-run 30-45 min of so-setup forever — and the post-condition
would have failed even on a genuinely good install. Fixed by probing
`/etc/salt/minion` instead, in both roles.

**Fix (applied).** Before the reboot, delegate to the manager:
`salt-key -d <inventory_hostname>_<so_role> -y`, so the stale key is
removed and the freshly generated one arrives as Unaccepted for the
existing grid-join tasks to accept. `failed_when: false` because "does
not match any accepted, unaccepted or rejected keys" is the expected
no-op on a first install. Gated on `not so_setup_can_skip` so a healthy
grid member's key is never touched.

`StreamClosedException` is confirmed incidental — it fires once during
the reinstall cleanup phase and is immediately followed by `result: True`.
Whitelisting it as benign was considered and **rejected**: the minion was
genuinely broken, so suppressing the error would have hidden a real
failure. The guard behaved correctly.

**Status.** VERIFIED (diagnosis + manual fix) 2026-07-28. Running the fix
by hand on the live range confirmed it exactly:
```
# salt-key -d so-sensor-1_sensor -y
The following keys are going to be deleted:
Denied Keys:
so-sensor-1_sensor
Unaccepted Keys:
so-sensor-1_sensor
Key for minion so-sensor-1_sensor deleted.
[INFO    ] Rotating AES key
```
then after `systemctl restart salt-minion` on the sensor:
```
# salt-key --list=unaccepted --no-color
Unaccepted Keys:
so-sensor-1_sensor
```

**Refinement worth recording:** the key was in **`Denied`**, not merely
stale-accepted. `Denied` is the state Salt uses when a minion presents a
key that conflicts with one already on file for that id — the exact
condition behind "The Salt Master has rejected this minion's public key".
A plain `salt-key -a` would NOT have fixed this; the key had to be
deleted first. Our fix uses `-d`, which is correct.

The role-level fix is still PROPOSED — it has not yet run in a deploy,
because on the current node `so_setup_can_skip` is now true (marker +
/etc/salt/minion + unit all present), so both so-setup and the gated
stale-key deletion are skipped. The role fix is what prevents recurrence
on the next fresh build; the manual commands above are what cleared this
particular node.

## 2026-07-28 (later 7) · gap · `BNICS` is NOT "the interface to monitor"; off-cloud installs hardcode `INTERFACE=bond0`

**Symptom.** Answer file sets `BNICS=tun0`, but so-setup logs
`Interface set to bond0` and creates a `bond0` (`NO-CARRIER`, state
`DOWN`, mtu 9000). Suricata and Zeek are pointed at that dead bond, which
is why the sensor captures nothing.

**Root cause (read from our pinned SO source, 2026-07-28).** `BNICS` means
"the NICs to enslave into bond0", not "the monitor interface". Three
places conspire:

1. `so-functions generate_interface_vars()`:
   ```bash
   if [[ $is_cloud ]]; then INTERFACE=${BNICS[0]}; else INTERFACE='bond0'; fi
   ```
   Off-cloud, `INTERFACE` is hardcoded — `BNICS` is never consulted.
2. `so-functions configure_network_sensor()` builds `bond0` with
   `nmcli ... type bond mode 0` off-cloud, vs `type ethernet` on cloud.
3. `so-common add_interface_bond0()` wraps **all** bond-slave creation in
   `if ! [[ $is_cloud ]]`, leaving only `ethtool -K` offload-disable and
   `ip link set ... promisc on` unconditional.

**Why the bond path can never work for us.** A GRE (L3) tunnel is not an
ethernet device and cannot be enslaved into a bond. Our whole capture
design is GRE-mirror → `tun0`, so bonding is structurally incompatible,
not merely misconfigured.

**Fix (applied).** `detect_cloud()` keys off a bare file test —
`[ -f /etc/SOCLOUD ]` (plus AWS/GCP/Azure signatures). Creating that file
on the sensor flips all three behaviors at once and nothing else in the
setup scripts: `INTERFACE` becomes `tun0`, the NM connection is created
as `type ethernet` instead of a bond, and the slave logic is skipped so
`tun0` merely gets promisc set — which is exactly what a mirror target
needs.

Implemented as a `file: state=touch` task in `so_sensor`, gated on a new
`so_sensor_force_cloud_mode` default (true) so it can be reverted to
stock behavior with one variable. **No SO script is patched**, which
CLAUDE.md §8 prefers over editing SO's own files. Sensor-only —
manager/search have no monitor interface and keep stock behavior.

**Side effect (good).** The role's existing "override sensor.interface
from bond0 to tun0" pillar step becomes redundant, because `INTERFACE` is
now `tun0` when the per-minion pillar is first generated. Left in place as
a harmless idempotent backstop.

**Risks to watch on the next deploy.**
  - `configure_network_sensor()` applies `ethernet.mtu 9000` to the
    `INTERFACE` connection. `tun0` is a GRE tunnel at mtu 1476, so NM may
    reject or warn on the MTU. Watch `/root/errors.log`.
  - ~~`is_cloud` may have meanings beyond the setup scripts.~~ **CHECKED
    2026-07-28 — blast radius confirmed narrow.** On so-sensor-1:
    `grep -rn SOCLOUD /root/manager_setup/securityonion/salt/` → **no
    hits**; nothing but `detect_cloud()` reads the file. `grep -rn
    is_cloud .../salt/` → only `common/tools/sbin/so-common:67,89`, which
    is the deployed copy of the same `add_interface_bond0()` we already
    analyzed, plus an unrelated `app_is_cloud` ECS field in a Sophos
    Elasticsearch template. No salt state, pillar, or runtime config
    consumes `is_cloud`.
  - ~~**Remaining edge:** `is_cloud` is exported only during so-setup, so
    a post-install caller of `add_interface_bond0()` would take the
    non-cloud branch and retry the `tun0`-into-`bond0` enslave.~~
    **RESOLVED 2026-07-28 — not reachable.** There are exactly two
    references to `add_interface_bond0` in the salt tree: its definition
    in `common/tools/sbin/so-common:36`, and one call from
    `common/tools/sbin/so-monitor-add:23`. And `so-monitor-add` is itself
    referenced nowhere but its own usage string (`so-monitor-add:7`) — no
    salt state, cron, or systemd unit invokes it. It is an operator
    convenience for adding a monitor NIC by hand, which we never call.
    So `/etc/SOCLOUD` holds permanently and no highstate can undo it.

    Worth having checked: had a state called it, the fix would have
    survived install but been torn out by the first 15-minute highstate —
    and that would have retroactively explained the original tun0 report
    ("earlier in the same range tun0 was decapping correctly... something
    in the running state broke decap since"). That explanation is now
    ruled out, so the tun0 decap bug still needs its own root cause.

**Status.** VERIFIED — deploy run 2026-07-28 ~22:54. `/root/so-setup.log`
line 105 reads:
```
2026-07-28T22:54:16Z | INFO | Interface set to tun0
```
replacing the previous `Interface set to bond0`. `grep -c bond0` over the
whole log drops to 1 (an incidental mention; no bond is built).

**Bonus — this also fixed (later 6)'s NetworkManager error.** `/root/errors.log`
previously carried both `StreamClosedException` AND `Connection activation
failed ... device eth0 not available because profile is not compatible
with device`. After this change the NM error is **gone entirely**; only
`StreamClosedException` remains. That makes sense: no bond means no NM
bond/slave profile to activate, so the failing `nmcli con up` never runs.
The `eth0` in that message was a red herring — it was NM reporting the
bond-slave profile mismatch, not something wrong with the mgmt NIC.

## 2026-07-28 (later 6) · bug · so-setup logs "Errors detected during setup" and exits 0 anyway; NetworkManager profile mismatch on eth0 is the real failure

**Symptom.** With the (later 4) guard in place, so-setup finally ran on
so-sensor-1 — and the guard caught it lying. `/root/so-setup.log` ends:
```
2026-07-28T20:06:08Z | INFO | Verifying setup
WARNING: Errors detected during setup.
--------- ERRORS ---------
[ERROR   ] Encountered StreamClosedException
Error: Connection activation failed: No suitable device found for this
connection (device eth0 not available because profile is not compatible
with device (mismatching interface name)).
--------------------------
```
Exit code: **0**.

**Detection.** Deploy run 2026-07-28 ~20:04-20:06. so-setup ran ~2 min.

**SO writes its own failure signals — use those, not rc.** `ls -la /root/`
after the run shows:
  - `/root/failure` (0 bytes) — SO's own failure marker
  - `/root/errors.log` (231 bytes) — the error text
  - `/root/sosetup.log` (49K) — SO's own log, MORE detail than the stdout
    we capture; prior runs rotated to `sosetup.log.<ISO timestamp>`
  - `/root/accept_changes` (0 bytes)

**Fix (applied).** In both `so_search` and `so_sensor`, check
`/root/failure` immediately after so-setup and fail if present, slurping
`/root/errors.log` into the failure message so the reason appears in
deploy output instead of requiring a manual host visit. The
`/etc/salt/minion_id` probe from (later 4) is kept as a second net.

This matters more than it looks: Salt **did** install successfully this
run (`dpkg -s salt-minion` → 3006.19, unit enabled), so the minion_id
probe alone came close to passing a failed setup. `/root/failure` is the
signal SO itself trusts.

**Root cause of the underlying failure — NOT yet fixed.** NetworkManager
cannot activate a profile for `eth0`: *"profile is not compatible with
device (mismatching interface name)"*. Notes for next session:
  - The sensor's `eth0` is the **mgmt** NIC (10.255.240.102/20); `eth1` is
    prod (172.16.5.20/**32** — the SimSpace /32 quirk, see 2026-07-24).
  - Our answer file sets `MNIC=eth1`, yet the failure names `eth0`.
  - SO expects NetworkManager; SimSpace images are netplan-managed. This
    is likely the same class as the 2026-07-24 /32 entry.

**Two more findings from the same log, logged so they aren't re-derived:**
  1. **`BNICS=tun0` is IGNORED.** so-setup logged `Interface set to
     bond0` and created a `bond0` (`NO-CARRIER ... state DOWN`, mtu 9000).
     Our monitor-interface intent is not reaching so-setup at all. This
     is separate from, and upstream of, the tun0 decap bug — and it may
     partly explain it, since the existing per-minion pillar override
     was written assuming so-setup had honored BNICS.
  2. **`Could not reach so-manager`** after a 60s timeout at 20:04:22,
     treated as non-fatal and setup continued. Worth understanding — our
     own `so_base` "Confirm we can reach the manager on the prod NIC"
     task passed on the same host, so SO's check differs from ours
     (likely a port probe rather than ICMP).

**Status.** PROPOSED (guard). The guard fix is applied and committed; the
underlying NetworkManager failure is OPEN and is now the blocker.

## 2026-07-28 (later 5) · enhancement · Ad-hoc `ansible` on the controller needs `sudo`; only `deploy.sh` documents it implicitly

**Symptom.** Any ad-hoc `ansible <host> -m shell` run as `simspace` dies:
```
ERROR! an error occurred while trying to read the file
'/etc/ansible/group_vars/all/vault.yml': [Errno 13] Permission denied
```

**Detection.** 2026-07-28 while gathering grid-join diagnostics. Cost a
full round trip, which is expensive when commands are hand-submitted
through a web console.

**Root cause.** The tarball extracts over `/etc/ansible/` as root, so
`group_vars/all/vault.yml` ends up root-owned. `deploy.sh` invokes
`ansible-playbook` unprefixed, so it only works because the operator runs
`sudo ./deploy.sh`. Nothing states that, so ad-hoc commands get written
without it. `vault_password_file` is an absolute path
(`/home/simspace/.vault_pass`), so `sudo` resolves it fine — the fix is
just to remember the prefix.

**Fix.** Prefix ad-hoc commands with `sudo`. Longer-term options: relax
ownership on extract in `pull-tarball.sh`, or have `deploy.sh` re-exec
itself under sudo so the requirement is explicit rather than folklore.

**Status.** OPEN (documented, not yet automated). Worth a CLAUDE.md §9
line so it stops recurring.

## 2026-07-28 (later 4) · bug · so-setup exits 0 on the sensor WITHOUT installing Salt; the setup-completed marker then makes it permanent

**Symptom.** so-sensor-1 grid-join fails at the salt-key wait loop with a
genuinely empty pending list. Manager's full key inventory:
```
Accepted Keys:
so-manager_manager
so-search_searchnode
Denied Keys:
Unaccepted Keys:
Rejected Keys:
```
No sensor key in ANY state.

**Detection.** Controller ad-hoc sweep 2026-07-28 ~19:30. On so-sensor-1:
  - `systemctl is-active salt-minion` → `inactive`
  - `systemctl is-enabled salt-minion` → *"No such file or directory"* —
    **the service unit does not exist**; Salt was never installed
  - `/etc/salt/minion_id` and `/etc/salt/minion` both absent (grep rc=2)
  - TCP 4505 + 4506 to the manager (172.16.5.10) → **both OPEN**, so the
    so-firewall work was correct all along and is exonerated

**Why this got missed for three attempts.** The role's marker logic makes
a false success permanent:
  1. `roles/so_sensor/tasks/main.yml` runs so-setup async and gates the
     shell task on `creates: /opt/so/state/setup-completed`.
  2. The marker is touched purely on `so_setup_result.rc == 0`.
  3. If so-setup exits 0 without doing the work, the marker is written,
     and every subsequent attempt **skips so-setup entirely** — the node
     can never self-heal, no matter how many times we redeploy.
This is the same class as the two idempotency bugs already fixed today,
but inverted: those re-ran work that was done; this one skips work that
was never done. An rc=0 exit code is too weak a completion proof.

**Note.** so-search uses the identical 20-min `install_timeout` and
succeeded, so a timeout is NOT the differentiator. The sensor-specific
variables are `BNICS={{ so_monitor_interface }}` (tun0) and the GRE
tunnel — tun0 must exist before so-setup validates BNICS.

**ROOT CAUSE CONFIRMED 2026-07-28.** so-setup never ran on the sensor —
not once. Evidence:
  - `/root/so-setup.log` **does not exist**. The shell task redirects
    `> /root/so-setup.log 2>&1`, and a redirect creates its target the
    instant the shell starts — even if `cd` fails or `./so-setup` is
    missing. No log file therefore proves the command never executed.
  - `/opt/so/` contains **only** `state/`. No packages, no `/etc/salt`.
  - `/opt/so/state/yeselastic.txt` is **ours**, not SO's — it reads
    `so-ansible: pre-accepted at ...`, written by `so_base` (see its
    "Pre-accept Elastic License 2.0 marker" task). It is not evidence
    that so-setup ran, which is how it misled the first analysis.
  - `tun0` exists and is UP with `10.100.0.2/30`, so the `BNICS=tun0`
    theory is dead too.

**The actual mechanism — a self-blessing marker.** `creates:` short-circuited
the shell task, meaning `/opt/so/state/setup-completed` already existed
before so-setup was ever attempted. That is self-perpetuating:
  1. When `creates:` is satisfied, Ansible's command module returns
     **`rc: 0`** together with `skipped: true`.
  2. The `Fail if so-setup exited non-zero` guard tests only
     `so_setup_result.rc`, so it **cannot distinguish "so-setup succeeded"
     from "so-setup was skipped"** — it passes in both cases.
  3. The role then re-touches the marker (which is why its mtime was
     19:08 with no log behind it).
So once the marker exists for ANY reason, it validates itself on every
subsequent run, and the node becomes permanently unrepairable — the one
task that would fix it is the one being skipped. Three full redeploy
attempts could never have helped.

**Fix (applied 2026-07-28).** Replace exit-code gating with positive
proof, in both `so_search` and `so_sensor`:
  - Drop `creates:` entirely. Probe instead: `/etc/salt/minion_id` exists
    AND `salt-minion.service` is a known unit AND the marker exists. Only
    all three together allow the skip. The marker alone is the bug above;
    Salt alone would wrongly skip a so-setup that installed Salt and then
    died mid-way.
  - Gate the so-setup shell task, its `async_status` poll, the rc check
    and the marker touch on `when: not so_setup_can_skip`, so a skip no
    longer flows through the rc guard at all.
  - Add a **post-condition**: after so-setup returns, re-probe for
    `/etc/salt/minion_id` and fail loudly if it's absent. Exit code 0 is
    explicitly not trusted as proof of installation.
  - Add a debug task printing the skip decision and all three inputs, so
    the reason is visible in deploy output instead of inferred.

**Self-healing.** No manual cleanup is needed on so-sensor-1. Salt is
absent there, so `so_setup_can_skip` is false regardless of the stale
marker, and so-setup will run on the next deploy.

**Status.** VERIFIED — deploy run 2026-07-28 ~20:04. The skip decision
printed `so-setup WILL RUN — marker=True, minion_id=False, unit=True`,
so-setup actually executed for the first time, and `/root/so-setup.log`
(29K) now exists. On the following attempt the decision printed
`marker=False`, confirming the failed run correctly refused to bless
itself — the self-perpetuating loop is broken. Self-heal worked with no
manual cleanup, as designed.

Two follow-ups from this verification:
  - The `unit=True` term was a **false positive at the time it was
    written** and is now genuinely true: `systemctl list-unit-files
    salt-minion.service` reports `enabled`, because so-setup did install
    salt-minion 3006.19 on this run. The earlier `is-enabled` → "No such
    file or directory" was from before any successful salt install. The
    probe is sound; requiring all three conditions is what caught the
    failure.
  - The original "what created `setup-completed` on a node where so-setup
    never ran?" question is **still unanswered**. It no longer blocks
    anything (the marker can no longer bless itself), but watch for it
    recurring on a genuinely fresh node.

The exit-code problem this entry describes turned out to be real and
distinct — see (later 6) above.

## 2026-07-28 (later 3) · bug · Grid-join `salt-key` hardcoded to `/usr/sbin/salt-key`, which does not exist

**Symptom.** After the (later 2) retry fix let the firewall state apply
succeed, the very next grid-join task burned its full 30 × 10s retry
budget and died with:
```
"cmd": ["sudo", "/usr/sbin/salt-key", "--list=unaccepted", "--no-color"],
"stderr": "sudo: /usr/sbin/salt-key: command not found"
```

**Detection.** Deploy run 2026-07-28 ~17:36, attempt 3 of 3, so-search.
The contradiction is visible in the same file: the task two above it
invokes `sudo salt-call state.apply firewall` **bare** and works fine.

**Root cause.** Two different families of binary live in two different
places on an SO node, and we conflated them:
  - **SO's own helper scripts** → `/usr/sbin/` — `so-firewall`,
    `so-minion`, `so-status`. Hardcoding `/usr/sbin/` for these is correct
    and those tasks have always worked.
  - **Salt's binaries** → `/usr/bin/` (Salt onedir package, symlinked out
    of `/opt/saltstack/salt/`). `salt-call`, `salt-key`, `salt-run`.
Only `salt-key` got the wrong prefix.

**Fix.**
  A. Invoke `salt-key` bare, matching the already-working `salt-call`
     invocation. sudo's `secure_path` covers `/usr/bin`.
  B. Add a fail-fast preflight task (`sudo salt-key --version`,
     `changed_when: false`) immediately before the wait loop. Without it
     a hard "command not found" is indistinguishable from "key hasn't
     appeared yet" and gets retried for a full 5 minutes before the real
     error surfaces — expensive when deploys are driven by hand.

Applied to both `roles/so_search/tasks/main.yml` and
`roles/so_sensor/tasks/main.yml`.

**Workaround.** None — fixed directly.

**Status.** VERIFIED — deploy run 2026-07-28 ~19:22. Both halves confirmed
on the sensor path (the one that had no evidence when this was written):
  - Preflight task `Grid join — preflight, confirm salt-key is invokable
    on manager` reported `ok`.
  - The wait loop's command ran with `rc: 0` and returned real output
    (`"stdout": "Unaccepted Keys:"`) instead of `command not found`.
so-search also cleared grid-join entirely this run (`ok=35 changed=0
failed=0` — role short-circuited on its installed marker, meaning it had
completed successfully in an earlier attempt).

The task still failed, but for an unrelated reason — the list was
genuinely empty. See the (later 4) entry above. This fix is done.

## 2026-07-28 (later 2) · bug · Grid-join `salt-call state.apply firewall` races with the 15-min highstate scheduler

**Symptom.** After 830c2cd fix, grid-join's `salt-call state.apply
firewall` step fails with:
```
Data failed to compile:
  The function "state.highstate" is running as PID X and was
  started at 2026, Jul 28 16:50:40 with jid ...
```
Salt's `maxrunning: 1` for the highstate schedule blocks concurrent
state.apply. Highstates fire every 15 min and take ~5-8 min each →
~30-50% chance our state.apply hits an in-flight highstate on any
given run.

**Fix.** Add `until: fw_apply.rc == 0; retries: 20; delay: 30` to the
delegated task in both so_search and so_sensor. 10-min ceiling covers
the worst-case wait for the highstate to release the lock.

**Workaround.** None — attempted the fix directly.

**Status.** VERIFIED — deploy run 2026-07-28 ~17:30, so-search. Task
`Grid join — on manager, apply firewall state` logged 13 consecutive
`FAILED - RETRYING` lines and then reported `changed`. That is exactly
the designed behavior: it waited out an in-flight highstate (~6.5 min at
30s/retry) and succeeded on the next free scheduler slot. Well inside the
20-retry ceiling.

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

**Status.** VERIFIED (both symptoms) — deploy run 2026-07-28 ~17:30, so-search.
  - **A (setup marker):** attempt 3 reached the grid-join tasks without
    re-running so-setup. Previously each attempt burned 30-45 min there.
    The `setup-completed` marker short-circuited as designed.
  - **B (so-firewall idempotency):** task `Grid join — on manager, add
    this node's IP to searchnode firewall hostgroup` reported `ok` rather
    than failing. That is the "already exists" path being correctly
    swallowed by the new `failed_when` — on the prior run this same task
    was a hard rc=3 failure.

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

**Fix.** UNKNOWN — but the search space narrowed sharply 2026-07-29.

**Diagnostic round 2026-07-29 ~00:09 — two earlier "facts" are DEAD.**

  1. ~~`IpInUnknownProtos` climbing (588 accumulated)~~ — **it is 0**,
     both before and after a 25s capture window. `ip_gre`, `ip_tunnel`
     and `gre` are all loaded. The kernel HAS a handler registered for
     proto 47. The original reading came from a different machine state
     and misdirected the entire first investigation.
  2. ~~NetworkManager/the (later 7) SOCLOUD change disturbed the tunnel~~
     — `nmcli dev status` reports `tun0  iptunnel  unmanaged`, and
     `ip -d link show tun0` still reports `gre remote 172.16.5.1 local
     172.16.5.20`, mtu 1476, UP, PROMISC. The tunnel is intact and NM
     never took ownership.

**What IS true:**
  - `tcpdump -i eth1 proto gre` captures cleanly addressed packets:
    `IP 172.16.5.1 > 172.16.5.20: GREv0, length 64: IP 172.16.8.5 >
    172.16.6.11: ICMP echo request`. Outer src/dst match tun0's
    remote/local exactly, and the inner payload decodes fine.
  - Each mirrored packet arrives **twice** (router mirrors on both
    ingress and egress interfaces) — cosmetic, not the bug.
  - Some frames are `gre-proto-0x806` (ARP), so the router is mirroring
    L2 frames, not just IPv4.
  - `tun0` RX is **frozen at 60 packets / 5910 bytes**, identical before
    and after the capture. Nothing arrives.
  - A nonzero historical RX of 60 proves decap **did** work on this
    device at some point — consistent with the original "worked earlier,
    broke later" report.
  - `iptables` INPUT policy is ACCEPT with no proto-47 rule. FORWARD is
    DROP, but that is post-decap and cannot explain a frozen RX counter.
  - `gre0` fallback exists but is DOWN.

**Conclusion.** Handler registered + packets correctly addressed + no
unknown-proto + RX not incrementing ⇒ the drop is inside `gre_rcv()` /
`ip_tunnel_lookup()`, which is a silent path with no dedicated counter.

**ROOT CAUSE (high confidence, 2026-07-29 ~00:19): SO's own host
firewall drops GRE in INPUT, before protocol demux.**

The checksum/key theory is dead — `tcpdump -nnvv` shows `GREv0, Flags
[none]`: no checksum, no key, no sequence. `gre0` RX is 0, `tc filter
show dev eth1 ingress` is empty, `rp_filter` is 2 (loose) and post-decap
anyway.

The answer is in the INPUT chain. The GRE packets match none of
so-firewall's rules (not `tcp dpt:22`, not the `172.17.1.0/24` docker
rules, not `icmp`) and fall through to the catch-all last line:
```
91  8290 LOGGING  all  --  *  *  0.0.0.0/0  0.0.0.0/0
```
SO's `LOGGING` chain terminates in DROP. **For a locally-destined packet
the INPUT filter runs BEFORE protocol demux**, so the GRE packets are
dropped before `ip_gre` ever sees them.

This explains every observation simultaneously:
  - `tun0` RX frozen — packets never reach the tunnel
  - `IpInUnknownProtos` = 0 — never reached protocol demux at all
  - `gre0` RX = 0 — same reason
  - "worked earlier, broke later" — GRE flowed until so-firewall's rules
    landed via highstate

**It also vindicates a clue dismissed in the original report:** *"iptables
-F flush briefly worked once with 12 packets captured — non-reproducible."*
That was not a fluke, it was the answer. The two anchor observations were
contradictory (a netfilter DROP and `IpInUnknownProtos` cannot both be
true) — the counter reading was the wrong one.

**CONFIRMED 2026-07-29 ~00:37 on the live range.** With a single
temporary `iptables -I INPUT 1 -p gre -j ACCEPT`:
  - `tun0` RX went **60 → 262 packets** (5910 → 20448 bytes) in a 15s window
  - `tcpdump -i tun0` captured real mirrored traffic:
    `IP 172.16.8.5 > 172.16.6.11: ICMP echo request`, and both directions
    of pings the sensor itself generated out through the mirrored subnets
  - The `LOGGING` chain is confirmed log-and-drop:
    ```
    Chain LOGGING (2 references)
      37  3032 LOG   all -- ... limit: avg 2/min burst 5 ... "IPTables-dropped: "
    7543  630K DROP  all -- 0.0.0.0/0  0.0.0.0/0
    ```
    7543 packets / 630K already dropped on that chain.

The GRE mirror, the VyOS tc rules, the tunnel config and the kernel decap
path were **all correct the entire time**. The only defect was SO's own
host firewall dropping proto 47 in INPUT before protocol demux.

Retired as never-relevant: the `promiscuity: 15` observation, the
gretap-instead-of-gre idea, the `dropwatch` plan, the netns-leak theory,
and every rp_filter/accept_local/ip_forward sysctl tried in the original
session.

**Fix direction — SO's firewall model CANNOT express GRE (confirmed
2026-07-29).** Read `/opt/so/saltstack/default/salt/firewall/iptables.jinja`
on the manager. The single rule-generating loop is:
```jinja
{%- for proto, ports in FIREWALL_MERGED['portgroups'][groupname].items() %}
{%-   for port in ports %}
-A {{chn}} -s {{ip}} -p {{proto}} -m {{proto}} --dport {{port}} -j ACCEPT
```
**Every generatable rule carries a mandatory `--dport`.** GRE is portless,
so no portgroup value yields a valid rule, and an empty `ports` list emits
nothing at all. Attempting `-p gre --dport N` would produce invalid
iptables syntax and fail the whole `iptables-restore`, which would leave
the host firewall in a broken state — do NOT try it.

Corroborating: SO hardcodes `-A INPUT -p icmp -j ACCEPT` for the one
portless protocol it supports, proving there is no general mechanism.
`/opt/so/saltstack/local/pillar/firewall/adv_firewall.sls` exists but is
**empty**, and feeds the same `FIREWALL_MERGED` structure, so it cannot
express GRE either.

This is a real upstream gap, not a misconfiguration: SO supports
GRE-mirror-fed sensors in principle, but its host firewall has no way to
permit the tunnel that feeds them. **Good PR / SO-Slack candidate.**

**FIX APPLIED 2026-07-29 — derived override, not a vendored fork.**

`local/salt/firewall/iptables.jinja` overrides the stock template via
file_roots precedence. Rather than committing a 5KB fork of SO's template
into this repo (which would silently go stale on every SO upgrade), the
role **derives** the override at deploy time:

  1. `slurp` `/opt/so/saltstack/default/salt/firewall/iptables.jinja`
     from the manager — whatever version SO currently ships.
  2. Fail loudly if the anchor `-A INPUT -j LOGGING` is absent, i.e. SO
     changed the template's shape and a human needs to re-derive it.
  3. Write the stock content back to `local/salt/...` with one guarded
     block injected immediately before that anchor:
     ```jinja
     {%- if GLOBALS.role == 'so-sensor' %}
     -A INPUT -s <router ip> -p gre -j ACCEPT
     {%- endif %}
     ```
  4. `salt-call state.apply firewall` on the sensor (with the same
     20x30s highstate-collision retry as grid-join).
  5. Verify with `iptables -S INPUT | grep -E '\-p (gre|47) '` and fail
     if absent.

Correct by construction on any SO version whose template still contains
the anchor, and it degrades to a loud failure rather than a silent stale
fork when that stops being true.

Design notes:
  - The rule is inside the same atomic `iptables-restore` as everything
    else, so there is never a window where GRE is dropped.
  - Guarded on `GLOBALS.role` because the same template renders on
    manager and search nodes, which have no tunnel and should not accept
    GRE. `GLOBALS.role` carries the full `so-<role>` form — matching
    SO's own `GLOBALS.role in ['so-hypervisor', 'so-managerhype']` usage
    in that file.
  - Source-restricted to the router's mirror endpoint, not `0.0.0.0/0`.
  - The injected block is `{% raw %}`-fenced in defaults so Ansible does
    not evaluate SALT's Jinja at template time; only the gateway IP is
    substituted Ansible-side.
  - `iptables_restore` is a bare `cmd.run` with **no `onchanges`**, so it
    re-runs every highstate (~15 min). That is why a manual `iptables -I`
    can never survive and the fix had to live in salt.

**Status.** VERIFIED — deploy run 2026-07-29. `iptables -S INPUT` carries
the proto-47 ACCEPT, the rendered ruleset passes `iptables-restore --test`,
and `tun0` captures traffic. The derived-override approach works: no
vendored fork, and it re-derives from whatever SO currently ships.

Structural notes for the fix:
  - The sensor has **no** `/opt/so/saltstack/` at all — rules are rendered
    on the manager and pushed. Any overlay belongs in the manager's
    `local/` tree.
  - Salt file_roots precedence is `/opt/so/saltstack/local/salt` **before**
    `/opt/so/saltstack/default/salt`, so a file placed at
    `local/salt/firewall/iptables.jinja` overrides the default one.
  - Overriding the template puts our rule inside the same atomic
    `iptables-restore`, so there is never a window where GRE is dropped —
    unlike a separate state that runs after the firewall state.
  - Cost of that approach: we fork a ~5KB template and must re-diff it on
    every SO upgrade (same discipline already used for the so-setup
    snapshot).

~~**Leading hypothesis for next round: GRE checksum flag.**~~ DEAD — If VyOS sets
the GRE checksum-present flag, the kernel validates it — and `tc mirred`
mirroring bypasses checksum offload, so the mirrored copies can carry a
stale/wrong checksum and be dropped silently in exactly this path.
`tcpdump -nnvv` on eth1 shows the GRE header flags and will confirm or
kill this immediately. Secondary candidates: an unexpected GRE key
(lookup keys on it), or a `tc`/XDP ingress filter on eth1 consuming the
packets before the IP stack.

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

**Status.** OPEN. A one-shot diagnostic script covering all six avenues
in a single console paste was drafted 2026-07-28 (10 labeled sections:
live tunnel params, address inventory, modules, netns, netfilter, nstat
deltas across a 25s dual tcpdump on eth1 + tun0, suricata binding,
netplan-on-disk). Not yet run, and not yet committed to this repo —
promote it to `diag_tun0.sh` alongside `verify_so.sh` if it proves out.

**Note on the evidence (2026-07-28).** Two recorded observations are
mutually inconsistent and one of them must be wrong:
  - `IpInUnknownProtos` climbing means the kernel found **no handler**
    for IP proto 47 — i.e. no tunnel matched the packet.
  - `iptables -F` briefly restoring capture implies a **netfilter drop**.
For a locally-destined packet, netfilter INPUT runs *before* protocol
demux, so a DROP there prevents the packet from ever reaching the GRE
handler — and therefore cannot also increment `IpInUnknownProtos`.
Resolving which observation is sound is the first job of the diagnostic;
it captures nstat deltas and INPUT rule counters across the same window
so the two can be compared directly rather than recalled from separate
sessions.

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

**Status.** VERIFIED (main path) — the sensor came up with 67K ETOPEN
rules loaded into suricata, confirmed while investigating the tun0 entry
above. The mirror-served ruleset + `soc.json` patch work end to end.
The **Deferred** sigma / AI-summary git-clone gap remains OPEN and is
tracked as part of this entry rather than separately.

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
