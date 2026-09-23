#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
cat > .git/hooks/pre-commit <<'HOOK'
#!/usr/bin/env bash
# Installed by tools/install-hooks.sh - do not edit by hand, re-run that
# script instead.
#
# Scans only the files staged for THIS commit, not the whole repository.
# That's deliberate and different from a manual `./tools/check-secrets.sh`
# run (which scans everything, for auditing): a repo-wide scan would let a
# single pre-existing finding anywhere in the tree block every future
# commit forever, including ones that touch nothing related - which makes
# the hook unusable, and an unusable hook gets bypassed. Restricting to
# staged files still makes it impossible to *introduce* a new credential,
# which is the actual point of a pre-commit guard.
#
# Note that "staged files" restricts what is SEARCHED, not what is searched
# for: check-secrets.sh always decrypts every vault under inventories/, so
# check 2 is live here even when no vault.yml is part of the commit.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# Plain while-read, not `mapfile`: mapfile is bash 4+, and stock macOS ships
# bash 3.2, where this hook would have died on its first line. tools/
# check-secrets.sh itself is written for 3.2 for the same reason.
staged_files=()
while IFS= read -r staged_file; do
  # An `[ ... ] && assign` one-liner here would be the last command in the
  # loop body, so an empty line would make it return 1 and `set -e` would
  # abort the hook - i.e. block an innocent commit. Spell it out instead.
  if [ -n "$staged_file" ]; then
    staged_files[${#staged_files[@]}]=$staged_file
  fi
done < <(git diff --cached --name-only --diff-filter=ACM)
if [ "${#staged_files[@]}" -eq 0 ]; then
  exit 0
fi
exec ./tools/check-secrets.sh "${staged_files[@]}"
HOOK
chmod +x .git/hooks/pre-commit
echo "pre-commit hook installed (scans staged files only; run ./tools/check-secrets.sh with no arguments for a full repo audit)"
