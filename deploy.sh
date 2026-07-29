#!/bin/bash
#
# deploy.sh — three-attempt Ansible runner for so-ansible.
#
# Modeled on airfield-range/deploy.sh but with reduced fork count (small
# inventory: 4 Linux + 1 VyOS + 3 Windows placeholders = 8 hosts).
#
# Attempt 1: full site.yml against every host
# Attempt 2: --limit @retry-file (failed hosts only) if retry file exists
# Attempt 3: full site.yml again (safety net for cross-host deps)

PLAYBOOK="site.yml"
RETRY_FILE="retry/$PLAYBOOK.retry"
MAX_ATTEMPTS=3
FORKS=8

export ANSIBLE_PIPELINING=True
export ANSIBLE_GATHERING=smart
export ANSIBLE_CACHE_PLUGIN=jsonfile
export ANSIBLE_CACHE_PLUGIN_CONNECTION="$HOME/.ansible/fact_cache"
export ANSIBLE_CACHE_PLUGIN_TIMEOUT=86400
mkdir -p "$ANSIBLE_CACHE_PLUGIN_CONNECTION"

# --- Vault encryption guard ------------------------------------------------
# Refuse to deploy if the vault is plaintext (operator forgot to re-encrypt
# after editing, or a fresh clone never went through vault-tools.sh encrypt).
# An encrypted file starts with `$ANSIBLE_VAULT;1.1;AES256`.
#
# BUG FIXED 2026-07-29: this pointed at group_vars/vault.yml, but the vault
# actually lives at group_vars/all/vault.yml. The `[ -f ... ] &&` made a
# missing file short-circuit the whole test to false, so the guard passed
# unconditionally and had NEVER fired since it was written. A plaintext
# vault would have deployed silently — exactly what it exists to prevent.
# A missing vault is now fatal rather than a silent pass.
VAULT_FILE="group_vars/all/vault.yml"

if [ ! -f "$VAULT_FILE" ]; then
	echo "ERROR: $VAULT_FILE not found. Refusing to deploy."
	echo "       The roles reference vault_* variables; deploying without it"
	echo "       fails later and less clearly."
	exit 1
fi

if ! head -1 "$VAULT_FILE" | grep -q '^\$ANSIBLE_VAULT'; then
	echo "ERROR: $VAULT_FILE is plaintext. Refusing to deploy."
	echo "       Encrypt first: ./vault-tools.sh encrypt"
	exit 1
fi

if [ -f requirements.yml ]; then
	echo "=== Installing/refreshing Ansible Galaxy collections ==="
	HTTPS_PROXY="http://10.255.240.1:3128" \
		ansible-galaxy collection install -r requirements.yml \
		|| echo "WARN: galaxy install returned non-zero; continuing"
fi

for i in $(seq 1 $MAX_ATTEMPTS); do
	if [ $i -eq 2 ] && [ -f "$RETRY_FILE" ]; then
		echo "=== Attempt $i (retry-file scope — failed hosts only) ==="
		if ansible-playbook $PLAYBOOK --forks $FORKS --limit @"$RETRY_FILE" "$@"; then
			echo "Success on attempt $i (retry scope)"
			break
		fi
	else
		echo "=== Attempt $i (full sweep) ==="
		if ansible-playbook $PLAYBOOK --forks $FORKS "$@"; then
			echo "Success on attempt $i"
			break
		fi
	fi

	echo "Attempt $i failed"

	if [ $i -ge 2 ]; then
		rm -f "$RETRY_FILE"
	fi

	if [ $i -eq $MAX_ATTEMPTS ]; then
		echo "ERROR: Playbook failed after $MAX_ATTEMPTS attempts"
		exit 1
	fi
done
