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

if [ -d "$SO_ANSIBLE/files" ]; then
  cp -R "$SO_ANSIBLE/files" "$STAGE/"
  find "$STAGE/files" -name '.DS_Store' -delete 2>/dev/null || true
fi

# --- Pack ------------------------------------------------------------------

cd "$STAGE"
TAR_PATHS=(roles host_vars group_vars hosts site.yml playbooks deploy.sh)
[ -f "requirements.yml" ] && TAR_PATHS+=(requirements.yml)
[ -f "verify_so.sh" ]     && TAR_PATHS+=(verify_so.sh)
[ -f "vault-tools.sh" ]   && TAR_PATHS+=(vault-tools.sh)
[ -d "files" ]            && TAR_PATHS+=(files)
tar --no-xattrs -czf "$ARCHIVE" "${TAR_PATHS[@]}"

echo ""
echo "=== Archive built ==="
ls -lh "$ARCHIVE"
echo "Roles bundled: ${#seen[@]} total"
