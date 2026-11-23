#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
hooks_dir=$(git rev-parse --git-path hooks)
mkdir -p "$hooks_dir"
cat > "$hooks_dir/pre-commit" <<'HOOK'
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
chmod +x "$hooks_dir/pre-commit"
echo "pre-commit hook installed (scans staged files only; run ./tools/check-secrets.sh with no arguments for a full repo audit)"

submodule=inventories/prod
if [ ! -e "$submodule/.git" ]; then
  printf 'note: %s is not checked out, skipping its pre-commit hook\n' "$submodule"
  exit 0
fi

submodule_git_dir=$(git -C "$submodule" rev-parse --git-dir)
case "$submodule_git_dir" in
  /*) ;;
  *) submodule_git_dir="$submodule/$submodule_git_dir" ;;
esac
mkdir -p "$submodule_git_dir/hooks"
cat > "$submodule_git_dir/hooks/pre-commit" <<'HOOK'
#!/usr/bin/env bash
# Installed by the parent repository's tools/install-hooks.sh.
set -euo pipefail

parent_root=$(git rev-parse --show-superproject-working-tree)
if [ -z "$parent_root" ]; then
  printf 'pre-commit: could not find the parent repository\n' >&2
  exit 1
fi
git_local_env_vars=$(git rev-parse --local-env-vars)

git diff --cached --name-only --no-renames --diff-filter=ACM -z | (
  staged_files=()
  while IFS= read -r -d '' staged_file; do
    staged_files+=("inventories/prod/$staged_file")
  done
  if [ "${#staged_files[@]}" -eq 0 ]; then
    exit 0
  fi
  # Git exports repository-specific variables to hooks. Clear them before
  # calling the parent guard so its Git commands use the parent repository.
  while IFS= read -r git_var; do
    unset "$git_var"
  done <<< "$git_local_env_vars"
  cd "$parent_root"
  exec ./tools/check-secrets.sh "${staged_files[@]}"
)
HOOK
chmod +x "$submodule_git_dir/hooks/pre-commit"
printf 'pre-commit hook installed for %s\n' "$submodule"
