#!/usr/bin/env bash
#
# Build so_ab.tgz for deployment.
#
# Per the airfield-range role-sourcing policy (memory:
# project-airfield-role-sourcing), every role used by this project must
# already exist under so-ansible/roles/ — copied from PowerPlant or
# range-development-ansible at copy-time, not referenced at build-time.
#
# This script:
#   1. Discovers role names referenced by site.yml + imported playbooks
#      + walks their meta deps.
#   2. Validates each one is physically present under ./roles/.
#   3. Stages: roles/ host_vars/ group_vars/ hosts site.yml playbooks/
#              deploy.sh (+ requirements.yml + files/ if present).
#
# UPSTREAM_FIXES.md and PROJECT_LOG.md are intentionally excluded.
#
# Usage: ./build_tarball.sh
set -euo pipefail

SO_ANSIBLE="$(cd "$(dirname "$0")" && pwd)"
ARCHIVE="$SO_ANSIBLE/so_ab.tgz"
STAGE_PARENT="$(mktemp -d)"
STAGE="$STAGE_PARENT/so_ab_build"

trap 'rm -rf "$STAGE_PARENT"' EXIT

# --- Helpers ---------------------------------------------------------------

extract_playbook_roles() {
  # Matches both classic `roles:` block entries AND
  # `import_role: name: <foo>` / `include_role: name: <foo>` forms.
  awk '
    /^  roles:/ { inroles=1; next }
    inroles && /^  [a-z]/ { inroles=0 }
    inroles && /^    - / {
      sub(/^    - role:[[:space:]]+/, "")
      sub(/^    - /, "")
      sub(/[ \t#].*$/, "")
      if (length($0) > 0) print
    }
    # ansible.builtin.import_role / include_role:  name: <role>
    /^[[:space:]]*name:[[:space:]]/ && prev_line ~ /(import_role|include_role)/ {
      role=$0
      sub(/^[[:space:]]*name:[[:space:]]+/, "", role)
      sub(/[ \t#].*$/, "", role)
      if (length(role) > 0) print role
    }
    { prev_line = $0 }
  ' "$1"
}

extract_meta_deps() {
  [ -f "$1" ] || return 0
  awk '
    /^dependencies:/ { indeps=1; next }
    indeps && /^[a-z]/ { indeps=0 }
    indeps && /^[[:space:]]*-[[:space:]]+role:/ {
      sub(/^[[:space:]]*-[[:space:]]+role:[[:space:]]+/, "")
      sub(/[ \t#].*$/, "")
      print
    }
  ' "$1"
}

in_array() {
  local needle="$1"; shift
  for x in "$@"; do
    [ "$x" = "$needle" ] && return 0
  done
  return 1
}

# --- Discovery -------------------------------------------------------------

PLAYBOOKS=("$SO_ANSIBLE/site.yml")
# also add all imported phase playbooks so their roles get discovered
for pb in "$SO_ANSIBLE"/playbooks/*.yml; do
  [ -f "$pb" ] && PLAYBOOKS+=("$pb")
done

[ -d "$SO_ANSIBLE/roles" ] || { echo "ERROR: roles dir missing at $SO_ANSIBLE/roles" >&2; exit 1; }

seen=()
queue=()
for pb in "${PLAYBOOKS[@]}"; do
  while IFS= read -r r; do queue+=("$r"); done < <(extract_playbook_roles "$pb")
done

missing=()
while [ ${#queue[@]} -gt 0 ]; do
  r="${queue[0]}"
  queue=("${queue[@]:1}")
  in_array "$r" "${seen[@]:-}" && continue
  seen+=("$r")

  rolepath="$SO_ANSIBLE/roles/$r"
  if [ -d "$rolepath" ]; then
    while IFS= read -r dep; do
      [ -n "$dep" ] && queue+=("$dep")
    done < <(extract_meta_deps "$rolepath/meta/main.yml")
  else
    missing+=("$r")
  fi
done

# --- Stage -----------------------------------------------------------------

mkdir -p "$STAGE/roles" "$STAGE/playbooks"

echo "=== Roles bundled (from $SO_ANSIBLE/roles) ==="
for r in "${seen[@]}"; do
  if [ -d "$SO_ANSIBLE/roles/$r" ]; then
    cp -R "$SO_ANSIBLE/roles/$r" "$STAGE/roles/"
    echo "  ✓ $r"
  fi
done

if [ ${#missing[@]} -gt 0 ]; then
  echo ""
  echo "ERROR: roles referenced by site.yml or playbooks/*.yml but not present under so-ansible/roles/:"
  for r in "${missing[@]}"; do echo "  - $r"; done
  echo ""
  echo "Per the role-sourcing policy, copy each into so-ansible/roles/ before re-running."
  echo "Sources (precedence on copy):"
  echo "  1. ../PowerPlant/ss-pp-ab/roles/"
  echo "  2. ../PowerPlant/range-development-ansible/roles/"
  echo "  3. ../airfield-range/roles/"
  echo "  4. author new here (SO-specific)"
  exit 1
fi

cp -R "$SO_ANSIBLE/host_vars"  "$STAGE/"
cp -R "$SO_ANSIBLE/group_vars" "$STAGE/"
cp    "$SO_ANSIBLE/hosts"      "$STAGE/"
cp    "$SO_ANSIBLE/site.yml"   "$STAGE/"
cp -R "$SO_ANSIBLE/playbooks/"* "$STAGE/playbooks/"
cp    "$SO_ANSIBLE/deploy.sh"  "$STAGE/"
chmod +x "$STAGE/deploy.sh"
[ -f "$SO_ANSIBLE/requirements.yml" ] && cp "$SO_ANSIBLE/requirements.yml" "$STAGE/"
[ -f "$SO_ANSIBLE/verify_so.sh" ]     && { cp "$SO_ANSIBLE/verify_so.sh"  "$STAGE/"; chmod +x "$STAGE/verify_so.sh"; }
[ -f "$SO_ANSIBLE/vault-tools.sh" ]   && { cp "$SO_ANSIBLE/vault-tools.sh" "$STAGE/"; chmod +x "$STAGE/vault-tools.sh"; }
[ -f "$SO_ANSIBLE/pull-tarball.sh" ]  && { cp "$SO_ANSIBLE/pull-tarball.sh" "$STAGE/"; chmod +x "$STAGE/pull-tarball.sh"; }

if [ -d "$SO_ANSIBLE/files" ]; then
  cp -R "$SO_ANSIBLE/files" "$STAGE/"
  find "$STAGE/files" -name '.DS_Store' -delete 2>/dev/null || true
fi

# rules/ ships pre-downloaded detection ruleset tarballs (currently just
# the ETOPEN emerging.rules.tar.gz). so-soc's suricataengine can't reach
# rules.emergingthreats.net through the corp proxy from inside the
# container (no proxy env vars + docker embedded DNS 127.0.0.11 can't
# resolve external hosts), so we host the ruleset locally via so_apt_mirror
# and point soc.json at http://<mirror>/so-source/emerging.rules.tar.gz.
if [ -d "$SO_ANSIBLE/rules" ]; then
  cp -R "$SO_ANSIBLE/rules" "$STAGE/"
  find "$STAGE/rules" -name '.DS_Store' -delete 2>/dev/null || true
fi

# HARD GATE. so_defend_exclusions is static group_vars data, so every check
# the so_manager role makes at deploy time can be made here in a second.
#
# On 2026-09-19 a 485-character description -- against Kibana's 256 limit --
# was caught by the role assert 1h 31m into deploy.sh attempt 3, after six
# hours of wall clock, on a range that was otherwise fully built. The assert
# is in the right place to protect Kibana and the wrong place to protect the
# deploy. This does not replace it; it means you never get that far.
if [ -x "$SO_ANSIBLE/verify_defend_filters.py" ] && command -v python3 >/dev/null 2>&1; then
  echo ""
  echo "=== Verifying Elastic Defend filters ==="
  if ! python3 "$SO_ANSIBLE/verify_defend_filters.py" "$STAGE"; then
    echo ""
    echo "ERROR: refusing to build a tarball with Defend filters the deploy will reject."
    exit 1
  fi
fi

# HARD GATE. A task with two `when:` keys loses the first one -- YAML keeps the
# last value and discards the earlier one without complaint, so a condition you
# wrote is simply not running, and the file reads correctly because both lines
# are right there. roles/dcpromo shipped an AD-services gate whose service
# condition had been dead for months; the probe feeding it ran every deploy and
# was read by nothing.
#
# yaml.safe_load() accepts duplicates silently, so no checker built on it can
# see this. Ansible warns at RUN time, on stderr, one line deep in a
# 26,000-line log. That is not a gate. This is.
if [ -x "$SO_ANSIBLE/verify_dup_keys.py" ] && command -v python3 >/dev/null 2>&1; then
  echo ""
  echo "=== Verifying no duplicate YAML keys ==="
  if ! python3 "$SO_ANSIBLE/verify_dup_keys.py" "$STAGE"; then
    echo ""
    echo "ERROR: refusing to build a tarball with logic that silently does not run."
    exit 1
  fi
fi

# HARD GATE. A task keyword indented one level too deep becomes a module
# ARGUMENT instead: the keyword is never applied, so a `when` never gates, a
# `loop` never loops, a `register` never registers.
#
# ss-pp-stacked 2026-09-20 nearly shipped a `when` indented under
# ansible.builtin.fail, which would have fired that fail task on every host in
# the play -- a targeted guard turned into a range-wide outage. Valid YAML, no
# duplicate keys, balanced quotes, so nothing else could see it, and it reads
# correctly at a glance: both lines spelled right, only the column wrong.
if [ -x "$SO_ANSIBLE/verify_task_keywords.py" ] && command -v python3 >/dev/null 2>&1; then
  echo ""
  echo "=== Verifying task keywords are not module arguments ==="
  if ! python3 "$SO_ANSIBLE/verify_task_keywords.py" "$STAGE"; then
    echo ""
    echo "ERROR: refusing to build a tarball with keywords that will not apply."
    exit 1
  fi
fi

# HARD GATE. An apostrophe in a shell or PowerShell comment inside a free-form
# module argument makes the PLAY FAIL TO LOAD -- not one task, the whole run,
# before any host is touched. Ansible runs split_args() over those arguments
# and counts quotes; it does not know the script has comments.
if [ -x "$SO_ANSIBLE/verify_shell_args.py" ] && command -v python3 >/dev/null 2>&1; then
  echo ""
  echo "=== Verifying free-form shell arguments ==="
  if ! python3 "$SO_ANSIBLE/verify_shell_args.py" "$STAGE"; then
    echo ""
    echo "ERROR: refusing to build a tarball whose plays cannot load."
    exit 1
  fi
fi

if [ -x "$SO_ANSIBLE/verify_vars.py" ] && command -v python3 >/dev/null 2>&1; then
  echo ""
  echo "=== Verifying Jinja var references ==="
  python3 "$SO_ANSIBLE/verify_vars.py" "$STAGE" || true
fi

# --- Pack ------------------------------------------------------------------

cd "$STAGE"
TAR_PATHS=(roles host_vars group_vars hosts site.yml playbooks deploy.sh)
[ -f "requirements.yml" ] && TAR_PATHS+=(requirements.yml)
[ -f "verify_so.sh" ]     && TAR_PATHS+=(verify_so.sh)
[ -f "vault-tools.sh" ]   && TAR_PATHS+=(vault-tools.sh)
[ -f "pull-tarball.sh" ]  && TAR_PATHS+=(pull-tarball.sh)
[ -d "files" ]            && TAR_PATHS+=(files)
[ -d "rules" ]            && TAR_PATHS+=(rules)
# macOS junk, stripped from the whole stage before packing.
find "$STAGE" \( -name '.DS_Store' -o -name '._*' \) -delete 2>/dev/null || true

# COPYFILE_DISABLE=1 is load-bearing. Apple's tar emits an AppleDouble
# "._name" companion for every file carrying an extended attribute, and
# com.apple.provenance is set on anything downloaded. `--no-xattrs` does NOT
# suppress them -- measured 2026-08-07: 2 junk members with --no-xattrs, 0 with
# COPYFILE_DISABLE=1. ss-pp-ab shipped archives that were 50% AppleDouble
# (942 members, 471 junk) until this was found, and extraction is ADDITIVE so
# every one of those files persists in /etc/ansible.
#
# Apple's `tar -tzf` HIDES these members when listing, so macOS tar cannot be
# used to verify this. Check with python3 tarfile instead.
COPYFILE_DISABLE=1 tar --no-xattrs \
  --exclude='.DS_Store' --exclude='._*' \
  -czf "$ARCHIVE" "${TAR_PATHS[@]}"

echo ""
echo "=== Archive built ==="
ls -lh "$ARCHIVE"
echo "Roles bundled: ${#seen[@]} total"
