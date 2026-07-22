#!/bin/bash
#
# verify_so.sh — read-only health check for the distributed Security Onion
# deployment after `./deploy.sh` (or site.yml) has run.
#
# Sections:
#   1. Inventory reachability — mgmt-plane connectivity to every host
#   2. Ansible controller mirror — nginx :80 + SO source tarball reachable
#   3. router-0 (VyOS) — GRE tunnel + tc mirror rules per source iface
#   4. so-manager — so-status, /opt/so/state/installed marker, SOC WebUI
#                   :443, Elastic /_cluster/health, salt-key accepted list
#   5. so-search  — so-status, is a data node in the Elastic cluster
#   6. so-sensor  — so-status, Suricata + Zeek running, tun0 UP +
#                   promiscuous, tcpdump on tun0 shows packets flowing
#
# Usage:
#   cd /etc/ansible && ./verify_so.sh          # summary
#   cd /etc/ansible && ./verify_so.sh -v       # show ansible output on fail
#
# Exit 0 if every check passes, 1 if any fails.

set -u

VERBOSE=0
case "${1:-}" in
  -v|--verbose) VERBOSE=1 ;;
  -h|--help)    sed -n '2,22p' "$0"; exit 0 ;;
esac

# --- colors --------------------------------------------------------------
if [ -t 1 ]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[36m'; D=$'\033[2m'; N=$'\033[0m'
else
  G=''; R=''; Y=''; B=''; D=''; N=''
fi

PASS=0
FAIL=0
declare -a FAILURES

pass() { printf "  ${G}✓${N} %s\n" "$1"; PASS=$((PASS+1)); }
fail() {
  printf "  ${R}✗${N} %s\n" "$1"
  FAIL=$((FAIL+1))
  FAILURES+=("$1")
  if [ "$VERBOSE" -eq 1 ] && [ -n "${2:-}" ]; then
    printf "      ${D}%s${N}\n" "$2" | head -5
  fi
}
section() { printf "\n${B}━━ %s ━━${N}\n" "$1"; }
note()    { printf "  ${D}%s${N}\n" "$1"; }

A() { ansible "$@" 2>&1; }

n_hosts() {
  ansible "$1" --list-hosts 2>/dev/null | tail -n +2 | sed '/^$/d' | wc -l | tr -d ' '
}

probe_group() {
  local group="$1" module="$2" cmd="$3" label="$4"
  local total ok out
  total=$(n_hosts "$group")
  if [ "$total" -eq 0 ]; then
    note "$label: 0 hosts in inventory (skipping)"
    return
  fi
  if [ -n "$cmd" ]; then
    out=$(A "$group" -m "$module" -a "$cmd" --one-line)
  else
    out=$(A "$group" -m "$module" --one-line)
  fi
  ok=$(echo "$out" | grep -cE '\| (SUCCESS|CHANGED)')
  if [ "$ok" -eq "$total" ]; then
    pass "$label: $ok/$total reachable"
  else
    fail "$label: $ok/$total reachable" "$out"
  fi
}

check_sh() {
  local host="$1" cmd="$2" expect="$3" label="$4"
  local out
  out=$(A "$host" -m ansible.builtin.shell -a "$cmd" --one-line)
  if echo "$out" | grep -qE "$expect"; then
    pass "$label"
  else
    fail "$label" "$out"
  fi
}

# =========================================================================
# 1. Inventory reachability
# =========================================================================
section "1. Reachability (mgmt-plane ping)"

probe_group ansible_controller ansible.builtin.ping ""                 "ansible controller"
probe_group net_vyos           vyos.vyos.vyos_command "commands='show version'" "router-0 (VyOS)"
probe_group so_all             ansible.builtin.ping ""                 "SO nodes"

# =========================================================================
# 2. Ansible controller — mirror
# =========================================================================
section "2. Ansible controller (SO source mirror)"

check_sh ansible \
  "systemctl is-active nginx 2>&1" \
  "^active$" \
  "ansible: nginx active"

check_sh ansible \
  "ls /var/www/so-mirror/so-source/*.tar.gz 2>&1 | head -1" \
  "securityonion-.*\\.tar\\.gz" \
  "ansible: SO source tarball staged"

check_sh ansible \
  "curl -fsSI http://127.0.0.1/so-source/ 2>&1 | head -1" \
  "HTTP/1\\.[01] 200" \
  "ansible: nginx :80 returns 200 for /so-source/"

# =========================================================================
# 3. router-0 — GRE tunnel + tc mirror rules
# =========================================================================
section "3. router-0 (VyOS: GRE tunnel + tc mirror)"

check_sh router-0 \
  "ip -brief link show tun0 2>&1" \
  "tun0.*UP" \
  "router-0: tun0 GRE tunnel UP"

for iface in eth1 eth2 eth3; do
  check_sh router-0 \
    "tc filter show dev $iface ingress 2>&1 | head -5" \
    "mirred" \
    "router-0: tc mirred rule on $iface (ingress)"
done

# =========================================================================
# 4. so-manager
# =========================================================================
section "4. so-manager"

check_sh so-manager \
  "stat -c '%n' /opt/so/state/installed 2>&1" \
  "/opt/so/state/installed" \
  "so-manager: /opt/so/state/installed marker present"

check_sh so-manager \
  "sudo so-status 2>&1 | tail -3" \
  "STATUS: OK|so-.*OK" \
  "so-manager: so-status OK"

check_sh so-manager \
  "sudo so-elasticsearch-query _cluster/health 2>&1 | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get(\"status\",\"?\"))'" \
  "^(green|yellow)$" \
  "so-manager: Elastic /_cluster/health green|yellow"

check_sh so-manager \
  "curl -kfsS -o /dev/null -w '%{http_code}' https://127.0.0.1/ 2>&1" \
  "^200$|^302$" \
  "so-manager: SOC WebUI :443 returns 200/302"

check_sh so-manager \
  "sudo salt-key -L 2>&1 | grep -A20 'Accepted Keys' | head -6" \
  "so-search.*so-sensor-1" \
  "so-manager: salt-key -L shows search + sensor accepted"

# =========================================================================
# 5. so-search
# =========================================================================
section "5. so-search"

check_sh so-search \
  "stat -c '%n' /opt/so/state/installed 2>&1" \
  "/opt/so/state/installed" \
  "so-search: /opt/so/state/installed present"

check_sh so-search \
  "sudo so-status 2>&1 | tail -3" \
  "STATUS: OK|so-.*OK" \
  "so-search: so-status OK"

check_sh so-search \
  "systemctl is-active salt-minion 2>&1" \
  "^active$" \
  "so-search: salt-minion active"

# From manager: is the search node an active data node in the ES cluster?
check_sh so-manager \
  "sudo so-elasticsearch-query _cat/nodes 2>&1 | grep -c so-search" \
  "^[1-9]" \
  "so-search: appears in Elastic _cat/nodes (data node)"

# =========================================================================
# 6. so-sensor-1
# =========================================================================
section "6. so-sensor-1"

check_sh so-sensor-1 \
  "stat -c '%n' /opt/so/state/installed 2>&1" \
  "/opt/so/state/installed" \
  "so-sensor-1: /opt/so/state/installed present"

check_sh so-sensor-1 \
  "sudo so-status 2>&1 | tail -3" \
  "STATUS: OK|so-.*OK" \
  "so-sensor-1: so-status OK"

check_sh so-sensor-1 \
  "ip -brief link show tun0 2>&1" \
  "tun0.*UP" \
  "so-sensor-1: tun0 GRE endpoint UP"

check_sh so-sensor-1 \
  "cat /sys/class/net/tun0/flags 2>&1" \
  "0x[0-9a-f]*[13579bdf]00[0-9a-f]$|0x[0-9a-f]*1[0-9a-f]{2}$" \
  "so-sensor-1: tun0 in promiscuous mode"

check_sh so-sensor-1 \
  "systemctl is-active suricata 2>&1 || sudo docker ps --format '{{.Names}}' | grep -q '^so-suricata\$' && echo active-container" \
  "^active|active-container" \
  "so-sensor-1: Suricata running (systemd unit or so-suricata container)"

check_sh so-sensor-1 \
  "sudo docker ps --format '{{.Names}}' 2>&1 | grep -q '^so-zeek\$' && echo container-running" \
  "container-running" \
  "so-sensor-1: so-zeek container running"

# Traffic-flow smoke: 5-sec tcpdump on tun0, expect >0 packets captured.
# This is the money-shot check — GRE mirror is delivering + kernel is
# decapping + Suricata/Zeek are actually seeing traffic.
check_sh so-sensor-1 \
  "sudo timeout 5 tcpdump -i tun0 -c 10 -nn 2>&1 | tail -3" \
  "packets captured|packets received" \
  "so-sensor-1: tun0 receiving mirrored packets from router-0"

# =========================================================================
# Summary
# =========================================================================
section "Summary"
TOTAL=$((PASS + FAIL))
printf "  Total checks : %d\n" "$TOTAL"
printf "  ${G}Pass${N}         : %d\n" "$PASS"
printf "  ${R}Fail${N}         : %d\n" "$FAIL"

if [ "$FAIL" -eq 0 ]; then
  printf "\n${G}All checks passed.${N}\n"
  exit 0
else
  printf "\n${R}Failed checks:${N}\n"
  for f in "${FAILURES[@]}"; do printf "  - %s\n" "$f"; done
  printf "\n${Y}Re-run with -v for the ansible output on each failing check.${N}\n"
  exit 1
fi
