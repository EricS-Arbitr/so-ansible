#!/bin/bash
#
# pull-tarball.sh — one-shot helper to refresh /etc/ansible/so_ab.tgz
# from GitHub and re-extract it into /etc/ansible.
#
# Usage:
#   ./pull-tarball.sh              # pull main branch head
#   ./pull-tarball.sh <sha>        # pull a specific commit (no wget cache)
#   ./pull-tarball.sh -h           # help
#
# Same fetch pattern we've been using by hand: wget through the mgmt-plane
# proxy, cache-busting via commit SHA, remove-before-extract so the
# tarball's timestamps win.
set -eu

REPO="EricS-Arbitr/so-ansible"
TARBALL="so_ab.tgz"
DEST_DIR="/etc/ansible"
DEST_PATH="${DEST_DIR}/${TARBALL}"
PROXY="http://10.255.240.1:3128"

REF="${1:-main}"
if [ "$REF" = "-h" ] || [ "$REF" = "--help" ]; then
  sed -n '2,15p' "$0"; exit 0
fi

# GitHub serves raw content by-SHA fresh (no CDN cache between commits).
# By-branch also works but can be cached — the ?nocache=<epoch> query
# suffix bypasses most caching layers.
if [[ "$REF" =~ ^[0-9a-f]{7,40}$ ]]; then
  URL="https://github.com/${REPO}/raw/${REF}/${TARBALL}"
else
  URL="https://github.com/${REPO}/raw/${REF}/${TARBALL}?nocache=$(date +%s)"
fi

echo "=== pull-tarball.sh ==="
echo "  ref  : ${REF}"
echo "  url  : ${URL}"
echo "  dest : ${DEST_PATH}"
echo ""

# 1. Delete existing tarball + verify
if [ -f "${DEST_PATH}" ]; then
  echo "-- removing existing ${DEST_PATH}"
  sudo rm -f "${DEST_PATH}"
fi
if [ -e "${DEST_PATH}" ]; then
  echo "ERROR: ${DEST_PATH} still exists after rm — aborting" >&2
  exit 1
fi
echo "  ✓ old tarball removed"

# 2. Download fresh
echo "-- downloading fresh tarball"
sudo wget --no-check-certificate --no-cache --no-cookies \
     -e use_proxy=yes -e "https_proxy=${PROXY}" \
     -O "${DEST_PATH}" \
     "${URL}" 2>&1 | tail -5

if [ ! -s "${DEST_PATH}" ]; then
  echo "ERROR: download failed or produced empty file" >&2
  exit 1
fi
SIZE=$(stat -c%s "${DEST_PATH}")
echo "  ✓ downloaded (${SIZE} bytes)"

# 3. Extract (also lists top-level dirs so we can see what landed)
echo "-- extracting into ${DEST_DIR}"
cd "${DEST_DIR}"
sudo tar xzf "${TARBALL}"
echo "  ✓ extracted. Roles present:"
ls roles/ | sed 's/^/    /'

# 4. Optional summary — count roles + files + report the version pin
echo ""
echo "=== summary ==="
echo "  roles bundled   : $(ls roles/ | wc -l | tr -d ' ')"
echo "  playbooks       : $(ls playbooks/*.yml 2>/dev/null | wc -l | tr -d ' ')"
if [ -f files/setup-automation-source/SOURCE_SHA.txt ]; then
  echo "  SO source pin   : $(cat files/setup-automation-source/SOURCE_SHA.txt)"
fi
echo ""
echo "Ready to run:  sudo ansible-playbook <playbook.yml>"
