#!/bin/bash
#
# vault-tools.sh — thin wrapper for the common ansible-vault operations
# on group_vars/vault.yml. Reads the password from ~/.vault_pass by
# default (matches ansible.cfg's vault_password_file setting) or from
# ./.vault_pass if that exists (useful for local dev on a Mac).
#
# Usage:
#   ./vault-tools.sh edit         # decrypt to tmpfile, open $EDITOR, re-encrypt
#   ./vault-tools.sh view         # print decrypted contents to stdout
#   ./vault-tools.sh encrypt      # encrypt an unencrypted vault.yml
#   ./vault-tools.sh decrypt      # decrypt in place (DEV ONLY — DO NOT commit)
#   ./vault-tools.sh rekey        # change the vault password (interactive)
#   ./vault-tools.sh check        # exit 0 if encrypted, 1 if plaintext

set -u

VAULT_FILE="group_vars/vault.yml"

# Prefer local ./.vault_pass (dev), fall back to controller-side path.
if [ -f "./.vault_pass" ]; then
  PW_FILE="./.vault_pass"
elif [ -f "/home/simspace/.vault_pass" ]; then
  PW_FILE="/home/simspace/.vault_pass"
elif [ -f "$HOME/.vault_pass" ]; then
  PW_FILE="$HOME/.vault_pass"
else
  echo "ERROR: no vault password file found." >&2
  echo "Create one at ./.vault_pass or ~/.vault_pass (mode 600, contents = the vault password)." >&2
  exit 1
fi

case "${1:-}" in
  edit)     ansible-vault edit    --vault-password-file "$PW_FILE" "$VAULT_FILE" ;;
  view)     ansible-vault view    --vault-password-file "$PW_FILE" "$VAULT_FILE" ;;
  encrypt)  ansible-vault encrypt --vault-password-file "$PW_FILE" "$VAULT_FILE" ;;
  decrypt)
    read -r -p "Decrypt vault.yml in place? (dev only — do not commit!) [y/N] " ans
    [ "$ans" = "y" ] || { echo "aborted"; exit 1; }
    ansible-vault decrypt --vault-password-file "$PW_FILE" "$VAULT_FILE"
    ;;
  rekey)    ansible-vault rekey   --vault-password-file "$PW_FILE" "$VAULT_FILE" ;;
  check)
    if head -1 "$VAULT_FILE" | grep -q '^\$ANSIBLE_VAULT'; then
      echo "$VAULT_FILE is encrypted"
      exit 0
    else
      echo "$VAULT_FILE is PLAINTEXT (not encrypted)"
      exit 1
    fi
    ;;
  ""|-h|--help)
    sed -n '2,20p' "$0"
    exit 0
    ;;
  *)
    echo "unknown subcommand: $1"
    sed -n '2,20p' "$0"
    exit 1
    ;;
esac
