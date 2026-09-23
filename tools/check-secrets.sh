#!/usr/bin/env bash
# Fails when:
#   1. a vault file is not encrypted
#   2. a real value from a decrypted vault.yml appears in plaintext anywhere
#   3. a line matches one of a small set of high-confidence credential shapes
#
# This deliberately does not guess at secrets from key names or value shapes.
# The vault files are the single source of truth for what a secret is; check
# 2 matches against their real, decrypted values instead of guessing.
#
# Two calling conventions, on purpose:
#   - With explicit file arguments (this is what tools/install-hooks.sh wires
#     up as the pre-commit hook: it passes `git diff --cached --name-only
#     --diff-filter=ACM`), only those files are scanned. This is the fast,
#     always-safe-to-run path: it cannot let a new credential slip into a
#     commit, and it cannot be blocked by a pre-existing finding somewhere
#     else in the tree that isn't part of this commit.
#   - With no arguments, the whole repository is scanned. This is the
#     manual/audit path (`./tools/check-secrets.sh`) - slower, and able to
#     surface pre-existing findings anywhere, not just what's staged. It is
#     never what the hook runs, because a repo-wide finding unrelated to a
#     given commit must not block that commit.
#
# The file arguments choose which files are SEARCHED. They never choose which
# vault values are searched *for*: check 2 always decrypts every vault file
# under the repository's inventories/ tree, whether or not one of them
# happens to be part of the current commit. Deriving the value set from the
# arguments instead is exactly the bug that left check 2 dead in the hook -
# `git add config.yml && git commit` stages no vault.yml, so there was
# nothing to match against and a verbatim production password committed
# cleanly. Check 1 is still confined to the targeted files, so a
# pre-existing unencrypted vault elsewhere cannot block an unrelated commit.
set -uo pipefail

# Everything below is written for stock macOS /bin/bash 3.2: no associative
# arrays, no mapfile, no ${arr[@]} on a possibly-empty array without the
# ${arr[@]+"${arr[@]}"} guard. That is deliberate - a contributor with only
# the system bash must get a working guard, not a cascade of errors. (The
# previous version used `declare -A` and died on 3.2 with exit status 0,
# i.e. it failed *open*.) If that floor is ever raised, raise it here too,
# loudly, rather than letting the script half-run.
if [ -z "${BASH_VERSINFO+x}" ] ||
   [ "${BASH_VERSINFO[0]}" -lt 3 ] ||
   { [ "${BASH_VERSINFO[0]}" -eq 3 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
  printf 'check-secrets.sh: requires bash 3.2 or newer (found %s)\n' \
    "${BASH_VERSION:-non-bash shell}" >&2
  exit 1
fi

# High-confidence credential shapes, checked on every plaintext line
# regardless of key name. All four have appeared in this project's history.
# This list is deliberately not extended by guesswork - guessing is what the
# previous version of this script did, and it never converged.
SHAPE_PATTERNS=(
  'sk-[A-Za-z0-9_-]{20,}'
  'AIzaSy[A-Za-z0-9_-]{30,}'
  'AKIA[A-Z0-9]{16}'
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
)

# A vault value shorter than this is skipped by check 2: short values (port
# numbers, booleans, single-digit ids, "true"/"5432"/...) would otherwise
# match half the repo as a literal substring.
MIN_VALUE_LEN=8

# Hard wall-clock ceiling, in whole seconds, for any single `ansible-vault`
# invocation. Without a vault password available for a file, ansible-vault
# does not fail fast - it prompts, and if a controlling terminal is
# reachable (e.g. /dev/tty, which Python's getpass opens directly and which
# redirecting stdin does not prevent it from reaching) it blocks forever
# waiting for input that a git hook can never supply. This is the backstop
# that makes that impossible: past this many seconds, the process is killed
# and the vault is treated as undecryptable.
VAULT_TIMEOUT_SECS=10

# Prefer gtimeout(1) (GNU coreutils, e.g. via `brew install coreutils`) when
# present. Stock macOS ships no timeout(1) at all, so this is only an
# optimization when found - HAVE_GTIMEOUT=0 falls back to a manual
# background+poll+kill loop below that needs nothing beyond plain
# /bin/bash 3.2 and job control.
HAVE_GTIMEOUT=0
if command -v gtimeout >/dev/null 2>&1; then
  HAVE_GTIMEOUT=1
fi

status=0

# Resolve paths relative to this script, not the caller's cwd, so the ignore
# file and repo-root-relative matching work no matter where the script is
# invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IGNORE_FILE="$SCRIPT_DIR/check-secrets-ignore"

fail() { printf '%s:%s: %s\n' "$1" "$2" "$3" >&2; status=1; }

trim() {
  printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

lower() {
  printf '%s' "$1" | tr 'A-Z' 'a-z'
}

strip_quotes() {
  local v=$1
  case "$v" in
    \"*\") v=${v#\"}; v=${v%\"} ;;
    \'*\') v=${v#\'}; v=${v%\'} ;;
  esac
  printf '%s' "$v"
}

is_vault_name() {
  case "$(basename "$1")" in
    vault.yml|vault-*.yml|vault.yaml|vault-*.yaml) return 0 ;;
  esac
  return 1
}

is_encrypted() {
  head -c 15 "$1" 2>/dev/null | grep -q '^\$ANSIBLE_VAULT'
}

# True if $1 is a binary file that checks 2/3 must not scan as text (e.g.
# the .jar files under docker/keycloak/providers/).
#
# Detection: shells out to file(1) and asks for its --mime-encoding
# classification. This is the same libmagic-backed `file` command macOS
# ships as part of the base OS (/usr/bin/file - no coreutils/brew install
# needed, unlike gtimeout above), so it is present in every environment this
# script already assumes for BSD grep/sed/find. It classifies by sniffing
# actual file content (magic numbers, byte distribution) rather than by
# extension, so a renamed or extensionless binary is still caught and a
# renamed or extensionless *text* file is still scanned. Its
# --mime-encoding output is one of a small closed set of charset names
# (us-ascii, utf-8, iso-8859-1, ...) for anything it can decode as text, and
# the literal token "binary" for anything it cannot - that binary/not-binary
# split is exactly what is needed here, so no extra parsing of a full MIME
# type or magic description is required.
is_binary_file() {
  local enc
  enc=$(file -b --mime-encoding -- "$1" 2>/dev/null)
  [ "$enc" = "binary" ]
}

# Runs `ansible-vault view <file>`, incapable of blocking:
#   - stdin is /dev/null, so it can never read a password off a pipe/redirect
#   - it is killed after VAULT_TIMEOUT_SECS wall-clock seconds no matter what
#     it is waiting on (including a prompt opened directly against /dev/tty,
#     which stdin redirection alone does not stop)
# Sets VAULT_VIEW_OUTPUT to whatever it printed (possibly empty) and returns
# its exit status - 124 on timeout, matching timeout(1)'s own convention.
run_vault_view() {
  local vf=$1 rc tmpout waited pid

  if [ "$HAVE_GTIMEOUT" -eq 1 ]; then
    VAULT_VIEW_OUTPUT=$(gtimeout "$VAULT_TIMEOUT_SECS" ansible-vault view "$vf" 2>/dev/null </dev/null)
    return $?
  fi

  # No gtimeout available (the stock-macOS case): background the process,
  # poll for it to finish, and kill it once VAULT_TIMEOUT_SECS have passed.
  # Output goes to a temp file rather than a command substitution because a
  # command substitution around a backgrounded pipeline can't be polled or
  # killed from the outside - it just blocks the same as running it
  # unbackgrounded would.
  #
  # `set -m` (job control) is enabled for the duration of the backgrounding
  # so the job lands in its own new process group instead of sharing this
  # script's group; without that, `kill "$pid"` only ever reaches
  # ansible-vault itself; if it ever attempts to shell out to a child (a
  # helper, an askpass program, ...) waiting on the same unreachable
  # prompt, that child would otherwise survive the kill as an orphan. We
  # signal the whole group (`kill -- -"$pid"`) so nothing is left behind.
  # `set -m` in a non-interactive shell does not print job-control
  # chatter, so this stays silent on stdout/stderr.
  tmpout=$(mktemp "${TMPDIR:-/tmp}/check-secrets-vault.XXXXXX") || {
    VAULT_VIEW_OUTPUT=''
    return 1
  }
  set -m
  ansible-vault view "$vf" >"$tmpout" 2>/dev/null </dev/null &
  pid=$!
  set +m
  waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$VAULT_TIMEOUT_SECS" ]; then
      kill -TERM -- "-$pid" 2>/dev/null
      sleep 1
      kill -KILL -- "-$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      VAULT_VIEW_OUTPUT=$(cat "$tmpout" 2>/dev/null)
      rm -f "$tmpout"
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid" 2>/dev/null
  rc=$?
  VAULT_VIEW_OUTPUT=$(cat "$tmpout" 2>/dev/null)
  rm -f "$tmpout"
  return $rc
}

IGNORE_PATTERNS=()
IGNORE_LINES=()

load_ignore_patterns() {
  local file=$1 pline lineno=0
  [ -f "$file" ] || return 0
  while IFS= read -r pline || [ -n "$pline" ]; do
    lineno=$((lineno + 1))
    pline=$(trim "$pline")
    case "$pline" in
      ''|'#'*) continue ;;
    esac
    IGNORE_PATTERNS+=("$pline")
    IGNORE_LINES+=("$lineno")
  done < "$file"
}

# inventories/ is the entire reason this guard exists - everything it is
# meant to protect lives there. An ignore pattern is therefore never allowed
# to exempt a path under it, no matter how it is spelled.
#
# Representative inventories/-rooted paths, at a few depths and with a few
# extensions/filenames, used to test whether a pattern's *effective* reach
# (after resolving "." / ".." components) would ever match something under
# inventories/. This is deliberately match-behavior-based rather than a
# literal-prefix string check: a prefix check on "inventories/" is trivially
# walked around by "*", "*.yml", "**/vault.yml", or a "./" / "foo/../"
# dressing on the same target, all of which this list is built to catch.
PROBE_PATHS_UNDER_INVENTORIES=(
  "inventories/canary.yml"
  "inventories/canary.yaml"
  "inventories/vault.yml"
  "inventories/prod/canary.yml"
  "inventories/prod/vault.yml"
  "inventories/prod/group_vars/all/vault.yml"
  "inventories/group_vars/all/secrets.yml"
)

# Resolves "." and ".." path components the way a real filesystem path would,
# leaving wildcard characters inside the remaining components untouched. This
# is what makes "./inventories/prod/*" and "foo/../inventories/prod/*" both
# collapse to a pattern that plainly starts with "inventories/", instead of
# needing to be special-cased as string tricks.
normalize_pattern() {
  local pat=$1 part leading=0 i out=''
  local -a stack=()
  local size=0
  case "$pat" in
    /*) leading=1 ;;
  esac
  local IFS='/'
  local -a parts
  read -ra parts <<< "$pat"
  for part in ${parts[@]+"${parts[@]}"}; do
    case "$part" in
      ''|'.') continue ;;
      '..')
        if [ "$size" -gt 0 ] && [ "${stack[$((size-1))]}" != '..' ]; then
          unset "stack[$((size-1))]"
          size=$((size-1))
        else
          stack[$size]='..'
          size=$((size+1))
        fi
        ;;
      *)
        stack[$size]=$part
        size=$((size+1))
        ;;
    esac
  done
  for ((i = 0; i < size; i++)); do
    if [ -z "$out" ]; then out=${stack[$i]}; else out="$out/${stack[$i]}"; fi
  done
  [ "$leading" -eq 1 ] && out="/$out"
  printf '%s' "$out"
}

# True if a normalized pattern would exempt anything under inventories/:
# either because it names that directory outright, or because - via
# wildcards - it matches one of the representative probe paths above.
#
# Each probe is tested in BOTH the repo-relative form and the absolute form
# ("$REPO_ROOT/<probe>"). is_ignored only ever matches the repo-relative
# path, so the relative probes alone would be sound - but a pattern written
# in absolute form ("*/inventories/*", "/Users/*/inventories/*") is still a
# clear attempt to exempt the inventory tree, and silently *accepting* it
# while quietly declining to honor it is a worse answer than refusing it out
# loud. Before this, those two patterns were accepted AND honored, because
# is_ignored also matched the path as given and the default whole-repo run
# scans absolute paths: both exempted every file under inventories/,
# including vault.yml itself, so an unencrypted vault sailed past check 1.
pattern_exempts_inventories() {
  local norm=$1 probe
  case "$norm" in
    inventories|inventories/*) return 0 ;;
    "$REPO_ROOT"/inventories|"$REPO_ROOT"/inventories/*) return 0 ;;
  esac
  for probe in ${PROBE_PATHS_UNDER_INVENTORIES[@]+"${PROBE_PATHS_UNDER_INVENTORIES[@]}"}; do
    case "$probe" in
      $norm) return 0 ;;
    esac
    case "$REPO_ROOT/$probe" in
      $norm) return 0 ;;
    esac
  done
  return 1
}

# Drops any loaded ignore pattern that would exempt a path under
# inventories/, warning on stderr and failing the run for each one so a
# quietly-disarmed guard cannot pass silently.
validate_ignore_patterns() {
  local i pat line norm rel
  local -a kept_patterns=() kept_lines=()
  rel=$IGNORE_FILE
  case "$IGNORE_FILE" in
    "$REPO_ROOT"/*) rel=${IGNORE_FILE#"$REPO_ROOT"/} ;;
  esac
  for ((i = 0; i < ${#IGNORE_PATTERNS[@]}; i++)); do
    pat=${IGNORE_PATTERNS[$i]}
    line=${IGNORE_LINES[$i]}
    norm=$(normalize_pattern "$pat")
    if pattern_exempts_inventories "$norm"; then
      fail "$rel" "$line" "refusing to exempt $pat - pattern ignored"
      continue
    fi
    kept_patterns[${#kept_patterns[@]}]=$pat
    kept_lines[${#kept_lines[@]}]=$line
  done
  IGNORE_PATTERNS=(${kept_patterns[@]+"${kept_patterns[@]}"})
  IGNORE_LINES=(${kept_lines[@]+"${kept_lines[@]}"})
}

# Sets IGNORE_MATCH to the pattern that matched.
#
# Patterns are matched against the REPO-RELATIVE path ONLY, never against the
# path as spelled on the command line. The repo-relative path is derived from
# the resolved absolute path, so "./vars/x.example.yml", "vars/x.example.yml"
# and "/abs/repo/vars/x.example.yml" all still match a "vars/*.example.yml"
# pattern regardless of how the target was invoked - but there is exactly one
# spelling a pattern can be written against, which is what makes
# validate_ignore_patterns' refusal to exempt inventories/ actually binding.
# Matching the as-given path too (the previous behavior) meant a pattern that
# only matched the absolute form was never seen by that validation and then
# applied anyway on the default whole-repo run, which scans absolute paths.
#
# A file outside REPO_ROOT has no repo-relative form; its absolute path is
# used, and it cannot be under inventories/ by definition.
is_ignored() {
  local f=$1 pat dir base abs_f rel_f
  [ ${#IGNORE_PATTERNS[@]} -eq 0 ] && return 1

  dir=$(dirname "$f")
  base=$(basename "$f")
  abs_f="$(cd "$dir" 2>/dev/null && pwd)/$base"
  rel_f=$abs_f
  case "$abs_f" in
    "$REPO_ROOT"/*) rel_f=${abs_f#"$REPO_ROOT"/} ;;
  esac

  for pat in ${IGNORE_PATTERNS[@]+"${IGNORE_PATTERNS[@]}"}; do
    case "$rel_f" in
      $pat) IGNORE_MATCH=$pat; return 0 ;;
    esac
  done
  return 1
}

# --- files git itself ignores are never scanned ---------------------------
#
# A path git ignores can never be committed, so scanning it only produces
# noise (this repo deliberately keeps a couple of real plaintext config
# files on disk that are gitignored). This is intentionally a separate
# mechanism from tools/check-secrets-ignore above: it is driven by .gitignore
# itself rather than by an editable list, and it is never subject to (and
# never has to honor) that file's refusal to exempt anything under
# inventories/ - a path that's actually gitignored under inventories/ would
# mean inventories/ itself is gitignored, which would be a far bigger
# problem than this script.
#
# Determined once, and batched (one `git check-ignore --stdin` call for
# every candidate file) rather than shelled out to per file, for the same
# reason check 2 below batches its grep calls: one process per candidate
# file, run once, beats one process per (file) invocation repeated for
# every check.
IS_GIT_WORKTREE=0
if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  IS_GIT_WORKTREE=1
fi

# The set of git-ignored paths, as a single newline-delimited string with a
# leading and trailing newline, so membership is one `case` glob against
# "\n<path>\n". A bash 4 associative array would read better, but stock macOS
# ships bash 3.2, where `declare -A` is a hard error - and the error landed
# mid-run, leaving the guard exiting 0 having scanned nothing. Paths cannot
# contain a newline here (git check-ignore --stdin is newline-delimited
# itself), so a newline is a safe record separator.
GIT_IGNORED_SET=$'\n'

# Populates GIT_IGNORED_SET from a batch `git check-ignore --stdin` over
# every path in $@. Outside a git work tree this is a no-op (GIT_IGNORED_SET
# stays empty), matching "behave as now" for that case.
load_git_ignored() {
  [ "$IS_GIT_WORKTREE" -eq 1 ] || return 0
  [ "$#" -eq 0 ] && return 0
  local gi
  while IFS= read -r gi; do
    [ -n "$gi" ] && GIT_IGNORED_SET="$GIT_IGNORED_SET$gi"$'\n'
  done < <(printf '%s\n' "$@" | git -C "$REPO_ROOT" check-ignore --stdin 2>/dev/null)
}

is_git_ignored() {
  [ "$IS_GIT_WORKTREE" -eq 1 ] || return 1
  case "$GIT_IGNORED_SET" in
    *$'\n'"$1"$'\n'*) return 0 ;;
  esac
  return 1
}

# --- check 1: vault files must be encrypted -------------------------------

scan_vault() {
  local f=$1
  is_encrypted "$f" ||
    fail "$f" 1 "vault file is not encrypted - run: ansible-vault encrypt --encrypt-vault-id <env> $f"
}

# --- check 2: no real vault value appears in plaintext --------------------

VAULT_NAMES=()
VAULT_VALUES=()
skipped_short=0

# Decrypts one vault file and adds its scalar name/value pairs to
# VAULT_NAMES/VAULT_VALUES (deduplicated by value, filtered by MIN_VALUE_LEN).
# Never prints a value. On decrypt failure, warns and leaves this vault's
# values uncollected - checks 1 and 3 still run.
collect_vault_values() {
  local vf=$1 content entry key value dup i rc
  run_vault_view "$vf"
  rc=$?
  content=$VAULT_VIEW_OUTPUT
  if [ "$rc" -ne 0 ] || [ -z "$content" ]; then
    printf 'note: vault at %s could not be decrypted, skipping plaintext-match check\n' "$vf" >&2
    return
  fi
  while IFS= read -r entry || [ -n "$entry" ]; do
    [[ "$entry" =~ ^[[:space:]]*([A-Za-z0-9_]+)[[:space:]]*:[[:space:]]*(.*)$ ]] || continue
    key=${BASH_REMATCH[1]}
    value=$(trim "${BASH_REMATCH[2]}")
    value=$(strip_quotes "$value")
    case "$value" in
      ''|'~'|'null'|'Null'|'|'*|'>'*) continue ;;
    esac
    if [ ${#value} -lt "$MIN_VALUE_LEN" ]; then
      skipped_short=$((skipped_short + 1))
      continue
    fi
    dup=0
    for ((i = 0; i < ${#VAULT_VALUES[@]}; i++)); do
      if [ "${VAULT_VALUES[$i]}" = "$value" ]; then dup=1; break; fi
    done
    [ "$dup" -eq 1 ] && continue
    VAULT_NAMES+=("$key")
    VAULT_VALUES+=("$value")
  done <<< "$content"
}

# Searches every file in PLAIN_FILES for any collected vault value, as a
# literal fixed string. Never prints the value - only the file, line, and
# the vault variable name it belongs to.
#
# Performance: the previous version ran one `grep` per (vault value, file)
# pair - with ~dozens of values and thousands of files that's on the order
# of 19,000 subprocess spawns, which is what made a whole-repo run take
# 69-143s. Spawning a process is the expensive part here, not the matching
# itself, so the fix is to spawn one process per *file* instead of one per
# (value, file): all vault values are written to a single patterns file
# once, and each file is scanned against all of them in one
# `grep -F -f patterns -n` call.
#
# That collapses "which value matched" along with the subprocess count -
# grep -f only reports the matching *line*, not which of the patterns in
# the file matched it. The fix is not to bring back the per-value loop, it's
# to move that comparison out of subprocess-per-attempt territory: only
# lines grep already flagged as containing *some* vault value are looked at
# again, and for each of those (normally zero, and never more than a
# handful even repo-wide) a plain in-process bash substring test
# (`case ... in *"$value"*)`) walks VAULT_VALUES to name which one(s)
# matched. No subprocess is spawned for that walk - it's the same
# information the old code got from a second `grep -F`, but as a bash
# string comparison instead of a fork+exec.
#
# The patterns file holds live decrypted secrets, so it is never written
# inside the repo: it lives in its own private (umask 077) temp directory,
# and PATTERNS_CLEANUP (registered on the EXIT/INT/TERM/HUP trap below)
# removes that directory on any exit path, including an interrupted run.
PATTERNS_DIR=''
PATTERNS_FILE=''

cleanup_patterns_dir() {
  [ -n "$PATTERNS_DIR" ] && rm -rf -- "$PATTERNS_DIR"
  PATTERNS_DIR=''
}
trap cleanup_patterns_dir EXIT INT TERM HUP

make_patterns_file() {
  local old_umask v
  old_umask=$(umask)
  umask 077
  PATTERNS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/check-secrets-patterns.XXXXXX") || {
    umask "$old_umask"
    return 1
  }
  umask "$old_umask"
  PATTERNS_FILE="$PATTERNS_DIR/patterns"
  : > "$PATTERNS_FILE"
  for v in ${VAULT_VALUES[@]+"${VAULT_VALUES[@]}"}; do
    printf '%s\n' "$v" >> "$PATTERNS_FILE"
  done
  return 0
}

check_plaintext_matches() {
  local pf hit hline content i value
  [ ${#VAULT_VALUES[@]} -eq 0 ] && return 0
  [ ${#PLAIN_FILES[@]} -eq 0 ] && return 0

  make_patterns_file || {
    printf 'warning: could not create a private temp dir for vault-value patterns, skipping plaintext-match check\n' >&2
    return 0
  }

  for pf in ${PLAIN_FILES[@]+"${PLAIN_FILES[@]}"}; do
    while IFS= read -r hit; do
      hline=${hit%%:*}
      content=${hit#*:}
      for ((i = 0; i < ${#VAULT_VALUES[@]}; i++)); do
        value=${VAULT_VALUES[$i]}
        case "$content" in
          *"$value"*)
            fail "$pf" "$hline" "value of ${VAULT_NAMES[$i]} appears here in plaintext - reference {{ ${VAULT_NAMES[$i]} }} instead"
            ;;
        esac
      done
    done < <(grep -F -f "$PATTERNS_FILE" -n -- "$pf" 2>/dev/null)
  done

  cleanup_patterns_dir
}

# --- check 3: high-confidence credential shapes ----------------------------

# All SHAPE_PATTERNS joined into one alternation, so each file gets a single
# `grep -nE` instead of one grep per pattern. Same reasoning as the
# patterns-file batching in check_plaintext_matches above: the message
# doesn't need to say *which* shape matched, so there's no need to unwind
# the alternation after the fact the way check 2 has to unwind its matched
# values - one combined regex per file is strictly enough.
SHAPE_PATTERN_COMBINED=$(IFS='|'; printf '%s' "${SHAPE_PATTERNS[*]}")

scan_shapes() {
  local f=$1 line content
  while IFS=: read -r line content; do
    fail "$f" "$line" "credential-shaped literal found - move it to vault.yml and reference {{ vault_... }}"
  done < <(grep -nE -- "$SHAPE_PATTERN_COMBINED" "$f" 2>/dev/null)
}

# --- main -------------------------------------------------------------------

no_ignore=0
list_ignored=0
targets=()
for arg in "$@"; do
  case "$arg" in
    --no-ignore) no_ignore=1 ;;
    --list-ignored) list_ignored=1 ;;
    *) targets+=("$arg") ;;
  esac
done
[ ${#targets[@]} -eq 0 ] && targets=("$REPO_ROOT")

if [ "$no_ignore" -eq 0 ]; then
  load_ignore_patterns "$IGNORE_FILE"
  validate_ignore_patterns
fi

FOUND_FILES=()
while IFS= read -r f; do
  FOUND_FILES+=("$f")
done < <(find "${targets[@]}" -type f -not -path '*/.git/*' 2>/dev/null)

load_git_ignored ${FOUND_FILES[@]+"${FOUND_FILES[@]}"}

SCANNED_FILES=()
for f in ${FOUND_FILES[@]+"${FOUND_FILES[@]}"}; do
  if is_ignored "$f"; then
    if [ "$list_ignored" -eq 1 ]; then
      printf 'ignored: %s (pattern: %s)\n' "$f" "$IGNORE_MATCH"
    fi
    continue
  fi
  # Files git itself ignores can never be committed, so scanning them only
  # produces noise (see is_git_ignored above). Separate from, and checked
  # after, the check-secrets-ignore mechanism above.
  if is_git_ignored "$f"; then
    if [ "$list_ignored" -eq 1 ]; then
      printf 'ignored: %s (git-ignored)\n' "$f"
    fi
    continue
  fi
  # Binary files (e.g. the .jar files under docker/keycloak/providers/)
  # cannot carry a plaintext vault-value match or a credential-shaped
  # literal the way text can, and grep'ing them wastes time and can print
  # "binary file matches" noise - skip them before they ever reach checks
  # 2/3. Check 1 never sees them either: is_vault_name only matches
  # vault.yml/vault-*.yml basenames, which are always text.
  if is_binary_file "$f"; then
    continue
  fi
  SCANNED_FILES+=("$f")
done

# Check 1, and sort the scanned files into:
#   VAULT_FILES - vault-named files, decrypted (attempted) for check 2
#   PLAIN_FILES - everything else, EXCEPT files that are themselves
#                 ansible-vault encrypted (nothing plaintext to find there)
VAULT_FILES=()
PLAIN_FILES=()
for f in ${SCANNED_FILES[@]+"${SCANNED_FILES[@]}"}; do
  if is_vault_name "$f"; then
    scan_vault "$f"
    VAULT_FILES+=("$f")
  elif is_encrypted "$f"; then
    continue
  else
    PLAIN_FILES+=("$f")
  fi
done

# Check 2's value set is NOT derived from the targets: every vault file under
# the inventory tree is added here, whether or not it was scanned. See the
# header - without this, the hook (which is handed only the staged paths)
# collected no vault values at all unless a vault.yml happened to be staged
# in the same commit, and check 2 silently did nothing.
#
# Only the value set is widened. Check 1 above still runs solely on targeted
# files, so a pre-existing unencrypted vault elsewhere cannot block an
# unrelated commit, and these extra vaults are never added to PLAIN_FILES, so
# checks 2 and 3 still search only what was asked for.
add_inventory_vaults() {
  local f seen=$'\n' vf d b abs
  for vf in ${VAULT_FILES[@]+"${VAULT_FILES[@]}"}; do
    d=$(dirname "$vf"); b=$(basename "$vf")
    abs="$(cd "$d" 2>/dev/null && pwd)/$b"
    seen="$seen$abs"$'\n'
  done
  # find(1), not `git ls-files`: this must behave identically when the script
  # is run from a subdirectory (REPO_ROOT is resolved from BASH_SOURCE, not
  # from the cwd) and when it is run outside a git work tree at all.
  [ -d "$REPO_ROOT/inventories" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$seen" in
      *$'\n'"$f"$'\n'*) continue ;;
    esac
    seen="$seen$f"$'\n'
    VAULT_FILES[${#VAULT_FILES[@]}]=$f
  done < <(find "$REPO_ROOT/inventories" -type f \
             \( -name 'vault.yml' -o -name 'vault-*.yml' \
                -o -name 'vault.yaml' -o -name 'vault-*.yaml' \) \
             -not -path '*/.git/*' 2>/dev/null)
}
add_inventory_vaults

for vf in ${VAULT_FILES[@]+"${VAULT_FILES[@]}"}; do
  collect_vault_values "$vf"
done
check_plaintext_matches
if [ "$skipped_short" -gt 0 ]; then
  printf 'note: skipped %d vault value(s) shorter than %d characters\n' \
    "$skipped_short" "$MIN_VALUE_LEN" >&2
fi

for f in ${PLAIN_FILES[@]+"${PLAIN_FILES[@]}"}; do
  scan_shapes "$f"
done

exit $status
