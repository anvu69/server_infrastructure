#!/usr/bin/env bash
# End-to-end test for check 2 ("no real vault value appears in plaintext").
#
# Why this exists: tools/fixtures/vault-good.yml is a stub, not real
# ciphertext, so no fixture in this directory can exercise check 2 at all -
# every passing fixture only ever reaches checks 1 and 3. That blind spot is
# how the pre-commit hook shipped with check 2 permanently disabled (the
# guard used to build its vault set from the *scanned* paths, so a commit
# that staged only a leaking plaintext file had no vault values to match
# against).
#
# This test uses no real key and no real secret. It builds a throwaway
# ansible-vault key and a throwaway "repository" in a temp directory OUTSIDE
# this repo, plants the throwaway vault's own value in a neighbouring
# plaintext file, and asserts the guard reports it - both when invoked
# directly on just the leaking file, and through the pre-commit hook body
# that tools/install-hooks.sh writes (the staged-files path, which is the
# case that was broken). The temp directory is removed on every exit path.
#
# Usage:  tools/fixtures/vault-e2e-test.sh
#         GUARD=/path/to/other/check-secrets.sh tools/fixtures/vault-e2e-test.sh
# Exit 0 = all assertions passed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUARD=${GUARD:-$REPO_ROOT/tools/check-secrets.sh}
INSTALLER=${INSTALLER:-$REPO_ROOT/tools/install-hooks.sh}

for cmd in ansible-vault git; do
  command -v "$cmd" >/dev/null 2>&1 || {
    printf 'SKIP: %s not available\n' "$cmd" >&2
    exit 0
  }
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/check-secrets-e2e.XXXXXX") || exit 1
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT INT TERM HUP

failures=0
ok()   { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; failures=$((failures + 1)); }

# --- throwaway key and throwaway secret -----------------------------------
# Both are generated here, live only under $TMP, and are never written
# anywhere inside the repository.
umask 077
KEY="$TMP/vault.key"
if command -v openssl >/dev/null 2>&1; then
  openssl rand -hex 24 > "$KEY"
  SECRET="e2e-$(openssl rand -hex 16)"
else
  date +%s%N | shasum | cut -d' ' -f1 > "$KEY"
  SECRET="e2e-$(date +%s%N | shasum | cut -c1-32)"
fi

WORK="$TMP/work"
mkdir -p "$WORK/tools" \
         "$WORK/inventories/dev/host_vars/t1" \
         "$WORK/roles/app/defaults"

/bin/cp -f "$GUARD" "$WORK/tools/check-secrets.sh"
/bin/cp -f "$INSTALLER" "$WORK/tools/install-hooks.sh"
/bin/cp -f "$REPO_ROOT/tools/check-secrets-ignore" "$WORK/tools/check-secrets-ignore"
chmod +x "$WORK/tools/check-secrets.sh" "$WORK/tools/install-hooks.sh"

# Only the throwaway identity is offered, and this repo's ansible.cfg is not
# read, so the real dev/staging/prod keys are never consulted and no real
# vault is ever decrypted by this test.
: > "$TMP/ansible.cfg"
export ANSIBLE_CONFIG="$TMP/ansible.cfg"
export ANSIBLE_VAULT_IDENTITY_LIST="e2e@$KEY"

VAULT="$WORK/inventories/dev/host_vars/t1/vault.yml"
printf -- '---\nvault_t1_db_password: "%s"\n' "$SECRET" > "$VAULT"
# ansible refuses to run with non-blocking stdio handles, which it can
# inherit from some callers, so give it plain files on all three.
ansible-vault encrypt --vault-id "e2e@$KEY" --encrypt-vault-id e2e "$VAULT" \
  </dev/null >"$TMP/encrypt.log" 2>&1 || {
  printf 'SKIP: ansible-vault encrypt failed:\n' >&2
  cat "$TMP/encrypt.log" >&2
  exit 0
}
head -c 15 "$VAULT" | grep -q '^\$ANSIBLE_VAULT' || {
  bad "throwaway vault is not encrypted - test setup is broken"
  exit 1
}

# The leak: the vault's own value, copied verbatim into a plaintext file that
# lives nowhere near inventories/.
LEAK="$WORK/roles/app/defaults/main.yml"
printf -- '---\ndb_password: "%s"\n' "$SECRET" > "$LEAK"

expect_catch() {
  local label=$1 rc=$2 out=$3
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'vault_t1_db_password'; then
    ok "$label (exit $rc, reported vault_t1_db_password)"
  else
    bad "$label (exit $rc, no check-2 finding)"
  fi
}

# --- 1. direct invocation, scoped to ONLY the leaking file -----------------
# This is the shape the hook uses: the vault file is not among the arguments.
out=$(cd "$WORK" && ./tools/check-secrets.sh roles/app/defaults/main.yml 2>&1)
expect_catch "direct scan of only the leaking file" "$?" "$out"

# --- 2. same, from a subdirectory -----------------------------------------
out=$(cd "$WORK/roles/app" && ../../tools/check-secrets.sh defaults/main.yml 2>&1)
expect_catch "direct scan from a subdirectory" "$?" "$out"

# --- 3. whole-tree audit run ----------------------------------------------
out=$(cd "$WORK" && ./tools/check-secrets.sh 2>&1)
expect_catch "whole-tree audit run" "$?" "$out"

# --- 4. the pre-commit hook body, staged-files path -----------------------
# This is the case C1 broke: only the plaintext file is staged, the vault is
# not part of the commit.
(
  cd "$WORK" || exit 1
  git init -q .
  git config user.email e2e@example.invalid
  git config user.name  e2e
  ./tools/install-hooks.sh >/dev/null 2>&1
  git add roles/app/defaults/main.yml
) || bad "temp git repo / hook install failed"

if [ -x "$WORK/.git/hooks/pre-commit" ]; then
  out=$(cd "$WORK" && ./.git/hooks/pre-commit 2>&1)
  expect_catch "pre-commit hook with only the leaking file staged" "$?" "$out"
else
  bad "pre-commit hook was not installed"
fi

# --- 5. control: no leak, no finding --------------------------------------
printf -- '---\ndb_password: "{{ vault_t1_db_password }}"\n' > "$LEAK"
out=$(cd "$WORK" && ./tools/check-secrets.sh roles/app/defaults/main.yml 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "control: templated reference is not flagged (exit 0)"
else
  bad "control: templated reference was flagged (exit $rc): $out"
fi

printf '\n%d assertion(s) failed\n' "$failures"
[ "$failures" -eq 0 ]
