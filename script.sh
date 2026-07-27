#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# github-helpers — GitHub maintenance toolkit
# Subcommands:
#   Cleanup & maintenance: unstar, cleanup-forks (forks), sync-forks,
#     cleanup-branches, archive-repos, release-cleanup, pr-cleanup,
#     cleanup-packages, stale-issues, cache-cleanup, artifact-cleanup,
#     run-cleanup, gist (gists), notifications (notifs), invite-cleanup
#   Audit & visibility: repo-audit (audit), stats, workflow-status (ci),
#     secret-audit, license-check, vulnerability-check, branch-protection,
#     webhook-audit, collaborator-audit, activity-report, traffic, org-audit,
#     follow-audit (follow)
#   Bulk operations: clone-org, bulk-topic, sync-labels, export-stars,
#     rename-default-branch, dependabot-enable, mirror, bulk-settings,
#     repo-template, bulk-merge, backup
# =============================================================================

VERSION="1.3.3"

# ── Colors ───────────────────────────────────────────────────────────────────
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
NC=$'\033[0m'

# ── Auto-detect: disable colors if not a TTY or NO_COLOR is set ─────────────
# See https://no-color.org/
if [ ! -t 1 ] || [ "${NO_COLOR:-}" != "" ]; then
  RED='' GREEN='' YELLOW='' CYAN='' BOLD='' DIM='' NC=''
fi

disable_colors() {
  RED='' GREEN='' YELLOW='' CYAN='' BOLD='' DIM='' NC=''
}

# ── Shared state ─────────────────────────────────────────────────────────────
AUTO_YES=false
VERBOSE=false
DRY_RUN=false

# =============================================================================
# SHARED UTILITIES
# =============================================================================

die() {
  echo -e "${RED}Error: $1${NC}" >&2
  exit 1
}

need_arg() {
  [ -n "${2:-}" ] || die "$1 requires a value"
}

preflight_check() {
  if ! command -v gh &>/dev/null; then
    die "gh CLI is required (https://cli.github.com)"
  fi
  if ! command -v jq &>/dev/null; then
    die "jq is required (brew install jq)"
  fi
  if ! gh auth status &>/dev/null; then
    die "not logged in. Run 'gh auth login' first."
  fi
}

get_username() {
  local user
  user=$(gh api user -q '.login' 2>/dev/null)
  if [ -z "$user" ]; then
    die "could not detect authenticated user"
  fi
  echo "$user"
}

warn() {
  echo -e "${YELLOW}Warning: $1${NC}" >&2
}

# count_lines <file> — number of non-blank lines, always a single integer.
# `grep -c '.' f || echo 0` is wrong: on an empty file grep prints 0 AND exits
# 1, so the fallback fires too and the caller gets "0\n0".
count_lines() {
  [ -f "$1" ] || { printf '0'; return 0; }
  awk 'NF {n++} END {printf "%d", n + 0}' "$1"
}

# ── Temp file registry ───────────────────────────────────────────────────────
# One EXIT trap for the whole script. New commands must NOT install their own
# EXIT trap (it would replace this one); they allocate through tmp_new instead.
TMP_FILES=""

tmp_new() {
  local f
  f=$(mktemp)
  TMP_FILES="${TMP_FILES} ${f}"
  printf '%s' "$f"
}

# Intentionally unquoted: TMP_FILES is a space-separated list to word-split.
# shellcheck disable=SC2086
tmp_cleanup() {
  [ -n "${TMP_FILES:-}" ] && rm -f ${TMP_FILES}
  return 0
}

trap tmp_cleanup EXIT

# ── Confirmation ─────────────────────────────────────────────────────────────
# confirm "<prompt>" — returns 0 to proceed, 1 to abort.
# Auto-proceeds under --yes and under --dry-run.
# ALWAYS call from a conditional context:  if ! confirm "..."; then ... fi
# A bare `confirm "..."` would trip `set -e` when the user declines.
confirm() {
  local prompt="${1:-Continue?}"
  if $DRY_RUN || $AUTO_YES; then
    return 0
  fi
  local reply=""
  read -rp "${prompt} [y/N] " reply || reply=""
  [[ "$reply" =~ ^[Yy]$ ]]
}

# ── Dates ────────────────────────────────────────────────────────────────────
# cutoff_date <n> <days|months|years> — ISO-8601 UTC timestamp, N units ago.
# BSD (macOS) `date -v` first, GNU `date -d` fallback. Both emit the trailing
# `Z` form, so lexicographic comparison against GitHub timestamps is valid.
cutoff_date() {
  local n="${1:-}" unit="${2:-days}" suffix word
  case "$unit" in
    d|day|days)     suffix="d"; word="days"   ;;
    m|month|months) suffix="m"; word="months" ;;
    y|year|years)   suffix="y"; word="years"  ;;
    *) die "cutoff_date: unknown unit '${unit}' (use days, months or years)" ;;
  esac
  [[ "$n" =~ ^[0-9]+$ ]] || die "cutoff_date: '${n}' is not a whole number"
  if date -u -v-1d +%Y >/dev/null 2>&1; then
    date -u -v-"${n}${suffix}" +"%Y-%m-%dT%H:%M:%SZ"
  else
    date -u -d "${n} ${word} ago" +"%Y-%m-%dT%H:%M:%SZ"
  fi
}

# ── Sizes ────────────────────────────────────────────────────────────────────
# parse_size <str> — "100", "500K", "100MB", "1.5GiB" -> bytes (base 1024).
parse_size() {
  local input="${1:-}" num unit mult
  [ -n "$input" ] || die "parse_size: empty size"
  input="${input// /}"
  num="${input%%[A-Za-z]*}"
  unit="${input#"$num"}"
  [[ "$num" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "parse_size: invalid size: $1"
  case "$(printf '%s' "$unit" | tr '[:lower:]' '[:upper:]')" in
    ""|B)     mult=1 ;;
    K|KB|KIB) mult=1024 ;;
    M|MB|MIB) mult=1048576 ;;
    G|GB|GIB) mult=1073741824 ;;
    T|TB|TIB) mult=1099511627776 ;;
    *) die "parse_size: unknown unit '${unit}' in '$1' (use B, KB, MB, GB, TB)" ;;
  esac
  LC_ALL=C awk -v n="$num" -v m="$mult" 'BEGIN { printf "%d\n", (n * m) }'
}

# human_bytes <n> — bytes -> "1.2 GB". LC_ALL=C so the decimal separator is a dot.
human_bytes() {
  local b="${1:-0}"
  [[ "$b" =~ ^[0-9]+$ ]] || { printf '0 B'; return 0; }
  LC_ALL=C awk -v b="$b" 'BEGIN {
    split("B KB MB GB TB PB", u, " ")
    i = 1
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    if (i == 1) printf "%d %s", b, u[i]
    else        printf "%.1f %s", b, u[i]
  }'
}

# ── Degraded access: note, continue, summarize ───────────────────────────────
SKIP_LOG=""
SKIP_COUNT=0
SKIP_HINT_SHOWN=false

skip_init() {
  SKIP_LOG=$(tmp_new)
  SKIP_COUNT=0
  SKIP_HINT_SHOWN=false
}

# skip_note <target> <reason> — record a non-fatal skip. Never aborts.
skip_note() {
  SKIP_COUNT=$((SKIP_COUNT + 1))
  [ -n "$SKIP_LOG" ] && printf '%s\t%s\n' "$1" "$2" >> "$SKIP_LOG"
  $VERBOSE && echo -e "    ${YELLOW}SKIP${NC} $1 ${DIM}($2)${NC}" >&2
  return 0
}

# scope_hint <scopes> — actionable hint, printed at most once per run.
# Deliberately not a pre-flight check: fine-grained PATs report no scopes at
# all, so pre-checking produces false negatives.
scope_hint() {
  $SKIP_HINT_SHOWN && return 0
  SKIP_HINT_SHOWN=true
  echo -e "  ${DIM}hint: gh auth refresh -h github.com -s $1${NC}" >&2
  return 0
}

print_skips() {
  [ "${SKIP_COUNT:-0}" -eq 0 ] && return 0
  echo -e "  ${YELLOW}Skipped: ${BOLD}${SKIP_COUNT}${NC}" >&2
  cut -f2 "$SKIP_LOG" | sort | uniq -c | sort -rn | while read -r n reason; do
    echo -e "    ${DIM}${n}x ${reason}${NC}" >&2
  done
  if $VERBOSE; then
    echo -e "  ${DIM}Details:${NC}" >&2
    sed 's/^/    /' "$SKIP_LOG" >&2
  fi
  return 0
}

# ── GitHub API wrappers ──────────────────────────────────────────────────────
GH_RETRY_MAX="${GH_RETRY_MAX:-4}"      # total attempts
GH_RETRY_SLEEP="${GH_RETRY_SLEEP:-2}"  # seconds, doubled each attempt

# gh_api_retry <gh api args...>
# Behaves like `gh api`: stdout is the body, exit code is gh's.
# Retries only on secondary rate limits, 429/5xx and transport errors.
# Also retries GraphQL RATE_LIMITED, which arrives as HTTP 200 with an error
# in the body. Never swallows a real error: on give-up it re-emits the body on
# stdout (so partial GraphQL data stays usable) and gh's stderr on stderr.
gh_api_retry() {
  local attempt=1 rc out err errfile wait limited
  errfile=$(mktemp)
  while :; do
    rc=0
    out=$(gh api "$@" 2>"$errfile") || rc=$?
    limited=false
    case "$out" in *'"RATE_LIMITED"'*) limited=true ;; esac
    if [ "$rc" -eq 0 ] && ! $limited; then
      rm -f "$errfile"
      printf '%s' "$out"
      return 0
    fi
    err=$(cat "$errfile" 2>/dev/null || true)
    if [ "$attempt" -lt "$GH_RETRY_MAX" ] && { $limited || printf '%s' "$err" | grep -qiE \
        'secondary rate limit|rate limit|abuse detection|submitted too quickly|retry after|HTTP (429|50[0-4])|timeout|connection reset|unexpected EOF'; }; then
      wait=$(( GH_RETRY_SLEEP * (2 ** (attempt - 1)) ))
      warn "gh api transient failure (attempt ${attempt}/${GH_RETRY_MAX}); retrying in ${wait}s"
      sleep "$wait"
      attempt=$((attempt + 1))
      continue
    fi
    rm -f "$errfile"
    printf '%s' "$out"
    [ -n "$err" ] && printf '%s\n' "$err" >&2
    [ "$rc" -eq 0 ] && rc=1
    return "$rc"
  done
}

# gh_api_try <label> <gh api args...>
# stdout = body on success. Returns 1 after recording a skip on failure.
# ALWAYS call as:  json=$(gh_api_try "lbl" ...) || continue
gh_api_try() {
  local label="$1"; shift
  local body rc=0 errfile err reason
  errfile=$(mktemp)
  body=$(gh_api_retry "$@" 2>"$errfile") || rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -f "$errfile"
    printf '%s' "$body"
    return 0
  fi
  err=$(cat "$errfile" 2>/dev/null || true)
  rm -f "$errfile"
  case "$err" in
    *SAML*|*saml*)              reason="SAML SSO not authorized for this org" ;;
    *"HTTP 401"*)               reason="not authenticated (401)" ;;
    *"HTTP 403"*|*Forbidden*)   reason="forbidden - missing scope or permission (403)" ;;
    *"HTTP 404"*|*"Not Found"*) reason="not found or no access (404)" ;;
    *"HTTP 410"*)               reason="feature disabled (410)" ;;
    *"HTTP 5"*)                 reason="GitHub server error" ;;
    *)                          reason="request failed" ;;
  esac
  skip_note "$label" "$reason"
  return 1
}

# gh_paginate <label> <path> [jq-selector] — full pagination as one JSON array.
# The selector defaults to '.[]' for endpoints that return a bare array; pass
# e.g. '.artifacts[]' for the ones that wrap it in an object.
# Always include per_page=100 in <path>: --paginate does not raise gh's
# default page size of 30.
gh_paginate() {
  local label="$1" path="$2" selector="${3:-.[]}" raw
  raw=$(gh_api_try "$label" "$path" --paginate --jq "$selector") || return 1
  printf '%s' "$raw" | jq -s '.'
}

# resolve_repo_list <target> <repo-or-empty> <limit> <label> -> file path
# Emits a temp file of nameWithOwner lines and warns when the list is capped,
# so a truncated sweep never reads as full coverage.
resolve_repo_list() {
  local target="$1" single="$2" limit="$3" label="$4" f
  f=$(tmp_new)
  if [ -n "$single" ]; then
    printf '%s\n' "$single" > "$f"
  else
    list_repos "$target" "$limit" --no-archived > "$f" 2>/dev/null \
      || die "${label}: failed to list repos for ${target}"
    local n
    n=$(count_lines "$f")
    if [ "$n" -ge "$limit" ]; then
      warn "${label}: limited to ${limit} repos — raise it with --limit"
    fi
  fi
  printf '%s' "$f"
}

# require_scope <scope> — 0 if the token carries it, or if scopes are
# unknowable (fine-grained PAT / GitHub App emit no X-Oauth-Scopes header).
require_scope() {
  local want="$1" scopes
  scopes=$(gh api user -i 2>/dev/null | tr -d '\r' \
    | awk 'tolower($1) == "x-oauth-scopes:" { sub(/^[^:]*:[ ]*/, ""); print; exit }') || scopes=""
  [ -z "$scopes" ] && return 0
  case ",${scopes// /}," in
    *",${want},"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ── Repo listing ─────────────────────────────────────────────────────────────
# list_repos <target> <limit> [extra gh repo list flags...] -> nameWithOwner lines
list_repos() {
  local target="$1" limit="${2:-9999}"
  shift 2
  gh repo list "$target" --json nameWithOwner --limit "$limit" "$@" --jq '.[].nameWithOwner'
}

# ── Output ───────────────────────────────────────────────────────────────────
hr() {
  echo -e "${DIM}─────────────────────────────────────────────${NC}"
}

# header "Title" — use `header "Title" >&2` in commands that render to stdout.
header() {
  echo -e "${BOLD}${CYAN}$1${NC} ${DIM}v${VERSION}${NC}"
  hr
}

# render_rows <json|csv|md> <json-array-of-flat-objects>
# Column order and headers come from the first object's key order.
render_rows() {
  local format="$1" rows="$2"
  case "$format" in
    json) printf '%s\n' "$rows" | jq '.' ;;
    csv)  printf '%s\n' "$rows" | jq -r '
            if length == 0 then empty else
              (.[0] | keys_unsorted) as $k
              | ($k | @csv),
                (.[] as $r | [$k[] | $r[.] |
                   if . == null then "" elif type == "string" then gsub("[\r\n]+"; " ") else tostring end
                 ] | @csv)
            end' ;;
    md)   printf '%s\n' "$rows" | jq -r '
            if length == 0 then empty else
              (.[0] | keys_unsorted) as $k
              | "| " + ($k | join(" | ")) + " |",
                "|" + ($k | map("---") | join("|")) + "|",
                (.[] as $r | "| " + ([$k[] | $r[.] |
                   if . == null then "" elif type == "string" then gsub("[\r\n]+"; " ") | gsub("\\|"; "/") else tostring end
                 ] | join(" | ")) + " |")
            end' ;;
    *) die "unknown format: ${format}" ;;
  esac
}

# write_output <file-or-empty> <content>
write_output() {
  if [ -n "$1" ]; then
    printf '%s\n' "$2" > "$1"
    echo -e "${GREEN}Done!${NC} Saved to ${BOLD}$1${NC}" >&2
  else
    printf '%s\n' "$2"
  fi
}

# ── Git ──────────────────────────────────────────────────────────────────────
# git_mirror_clone <owner/name> <dest_dir>
# Uses `gh repo clone` so gh's credential helper handles private repos; a raw
# https:// URL fails on private repos unless the user ran `gh auth setup-git`.
git_mirror_clone() {
  gh repo clone "$1" "$2" -- --mirror --quiet
}

# git_bundle_from_mirror <mirror_dir> <bundle_path> — rc 2 when the repo is empty
# (`git bundle create` refuses to create a bundle with no refs).
git_bundle_from_mirror() {
  if [ "$(git -C "$1" for-each-ref --count=1 | wc -l | tr -d ' ')" -eq 0 ]; then
    return 2
  fi
  git -C "$1" bundle create "$2" --all HEAD >/dev/null 2>&1
}

sha256_of() {
  if command -v shasum &>/dev/null; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# ── Top-level usage ──────────────────────────────────────────────────────────
usage() {
  cat <<EOF
${BOLD}github-helpers${NC} ${DIM}v${VERSION}${NC} — GitHub maintenance toolkit

${BOLD}USAGE${NC}
  github-helpers <command> [options]

${BOLD}COMMANDS${NC}
  ${BOLD}Cleanup & maintenance${NC}
  unstar              Clean up your GitHub stars (filter & bulk-unstar)
  cleanup-forks       Audit forks; delete only those with zero activity
  sync-forks          Update your forks from their upstream
  cleanup-branches    Delete merged or stale remote branches
  archive-repos       Archive inactive repos in batch
  release-cleanup     Delete old releases
  pr-cleanup          Find and close abandoned pull requests
  cleanup-packages    Delete old GitHub Package versions
  stale-issues        Find and close stale issues/PRs
  cache-cleanup       Purge GitHub Actions caches (10 GB/repo quota)
  artifact-cleanup    Delete GitHub Actions artifacts
  run-cleanup         Delete old workflow runs (and their logs)
  gist                List, export and bulk-delete your gists
  notifications       Triage and bulk-clear your notification inbox
  invite-cleanup      List, accept or decline pending invitations

  ${BOLD}Audit & visibility${NC}
  repo-audit          Scan repos for missing LICENSE, README, description, topics
  stats               Quick GitHub profile stats dashboard
  workflow-status     Overview of latest CI workflow runs
  secret-audit        List secrets and env vars across repos
  license-check       Check and add LICENSE files
  vulnerability-check Audit Dependabot vulnerability alerts
  branch-protection   Audit or enforce branch protection rules
  webhook-audit       List webhooks across repos
  collaborator-audit  Audit outside collaborators and permissions
  org-audit           Org-level security and membership posture
  follow-audit        Who follows you back, and who does not
  activity-report     Generate activity summary for a period
  traffic             Snapshot repo views and clones (14-day window)

  ${BOLD}Bulk operations${NC}
  clone-org           Clone all repos from a GitHub org or user
  bulk-topic          Add or remove topics across multiple repos
  sync-labels         Sync issue labels from a template repo
  export-stars        Export starred repos to JSON/CSV/Markdown
  rename-default-branch  Rename default branch across repos
  dependabot-enable   Enable Dependabot on repos
  mirror              Mirror repos to another remote
  bulk-settings       Apply repo settings in batch
  bulk-merge          Merge green dependency-update PRs in batch
  repo-template       Sync settings from a template repo
  backup              Export repos and their metadata locally

${BOLD}FLAGS${NC}
  --no-color    Disable colored output
  --version     Show version
  --help        Show this help

${BOLD}EXAMPLES${NC}
  github-helpers unstar --archived --dry-run
  github-helpers forks --report
  github-helpers cleanup-forks --older-than 180 --dry-run
  github-helpers stats --org my-company
  github-helpers repo-audit --language Shell
  github-helpers bulk-topic --add cli --language Shell --dry-run
  github-helpers clone-org --org my-company --ssh --pull

Run ${BOLD}github-helpers <command> --help${NC} for command-specific help.
EOF
}

# =============================================================================
# COMMAND: unstar
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
FILTER_COMMIT_BEFORE=""
FILTER_COMMIT_AFTER=""
FILTER_ACTIVITY_BEFORE=""
FILTER_ACTIVITY_AFTER=""
FILTER_ARCHIVED=""
FILTER_MODE="any"
FROM_FILE=""
OUT_FILE="unstar-repos.txt"
SAVE_LIST=false

cmd_unstar_usage() {
  cat <<EOF
${BOLD}github-helpers unstar${NC} ${DIM}v${VERSION}${NC} — Clean up your GitHub stars

${BOLD}USAGE${NC}
  github-helpers unstar [options]
  github-helpers unstar --from <file>

${BOLD}FILTERS${NC} (combine as many as needed)
  --commit-before DATE    Last commit was BEFORE this date  (YYYY-MM-DD)
  --commit-after  DATE    Last commit was AFTER this date   (YYYY-MM-DD)
  --activity-before DATE  Last push was BEFORE this date    (YYYY-MM-DD)
  --activity-after  DATE  Last push was AFTER this date     (YYYY-MM-DD)
  --archived              Include only archived repos
  --not-archived          Include only non-archived repos

${BOLD}LOGIC${NC}
  --any                   Match repos where ANY filter hits  (OR, default)
  --all                   Match repos where ALL filters hit  (AND)

${BOLD}I/O${NC}
  --dry-run               Preview only — saves list to file, no unstar
  --out FILE              Save matched repos to FILE (default: unstar-repos.txt)
                          Implies --save-list when used without --dry-run
  --save-list             Save the matched repos list (even without --dry-run)
  --from FILE             Skip fetch — unstar repos from a previous dry-run file

${BOLD}FLAGS${NC}
  -y, --yes               Skip confirmation prompt
  -v, --verbose           Show details for every repo (reasons, dates)
  -h, --help              Show this help

${BOLD}WORKFLOW${NC}
  1. Preview:  github-helpers unstar --commit-before 2024-01-01 --archived --dry-run -v
  2. Edit:     vim unstar-repos.txt
  3. Execute:  github-helpers unstar --from unstar-repos.txt

${BOLD}EXAMPLES${NC}
  # Unstar repos with no commit since 2024 OR archived (dry-run)
  github-helpers unstar --commit-before 2024-01-01 --archived --dry-run

  # Same but ALL must match (AND)
  github-helpers unstar --all --commit-before 2024-01-01 --archived --dry-run

  # Execute from a previous dry-run
  github-helpers unstar --from unstar-repos.txt

  # One-shot: unstar all archived repos
  github-helpers unstar --archived -y
EOF
  exit 0
}

cmd_unstar_parse_args() {
  if [ $# -eq 0 ]; then
    cmd_unstar_usage
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
      --commit-before)   need_arg "--commit-before" "${2:-}"; FILTER_COMMIT_BEFORE="${2}T00:00:00Z"; shift 2 ;;
      --commit-after)    need_arg "--commit-after" "${2:-}"; FILTER_COMMIT_AFTER="${2}T00:00:00Z";  shift 2 ;;
      --activity-before) need_arg "--activity-before" "${2:-}"; FILTER_ACTIVITY_BEFORE="${2}T00:00:00Z"; shift 2 ;;
      --activity-after)  need_arg "--activity-after" "${2:-}"; FILTER_ACTIVITY_AFTER="${2}T00:00:00Z"; shift 2 ;;
      --archived)        FILTER_ARCHIVED="true";  shift ;;
      --not-archived)    FILTER_ARCHIVED="false"; shift ;;
      --any)             FILTER_MODE="any"; shift ;;
      --all)             FILTER_MODE="all"; shift ;;
      --from)            need_arg "--from" "${2:-}"; FROM_FILE="$2"; shift 2 ;;
      --out)             need_arg "--out" "${2:-}"; OUT_FILE="$2"; SAVE_LIST=true; shift 2 ;;
      --save-list)       SAVE_LIST=true; shift ;;
      --dry-run)         DRY_RUN=true;  shift ;;
      -y|--yes)          AUTO_YES=true; shift ;;
      -v|--verbose)      VERBOSE=true;  shift ;;
      -h|--help)         cmd_unstar_usage ;;
      *) die "unstar: unknown option: $1" ;;
    esac
  done

  # --from mode: no filters needed
  if [ -n "$FROM_FILE" ]; then
    if [ ! -f "$FROM_FILE" ]; then
      die "file not found: ${FROM_FILE}"
    fi
    return
  fi

  if [ -z "$FILTER_COMMIT_BEFORE" ] && [ -z "$FILTER_COMMIT_AFTER" ] \
    && [ -z "$FILTER_ACTIVITY_BEFORE" ] && [ -z "$FILTER_ACTIVITY_AFTER" ] \
    && [ -z "$FILTER_ARCHIVED" ]; then
    die "unstar: at least one filter is required (or use --from <file>)"
  fi

  # Validate date formats
  for date_label in "commit-before:$FILTER_COMMIT_BEFORE" "commit-after:$FILTER_COMMIT_AFTER" \
                    "activity-before:$FILTER_ACTIVITY_BEFORE" "activity-after:$FILTER_ACTIVITY_AFTER"; do
    label="${date_label%%:*}"
    val="${date_label#*:}"
    [ -z "$val" ] && continue
    if [[ ! "$val" =~ ^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
      die "invalid date for --${label}: ${val%%T*}"
    fi
  done
}

# ── Filtering helpers ────────────────────────────────────────────────────────
declare -a REASONS

cmd_unstar_matches_filters() {
  local repo="$1" pushed_at="$2" archived="$3" last_commit="$4"
  REASONS=()

  local active=0 passed=0

  # --archived / --not-archived
  if [ -n "$FILTER_ARCHIVED" ]; then
    active=$((active + 1))
    if [ "$FILTER_ARCHIVED" = "true" ] && [ "$archived" = "true" ]; then
      passed=$((passed + 1))
      REASONS+=("archived")
    elif [ "$FILTER_ARCHIVED" = "false" ] && [ "$archived" != "true" ]; then
      passed=$((passed + 1))
      REASONS+=("not archived")
    fi
  fi

  # --activity-before (pushed_at)
  if [ -n "$FILTER_ACTIVITY_BEFORE" ]; then
    active=$((active + 1))
    if [ -z "$pushed_at" ]; then
      passed=$((passed + 1))
      REASONS+=("push: unknown")
    elif [[ ! "$pushed_at" > "$FILTER_ACTIVITY_BEFORE" ]]; then
      passed=$((passed + 1))
      REASONS+=("push: ${pushed_at%%T*}")
    fi
  fi

  # --activity-after (pushed_at)
  if [ -n "$FILTER_ACTIVITY_AFTER" ]; then
    active=$((active + 1))
    if [ -n "$pushed_at" ] && [[ ! "$pushed_at" < "$FILTER_ACTIVITY_AFTER" ]]; then
      passed=$((passed + 1))
      REASONS+=("push: ${pushed_at%%T*}")
    fi
  fi

  # --commit-before
  if [ -n "$FILTER_COMMIT_BEFORE" ]; then
    active=$((active + 1))
    if [ -z "$last_commit" ]; then
      passed=$((passed + 1))
      REASONS+=("commit: none")
    elif [[ ! "$last_commit" > "$FILTER_COMMIT_BEFORE" ]]; then
      passed=$((passed + 1))
      REASONS+=("commit: ${last_commit%%T*}")
    fi
  fi

  # --commit-after
  if [ -n "$FILTER_COMMIT_AFTER" ]; then
    active=$((active + 1))
    if [ -n "$last_commit" ] && [[ ! "$last_commit" < "$FILTER_COMMIT_AFTER" ]]; then
      passed=$((passed + 1))
      REASONS+=("commit: ${last_commit%%T*}")
    fi
  fi

  # Combine based on mode
  if [ "$FILTER_MODE" = "any" ]; then
    [ "$passed" -gt 0 ]
  else
    [ "$passed" -eq "$active" ]
  fi
}

# ── Fetch starred repos via GraphQL (batch) ──────────────────────────────────
cmd_unstar_fetch_starred_repos() {
  local username="$1"
  local has_next="true" total_fetched=0
  local -a cursor_arg=("-F" "cursor=null")

  while [ "$has_next" = "true" ]; do
    local result
    result=$(gh api graphql -f query='
      query($login: String!, $cursor: String) {
        user(login: $login) {
          starredRepositories(first: 100, after: $cursor) {
            totalCount
            edges {
              node {
                nameWithOwner
                pushedAt
                isArchived
                defaultBranchRef {
                  target {
                    ... on Commit {
                      committedDate
                    }
                  }
                }
              }
            }
            pageInfo {
              hasNextPage
              endCursor
            }
          }
        }
      }' -f login="$username" "${cursor_arg[@]}") || {
      die "GraphQL request failed. Check your network and gh auth."
    }

    # Check for GraphQL-level errors
    local gql_error
    gql_error=$(echo "$result" | jq -r '.errors[0].message // empty' 2>/dev/null)
    if [ -n "$gql_error" ]; then
      die "GitHub API: ${gql_error}"
    fi

    # Output each repo as TSV: name  pushed_at  archived  committed_date
    echo "$result" | jq -r '
      .data.user.starredRepositories.edges[] |
      [
        .node.nameWithOwner,
        (.node.pushedAt // ""),
        (.node.isArchived | tostring),
        (.node.defaultBranchRef.target.committedDate // "")
      ] | @tsv'

    local count total_count
    count=$(echo "$result" | jq '.data.user.starredRepositories.edges | length')
    total_fetched=$((total_fetched + count))
    total_count=$(echo "$result" | jq '.data.user.starredRepositories.totalCount')
    echo -e "  ${DIM}Fetched ${total_fetched}/${total_count} starred repos...${NC}" >&2

    has_next=$(echo "$result" | jq -r '.data.user.starredRepositories.pageInfo.hasNextPage')
    local end_cursor
    end_cursor=$(echo "$result" | jq -r '.data.user.starredRepositories.pageInfo.endCursor // empty')
    if [ -z "$end_cursor" ]; then
      break
    fi
    cursor_arg=("-f" "cursor=${end_cursor}")
  done
}

# ── Unstar from list ─────────────────────────────────────────────────────────
cmd_unstar_do_unstar() {
  local list_file="$1"

  local total
  total=$(count_lines "$list_file")

  if [ "$total" -eq 0 ]; then
    echo -e "${GREEN}No repos to unstar.${NC}"
    exit 0
  fi

  echo -e "${YELLOW}${total} repos to unstar${NC}"
  echo ""

  echo -e "${BOLD}Repos:${NC}"
  while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    echo -e "  ${DIM}•${NC} $repo"
  done < "$list_file"
  echo ""

  if ! confirm "Unstar all $total repos?"; then
    echo "Cancelled."
    exit 0
  fi

  local count=0 failed=0
  while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    if gh api --method DELETE "/user/starred/$repo" &>/dev/null; then
      count=$((count + 1))
    else
      failed=$((failed + 1))
      echo -e "  ${RED}FAILED${NC}: $repo"
    fi
    local progress=$((count + failed))
    if [ $((progress % 25)) -eq 0 ] && [ "$progress" -gt 0 ]; then
      echo -e "  ${DIM}[${progress}/${total}]...${NC}"
    fi
  done < "$list_file"

  echo ""
  echo -e "${GREEN}Done!${NC} Unstarred: ${BOLD}${count}${NC}, Failed: ${BOLD}${failed}${NC}"
}

# ── Unstar main ──────────────────────────────────────────────────────────────
cmd_unstar_main() {
  cmd_unstar_parse_args "$@"
  preflight_check

  local USERNAME
  USERNAME=$(get_username)

  echo -e "${BOLD}${CYAN}GitHub Star Cleanup${NC} ${DIM}v${VERSION}${NC}"
  echo -e "${DIM}─────────────────────────────────────────────${NC}"
  echo -e "  User: ${BOLD}${USERNAME}${NC}"

  # ── --from mode: skip fetch, unstar directly ────────────────────────────
  if [ -n "$FROM_FILE" ]; then
    echo -e "  From: ${BOLD}${FROM_FILE}${NC}"
    echo ""
    cmd_unstar_do_unstar "$FROM_FILE"
    exit 0
  fi

  # ── Filter mode ─────────────────────────────────────────────────────────
  local -a active_filters=()
  [ -n "$FILTER_COMMIT_BEFORE" ]   && active_filters+=("commit before ${FILTER_COMMIT_BEFORE%%T*}")
  [ -n "$FILTER_COMMIT_AFTER" ]    && active_filters+=("commit after ${FILTER_COMMIT_AFTER%%T*}")
  [ -n "$FILTER_ACTIVITY_BEFORE" ] && active_filters+=("activity before ${FILTER_ACTIVITY_BEFORE%%T*}")
  [ -n "$FILTER_ACTIVITY_AFTER" ]  && active_filters+=("activity after ${FILTER_ACTIVITY_AFTER%%T*}")
  [ "$FILTER_ARCHIVED" = "true" ]  && active_filters+=("archived only")
  [ "$FILTER_ARCHIVED" = "false" ] && active_filters+=("not archived")

  local mode_label="ALL match"
  local mode_join=" AND "
  if [ "$FILTER_MODE" = "any" ]; then
    mode_label="ANY match"
    mode_join=" OR "
  fi
  local filters_display
  filters_display=$(IFS="$mode_join"; echo "${active_filters[*]}")

  echo -e "  Filters: ${filters_display} ${DIM}(${mode_label})${NC}"
  if $DRY_RUN; then
    echo -e "  Mode:    ${YELLOW}DRY RUN${NC} (no changes)"
  fi
  echo ""

  # ── Fetch all starred repos ──────────────────────────────────────────────
  DATAFILE=$(mktemp)
  trap 'rm -f "${DATAFILE:-}" "${MATCHFILE:-}"' EXIT

  echo -e "${DIM}Fetching starred repos...${NC}"
  cmd_unstar_fetch_starred_repos "$USERNAME" > "$DATAFILE"
  echo ""

  # ── Apply filters ────────────────────────────────────────────────────────
  MATCHFILE=$(mktemp)

  local total_fetched=0 matched=0 skipped=0

  while IFS=$'\t' read -r repo pushed_at archived last_commit; do
    [ -z "$repo" ] && continue
    total_fetched=$((total_fetched + 1))

    if cmd_unstar_matches_filters "$repo" "$pushed_at" "$archived" "$last_commit"; then
      echo "$repo" >> "$MATCHFILE"
      matched=$((matched + 1))

      if $VERBOSE; then
        local reason_str
        reason_str=$(IFS=', '; echo "${REASONS[*]}")
        printf "  ${GREEN}✓${NC} %-45s ${DIM}%s${NC}\n" "$repo" "$reason_str"
      fi
    else
      skipped=$((skipped + 1))
      if $VERBOSE; then
        printf "  ${DIM}✗ %-45s${NC}\n" "$repo"
      fi
    fi
  done < "$DATAFILE"

  echo ""

  # ── Results ──────────────────────────────────────────────────────────────
  local total
  total=$(sort -u "$MATCHFILE" | awk 'NF {n++} END {printf "%d", n + 0}')

  if [ "$total" -eq 0 ]; then
    echo -e "${GREEN}No repos matched your filters. Your stars are clean!${NC}"
    exit 0
  fi

  echo -e "${YELLOW}Found ${total} repos matching your filters${NC} (scanned ${total_fetched}, skipped ${skipped})"
  echo ""

  # Save sorted list — write to OUT_FILE if dry-run or --save-list/--out
  if $DRY_RUN || $SAVE_LIST; then
    RESULTFILE="$OUT_FILE"
  else
    RESULTFILE=$(mktemp)
    trap 'rm -f "${DATAFILE:-}" "${MATCHFILE:-}" "${RESULTFILE:-}"' EXIT
  fi
  sort -u "$MATCHFILE" | grep '.' > "$RESULTFILE"

  if ! $VERBOSE; then
    echo -e "${BOLD}Repos to unstar:${NC}"
    while IFS= read -r repo; do
      echo -e "  ${DIM}•${NC} $repo"
    done < "$RESULTFILE"
    echo ""
  fi

  # ── Dry-run stop ─────────────────────────────────────────────────────────
  if $DRY_RUN; then
    echo -e "${YELLOW}DRY RUN — no repos were unstarred.${NC}"
    echo -e "List saved to: ${BOLD}${OUT_FILE}${NC} (${total} repos)"
    echo ""
    echo -e "Edit the file to remove repos you want to keep, then run:"
    echo -e "  ${BOLD}github-helpers unstar --from ${OUT_FILE}${NC}"
    exit 0
  fi

  # ── Confirm & unstar ────────────────────────────────────────────────────
  if ! confirm "Unstar all $total repos?"; then
    echo "Cancelled."
    exit 0
  fi

  local count=0 failed=0
  while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    if gh api --method DELETE "/user/starred/$repo" &>/dev/null; then
      count=$((count + 1))
    else
      failed=$((failed + 1))
      echo -e "  ${RED}FAILED${NC}: $repo"
    fi
    local progress=$((count + failed))
    if [ $((progress % 25)) -eq 0 ] && [ "$progress" -gt 0 ]; then
      echo -e "  ${DIM}[${progress}/${total}]...${NC}"
    fi
  done < "$RESULTFILE"

  echo ""
  echo -e "${GREEN}Done!${NC} Unstarred: ${BOLD}${count}${NC}, Failed: ${BOLD}${failed}${NC}"
  if $SAVE_LIST; then
    echo -e "List saved to: ${BOLD}${OUT_FILE}${NC}"
  fi
}

# =============================================================================
# COMMAND: clone-org
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
CLONE_ORG_TARGET=""
CLONE_ORG_TARGET_TYPE=""
CLONE_ORG_DIR="."
CLONE_ORG_DRY_RUN=false
CLONE_ORG_SSH=false
CLONE_ORG_PULL=false
CLONE_ORG_ARCHIVED=""
CLONE_ORG_FORK=""
CLONE_ORG_VISIBILITY=""
CLONE_ORG_LANGUAGE=""
CLONE_ORG_TOPIC=""
CLONE_ORG_LIMIT=0

cmd_clone_org_usage() {
  cat <<EOF
${BOLD}github-helpers clone-org${NC} ${DIM}v${VERSION}${NC} — Clone all repos from a GitHub org or user

${BOLD}USAGE${NC}
  github-helpers clone-org --org NAME [options]
  github-helpers clone-org --user NAME [options]

${BOLD}TARGET${NC} (one is required)
  --org NAME              GitHub organization name
  --user NAME             GitHub username

${BOLD}OPTIONS${NC}
  --dir PATH              Clone destination directory (default: current dir)
  --ssh                   Clone via SSH instead of HTTPS
  --pull                  Pull existing repos instead of skipping them
  --archived              Only archived repos
  --not-archived          Only non-archived repos
  --fork                  Only forked repos
  --source                Only non-fork (source) repos
  --visibility TYPE       Filter by visibility: public, private, internal
  --language LANG         Filter by primary language (e.g. Go, TypeScript)
  --topic TOPIC           Filter by topic
  --limit N               Maximum number of repos (default: all)
  --dry-run               List repos without cloning
  -y, --yes               Skip confirmation prompt
  -v, --verbose           Show detailed output
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  # List all repos in an org (dry-run)
  github-helpers clone-org --org my-company --dry-run

  # Clone all non-archived repos via SSH
  github-helpers clone-org --org my-company --ssh --not-archived

  # Clone only Go source repos from a user
  github-helpers clone-org --user octocat --source --language Go

  # Clone into a specific directory, pull existing
  github-helpers clone-org --org my-company --dir ~/projects --pull

  # Clone only public repos, no confirmation
  github-helpers clone-org --org my-company --visibility public -y
EOF
  exit 0
}

cmd_clone_org_parse_args() {
  if [ $# -eq 0 ]; then
    cmd_clone_org_usage
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
      --org)           need_arg "--org" "${2:-}"; CLONE_ORG_TARGET="$2"; CLONE_ORG_TARGET_TYPE="org"; shift 2 ;;
      --user)          need_arg "--user" "${2:-}"; CLONE_ORG_TARGET="$2"; CLONE_ORG_TARGET_TYPE="user"; shift 2 ;;
      --dir)           need_arg "--dir" "${2:-}"; CLONE_ORG_DIR="$2"; shift 2 ;;
      --ssh)           CLONE_ORG_SSH=true; shift ;;
      --pull)          CLONE_ORG_PULL=true; shift ;;
      --archived)      CLONE_ORG_ARCHIVED="true"; shift ;;
      --not-archived)  CLONE_ORG_ARCHIVED="false"; shift ;;
      --fork)          CLONE_ORG_FORK="true"; shift ;;
      --source)        CLONE_ORG_FORK="false"; shift ;;
      --visibility)    need_arg "--visibility" "${2:-}"; CLONE_ORG_VISIBILITY="$2"; shift 2 ;;
      --language)      need_arg "--language" "${2:-}"; CLONE_ORG_LANGUAGE="$2"; shift 2 ;;
      --topic)         need_arg "--topic" "${2:-}"; CLONE_ORG_TOPIC="$2"; shift 2 ;;
      --limit)         need_arg "--limit" "${2:-}"; CLONE_ORG_LIMIT="$2"; shift 2 ;;
      --dry-run)       CLONE_ORG_DRY_RUN=true; shift ;;
      -y|--yes)        AUTO_YES=true; shift ;;
      -v|--verbose)    VERBOSE=true; shift ;;
      -h|--help)       cmd_clone_org_usage ;;
      *) die "clone-org: unknown option: $1" ;;
    esac
  done

  if [ -z "$CLONE_ORG_TARGET" ]; then
    die "clone-org: --org NAME or --user NAME is required"
  fi

  if [ "$CLONE_ORG_LIMIT" != "0" ] && ! [[ "$CLONE_ORG_LIMIT" =~ ^[0-9]+$ ]]; then
    die "clone-org: --limit must be a number"
  fi
}

cmd_clone_org_list_repos() {
  local limit="${CLONE_ORG_LIMIT}"
  if [ "$limit" -eq 0 ]; then
    limit=9999
  fi

  local -a flags=("--json" "nameWithOwner,sshUrl,url,isArchived,isFork,name" "--limit" "$limit")

  if [ "$CLONE_ORG_ARCHIVED" = "true" ]; then
    flags+=("--archived")
  elif [ "$CLONE_ORG_ARCHIVED" = "false" ]; then
    flags+=("--no-archived")
  fi

  if [ "$CLONE_ORG_FORK" = "true" ]; then
    flags+=("--fork")
  elif [ "$CLONE_ORG_FORK" = "false" ]; then
    flags+=("--source")
  fi

  if [ -n "$CLONE_ORG_VISIBILITY" ]; then
    flags+=("--visibility" "$CLONE_ORG_VISIBILITY")
  fi

  if [ -n "$CLONE_ORG_LANGUAGE" ]; then
    flags+=("--language" "$CLONE_ORG_LANGUAGE")
  fi

  if [ -n "$CLONE_ORG_TOPIC" ]; then
    flags+=("--topic" "$CLONE_ORG_TOPIC")
  fi

  gh repo list "$CLONE_ORG_TARGET" "${flags[@]}" 2>/dev/null || {
    die "Failed to list repos for '${CLONE_ORG_TARGET}'. Check the name and your permissions."
  }
}

cmd_clone_org_main() {
  cmd_clone_org_parse_args "$@"
  preflight_check

  local target_label="Org"
  [ "$CLONE_ORG_TARGET_TYPE" = "user" ] && target_label="User"

  echo -e "${BOLD}${CYAN}Clone Repos${NC} ${DIM}v${VERSION}${NC}"
  echo -e "${DIM}─────────────────────────────────────────────${NC}"
  echo -e "  ${target_label}:  ${BOLD}${CLONE_ORG_TARGET}${NC}"
  echo -e "  Dir:  ${BOLD}$(cd "$CLONE_ORG_DIR" 2>/dev/null && pwd || echo "$CLONE_ORG_DIR")${NC}"
  local proto="HTTPS"
  $CLONE_ORG_SSH && proto="SSH"
  echo -e "  Proto: ${BOLD}${proto}${NC}"
  $CLONE_ORG_PULL && echo -e "  Pull:  ${BOLD}yes${NC} (update existing repos)"
  if $CLONE_ORG_DRY_RUN; then
    echo -e "  Mode:  ${YELLOW}DRY RUN${NC} (no changes)"
  fi

  # Show active filters
  local -a filters=()
  [ "$CLONE_ORG_ARCHIVED" = "true" ]  && filters+=("archived")
  [ "$CLONE_ORG_ARCHIVED" = "false" ] && filters+=("not-archived")
  [ "$CLONE_ORG_FORK" = "true" ]      && filters+=("forks only")
  [ "$CLONE_ORG_FORK" = "false" ]     && filters+=("source only")
  [ -n "$CLONE_ORG_VISIBILITY" ]      && filters+=("${CLONE_ORG_VISIBILITY}")
  [ -n "$CLONE_ORG_LANGUAGE" ]        && filters+=("lang:${CLONE_ORG_LANGUAGE}")
  [ -n "$CLONE_ORG_TOPIC" ]           && filters+=("topic:${CLONE_ORG_TOPIC}")
  if [ ${#filters[@]} -gt 0 ]; then
    local filters_str
    filters_str=$(IFS=', '; echo "${filters[*]}")
    echo -e "  Filters: ${DIM}${filters_str}${NC}"
  fi
  echo ""

  # ── Fetch repo list ─────────────────────────────────────────────────────
  echo -e "${DIM}Fetching repository list...${NC}"
  local repos_json
  repos_json=$(cmd_clone_org_list_repos)

  local total
  total=$(echo "$repos_json" | jq 'length')

  if [ "$total" -eq 0 ]; then
    echo -e "${GREEN}No repositories found matching your filters.${NC}"
    exit 0
  fi

  echo -e "${YELLOW}Found ${total} repositories${NC}"
  echo ""

  # ── Display list ────────────────────────────────────────────────────────
  echo -e "${BOLD}Repos:${NC}"
  echo "$repos_json" | jq -r '.[] | [.nameWithOwner, (.isArchived | tostring), (.isFork | tostring)] | @tsv' | \
    while IFS=$'\t' read -r nwo archived is_fork; do
      local tags=""
      [ "$archived" = "true" ] && tags+=" ${DIM}(archived)${NC}"
      [ "$is_fork" = "true" ]  && tags+=" ${DIM}(fork)${NC}"
      echo -e "  ${DIM}•${NC} ${nwo}${tags}"
    done
  echo ""

  # ── Dry-run stop ────────────────────────────────────────────────────────
  if $CLONE_ORG_DRY_RUN; then
    echo -e "${YELLOW}DRY RUN — no repos were cloned.${NC}"
    exit 0
  fi

  # ── Confirm ─────────────────────────────────────────────────────────────
  local action="Clone"
  $CLONE_ORG_PULL && action="Clone/pull"
  if ! confirm "${action} ${total} repos into ${CLONE_ORG_DIR}?"; then
    echo "Cancelled."
    exit 0
  fi

  # ── Create target directory ─────────────────────────────────────────────
  mkdir -p "$CLONE_ORG_DIR"

  # ── Clone loop ──────────────────────────────────────────────────────────
  repo_list=$(mktemp)
  trap 'rm -f "${repo_list:-}"' EXIT

  echo "$repos_json" | jq -r '.[] | [.nameWithOwner, .sshUrl, .name] | @tsv' > "$repo_list"

  local cloned=0 pulled=0 skip=0 failed=0 idx=0
  while IFS=$'\t' read -r nwo ssh_url repo_name; do
    idx=$((idx + 1))
    local target_dir="${CLONE_ORG_DIR}/${repo_name}"
    local prefix="${DIM}[${idx}/${total}]${NC}"

    if [ -d "$target_dir" ]; then
      if $CLONE_ORG_PULL; then
        if git -C "$target_dir" pull --ff-only --quiet 2>/dev/null; then
          pulled=$((pulled + 1))
          echo -e "  ${prefix} ${CYAN}PULLED${NC}  ${nwo}"
        else
          failed=$((failed + 1))
          echo -e "  ${prefix} ${RED}FAILED${NC}  ${nwo} (pull)"
        fi
      else
        skip=$((skip + 1))
        $VERBOSE && echo -e "  ${prefix} ${DIM}SKIP${NC}    ${nwo} (already exists)"
      fi
      continue
    fi

    if $CLONE_ORG_SSH; then
      if git clone --quiet "$ssh_url" "$target_dir" 2>/dev/null; then
        cloned=$((cloned + 1))
        echo -e "  ${prefix} ${GREEN}CLONED${NC}  ${nwo}"
      else
        failed=$((failed + 1))
        echo -e "  ${prefix} ${RED}FAILED${NC}  ${nwo}"
      fi
    else
      if gh repo clone "$nwo" "$target_dir" -- --quiet 2>/dev/null; then
        cloned=$((cloned + 1))
        echo -e "  ${prefix} ${GREEN}CLONED${NC}  ${nwo}"
      else
        failed=$((failed + 1))
        echo -e "  ${prefix} ${RED}FAILED${NC}  ${nwo}"
      fi
    fi
  done < "$repo_list"

  echo ""
  local summary="${GREEN}Done!${NC} Cloned: ${BOLD}${cloned}${NC}"
  if $CLONE_ORG_PULL; then
    summary+=", Pulled: ${BOLD}${pulled}${NC}"
  fi
  summary+=", Skipped: ${BOLD}${skip}${NC}, Failed: ${BOLD}${failed}${NC}"
  echo -e "$summary"
}

# =============================================================================
# COMMAND: cleanup-forks
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
CLEANUP_FORKS_TARGET=""
CLEANUP_FORKS_TARGET_TYPE=""
CLEANUP_FORKS_OLDER_THAN=30
CLEANUP_FORKS_LIMIT=1000
CLEANUP_FORKS_MAX_BRANCHES=100
CLEANUP_FORKS_BATCH=10
CLEANUP_FORKS_IGNORE_PRS=false
CLEANUP_FORKS_IGNORE_POPULARITY=false
CLEANUP_FORKS_DEFAULT_BRANCH_ONLY=false
CLEANUP_FORKS_INCLUDE_ARCHIVED=false
CLEANUP_FORKS_INCLUDE_ORPHANS=false
CLEANUP_FORKS_REPORT=false
CLEANUP_FORKS_FORMAT="table"
CLEANUP_FORKS_OUT="cleanup-forks.txt"
CLEANUP_FORKS_SAVE_LIST=false
CLEANUP_FORKS_FROM=""
CLEANUP_FORKS_NO_VERIFY=false

cmd_cleanup_forks_usage() {
  cat <<EOF
${BOLD}github-helpers cleanup-forks${NC} ${DIM}v${VERSION}${NC} — Audit forks, delete only the inactive ones
                                        ${DIM}(alias: github-helpers forks)${NC}

${BOLD}USAGE${NC}
  github-helpers cleanup-forks [options]
  github-helpers cleanup-forks --report -v
  github-helpers cleanup-forks --from cleanup-forks.txt

${BOLD}TARGET${NC}
  --user NAME             Target user (default: authenticated user)
  --org NAME              Target organization
  --limit N               Max forks to examine (default: ${CLEANUP_FORKS_LIMIT})

${BOLD}PROTECTION${NC} (all ON by default — a fork is KEPT if any signal fires)
  --older-than N          Only consider forks untouched for N days (default: ${CLEANUP_FORKS_OLDER_THAN})
  --ignore-open-prs       Do NOT protect forks that have an open pull request
  --ignore-popularity     Do NOT protect forks with stars / watchers / forks
  --default-branch-only   Only inspect the default branch (ignore other branches)
  --include-archived      Also consider archived forks
  --include-orphans       Also consider forks whose upstream is gone or private
                          ${DIM}(divergence CANNOT be verified — extra confirmation)${NC}
  --max-branches N        Protect, without verifying, above N branches (max 100)

${BOLD}I/O${NC}
  --report                Audit only — classify every fork, never delete
  --format FORMAT         Report format: table, json, csv (default: table)
  --out FILE              Save deletion candidates to FILE
                          (default: ${CLEANUP_FORKS_OUT}; implies --save-list)
  --save-list             Save the candidate list even outside --dry-run
  --from FILE             Skip scanning — delete the repos listed in FILE
  --no-verify             With --from, skip re-checking protections ${DIM}(dangerous)${NC}

${BOLD}FLAGS${NC}
  --dry-run               Preview only — saves the candidate list, deletes nothing
  -y, --yes               Skip confirmation prompt
  -v, --verbose           Show protected forks and per-branch detail
  -h, --help              Show this help

${BOLD}WORKFLOW${NC}
  1. Audit:    github-helpers cleanup-forks --report -v
  2. Preview:  github-helpers cleanup-forks --dry-run
  3. Edit:     vim ${CLEANUP_FORKS_OUT}
  4. Execute:  github-helpers cleanup-forks --from ${CLEANUP_FORKS_OUT}

${BOLD}EXAMPLES${NC}
  github-helpers forks --report
  github-helpers cleanup-forks --older-than 180 --dry-run
  github-helpers cleanup-forks --org my-company --older-than 365 --dry-run
  github-helpers cleanup-forks --default-branch-only --ignore-popularity -y

${BOLD}NOTE${NC}
  Deleting a fork permanently closes any open pull request opened from it.
  Deletion requires the 'delete_repo' token scope:
    gh auth refresh -h github.com -s delete_repo
EOF
  exit 0
}

cmd_cleanup_forks_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --user)                     need_arg "--user" "${2:-}"; CLEANUP_FORKS_TARGET="$2"; CLEANUP_FORKS_TARGET_TYPE="user"; shift 2 ;;
      --org)                      need_arg "--org" "${2:-}"; CLEANUP_FORKS_TARGET="$2"; CLEANUP_FORKS_TARGET_TYPE="org"; shift 2 ;;
      --limit)                    need_arg "--limit" "${2:-}"; CLEANUP_FORKS_LIMIT="$2"; shift 2 ;;
      --older-than)               need_arg "--older-than" "${2:-}"; CLEANUP_FORKS_OLDER_THAN="$2"; shift 2 ;;
      --max-branches)             need_arg "--max-branches" "${2:-}"; CLEANUP_FORKS_MAX_BRANCHES="$2"; shift 2 ;;
      --format)                   need_arg "--format" "${2:-}"; CLEANUP_FORKS_FORMAT="$2"; shift 2 ;;
      --out)                      need_arg "--out" "${2:-}"; CLEANUP_FORKS_OUT="$2"; CLEANUP_FORKS_SAVE_LIST=true; shift 2 ;;
      --from)                     need_arg "--from" "${2:-}"; CLEANUP_FORKS_FROM="$2"; shift 2 ;;
      --ignore-open-prs)          CLEANUP_FORKS_IGNORE_PRS=true; shift ;;
      --ignore-popularity|--ignore-stars) CLEANUP_FORKS_IGNORE_POPULARITY=true; shift ;;
      --default-branch-only)      CLEANUP_FORKS_DEFAULT_BRANCH_ONLY=true; shift ;;
      --include-archived)         CLEANUP_FORKS_INCLUDE_ARCHIVED=true; shift ;;
      --include-orphans)          CLEANUP_FORKS_INCLUDE_ORPHANS=true; shift ;;
      --report)                   CLEANUP_FORKS_REPORT=true; shift ;;
      --save-list)                CLEANUP_FORKS_SAVE_LIST=true; shift ;;
      --no-verify)                CLEANUP_FORKS_NO_VERIFY=true; shift ;;
      --dry-run)                  DRY_RUN=true; shift ;;
      -y|--yes)                   AUTO_YES=true; shift ;;
      -v|--verbose)               VERBOSE=true; shift ;;
      -h|--help)                  cmd_cleanup_forks_usage ;;
      *) die "cleanup-forks: unknown option: $1" ;;
    esac
  done

  case "$CLEANUP_FORKS_FORMAT" in
    table|json|csv) ;;
    *) die "cleanup-forks: invalid --format '${CLEANUP_FORKS_FORMAT}' (use table, json or csv)" ;;
  esac
  [[ "$CLEANUP_FORKS_OLDER_THAN" =~ ^[0-9]+$ ]] || die "cleanup-forks: --older-than must be a whole number of days"
  [[ "$CLEANUP_FORKS_LIMIT" =~ ^[0-9]+$ ]] || die "cleanup-forks: --limit must be a whole number"
  [[ "$CLEANUP_FORKS_MAX_BRANCHES" =~ ^[0-9]+$ ]] || die "cleanup-forks: --max-branches must be a whole number"

  # A single GraphQL page tops out at 100 refs, so anything above that cannot
  # be verified exhaustively. Clamp rather than silently judge partial data.
  if [ "$CLEANUP_FORKS_MAX_BRANCHES" -gt 100 ]; then
    CLEANUP_FORKS_MAX_BRANCHES=100
  fi

  if $CLEANUP_FORKS_REPORT && [ -n "$CLEANUP_FORKS_FROM" ]; then
    die "cleanup-forks: --report and --from are mutually exclusive"
  fi
  if [ -n "$CLEANUP_FORKS_FROM" ] && [ ! -f "$CLEANUP_FORKS_FROM" ]; then
    die "cleanup-forks: file not found: ${CLEANUP_FORKS_FROM}"
  fi
}

# ── Cheap classifier (pure: no network, no side effects) ─────────────────────
# cmd_cleanup_forks_cheap_verdict <nwo> <parent> <archived> <locked> <empty>
#                                 <stars> <forks> <watchers> <pushed> <created> <cutoff>
# echoes "<VERDICT>\t<reason>"; VERDICT is PROTECTED, SKIPPED or PROBE.
#
# INVARIANT: this function can never emit DELETABLE. Anything it cannot read
# becomes SKIPPED, so a missing or malformed value is never a deletion.
cmd_cleanup_forks_cheap_verdict() {
  local nwo="$1" parent="$2" archived="$3" locked="$4" empty="$5" \
        stars="$6" forks="$7" watchers="$8" pushed="$9" created="${10}" cutoff="${11}"

  if [ -z "$nwo" ]; then
    printf 'SKIPPED\tmalformed record\n'; return 0
  fi

  # An unreadable counter means the record is corrupt -> skip, never delete.
  local f
  for f in "$stars" "$forks" "$watchers"; do
    if [[ ! "$f" =~ ^[0-9]+$ ]]; then
      printf 'SKIPPED\tunreadable metadata\n'; return 0
    fi
  done

  if [ "$locked" = "true" ]; then
    printf 'PROTECTED\tlocked (migration in progress)\n'; return 0
  fi

  # Orphan: upstream deleted, turned private, or otherwise inaccessible.
  # Divergence cannot be computed, so this is never deletable by default.
  if [ -z "$parent" ] && ! $CLEANUP_FORKS_INCLUDE_ORPHANS; then
    printf 'PROTECTED\torphan: upstream unavailable (use --include-orphans)\n'; return 0
  fi

  if [ "$archived" = "true" ] && ! $CLEANUP_FORKS_INCLUDE_ARCHIVED; then
    printf 'PROTECTED\tarchived (use --include-archived)\n'; return 0
  fi

  if ! $CLEANUP_FORKS_IGNORE_POPULARITY; then
    if [ "$stars" -gt 0 ];    then printf 'PROTECTED\t%s star(s)\n' "$stars"; return 0; fi
    if [ "$watchers" -gt 0 ]; then printf 'PROTECTED\t%s watcher(s)\n' "$watchers"; return 0; fi
    if [ "$forks" -gt 0 ];    then printf 'PROTECTED\tforked %s time(s) by others\n' "$forks"; return 0; fi
  fi

  # ISO-8601 UTC sorts lexicographically, so [[ > ]] is a valid date compare.
  if [ -n "$cutoff" ]; then
    if [ -z "$pushed" ] && [ -z "$created" ]; then
      printf 'SKIPPED\tno timestamps\n'; return 0
    fi
    if [ -n "$pushed" ] && [[ "$pushed" > "$cutoff" ]]; then
      printf 'PROTECTED\tpushed %s (within --older-than)\n' "${pushed%%T*}"; return 0
    fi
    if [ -n "$created" ] && [[ "$created" > "$cutoff" ]]; then
      printf 'PROTECTED\tcreated %s (within --older-than)\n' "${created%%T*}"; return 0
    fi
  fi

  printf 'PROBE\t\n'
}

# ── Phase 1: fork metadata sweep (shared with sync-forks) ────────────────────
# cmd_forks_fetch_meta <login> <limit> -> 15-column TSV on stdout
#   1 nameWithOwner        6 fork default branch oid   11 forkCount
#   2 parent nameWithOwner 7 isArchived                12 watchers
#   3 parent default ref   8 isLocked                  13 pushedAt
#   4 parent default oid   9 isEmpty                   14 createdAt
#   5 fork default branch 10 stargazerCount            15 diskUsage
# Costs 1 GraphQL point per 100 forks. Works for both users and orgs:
# repositoryOwner resolves either without an inline fragment.
cmd_forks_fetch_meta() {
  local login="$1" limit="${2:-1000}"
  local has_next="true" fetched=0 page=100 rc result gql_error count total
  local -a cursor_arg=("-F" "cursor=null")

  while [ "$has_next" = "true" ]; do
    page=$(( limit - fetched ))
    [ "$page" -gt 100 ] && page=100
    if [ "$page" -le 0 ]; then break; fi

    rc=0
    result=$(gh_api_retry graphql -f query='
      query($login: String!, $cursor: String, $page: Int!) {
        repositoryOwner(login: $login) {
          repositories(first: $page, isFork: true, ownerAffiliations: [OWNER],
                       after: $cursor, orderBy: {field: PUSHED_AT, direction: DESC}) {
            totalCount
            pageInfo { hasNextPage endCursor }
            nodes {
              nameWithOwner
              isArchived
              isLocked
              isEmpty
              diskUsage
              stargazerCount
              forkCount
              watchers { totalCount }
              pushedAt
              createdAt
              defaultBranchRef { name target { ... on Commit { oid } } }
              parent {
                nameWithOwner
                defaultBranchRef { name target { ... on Commit { oid } } }
              }
            }
          }
        }
      }' -f login="$login" -F page="$page" "${cursor_arg[@]}") || rc=$?

    # A partial failure still carries usable data plus an errors[] array, so
    # never `|| die` here: report and keep whatever resolved.
    gql_error=$(printf '%s' "$result" | jq -r '.errors[0].message // empty' 2>/dev/null || true)
    if [ -n "$gql_error" ]; then
      warn "GitHub API: ${gql_error}"
    fi
    if [ "$rc" -ne 0 ] && [ -z "$gql_error" ]; then
      die "GraphQL request failed. Check your network and gh auth."
    fi
    if ! printf '%s' "$result" | jq -e '.data.repositoryOwner' >/dev/null 2>&1; then
      die "cleanup-forks: no such user or organization: ${login}"
    fi

    printf '%s' "$result" | jq -r '
      .data.repositoryOwner.repositories.nodes[]? | [
        .nameWithOwner,
        (.parent.nameWithOwner // ""),
        (.parent.defaultBranchRef.name // ""),
        (.parent.defaultBranchRef.target.oid // ""),
        (.defaultBranchRef.name // ""),
        (.defaultBranchRef.target.oid // ""),
        (.isArchived | tostring),
        (.isLocked | tostring),
        (.isEmpty | tostring),
        (.stargazerCount | tostring),
        (.forkCount | tostring),
        (.watchers.totalCount | tostring),
        (.pushedAt // ""),
        (.createdAt // ""),
        ((.diskUsage // 0) | tostring)
      ] | @tsv'

    count=$(printf '%s' "$result" | jq '.data.repositoryOwner.repositories.nodes | length' 2>/dev/null || echo 0)
    total=$(printf '%s' "$result" | jq '.data.repositoryOwner.repositories.totalCount' 2>/dev/null || echo 0)
    fetched=$((fetched + count))
    [ "$count" -gt 0 ] && echo -e "  ${DIM}Fetched ${fetched}/${total} forks...${NC}" >&2

    has_next=$(printf '%s' "$result" | jq -r '.data.repositoryOwner.repositories.pageInfo.hasNextPage' 2>/dev/null || echo false)
    local end_cursor
    end_cursor=$(printf '%s' "$result" | jq -r '.data.repositoryOwner.repositories.pageInfo.endCursor // empty' 2>/dev/null || true)
    [ -z "$end_cursor" ] && break
    [ "$fetched" -ge "$limit" ] && break
    cursor_arg=("-f" "cursor=${end_cursor}")
  done
}

# ── Phase 2: aliased batch probe ─────────────────────────────────────────────
# Builds one GraphQL document covering N forks. Repo names travel as GraphQL
# variables, never interpolated into the query text.
# Sets CF_QUERY, CF_GQL_ARGS (gh api argv) and CF_BATCH_META (jq --argjson
# payload). These are globals rather than a return value on purpose: a command
# substitution would run this in a subshell and drop every assignment.
CF_QUERY=""
CF_GQL_ARGS=()
CF_BATCH_META=""
cmd_cleanup_forks_build_batch_query() {
  local -a items=("$@")
  local i=0 decls="" body="" meta="" nwo parent parent_ref owner name alias
  CF_GQL_ARGS=()

  for entry in "${items[@]}"; do
    IFS=$'\x1f' read -r nwo parent parent_ref _fork_ref <<< "$entry"
    alias="f${i}"
    owner="${nwo%%/*}"
    name="${nwo#*/}"
    decls="${decls}\$o${i}: String!, \$n${i}: String!, "
    CF_GQL_ARGS+=("-f" "o${i}=${owner}" "-f" "n${i}=${name}")

    local compare_field=""
    if [ -n "$parent" ] && [ -n "$parent_ref" ]; then
      decls="${decls}\$h${i}: String!, "
      CF_GQL_ARGS+=("-f" "h${i}=${parent%%/*}:${parent_ref}")
      compare_field="compare(headRef: \$h${i}) { aheadBy behindBy status }"
    fi

    body="${body}
  ${alias}: repository(owner: \$o${i}, name: \$n${i}) {
    nameWithOwner
    refs(refPrefix: \"refs/heads/\", first: 100) {
      totalCount
      nodes {
        name
        ${compare_field}
        associatedPullRequests(states: [OPEN], first: 10) {
          totalCount
          nodes { number isDraft baseRepository { nameWithOwner } }
        }
      }
    }
  }"
    meta="${meta}$(jq -nc --arg k "$alias" --arg nwo "$nwo" --arg parent "$parent" \
      --arg def "$_fork_ref" '{key:$k, value:{nwo:$nwo, parent:$parent, default:$def}}')"$'\n'
    i=$((i + 1))
  done

  decls="${decls%, }"
  CF_BATCH_META=$(printf '%s' "$meta" | jq -sc 'from_entries')
  CF_QUERY=$(printf 'query(%s) {%s\n}\n' "$decls" "$body")
}

# cmd_cleanup_forks_probe_batch <entry...> -> "<VERDICT>\t<nwo>\t<reason>" lines
cmd_cleanup_forks_probe_batch() {
  local rc=0 result
  cmd_cleanup_forks_build_batch_query "$@"

  result=$(gh_api_retry graphql -f query="$CF_QUERY" "${CF_GQL_ARGS[@]}") || rc=$?
  if [ -z "$result" ]; then
    # Total failure: every fork in the batch is unverified, so none is deletable.
    printf '%s' "$CF_BATCH_META" | jq -r '.[] | ["SKIPPED", .nwo, "API error: batch request failed"] | @tsv'
    return 0
  fi

  printf '%s' "$result" | jq -r \
    --argjson meta "$CF_BATCH_META" \
    --argjson opt "$(jq -nc \
        --argjson maxBranches "$CLEANUP_FORKS_MAX_BRANCHES" \
        --argjson ignorePrs "$CLEANUP_FORKS_IGNORE_PRS" \
        --argjson defaultOnly "$CLEANUP_FORKS_DEFAULT_BRANCH_ONLY" \
        '{maxBranches:$maxBranches, ignorePrs:$ignorePrs, defaultOnly:$defaultOnly}')" '
    # NOTE: compare() is evaluated FROM the fork ref, so the names are inverted:
    #   compare.behindBy == commits the FORK branch has that the parent lacks  <- "ahead"
    #   compare.aheadBy  == commits the parent has that the fork branch lacks  <- "behind"
    # Verified: fork branch with 1 own commit -> GraphQL behindBy=1, and
    # REST /compare/main...user:branch -> ahead_by=1.
    def classify($m; $o):
      if . == null then ["SKIPPED", "API error: repository unreadable"]
      elif ((.refs.totalCount // 0) > $o.maxBranches) then
        ["PROTECTED", "\(.refs.totalCount) branches (> --max-branches \($o.maxBranches)), not verified"]
      else
        (.refs.nodes // []) as $refs
        | [ $refs[] | .associatedPullRequests.nodes[]? ] as $prs
        | if (($o.ignorePrs | not) and (($prs | length) > 0)) then
            ($prs | map(select(.baseRepository.nameWithOwner != $m.nwo))) as $up
            | if ($up | length) > 0 then
                ["PROTECTED", "open PR " + ($up | map("#\(.number)->\(.baseRepository.nameWithOwner)") | join(", "))]
              else
                ["PROTECTED", "\($prs | length) open PR(s) (internal)"]
              end
          else
            (if $o.defaultOnly then [ $refs[] | select(.name == $m.default) ] else $refs end) as $c
            | if ($c | length) == 0 then ["SKIPPED", "no branches resolved"]
              elif ($m.parent == "") then
                (if ($c | length) == 1
                 then ["DELETABLE", "orphan; 1 branch, no open PRs - divergence UNVERIFIED"]
                 else ["PROTECTED", "orphan with \($c | length) branches - divergence UNVERIFIED"]
                 end)
              elif (([ $c[] | select(.compare == null) ] | length) > 0) then
                ["SKIPPED", "compare failed on: " + ([ $c[] | select(.compare == null) | .name ] | join(", "))]
              else
                ([ $c[] | {n: .name, a: .compare.behindBy} ] | max_by(.a)) as $top
                | if (($top.a // 0) > 0)
                  then ["PROTECTED", "\($top.a) commit(s) ahead on \($top.n)"]
                  else ["DELETABLE", "0 ahead on \($c | length) branch(es)"]
                  end
              end
          end
      end;

    . as $resp
    | ([ ($resp.errors // [])[] | select(.path != null) | .path[0] ] | unique) as $failed
    | ($resp.data // {}) as $data
    | [ $meta | keys[] ]
    | map(
        . as $k
        | $meta[$k] as $m
        | (if ($failed | index($k)) then ["SKIPPED", "API error on this repository"]
           else ($data[$k] | classify($m; $opt)) end) as $v
        | [$v[0], $m.nwo, $v[1]] | @tsv
      ) | .[]'
}

# ── Rendering ────────────────────────────────────────────────────────────────
# Escape sequences are allowed in the printf FORMAT string but never in an
# argument to a padded conversion, which is what breaks column alignment.
cmd_cleanup_forks_row() {
  printf "  %s%-9s%s %-45s %s%s%s\n" "$1" "$2" "$NC" "$3" "$DIM" "$4" "$NC"
}

cmd_cleanup_forks_render() {
  local class_file="$1" total="$2"

  if [ "$CLEANUP_FORKS_FORMAT" != "table" ]; then
    local rows
    rows=$(jq -R -s 'split("\n") | map(select(length > 0) | split("\t")
             | {verdict: .[0], repo: .[1], reason: .[2]})' < "$class_file")
    render_rows "$CLEANUP_FORKS_FORMAT" "$rows"
    return 0
  fi

  echo ""
  printf "  ${BOLD}%-9s %-45s %s${NC}\n" "STATUS" "REPOSITORY" "REASON"
  printf "  ${DIM}%-9s %-45s %s${NC}\n" "─────────" "─────────────────────────────────────────────" "──────────────────────────"

  local verdict nwo reason
  # DELETE first (next to the prompt), then SKIP (a warning the user must see),
  # then PROTECT (only under -v or --report; the counts suffice otherwise).
  while IFS=$'\t' read -r verdict nwo reason; do
    [ "$verdict" = "DELETABLE" ] && cmd_cleanup_forks_row "$YELLOW" "DELETE" "$nwo" "$reason"
  done < "$class_file"
  while IFS=$'\t' read -r verdict nwo reason; do
    [ "$verdict" = "SKIPPED" ] && cmd_cleanup_forks_row "$RED" "SKIP" "$nwo" "$reason"
  done < "$class_file"
  if $VERBOSE || $CLEANUP_FORKS_REPORT; then
    while IFS=$'\t' read -r verdict nwo reason; do
      [ "$verdict" = "PROTECTED" ] && cmd_cleanup_forks_row "$GREEN" "PROTECT" "$nwo" "$reason"
    done < "$class_file"
  fi

  local n_prot n_del n_skip n_orph
  n_prot=$(awk -F'\t' '$1=="PROTECTED"' "$class_file" | wc -l | tr -d ' ')
  n_del=$(awk -F'\t' '$1=="DELETABLE"' "$class_file" | wc -l | tr -d ' ')
  n_skip=$(awk -F'\t' '$1=="SKIPPED"' "$class_file" | wc -l | tr -d ' ')
  n_orph=$(grep -c 'orphan' "$class_file" || true)
  echo ""
  echo -e "  ${BOLD}${total}${NC} forks   •   ${GREEN}PROTECTED ${n_prot}${NC}   •   ${YELLOW}DELETABLE ${n_del}${NC}   •   ${RED}SKIPPED ${n_skip}${NC}   •   ${DIM}ORPHANS ${n_orph}${NC}"
}

# ── Deletion ─────────────────────────────────────────────────────────────────
cmd_cleanup_forks_delete() {
  local list_file="$1"
  local deleted=0 fail=0 repo

  while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    if gh repo delete "$repo" --yes 2>/dev/null; then
      deleted=$((deleted + 1))
      echo -e "  ${GREEN}DELETED${NC}  $repo"
    else
      fail=$((fail + 1))
      echo -e "  ${RED}FAILED${NC}   $repo"
    fi
  done < "$list_file"

  echo ""
  echo -e "${GREEN}Done!${NC} Deleted: ${BOLD}${deleted}${NC}, Failed: ${BOLD}${fail}${NC}"
}

cmd_cleanup_forks_main() {
  cmd_cleanup_forks_parse_args "$@"
  preflight_check
  skip_init

  if ! $CLEANUP_FORKS_REPORT && ! require_scope "delete_repo"; then
    warn "your token has no 'delete_repo' scope — deletions will fail with 403."
    warn "run: gh auth refresh -h github.com -s delete_repo"
  fi

  if [ -z "$CLEANUP_FORKS_TARGET" ]; then
    CLEANUP_FORKS_TARGET=$(get_username)
    CLEANUP_FORKS_TARGET_TYPE="user"
  fi

  # Chrome goes to stderr whenever stdout carries a machine-readable payload.
  local out=1
  [ "$CLEANUP_FORKS_FORMAT" != "table" ] && out=2

  {
    header "Fork Cleanup"
    echo -e "  Target:      ${BOLD}${CLEANUP_FORKS_TARGET}${NC}"
  } >&$out

  local cutoff=""
  if [ "$CLEANUP_FORKS_OLDER_THAN" -gt 0 ]; then
    cutoff=$(cutoff_date "$CLEANUP_FORKS_OLDER_THAN" days)
    echo -e "  Older than:  ${BOLD}${CLEANUP_FORKS_OLDER_THAN}${NC} days (before ${cutoff%%T*})" >&$out
  fi

  local -a protections=()
  $CLEANUP_FORKS_IGNORE_PRS         || protections+=("open PRs")
  $CLEANUP_FORKS_DEFAULT_BRANCH_ONLY && protections+=("default branch only") || protections+=("all branches")
  $CLEANUP_FORKS_IGNORE_POPULARITY  || protections+=("popularity")
  $CLEANUP_FORKS_INCLUDE_ARCHIVED   || protections+=("archived")
  $CLEANUP_FORKS_INCLUDE_ORPHANS    || protections+=("orphans")
  local prot_str
  prot_str=$(printf '%s, ' "${protections[@]}")
  {
    echo -e "  Protections: ${BOLD}${prot_str%, }${NC}"
    $DRY_RUN && echo -e "  Mode:        ${YELLOW}DRY RUN${NC}"
    $CLEANUP_FORKS_REPORT && echo -e "  Mode:        ${CYAN}REPORT (read-only)${NC}"
    echo ""
  } >&$out

  # ── --from --no-verify: straight to deletion, no scan ──────────────────────
  if [ -n "$CLEANUP_FORKS_FROM" ] && $CLEANUP_FORKS_NO_VERIFY; then
    warn "--no-verify: protections are NOT re-checked for the listed repos"
    local n_from
    n_from=$(count_lines "$CLEANUP_FORKS_FROM")
    [ "$n_from" -eq 0 ] && { echo -e "${GREEN}Nothing to delete.${NC}"; exit 0; }
    if $DRY_RUN; then
      echo -e "${YELLOW}DRY RUN — no forks were deleted.${NC}"; exit 0
    fi
    if ! confirm "Delete ${n_from} fork(s) WITHOUT verification? This is irreversible."; then
      echo "Cancelled."; exit 0
    fi
    cmd_cleanup_forks_delete "$CLEANUP_FORKS_FROM"
    exit 0
  fi

  # ── Phase 1 ────────────────────────────────────────────────────────────────
  local meta_file class_file probe_file
  meta_file=$(tmp_new); class_file=$(tmp_new); probe_file=$(tmp_new)

  echo -e "${DIM}Fetching forks...${NC}" >&$out
  cmd_forks_fetch_meta "$CLEANUP_FORKS_TARGET" "$CLEANUP_FORKS_LIMIT" > "$meta_file"

  # --from restricts the scan to the listed repos, but still re-verifies them:
  # a list from last week may name a fork that has since gained a pull request.
  if [ -n "$CLEANUP_FORKS_FROM" ]; then
    local want_file kept_file
    want_file=$(tmp_new); kept_file=$(tmp_new)
    sed 's/#.*//' "$CLEANUP_FORKS_FROM" | awk 'NF {print $1}' | sort -u > "$want_file"
    awk -F'\t' 'NR==FNR {want[$1]; next} $1 in want' "$want_file" "$meta_file" > "$kept_file"
    local missing
    missing=$(awk -F'\t' 'NR==FNR {have[$1]; next} !($1 in have)' "$kept_file" "$want_file" || true)
    if [ -n "$missing" ]; then
      while IFS= read -r m; do
        [ -n "$m" ] && skip_note "$m" "not a fork of ${CLEANUP_FORKS_TARGET} (or already gone)"
      done <<< "$missing"
    fi
    mv "$kept_file" "$meta_file"
  fi

  local total
  total=$(count_lines "$meta_file")
  if [ "$total" -eq 0 ]; then
    echo -e "${GREEN}No forks found.${NC}" >&$out
    print_skips
    exit 0
  fi

  # ── Cheap pass (no network) ────────────────────────────────────────────────
  # `done < file`, never a pipe: a subshell would lose everything written here.
  local nwo parent parent_ref parent_oid fork_ref fork_oid archived locked empty \
        stars forks watchers pushed created disk verdict reason
  while IFS=$'\t' read -r nwo parent parent_ref parent_oid fork_ref fork_oid \
                          archived locked empty stars forks watchers pushed created disk; do
    IFS=$'\t' read -r verdict reason < <(cmd_cleanup_forks_cheap_verdict \
      "$nwo" "$parent" "$archived" "$locked" "$empty" \
      "$stars" "$forks" "$watchers" "$pushed" "$created" "$cutoff")
    if [ "$verdict" = "PROBE" ]; then
      printf '%s\x1f%s\x1f%s\x1f%s\n' "$nwo" "$parent" "$parent_ref" "$fork_ref" >> "$probe_file"
    else
      printf '%s\t%s\t%s\n' "$verdict" "$nwo" "$reason" >> "$class_file"
    fi
  done < "$meta_file"

  # ── Phase 2 (batched GraphQL) ──────────────────────────────────────────────
  local n_probe
  n_probe=$(count_lines "$probe_file")
  if [ "$n_probe" -gt 0 ]; then
    local batches=$(( (n_probe + CLEANUP_FORKS_BATCH - 1) / CLEANUP_FORKS_BATCH ))
    echo -e "  ${DIM}Probing ${n_probe} candidate forks (${batches} batch(es))...${NC}" >&$out
    local -a batch=()
    local entry
    while IFS= read -r entry; do
      [ -z "$entry" ] && continue
      batch+=("$entry")
      if [ "${#batch[@]}" -ge "$CLEANUP_FORKS_BATCH" ]; then
        cmd_cleanup_forks_probe_batch "${batch[@]}" >> "$class_file"
        batch=()
      fi
    done < "$probe_file"
    if [ "${#batch[@]}" -gt 0 ]; then
      cmd_cleanup_forks_probe_batch "${batch[@]}" >> "$class_file"
    fi
  fi

  # Every skip is a fork we could NOT verify. Say so out loud.
  while IFS=$'\t' read -r verdict nwo reason; do
    [ "$verdict" = "SKIPPED" ] && warn "${nwo}: ${reason} — skipped, will NOT be deleted"
  done < "$class_file"

  cmd_cleanup_forks_render "$class_file" "$total"

  if $CLEANUP_FORKS_REPORT; then
    print_skips
    exit 0
  fi

  # ── Candidate list ─────────────────────────────────────────────────────────
  local cand_file
  if $DRY_RUN || $CLEANUP_FORKS_SAVE_LIST; then
    cand_file="$CLEANUP_FORKS_OUT"
  else
    cand_file=$(tmp_new)
  fi
  awk -F'\t' '$1=="DELETABLE" {print $2}' "$class_file" | sort -u > "$cand_file"

  local n_cand
  n_cand=$(count_lines "$cand_file")
  if [ "$n_cand" -eq 0 ]; then
    echo ""
    echo -e "${GREEN}Nothing to clean up — every fork is protected.${NC}"
    print_skips
    exit 0
  fi

  if $DRY_RUN; then
    echo ""
    echo -e "${YELLOW}DRY RUN — no forks were deleted.${NC}"
    echo -e "List saved to: ${BOLD}${cand_file}${NC}"
    echo -e "Review it, then run:"
    echo -e "  ${BOLD}github-helpers cleanup-forks --from ${cand_file}${NC}"
    print_skips
    exit 0
  fi

  # ── Orphan gate: unverifiable divergence gets its own confirmation ─────────
  local orphan_count orphan_file
  orphan_file=$(tmp_new)
  awk -F'\t' '$1=="DELETABLE" && $3 ~ /orphan/ {print $2}' "$class_file" | sort -u > "$orphan_file"
  orphan_count=$(count_lines "$orphan_file")
  if [ "$orphan_count" -gt 0 ]; then
    echo ""
    warn "${orphan_count} candidate(s) are orphaned forks — their commit divergence could NOT be verified."
    if ! confirm "Include ${orphan_count} UNVERIFIED orphan fork(s) in the deletion?"; then
      local trimmed
      trimmed=$(tmp_new)
      grep -vxF -f "$orphan_file" "$cand_file" > "$trimmed" || true
      mv "$trimmed" "$cand_file"
      n_cand=$(count_lines "$cand_file")
      echo -e "  ${DIM}Orphans excluded — ${n_cand} candidate(s) left.${NC}"
      [ "$n_cand" -eq 0 ] && { echo -e "${GREEN}Nothing left to delete.${NC}"; print_skips; exit 0; }
    fi
  fi

  echo ""
  if ! confirm "Delete ${n_cand} fork(s)? This is irreversible and closes any open PR from them."; then
    echo "Cancelled."
    exit 0
  fi

  cmd_cleanup_forks_delete "$cand_file"
  print_skips
}

# =============================================================================
# COMMAND: archive-repos
# =============================================================================

cmd_archive_repos_usage() {
  cat <<EOF
${BOLD}github-helpers archive-repos${NC} ${DIM}v${VERSION}${NC} — Archive inactive repos in batch

${BOLD}USAGE${NC}
  github-helpers archive-repos [options]

${BOLD}OPTIONS${NC}
  --user NAME             Target user (default: authenticated user)
  --org NAME              Target organization
  --inactive-months N     Repos with no push in N months (default: 12)
  --language LANG         Filter by primary language
  --topic TOPIC           Filter by topic
  --dry-run               List repos without archiving
  -y, --yes               Skip confirmation prompt
  -v, --verbose           Show detailed output
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  github-helpers archive-repos --inactive-months 24 --dry-run
  github-helpers archive-repos --org my-company --inactive-months 12 -y
EOF
  exit 0
}

cmd_archive_repos_main() {
  local target="" target_type="" inactive_months=12 language="" topic="" dry_run=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --user)             need_arg "--user" "${2:-}"; target="$2"; target_type="user"; shift 2 ;;
      --org)              need_arg "--org" "${2:-}"; target="$2"; target_type="org"; shift 2 ;;
      --inactive-months)  need_arg "--inactive-months" "${2:-}"; inactive_months="$2"; shift 2 ;;
      --language)         need_arg "--language" "${2:-}"; language="$2"; shift 2 ;;
      --topic)            need_arg "--topic" "${2:-}"; topic="$2"; shift 2 ;;
      --dry-run)          dry_run=true; shift ;;
      -y|--yes)           AUTO_YES=true; shift ;;
      -v|--verbose)       VERBOSE=true; shift ;;
      -h|--help)          cmd_archive_repos_usage ;;
      *) die "archive-repos: unknown option: $1" ;;
    esac
  done

  preflight_check

  if [ -z "$target" ]; then
    target=$(get_username)
    target_type="user"
  fi

  local cutoff
  cutoff=$(cutoff_date "$inactive_months" months)

  echo -e "${BOLD}${CYAN}Archive Repos${NC} ${DIM}v${VERSION}${NC}"
  echo -e "${DIM}─────────────────────────────────────────────${NC}"
  echo -e "  Target:   ${BOLD}${target}${NC}"
  echo -e "  Inactive: ${BOLD}>${inactive_months} months${NC} (before ${cutoff%%T*})"
  if $dry_run; then
    echo -e "  Mode:     ${YELLOW}DRY RUN${NC}"
  fi
  echo ""

  echo -e "${DIM}Fetching repos...${NC}"
  local -a flags=("--json" "nameWithOwner,pushedAt,isArchived" "--no-archived" "--source" "--limit" "9999")
  [ -n "$language" ] && flags+=("--language" "$language")
  [ -n "$topic" ]    && flags+=("--topic" "$topic")

  local repos_json
  repos_json=$(gh repo list "$target" "${flags[@]}" 2>/dev/null) || die "Failed to list repos"

  # Filter by inactivity
  local inactive_json
  inactive_json=$(echo "$repos_json" | jq --arg cutoff "$cutoff" '[.[] | select(.pushedAt < $cutoff)]')

  local total
  total=$(echo "$inactive_json" | jq 'length')

  if [ "$total" -eq 0 ]; then
    echo -e "${GREEN}No inactive repos found. Everything is active!${NC}"
    exit 0
  fi

  echo -e "${YELLOW}Found ${total} inactive repos${NC}"
  echo ""

  echo -e "${BOLD}Repos to archive:${NC}"
  echo "$inactive_json" | jq -r '.[] | [.nameWithOwner, .pushedAt] | @tsv' | \
    while IFS=$'\t' read -r nwo pushed; do
      echo -e "  ${DIM}•${NC} ${nwo} ${DIM}(last push: ${pushed%%T*})${NC}"
    done
  echo ""

  if $dry_run; then
    echo -e "${YELLOW}DRY RUN — no repos were archived.${NC}"
    exit 0
  fi

  if ! confirm "Archive ${total} repos?"; then
    echo "Cancelled."
    exit 0
  fi

  local archived=0 fail=0
  while IFS= read -r nwo; do
    if gh repo archive "$nwo" --yes 2>/dev/null; then
      archived=$((archived + 1))
      echo -e "  ${GREEN}ARCHIVED${NC}  $nwo"
    else
      fail=$((fail + 1))
      echo -e "  ${RED}FAILED${NC}    $nwo"
    fi
  done < <(echo "$inactive_json" | jq -r '.[].nameWithOwner')

  echo ""
  echo -e "${GREEN}Done!${NC} Archived: ${BOLD}${archived}${NC}, Failed: ${BOLD}${fail}${NC}"
}

# =============================================================================
# COMMAND: repo-audit
# =============================================================================

cmd_repo_audit_usage() {
  cat <<EOF
${BOLD}github-helpers repo-audit${NC} ${DIM}v${VERSION}${NC} — Scan repos for common issues

${BOLD}USAGE${NC}
  github-helpers repo-audit [options]

${BOLD}OPTIONS${NC}
  --user NAME             Target user (default: authenticated user)
  --org NAME              Target organization
  --language LANG         Filter by primary language
  --topic TOPIC           Filter by topic
  --limit N               Max repos to scan (default: all)
  -v, --verbose           Show passing checks too
  -h, --help              Show this help

${BOLD}CHECKS${NC}
  - Missing description
  - Missing LICENSE file
  - Missing README file
  - No default branch protection
  - No topics assigned

${BOLD}EXAMPLES${NC}
  github-helpers repo-audit
  github-helpers repo-audit --org my-company
  github-helpers repo-audit --language Shell -v
EOF
  exit 0
}

cmd_repo_audit_main() {
  local target="" target_type="" language="" topic="" limit=9999

  while [ $# -gt 0 ]; do
    case "$1" in
      --user)      need_arg "--user" "${2:-}"; target="$2"; target_type="user"; shift 2 ;;
      --org)       need_arg "--org" "${2:-}"; target="$2"; target_type="org"; shift 2 ;;
      --language)  need_arg "--language" "${2:-}"; language="$2"; shift 2 ;;
      --topic)     need_arg "--topic" "${2:-}"; topic="$2"; shift 2 ;;
      --limit)     need_arg "--limit" "${2:-}"; limit="$2"; shift 2 ;;
      -v|--verbose) VERBOSE=true; shift ;;
      -h|--help)   cmd_repo_audit_usage ;;
      *) die "repo-audit: unknown option: $1" ;;
    esac
  done

  preflight_check

  if [ -z "$target" ]; then
    target=$(get_username)
    target_type="user"
  fi

  echo -e "${BOLD}${CYAN}Repo Audit${NC} ${DIM}v${VERSION}${NC}"
  echo -e "${DIM}─────────────────────────────────────────────${NC}"
  echo -e "  Target: ${BOLD}${target}${NC}"
  echo ""

  echo -e "${DIM}Fetching repos...${NC}"
  local -a flags=("--json" "nameWithOwner,description,licenseInfo,hasWikiEnabled,repositoryTopics,defaultBranchRef" "--source" "--no-archived" "--limit" "$limit")
  [ -n "$language" ] && flags+=("--language" "$language")
  [ -n "$topic" ]    && flags+=("--topic" "$topic")

  local repos_json
  repos_json=$(gh repo list "$target" "${flags[@]}" 2>/dev/null) || die "Failed to list repos"

  local total
  total=$(echo "$repos_json" | jq 'length')

  echo -e "Scanning ${BOLD}${total}${NC} repos..."
  echo ""

  local issues_total=0 repos_with_issues=0

  echo "$repos_json" | jq -c '.[]' | while IFS= read -r repo; do
    local nwo desc license topics
    nwo=$(echo "$repo" | jq -r '.nameWithOwner')
    desc=$(echo "$repo" | jq -r '.description // ""')
    license=$(echo "$repo" | jq -r '.licenseInfo.spdxId // ""')
    topics=$(echo "$repo" | jq -r '.repositoryTopics | length')

    local -a warnings=()

    [ -z "$desc" ] && warnings+=("no description")
    [ -z "$license" ] || [ "$license" = "NOASSERTION" ] && warnings+=("no license")
    [ "$topics" -eq 0 ] && warnings+=("no topics")

    # Check README via API
    local has_readme
    has_readme=$(gh api "repos/${nwo}/readme" --jq '.name' 2>/dev/null || echo "")
    [ -z "$has_readme" ] && warnings+=("no README")

    if [ ${#warnings[@]} -gt 0 ]; then
      repos_with_issues=$((repos_with_issues + 1))
      issues_total=$((issues_total + ${#warnings[@]}))
      local warning_str
      warning_str=$(IFS=', '; echo "${warnings[*]}")
      echo -e "  ${YELLOW}!${NC} ${BOLD}${nwo}${NC} — ${warning_str}"
    elif $VERBOSE; then
      echo -e "  ${GREEN}✓${NC} ${nwo}"
    fi
  done

  echo ""
  echo -e "${BOLD}Audit complete.${NC}"
}

# =============================================================================
# COMMAND: stats
# =============================================================================

cmd_stats_usage() {
  cat <<EOF
${BOLD}github-helpers stats${NC} ${DIM}v${VERSION}${NC} — Quick GitHub profile stats

${BOLD}USAGE${NC}
  github-helpers stats [options]

${BOLD}OPTIONS${NC}
  --user NAME             Target user (default: authenticated user)
  --org NAME              Target organization
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  github-helpers stats
  github-helpers stats --org my-company
EOF
  exit 0
}

cmd_stats_main() {
  local target="" target_type=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --user) need_arg "--user" "${2:-}"; target="$2"; target_type="user"; shift 2 ;;
      --org)  need_arg "--org" "${2:-}"; target="$2"; target_type="org"; shift 2 ;;
      -h|--help) cmd_stats_usage ;;
      *) die "stats: unknown option: $1" ;;
    esac
  done

  preflight_check

  if [ -z "$target" ]; then
    target=$(get_username)
    target_type="user"
  fi

  echo -e "${BOLD}${CYAN}GitHub Stats${NC} ${DIM}v${VERSION}${NC}"
  echo -e "${DIM}─────────────────────────────────────────────${NC}"
  echo -e "  Target: ${BOLD}${target}${NC}"
  echo ""

  echo -e "${DIM}Fetching repos...${NC}"
  local repos_json
  repos_json=$(gh repo list "$target" --json nameWithOwner,stargazerCount,forkCount,primaryLanguage,isArchived,isFork,pushedAt --limit 9999 --source 2>/dev/null) || die "Failed to list repos"

  local total stars forks archived languages most_starred least_active
  total=$(echo "$repos_json" | jq 'length')
  stars=$(echo "$repos_json" | jq '[.[].stargazerCount] | add // 0')
  forks=$(echo "$repos_json" | jq '[.[].forkCount] | add // 0')
  archived=$(echo "$repos_json" | jq '[.[] | select(.isArchived)] | length')

  echo ""
  echo -e "  ${BOLD}Repos:${NC}     $total (${archived} archived)"
  echo -e "  ${BOLD}Stars:${NC}     $stars"
  echo -e "  ${BOLD}Forks:${NC}     $forks"
  echo ""

  echo -e "  ${BOLD}Top languages:${NC}"
  echo "$repos_json" | jq -r '[.[] | .primaryLanguage.name // "None"] | group_by(.) | map({lang: .[0], count: length}) | sort_by(-.count) | .[:8][] | "    \(.count)\t\(.lang)"' | \
    while IFS=$'\t' read -r count lang; do
      printf "    ${CYAN}%-4s${NC} %s\n" "$count" "$lang"
    done
  echo ""

  echo -e "  ${BOLD}Most starred:${NC}"
  echo "$repos_json" | jq -r 'sort_by(-.stargazerCount) | .[:5][] | "    \(.stargazerCount)\t\(.nameWithOwner)"' | \
    while IFS=$'\t' read -r count nwo; do
      printf "    ${YELLOW}★ %-4s${NC} %s\n" "$count" "$nwo"
    done
  echo ""

  echo -e "  ${BOLD}Least active (source, non-archived):${NC}"
  echo "$repos_json" | jq -r '[.[] | select(.isArchived | not)] | sort_by(.pushedAt) | .[:5][] | "    \(.pushedAt[:10])\t\(.nameWithOwner)"' | \
    while IFS=$'\t' read -r date nwo; do
      echo -e "    ${DIM}${date}${NC}  ${nwo}"
    done
  echo ""
}

# =============================================================================
# COMMAND: bulk-topic
# =============================================================================

cmd_bulk_topic_usage() {
  cat <<EOF
${BOLD}github-helpers bulk-topic${NC} ${DIM}v${VERSION}${NC} — Add or remove topics in batch

${BOLD}USAGE${NC}
  github-helpers bulk-topic --add TOPIC [options]
  github-helpers bulk-topic --remove TOPIC [options]

${BOLD}ACTION${NC} (one required)
  --add TOPIC             Add topic to matching repos
  --remove TOPIC          Remove topic from matching repos

${BOLD}OPTIONS${NC}
  --user NAME             Target user (default: authenticated user)
  --org NAME              Target organization
  --language LANG         Filter repos by language
  --topic TOPIC           Filter repos by existing topic
  --pattern PATTERN       Filter repos by name pattern (grep regex)
  --dry-run               Preview changes without applying
  -y, --yes               Skip confirmation prompt
  -v, --verbose           Show detailed output
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  github-helpers bulk-topic --add shell --language Shell --dry-run
  github-helpers bulk-topic --remove deprecated --topic deprecated -y
  github-helpers bulk-topic --add cli --pattern "^maxgfr/(git-|package-)" --dry-run
EOF
  exit 0
}

cmd_bulk_topic_main() {
  local action="" topic_value="" target="" target_type="" language="" filter_topic="" pattern="" dry_run=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --add)       need_arg "--add" "${2:-}"; action="add"; topic_value="$2"; shift 2 ;;
      --remove)    need_arg "--remove" "${2:-}"; action="remove"; topic_value="$2"; shift 2 ;;
      --user)      need_arg "--user" "${2:-}"; target="$2"; target_type="user"; shift 2 ;;
      --org)       need_arg "--org" "${2:-}"; target="$2"; target_type="org"; shift 2 ;;
      --language)  need_arg "--language" "${2:-}"; language="$2"; shift 2 ;;
      --topic)     need_arg "--topic" "${2:-}"; filter_topic="$2"; shift 2 ;;
      --pattern)   need_arg "--pattern" "${2:-}"; pattern="$2"; shift 2 ;;
      --dry-run)   dry_run=true; shift ;;
      -y|--yes)    AUTO_YES=true; shift ;;
      -v|--verbose) VERBOSE=true; shift ;;
      -h|--help)   cmd_bulk_topic_usage ;;
      *) die "bulk-topic: unknown option: $1" ;;
    esac
  done

  [ -z "$action" ] && die "bulk-topic: --add or --remove is required"
  [ -z "$topic_value" ] && die "bulk-topic: topic value is required"

  preflight_check

  if [ -z "$target" ]; then
    target=$(get_username)
    target_type="user"
  fi

  echo -e "${BOLD}${CYAN}Bulk Topic${NC} ${DIM}v${VERSION}${NC}"
  echo -e "${DIM}─────────────────────────────────────────────${NC}"
  echo -e "  Action: ${BOLD}${action} '${topic_value}'${NC}"
  echo -e "  Target: ${BOLD}${target}${NC}"
  if $dry_run; then
    echo -e "  Mode:   ${YELLOW}DRY RUN${NC}"
  fi
  echo ""

  local -a flags=("--json" "nameWithOwner,repositoryTopics" "--limit" "9999" "--source" "--no-archived")
  [ -n "$language" ]     && flags+=("--language" "$language")
  [ -n "$filter_topic" ] && flags+=("--topic" "$filter_topic")

  local repos_json
  repos_json=$(gh repo list "$target" "${flags[@]}" 2>/dev/null) || die "Failed to list repos"

  # Apply pattern filter
  if [ -n "$pattern" ]; then
    repos_json=$(echo "$repos_json" | jq --arg p "$pattern" '[.[] | select(.nameWithOwner | test($p))]')
  fi

  local total
  total=$(echo "$repos_json" | jq 'length')

  if [ "$total" -eq 0 ]; then
    echo -e "${GREEN}No repos matched your filters.${NC}"
    exit 0
  fi

  echo -e "Found ${BOLD}${total}${NC} repos"
  echo ""

  # Filter: for --add, skip repos that already have the topic; for --remove, skip repos without it
  local filtered_repos
  if [ "$action" = "add" ]; then
    filtered_repos=$(echo "$repos_json" | jq --arg t "$topic_value" '[.[] | select([.repositoryTopics[].name] | index($t) | not)]')
  else
    filtered_repos=$(echo "$repos_json" | jq --arg t "$topic_value" '[.[] | select([.repositoryTopics[].name] | index($t))]')
  fi

  local count
  count=$(echo "$filtered_repos" | jq 'length')

  if [ "$count" -eq 0 ]; then
    echo -e "${GREEN}No repos need changes.${NC}"
    exit 0
  fi

  echo -e "${YELLOW}${count} repos to update:${NC}"
  echo "$filtered_repos" | jq -r '.[].nameWithOwner' | while IFS= read -r nwo; do
    echo -e "  ${DIM}•${NC} $nwo"
  done
  echo ""

  if $dry_run; then
    echo -e "${YELLOW}DRY RUN — no changes made.${NC}"
    exit 0
  fi

  if ! confirm "${action^} topic '${topic_value}' on ${count} repos?"; then
    echo "Cancelled."
    exit 0
  fi

  local success=0 fail=0
  while IFS= read -r nwo; do
    if gh repo edit "$nwo" --"${action}-topic" "$topic_value" 2>/dev/null; then
      success=$((success + 1))
      echo -e "  ${GREEN}OK${NC}     $nwo"
    else
      fail=$((fail + 1))
      echo -e "  ${RED}FAILED${NC} $nwo"
    fi
  done < <(echo "$filtered_repos" | jq -r '.[].nameWithOwner')

  echo ""
  echo -e "${GREEN}Done!${NC} Success: ${BOLD}${success}${NC}, Failed: ${BOLD}${fail}${NC}"
}

# =============================================================================
# COMMAND: cleanup-branches
# =============================================================================

cmd_cleanup_branches_usage() {
  cat <<EOF
${BOLD}github-helpers cleanup-branches${NC} ${DIM}v${VERSION}${NC} — Delete merged/stale remote branches

${BOLD}USAGE${NC}
  github-helpers cleanup-branches --repo OWNER/REPO [options]
  github-helpers cleanup-branches --org NAME [options]
  github-helpers cleanup-branches --user NAME [options]

${BOLD}TARGET${NC} (one required)
  --repo OWNER/REPO       Single repository
  --org NAME              All repos in organization
  --user NAME             All repos for user

${BOLD}OPTIONS${NC}
  --merged                Delete only merged branches (default)
  --stale-days N          Delete branches with no commits in N days
  --exclude PATTERN       Exclude branches matching pattern (grep regex)
  --dry-run               List branches without deleting
  -y, --yes               Skip confirmation prompt
  -v, --verbose           Show detailed output
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  github-helpers cleanup-branches --repo maxgfr/my-repo --dry-run
  github-helpers cleanup-branches --org my-company --merged --exclude "release|hotfix" --dry-run
  github-helpers cleanup-branches --user maxgfr --stale-days 90 -y
EOF
  exit 0
}

cmd_cleanup_branches_for_repo() {
  local nwo="$1" mode="$2" stale_days="$3" exclude="$4" dry_run="$5"

  # Get default branch
  local default_branch
  default_branch=$(gh api "repos/${nwo}" --jq '.default_branch' 2>/dev/null) || return 1

  # List remote branches
  local branches_json
  branches_json=$(gh api "repos/${nwo}/branches" --paginate --jq '.[] | select(.name != "'"$default_branch"'") | .name' 2>/dev/null) || return 1

  local -a to_delete=()

  while IFS= read -r branch; do
    [ -z "$branch" ] && continue

    # Exclude pattern
    if [ -n "$exclude" ] && echo "$branch" | grep -qE "$exclude"; then
      $VERBOSE && echo -e "    ${DIM}SKIP${NC} $branch ${DIM}(excluded)${NC}"
      continue
    fi

    local should_delete=false

    if [ "$mode" = "merged" ]; then
      # Check if branch is merged into default
      local comparison
      comparison=$(gh api "repos/${nwo}/compare/${default_branch}...${branch}" --jq '.ahead_by' 2>/dev/null || echo "-1")
      if [ "$comparison" = "0" ]; then
        should_delete=true
      fi
    fi

    if [ "$mode" = "stale" ] && [ -n "$stale_days" ]; then
      local last_commit_date
      last_commit_date=$(gh api "repos/${nwo}/branches/${branch}" --jq '.commit.commit.committer.date' 2>/dev/null || echo "")
      if [ -n "$last_commit_date" ]; then
        local cutoff_ts last_ts
        cutoff_ts=$(date -v-"${stale_days}"d +%s 2>/dev/null || date -d "${stale_days} days ago" +%s 2>/dev/null)
        last_ts=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$last_commit_date" +%s 2>/dev/null || date -d "$last_commit_date" +%s 2>/dev/null)
        if [ -n "$cutoff_ts" ] && [ -n "$last_ts" ] && [ "$last_ts" -lt "$cutoff_ts" ]; then
          should_delete=true
        fi
      fi
    fi

    if $should_delete; then
      to_delete+=("$branch")
      echo -e "    ${YELLOW}DELETE${NC} $branch"
    elif $VERBOSE; then
      echo -e "    ${DIM}KEEP${NC}   $branch"
    fi
  done <<< "$branches_json"

  if [ ${#to_delete[@]} -eq 0 ]; then
    $VERBOSE && echo -e "    ${GREEN}No branches to delete${NC}"
    return 0
  fi

  if $dry_run; then
    return 0
  fi

  for branch in "${to_delete[@]}"; do
    if gh api --method DELETE "repos/${nwo}/git/refs/heads/${branch}" 2>/dev/null; then
      $VERBOSE && echo -e "    ${GREEN}DELETED${NC} $branch"
    else
      echo -e "    ${RED}FAILED${NC}  $branch"
    fi
  done
}

cmd_cleanup_branches_main() {
  local target="" target_type="" mode="merged" stale_days="" exclude="" dry_run=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)        need_arg "--repo" "${2:-}"; target="$2"; target_type="repo"; shift 2 ;;
      --org)         need_arg "--org" "${2:-}"; target="$2"; target_type="org"; shift 2 ;;
      --user)        need_arg "--user" "${2:-}"; target="$2"; target_type="user"; shift 2 ;;
      --merged)      mode="merged"; shift ;;
      --stale-days)  need_arg "--stale-days" "${2:-}"; mode="stale"; stale_days="$2"; shift 2 ;;
      --exclude)     need_arg "--exclude" "${2:-}"; exclude="$2"; shift 2 ;;
      --dry-run)     dry_run=true; shift ;;
      -y|--yes)      AUTO_YES=true; shift ;;
      -v|--verbose)  VERBOSE=true; shift ;;
      -h|--help)     cmd_cleanup_branches_usage ;;
      *) die "cleanup-branches: unknown option: $1" ;;
    esac
  done

  [ -z "$target" ] && die "cleanup-branches: --repo, --org or --user is required"

  preflight_check

  echo -e "${BOLD}${CYAN}Cleanup Branches${NC} ${DIM}v${VERSION}${NC}"
  echo -e "${DIM}─────────────────────────────────────────────${NC}"
  echo -e "  Target: ${BOLD}${target}${NC}"
  echo -e "  Mode:   ${BOLD}${mode}${NC}"
  if $dry_run; then
    echo -e "  Run:    ${YELLOW}DRY RUN${NC}"
  fi
  echo ""

  if [ "$target_type" = "repo" ]; then
    echo -e "  ${BOLD}${target}${NC}"
    cmd_cleanup_branches_for_repo "$target" "$mode" "$stale_days" "$exclude" "$dry_run"
  else
    local repos_json
    repos_json=$(gh repo list "$target" --json nameWithOwner --source --no-archived --limit 9999 2>/dev/null) || die "Failed to list repos"

    local total
    total=$(echo "$repos_json" | jq 'length')
    echo -e "Scanning ${BOLD}${total}${NC} repos..."
    echo ""

    echo "$repos_json" | jq -r '.[].nameWithOwner' | while IFS= read -r nwo; do
      echo -e "  ${BOLD}${nwo}${NC}"
      cmd_cleanup_branches_for_repo "$nwo" "$mode" "$stale_days" "$exclude" "$dry_run"
    done
  fi

  echo ""
  if $dry_run; then
    echo -e "${YELLOW}DRY RUN — no branches were deleted.${NC}"
  else
    echo -e "${GREEN}Done!${NC}"
  fi
}

# =============================================================================
# COMMAND: workflow-status
# =============================================================================

cmd_workflow_status_usage() {
  cat <<EOF
${BOLD}github-helpers workflow-status${NC} ${DIM}v${VERSION}${NC} — Overview of CI workflow runs

${BOLD}USAGE${NC}
  github-helpers workflow-status [options]

${BOLD}OPTIONS${NC}
  --user NAME             Target user (default: authenticated user)
  --org NAME              Target organization
  --limit N               Max repos to scan (default: 30)
  --failed                Show only repos with failed workflows
  -v, --verbose           Show all workflows, not just latest
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  github-helpers workflow-status
  github-helpers workflow-status --org my-company --failed
  github-helpers workflow-status --limit 50 -v
EOF
  exit 0
}

cmd_workflow_status_main() {
  local target="" target_type="" limit=30 failed_only=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --user)      need_arg "--user" "${2:-}"; target="$2"; target_type="user"; shift 2 ;;
      --org)       need_arg "--org" "${2:-}"; target="$2"; target_type="org"; shift 2 ;;
      --limit)     need_arg "--limit" "${2:-}"; limit="$2"; shift 2 ;;
      --failed)    failed_only=true; shift ;;
      -v|--verbose) VERBOSE=true; shift ;;
      -h|--help)   cmd_workflow_status_usage ;;
      *) die "workflow-status: unknown option: $1" ;;
    esac
  done

  preflight_check

  if [ -z "$target" ]; then
    target=$(get_username)
    target_type="user"
  fi

  echo -e "${BOLD}${CYAN}Workflow Status${NC} ${DIM}v${VERSION}${NC}"
  echo -e "${DIM}─────────────────────────────────────────────${NC}"
  echo -e "  Target: ${BOLD}${target}${NC}"
  echo ""

  local repos_json
  repos_json=$(gh repo list "$target" --json nameWithOwner --source --no-archived --limit "$limit" 2>/dev/null) || die "Failed to list repos"

  local total
  total=$(echo "$repos_json" | jq 'length')
  echo -e "${DIM}Checking ${total} repos...${NC}"
  echo ""

  printf "  ${BOLD}%-40s %-12s %-12s %s${NC}\n" "Repository" "Status" "Branch" "Workflow"
  printf "  %-40s %-12s %-12s %s\n" "────────────────────────────────────────" "────────────" "────────────" "────────────────"

  echo "$repos_json" | jq -r '.[].nameWithOwner' | while IFS= read -r nwo; do
    # Get latest workflow run
    local run_json
    run_json=$(gh api "repos/${nwo}/actions/runs?per_page=1" --jq '.workflow_runs[0] // empty' 2>/dev/null || echo "")

    if [ -z "$run_json" ]; then
      if ! $failed_only; then
        printf "  %-40s ${DIM}%-12s${NC}\n" "$nwo" "no workflows"
      fi
      continue
    fi

    local status conclusion branch workflow_name
    status=$(echo "$run_json" | jq -r '.status')
    conclusion=$(echo "$run_json" | jq -r '.conclusion // "pending"')
    branch=$(echo "$run_json" | jq -r '.head_branch')
    workflow_name=$(echo "$run_json" | jq -r '.name')

    local status_display=""
    case "$conclusion" in
      success)    status_display="${GREEN}✓ success${NC}" ;;
      failure)    status_display="${RED}✗ failure${NC}" ;;
      cancelled)  status_display="${YELLOW}○ cancelled${NC}" ;;
      pending)    status_display="${CYAN}◌ pending${NC}" ;;
      *)          status_display="${DIM}? ${conclusion}${NC}" ;;
    esac

    if $failed_only && [ "$conclusion" != "failure" ]; then
      continue
    fi

    printf "  %-40s $(echo -e "$status_display")%-3s %-12s %s\n" "$nwo" "" "$branch" "$workflow_name"
  done

  echo ""
}

# =============================================================================
# COMMAND: sync-labels
# =============================================================================

cmd_sync_labels_usage() {
  cat <<EOF
${BOLD}github-helpers sync-labels${NC} ${DIM}v${VERSION}${NC} — Sync labels from a template repo

${BOLD}USAGE${NC}
  github-helpers sync-labels --from OWNER/REPO --to OWNER/REPO [options]
  github-helpers sync-labels --from OWNER/REPO --org NAME [options]

${BOLD}OPTIONS${NC}
  --from OWNER/REPO       Source repo with template labels
  --to OWNER/REPO         Single target repo
  --org NAME              Apply to all repos in org
  --user NAME             Apply to all repos for user
  --dry-run               Preview changes without applying
  -y, --yes               Skip confirmation prompt
  -v, --verbose           Show detailed output
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  github-helpers sync-labels --from maxgfr/template --to maxgfr/my-repo --dry-run
  github-helpers sync-labels --from maxgfr/template --org my-company -y
EOF
  exit 0
}

cmd_sync_labels_main() {
  local from_repo="" to_repo="" to_target="" to_type="" dry_run=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --from)      need_arg "--from" "${2:-}"; from_repo="$2"; shift 2 ;;
      --to)        need_arg "--to" "${2:-}"; to_repo="$2"; to_type="repo"; shift 2 ;;
      --org)       need_arg "--org" "${2:-}"; to_target="$2"; to_type="org"; shift 2 ;;
      --user)      need_arg "--user" "${2:-}"; to_target="$2"; to_type="user"; shift 2 ;;
      --dry-run)   dry_run=true; shift ;;
      -y|--yes)    AUTO_YES=true; shift ;;
      -v|--verbose) VERBOSE=true; shift ;;
      -h|--help)   cmd_sync_labels_usage ;;
      *) die "sync-labels: unknown option: $1" ;;
    esac
  done

  [ -z "$from_repo" ] && die "sync-labels: --from is required"
  [ -z "$to_repo" ] && [ -z "$to_target" ] && die "sync-labels: --to, --org, or --user is required"

  preflight_check

  echo -e "${BOLD}${CYAN}Sync Labels${NC} ${DIM}v${VERSION}${NC}"
  echo -e "${DIM}─────────────────────────────────────────────${NC}"
  echo -e "  From: ${BOLD}${from_repo}${NC}"
  if $dry_run; then
    echo -e "  Mode: ${YELLOW}DRY RUN${NC}"
  fi
  echo ""

  # Fetch source labels
  echo -e "${DIM}Fetching labels from ${from_repo}...${NC}"
  local source_labels
  source_labels=$(gh api "repos/${from_repo}/labels" --paginate --jq '.[] | {name, color, description}' 2>/dev/null) || die "Failed to fetch labels from ${from_repo}"

  local label_count
  label_count=$(echo "$source_labels" | jq -s 'length')
  echo -e "Found ${BOLD}${label_count}${NC} labels"
  echo ""

  # Build target list
  local -a targets=()
  if [ "$to_type" = "repo" ]; then
    targets=("$to_repo")
  else
    local repos_json
    repos_json=$(gh repo list "$to_target" --json nameWithOwner --source --no-archived --limit 9999 2>/dev/null) || die "Failed to list repos"
    while IFS= read -r nwo; do
      [ "$nwo" = "$from_repo" ] && continue
      targets+=("$nwo")
    done < <(echo "$repos_json" | jq -r '.[].nameWithOwner')
  fi

  echo -e "Target repos: ${BOLD}${#targets[@]}${NC}"

  if $dry_run; then
    echo ""
    echo -e "${BOLD}Labels to sync:${NC}"
    echo "$source_labels" | jq -rs '.[] | "  • \(.name) (#\(.color))"'
    echo ""
    echo -e "${YELLOW}DRY RUN — no labels were synced.${NC}"
    exit 0
  fi

  if ! confirm "Sync ${label_count} labels to ${#targets[@]} repos?"; then
    echo "Cancelled."
    exit 0
  fi

  echo ""
  for target_nwo in "${targets[@]}"; do
    echo -e "  ${BOLD}${target_nwo}${NC}"

    echo "$source_labels" | jq -c '.' | while IFS= read -r label; do
      local name color desc
      name=$(echo "$label" | jq -r '.name')
      color=$(echo "$label" | jq -r '.color')
      desc=$(echo "$label" | jq -r '.description // ""')

      # Try to update existing, create if not found
      local encoded_name
      encoded_name=$(printf '%s' "$name" | jq -sRr @uri)
      if gh api --method PATCH "repos/${target_nwo}/labels/${encoded_name}" \
        -f color="$color" -f description="$desc" &>/dev/null; then
        $VERBOSE && echo -e "    ${CYAN}UPDATED${NC} $name"
      elif gh api --method POST "repos/${target_nwo}/labels" \
        -f name="$name" -f color="$color" -f description="$desc" &>/dev/null; then
        $VERBOSE && echo -e "    ${GREEN}CREATED${NC} $name"
      else
        echo -e "    ${RED}FAILED${NC}  $name"
      fi
    done
  done

  echo ""
  echo -e "${GREEN}Done!${NC}"
}

# =============================================================================
# COMMAND: export-stars
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
EXPORT_STARS_FORMAT="json"
EXPORT_STARS_OUT=""

cmd_export_stars_usage() {
  cat <<EOF
${BOLD}github-helpers export-stars${NC} ${DIM}v${VERSION}${NC} — Export starred repos to JSON/CSV/Markdown

${BOLD}USAGE${NC}
  github-helpers export-stars [options]

${BOLD}OPTIONS${NC}
  --format FORMAT         Output format: json, csv, md (default: json)
  --out FILE              Output file (default: stdout)
  -v, --verbose           Show progress during fetch
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  github-helpers export-stars --format json --out stars.json
  github-helpers export-stars --format csv --out stars.csv
  github-helpers export-stars --format md -v
EOF
  exit 0
}

cmd_export_stars_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --format)    need_arg "--format" "${2:-}"; EXPORT_STARS_FORMAT="$2"; shift 2 ;;
      --out)       need_arg "--out" "${2:-}"; EXPORT_STARS_OUT="$2"; shift 2 ;;
      -v|--verbose) VERBOSE=true; shift ;;
      -h|--help)   cmd_export_stars_usage ;;
      *) die "export-stars: unknown option: $1" ;;
    esac
  done

  case "$EXPORT_STARS_FORMAT" in
    json|csv|md) ;;
    *) die "export-stars: --format must be json, csv, or md (got: ${EXPORT_STARS_FORMAT})" ;;
  esac
}

cmd_export_stars_fetch() {
  local username="$1"
  local has_next="true" total_fetched=0
  local -a cursor_arg=("-F" "cursor=null")
  local all_json="[]"

  while [ "$has_next" = "true" ]; do
    local result
    result=$(gh api graphql -f query='
      query($login: String!, $cursor: String) {
        user(login: $login) {
          starredRepositories(first: 100, after: $cursor) {
            totalCount
            edges {
              node {
                nameWithOwner
                description
                url
                primaryLanguage { name }
                stargazerCount
                pushedAt
                isArchived
              }
            }
            pageInfo {
              hasNextPage
              endCursor
            }
          }
        }
      }' -f login="$username" "${cursor_arg[@]}") || {
      die "GraphQL request failed. Check your network and gh auth."
    }

    local gql_error
    gql_error=$(echo "$result" | jq -r '.errors[0].message // empty' 2>/dev/null)
    if [ -n "$gql_error" ]; then
      die "GitHub API: ${gql_error}"
    fi

    # Extract repos and append to all_json
    local page_repos
    page_repos=$(echo "$result" | jq '[.data.user.starredRepositories.edges[].node | {
      nameWithOwner,
      description: (.description // ""),
      url,
      primaryLanguage: (.primaryLanguage.name // ""),
      stargazerCount,
      pushedAt: (.pushedAt // ""),
      isArchived
    }]')
    all_json=$(echo "$all_json" "$page_repos" | jq -s '.[0] + .[1]')

    local count total_count
    count=$(echo "$result" | jq '.data.user.starredRepositories.edges | length')
    total_fetched=$((total_fetched + count))
    total_count=$(echo "$result" | jq '.data.user.starredRepositories.totalCount')

    if $VERBOSE; then
      echo -e "  ${DIM}Fetched ${total_fetched}/${total_count} starred repos...${NC}" >&2
    fi

    has_next=$(echo "$result" | jq -r '.data.user.starredRepositories.pageInfo.hasNextPage')
    local end_cursor
    end_cursor=$(echo "$result" | jq -r '.data.user.starredRepositories.pageInfo.endCursor // empty')
    if [ -z "$end_cursor" ]; then
      break
    fi
    cursor_arg=("-f" "cursor=${end_cursor}")
  done

  echo "$all_json"
}

cmd_export_stars_main() {
  cmd_export_stars_parse_args "$@"
  preflight_check

  local USERNAME
  USERNAME=$(get_username)

  echo -e "${BOLD}${CYAN}Export Stars${NC} ${DIM}v${VERSION}${NC}" >&2
  echo -e "${DIM}─────────────────────────────────────────────${NC}" >&2
  echo -e "  User:   ${BOLD}${USERNAME}${NC}" >&2
  echo -e "  Format: ${BOLD}${EXPORT_STARS_FORMAT}${NC}" >&2
  if [ -n "$EXPORT_STARS_OUT" ]; then
    echo -e "  Output: ${BOLD}${EXPORT_STARS_OUT}${NC}" >&2
  fi
  echo "" >&2

  echo -e "${DIM}Fetching starred repos...${NC}" >&2
  local stars_json
  stars_json=$(cmd_export_stars_fetch "$USERNAME")

  local total
  total=$(echo "$stars_json" | jq 'length')
  echo -e "${GREEN}Fetched ${total} starred repos.${NC}" >&2

  local output=""

  case "$EXPORT_STARS_FORMAT" in
    json)
      output=$(echo "$stars_json" | jq '.')
      ;;
    csv)
      output=$(echo "$stars_json" | jq -r '
        ["nameWithOwner","description","url","primaryLanguage","stargazerCount","pushedAt","isArchived"],
        (.[] | [
          .nameWithOwner,
          (.description | gsub(","; " ") | gsub("\n"; " ")),
          .url,
          .primaryLanguage,
          (.stargazerCount | tostring),
          .pushedAt,
          (.isArchived | tostring)
        ]) | @csv')
      ;;
    md)
      output=$(echo "$stars_json" | jq -r '
        "| Repository | Description | Language | Stars | Last Push | Archived |",
        "| --- | --- | --- | ---: | --- | --- |",
        (.[] | "| [\(.nameWithOwner)](\(.url)) | \(.description | gsub("\\|"; "/") | gsub("\n"; " ") | .[0:80]) | \(.primaryLanguage) | \(.stargazerCount) | \(.pushedAt | .[0:10]) | \(.isArchived) |")')
      ;;
  esac

  if [ -n "$EXPORT_STARS_OUT" ]; then
    echo "$output" > "$EXPORT_STARS_OUT"
    echo -e "${GREEN}Done!${NC} Saved to ${BOLD}${EXPORT_STARS_OUT}${NC}" >&2
  else
    echo "$output"
  fi
}

# =============================================================================
# COMMAND: rename-default-branch
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
RENAME_BRANCH_FROM="master"
RENAME_BRANCH_TO="main"
RENAME_BRANCH_TARGET=""
RENAME_BRANCH_TARGET_TYPE=""
RENAME_BRANCH_REPO=""

cmd_rename_default_branch_usage() {
  cat <<EOF
${BOLD}github-helpers rename-default-branch${NC} ${DIM}v${VERSION}${NC} — Rename default branch across repos

${BOLD}USAGE${NC}
  github-helpers rename-default-branch [options]

${BOLD}OPTIONS${NC}
  --from NAME             Current branch name (default: master)
  --to NAME               New branch name (default: main)
  --user NAME             Target user (default: authenticated user)
  --org NAME              Target organization
  --repo OWNER/REPO       Single repo to rename
  --dry-run               Preview changes without applying
  -y, --yes               Skip confirmation prompt
  -v, --verbose           Show detailed output
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  github-helpers rename-default-branch --dry-run
  github-helpers rename-default-branch --from master --to main -y
  github-helpers rename-default-branch --repo myuser/myrepo --dry-run
  github-helpers rename-default-branch --org my-company --dry-run
EOF
  exit 0
}

cmd_rename_default_branch_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --from)      need_arg "--from" "${2:-}"; RENAME_BRANCH_FROM="$2"; shift 2 ;;
      --to)        need_arg "--to" "${2:-}"; RENAME_BRANCH_TO="$2"; shift 2 ;;
      --user)      need_arg "--user" "${2:-}"; RENAME_BRANCH_TARGET="$2"; RENAME_BRANCH_TARGET_TYPE="user"; shift 2 ;;
      --org)       need_arg "--org" "${2:-}"; RENAME_BRANCH_TARGET="$2"; RENAME_BRANCH_TARGET_TYPE="org"; shift 2 ;;
      --repo)      need_arg "--repo" "${2:-}"; RENAME_BRANCH_REPO="$2"; shift 2 ;;
      --dry-run)   DRY_RUN=true; shift ;;
      -y|--yes)    AUTO_YES=true; shift ;;
      -v|--verbose) VERBOSE=true; shift ;;
      -h|--help)   cmd_rename_default_branch_usage ;;
      *) die "rename-default-branch: unknown option: $1" ;;
    esac
  done

  if [ "$RENAME_BRANCH_FROM" = "$RENAME_BRANCH_TO" ]; then
    die "rename-default-branch: --from and --to cannot be the same"
  fi
}

cmd_rename_default_branch_main() {
  cmd_rename_default_branch_parse_args "$@"
  preflight_check

  echo -e "${BOLD}${CYAN}Rename Default Branch${NC} ${DIM}v${VERSION}${NC}"
  echo -e "${DIM}─────────────────────────────────────────────${NC}"
  echo -e "  Rename: ${BOLD}${RENAME_BRANCH_FROM}${NC} → ${BOLD}${RENAME_BRANCH_TO}${NC}"
  if $DRY_RUN; then
    echo -e "  Mode:   ${YELLOW}DRY RUN${NC}"
  fi
  echo ""

  # Build list of repos
  local repos_json
  if [ -n "$RENAME_BRANCH_REPO" ]; then
    repos_json=$(gh api "repos/${RENAME_BRANCH_REPO}" --jq '[{nameWithOwner: .full_name, defaultBranch: .default_branch}]' 2>/dev/null) \
      || die "Failed to fetch repo: ${RENAME_BRANCH_REPO}"
  else
    if [ -z "$RENAME_BRANCH_TARGET" ]; then
      RENAME_BRANCH_TARGET=$(get_username)
      RENAME_BRANCH_TARGET_TYPE="user"
    fi
    echo -e "  Target: ${BOLD}${RENAME_BRANCH_TARGET}${NC}"
    echo ""
    echo -e "${DIM}Fetching repos...${NC}"
    repos_json=$(gh repo list "$RENAME_BRANCH_TARGET" --json nameWithOwner,defaultBranchRef --source --no-archived --limit 9999 2>/dev/null) \
      || die "Failed to list repos"
    # Normalize field name
    repos_json=$(echo "$repos_json" | jq '[.[] | {nameWithOwner, defaultBranch: .defaultBranchRef.name}]')
  fi

  # Filter to repos whose default branch matches --from
  local matching_json
  matching_json=$(echo "$repos_json" | jq --arg from "$RENAME_BRANCH_FROM" '[.[] | select(.defaultBranch == $from)]')

  local total
  total=$(echo "$matching_json" | jq 'length')

  if [ "$total" -eq 0 ]; then
    echo -e "${GREEN}No repos found with default branch '${RENAME_BRANCH_FROM}'. Nothing to rename.${NC}"
    exit 0
  fi

  local skipped
  skipped=$(echo "$repos_json" | jq --arg from "$RENAME_BRANCH_FROM" '[.[] | select(.defaultBranch != $from)] | length')

  echo -e "${YELLOW}Found ${total} repos with default branch '${RENAME_BRANCH_FROM}'${NC} (skipped ${skipped} already on other branches)"
  echo ""

  echo -e "${BOLD}Repos to rename:${NC}"
  echo "$matching_json" | jq -r '.[].nameWithOwner' | while IFS= read -r nwo; do
    echo -e "  ${DIM}•${NC} ${nwo}"
  done
  echo ""

  if $DRY_RUN; then
    echo -e "${YELLOW}DRY RUN — no branches were renamed.${NC}"
    exit 0
  fi

  if ! confirm "Rename default branch on ${total} repos?"; then
    echo "Cancelled."
    exit 0
  fi

  local success=0 fail=0
  while IFS= read -r nwo; do
    # Rename the branch
    if gh api -X POST "repos/${nwo}/branches/${RENAME_BRANCH_FROM}/rename" \
      -f new_name="$RENAME_BRANCH_TO" &>/dev/null; then
      # Update default branch
      if gh api -X PATCH "repos/${nwo}" -f default_branch="$RENAME_BRANCH_TO" &>/dev/null; then
        success=$((success + 1))
        echo -e "  ${GREEN}RENAMED${NC}  ${nwo}: ${RENAME_BRANCH_FROM} → ${RENAME_BRANCH_TO}"
      else
        fail=$((fail + 1))
        echo -e "  ${YELLOW}PARTIAL${NC}  ${nwo}: branch renamed but default not updated"
      fi
    else
      fail=$((fail + 1))
      echo -e "  ${RED}FAILED${NC}   ${nwo}"
    fi
  done < <(echo "$matching_json" | jq -r '.[].nameWithOwner')

  echo ""
  echo -e "${GREEN}Done!${NC} Success: ${BOLD}${success}${NC}, Failed: ${BOLD}${fail}${NC}"
}

# =============================================================================
# COMMAND: secret-audit
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
SECRET_AUDIT_TARGET=""
SECRET_AUDIT_TARGET_TYPE=""
SECRET_AUDIT_REPO=""
SECRET_AUDIT_LIMIT=0

cmd_secret_audit_usage() {
  cat <<EOF
${BOLD}github-helpers secret-audit${NC} ${DIM}v${VERSION}${NC} — List secrets and env vars across repos

${BOLD}USAGE${NC}
  github-helpers secret-audit [options]

${BOLD}OPTIONS${NC}
  --user NAME             Target user (default: authenticated user)
  --org NAME              Target organization
  --repo OWNER/REPO       Single repo to audit
  --limit N               Max repos to scan (default: all)
  -v, --verbose           Show repos even if they have no secrets
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  github-helpers secret-audit
  github-helpers secret-audit --org my-company --limit 50
  github-helpers secret-audit --repo myuser/myrepo
  github-helpers secret-audit -v
EOF
  exit 0
}

cmd_secret_audit_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --user)      need_arg "--user" "${2:-}"; SECRET_AUDIT_TARGET="$2"; SECRET_AUDIT_TARGET_TYPE="user"; shift 2 ;;
      --org)       need_arg "--org" "${2:-}"; SECRET_AUDIT_TARGET="$2"; SECRET_AUDIT_TARGET_TYPE="org"; shift 2 ;;
      --repo)      need_arg "--repo" "${2:-}"; SECRET_AUDIT_REPO="$2"; shift 2 ;;
      --limit)     need_arg "--limit" "${2:-}"; SECRET_AUDIT_LIMIT="$2"; shift 2 ;;
      -v|--verbose) VERBOSE=true; shift ;;
      -h|--help)   cmd_secret_audit_usage ;;
      *) die "secret-audit: unknown option: $1" ;;
    esac
  done
}

cmd_secret_audit_main() {
  cmd_secret_audit_parse_args "$@"
  preflight_check

  echo -e "${BOLD}${CYAN}Secret Audit${NC} ${DIM}v${VERSION}${NC}"
  echo -e "${DIM}─────────────────────────────────────────────${NC}"

  # Build repo list
  local repo_list
  if [ -n "$SECRET_AUDIT_REPO" ]; then
    repo_list="$SECRET_AUDIT_REPO"
    echo -e "  Repo: ${BOLD}${SECRET_AUDIT_REPO}${NC}"
  else
    if [ -z "$SECRET_AUDIT_TARGET" ]; then
      SECRET_AUDIT_TARGET=$(get_username)
      SECRET_AUDIT_TARGET_TYPE="user"
    fi
    echo -e "  Target: ${BOLD}${SECRET_AUDIT_TARGET}${NC}"
    echo ""
    echo -e "${DIM}Fetching repos...${NC}"

    local -a flags=("--json" "nameWithOwner" "--limit")
    if [ "$SECRET_AUDIT_LIMIT" -gt 0 ] 2>/dev/null; then
      flags+=("$SECRET_AUDIT_LIMIT")
    else
      flags+=("9999")
    fi

    repo_list=$(gh repo list "$SECRET_AUDIT_TARGET" "${flags[@]}" --no-archived 2>/dev/null \
      | jq -r '.[].nameWithOwner') || die "Failed to list repos"
  fi
  echo ""

  local total_repos=0 repos_with_secrets=0 total_secrets=0 total_variables=0

  while IFS= read -r nwo; do
    [ -z "$nwo" ] && continue
    total_repos=$((total_repos + 1))

    # Fetch secrets
    local secrets_json
    secrets_json=$(gh api "repos/${nwo}/actions/secrets" --jq '.secrets' 2>/dev/null || echo "[]")
    local secret_count
    secret_count=$(echo "$secrets_json" | jq 'length')

    # Fetch variables
    local vars_json
    vars_json=$(gh api "repos/${nwo}/actions/variables" --jq '.variables' 2>/dev/null || echo "[]")
    local var_count
    var_count=$(echo "$vars_json" | jq 'length')

    total_secrets=$((total_secrets + secret_count))
    total_variables=$((total_variables + var_count))

    if [ "$secret_count" -eq 0 ] && [ "$var_count" -eq 0 ]; then
      if $VERBOSE; then
        echo -e "  ${DIM}${nwo}: no secrets or variables${NC}"
      fi
      continue
    fi

    repos_with_secrets=$((repos_with_secrets + 1))

    echo -e "  ${BOLD}${nwo}${NC}"

    if [ "$secret_count" -gt 0 ]; then
      echo -e "    ${YELLOW}Secrets (${secret_count}):${NC}"
      echo "$secrets_json" | jq -r '.[].name' | while IFS= read -r name; do
        echo -e "      ${DIM}•${NC} ${name}"
      done
    fi

    if [ "$var_count" -gt 0 ]; then
      echo -e "    ${CYAN}Variables (${var_count}):${NC}"
      echo "$vars_json" | jq -r '.[] | "\(.name)=\(.value)"' | while IFS= read -r line; do
        local vname="${line%%=*}"
        local vvalue="${line#*=}"
        echo -e "      ${DIM}•${NC} ${vname} ${DIM}= ${vvalue}${NC}"
      done
    fi

    echo ""
  done <<< "$repo_list"

  echo -e "${DIM}─────────────────────────────────────────────${NC}"
  echo -e "${BOLD}Summary:${NC}"
  echo -e "  Repos scanned:      ${BOLD}${total_repos}${NC}"
  echo -e "  Repos with secrets: ${BOLD}${repos_with_secrets}${NC}"
  echo -e "  Total secrets:      ${BOLD}${total_secrets}${NC}"
  echo -e "  Total variables:    ${BOLD}${total_variables}${NC}"
  echo ""
}

# =============================================================================
# COMMAND: license-check
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
LICENSE_CHECK_TARGET=""
LICENSE_CHECK_TARGET_TYPE=""
LICENSE_CHECK_TEMPLATE=""
LICENSE_CHECK_ADD=false

cmd_license_check_usage() {
  cat <<EOF
${BOLD}github-helpers license-check${NC} ${DIM}v${VERSION}${NC} — Check and add LICENSE files

${BOLD}USAGE${NC}
  github-helpers license-check [options]

${BOLD}OPTIONS${NC}
  --user NAME             Target user (default: authenticated user)
  --org NAME              Target organization
  --template SPDX         License template to add (e.g., MIT, Apache-2.0)
  --add                   Add missing licenses (requires --template)
  --dry-run               Preview changes without applying
  -y, --yes               Skip confirmation prompt
  -v, --verbose           Show detailed output
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  # List license status for all your repos
  github-helpers license-check

  # Check an org's repos
  github-helpers license-check --org my-company

  # Preview adding MIT license to repos missing one
  github-helpers license-check --add --template MIT --dry-run

  # Add MIT license to repos missing one
  github-helpers license-check --add --template MIT -y
EOF
  exit 0
}

cmd_license_check_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --user)       need_arg "--user" "${2:-}"; LICENSE_CHECK_TARGET="$2"; LICENSE_CHECK_TARGET_TYPE="user"; shift 2 ;;
      --org)        need_arg "--org" "${2:-}"; LICENSE_CHECK_TARGET="$2"; LICENSE_CHECK_TARGET_TYPE="org"; shift 2 ;;
      --template)   need_arg "--template" "${2:-}"; LICENSE_CHECK_TEMPLATE="$2"; shift 2 ;;
      --add)        LICENSE_CHECK_ADD=true; shift ;;
      --dry-run)    DRY_RUN=true; shift ;;
      -y|--yes)     AUTO_YES=true; shift ;;
      -v|--verbose) VERBOSE=true; shift ;;
      -h|--help)    cmd_license_check_usage ;;
      *) die "license-check: unknown option: $1" ;;
    esac
  done

  if $LICENSE_CHECK_ADD && [ -z "$LICENSE_CHECK_TEMPLATE" ]; then
    die "license-check: --add requires --template"
  fi
}

cmd_license_check_main() {
  cmd_license_check_parse_args "$@"
  preflight_check

  if [ -z "$LICENSE_CHECK_TARGET" ]; then
    LICENSE_CHECK_TARGET=$(get_username)
    LICENSE_CHECK_TARGET_TYPE="user"
  fi

  echo -e "${BOLD}${CYAN}License Check${NC} ${DIM}v${VERSION}${NC}"
  echo -e "${DIM}─────────────────────────────────────────────${NC}"
  echo -e "  Target: ${BOLD}${LICENSE_CHECK_TARGET}${NC}"
  if $LICENSE_CHECK_ADD; then
    echo -e "  Action: ${BOLD}Add '${LICENSE_CHECK_TEMPLATE}' to repos missing a license${NC}"
  fi
  if $DRY_RUN; then
    echo -e "  Mode:   ${YELLOW}DRY RUN${NC}"
  fi
  echo ""

  echo -e "${DIM}Fetching repos...${NC}"
  local repos_json
  repos_json=$(gh repo list "$LICENSE_CHECK_TARGET" --json nameWithOwner,licenseInfo --source --no-archived --limit 9999 2>/dev/null) \
    || die "Failed to list repos"

  local total
  total=$(echo "$repos_json" | jq 'length')

  if [ "$total" -eq 0 ]; then
    echo -e "${GREEN}No repos found.${NC}"
    exit 0
  fi

  echo -e "Found ${BOLD}${total}${NC} repos"
  echo ""

  # Categorize repos
  local with_license=0 without_license=0
  local -a missing_nwos=()

  printf "  ${BOLD}%-45s %s${NC}\n" "Repository" "License"
  printf "  %-45s %s\n" "─────────────────────────────────────────────" "──────────────────"

  echo "$repos_json" | jq -c '.[]' | while IFS= read -r repo; do
    local nwo license_name
    nwo=$(echo "$repo" | jq -r '.nameWithOwner')
    license_name=$(echo "$repo" | jq -r '.licenseInfo.name // empty')

    if [ -n "$license_name" ]; then
      printf "  %-45s ${GREEN}%s${NC}\n" "$nwo" "$license_name"
    else
      printf "  %-45s ${RED}%s${NC}\n" "$nwo" "NONE"
    fi
  done

  # Get counts and missing list outside subshell
  with_license=$(echo "$repos_json" | jq '[.[] | select(.licenseInfo.name != null and .licenseInfo.name != "")] | length')
  without_license=$(echo "$repos_json" | jq '[.[] | select(.licenseInfo.name == null or .licenseInfo.name == "")] | length')

  echo ""
  echo -e "${BOLD}Summary:${NC} ${GREEN}${with_license} with license${NC}, ${RED}${without_license} missing${NC}"
  echo ""

  # If not adding, stop here
  if ! $LICENSE_CHECK_ADD; then
    exit 0
  fi

  if [ "$without_license" -eq 0 ]; then
    echo -e "${GREEN}All repos have licenses. Nothing to add.${NC}"
    exit 0
  fi

  # Fetch license template
  echo -e "${DIM}Fetching license template '${LICENSE_CHECK_TEMPLATE}'...${NC}"
  local license_body
  license_body=$(gh api "licenses/${LICENSE_CHECK_TEMPLATE}" --jq '.body' 2>/dev/null) \
    || die "Failed to fetch license template '${LICENSE_CHECK_TEMPLATE}'. Use a valid SPDX ID (e.g., MIT, Apache-2.0, GPL-3.0)."

  if [ -z "$license_body" ]; then
    die "License template '${LICENSE_CHECK_TEMPLATE}' returned empty body."
  fi

  # Get list of repos missing licenses
  local missing_repos
  missing_repos=$(echo "$repos_json" | jq -r '.[] | select(.licenseInfo.name == null or .licenseInfo.name == "") | .nameWithOwner')

  echo -e "${YELLOW}Will add '${LICENSE_CHECK_TEMPLATE}' license to ${without_license} repos:${NC}"
  echo "$missing_repos" | while IFS= read -r nwo; do
    echo -e "  ${DIM}•${NC} ${nwo}"
  done
  echo ""

  if $DRY_RUN; then
    echo -e "${YELLOW}DRY RUN — no licenses were added.${NC}"
    exit 0
  fi

  if ! confirm "Add '${LICENSE_CHECK_TEMPLATE}' license to ${without_license} repos?"; then
    echo "Cancelled."
    exit 0
  fi

  local encoded_body
  encoded_body=$(echo -n "$license_body" | base64 | tr -d '\n')

  local success=0 fail=0
  while IFS= read -r nwo; do
    [ -z "$nwo" ] && continue
    if gh api -X PUT "repos/${nwo}/contents/LICENSE" \
      -f message="Add ${LICENSE_CHECK_TEMPLATE} license" \
      -f content="$encoded_body" &>/dev/null; then
      success=$((success + 1))
      echo -e "  ${GREEN}ADDED${NC}   ${nwo}"
    else
      fail=$((fail + 1))
      echo -e "  ${RED}FAILED${NC}  ${nwo}"
    fi
  done <<< "$missing_repos"

  echo ""
  echo -e "${GREEN}Done!${NC} Added: ${BOLD}${success}${NC}, Failed: ${BOLD}${fail}${NC}"
}

# =============================================================================
# COMMAND: dependabot-enable
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
DEPENDABOT_TARGET=""
DEPENDABOT_TARGET_TYPE=""
DEPENDABOT_ECOSYSTEMS=""
DEPENDABOT_SCHEDULE="weekly"

cmd_dependabot_enable_usage() {
  cat <<EOF
${BOLD}github-helpers dependabot-enable${NC} ${DIM}v${VERSION}${NC} — Enable Dependabot on repos

${BOLD}USAGE${NC}
  github-helpers dependabot-enable [options]

${BOLD}OPTIONS${NC}
  --user NAME             Target user (default: authenticated user)
  --org NAME              Target organization
  --ecosystems LIST       Comma-separated: npm,pip,docker,github-actions,
                          bundler,cargo,composer,gomod,maven,nuget
                          (default: auto-detect from repo languages)
  --schedule FREQ         Update frequency: daily, weekly, monthly
                          (default: weekly)
  --dry-run               Preview changes without applying
  -y, --yes               Skip confirmation prompt
  -v, --verbose           Show detailed output
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  github-helpers dependabot-enable --dry-run
  github-helpers dependabot-enable --ecosystems npm,github-actions --schedule daily
  github-helpers dependabot-enable --org my-company --dry-run
EOF
  exit 0
}

cmd_dependabot_enable_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --user)        need_arg "--user" "${2:-}"; DEPENDABOT_TARGET="$2"; DEPENDABOT_TARGET_TYPE="user"; shift 2 ;;
      --org)         need_arg "--org" "${2:-}"; DEPENDABOT_TARGET="$2"; DEPENDABOT_TARGET_TYPE="org"; shift 2 ;;
      --ecosystems)  need_arg "--ecosystems" "${2:-}"; DEPENDABOT_ECOSYSTEMS="$2"; shift 2 ;;
      --schedule)    need_arg "--schedule" "${2:-}"; DEPENDABOT_SCHEDULE="$2"; shift 2 ;;
      --dry-run)     DRY_RUN=true; shift ;;
      -y|--yes)      AUTO_YES=true; shift ;;
      -v|--verbose)  VERBOSE=true; shift ;;
      -h|--help)     cmd_dependabot_enable_usage ;;
      *) die "dependabot-enable: unknown option: $1" ;;
    esac
  done

  case "$DEPENDABOT_SCHEDULE" in
    daily|weekly|monthly) ;;
    *) die "dependabot-enable: --schedule must be daily, weekly, or monthly (got: ${DEPENDABOT_SCHEDULE})" ;;
  esac
}

cmd_dependabot_enable_detect_ecosystem() {
  local language="$1"
  case "$language" in
    JavaScript|TypeScript|CoffeeScript) echo "npm" ;;
    Python)          echo "pip" ;;
    Ruby)            echo "bundler" ;;
    Go)              echo "gomod" ;;
    Rust)            echo "cargo" ;;
    Java|Kotlin|Scala) echo "maven" ;;
    PHP)             echo "composer" ;;
    C#|F#|"Visual Basic .NET") echo "nuget" ;;
    Dockerfile)      echo "docker" ;;
    Elixir)          echo "mix" ;;
    Swift)           echo "swift" ;;
    *)               echo "" ;;
  esac
}

cmd_dependabot_enable_build_config() {
  local schedule="$1"
  shift
  local ecosystems=("$@")

  local config="version: 2\nupdates:"
  for eco in "${ecosystems[@]}"; do
    local directory="/"
    config="${config}\n  - package-ecosystem: \"${eco}\""
    config="${config}\n    directory: \"${directory}\""
    config="${config}\n    schedule:"
    config="${config}\n      interval: \"${schedule}\""
  done

  echo -e "$config"
}

cmd_dependabot_enable_main() {
  cmd_dependabot_enable_parse_args "$@"
  preflight_check

  if [ -z "$DEPENDABOT_TARGET" ]; then
    DEPENDABOT_TARGET=$(get_username)
    DEPENDABOT_TARGET_TYPE="user"
  fi

  echo -e "${BOLD}${CYAN}Dependabot Enable${NC} ${DIM}v${VERSION}${NC}"
  echo -e "${DIM}─────────────────────────────────────────────${NC}"
  echo -e "  Target:   ${BOLD}${DEPENDABOT_TARGET}${NC}"
  echo -e "  Schedule: ${BOLD}${DEPENDABOT_SCHEDULE}${NC}"
  if [ -n "$DEPENDABOT_ECOSYSTEMS" ]; then
    echo -e "  Ecosystems: ${BOLD}${DEPENDABOT_ECOSYSTEMS}${NC}"
  else
    echo -e "  Ecosystems: ${BOLD}auto-detect${NC}"
  fi
  if $DRY_RUN; then
    echo -e "  Mode:     ${YELLOW}DRY RUN${NC}"
  fi
  echo ""

  echo -e "${DIM}Fetching repos...${NC}"
  local repos_json
  repos_json=$(gh repo list "$DEPENDABOT_TARGET" --json nameWithOwner,primaryLanguage --source --no-archived --limit 9999 2>/dev/null) \
    || die "Failed to list repos"

  local total
  total=$(echo "$repos_json" | jq 'length')

  if [ "$total" -eq 0 ]; then
    echo -e "${GREEN}No repos found.${NC}"
    exit 0
  fi

  echo -e "Found ${BOLD}${total}${NC} repos"
  echo ""

  # Check each repo for existing dependabot config
  local to_enable=0 already=0 skipped=0
  local -a enable_repos=()
  local -a enable_ecosystems=()

  while IFS= read -r repo; do
    local nwo lang
    nwo=$(echo "$repo" | jq -r '.nameWithOwner')
    lang=$(echo "$repo" | jq -r '.primaryLanguage.name // empty')

    # Check if dependabot.yml already exists
    if gh api "repos/${nwo}/contents/.github/dependabot.yml" &>/dev/null; then
      already=$((already + 1))
      $VERBOSE && echo -e "  ${DIM}SKIP${NC}  ${nwo} ${DIM}(already has dependabot.yml)${NC}"
      continue
    fi

    # Determine ecosystems
    local -a repo_ecosystems=()
    if [ -n "$DEPENDABOT_ECOSYSTEMS" ]; then
      IFS=',' read -ra repo_ecosystems <<< "$DEPENDABOT_ECOSYSTEMS"
    else
      # Auto-detect from language
      if [ -n "$lang" ]; then
        local detected
        detected=$(cmd_dependabot_enable_detect_ecosystem "$lang")
        if [ -n "$detected" ]; then
          repo_ecosystems+=("$detected")
        fi
      fi
      # Always include github-actions
      repo_ecosystems+=("github-actions")
    fi

    if [ ${#repo_ecosystems[@]} -eq 0 ]; then
      skipped=$((skipped + 1))
      $VERBOSE && echo -e "  ${DIM}SKIP${NC}  ${nwo} ${DIM}(no ecosystem detected)${NC}"
      continue
    fi

    local eco_list
    eco_list=$(IFS=','; echo "${repo_ecosystems[*]}")

    to_enable=$((to_enable + 1))
    echo -e "  ${YELLOW}ENABLE${NC} ${nwo} ${DIM}(${eco_list})${NC}"

    # Store for later processing
    echo "${nwo}|${eco_list}" >> /tmp/gh-dependabot-enable-list.$$
  done < <(echo "$repos_json" | jq -c '.[]')

  echo ""

  local list_file="/tmp/gh-dependabot-enable-list.$$"
  if [ ! -f "$list_file" ] || [ ! -s "$list_file" ]; then
    echo -e "${GREEN}All repos already have Dependabot configured. Nothing to do.${NC}"
    rm -f "$list_file"
    exit 0
  fi

  local enable_count
  enable_count=$(wc -l < "$list_file" | tr -d ' ')

  if $DRY_RUN; then
    echo -e "${YELLOW}DRY RUN — no dependabot.yml files were created.${NC}"
    rm -f "$list_file"
    exit 0
  fi

  if ! confirm "Enable Dependabot on ${enable_count} repos?"; then
    echo "Cancelled."
    rm -f "$list_file"
    exit 0
  fi

  echo ""
  local success=0 fail=0
  while IFS='|' read -r nwo eco_list; do
    [ -z "$nwo" ] && continue

    IFS=',' read -ra ecosystems <<< "$eco_list"
    local config_content
    config_content=$(cmd_dependabot_enable_build_config "$DEPENDABOT_SCHEDULE" "${ecosystems[@]}")

    local encoded_content
    encoded_content=$(echo -e "$config_content" | base64 | tr -d '\n')

    if gh api -X PUT "repos/${nwo}/contents/.github/dependabot.yml" \
      -f message="Enable Dependabot updates" \
      -f content="$encoded_content" &>/dev/null; then
      success=$((success + 1))
      echo -e "  ${GREEN}CREATED${NC}  ${nwo}"
    else
      fail=$((fail + 1))
      echo -e "  ${RED}FAILED${NC}   ${nwo}"
    fi
  done < "$list_file"

  rm -f "$list_file"

  echo ""
  echo -e "${GREEN}Done!${NC}"
}

# =============================================================================
# COMMAND: mirror
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
MIRROR_REPO=""
MIRROR_TARGET=""
MIRROR_TARGET_TYPE=""
MIRROR_URL_TEMPLATE=""
MIRROR_DIR="/tmp/gh-mirror"

cmd_mirror_usage() {
  cat <<EOF
${BOLD}github-helpers mirror${NC} ${DIM}v${VERSION}${NC} — Mirror repos to another remote

${BOLD}USAGE${NC}
  github-helpers mirror --target URL_TEMPLATE [options]

${BOLD}OPTIONS${NC}
  --repo OWNER/REPO       Single source repo
  --user NAME             All repos from user (default: authenticated user)
  --org NAME              All repos from organization
  --target URL_TEMPLATE   Target URL with {name} placeholder
                          (e.g., git@gitlab.com:myorg/{name}.git)
  --dir PATH              Temp directory for bare clones
                          (default: /tmp/gh-mirror)
  --dry-run               Preview changes without applying
  -y, --yes               Skip confirmation prompt
  -v, --verbose           Show detailed output
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  # Mirror a single repo to GitLab
  github-helpers mirror --repo myuser/myrepo --target "git@gitlab.com:myorg/{name}.git"

  # Mirror all user repos (dry-run)
  github-helpers mirror --target "git@gitlab.com:myorg/{name}.git" --dry-run

  # Mirror an org's repos
  github-helpers mirror --org my-company --target "git@gitlab.com:backup/{name}.git" -y
EOF
  exit 0
}

cmd_mirror_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)      need_arg "--repo" "${2:-}"; MIRROR_REPO="$2"; shift 2 ;;
      --user)      need_arg "--user" "${2:-}"; MIRROR_TARGET="$2"; MIRROR_TARGET_TYPE="user"; shift 2 ;;
      --org)       need_arg "--org" "${2:-}"; MIRROR_TARGET="$2"; MIRROR_TARGET_TYPE="org"; shift 2 ;;
      --target)    need_arg "--target" "${2:-}"; MIRROR_URL_TEMPLATE="$2"; shift 2 ;;
      --dir)       need_arg "--dir" "${2:-}"; MIRROR_DIR="$2"; shift 2 ;;
      --dry-run)   DRY_RUN=true; shift ;;
      -y|--yes)    AUTO_YES=true; shift ;;
      -v|--verbose) VERBOSE=true; shift ;;
      -h|--help)   cmd_mirror_usage ;;
      *) die "mirror: unknown option: $1" ;;
    esac
  done

  if [ -z "$MIRROR_URL_TEMPLATE" ]; then
    die "mirror: --target URL_TEMPLATE is required"
  fi

  if [[ "$MIRROR_URL_TEMPLATE" != *"{name}"* ]]; then
    die "mirror: --target must contain {name} placeholder (e.g., git@gitlab.com:myorg/{name}.git)"
  fi
}

cmd_mirror_main() {
  cmd_mirror_parse_args "$@"
  preflight_check

  if ! command -v git &>/dev/null; then
    die "git is required for mirror"
  fi

  echo -e "${BOLD}${CYAN}Mirror Repos${NC} ${DIM}v${VERSION}${NC}"
  echo -e "${DIM}─────────────────────────────────────────────${NC}"
  echo -e "  Target template: ${BOLD}${MIRROR_URL_TEMPLATE}${NC}"
  echo -e "  Clone dir:       ${BOLD}${MIRROR_DIR}${NC}"
  if $DRY_RUN; then
    echo -e "  Mode:            ${YELLOW}DRY RUN${NC}"
  fi
  echo ""

  # Build repo list
  local repo_list_json
  if [ -n "$MIRROR_REPO" ]; then
    repo_list_json=$(gh api "repos/${MIRROR_REPO}" --jq '[{nameWithOwner: .full_name, name: .name, clone_url: .clone_url, ssh_url: .ssh_url}]' 2>/dev/null) \
      || die "Failed to fetch repo: ${MIRROR_REPO}"
  else
    if [ -z "$MIRROR_TARGET" ]; then
      MIRROR_TARGET=$(get_username)
      MIRROR_TARGET_TYPE="user"
    fi
    echo -e "  Source: ${BOLD}${MIRROR_TARGET}${NC}"
    echo ""
    echo -e "${DIM}Fetching repos...${NC}"
    repo_list_json=$(gh repo list "$MIRROR_TARGET" --json nameWithOwner,name,url --source --no-archived --limit 9999 2>/dev/null) \
      || die "Failed to list repos"
  fi

  local total
  total=$(echo "$repo_list_json" | jq 'length')

  if [ "$total" -eq 0 ]; then
    echo -e "${GREEN}No repos found.${NC}"
    exit 0
  fi

  echo -e "Found ${BOLD}${total}${NC} repos to mirror"
  echo ""

  echo -e "${BOLD}Repos:${NC}"
  echo "$repo_list_json" | jq -r '.[] | .nameWithOwner' | while IFS= read -r nwo; do
    local repo_name="${nwo#*/}"
    local target_url="${MIRROR_URL_TEMPLATE//\{name\}/$repo_name}"
    echo -e "  ${DIM}•${NC} ${nwo} → ${DIM}${target_url}${NC}"
  done
  echo ""

  if $DRY_RUN; then
    echo -e "${YELLOW}DRY RUN — no repos were mirrored.${NC}"
    exit 0
  fi

  if ! confirm "Mirror ${total} repos?"; then
    echo "Cancelled."
    exit 0
  fi

  # Create mirror directory
  mkdir -p "$MIRROR_DIR"

  local success=0 fail=0
  while IFS=$'\t' read -r nwo repo_name; do
    [ -z "$nwo" ] && continue

    local target_url="${MIRROR_URL_TEMPLATE//\{name\}/$repo_name}"
    local clone_path="${MIRROR_DIR}/${repo_name}.git"

    echo -e "  ${BOLD}${nwo}${NC}"

    # Clone bare
    $VERBOSE && echo -e "    ${DIM}Cloning bare...${NC}"
    rm -rf "$clone_path"
    if ! git_mirror_clone "$nwo" "$clone_path" 2>/dev/null; then
      fail=$((fail + 1))
      echo -e "    ${RED}FAILED${NC} (clone)"
      continue
    fi

    # Push mirror
    $VERBOSE && echo -e "    ${DIM}Pushing to ${target_url}...${NC}"
    if (cd "$clone_path" && git push --mirror "$target_url" 2>/dev/null); then
      success=$((success + 1))
      echo -e "    ${GREEN}MIRRORED${NC} → ${target_url}"
    else
      fail=$((fail + 1))
      echo -e "    ${RED}FAILED${NC} (push to ${target_url})"
    fi

    # Cleanup
    rm -rf "$clone_path"
  done < <(echo "$repo_list_json" | jq -r '.[] | "\(.nameWithOwner)\t\(.name)"')

  echo ""
  echo -e "${GREEN}Done!${NC} Mirrored: ${BOLD}${success}${NC}, Failed: ${BOLD}${fail}${NC}"
}

# =============================================================================
# COMMAND: release-cleanup
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
RELEASE_CLEANUP_REPO=""
RELEASE_CLEANUP_TARGET=""
RELEASE_CLEANUP_TARGET_TYPE=""
RELEASE_CLEANUP_KEEP=5
RELEASE_CLEANUP_PRE_ONLY=false

cmd_release_cleanup_usage() {
  cat <<EOF
${BOLD}github-helpers release-cleanup${NC} ${DIM}v${VERSION}${NC} — Delete old releases

${BOLD}USAGE${NC}
  github-helpers release-cleanup [options]

${BOLD}OPTIONS${NC}
  --repo OWNER/REPO       Single repo (required if no --user/--org)
  --user NAME             All repos from user
  --org NAME              All repos from organization
  --keep N                Number of releases to keep (default: 5)
  --pre-only              Only delete pre-releases
  --dry-run               Preview deletions without applying
  -y, --yes               Skip confirmation prompt
  -v, --verbose           Show detailed output
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  github-helpers release-cleanup --repo myuser/myrepo --keep 3 --dry-run
  github-helpers release-cleanup --repo myuser/myrepo --pre-only --keep 0
  github-helpers release-cleanup --org my-company --keep 10 --dry-run
  github-helpers release-cleanup --repo myuser/myrepo --keep 5 -y
EOF
  exit 0
}

cmd_release_cleanup_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)       need_arg "--repo" "${2:-}"; RELEASE_CLEANUP_REPO="$2"; shift 2 ;;
      --user)       need_arg "--user" "${2:-}"; RELEASE_CLEANUP_TARGET="$2"; RELEASE_CLEANUP_TARGET_TYPE="user"; shift 2 ;;
      --org)        need_arg "--org" "${2:-}"; RELEASE_CLEANUP_TARGET="$2"; RELEASE_CLEANUP_TARGET_TYPE="org"; shift 2 ;;
      --keep)       need_arg "--keep" "${2:-}"; RELEASE_CLEANUP_KEEP="$2"; shift 2 ;;
      --pre-only)   RELEASE_CLEANUP_PRE_ONLY=true; shift ;;
      --dry-run)    DRY_RUN=true; shift ;;
      -y|--yes)     AUTO_YES=true; shift ;;
      -v|--verbose) VERBOSE=true; shift ;;
      -h|--help)    cmd_release_cleanup_usage ;;
      *) die "release-cleanup: unknown option: $1" ;;
    esac
  done

  if [ -z "$RELEASE_CLEANUP_REPO" ] && [ -z "$RELEASE_CLEANUP_TARGET" ]; then
    die "release-cleanup: --repo, --user, or --org is required"
  fi

  if ! [[ "$RELEASE_CLEANUP_KEEP" =~ ^[0-9]+$ ]]; then
    die "release-cleanup: --keep must be a non-negative number"
  fi
}

cmd_release_cleanup_process_repo() {
  local nwo="$1"
  local keep="$2"
  local pre_only="$3"

  $VERBOSE && echo -e "  ${DIM}Fetching releases for ${nwo}...${NC}"

  # Fetch all releases (paginated up to 100)
  local releases_json
  releases_json=$(gh api "repos/${nwo}/releases?per_page=100" 2>/dev/null) || {
    echo -e "  ${RED}FAILED${NC}  Could not fetch releases for ${nwo}"
    return 1
  }

  # Sort by created_at desc (API already returns sorted, but be explicit)
  releases_json=$(echo "$releases_json" | jq 'sort_by(.created_at) | reverse')

  # If pre-only, filter to only pre-releases
  local target_releases
  if $pre_only; then
    target_releases=$(echo "$releases_json" | jq '[.[] | select(.prerelease == true)]')
  else
    target_releases=$(echo "$releases_json")
  fi

  local total_target
  total_target=$(echo "$target_releases" | jq 'length')

  if [ "$total_target" -le "$keep" ]; then
    $VERBOSE && echo -e "  ${DIM}${nwo}: ${total_target} releases (keeping ${keep}) — nothing to delete${NC}"
    return 0
  fi

  # Releases to delete: skip first $keep, take the rest
  local to_delete
  to_delete=$(echo "$target_releases" | jq --argjson keep "$keep" '.[$keep:]')

  local delete_count
  delete_count=$(echo "$to_delete" | jq 'length')

  echo -e "  ${BOLD}${nwo}${NC}: ${delete_count} releases to delete (keeping ${keep})"

  echo "$to_delete" | jq -c '.[]' | while IFS= read -r release; do
    local release_id tag_name prerelease created_at
    release_id=$(echo "$release" | jq -r '.id')
    tag_name=$(echo "$release" | jq -r '.tag_name')
    prerelease=$(echo "$release" | jq -r '.prerelease')
    created_at=$(echo "$release" | jq -r '.created_at')

    local pre_label=""
    if [ "$prerelease" = "true" ]; then
      pre_label=" ${YELLOW}(pre-release)${NC}"
    fi

    if $DRY_RUN; then
      echo -e "    ${YELLOW}WOULD DELETE${NC} ${tag_name} ${DIM}(${created_at%%T*})${NC}${pre_label}"
    else
      if gh api -X DELETE "repos/${nwo}/releases/${release_id}" &>/dev/null; then
        echo -e "    ${GREEN}DELETED${NC}  ${tag_name} ${DIM}(${created_at%%T*})${NC}${pre_label}"
      else
        echo -e "    ${RED}FAILED${NC}   ${tag_name}"
      fi
    fi
  done
}

cmd_release_cleanup_main() {
  cmd_release_cleanup_parse_args "$@"
  preflight_check

  echo -e "${BOLD}${CYAN}Release Cleanup${NC} ${DIM}v${VERSION}${NC}"
  echo -e "${DIM}─────────────────────────────────────────────${NC}"
  echo -e "  Keep:     ${BOLD}${RELEASE_CLEANUP_KEEP}${NC} latest releases"
  if $RELEASE_CLEANUP_PRE_ONLY; then
    echo -e "  Filter:   ${BOLD}pre-releases only${NC}"
  fi
  if $DRY_RUN; then
    echo -e "  Mode:     ${YELLOW}DRY RUN${NC}"
  fi
  echo ""

  # Build repo list
  local repo_nwos
  if [ -n "$RELEASE_CLEANUP_REPO" ]; then
    repo_nwos="$RELEASE_CLEANUP_REPO"
  else
    if [ -z "$RELEASE_CLEANUP_TARGET" ]; then
      RELEASE_CLEANUP_TARGET=$(get_username)
      RELEASE_CLEANUP_TARGET_TYPE="user"
    fi
    echo -e "  Target: ${BOLD}${RELEASE_CLEANUP_TARGET}${NC}"
    echo ""
    echo -e "${DIM}Fetching repos...${NC}"
    repo_nwos=$(gh repo list "$RELEASE_CLEANUP_TARGET" --json nameWithOwner --source --no-archived --limit 9999 2>/dev/null \
      | jq -r '.[].nameWithOwner') || die "Failed to list repos"
  fi
  echo ""

  # First pass: collect info about what will be deleted
  local total_to_delete=0
  tmpfile=$(mktemp)
  trap 'rm -f "${tmpfile:-}"' EXIT

  while IFS= read -r nwo; do
    [ -z "$nwo" ] && continue

    local releases_json
    releases_json=$(gh api "repos/${nwo}/releases?per_page=100" 2>/dev/null || echo "[]")
    releases_json=$(echo "$releases_json" | jq 'sort_by(.created_at) | reverse')

    local target_releases
    if $RELEASE_CLEANUP_PRE_ONLY; then
      target_releases=$(echo "$releases_json" | jq '[.[] | select(.prerelease == true)]')
    else
      target_releases=$(echo "$releases_json")
    fi

    local total_target
    total_target=$(echo "$target_releases" | jq 'length')

    if [ "$total_target" -gt "$RELEASE_CLEANUP_KEEP" ]; then
      local delete_count=$((total_target - RELEASE_CLEANUP_KEEP))
      total_to_delete=$((total_to_delete + delete_count))
      echo "$nwo" >> "$tmpfile"
    else
      $VERBOSE && echo -e "  ${DIM}${nwo}: ${total_target} releases — nothing to delete${NC}"
    fi
  done <<< "$repo_nwos"

  if [ "$total_to_delete" -eq 0 ]; then
    echo -e "${GREEN}No releases to clean up.${NC}"
    exit 0
  fi

  local repo_count
  repo_count=$(wc -l < "$tmpfile" | tr -d ' ')
  echo -e "${YELLOW}Found ${total_to_delete} releases to delete across ${repo_count} repos${NC}"
  echo ""

  if ! confirm "Delete ${total_to_delete} releases?"; then
    echo "Cancelled."
    exit 0
  fi
  echo ""

  # Second pass: process each repo
  while IFS= read -r nwo; do
    [ -z "$nwo" ] && continue
    cmd_release_cleanup_process_repo "$nwo" "$RELEASE_CLEANUP_KEEP" "$RELEASE_CLEANUP_PRE_ONLY"
  done < "$tmpfile"

  echo ""
  if $DRY_RUN; then
    echo -e "${YELLOW}DRY RUN — no releases were deleted.${NC}"
  else
    echo -e "${GREEN}Done!${NC}"
  fi
}

# =============================================================================
# COMMAND: vulnerability-check
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
VULN_CHECK_TARGET=""
VULN_CHECK_TARGET_TYPE=""
VULN_CHECK_REPO=""
VULN_CHECK_SEVERITY=""
VULN_CHECK_LIMIT=9999

cmd_vulnerability_check_usage() {
  cat <<EOF
${BOLD}github-helpers vulnerability-check${NC} ${DIM}v${VERSION}${NC} — Audit Dependabot vulnerability alerts

${BOLD}USAGE${NC}
  github-helpers vulnerability-check [options]

${BOLD}OPTIONS${NC}
  --repo OWNER/REPO       Single repo
  --user NAME             Target user (default: authenticated user)
  --org NAME              Target organization
  --severity LEVEL        Filter: critical, high, medium, low
  --limit N               Max repos to scan (default: all)
  -v, --verbose           Show individual alert details
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  github-helpers vulnerability-check
  github-helpers vulnerability-check --org my-company --severity critical
  github-helpers vulnerability-check --repo myuser/myrepo -v
EOF
  exit 0
}

cmd_vulnerability_check_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)      need_arg "--repo" "${2:-}"; VULN_CHECK_REPO="$2"; shift 2 ;;
      --user)      need_arg "--user" "${2:-}"; VULN_CHECK_TARGET="$2"; VULN_CHECK_TARGET_TYPE="user"; shift 2 ;;
      --org)       need_arg "--org" "${2:-}"; VULN_CHECK_TARGET="$2"; VULN_CHECK_TARGET_TYPE="org"; shift 2 ;;
      --severity)  need_arg "--severity" "${2:-}"; VULN_CHECK_SEVERITY="$2"; shift 2 ;;
      --limit)     need_arg "--limit" "${2:-}"; VULN_CHECK_LIMIT="$2"; shift 2 ;;
      -v|--verbose) VERBOSE=true; shift ;;
      -h|--help)   cmd_vulnerability_check_usage ;;
      *) die "vulnerability-check: unknown option: $1" ;;
    esac
  done
}

cmd_vulnerability_check_main() {
  cmd_vulnerability_check_parse_args "$@"
  preflight_check

  echo -e "${BOLD}${CYAN}Vulnerability Check${NC} ${DIM}v${VERSION}${NC}"
  echo -e "${DIM}─────────────────────────────────────────────${NC}"

  local repo_list
  if [ -n "$VULN_CHECK_REPO" ]; then
    repo_list="$VULN_CHECK_REPO"
    echo -e "  Repo: ${BOLD}${VULN_CHECK_REPO}${NC}"
  else
    if [ -z "$VULN_CHECK_TARGET" ]; then
      VULN_CHECK_TARGET=$(get_username)
      VULN_CHECK_TARGET_TYPE="user"
    fi
    echo -e "  Target: ${BOLD}${VULN_CHECK_TARGET}${NC}"
    [ -n "$VULN_CHECK_SEVERITY" ] && echo -e "  Severity: ${BOLD}${VULN_CHECK_SEVERITY}${NC}"
    echo ""
    echo -e "${DIM}Fetching repos...${NC}"
    repo_list=$(gh repo list "$VULN_CHECK_TARGET" --json nameWithOwner --source --no-archived --limit "${VULN_CHECK_LIMIT:-9999}" 2>/dev/null \
      | jq -r '.[].nameWithOwner') || die "Failed to list repos"
  fi
  echo ""

  local total_repos=0 repos_with_vulns=0
  local total_critical=0 total_high=0 total_medium=0 total_low=0

  while IFS= read -r nwo; do
    [ -z "$nwo" ] && continue
    total_repos=$((total_repos + 1))

    local query="state=open&per_page=100"
    [ -n "$VULN_CHECK_SEVERITY" ] && query="${query}&severity=${VULN_CHECK_SEVERITY}"

    local alerts_json
    alerts_json=$(gh api "repos/${nwo}/dependabot/alerts?${query}" 2>/dev/null) || {
      $VERBOSE && echo -e "  ${DIM}${nwo}: alerts not enabled or no access${NC}"
      continue
    }

    local alert_count
    alert_count=$(echo "$alerts_json" | jq 'if type == "array" then length else 0 end')

    if [ "$alert_count" -eq 0 ]; then
      $VERBOSE && echo -e "  ${GREEN}✓${NC} ${nwo}"
      continue
    fi

    repos_with_vulns=$((repos_with_vulns + 1))

    local critical high medium low
    critical=$(echo "$alerts_json" | jq '[.[] | select(.security_vulnerability.severity == "critical")] | length')
    high=$(echo "$alerts_json" | jq '[.[] | select(.security_vulnerability.severity == "high")] | length')
    medium=$(echo "$alerts_json" | jq '[.[] | select(.security_vulnerability.severity == "medium")] | length')
    low=$(echo "$alerts_json" | jq '[.[] | select(.security_vulnerability.severity == "low")] | length')

    total_critical=$((total_critical + critical))
    total_high=$((total_high + high))
    total_medium=$((total_medium + medium))
    total_low=$((total_low + low))

    local severity_str=""
    [ "$critical" -gt 0 ] && severity_str+="${RED}${critical} critical${NC} "
    [ "$high" -gt 0 ] && severity_str+="${YELLOW}${high} high${NC} "
    [ "$medium" -gt 0 ] && severity_str+="${CYAN}${medium} medium${NC} "
    [ "$low" -gt 0 ] && severity_str+="${DIM}${low} low${NC} "

    echo -e "  ${YELLOW}!${NC} ${BOLD}${nwo}${NC} — ${severity_str}"

    if $VERBOSE; then
      echo "$alerts_json" | jq -r '.[] | "\(.security_vulnerability.severity)\t\(.security_advisory.summary // .security_vulnerability.package.name)"' | \
        while IFS=$'\t' read -r sev summary; do
          case "$sev" in
            critical) echo -e "      ${RED}●${NC} ${summary}" ;;
            high)     echo -e "      ${YELLOW}●${NC} ${summary}" ;;
            medium)   echo -e "      ${CYAN}●${NC} ${summary}" ;;
            *)        echo -e "      ${DIM}●${NC} ${summary}" ;;
          esac
        done
    fi
  done <<< "$repo_list"

  echo ""
  echo -e "${DIM}─────────────────────────────────────────────${NC}"
  echo -e "${BOLD}Summary:${NC}"
  echo -e "  Repos scanned:      ${BOLD}${total_repos}${NC}"
  echo -e "  Repos with alerts:  ${BOLD}${repos_with_vulns}${NC}"
  if [ $((total_critical + total_high + total_medium + total_low)) -gt 0 ]; then
    echo -e "  Critical:           ${RED}${total_critical}${NC}"
    echo -e "  High:               ${YELLOW}${total_high}${NC}"
    echo -e "  Medium:             ${CYAN}${total_medium}${NC}"
    echo -e "  Low:                ${DIM}${total_low}${NC}"
  fi
  echo ""
}

# =============================================================================
# COMMAND: branch-protection
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
BRANCH_PROT_TARGET=""
BRANCH_PROT_TARGET_TYPE=""
BRANCH_PROT_REPO=""
BRANCH_PROT_ENFORCE=false
BRANCH_PROT_REVIEWS=1
BRANCH_PROT_STATUS_CHECKS=false
BRANCH_PROT_NO_FORCE_PUSH=true

cmd_branch_protection_usage() {
  cat <<EOF
${BOLD}github-helpers branch-protection${NC} ${DIM}v${VERSION}${NC} — Audit or enforce branch protection rules

${BOLD}USAGE${NC}
  github-helpers branch-protection [options]

${BOLD}OPTIONS${NC}
  --repo OWNER/REPO       Single repo
  --user NAME             Target user (default: authenticated user)
  --org NAME              Target organization
  --enforce               Apply protection rules (default: audit only)
  --require-reviews N     Required approving reviews (default: 1)
  --require-status-checks Require status checks to pass
  --allow-force-push      Allow force push (default: disallow)
  --dry-run               Preview enforcement changes
  -y, --yes               Skip confirmation prompt
  -v, --verbose           Show detailed protection info
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  github-helpers branch-protection
  github-helpers branch-protection --org my-company
  github-helpers branch-protection --enforce --require-reviews 2 --dry-run
  github-helpers branch-protection --repo myuser/myrepo --enforce -y
EOF
  exit 0
}

cmd_branch_protection_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)                   need_arg "--repo" "${2:-}"; BRANCH_PROT_REPO="$2"; shift 2 ;;
      --user)                   need_arg "--user" "${2:-}"; BRANCH_PROT_TARGET="$2"; BRANCH_PROT_TARGET_TYPE="user"; shift 2 ;;
      --org)                    need_arg "--org" "${2:-}"; BRANCH_PROT_TARGET="$2"; BRANCH_PROT_TARGET_TYPE="org"; shift 2 ;;
      --enforce)                BRANCH_PROT_ENFORCE=true; shift ;;
      --require-reviews)        need_arg "--require-reviews" "${2:-}"; BRANCH_PROT_REVIEWS="$2"; shift 2 ;;
      --require-status-checks)  BRANCH_PROT_STATUS_CHECKS=true; shift ;;
      --allow-force-push)       BRANCH_PROT_NO_FORCE_PUSH=false; shift ;;
      --dry-run)                DRY_RUN=true; shift ;;
      -y|--yes)                 AUTO_YES=true; shift ;;
      -v|--verbose)             VERBOSE=true; shift ;;
      -h|--help)                cmd_branch_protection_usage ;;
      *) die "branch-protection: unknown option: $1" ;;
    esac
  done
}

cmd_branch_protection_main() {
  cmd_branch_protection_parse_args "$@"
  preflight_check

  echo -e "${BOLD}${CYAN}Branch Protection${NC} ${DIM}v${VERSION}${NC}"
  echo -e "${DIM}─────────────────────────────────────────────${NC}"

  local repo_list
  if [ -n "$BRANCH_PROT_REPO" ]; then
    repo_list="$BRANCH_PROT_REPO"
    echo -e "  Repo: ${BOLD}${BRANCH_PROT_REPO}${NC}"
  else
    if [ -z "$BRANCH_PROT_TARGET" ]; then
      BRANCH_PROT_TARGET=$(get_username)
      BRANCH_PROT_TARGET_TYPE="user"
    fi
    echo -e "  Target: ${BOLD}${BRANCH_PROT_TARGET}${NC}"
    echo ""
    echo -e "${DIM}Fetching repos...${NC}"
    repo_list=$(gh repo list "$BRANCH_PROT_TARGET" --json nameWithOwner --source --no-archived --limit 9999 2>/dev/null \
      | jq -r '.[].nameWithOwner') || die "Failed to list repos"
  fi
  if $BRANCH_PROT_ENFORCE; then
    echo -e "  Mode: ${YELLOW}ENFORCE${NC}"
    echo -e "  Reviews: ${BOLD}${BRANCH_PROT_REVIEWS}${NC}"
    $BRANCH_PROT_STATUS_CHECKS && echo -e "  Status checks: ${BOLD}required${NC}"
    $BRANCH_PROT_NO_FORCE_PUSH && echo -e "  Force push: ${BOLD}disallowed${NC}"
    if $DRY_RUN; then
      echo -e "  Run: ${YELLOW}DRY RUN${NC}"
    fi
  else
    echo -e "  Mode: ${BOLD}audit${NC}"
  fi
  echo ""

  local total_repos=0 protected=0 unprotected=0
  tmpfile=$(mktemp)
  trap 'rm -f "${tmpfile:-}"' EXIT

  while IFS= read -r nwo; do
    [ -z "$nwo" ] && continue
    total_repos=$((total_repos + 1))

    # Get default branch
    local default_branch
    default_branch=$(gh api "repos/${nwo}" --jq '.default_branch' 2>/dev/null) || {
      echo -e "  ${RED}FAILED${NC}  ${nwo} ${DIM}(could not fetch repo info)${NC}"
      continue
    }

    # Check protection
    local prot_json
    if prot_json=$(gh api "repos/${nwo}/branches/${default_branch}/protection" 2>/dev/null); then
      protected=$((protected + 1))
      if $VERBOSE; then
        local reviews_required force_push_allowed
        reviews_required=$(echo "$prot_json" | jq -r '.required_pull_request_reviews.required_approving_review_count // "none"')
        force_push_allowed=$(echo "$prot_json" | jq -r '.allow_force_pushes.enabled // false')
        echo -e "  ${GREEN}✓${NC} ${nwo} ${DIM}(${default_branch}: reviews=${reviews_required}, force-push=${force_push_allowed})${NC}"
      fi
    else
      unprotected=$((unprotected + 1))
      echo "${nwo}|${default_branch}" >> "$tmpfile"
      echo -e "  ${YELLOW}!${NC} ${BOLD}${nwo}${NC} — ${RED}no protection${NC} on ${default_branch}"
    fi
  done <<< "$repo_list"

  echo ""

  # Enforce mode
  if $BRANCH_PROT_ENFORCE && [ -s "$tmpfile" ]; then
    local enforce_count
    enforce_count=$(wc -l < "$tmpfile" | tr -d ' ')
    echo -e "${YELLOW}${enforce_count} repos need protection${NC}"
    echo ""

    if ! confirm "Apply branch protection to ${enforce_count} repos?"; then
      echo "Cancelled."
      exit 0
    fi
    echo ""

    while IFS='|' read -r nwo branch; do
      [ -z "$nwo" ] && continue

      if $DRY_RUN; then
        echo -e "  ${YELLOW}WOULD PROTECT${NC} ${nwo} (${branch})"
        continue
      fi

      local payload
      payload=$(jq -n \
        --argjson reviews "$BRANCH_PROT_REVIEWS" \
        --argjson status_checks "$BRANCH_PROT_STATUS_CHECKS" \
        --argjson no_force_push "$BRANCH_PROT_NO_FORCE_PUSH" \
        '{
          required_pull_request_reviews: { required_approving_review_count: $reviews, dismiss_stale_reviews: false },
          enforce_admins: true,
          required_status_checks: (if $status_checks then { strict: true, contexts: [] } else null end),
          restrictions: null,
          allow_force_pushes: (if $no_force_push then false else true end),
          allow_deletions: false
        }')

      if gh api -X PUT "repos/${nwo}/branches/${branch}/protection" --input - <<< "$payload" &>/dev/null; then
        echo -e "  ${GREEN}PROTECTED${NC} ${nwo} (${branch})"
      else
        echo -e "  ${RED}FAILED${NC}    ${nwo}"
      fi
    done < "$tmpfile"

    echo ""
  fi

  echo -e "${DIM}─────────────────────────────────────────────${NC}"
  echo -e "${BOLD}Summary:${NC}"
  echo -e "  Repos scanned:    ${BOLD}${total_repos}${NC}"
  echo -e "  Protected:        ${GREEN}${protected}${NC}"
  echo -e "  Unprotected:      ${YELLOW}${unprotected}${NC}"
  if $DRY_RUN && $BRANCH_PROT_ENFORCE; then
    echo ""
    echo -e "${YELLOW}DRY RUN — no changes were applied.${NC}"
  fi
  echo ""
}

# =============================================================================
# COMMAND: stale-issues
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
STALE_ISSUES_TARGET=""
STALE_ISSUES_TARGET_TYPE=""
STALE_ISSUES_REPO=""
STALE_ISSUES_DAYS=90
STALE_ISSUES_TYPE="all"
STALE_ISSUES_LABEL=""
STALE_ISSUES_CLOSE=false
STALE_ISSUES_COMMENT=""

cmd_stale_issues_usage() {
  cat <<EOF
${BOLD}github-helpers stale-issues${NC} ${DIM}v${VERSION}${NC} — Find and close stale issues and PRs

${BOLD}USAGE${NC}
  github-helpers stale-issues [options]

${BOLD}OPTIONS${NC}
  --repo OWNER/REPO       Single repo
  --user NAME             Target user (default: authenticated user)
  --org NAME              Target organization
  --days N                Days without activity (default: 90)
  --type TYPE             Filter: issue, pr, all (default: all)
  --label LABEL           Filter by label
  --close                 Close stale issues/PRs
  --comment TEXT           Comment before closing (requires --close)
  --dry-run               Preview actions without applying
  -y, --yes               Skip confirmation prompt
  -v, --verbose           Show detailed output
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  github-helpers stale-issues --repo myuser/myrepo --days 180
  github-helpers stale-issues --org my-company --type pr --days 60
  github-helpers stale-issues --repo myuser/myrepo --close --comment "Closing as stale" --dry-run
EOF
  exit 0
}

cmd_stale_issues_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)      need_arg "--repo" "${2:-}"; STALE_ISSUES_REPO="$2"; shift 2 ;;
      --user)      need_arg "--user" "${2:-}"; STALE_ISSUES_TARGET="$2"; STALE_ISSUES_TARGET_TYPE="user"; shift 2 ;;
      --org)       need_arg "--org" "${2:-}"; STALE_ISSUES_TARGET="$2"; STALE_ISSUES_TARGET_TYPE="org"; shift 2 ;;
      --days)      need_arg "--days" "${2:-}"; STALE_ISSUES_DAYS="$2"; shift 2 ;;
      --type)      need_arg "--type" "${2:-}"; STALE_ISSUES_TYPE="$2"; shift 2 ;;
      --label)     need_arg "--label" "${2:-}"; STALE_ISSUES_LABEL="$2"; shift 2 ;;
      --close)     STALE_ISSUES_CLOSE=true; shift ;;
      --comment)   need_arg "--comment" "${2:-}"; STALE_ISSUES_COMMENT="$2"; shift 2 ;;
      --dry-run)   DRY_RUN=true; shift ;;
      -y|--yes)    AUTO_YES=true; shift ;;
      -v|--verbose) VERBOSE=true; shift ;;
      -h|--help)   cmd_stale_issues_usage ;;
      *) die "stale-issues: unknown option: $1" ;;
    esac
  done
}

cmd_stale_issues_process_repo() {
  local nwo="$1"
  local cutoff="$2"

  # Process issues
  if [ "$STALE_ISSUES_TYPE" = "all" ] || [ "$STALE_ISSUES_TYPE" = "issue" ]; then
    local -a issue_flags=(--repo "$nwo" --state open --json number,title,updatedAt --limit 200)
    [ -n "$STALE_ISSUES_LABEL" ] && issue_flags+=(--label "$STALE_ISSUES_LABEL")

    local issues_json
    issues_json=$(gh issue list "${issue_flags[@]}" 2>/dev/null || echo "[]")

    echo "$issues_json" | jq -c --arg cutoff "$cutoff" '.[] | select(.updatedAt < $cutoff)' | while IFS= read -r item; do
      local number title updated
      number=$(echo "$item" | jq -r '.number')
      title=$(echo "$item" | jq -r '.title')
      updated=$(echo "$item" | jq -r '.updatedAt[:10]')

      if $STALE_ISSUES_CLOSE; then
        if $DRY_RUN; then
          echo -e "      ${YELLOW}WOULD CLOSE${NC} #${number} ${DIM}(issue, last activity ${updated})${NC} ${title}"
        else
          [ -n "$STALE_ISSUES_COMMENT" ] && gh issue comment "$number" --repo "$nwo" --body "$STALE_ISSUES_COMMENT" &>/dev/null
          if gh issue close "$number" --repo "$nwo" &>/dev/null; then
            echo -e "      ${GREEN}CLOSED${NC} #${number} ${DIM}(issue, ${updated})${NC} ${title}"
          else
            echo -e "      ${RED}FAILED${NC} #${number} ${title}"
          fi
        fi
      else
        echo -e "      ${DIM}#${number}${NC} ${title} ${DIM}(issue, last activity ${updated})${NC}"
      fi
    done
  fi

  # Process PRs
  if [ "$STALE_ISSUES_TYPE" = "all" ] || [ "$STALE_ISSUES_TYPE" = "pr" ]; then
    local -a pr_flags=(--repo "$nwo" --state open --json number,title,updatedAt --limit 200)
    [ -n "$STALE_ISSUES_LABEL" ] && pr_flags+=(--label "$STALE_ISSUES_LABEL")

    local prs_json
    prs_json=$(gh pr list "${pr_flags[@]}" 2>/dev/null || echo "[]")

    echo "$prs_json" | jq -c --arg cutoff "$cutoff" '.[] | select(.updatedAt < $cutoff)' | while IFS= read -r item; do
      local number title updated
      number=$(echo "$item" | jq -r '.number')
      title=$(echo "$item" | jq -r '.title')
      updated=$(echo "$item" | jq -r '.updatedAt[:10]')

      if $STALE_ISSUES_CLOSE; then
        if $DRY_RUN; then
          echo -e "      ${YELLOW}WOULD CLOSE${NC} #${number} ${DIM}(PR, last activity ${updated})${NC} ${title}"
        else
          [ -n "$STALE_ISSUES_COMMENT" ] && gh pr comment "$number" --repo "$nwo" --body "$STALE_ISSUES_COMMENT" &>/dev/null
          if gh pr close "$number" --repo "$nwo" &>/dev/null; then
            echo -e "      ${GREEN}CLOSED${NC} #${number} ${DIM}(PR, ${updated})${NC} ${title}"
          else
            echo -e "      ${RED}FAILED${NC} #${number} ${title}"
          fi
        fi
      else
        echo -e "      ${DIM}#${number}${NC} ${title} ${DIM}(PR, last activity ${updated})${NC}"
      fi
    done
  fi
}

cmd_stale_issues_main() {
  cmd_stale_issues_parse_args "$@"
  preflight_check

  echo -e "${BOLD}${CYAN}Stale Issues${NC} ${DIM}v${VERSION}${NC}"
  echo -e "${DIM}─────────────────────────────────────────────${NC}"
  echo -e "  Stale after: ${BOLD}${STALE_ISSUES_DAYS}${NC} days"
  echo -e "  Type:        ${BOLD}${STALE_ISSUES_TYPE}${NC}"
  if $STALE_ISSUES_CLOSE; then
    echo -e "  Action:      ${YELLOW}close${NC}"
  else
    echo -e "  Action:      ${BOLD}list only${NC}"
  fi
  if $DRY_RUN; then
    echo -e "  Mode:        ${YELLOW}DRY RUN${NC}"
  fi
  echo ""

  local cutoff
  cutoff=$(cutoff_date "$STALE_ISSUES_DAYS" days)

  local repo_list
  if [ -n "$STALE_ISSUES_REPO" ]; then
    repo_list="$STALE_ISSUES_REPO"
  else
    if [ -z "$STALE_ISSUES_TARGET" ]; then
      STALE_ISSUES_TARGET=$(get_username)
      STALE_ISSUES_TARGET_TYPE="user"
    fi
    echo -e "  Target: ${BOLD}${STALE_ISSUES_TARGET}${NC}"
    echo ""
    echo -e "${DIM}Fetching repos...${NC}"
    repo_list=$(gh repo list "$STALE_ISSUES_TARGET" --json nameWithOwner --source --no-archived --limit 9999 2>/dev/null \
      | jq -r '.[].nameWithOwner') || die "Failed to list repos"
  fi
  echo ""

  if $STALE_ISSUES_CLOSE && ! confirm "Close stale issues/PRs?"; then
    echo "Cancelled."
    exit 0
  fi
  echo ""

  while IFS= read -r nwo; do
    [ -z "$nwo" ] && continue
    echo -e "  ${BOLD}${nwo}${NC}"
    cmd_stale_issues_process_repo "$nwo" "$cutoff"
  done <<< "$repo_list"

  echo ""
  if $DRY_RUN; then
    echo -e "${YELLOW}DRY RUN — no changes were applied.${NC}"
  else
    echo -e "${GREEN}Done!${NC}"
  fi
}

# =============================================================================
# COMMAND: bulk-settings
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
BULK_SETTINGS_TARGET=""
BULK_SETTINGS_TARGET_TYPE=""
BULK_SETTINGS_LANGUAGE=""
BULK_SETTINGS_TOPIC=""
BULK_SETTINGS_PATTERN=""
BULK_SETTINGS_WIKI=""
BULK_SETTINGS_ISSUES=""
BULK_SETTINGS_PROJECTS=""
BULK_SETTINGS_DISCUSSIONS=""
BULK_SETTINGS_AUTO_MERGE=""
BULK_SETTINGS_DELETE_BRANCH=""

cmd_bulk_settings_usage() {
  cat <<EOF
${BOLD}github-helpers bulk-settings${NC} ${DIM}v${VERSION}${NC} — Apply repo settings in batch

${BOLD}USAGE${NC}
  github-helpers bulk-settings <setting-flags> [options]

${BOLD}SETTINGS${NC}
  --enable-wiki               Enable wiki
  --disable-wiki              Disable wiki
  --enable-issues             Enable issues
  --disable-issues            Disable issues
  --enable-projects           Enable projects
  --disable-projects          Disable projects
  --enable-discussions        Enable discussions
  --disable-discussions       Disable discussions
  --enable-auto-merge         Enable auto-merge
  --disable-auto-merge        Disable auto-merge
  --enable-delete-branch      Enable delete branch on merge
  --disable-delete-branch     Disable delete branch on merge

${BOLD}OPTIONS${NC}
  --user NAME             Target user (default: authenticated user)
  --org NAME              Target organization
  --language LANG         Filter by primary language
  --topic TOPIC           Filter by topic
  --pattern PATTERN       Filter by repo name (grep regex)
  --dry-run               Preview changes without applying
  -y, --yes               Skip confirmation prompt
  -v, --verbose           Show detailed output
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  github-helpers bulk-settings --disable-wiki --language TypeScript --dry-run
  github-helpers bulk-settings --enable-delete-branch --enable-auto-merge --org my-company
  github-helpers bulk-settings --disable-projects --disable-wiki --topic archived --dry-run
EOF
  exit 0
}

cmd_bulk_settings_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --user)                   need_arg "--user" "${2:-}"; BULK_SETTINGS_TARGET="$2"; BULK_SETTINGS_TARGET_TYPE="user"; shift 2 ;;
      --org)                    need_arg "--org" "${2:-}"; BULK_SETTINGS_TARGET="$2"; BULK_SETTINGS_TARGET_TYPE="org"; shift 2 ;;
      --language)               need_arg "--language" "${2:-}"; BULK_SETTINGS_LANGUAGE="$2"; shift 2 ;;
      --topic)                  need_arg "--topic" "${2:-}"; BULK_SETTINGS_TOPIC="$2"; shift 2 ;;
      --pattern)                need_arg "--pattern" "${2:-}"; BULK_SETTINGS_PATTERN="$2"; shift 2 ;;
      --enable-wiki)            BULK_SETTINGS_WIKI=true; shift ;;
      --disable-wiki)           BULK_SETTINGS_WIKI=false; shift ;;
      --enable-issues)          BULK_SETTINGS_ISSUES=true; shift ;;
      --disable-issues)         BULK_SETTINGS_ISSUES=false; shift ;;
      --enable-projects)        BULK_SETTINGS_PROJECTS=true; shift ;;
      --disable-projects)       BULK_SETTINGS_PROJECTS=false; shift ;;
      --enable-discussions)     BULK_SETTINGS_DISCUSSIONS=true; shift ;;
      --disable-discussions)    BULK_SETTINGS_DISCUSSIONS=false; shift ;;
      --enable-auto-merge)      BULK_SETTINGS_AUTO_MERGE=true; shift ;;
      --disable-auto-merge)     BULK_SETTINGS_AUTO_MERGE=false; shift ;;
      --enable-delete-branch)   BULK_SETTINGS_DELETE_BRANCH=true; shift ;;
      --disable-delete-branch)  BULK_SETTINGS_DELETE_BRANCH=false; shift ;;
      --dry-run)                DRY_RUN=true; shift ;;
      -y|--yes)                 AUTO_YES=true; shift ;;
      -v|--verbose)             VERBOSE=true; shift ;;
      -h|--help)                cmd_bulk_settings_usage ;;
      *) die "bulk-settings: unknown option: $1" ;;
    esac
  done

  if [ -z "$BULK_SETTINGS_WIKI" ] && [ -z "$BULK_SETTINGS_ISSUES" ] && \
     [ -z "$BULK_SETTINGS_PROJECTS" ] && [ -z "$BULK_SETTINGS_DISCUSSIONS" ] && \
     [ -z "$BULK_SETTINGS_AUTO_MERGE" ] && [ -z "$BULK_SETTINGS_DELETE_BRANCH" ]; then
    die "bulk-settings: at least one --enable-* or --disable-* flag is required"
  fi
}

cmd_bulk_settings_main() {
  cmd_bulk_settings_parse_args "$@"
  preflight_check

  echo -e "${BOLD}${CYAN}Bulk Settings${NC} ${DIM}v${VERSION}${NC}"
  echo -e "${DIM}─────────────────────────────────────────────${NC}"

  echo -e "  ${BOLD}Changes:${NC}"
  [ -n "$BULK_SETTINGS_WIKI" ]          && echo -e "    Wiki:             ${BOLD}${BULK_SETTINGS_WIKI}${NC}"
  [ -n "$BULK_SETTINGS_ISSUES" ]        && echo -e "    Issues:           ${BOLD}${BULK_SETTINGS_ISSUES}${NC}"
  [ -n "$BULK_SETTINGS_PROJECTS" ]      && echo -e "    Projects:         ${BOLD}${BULK_SETTINGS_PROJECTS}${NC}"
  [ -n "$BULK_SETTINGS_DISCUSSIONS" ]   && echo -e "    Discussions:      ${BOLD}${BULK_SETTINGS_DISCUSSIONS}${NC}"
  [ -n "$BULK_SETTINGS_AUTO_MERGE" ]    && echo -e "    Auto-merge:       ${BOLD}${BULK_SETTINGS_AUTO_MERGE}${NC}"
  [ -n "$BULK_SETTINGS_DELETE_BRANCH" ] && echo -e "    Delete branch:    ${BOLD}${BULK_SETTINGS_DELETE_BRANCH}${NC}"
  if $DRY_RUN; then
    echo -e "  Mode: ${YELLOW}DRY RUN${NC}"
  fi
  echo ""

  if [ -z "$BULK_SETTINGS_TARGET" ]; then
    BULK_SETTINGS_TARGET=$(get_username)
    BULK_SETTINGS_TARGET_TYPE="user"
  fi
  echo -e "  Target: ${BOLD}${BULK_SETTINGS_TARGET}${NC}"
  echo ""

  echo -e "${DIM}Fetching repos...${NC}"
  local -a flags=("--json" "nameWithOwner" "--source" "--no-archived" "--limit" "9999")
  [ -n "$BULK_SETTINGS_LANGUAGE" ] && flags+=("--language" "$BULK_SETTINGS_LANGUAGE")
  [ -n "$BULK_SETTINGS_TOPIC" ]    && flags+=("--topic" "$BULK_SETTINGS_TOPIC")

  local repo_list
  repo_list=$(gh repo list "$BULK_SETTINGS_TARGET" "${flags[@]}" 2>/dev/null \
    | jq -r '.[].nameWithOwner') || die "Failed to list repos"

  if [ -n "$BULK_SETTINGS_PATTERN" ]; then
    repo_list=$(echo "$repo_list" | grep -E "$BULK_SETTINGS_PATTERN" || true)
  fi

  local total
  total=$(printf '%s\n' "$repo_list" | awk 'NF {n++} END {printf "%d", n + 0}')

  if [ "$total" -eq 0 ]; then
    echo -e "${GREEN}No repos found.${NC}"
    exit 0
  fi

  echo -e "Found ${BOLD}${total}${NC} repos"
  echo ""

  if ! confirm "Apply settings to ${total} repos?"; then
    echo "Cancelled."
    exit 0
  fi
  echo ""

  # Build API args (use -F for JSON booleans)
  local -a api_args=()
  [ -n "$BULK_SETTINGS_WIKI" ]          && api_args+=("-F" "has_wiki=${BULK_SETTINGS_WIKI}")
  [ -n "$BULK_SETTINGS_ISSUES" ]        && api_args+=("-F" "has_issues=${BULK_SETTINGS_ISSUES}")
  [ -n "$BULK_SETTINGS_PROJECTS" ]      && api_args+=("-F" "has_projects=${BULK_SETTINGS_PROJECTS}")
  [ -n "$BULK_SETTINGS_DISCUSSIONS" ]   && api_args+=("-F" "has_discussions=${BULK_SETTINGS_DISCUSSIONS}")
  [ -n "$BULK_SETTINGS_AUTO_MERGE" ]    && api_args+=("-F" "allow_auto_merge=${BULK_SETTINGS_AUTO_MERGE}")
  [ -n "$BULK_SETTINGS_DELETE_BRANCH" ] && api_args+=("-F" "delete_branch_on_merge=${BULK_SETTINGS_DELETE_BRANCH}")

  local success=0 fail=0
  while IFS= read -r nwo; do
    [ -z "$nwo" ] && continue

    if $DRY_RUN; then
      echo -e "  ${YELLOW}WOULD UPDATE${NC} ${nwo}"
      continue
    fi

    if gh api -X PATCH "repos/${nwo}" "${api_args[@]}" &>/dev/null; then
      success=$((success + 1))
      echo -e "  ${GREEN}UPDATED${NC} ${nwo}"
    else
      fail=$((fail + 1))
      echo -e "  ${RED}FAILED${NC}  ${nwo}"
    fi
  done <<< "$repo_list"

  echo ""
  if $DRY_RUN; then
    echo -e "${YELLOW}DRY RUN — no changes were applied.${NC}"
  else
    echo -e "${GREEN}Done!${NC} Updated: ${BOLD}${success}${NC}, Failed: ${BOLD}${fail}${NC}"
  fi
}

# =============================================================================
# COMMAND: webhook-audit
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
WEBHOOK_AUDIT_TARGET=""
WEBHOOK_AUDIT_TARGET_TYPE=""
WEBHOOK_AUDIT_REPO=""
WEBHOOK_AUDIT_LIMIT=9999

cmd_webhook_audit_usage() {
  cat <<EOF
${BOLD}github-helpers webhook-audit${NC} ${DIM}v${VERSION}${NC} — List webhooks across repos

${BOLD}USAGE${NC}
  github-helpers webhook-audit [options]

${BOLD}OPTIONS${NC}
  --repo OWNER/REPO       Single repo
  --user NAME             Target user (default: authenticated user)
  --org NAME              Target organization
  --limit N               Max repos to scan (default: all)
  -v, --verbose           Show event list and last response
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  github-helpers webhook-audit
  github-helpers webhook-audit --org my-company -v
  github-helpers webhook-audit --repo myuser/myrepo
EOF
  exit 0
}

cmd_webhook_audit_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)      need_arg "--repo" "${2:-}"; WEBHOOK_AUDIT_REPO="$2"; shift 2 ;;
      --user)      need_arg "--user" "${2:-}"; WEBHOOK_AUDIT_TARGET="$2"; WEBHOOK_AUDIT_TARGET_TYPE="user"; shift 2 ;;
      --org)       need_arg "--org" "${2:-}"; WEBHOOK_AUDIT_TARGET="$2"; WEBHOOK_AUDIT_TARGET_TYPE="org"; shift 2 ;;
      --limit)     need_arg "--limit" "${2:-}"; WEBHOOK_AUDIT_LIMIT="$2"; shift 2 ;;
      -v|--verbose) VERBOSE=true; shift ;;
      -h|--help)   cmd_webhook_audit_usage ;;
      *) die "webhook-audit: unknown option: $1" ;;
    esac
  done
}

cmd_webhook_audit_main() {
  cmd_webhook_audit_parse_args "$@"
  preflight_check

  echo -e "${BOLD}${CYAN}Webhook Audit${NC} ${DIM}v${VERSION}${NC}"
  echo -e "${DIM}─────────────────────────────────────────────${NC}"

  local repo_list
  if [ -n "$WEBHOOK_AUDIT_REPO" ]; then
    repo_list="$WEBHOOK_AUDIT_REPO"
    echo -e "  Repo: ${BOLD}${WEBHOOK_AUDIT_REPO}${NC}"
  else
    if [ -z "$WEBHOOK_AUDIT_TARGET" ]; then
      WEBHOOK_AUDIT_TARGET=$(get_username)
      WEBHOOK_AUDIT_TARGET_TYPE="user"
    fi
    echo -e "  Target: ${BOLD}${WEBHOOK_AUDIT_TARGET}${NC}"
    echo ""
    echo -e "${DIM}Fetching repos...${NC}"
    repo_list=$(gh repo list "$WEBHOOK_AUDIT_TARGET" --json nameWithOwner --source --no-archived --limit "${WEBHOOK_AUDIT_LIMIT:-9999}" 2>/dev/null \
      | jq -r '.[].nameWithOwner') || die "Failed to list repos"
  fi
  echo ""

  local total_repos=0 repos_with_hooks=0 total_hooks=0 inactive_hooks=0

  while IFS= read -r nwo; do
    [ -z "$nwo" ] && continue
    total_repos=$((total_repos + 1))

    local hooks_json
    hooks_json=$(gh api "repos/${nwo}/hooks" 2>/dev/null || echo "[]")

    local hook_count
    hook_count=$(echo "$hooks_json" | jq 'if type == "array" then length else 0 end')

    if [ "$hook_count" -eq 0 ]; then
      $VERBOSE && echo -e "  ${DIM}${nwo}: no webhooks${NC}"
      continue
    fi

    repos_with_hooks=$((repos_with_hooks + 1))
    total_hooks=$((total_hooks + hook_count))

    # Count inactive hooks via jq (avoids subshell counter issue)
    local repo_inactive
    repo_inactive=$(echo "$hooks_json" | jq '[.[] | select(.active == false or (.last_response.code != null and .last_response.code != 200 and .last_response.code != 0))] | length')
    inactive_hooks=$((inactive_hooks + repo_inactive))

    echo -e "  ${BOLD}${nwo}${NC} ${DIM}(${hook_count} hooks)${NC}"

    echo "$hooks_json" | jq -c '.[]' | while IFS= read -r hook; do
      local url active last_status
      url=$(echo "$hook" | jq -r '.config.url // "unknown"')
      active=$(echo "$hook" | jq -r '.active')
      last_status=$(echo "$hook" | jq -r '.last_response.code // 0')

      local status_icon
      if [ "$active" = "true" ]; then
        if [ "$last_status" = "200" ] || [ "$last_status" = "0" ]; then
          status_icon="${GREEN}●${NC}"
        else
          status_icon="${YELLOW}●${NC}"
        fi
      else
        status_icon="${RED}●${NC}"
      fi

      echo -e "    ${status_icon} ${url}"
      if $VERBOSE; then
        local events
        events=$(echo "$hook" | jq -r '.events | join(", ")')
        echo -e "      ${DIM}Events: ${events}${NC}"
        echo -e "      ${DIM}Active: ${active}, Last response: ${last_status}${NC}"
      fi
    done
    echo ""
  done <<< "$repo_list"

  echo -e "${DIM}─────────────────────────────────────────────${NC}"
  echo -e "${BOLD}Summary:${NC}"
  echo -e "  Repos scanned:      ${BOLD}${total_repos}${NC}"
  echo -e "  Repos with hooks:   ${BOLD}${repos_with_hooks}${NC}"
  echo -e "  Total webhooks:     ${BOLD}${total_hooks}${NC}"
  echo -e "  Inactive/failing:   ${YELLOW}${inactive_hooks}${NC}"
  echo ""
}

# =============================================================================
# COMMAND: cleanup-packages
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
CLEANUP_PKG_TARGET=""
CLEANUP_PKG_TARGET_TYPE=""
CLEANUP_PKG_TYPE=""
CLEANUP_PKG_PACKAGE=""
CLEANUP_PKG_KEEP=5

cmd_cleanup_packages_usage() {
  cat <<EOF
${BOLD}github-helpers cleanup-packages${NC} ${DIM}v${VERSION}${NC} — Delete old GitHub Package versions

${BOLD}USAGE${NC}
  github-helpers cleanup-packages [options]

${BOLD}OPTIONS${NC}
  --user NAME             Target user (default: authenticated user)
  --org NAME              Target organization
  --type TYPE             Package type: npm, maven, rubygems, docker, nuget, container (required)
  --package NAME          Specific package name (default: all)
  --keep N                Versions to keep per package (default: 5)
  --dry-run               Preview deletions without applying
  -y, --yes               Skip confirmation prompt
  -v, --verbose           Show detailed output
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  github-helpers cleanup-packages --type container --keep 3 --dry-run
  github-helpers cleanup-packages --org my-company --type npm --keep 10
  github-helpers cleanup-packages --type container --package myapp --keep 1
EOF
  exit 0
}

cmd_cleanup_packages_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --user)      need_arg "--user" "${2:-}"; CLEANUP_PKG_TARGET="$2"; CLEANUP_PKG_TARGET_TYPE="user"; shift 2 ;;
      --org)       need_arg "--org" "${2:-}"; CLEANUP_PKG_TARGET="$2"; CLEANUP_PKG_TARGET_TYPE="org"; shift 2 ;;
      --type)      need_arg "--type" "${2:-}"; CLEANUP_PKG_TYPE="$2"; shift 2 ;;
      --package)   need_arg "--package" "${2:-}"; CLEANUP_PKG_PACKAGE="$2"; shift 2 ;;
      --keep)      need_arg "--keep" "${2:-}"; CLEANUP_PKG_KEEP="$2"; shift 2 ;;
      --dry-run)   DRY_RUN=true; shift ;;
      -y|--yes)    AUTO_YES=true; shift ;;
      -v|--verbose) VERBOSE=true; shift ;;
      -h|--help)   cmd_cleanup_packages_usage ;;
      *) die "cleanup-packages: unknown option: $1" ;;
    esac
  done

  [ -z "$CLEANUP_PKG_TYPE" ] && die "cleanup-packages: --type is required"
  ! [[ "$CLEANUP_PKG_KEEP" =~ ^[0-9]+$ ]] && die "cleanup-packages: --keep must be a non-negative number"
}

cmd_cleanup_packages_main() {
  cmd_cleanup_packages_parse_args "$@"
  preflight_check

  if [ -z "$CLEANUP_PKG_TARGET" ]; then
    CLEANUP_PKG_TARGET=$(get_username)
    CLEANUP_PKG_TARGET_TYPE="user"
  fi

  echo -e "${BOLD}${CYAN}Cleanup Packages${NC} ${DIM}v${VERSION}${NC}"
  echo -e "${DIM}─────────────────────────────────────────────${NC}"
  echo -e "  Target: ${BOLD}${CLEANUP_PKG_TARGET}${NC}"
  echo -e "  Type:   ${BOLD}${CLEANUP_PKG_TYPE}${NC}"
  echo -e "  Keep:   ${BOLD}${CLEANUP_PKG_KEEP}${NC} versions"
  if $DRY_RUN; then
    echo -e "  Mode:   ${YELLOW}DRY RUN${NC}"
  fi
  echo ""

  # Build API base path
  local api_base
  if [ "$CLEANUP_PKG_TARGET_TYPE" = "org" ]; then
    api_base="orgs/${CLEANUP_PKG_TARGET}"
  else
    api_base="users/${CLEANUP_PKG_TARGET}"
  fi

  echo -e "${DIM}Fetching packages...${NC}"
  local packages_json
  if [ -n "$CLEANUP_PKG_PACKAGE" ]; then
    packages_json=$(gh api "${api_base}/packages/${CLEANUP_PKG_TYPE}/${CLEANUP_PKG_PACKAGE}" 2>/dev/null \
      | jq '[.]') || die "Failed to fetch package: ${CLEANUP_PKG_PACKAGE}"
  else
    packages_json=$(gh api "${api_base}/packages?package_type=${CLEANUP_PKG_TYPE}&per_page=100" 2>/dev/null) \
      || die "Failed to list packages"
  fi

  local pkg_count
  pkg_count=$(echo "$packages_json" | jq 'length')

  if [ "$pkg_count" -eq 0 ]; then
    echo -e "${GREEN}No packages found.${NC}"
    exit 0
  fi

  echo -e "Found ${BOLD}${pkg_count}${NC} packages"
  echo ""

  if ! confirm "Clean up old versions (keeping ${CLEANUP_PKG_KEEP} per package)?"; then
    echo "Cancelled."
    exit 0
  fi
  echo ""

  echo "$packages_json" | jq -r '.[].name' | while IFS= read -r pkg_name; do
    [ -z "$pkg_name" ] && continue

    # URL-encode package name (replace / with %2F for container packages)
    local encoded_name="${pkg_name//\//%2F}"

    local versions_json
    versions_json=$(gh api "${api_base}/packages/${CLEANUP_PKG_TYPE}/${encoded_name}/versions?per_page=100" 2>/dev/null || echo "[]")

    local ver_count
    ver_count=$(echo "$versions_json" | jq 'length')

    if [ "$ver_count" -le "$CLEANUP_PKG_KEEP" ]; then
      $VERBOSE && echo -e "  ${DIM}${pkg_name}: ${ver_count} versions (keeping all)${NC}"
      continue
    fi

    local to_delete=$((ver_count - CLEANUP_PKG_KEEP))
    echo -e "  ${BOLD}${pkg_name}${NC}: ${ver_count} versions, deleting ${to_delete}"

    # Versions are returned newest first; skip $KEEP, delete rest
    echo "$versions_json" | jq -c ".[$CLEANUP_PKG_KEEP:][]" | while IFS= read -r version; do
      local ver_id ver_name created
      ver_id=$(echo "$version" | jq -r '.id')
      ver_name=$(echo "$version" | jq -r '.metadata.container.tags[0] // .name // "unknown"')
      created=$(echo "$version" | jq -r '.created_at[:10]')

      if $DRY_RUN; then
        echo -e "    ${YELLOW}WOULD DELETE${NC} ${ver_name} ${DIM}(${created})${NC}"
      else
        if gh api -X DELETE "${api_base}/packages/${CLEANUP_PKG_TYPE}/${encoded_name}/versions/${ver_id}" &>/dev/null; then
          echo -e "    ${GREEN}DELETED${NC} ${ver_name} ${DIM}(${created})${NC}"
        else
          echo -e "    ${RED}FAILED${NC}  ${ver_name}"
        fi
      fi
    done
  done

  echo ""
  if $DRY_RUN; then
    echo -e "${YELLOW}DRY RUN — no versions were deleted.${NC}"
  else
    echo -e "${GREEN}Done!${NC}"
  fi
}

# =============================================================================
# COMMAND: collaborator-audit
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
COLLAB_AUDIT_TARGET=""
COLLAB_AUDIT_TARGET_TYPE=""
COLLAB_AUDIT_PERMISSION=""
COLLAB_AUDIT_LIMIT=9999

cmd_collaborator_audit_usage() {
  cat <<EOF
${BOLD}github-helpers collaborator-audit${NC} ${DIM}v${VERSION}${NC} — Audit outside collaborators and permissions

${BOLD}USAGE${NC}
  github-helpers collaborator-audit [options]

${BOLD}OPTIONS${NC}
  --org NAME              Target organization
  --user NAME             Target user
  --permission LEVEL      Filter: admin, write, read
  --limit N               Max repos to scan (default: all)
  -v, --verbose           Show repos with no outside collaborators
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  github-helpers collaborator-audit --org my-company
  github-helpers collaborator-audit --org my-company --permission admin
  github-helpers collaborator-audit --user myuser
EOF
  exit 0
}

cmd_collaborator_audit_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --org)        need_arg "--org" "${2:-}"; COLLAB_AUDIT_TARGET="$2"; COLLAB_AUDIT_TARGET_TYPE="org"; shift 2 ;;
      --user)       need_arg "--user" "${2:-}"; COLLAB_AUDIT_TARGET="$2"; COLLAB_AUDIT_TARGET_TYPE="user"; shift 2 ;;
      --permission) need_arg "--permission" "${2:-}"; COLLAB_AUDIT_PERMISSION="$2"; shift 2 ;;
      --limit)      need_arg "--limit" "${2:-}"; COLLAB_AUDIT_LIMIT="$2"; shift 2 ;;
      -v|--verbose) VERBOSE=true; shift ;;
      -h|--help)    cmd_collaborator_audit_usage ;;
      *) die "collaborator-audit: unknown option: $1" ;;
    esac
  done

  [ -z "$COLLAB_AUDIT_TARGET" ] && die "collaborator-audit: --org or --user is required"
}

cmd_collaborator_audit_main() {
  cmd_collaborator_audit_parse_args "$@"
  preflight_check

  echo -e "${BOLD}${CYAN}Collaborator Audit${NC} ${DIM}v${VERSION}${NC}"
  echo -e "${DIM}─────────────────────────────────────────────${NC}"
  echo -e "  Target: ${BOLD}${COLLAB_AUDIT_TARGET}${NC}"
  [ -n "$COLLAB_AUDIT_PERMISSION" ] && echo -e "  Permission: ${BOLD}${COLLAB_AUDIT_PERMISSION}${NC}"
  echo ""

  echo -e "${DIM}Fetching repos...${NC}"
  local repo_list
  repo_list=$(gh repo list "$COLLAB_AUDIT_TARGET" --json nameWithOwner --source --no-archived --limit "${COLLAB_AUDIT_LIMIT:-9999}" 2>/dev/null \
    | jq -r '.[].nameWithOwner') || die "Failed to list repos"
  echo ""

  local total_repos=0 repos_with_collabs=0 total_collabs=0

  while IFS= read -r nwo; do
    [ -z "$nwo" ] && continue
    total_repos=$((total_repos + 1))

    local query="affiliation=outside&per_page=100"
    [ -n "$COLLAB_AUDIT_PERMISSION" ] && query="${query}&permission=${COLLAB_AUDIT_PERMISSION}"

    local collabs_json
    collabs_json=$(gh api "repos/${nwo}/collaborators?${query}" 2>/dev/null || echo "[]")

    local collab_count
    collab_count=$(echo "$collabs_json" | jq 'if type == "array" then length else 0 end')

    if [ "$collab_count" -eq 0 ]; then
      $VERBOSE && echo -e "  ${DIM}${nwo}: no outside collaborators${NC}"
      continue
    fi

    repos_with_collabs=$((repos_with_collabs + 1))
    total_collabs=$((total_collabs + collab_count))

    echo -e "  ${BOLD}${nwo}${NC} ${DIM}(${collab_count} collaborators)${NC}"

    echo "$collabs_json" | jq -c '.[]' | while IFS= read -r collab; do
      local login role_name
      login=$(echo "$collab" | jq -r '.login')
      role_name=$(echo "$collab" | jq -r '.role_name // "unknown"')

      local perm_color
      case "$role_name" in
        admin) perm_color="$RED" ;;
        write|maintain) perm_color="$YELLOW" ;;
        *)     perm_color="$DIM" ;;
      esac

      echo -e "    ${perm_color}${role_name}${NC}\t${login}"
    done
    echo ""
  done <<< "$repo_list"

  echo -e "${DIM}─────────────────────────────────────────────${NC}"
  echo -e "${BOLD}Summary:${NC}"
  echo -e "  Repos scanned:            ${BOLD}${total_repos}${NC}"
  echo -e "  Repos with collaborators: ${BOLD}${repos_with_collabs}${NC}"
  echo -e "  Total collaborators:      ${BOLD}${total_collabs}${NC}"
  echo ""
}

# =============================================================================
# COMMAND: repo-template
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
REPO_TEMPLATE_FROM=""
REPO_TEMPLATE_TARGET=""
REPO_TEMPLATE_TARGET_TYPE=""
REPO_TEMPLATE_LANGUAGE=""
REPO_TEMPLATE_TOPIC=""
REPO_TEMPLATE_SYNC_SETTINGS=false
REPO_TEMPLATE_SYNC_LABELS=false
REPO_TEMPLATE_SYNC_PROTECTION=false

cmd_repo_template_usage() {
  cat <<EOF
${BOLD}github-helpers repo-template${NC} ${DIM}v${VERSION}${NC} — Sync settings from a template repo

${BOLD}USAGE${NC}
  github-helpers repo-template --from OWNER/REPO [options]

${BOLD}OPTIONS${NC}
  --from OWNER/REPO       Template repo to copy from (required)
  --user NAME             Target user (default: authenticated user)
  --org NAME              Target organization
  --language LANG         Filter target repos by language
  --topic TOPIC           Filter target repos by topic
  --sync-settings         Sync repo settings (wiki, issues, projects, etc.)
  --sync-labels           Sync issue labels
  --sync-protection       Sync branch protection rules
  --all                   Sync everything (settings + labels + protection)
  --dry-run               Preview changes without applying
  -y, --yes               Skip confirmation prompt
  -v, --verbose           Show detailed output
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  github-helpers repo-template --from myuser/template --sync-labels --dry-run
  github-helpers repo-template --from myuser/template --all --org my-company
  github-helpers repo-template --from myuser/template --sync-settings --topic typescript
EOF
  exit 0
}

cmd_repo_template_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --from)            need_arg "--from" "${2:-}"; REPO_TEMPLATE_FROM="$2"; shift 2 ;;
      --user)            need_arg "--user" "${2:-}"; REPO_TEMPLATE_TARGET="$2"; REPO_TEMPLATE_TARGET_TYPE="user"; shift 2 ;;
      --org)             need_arg "--org" "${2:-}"; REPO_TEMPLATE_TARGET="$2"; REPO_TEMPLATE_TARGET_TYPE="org"; shift 2 ;;
      --language)        need_arg "--language" "${2:-}"; REPO_TEMPLATE_LANGUAGE="$2"; shift 2 ;;
      --topic)           need_arg "--topic" "${2:-}"; REPO_TEMPLATE_TOPIC="$2"; shift 2 ;;
      --sync-settings)   REPO_TEMPLATE_SYNC_SETTINGS=true; shift ;;
      --sync-labels)     REPO_TEMPLATE_SYNC_LABELS=true; shift ;;
      --sync-protection) REPO_TEMPLATE_SYNC_PROTECTION=true; shift ;;
      --all)             REPO_TEMPLATE_SYNC_SETTINGS=true; REPO_TEMPLATE_SYNC_LABELS=true; REPO_TEMPLATE_SYNC_PROTECTION=true; shift ;;
      --dry-run)         DRY_RUN=true; shift ;;
      -y|--yes)          AUTO_YES=true; shift ;;
      -v|--verbose)      VERBOSE=true; shift ;;
      -h|--help)         cmd_repo_template_usage ;;
      *) die "repo-template: unknown option: $1" ;;
    esac
  done

  [ -z "$REPO_TEMPLATE_FROM" ] && die "repo-template: --from is required"

  if ! $REPO_TEMPLATE_SYNC_SETTINGS && ! $REPO_TEMPLATE_SYNC_LABELS && ! $REPO_TEMPLATE_SYNC_PROTECTION; then
    die "repo-template: at least one --sync-* flag or --all is required"
  fi
}

cmd_repo_template_main() {
  cmd_repo_template_parse_args "$@"
  preflight_check

  echo -e "${BOLD}${CYAN}Repo Template${NC} ${DIM}v${VERSION}${NC}"
  echo -e "${DIM}─────────────────────────────────────────────${NC}"
  echo -e "  Template: ${BOLD}${REPO_TEMPLATE_FROM}${NC}"
  echo -e "  Sync:"
  $REPO_TEMPLATE_SYNC_SETTINGS   && echo -e "    ${BOLD}settings${NC}"
  $REPO_TEMPLATE_SYNC_LABELS     && echo -e "    ${BOLD}labels${NC}"
  $REPO_TEMPLATE_SYNC_PROTECTION && echo -e "    ${BOLD}branch protection${NC}"
  if $DRY_RUN; then
    echo -e "  Mode: ${YELLOW}DRY RUN${NC}"
  fi
  echo ""

  # Fetch template repo config
  echo -e "${DIM}Reading template repo...${NC}"

  local template_settings="" template_labels="" template_protection=""

  if $REPO_TEMPLATE_SYNC_SETTINGS; then
    template_settings=$(gh api "repos/${REPO_TEMPLATE_FROM}" --jq '{
      has_wiki, has_issues, has_projects, has_discussions,
      allow_auto_merge, delete_branch_on_merge, allow_squash_merge,
      allow_merge_commit, allow_rebase_merge
    }' 2>/dev/null) || die "Failed to fetch template settings"
    $VERBOSE && echo -e "  ${DIM}Settings loaded${NC}"
  fi

  if $REPO_TEMPLATE_SYNC_LABELS; then
    template_labels=$(gh api "repos/${REPO_TEMPLATE_FROM}/labels" --paginate 2>/dev/null) \
      || die "Failed to fetch template labels"
    local label_count
    label_count=$(echo "$template_labels" | jq 'length')
    $VERBOSE && echo -e "  ${DIM}${label_count} labels loaded${NC}"
  fi

  if $REPO_TEMPLATE_SYNC_PROTECTION; then
    local template_branch
    template_branch=$(gh api "repos/${REPO_TEMPLATE_FROM}" --jq '.default_branch' 2>/dev/null)
    template_protection=$(gh api "repos/${REPO_TEMPLATE_FROM}/branches/${template_branch}/protection" 2>/dev/null) || {
      echo -e "  ${YELLOW}Warning: template repo has no branch protection rules${NC}"
      REPO_TEMPLATE_SYNC_PROTECTION=false
    }
  fi
  echo ""

  # Get target repos
  if [ -z "$REPO_TEMPLATE_TARGET" ]; then
    REPO_TEMPLATE_TARGET=$(get_username)
    REPO_TEMPLATE_TARGET_TYPE="user"
  fi

  echo -e "  Target: ${BOLD}${REPO_TEMPLATE_TARGET}${NC}"
  echo ""

  local -a flags=("--json" "nameWithOwner" "--source" "--no-archived" "--limit" "9999")
  [ -n "$REPO_TEMPLATE_LANGUAGE" ] && flags+=("--language" "$REPO_TEMPLATE_LANGUAGE")
  [ -n "$REPO_TEMPLATE_TOPIC" ]    && flags+=("--topic" "$REPO_TEMPLATE_TOPIC")

  local repo_list
  repo_list=$(gh repo list "$REPO_TEMPLATE_TARGET" "${flags[@]}" 2>/dev/null \
    | jq -r '.[].nameWithOwner') || die "Failed to list repos"

  # Exclude template repo itself
  repo_list=$(echo "$repo_list" | grep -v "^${REPO_TEMPLATE_FROM}$" || true)

  local total
  total=$(printf '%s\n' "$repo_list" | awk 'NF {n++} END {printf "%d", n + 0}')

  if [ "$total" -eq 0 ]; then
    echo -e "${GREEN}No target repos found.${NC}"
    exit 0
  fi

  echo -e "Found ${BOLD}${total}${NC} target repos"
  echo ""

  if ! confirm "Apply template to ${total} repos?"; then
    echo "Cancelled."
    exit 0
  fi
  echo ""

  while IFS= read -r nwo; do
    [ -z "$nwo" ] && continue
    echo -e "  ${BOLD}${nwo}${NC}"

    # Sync settings
    if $REPO_TEMPLATE_SYNC_SETTINGS; then
      if $DRY_RUN; then
        echo -e "    ${YELLOW}WOULD SYNC${NC} settings"
      else
        if gh api -X PATCH "repos/${nwo}" --input - <<< "$template_settings" &>/dev/null; then
          echo -e "    ${GREEN}SYNCED${NC} settings"
        else
          echo -e "    ${RED}FAILED${NC} settings"
        fi
      fi
    fi

    # Sync labels
    if $REPO_TEMPLATE_SYNC_LABELS; then
      if $DRY_RUN; then
        echo -e "    ${YELLOW}WOULD SYNC${NC} labels"
      else
        echo "$template_labels" | jq -c '.[]' | while IFS= read -r label; do
          local lname lcolor ldesc
          lname=$(echo "$label" | jq -r '.name')
          lcolor=$(echo "$label" | jq -r '.color')
          ldesc=$(echo "$label" | jq -r '.description // ""')

          # URL-encode label name for API path (spaces, special chars)
          local encoded_lname
          encoded_lname=$(printf '%s' "$lname" | jq -sRr @uri)

          # Try to update first, then create
          if ! gh api -X PATCH "repos/${nwo}/labels/${encoded_lname}" \
            -f color="$lcolor" -f description="$ldesc" &>/dev/null; then
            gh api -X POST "repos/${nwo}/labels" \
              -f name="$lname" -f color="$lcolor" -f description="$ldesc" &>/dev/null || true
          fi
        done
        echo -e "    ${GREEN}SYNCED${NC} labels"
      fi
    fi

    # Sync branch protection
    if $REPO_TEMPLATE_SYNC_PROTECTION; then
      local target_branch
      target_branch=$(gh api "repos/${nwo}" --jq '.default_branch' 2>/dev/null)

      if $DRY_RUN; then
        echo -e "    ${YELLOW}WOULD SYNC${NC} branch protection (${target_branch})"
      else
        local prot_payload
        prot_payload=$(echo "$template_protection" | jq '{
          required_pull_request_reviews: (if .required_pull_request_reviews then {
            required_approving_review_count: .required_pull_request_reviews.required_approving_review_count,
            dismiss_stale_reviews: .required_pull_request_reviews.dismiss_stale_reviews
          } else null end),
          required_status_checks: (if .required_status_checks then {
            strict: .required_status_checks.strict,
            contexts: .required_status_checks.contexts
          } else null end),
          enforce_admins: .enforce_admins.enabled,
          restrictions: null,
          allow_force_pushes: .allow_force_pushes.enabled,
          allow_deletions: .allow_deletions.enabled
        }')

        if gh api -X PUT "repos/${nwo}/branches/${target_branch}/protection" --input - <<< "$prot_payload" &>/dev/null; then
          echo -e "    ${GREEN}SYNCED${NC} branch protection (${target_branch})"
        else
          echo -e "    ${RED}FAILED${NC} branch protection"
        fi
      fi
    fi
  done <<< "$repo_list"

  echo ""
  if $DRY_RUN; then
    echo -e "${YELLOW}DRY RUN — no changes were applied.${NC}"
  else
    echo -e "${GREEN}Done!${NC}"
  fi
}

# =============================================================================
# COMMAND: pr-cleanup
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
PR_CLEANUP_TARGET=""
PR_CLEANUP_TARGET_TYPE=""
PR_CLEANUP_REPO=""
PR_CLEANUP_DAYS=90
PR_CLEANUP_DRAFT_ONLY=false
PR_CLEANUP_CLOSE=false
PR_CLEANUP_COMMENT=""
PR_CLEANUP_DELETE_BRANCH=false

cmd_pr_cleanup_usage() {
  cat <<EOF
${BOLD}github-helpers pr-cleanup${NC} ${DIM}v${VERSION}${NC} — Find and close abandoned pull requests

${BOLD}USAGE${NC}
  github-helpers pr-cleanup [options]

${BOLD}OPTIONS${NC}
  --repo OWNER/REPO       Single repo
  --user NAME             Target user (default: authenticated user)
  --org NAME              Target organization
  --days N                Days without activity (default: 90)
  --draft-only            Only target draft PRs
  --close                 Close abandoned PRs
  --comment TEXT           Comment before closing (requires --close)
  --delete-branch         Delete head branch after closing
  --dry-run               Preview actions without applying
  -y, --yes               Skip confirmation prompt
  -v, --verbose           Show detailed output
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  github-helpers pr-cleanup --repo myuser/myrepo --days 60
  github-helpers pr-cleanup --org my-company --draft-only --days 30
  github-helpers pr-cleanup --repo myuser/myrepo --close --delete-branch --dry-run
EOF
  exit 0
}

cmd_pr_cleanup_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)           need_arg "--repo" "${2:-}"; PR_CLEANUP_REPO="$2"; shift 2 ;;
      --user)           need_arg "--user" "${2:-}"; PR_CLEANUP_TARGET="$2"; PR_CLEANUP_TARGET_TYPE="user"; shift 2 ;;
      --org)            need_arg "--org" "${2:-}"; PR_CLEANUP_TARGET="$2"; PR_CLEANUP_TARGET_TYPE="org"; shift 2 ;;
      --days)           need_arg "--days" "${2:-}"; PR_CLEANUP_DAYS="$2"; shift 2 ;;
      --draft-only)     PR_CLEANUP_DRAFT_ONLY=true; shift ;;
      --close)          PR_CLEANUP_CLOSE=true; shift ;;
      --comment)        need_arg "--comment" "${2:-}"; PR_CLEANUP_COMMENT="$2"; shift 2 ;;
      --delete-branch)  PR_CLEANUP_DELETE_BRANCH=true; shift ;;
      --dry-run)        DRY_RUN=true; shift ;;
      -y|--yes)         AUTO_YES=true; shift ;;
      -v|--verbose)     VERBOSE=true; shift ;;
      -h|--help)        cmd_pr_cleanup_usage ;;
      *) die "pr-cleanup: unknown option: $1" ;;
    esac
  done
}

cmd_pr_cleanup_process_repo() {
  local nwo="$1"
  local cutoff="$2"

  local prs_json
  prs_json=$(gh pr list --repo "$nwo" --state open --json number,title,updatedAt,isDraft,headRefName --limit 200 2>/dev/null || echo "[]")

  # Filter by date and optionally by draft status
  local filter
  if $PR_CLEANUP_DRAFT_ONLY; then
    filter='select(.updatedAt < $cutoff and .isDraft == true)'
  else
    filter='select(.updatedAt < $cutoff)'
  fi

  local stale_prs
  stale_prs=$(echo "$prs_json" | jq -c --arg cutoff "$cutoff" "[.[] | ${filter}]")

  local stale_count
  stale_count=$(echo "$stale_prs" | jq 'length')

  if [ "$stale_count" -eq 0 ]; then
    $VERBOSE && echo -e "    ${DIM}no stale PRs${NC}"
    return
  fi

  echo "$stale_prs" | jq -c '.[]' | while IFS= read -r pr; do
    local number title updated is_draft head_branch
    number=$(echo "$pr" | jq -r '.number')
    title=$(echo "$pr" | jq -r '.title')
    updated=$(echo "$pr" | jq -r '.updatedAt[:10]')
    is_draft=$(echo "$pr" | jq -r '.isDraft')
    head_branch=$(echo "$pr" | jq -r '.headRefName')

    local draft_label=""
    [ "$is_draft" = "true" ] && draft_label=" ${DIM}[draft]${NC}"

    if $PR_CLEANUP_CLOSE; then
      if $DRY_RUN; then
        echo -e "    ${YELLOW}WOULD CLOSE${NC} #${number}${draft_label} ${DIM}(${updated})${NC} ${title}"
        $PR_CLEANUP_DELETE_BRANCH && echo -e "      ${YELLOW}WOULD DELETE${NC} branch ${head_branch}"
      else
        [ -n "$PR_CLEANUP_COMMENT" ] && gh pr comment "$number" --repo "$nwo" --body "$PR_CLEANUP_COMMENT" &>/dev/null
        if gh pr close "$number" --repo "$nwo" &>/dev/null; then
          echo -e "    ${GREEN}CLOSED${NC} #${number}${draft_label} ${DIM}(${updated})${NC} ${title}"
          if $PR_CLEANUP_DELETE_BRANCH; then
            if gh api -X DELETE "repos/${nwo}/git/refs/heads/${head_branch}" &>/dev/null; then
              echo -e "      ${GREEN}DELETED${NC} branch ${head_branch}"
            else
              echo -e "      ${DIM}branch ${head_branch} not deleted (may be from fork)${NC}"
            fi
          fi
        else
          echo -e "    ${RED}FAILED${NC} #${number} ${title}"
        fi
      fi
    else
      echo -e "    ${DIM}#${number}${NC}${draft_label} ${title} ${DIM}(last activity ${updated})${NC}"
    fi
  done
}

cmd_pr_cleanup_main() {
  cmd_pr_cleanup_parse_args "$@"
  preflight_check

  echo -e "${BOLD}${CYAN}PR Cleanup${NC} ${DIM}v${VERSION}${NC}"
  echo -e "${DIM}─────────────────────────────────────────────${NC}"
  echo -e "  Stale after: ${BOLD}${PR_CLEANUP_DAYS}${NC} days"
  $PR_CLEANUP_DRAFT_ONLY && echo -e "  Filter:      ${BOLD}draft only${NC}"
  if $PR_CLEANUP_CLOSE; then
    echo -e "  Action:      ${YELLOW}close${NC}"
    $PR_CLEANUP_DELETE_BRANCH && echo -e "  Branches:    ${YELLOW}delete${NC}"
  else
    echo -e "  Action:      ${BOLD}list only${NC}"
  fi
  if $DRY_RUN; then
    echo -e "  Mode:        ${YELLOW}DRY RUN${NC}"
  fi
  echo ""

  local cutoff
  cutoff=$(cutoff_date "$PR_CLEANUP_DAYS" days)

  local repo_list
  if [ -n "$PR_CLEANUP_REPO" ]; then
    repo_list="$PR_CLEANUP_REPO"
  else
    if [ -z "$PR_CLEANUP_TARGET" ]; then
      PR_CLEANUP_TARGET=$(get_username)
      PR_CLEANUP_TARGET_TYPE="user"
    fi
    echo -e "  Target: ${BOLD}${PR_CLEANUP_TARGET}${NC}"
    echo ""
    echo -e "${DIM}Fetching repos...${NC}"
    repo_list=$(gh repo list "$PR_CLEANUP_TARGET" --json nameWithOwner --source --no-archived --limit 9999 2>/dev/null \
      | jq -r '.[].nameWithOwner') || die "Failed to list repos"
  fi
  echo ""

  if $PR_CLEANUP_CLOSE && ! confirm "Close stale PRs?"; then
    echo "Cancelled."
    exit 0
  fi
  echo ""

  while IFS= read -r nwo; do
    [ -z "$nwo" ] && continue
    echo -e "  ${BOLD}${nwo}${NC}"
    cmd_pr_cleanup_process_repo "$nwo" "$cutoff"
  done <<< "$repo_list"

  echo ""
  if $DRY_RUN; then
    echo -e "${YELLOW}DRY RUN — no changes were applied.${NC}"
  else
    echo -e "${GREEN}Done!${NC}"
  fi
}

# =============================================================================
# COMMAND: activity-report
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
ACTIVITY_REPORT_TARGET=""
ACTIVITY_REPORT_TARGET_TYPE=""
ACTIVITY_REPORT_SINCE=""
ACTIVITY_REPORT_UNTIL=""
ACTIVITY_REPORT_FORMAT="text"

cmd_activity_report_usage() {
  cat <<EOF
${BOLD}github-helpers activity-report${NC} ${DIM}v${VERSION}${NC} — Generate activity summary for a period

${BOLD}USAGE${NC}
  github-helpers activity-report [options]

${BOLD}OPTIONS${NC}
  --user NAME             Target user (default: authenticated user)
  --org NAME              Target organization
  --since DATE            Start date YYYY-MM-DD (default: 30 days ago)
  --until DATE            End date YYYY-MM-DD (default: today)
  --format FORMAT         Output: text, json, csv (default: text)
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  github-helpers activity-report
  github-helpers activity-report --org my-company --since 2025-01-01
  github-helpers activity-report --since 2025-06-01 --until 2025-06-30 --format json
  github-helpers activity-report --user octocat --format csv
EOF
  exit 0
}

cmd_activity_report_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --user)    need_arg "--user" "${2:-}"; ACTIVITY_REPORT_TARGET="$2"; ACTIVITY_REPORT_TARGET_TYPE="user"; shift 2 ;;
      --org)     need_arg "--org" "${2:-}"; ACTIVITY_REPORT_TARGET="$2"; ACTIVITY_REPORT_TARGET_TYPE="org"; shift 2 ;;
      --since)   need_arg "--since" "${2:-}"; ACTIVITY_REPORT_SINCE="$2"; shift 2 ;;
      --until)   need_arg "--until" "${2:-}"; ACTIVITY_REPORT_UNTIL="$2"; shift 2 ;;
      --format)  need_arg "--format" "${2:-}"; ACTIVITY_REPORT_FORMAT="$2"; shift 2 ;;
      -h|--help) cmd_activity_report_usage ;;
      *) die "activity-report: unknown option: $1" ;;
    esac
  done
}

cmd_activity_report_main() {
  cmd_activity_report_parse_args "$@"
  preflight_check

  if [ -z "$ACTIVITY_REPORT_TARGET" ]; then
    ACTIVITY_REPORT_TARGET=$(get_username)
    ACTIVITY_REPORT_TARGET_TYPE="user"
  fi

  # Default dates
  if [ -z "$ACTIVITY_REPORT_SINCE" ]; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
      ACTIVITY_REPORT_SINCE=$(date -v-30d +"%Y-%m-%d")
    else
      ACTIVITY_REPORT_SINCE=$(date -d "30 days ago" +"%Y-%m-%d")
    fi
  fi
  [ -z "$ACTIVITY_REPORT_UNTIL" ] && ACTIVITY_REPORT_UNTIL=$(date +"%Y-%m-%d")

  if [ "$ACTIVITY_REPORT_FORMAT" = "text" ]; then
    echo -e "${BOLD}${CYAN}Activity Report${NC} ${DIM}v${VERSION}${NC}"
    echo -e "${DIM}─────────────────────────────────────────────${NC}"
    echo -e "  Target: ${BOLD}${ACTIVITY_REPORT_TARGET}${NC}"
    echo -e "  Period: ${BOLD}${ACTIVITY_REPORT_SINCE}${NC} → ${BOLD}${ACTIVITY_REPORT_UNTIL}${NC}"
    echo ""
    echo -e "${DIM}Fetching activity data...${NC}"
  fi

  # Build search qualifier
  local search_target
  if [ "$ACTIVITY_REPORT_TARGET_TYPE" = "org" ]; then
    search_target="org:${ACTIVITY_REPORT_TARGET}"
  else
    search_target="author:${ACTIVITY_REPORT_TARGET}"
  fi

  # Count repos (total + active)
  local repos_json
  repos_json=$(gh repo list "$ACTIVITY_REPORT_TARGET" --json nameWithOwner,pushedAt --source --no-archived --limit 9999 2>/dev/null) || repos_json="[]"
  local total_repos active_repos
  total_repos=$(echo "$repos_json" | jq 'length')
  active_repos=$(echo "$repos_json" | jq --arg since "${ACTIVITY_REPORT_SINCE}T00:00:00Z" '[.[] | select(.pushedAt >= $since)] | length')

  # PRs opened
  local prs_opened
  prs_opened=$(gh api "search/issues?q=${search_target}+is:pr+created:${ACTIVITY_REPORT_SINCE}..${ACTIVITY_REPORT_UNTIL}&per_page=1" 2>/dev/null \
    | jq '.total_count // 0' || echo "0")

  # PRs merged
  local prs_merged
  prs_merged=$(gh api "search/issues?q=${search_target}+is:pr+is:merged+merged:${ACTIVITY_REPORT_SINCE}..${ACTIVITY_REPORT_UNTIL}&per_page=1" 2>/dev/null \
    | jq '.total_count // 0' || echo "0")

  # Issues opened
  local issues_opened
  issues_opened=$(gh api "search/issues?q=${search_target}+is:issue+created:${ACTIVITY_REPORT_SINCE}..${ACTIVITY_REPORT_UNTIL}&per_page=1" 2>/dev/null \
    | jq '.total_count // 0' || echo "0")

  # Issues closed
  local issues_closed
  issues_closed=$(gh api "search/issues?q=${search_target}+is:issue+is:closed+closed:${ACTIVITY_REPORT_SINCE}..${ACTIVITY_REPORT_UNTIL}&per_page=1" 2>/dev/null \
    | jq '.total_count // 0' || echo "0")

  case "$ACTIVITY_REPORT_FORMAT" in
    json)
      jq -n \
        --arg target "$ACTIVITY_REPORT_TARGET" \
        --arg since "$ACTIVITY_REPORT_SINCE" \
        --arg until "$ACTIVITY_REPORT_UNTIL" \
        --argjson total_repos "$total_repos" \
        --argjson active_repos "$active_repos" \
        --argjson prs_opened "$prs_opened" \
        --argjson prs_merged "$prs_merged" \
        --argjson issues_opened "$issues_opened" \
        --argjson issues_closed "$issues_closed" \
        '{
          target: $target,
          period: { since: $since, until: $until },
          repos: { total: $total_repos, active: $active_repos },
          pull_requests: { opened: $prs_opened, merged: $prs_merged },
          issues: { opened: $issues_opened, closed: $issues_closed }
        }'
      ;;
    csv)
      echo "metric,value"
      echo "target,${ACTIVITY_REPORT_TARGET}"
      echo "period_since,${ACTIVITY_REPORT_SINCE}"
      echo "period_until,${ACTIVITY_REPORT_UNTIL}"
      echo "total_repos,${total_repos}"
      echo "active_repos,${active_repos}"
      echo "prs_opened,${prs_opened}"
      echo "prs_merged,${prs_merged}"
      echo "issues_opened,${issues_opened}"
      echo "issues_closed,${issues_closed}"
      ;;
    text)
      echo ""
      echo -e "  ${BOLD}Repositories${NC}"
      echo -e "    Total:          ${BOLD}${total_repos}${NC}"
      echo -e "    Active:         ${BOLD}${active_repos}${NC} ${DIM}(pushed during period)${NC}"
      echo ""
      echo -e "  ${BOLD}Pull Requests${NC}"
      echo -e "    Opened:         ${BOLD}${prs_opened}${NC}"
      echo -e "    Merged:         ${BOLD}${prs_merged}${NC}"
      echo ""
      echo -e "  ${BOLD}Issues${NC}"
      echo -e "    Opened:         ${BOLD}${issues_opened}${NC}"
      echo -e "    Closed:         ${BOLD}${issues_closed}${NC}"
      echo ""
      ;;
    *) die "activity-report: unknown format: ${ACTIVITY_REPORT_FORMAT} (use text, json, or csv)" ;;
  esac
}

# =============================================================================
# COMMAND: sync-forks
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
SYNC_FORKS_TARGET=""
SYNC_FORKS_TARGET_TYPE=""
SYNC_FORKS_REPO=""
SYNC_FORKS_BRANCH=""
SYNC_FORKS_LIMIT=1000

cmd_sync_forks_usage() {
  cat <<EOF
${BOLD}github-helpers sync-forks${NC} ${DIM}v${VERSION}${NC} — Update your forks from their upstream

${BOLD}USAGE${NC}
  github-helpers sync-forks [options]

${BOLD}OPTIONS${NC}
  --user NAME             Target user (default: authenticated user)
  --org NAME              Target organization
  --repo OWNER/NAME       Sync a single fork
  --branch NAME           Branch to sync (default: each fork's default branch)
  --limit N               Max forks to examine (default: ${SYNC_FORKS_LIMIT})
  --dry-run               Show what would be synced, change nothing
  -v, --verbose           Also list forks that are already up to date
  -h, --help              Show this help

${BOLD}RESULTS${NC}
  SYNCED      Fast-forwarded (or merged) from the upstream
  UP-TO-DATE  Already level with the upstream — no request sent
  CONFLICT    Upstream cannot be merged automatically; resolve it locally
  SKIPPED     Archived fork, or the upstream is gone or private

${BOLD}EXAMPLES${NC}
  github-helpers sync-forks --dry-run
  github-helpers sync-forks
  github-helpers sync-forks --repo me/my-fork --branch main
  github-helpers sync-forks --org my-company --limit 50

${BOLD}NOTE${NC}
  This only fast-forwards or merges FROM the upstream, so it never discards
  your work and needs no confirmation. Use --dry-run to preview.
EOF
  exit 0
}

cmd_sync_forks_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --user)       need_arg "--user" "${2:-}"; SYNC_FORKS_TARGET="$2"; SYNC_FORKS_TARGET_TYPE="user"; shift 2 ;;
      --org)        need_arg "--org" "${2:-}"; SYNC_FORKS_TARGET="$2"; SYNC_FORKS_TARGET_TYPE="org"; shift 2 ;;
      --repo)       need_arg "--repo" "${2:-}"; SYNC_FORKS_REPO="$2"; shift 2 ;;
      --branch)     need_arg "--branch" "${2:-}"; SYNC_FORKS_BRANCH="$2"; shift 2 ;;
      --limit)      need_arg "--limit" "${2:-}"; SYNC_FORKS_LIMIT="$2"; shift 2 ;;
      --dry-run)    DRY_RUN=true; shift ;;
      -y|--yes)     AUTO_YES=true; shift ;;
      -v|--verbose) VERBOSE=true; shift ;;
      -h|--help)    cmd_sync_forks_usage ;;
      *) die "sync-forks: unknown option: $1" ;;
    esac
  done

  [[ "$SYNC_FORKS_LIMIT" =~ ^[0-9]+$ ]] || die "sync-forks: --limit must be a whole number"
  if [ -n "$SYNC_FORKS_REPO" ] && [[ "$SYNC_FORKS_REPO" != */* ]]; then
    die "sync-forks: --repo must be OWNER/NAME"
  fi
}

# cmd_sync_forks_one <nwo> <branch> -> "<STATUS>\t<detail>"
cmd_sync_forks_one() {
  local nwo="$1" branch="$2" body rc=0 errfile err merge_type
  errfile=$(mktemp)
  body=$(gh_api_retry --method POST "repos/${nwo}/merge-upstream" -f branch="$branch" 2>"$errfile") || rc=$?
  err=$(cat "$errfile" 2>/dev/null || true)
  rm -f "$errfile"

  if [ "$rc" -eq 0 ]; then
    merge_type=$(printf '%s' "$body" | jq -r '.merge_type // "unknown"' 2>/dev/null || echo unknown)
    case "$merge_type" in
      none) printf 'UP-TO-DATE\talready level with upstream\n' ;;
      *)    printf 'SYNCED\t%s on %s\n' "$merge_type" "$branch" ;;
    esac
    return 0
  fi

  case "$err" in
    *"HTTP 409"*|*[Cc]onflict*) printf 'CONFLICT\tmerge conflict on %s — resolve locally\n' "$branch" ;;
    *"HTTP 422"*)               printf 'CONFLICT\tnot fast-forwardable on %s\n' "$branch" ;;
    *"HTTP 404"*)               printf 'SKIPPED\tbranch %s or upstream not found\n' "$branch" ;;
    *"HTTP 403"*)               printf 'SKIPPED\tno write access\n' ;;
    *)                          printf 'SKIPPED\tmerge-upstream failed\n' ;;
  esac
}

cmd_sync_forks_main() {
  cmd_sync_forks_parse_args "$@"
  preflight_check
  skip_init

  if [ -z "$SYNC_FORKS_TARGET" ]; then
    SYNC_FORKS_TARGET=$(get_username)
    SYNC_FORKS_TARGET_TYPE="user"
  fi

  header "Sync Forks"
  if [ -n "$SYNC_FORKS_REPO" ]; then
    echo -e "  Repo:   ${BOLD}${SYNC_FORKS_REPO}${NC}"
  else
    echo -e "  Target: ${BOLD}${SYNC_FORKS_TARGET}${NC}"
  fi
  [ -n "$SYNC_FORKS_BRANCH" ] && echo -e "  Branch: ${BOLD}${SYNC_FORKS_BRANCH}${NC}"
  $DRY_RUN && echo -e "  Mode:   ${YELLOW}DRY RUN${NC}"
  echo ""

  local meta_file
  meta_file=$(tmp_new)

  if [ -n "$SYNC_FORKS_REPO" ]; then
    # Single repo: same 15-column shape as cmd_forks_fetch_meta, columns 1-6 only.
    local one
    one=$(gh_api_try "$SYNC_FORKS_REPO" "repos/${SYNC_FORKS_REPO}") || {
      print_skips; die "sync-forks: cannot read ${SYNC_FORKS_REPO}"
    }
    printf '%s' "$one" | jq -r '[
      .full_name,
      (.parent.full_name // ""),
      (.parent.default_branch // ""),
      "",
      (.default_branch // ""),
      "",
      (.archived | tostring), "false", "false", "0", "0", "0", "", "", "0"
    ] | @tsv' > "$meta_file"
  else
    echo -e "${DIM}Fetching forks...${NC}"
    cmd_forks_fetch_meta "$SYNC_FORKS_TARGET" "$SYNC_FORKS_LIMIT" > "$meta_file"
  fi

  local total
  total=$(count_lines "$meta_file")
  if [ "$total" -eq 0 ]; then
    echo -e "${GREEN}No forks found.${NC}"
    print_skips
    exit 0
  fi
  echo -e "Found ${BOLD}${total}${NC} fork(s)"
  echo ""

  local synced=0 uptodate=0 conflict=0 skipped=0
  local nwo parent parent_ref parent_oid fork_ref fork_oid archived locked empty \
        stars forks watchers pushed created disk branch status detail
  while IFS=$'\t' read -r nwo parent parent_ref parent_oid fork_ref fork_oid \
                          archived locked empty stars forks watchers pushed created disk; do
    [ -z "$nwo" ] && continue

    if [ "$archived" = "true" ]; then
      skip_note "$nwo" "archived — read-only"; skipped=$((skipped + 1))
      echo -e "  ${DIM}SKIPPED   ${nwo} (archived)${NC}"
      continue
    fi
    if [ -z "$parent" ]; then
      skip_note "$nwo" "upstream unavailable (deleted or private)"; skipped=$((skipped + 1))
      echo -e "  ${DIM}SKIPPED   ${nwo} (no upstream)${NC}"
      continue
    fi

    branch="${SYNC_FORKS_BRANCH:-$fork_ref}"
    if [ -z "$branch" ]; then
      skip_note "$nwo" "no default branch (empty repo)"; skipped=$((skipped + 1))
      echo -e "  ${DIM}SKIPPED   ${nwo} (empty)${NC}"
      continue
    fi

    # Phase 1 already gave us both head oids: when they match on the default
    # branch there is nothing to do and no request is worth sending.
    if [ -z "$SYNC_FORKS_BRANCH" ] && [ -n "$parent_oid" ] && [ "$parent_oid" = "$fork_oid" ]; then
      uptodate=$((uptodate + 1))
      $VERBOSE && echo -e "  ${DIM}UP-TO-DATE ${nwo}${NC}"
      continue
    fi

    if $DRY_RUN; then
      echo -e "  ${YELLOW}WOULD SYNC${NC} ${nwo} ${DIM}(${branch} <- ${parent})${NC}"
      synced=$((synced + 1))
      continue
    fi

    IFS=$'\t' read -r status detail < <(cmd_sync_forks_one "$nwo" "$branch")
    case "$status" in
      SYNCED)     synced=$((synced + 1));    echo -e "  ${GREEN}SYNCED${NC}     ${nwo} ${DIM}(${detail})${NC}" ;;
      UP-TO-DATE) uptodate=$((uptodate + 1)); $VERBOSE && echo -e "  ${DIM}UP-TO-DATE ${nwo}${NC}" ;;
      CONFLICT)   conflict=$((conflict + 1)); echo -e "  ${RED}CONFLICT${NC}   ${nwo} ${DIM}(${detail})${NC}" ;;
      *)          skipped=$((skipped + 1));  skip_note "$nwo" "$detail"
                  echo -e "  ${DIM}SKIPPED   ${nwo} (${detail})${NC}" ;;
    esac
  done < "$meta_file"

  echo ""
  if $DRY_RUN; then
    echo -e "${YELLOW}DRY RUN — nothing was synced.${NC}"
    echo -e "Would sync: ${BOLD}${synced}${NC}, Up to date: ${BOLD}${uptodate}${NC}, Skipped: ${BOLD}${skipped}${NC}"
  else
    echo -e "${GREEN}Done!${NC} Synced: ${BOLD}${synced}${NC}, Up to date: ${BOLD}${uptodate}${NC}, Conflicts: ${BOLD}${conflict}${NC}, Skipped: ${BOLD}${skipped}${NC}"
  fi
  print_skips
}
# =============================================================================
# COMMAND: cache-cleanup
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
CACHE_CLEANUP_TARGET=""
CACHE_CLEANUP_TARGET_TYPE=""
CACHE_CLEANUP_REPO=""
CACHE_CLEANUP_OLDER_THAN=""
CACHE_CLEANUP_KEY=""
CACHE_CLEANUP_REF=""
CACHE_CLEANUP_LARGER_THAN=""
CACHE_CLEANUP_KEEP=""
CACHE_CLEANUP_LIMIT=200

cmd_cache_cleanup_usage() {
  cat <<EOF
${BOLD}github-helpers cache-cleanup${NC} ${DIM}v${VERSION}${NC} — Purge GitHub Actions caches

${BOLD}USAGE${NC}
  github-helpers cache-cleanup [options]

${BOLD}OPTIONS${NC}
  --user NAME             Target user (default: authenticated user)
  --org NAME              Target organization
  --repo OWNER/NAME       Single repository
  --older-than N          Caches not accessed for N days
  --key PATTERN           Cache key matches this regex
  --ref REF               Only caches for this ref (e.g. refs/heads/main)
  --larger-than SIZE      Caches at least this big (100MB, 1.5GiB, 500K)
  --keep N                Keep the N most recently accessed caches per repo
  --limit N               Max repos to scan (default: ${CACHE_CLEANUP_LIMIT})
  --dry-run               Show what would be deleted, delete nothing
  -y, --yes               Skip confirmation prompt
  -v, --verbose           List every cache, not just the totals
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  github-helpers cache-cleanup --dry-run
  github-helpers cache-cleanup --older-than 30 -y
  github-helpers cache-cleanup --repo me/proj --keep 5
  github-helpers cache-cleanup --org my-company --larger-than 500MB --dry-run

${BOLD}NOTE${NC}
  Each repository has a 10 GB Actions cache quota; GitHub evicts the least
  recently used entries once it is full. Repos with Actions disabled are
  skipped, not treated as failures.
EOF
  exit 0
}

cmd_cache_cleanup_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --user)         need_arg "--user" "${2:-}"; CACHE_CLEANUP_TARGET="$2"; CACHE_CLEANUP_TARGET_TYPE="user"; shift 2 ;;
      --org)          need_arg "--org" "${2:-}"; CACHE_CLEANUP_TARGET="$2"; CACHE_CLEANUP_TARGET_TYPE="org"; shift 2 ;;
      --repo)         need_arg "--repo" "${2:-}"; CACHE_CLEANUP_REPO="$2"; shift 2 ;;
      --older-than)   need_arg "--older-than" "${2:-}"; CACHE_CLEANUP_OLDER_THAN="$2"; shift 2 ;;
      --key)          need_arg "--key" "${2:-}"; CACHE_CLEANUP_KEY="$2"; shift 2 ;;
      --ref)          need_arg "--ref" "${2:-}"; CACHE_CLEANUP_REF="$2"; shift 2 ;;
      --larger-than)  need_arg "--larger-than" "${2:-}"; CACHE_CLEANUP_LARGER_THAN="$2"; shift 2 ;;
      --keep)         need_arg "--keep" "${2:-}"; CACHE_CLEANUP_KEEP="$2"; shift 2 ;;
      --limit)        need_arg "--limit" "${2:-}"; CACHE_CLEANUP_LIMIT="$2"; shift 2 ;;
      --dry-run)      DRY_RUN=true; shift ;;
      -y|--yes)       AUTO_YES=true; shift ;;
      -v|--verbose)   VERBOSE=true; shift ;;
      -h|--help)      cmd_cache_cleanup_usage ;;
      *) die "cache-cleanup: unknown option: $1" ;;
    esac
  done

  [ -n "$CACHE_CLEANUP_OLDER_THAN" ] && { [[ "$CACHE_CLEANUP_OLDER_THAN" =~ ^[0-9]+$ ]] || die "cache-cleanup: --older-than must be a whole number of days"; }
  [ -n "$CACHE_CLEANUP_KEEP" ] && { [[ "$CACHE_CLEANUP_KEEP" =~ ^[0-9]+$ ]] || die "cache-cleanup: --keep must be a whole number"; }
  [[ "$CACHE_CLEANUP_LIMIT" =~ ^[0-9]+$ ]] || die "cache-cleanup: --limit must be a whole number"
  [ -n "$CACHE_CLEANUP_REPO" ] && [[ "$CACHE_CLEANUP_REPO" != */* ]] && die "cache-cleanup: --repo must be OWNER/NAME"
  if [ -n "$CACHE_CLEANUP_KEY" ]; then
    jq -n --arg p "$CACHE_CLEANUP_KEY" '"" | test($p)' >/dev/null 2>&1 \
      || die "cache-cleanup: --key is not a valid regex: ${CACHE_CLEANUP_KEY}"
  fi
  return 0
}

cmd_cache_cleanup_main() {
  cmd_cache_cleanup_parse_args "$@"
  preflight_check
  skip_init

  if [ -z "$CACHE_CLEANUP_TARGET" ]; then
    CACHE_CLEANUP_TARGET=$(get_username)
    CACHE_CLEANUP_TARGET_TYPE="user"
  fi

  local min_bytes=0 cutoff=""
  [ -n "$CACHE_CLEANUP_LARGER_THAN" ] && min_bytes=$(parse_size "$CACHE_CLEANUP_LARGER_THAN")
  [ -n "$CACHE_CLEANUP_OLDER_THAN" ] && cutoff=$(cutoff_date "$CACHE_CLEANUP_OLDER_THAN" days)

  header "Actions Cache Cleanup"
  if [ -n "$CACHE_CLEANUP_REPO" ]; then
    echo -e "  Repo:        ${BOLD}${CACHE_CLEANUP_REPO}${NC}"
  else
    echo -e "  Target:      ${BOLD}${CACHE_CLEANUP_TARGET}${NC}"
  fi
  [ -n "$cutoff" ] && echo -e "  Not used in: ${BOLD}${CACHE_CLEANUP_OLDER_THAN}${NC} days (before ${cutoff%%T*})"
  [ -n "$CACHE_CLEANUP_KEY" ] && echo -e "  Key regex:   ${BOLD}${CACHE_CLEANUP_KEY}${NC}"
  [ -n "$CACHE_CLEANUP_REF" ] && echo -e "  Ref:         ${BOLD}${CACHE_CLEANUP_REF}${NC}"
  [ "$min_bytes" -gt 0 ] && echo -e "  Larger than: ${BOLD}$(human_bytes "$min_bytes")${NC}"
  [ -n "$CACHE_CLEANUP_KEEP" ] && echo -e "  Keep:        ${BOLD}${CACHE_CLEANUP_KEEP}${NC} most recent per repo"
  $DRY_RUN && echo -e "  Mode:        ${YELLOW}DRY RUN${NC}"
  echo ""

  local repo_file cand_file
  repo_file=$(resolve_repo_list "$CACHE_CLEANUP_TARGET" "$CACHE_CLEANUP_REPO" "$CACHE_CLEANUP_LIMIT" "cache-cleanup")
  cand_file=$(tmp_new)

  echo -e "${DIM}Scanning $(count_lines "$repo_file") repo(s)...${NC}"
  local nwo caches
  while IFS= read -r nwo; do
    [ -z "$nwo" ] && continue
    caches=$(gh_paginate "$nwo" "repos/${nwo}/actions/caches?per_page=100" '.actions_caches[]') || continue
    printf '%s' "$caches" | jq -r \
      --arg repo "$nwo" --arg cutoff "$cutoff" --arg key "$CACHE_CLEANUP_KEY" \
      --arg ref "$CACHE_CLEANUP_REF" --argjson min "$min_bytes" \
      --argjson keep "${CACHE_CLEANUP_KEEP:-0}" '
      sort_by(.last_accessed_at) | reverse
      | (if $keep > 0 then .[$keep:] else . end)
      | map(select($cutoff == "" or .last_accessed_at < $cutoff))
      | map(select($key == "" or (.key | test($key))))
      | map(select($ref == "" or .ref == $ref))
      | map(select(.size_in_bytes >= $min))
      | .[] | [$repo, (.id | tostring), .key, (.size_in_bytes | tostring), .ref, .last_accessed_at] | @tsv
      ' >> "$cand_file"
  done < "$repo_file"

  local n_cand total_bytes
  n_cand=$(count_lines "$cand_file")
  if [ "$n_cand" -eq 0 ]; then
    echo -e "${GREEN}No caches match — nothing to reclaim.${NC}"
    print_skips
    exit 0
  fi
  total_bytes=$(awk -F'\t' '{s += $4} END {printf "%d", s + 0}' "$cand_file")

  echo ""
  echo -e "${YELLOW}${n_cand} cache(s), $(human_bytes "$total_bytes") reclaimable${NC}"
  awk -F'\t' '{s[$1] += $4; n[$1]++} END {for (r in s) printf "%s\t%d\t%d\n", r, n[r], s[r]}' "$cand_file" \
    | sort -k3 -rn | while IFS=$'\t' read -r r n b; do
        echo -e "  ${DIM}•${NC} ${r} ${DIM}(${n} caches, $(human_bytes "$b"))${NC}"
      done
  if $VERBOSE; then
    echo ""
    while IFS=$'\t' read -r r id key sz ref last; do
      echo -e "    ${DIM}${r}  ${key}  $(human_bytes "$sz")  ${ref}  ${last%%T*}${NC}"
    done < "$cand_file"
  fi
  echo ""

  if $DRY_RUN; then
    echo -e "${YELLOW}DRY RUN — no caches were deleted.${NC}"
    print_skips
    exit 0
  fi

  if ! confirm "Delete ${n_cand} cache(s) and reclaim $(human_bytes "$total_bytes")?"; then
    echo "Cancelled."
    exit 0
  fi

  local deleted=0 fail=0 freed=0 r id key sz ref last
  while IFS=$'\t' read -r r id key sz ref last; do
    if gh api --method DELETE "repos/${r}/actions/caches/${id}" &>/dev/null; then
      deleted=$((deleted + 1)); freed=$((freed + sz))
      $VERBOSE && echo -e "  ${GREEN}DELETED${NC}  ${r} ${DIM}${key}${NC}"
    else
      fail=$((fail + 1))
      echo -e "  ${RED}FAILED${NC}   ${r} ${DIM}${key}${NC}"
    fi
  done < "$cand_file"

  echo ""
  echo -e "${GREEN}Done!${NC} Deleted: ${BOLD}${deleted}${NC}, Failed: ${BOLD}${fail}${NC}, Reclaimed: ${BOLD}$(human_bytes "$freed")${NC}"
  print_skips
}

# =============================================================================
# COMMAND: artifact-cleanup
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
ARTIFACT_CLEANUP_TARGET=""
ARTIFACT_CLEANUP_TARGET_TYPE=""
ARTIFACT_CLEANUP_REPO=""
ARTIFACT_CLEANUP_OLDER_THAN=""
ARTIFACT_CLEANUP_NAME=""
ARTIFACT_CLEANUP_BRANCH=""
ARTIFACT_CLEANUP_LARGER_THAN=""
ARTIFACT_CLEANUP_EXPIRED=false
ARTIFACT_CLEANUP_LIMIT=200

cmd_artifact_cleanup_usage() {
  cat <<EOF
${BOLD}github-helpers artifact-cleanup${NC} ${DIM}v${VERSION}${NC} — Delete GitHub Actions artifacts

${BOLD}USAGE${NC}
  github-helpers artifact-cleanup [options]

${BOLD}OPTIONS${NC}
  --user NAME             Target user (default: authenticated user)
  --org NAME              Target organization
  --repo OWNER/NAME       Single repository
  --older-than N          Artifacts created more than N days ago
  --name PATTERN          Artifact name matches this regex
  --branch NAME           Only artifacts from runs on this branch
  --larger-than SIZE      Artifacts at least this big (100MB, 1.5GiB)
  --expired               Only ALREADY-EXPIRED artifacts (see NOTE)
  --limit N               Max repos to scan (default: ${ARTIFACT_CLEANUP_LIMIT})
  --dry-run               Show what would be deleted, delete nothing
  -y, --yes               Skip confirmation prompt
  -v, --verbose           List every artifact, not just the totals
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  github-helpers artifact-cleanup --dry-run
  github-helpers artifact-cleanup --older-than 14 -y
  github-helpers artifact-cleanup --repo me/proj --larger-than 200MB

${BOLD}NOTE${NC}
  Expired artifacts no longer count against billed storage, so deleting them
  reclaims nothing. They are excluded by default; --expired selects only them,
  for tidiness rather than savings.

  To also drop the runs themselves (and their logs), see ${BOLD}run-cleanup${NC}.
EOF
  exit 0
}

cmd_artifact_cleanup_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --user)        need_arg "--user" "${2:-}"; ARTIFACT_CLEANUP_TARGET="$2"; ARTIFACT_CLEANUP_TARGET_TYPE="user"; shift 2 ;;
      --org)         need_arg "--org" "${2:-}"; ARTIFACT_CLEANUP_TARGET="$2"; ARTIFACT_CLEANUP_TARGET_TYPE="org"; shift 2 ;;
      --repo)        need_arg "--repo" "${2:-}"; ARTIFACT_CLEANUP_REPO="$2"; shift 2 ;;
      --older-than)  need_arg "--older-than" "${2:-}"; ARTIFACT_CLEANUP_OLDER_THAN="$2"; shift 2 ;;
      --name)        need_arg "--name" "${2:-}"; ARTIFACT_CLEANUP_NAME="$2"; shift 2 ;;
      --branch)      need_arg "--branch" "${2:-}"; ARTIFACT_CLEANUP_BRANCH="$2"; shift 2 ;;
      --larger-than) need_arg "--larger-than" "${2:-}"; ARTIFACT_CLEANUP_LARGER_THAN="$2"; shift 2 ;;
      --expired)     ARTIFACT_CLEANUP_EXPIRED=true; shift ;;
      --limit)       need_arg "--limit" "${2:-}"; ARTIFACT_CLEANUP_LIMIT="$2"; shift 2 ;;
      --dry-run)     DRY_RUN=true; shift ;;
      -y|--yes)      AUTO_YES=true; shift ;;
      -v|--verbose)  VERBOSE=true; shift ;;
      -h|--help)     cmd_artifact_cleanup_usage ;;
      *) die "artifact-cleanup: unknown option: $1" ;;
    esac
  done

  [ -n "$ARTIFACT_CLEANUP_OLDER_THAN" ] && { [[ "$ARTIFACT_CLEANUP_OLDER_THAN" =~ ^[0-9]+$ ]] || die "artifact-cleanup: --older-than must be a whole number of days"; }
  [[ "$ARTIFACT_CLEANUP_LIMIT" =~ ^[0-9]+$ ]] || die "artifact-cleanup: --limit must be a whole number"
  [ -n "$ARTIFACT_CLEANUP_REPO" ] && [[ "$ARTIFACT_CLEANUP_REPO" != */* ]] && die "artifact-cleanup: --repo must be OWNER/NAME"
  if [ -n "$ARTIFACT_CLEANUP_NAME" ]; then
    jq -n --arg p "$ARTIFACT_CLEANUP_NAME" '"" | test($p)' >/dev/null 2>&1 \
      || die "artifact-cleanup: --name is not a valid regex: ${ARTIFACT_CLEANUP_NAME}"
  fi
  return 0
}

cmd_artifact_cleanup_main() {
  cmd_artifact_cleanup_parse_args "$@"
  preflight_check
  skip_init

  if [ -z "$ARTIFACT_CLEANUP_TARGET" ]; then
    ARTIFACT_CLEANUP_TARGET=$(get_username)
    ARTIFACT_CLEANUP_TARGET_TYPE="user"
  fi

  local min_bytes=0 cutoff=""
  [ -n "$ARTIFACT_CLEANUP_LARGER_THAN" ] && min_bytes=$(parse_size "$ARTIFACT_CLEANUP_LARGER_THAN")
  [ -n "$ARTIFACT_CLEANUP_OLDER_THAN" ] && cutoff=$(cutoff_date "$ARTIFACT_CLEANUP_OLDER_THAN" days)

  header "Actions Artifact Cleanup"
  if [ -n "$ARTIFACT_CLEANUP_REPO" ]; then
    echo -e "  Repo:        ${BOLD}${ARTIFACT_CLEANUP_REPO}${NC}"
  else
    echo -e "  Target:      ${BOLD}${ARTIFACT_CLEANUP_TARGET}${NC}"
  fi
  [ -n "$cutoff" ] && echo -e "  Older than:  ${BOLD}${ARTIFACT_CLEANUP_OLDER_THAN}${NC} days (before ${cutoff%%T*})"
  [ -n "$ARTIFACT_CLEANUP_NAME" ] && echo -e "  Name regex:  ${BOLD}${ARTIFACT_CLEANUP_NAME}${NC}"
  [ -n "$ARTIFACT_CLEANUP_BRANCH" ] && echo -e "  Branch:      ${BOLD}${ARTIFACT_CLEANUP_BRANCH}${NC}"
  [ "$min_bytes" -gt 0 ] && echo -e "  Larger than: ${BOLD}$(human_bytes "$min_bytes")${NC}"
  $ARTIFACT_CLEANUP_EXPIRED && echo -e "  Selecting:   ${BOLD}expired only${NC} ${DIM}(reclaims no billed storage)${NC}"
  $DRY_RUN && echo -e "  Mode:        ${YELLOW}DRY RUN${NC}"
  echo ""

  local repo_file cand_file
  repo_file=$(resolve_repo_list "$ARTIFACT_CLEANUP_TARGET" "$ARTIFACT_CLEANUP_REPO" "$ARTIFACT_CLEANUP_LIMIT" "artifact-cleanup")
  cand_file=$(tmp_new)

  echo -e "${DIM}Scanning $(count_lines "$repo_file") repo(s)...${NC}"
  local nwo arts
  while IFS= read -r nwo; do
    [ -z "$nwo" ] && continue
    arts=$(gh_paginate "$nwo" "repos/${nwo}/actions/artifacts?per_page=100" '.artifacts[]') || continue
    printf '%s' "$arts" | jq -r \
      --arg repo "$nwo" --arg cutoff "$cutoff" --arg name "$ARTIFACT_CLEANUP_NAME" \
      --arg branch "$ARTIFACT_CLEANUP_BRANCH" --argjson min "$min_bytes" \
      --argjson wantExpired "$ARTIFACT_CLEANUP_EXPIRED" '
      map(select(if $wantExpired then .expired == true else .expired != true end))
      | map(select($cutoff == "" or .created_at < $cutoff))
      | map(select($name == "" or (.name | test($name))))
      | map(select($branch == "" or (.workflow_run.head_branch // "") == $branch))
      | map(select(.size_in_bytes >= $min))
      | .[] | [$repo, (.id | tostring), .name, (.size_in_bytes | tostring),
               (.workflow_run.head_branch // ""), .created_at] | @tsv
      ' >> "$cand_file"
  done < "$repo_file"

  local n_cand total_bytes
  n_cand=$(count_lines "$cand_file")
  if [ "$n_cand" -eq 0 ]; then
    echo -e "${GREEN}No artifacts match — nothing to delete.${NC}"
    print_skips
    exit 0
  fi
  total_bytes=$(awk -F'\t' '{s += $4} END {printf "%d", s + 0}' "$cand_file")

  echo ""
  echo -e "${YELLOW}${n_cand} artifact(s), $(human_bytes "$total_bytes")${NC}"
  awk -F'\t' '{s[$1] += $4; n[$1]++} END {for (r in s) printf "%s\t%d\t%d\n", r, n[r], s[r]}' "$cand_file" \
    | sort -k3 -rn | while IFS=$'\t' read -r r n b; do
        echo -e "  ${DIM}•${NC} ${r} ${DIM}(${n} artifacts, $(human_bytes "$b"))${NC}"
      done
  if $VERBOSE; then
    echo ""
    while IFS=$'\t' read -r r id name sz branch created; do
      echo -e "    ${DIM}${r}  ${name}  $(human_bytes "$sz")  ${branch}  ${created%%T*}${NC}"
    done < "$cand_file"
  fi
  echo ""

  if $DRY_RUN; then
    echo -e "${YELLOW}DRY RUN — no artifacts were deleted.${NC}"
    print_skips
    exit 0
  fi

  if ! confirm "Delete ${n_cand} artifact(s) ($(human_bytes "$total_bytes"))?"; then
    echo "Cancelled."
    exit 0
  fi

  local deleted=0 fail=0 freed=0 r id name sz branch created
  while IFS=$'\t' read -r r id name sz branch created; do
    if gh api --method DELETE "repos/${r}/actions/artifacts/${id}" &>/dev/null; then
      deleted=$((deleted + 1)); freed=$((freed + sz))
      $VERBOSE && echo -e "  ${GREEN}DELETED${NC}  ${r} ${DIM}${name}${NC}"
    else
      fail=$((fail + 1))
      echo -e "  ${RED}FAILED${NC}   ${r} ${DIM}${name}${NC}"
    fi
  done < "$cand_file"

  echo ""
  echo -e "${GREEN}Done!${NC} Deleted: ${BOLD}${deleted}${NC}, Failed: ${BOLD}${fail}${NC}, Reclaimed: ${BOLD}$(human_bytes "$freed")${NC}"
  print_skips
}

# =============================================================================
# COMMAND: run-cleanup
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
RUN_CLEANUP_TARGET=""
RUN_CLEANUP_TARGET_TYPE=""
RUN_CLEANUP_REPO=""
RUN_CLEANUP_OLDER_THAN=""
RUN_CLEANUP_KEEP=""
RUN_CLEANUP_CONCLUSION=""
RUN_CLEANUP_BRANCH=""
RUN_CLEANUP_WORKFLOW=""
RUN_CLEANUP_LIMIT=200

cmd_run_cleanup_usage() {
  cat <<EOF
${BOLD}github-helpers run-cleanup${NC} ${DIM}v${VERSION}${NC} — Delete old GitHub Actions workflow runs

${BOLD}USAGE${NC}
  github-helpers run-cleanup [options]

${BOLD}OPTIONS${NC}
  --user NAME             Target user (default: authenticated user)
  --org NAME              Target organization
  --repo OWNER/NAME       Single repository
  --older-than N          Runs created more than N days ago
  --keep N                Keep the N most recent runs OF EACH WORKFLOW
  --conclusion C          success, failure, cancelled, skipped, timed_out...
  --branch NAME           Only runs on this branch
  --workflow NAME         Only this workflow (file name or display name)
  --limit N               Max repos to scan (default: ${RUN_CLEANUP_LIMIT})
  --dry-run               Show what would be deleted, delete nothing
  -y, --yes               Skip confirmation prompt
  -v, --verbose           List every run, not just the totals
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  github-helpers run-cleanup --older-than 90 --dry-run
  github-helpers run-cleanup --keep 10 -y
  github-helpers run-cleanup --conclusion failure --older-than 30
  github-helpers run-cleanup --repo me/proj --workflow ci.yml --keep 5

${BOLD}NOTE${NC}
  --keep is per workflow, not per repo: a noisy workflow would otherwise wipe
  out the entire history of a rarely-run one.

  Deleting a run also deletes ${BOLD}its logs and its artifacts${NC}. To reclaim storage
  while keeping the run history, use ${BOLD}artifact-cleanup${NC} instead.

  Runs that are queued, in progress or waiting are never deleted.
EOF
  exit 0
}

cmd_run_cleanup_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --user)        need_arg "--user" "${2:-}"; RUN_CLEANUP_TARGET="$2"; RUN_CLEANUP_TARGET_TYPE="user"; shift 2 ;;
      --org)         need_arg "--org" "${2:-}"; RUN_CLEANUP_TARGET="$2"; RUN_CLEANUP_TARGET_TYPE="org"; shift 2 ;;
      --repo)        need_arg "--repo" "${2:-}"; RUN_CLEANUP_REPO="$2"; shift 2 ;;
      --older-than)  need_arg "--older-than" "${2:-}"; RUN_CLEANUP_OLDER_THAN="$2"; shift 2 ;;
      --keep)        need_arg "--keep" "${2:-}"; RUN_CLEANUP_KEEP="$2"; shift 2 ;;
      --conclusion)  need_arg "--conclusion" "${2:-}"; RUN_CLEANUP_CONCLUSION="$2"; shift 2 ;;
      --branch)      need_arg "--branch" "${2:-}"; RUN_CLEANUP_BRANCH="$2"; shift 2 ;;
      --workflow)    need_arg "--workflow" "${2:-}"; RUN_CLEANUP_WORKFLOW="$2"; shift 2 ;;
      --limit)       need_arg "--limit" "${2:-}"; RUN_CLEANUP_LIMIT="$2"; shift 2 ;;
      --dry-run)     DRY_RUN=true; shift ;;
      -y|--yes)      AUTO_YES=true; shift ;;
      -v|--verbose)  VERBOSE=true; shift ;;
      -h|--help)     cmd_run_cleanup_usage ;;
      *) die "run-cleanup: unknown option: $1" ;;
    esac
  done

  [ -n "$RUN_CLEANUP_OLDER_THAN" ] && { [[ "$RUN_CLEANUP_OLDER_THAN" =~ ^[0-9]+$ ]] || die "run-cleanup: --older-than must be a whole number of days"; }
  [ -n "$RUN_CLEANUP_KEEP" ] && { [[ "$RUN_CLEANUP_KEEP" =~ ^[0-9]+$ ]] || die "run-cleanup: --keep must be a whole number"; }
  [[ "$RUN_CLEANUP_LIMIT" =~ ^[0-9]+$ ]] || die "run-cleanup: --limit must be a whole number"
  [ -n "$RUN_CLEANUP_REPO" ] && [[ "$RUN_CLEANUP_REPO" != */* ]] && die "run-cleanup: --repo must be OWNER/NAME"
  if [ -z "$RUN_CLEANUP_OLDER_THAN" ] && [ -z "$RUN_CLEANUP_KEEP" ] && [ -z "$RUN_CLEANUP_CONCLUSION" ]; then
    die "run-cleanup: refusing to delete every run — use --older-than, --keep or --conclusion"
  fi
  return 0
}

cmd_run_cleanup_main() {
  cmd_run_cleanup_parse_args "$@"
  preflight_check
  skip_init

  if [ -z "$RUN_CLEANUP_TARGET" ]; then
    RUN_CLEANUP_TARGET=$(get_username)
    RUN_CLEANUP_TARGET_TYPE="user"
  fi

  local cutoff=""
  [ -n "$RUN_CLEANUP_OLDER_THAN" ] && cutoff=$(cutoff_date "$RUN_CLEANUP_OLDER_THAN" days)

  header "Workflow Run Cleanup"
  if [ -n "$RUN_CLEANUP_REPO" ]; then
    echo -e "  Repo:       ${BOLD}${RUN_CLEANUP_REPO}${NC}"
  else
    echo -e "  Target:     ${BOLD}${RUN_CLEANUP_TARGET}${NC}"
  fi
  [ -n "$cutoff" ] && echo -e "  Older than: ${BOLD}${RUN_CLEANUP_OLDER_THAN}${NC} days (before ${cutoff%%T*})"
  [ -n "$RUN_CLEANUP_KEEP" ] && echo -e "  Keep:       ${BOLD}${RUN_CLEANUP_KEEP}${NC} most recent per workflow"
  [ -n "$RUN_CLEANUP_CONCLUSION" ] && echo -e "  Conclusion: ${BOLD}${RUN_CLEANUP_CONCLUSION}${NC}"
  [ -n "$RUN_CLEANUP_BRANCH" ] && echo -e "  Branch:     ${BOLD}${RUN_CLEANUP_BRANCH}${NC}"
  [ -n "$RUN_CLEANUP_WORKFLOW" ] && echo -e "  Workflow:   ${BOLD}${RUN_CLEANUP_WORKFLOW}${NC}"
  $DRY_RUN && echo -e "  Mode:       ${YELLOW}DRY RUN${NC}"
  echo ""

  # `created=<DATE` is the only server-side filter the runs API offers. Without
  # --older-than every page of every repo's full history has to come down.
  if [ -z "$cutoff" ]; then
    warn "no --older-than: the full run history of each repo must be paged in, which is slow"
  fi

  local repo_file cand_file
  repo_file=$(resolve_repo_list "$RUN_CLEANUP_TARGET" "$RUN_CLEANUP_REPO" "$RUN_CLEANUP_LIMIT" "run-cleanup")
  cand_file=$(tmp_new)

  echo -e "${DIM}Scanning $(count_lines "$repo_file") repo(s)...${NC}"
  local nwo runs query
  while IFS= read -r nwo; do
    [ -z "$nwo" ] && continue
    # created=<DATE is a server-side filter — far cheaper than paging it all in.
    query="per_page=100&exclude_pull_requests=true"
    [ -n "$cutoff" ] && query="${query}&created=%3C${cutoff%%T*}"
    [ -n "$RUN_CLEANUP_BRANCH" ] && query="${query}&branch=${RUN_CLEANUP_BRANCH}"
    runs=$(gh_paginate "$nwo" "repos/${nwo}/actions/runs?${query}" '.workflow_runs[]') || continue
    printf '%s' "$runs" | jq -r \
      --arg repo "$nwo" --arg cutoff "$cutoff" --arg concl "$RUN_CLEANUP_CONCLUSION" \
      --arg wf "$RUN_CLEANUP_WORKFLOW" --argjson keep "${RUN_CLEANUP_KEEP:-0}" '
      # Never touch a run that has not finished. Bind the status first: after a
      # pipe the context is the literal array, so `index(.status)` would look
      # up ".status" on the array itself.
      map(select((.status // "") as $st
                 | ["queued","in_progress","requested","waiting","pending"]
                 | index($st) == null))
      | map(select($wf == "" or (.name // "") == $wf or ((.path // "") | endswith("/" + $wf))))
      | group_by(.workflow_id)
      | map(sort_by(.created_at) | reverse | (if $keep > 0 then .[$keep:] else . end))
      | flatten
      | map(select($cutoff == "" or .created_at < $cutoff))
      | map(select($concl == "" or (.conclusion // "") == $concl))
      | .[] | [$repo, (.id | tostring), (.name // "?"), (.conclusion // "none"),
               (.head_branch // ""), .created_at] | @tsv
      ' >> "$cand_file"
  done < "$repo_file"

  local n_cand
  n_cand=$(count_lines "$cand_file")
  if [ "$n_cand" -eq 0 ]; then
    echo -e "${GREEN}No runs match — nothing to delete.${NC}"
    print_skips
    exit 0
  fi

  echo ""
  echo -e "${YELLOW}${n_cand} workflow run(s) to delete${NC}"
  awk -F'\t' '{n[$1]++} END {for (r in n) printf "%s\t%d\n", r, n[r]}' "$cand_file" \
    | sort -k2 -rn | while IFS=$'\t' read -r r n; do
        echo -e "  ${DIM}•${NC} ${r} ${DIM}(${n} runs)${NC}"
      done
  if $VERBOSE; then
    echo ""
    while IFS=$'\t' read -r r id name concl branch created; do
      echo -e "    ${DIM}${r}  ${name}  ${concl}  ${branch}  ${created%%T*}${NC}"
    done < "$cand_file"
  fi
  echo ""

  if $DRY_RUN; then
    echo -e "${YELLOW}DRY RUN — no runs were deleted.${NC}"
    print_skips
    exit 0
  fi

  if ! confirm "Delete ${n_cand} workflow run(s), including their logs and artifacts?"; then
    echo "Cancelled."
    exit 0
  fi

  local deleted=0 fail=0 r id name concl branch created
  while IFS=$'\t' read -r r id name concl branch created; do
    if gh api --method DELETE "repos/${r}/actions/runs/${id}" &>/dev/null; then
      deleted=$((deleted + 1))
      $VERBOSE && echo -e "  ${GREEN}DELETED${NC}  ${r} ${DIM}#${id} ${name}${NC}"
    else
      fail=$((fail + 1))
      echo -e "  ${RED}FAILED${NC}   ${r} ${DIM}#${id} ${name}${NC}"
    fi
  done < "$cand_file"

  echo ""
  echo -e "${GREEN}Done!${NC} Deleted: ${BOLD}${deleted}${NC}, Failed: ${BOLD}${fail}${NC}"
  print_skips
}
# =============================================================================
# COMMAND: gist
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
GIST_VIS=""
GIST_OLDER_THAN=""
GIST_UNTOUCHED=""
GIST_EMPTY=false
GIST_NO_DESC=false
GIST_MATCH=""
GIST_STARRED=false
GIST_LIMIT=1000
GIST_DELETE=false
GIST_FORMAT="text"
GIST_OUT="gist-delete.txt"
GIST_SAVE_LIST=false
GIST_FROM=""

cmd_gist_usage() {
  cat <<EOF
${BOLD}github-helpers gist${NC} ${DIM}v${VERSION}${NC} — List, export and bulk-delete your gists

${BOLD}USAGE${NC}
  github-helpers gist [filters]
  github-helpers gist [filters] --delete --dry-run
  github-helpers gist --from ${GIST_OUT}

${BOLD}FILTERS${NC} (combined with AND — see NOTE)
  --public / --secret     Only public, or only secret, gists
  --older-than N          Created more than N days ago
  --untouched N           Not updated in N days
  --empty                 All files are empty or whitespace-only
  --no-description        No description
  --match PATTERN         Regex on the description or any filename
  --starred               Operate on gists you starred ${DIM}(read-only)${NC}
  --limit N               Max gists to fetch (default: ${GIST_LIMIT})

${BOLD}ACTION${NC}
  --delete                Delete the matched gists ${DIM}(needs at least one filter)${NC}

${BOLD}I/O${NC}
  --dry-run               Preview only — writes an annotated list, deletes nothing
  --out FILE              List file (default: ${GIST_OUT}), or report file with --format
  --save-list             Save the list even outside --dry-run
  --from FILE             Delete the ids listed in FILE (comments after # are ignored)
  --format FORMAT         text, json, csv or md (default: text)

${BOLD}FLAGS${NC}
  -y, --yes               Skip confirmation prompt
  -v, --verbose           Show every gist
  -h, --help              Show this help

${BOLD}WORKFLOW${NC}
  1. Preview:  github-helpers gist --empty --delete --dry-run
  2. Edit:     vim ${GIST_OUT}
  3. Execute:  github-helpers gist --from ${GIST_OUT}

${BOLD}EXAMPLES${NC}
  github-helpers gist --secret
  github-helpers gist --format csv --out gists.csv
  github-helpers gist --empty --no-description --delete --dry-run
  github-helpers gist --older-than 1825 --untouched 1825 --delete

${BOLD}NOTE${NC}
  Filters are ANDed, unlike unstar's default OR. You are building a deletion
  set here, and an OR would be a trap.

  Gists are deleted permanently — there is no trash. --empty checks file sizes
  from the listing for free, and only fetches the content of gists whose
  largest file is under 64 bytes.
EOF
  exit 0
}

cmd_gist_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --older-than)     need_arg "--older-than" "${2:-}"; GIST_OLDER_THAN="$2"; shift 2 ;;
      --untouched)      need_arg "--untouched" "${2:-}"; GIST_UNTOUCHED="$2"; shift 2 ;;
      --match)          need_arg "--match" "${2:-}"; GIST_MATCH="$2"; shift 2 ;;
      --limit)          need_arg "--limit" "${2:-}"; GIST_LIMIT="$2"; shift 2 ;;
      --out)            need_arg "--out" "${2:-}"; GIST_OUT="$2"; GIST_SAVE_LIST=true; shift 2 ;;
      --from)           need_arg "--from" "${2:-}"; GIST_FROM="$2"; shift 2 ;;
      --format)         need_arg "--format" "${2:-}"; GIST_FORMAT="$2"; shift 2 ;;
      --public)         GIST_VIS="true"; shift ;;
      --secret)         GIST_VIS="false"; shift ;;
      --empty)          GIST_EMPTY=true; shift ;;
      --no-description) GIST_NO_DESC=true; shift ;;
      --starred)        GIST_STARRED=true; shift ;;
      --delete)         GIST_DELETE=true; shift ;;
      --save-list)      GIST_SAVE_LIST=true; shift ;;
      --dry-run)        DRY_RUN=true; shift ;;
      -y|--yes)         AUTO_YES=true; shift ;;
      -v|--verbose)     VERBOSE=true; shift ;;
      -h|--help)        cmd_gist_usage ;;
      *) die "gist: unknown option: $1" ;;
    esac
  done

  case "$GIST_FORMAT" in
    text|json|csv|md) ;;
    *) die "gist: invalid --format '${GIST_FORMAT}' (use text, json, csv or md)" ;;
  esac
  [ -n "$GIST_OLDER_THAN" ] && { [[ "$GIST_OLDER_THAN" =~ ^[0-9]+$ ]] || die "gist: --older-than must be a whole number of days"; }
  [ -n "$GIST_UNTOUCHED" ] && { [[ "$GIST_UNTOUCHED" =~ ^[0-9]+$ ]] || die "gist: --untouched must be a whole number of days"; }
  [[ "$GIST_LIMIT" =~ ^[0-9]+$ ]] || die "gist: --limit must be a whole number"

  if [ -n "$GIST_FROM" ]; then
    [ -f "$GIST_FROM" ] || die "gist: file not found: ${GIST_FROM}"
    GIST_DELETE=true
    return 0
  fi

  # Validate the regex before spending a single request on it.
  if [ -n "$GIST_MATCH" ]; then
    jq -n --arg p "$GIST_MATCH" '"" | test($p; "i")' >/dev/null 2>&1 \
      || die "gist: --match is not a valid regex: ${GIST_MATCH}"
  fi

  $GIST_DELETE && $GIST_STARRED && die "gist: --starred gists belong to other people and cannot be deleted"
  if [ "$GIST_FORMAT" != "text" ] && { $GIST_DELETE || $DRY_RUN; }; then
    die "gist: --format is for reporting — drop --delete/--dry-run"
  fi

  local nfilters=0
  [ -n "$GIST_VIS" ] && nfilters=$((nfilters + 1))
  [ -n "$GIST_OLDER_THAN" ] && nfilters=$((nfilters + 1))
  [ -n "$GIST_UNTOUCHED" ] && nfilters=$((nfilters + 1))
  [ -n "$GIST_MATCH" ] && nfilters=$((nfilters + 1))
  $GIST_EMPTY && nfilters=$((nfilters + 1))
  $GIST_NO_DESC && nfilters=$((nfilters + 1))
  if $GIST_DELETE && [ "$nfilters" -eq 0 ]; then
    die "gist: --delete requires at least one filter (refusing to delete every gist)"
  fi
  return 0
}

cmd_gist_delete_from() {
  local list_file="$1" total deleted=0 fail=0 id
  total=$(sed 's/#.*//' "$list_file" | awk 'NF' | wc -l | tr -d ' ')
  if [ "$total" -eq 0 ]; then
    echo -e "${GREEN}No gists to delete.${NC}"
    exit 0
  fi
  echo -e "${YELLOW}${total} gist(s) to delete${NC}"
  echo ""
  if ! confirm "Delete ${total} gist(s)? This is permanent."; then
    echo "Cancelled."
    exit 0
  fi
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    if gh api --method DELETE "gists/${id}" &>/dev/null; then
      deleted=$((deleted + 1))
      $VERBOSE && echo -e "  ${GREEN}DELETED${NC}  ${id}"
    else
      fail=$((fail + 1))
      echo -e "  ${RED}FAILED${NC}   ${id}"
    fi
  done < <(sed 's/#.*//' "$list_file" | awk 'NF {print $1}')
  echo ""
  echo -e "${GREEN}Done!${NC} Deleted: ${BOLD}${deleted}${NC}, Failed: ${BOLD}${fail}${NC}"
}

cmd_gist_main() {
  cmd_gist_parse_args "$@"
  preflight_check
  skip_init

  local out=1
  [ "$GIST_FORMAT" != "text" ] && out=2

  { header "Gists"; } >&$out

  if [ -n "$GIST_FROM" ]; then
    echo -e "  From: ${BOLD}${GIST_FROM}${NC}"
    echo ""
    cmd_gist_delete_from "$GIST_FROM"
    exit 0
  fi

  local older_cut="" untouched_cut=""
  [ -n "$GIST_OLDER_THAN" ] && older_cut=$(cutoff_date "$GIST_OLDER_THAN" days)
  [ -n "$GIST_UNTOUCHED" ] && untouched_cut=$(cutoff_date "$GIST_UNTOUCHED" days)

  {
    $GIST_STARRED && echo -e "  Source:   ${BOLD}starred gists${NC}"
    [ "$GIST_VIS" = "true" ]  && echo -e "  Filter:   ${BOLD}public only${NC}"
    [ "$GIST_VIS" = "false" ] && echo -e "  Filter:   ${BOLD}secret only${NC}"
    [ -n "$older_cut" ] && echo -e "  Created:  ${BOLD}before ${older_cut%%T*}${NC}"
    [ -n "$untouched_cut" ] && echo -e "  Updated:  ${BOLD}before ${untouched_cut%%T*}${NC}"
    [ -n "$GIST_MATCH" ] && echo -e "  Match:    ${BOLD}${GIST_MATCH}${NC}"
    $GIST_EMPTY && echo -e "  Filter:   ${BOLD}empty content${NC}"
    $GIST_NO_DESC && echo -e "  Filter:   ${BOLD}no description${NC}"
    $DRY_RUN && echo -e "  Mode:     ${YELLOW}DRY RUN${NC}"
    echo ""
    echo -e "${DIM}Fetching gists...${NC}"
  } >&$out

  local path="gists?per_page=100"
  $GIST_STARRED && path="gists/starred?per_page=100"
  local all
  all=$(gh_paginate "gists" "$path") || die "gist: failed to list gists"
  all=$(printf '%s' "$all" | jq --argjson lim "$GIST_LIMIT" '.[0:$lim]')

  # emptiness: "yes" when every file is zero bytes, "probe" when the largest
  # file is tiny enough that whitespace-only is plausible, "no" otherwise.
  local rows
  rows=$(printf '%s' "$all" | jq -c \
    --arg vis "$GIST_VIS" --arg older "$older_cut" --arg untouched "$untouched_cut" \
    --arg pat "$GIST_MATCH" --argjson nodesc "$GIST_NO_DESC" '
    map(select($vis == "" or ((.public | tostring) == $vis)))
    | map(select($older == "" or .created_at < $older))
    | map(select($untouched == "" or .updated_at < $untouched))
    | map(select($nodesc == false or (((.description // "") | gsub("\\s"; "") | length) == 0)))
    | map(select($pat == "" or ((.description // "") | test($pat; "i"))
                            or ([.files | keys[]] | any(test($pat; "i")))))
    | map({ id, description: (.description // ""), public, files: (.files | length),
            bytes: ([.files[].size] | add // 0),
            maxsize: ([.files[].size] | max // 0),
            comments, created_at, updated_at, url: .html_url })
    | map(. + {empty: (if .bytes == 0 then "yes" elif .maxsize <= 64 then "probe" else "no" end)})')

  if $GIST_EMPTY; then
    local probes
    probes=$(printf '%s' "$rows" | jq -r '.[] | select(.empty == "probe") | .id')
    if [ -n "$probes" ]; then
      echo -e "  ${DIM}Checking $(printf '%s\n' "$probes" | wc -l | tr -d ' ') small gist(s) for whitespace-only content...${NC}" >&$out
      local confirmed_file id body
      confirmed_file=$(tmp_new)
      while IFS= read -r id; do
        [ -z "$id" ] && continue
        body=$(gh_api_try "gist ${id}" "gists/${id}") || continue
        if printf '%s' "$body" | jq -e '[.files[].content // ""] | join("") | gsub("\\s"; "") | length == 0' >/dev/null 2>&1; then
          printf '%s\n' "$id" >> "$confirmed_file"
        fi
      done <<< "$probes"
      rows=$(printf '%s' "$rows" | jq -c --slurpfile ok <(jq -R . "$confirmed_file" 2>/dev/null || echo '[]') '
        ($ok | map(select(type == "string"))) as $ids
        | map(select(.empty == "yes" or (.empty == "probe" and (.id as $i | $ids | index($i)))))')
    else
      rows=$(printf '%s' "$rows" | jq -c 'map(select(.empty == "yes"))')
    fi
  fi

  local total
  total=$(printf '%s' "$rows" | jq 'length')
  if [ "$total" -eq 0 ]; then
    echo -e "${GREEN}No gists match.${NC}" >&$out
    print_skips
    exit 0
  fi

  # ── Report mode ────────────────────────────────────────────────────────────
  if [ "$GIST_FORMAT" != "text" ]; then
    local payload outfile=""
    # NOT ${GIST_SAVE_LIST:+...}: the variable holds the string "false", which
    # is non-empty, so :+ would always fire and swallow stdout.
    $GIST_SAVE_LIST && outfile="$GIST_OUT"
    payload=$(printf '%s' "$rows" | jq 'map({id, description, public, files, bytes, comments,
                                             created: (.created_at[0:10]), updated: (.updated_at[0:10]), url})')
    write_output "$outfile" "$(render_rows "$GIST_FORMAT" "$payload")"
    print_skips
    exit 0
  fi

  echo ""
  echo -e "${YELLOW}${total} gist(s)${NC}"
  local n_pub n_sec
  n_pub=$(printf '%s' "$rows" | jq '[.[] | select(.public)] | length')
  n_sec=$((total - n_pub))
  echo -e "  ${DIM}public: ${n_pub}   secret: ${n_sec}${NC}"
  echo ""
  if $VERBOSE || ! $GIST_DELETE; then
    printf "  ${BOLD}%-34s %-8s %-6s %-11s %s${NC}\n" "ID" "VIS" "FILES" "CREATED" "DESCRIPTION"
    printf '%s' "$rows" | jq -r '.[] | [.id, (if .public then "public" else "secret" end),
      (.files | tostring), (.created_at[0:10]), (.description // "")] | @tsv' \
      | while IFS=$'\t' read -r id vis files created desc; do
          printf "  %-34s %-8s %-6s %-11s %s\n" "$id" "$vis" "$files" "$created" "${desc:0:50}"
        done
    echo ""
  fi

  if ! $GIST_DELETE; then
    print_skips
    exit 0
  fi

  # ── Deletion path: annotate the list, ids alone tell a human nothing ───────
  local list_file
  if $DRY_RUN || $GIST_SAVE_LIST; then
    list_file="$GIST_OUT"
  else
    list_file=$(tmp_new)
  fi
  printf '%s' "$rows" | jq -r '.[] |
    "\(.id)  # \(if .public then "public" else "secret" end) · created \(.created_at[0:10]) · \(.files) file(s) · \(if (.description // "") == "" then "(no description)" else "\"\(.description)\"" end)"' \
    > "$list_file"

  if $DRY_RUN; then
    echo -e "${YELLOW}DRY RUN — no gists were deleted.${NC}"
    echo -e "List saved to: ${BOLD}${list_file}${NC}"
    echo -e "Review it, then run:"
    echo -e "  ${BOLD}github-helpers gist --from ${list_file}${NC}"
    print_skips
    exit 0
  fi

  cmd_gist_delete_from "$list_file"
  print_skips
}
# =============================================================================
# COMMAND: traffic
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
TRAFFIC_TARGET=""
TRAFFIC_TARGET_TYPE=""
TRAFFIC_REPO=""
TRAFFIC_PER="day"
TRAFFIC_SORT="views"
TRAFFIC_TOP=0
TRAFFIC_PATHS=false
TRAFFIC_REFERRERS=false
TRAFFIC_FORMAT="text"
TRAFFIC_OUT=""
TRAFFIC_APPEND=false
TRAFFIC_LIMIT=200

cmd_traffic_usage() {
  cat <<EOF
${BOLD}github-helpers traffic${NC} ${DIM}v${VERSION}${NC} — Snapshot repository views and clones

${BOLD}USAGE${NC}
  github-helpers traffic [options]
  github-helpers traffic --format csv --out traffic.csv --append

${BOLD}OPTIONS${NC}
  --user NAME             Target user (default: authenticated user)
  --org NAME              Target organization
  --repo OWNER/NAME       Single repository
  --per day|week          Granularity (default: ${TRAFFIC_PER})
  --sort views|clones     Sort the summary by this metric (default: ${TRAFFIC_SORT})
  --top N                 Only the top N repos in the summary
  --paths                 Also show the most visited paths
  --referrers             Also show the top referring sites
  --format FORMAT         text, json, csv or md (default: text)
  --out FILE              Write the report to FILE instead of stdout
  --append                Append only new (date, repo) rows to --out
  --limit N               Max repos to scan (default: ${TRAFFIC_LIMIT})
  -v, --verbose           Show repos with no traffic too
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  github-helpers traffic
  github-helpers traffic --sort clones --top 10
  github-helpers traffic --repo me/proj --paths --referrers
  github-helpers traffic --format csv --out traffic.csv --append   ${DIM}# cron this${NC}

${BOLD}NOTE${NC}
  GitHub only keeps 14 days of traffic data, so the point of this command is
  to build your own history: --append writes only (date, repo) pairs the file
  does not already have, which makes repeated runs idempotent.

  These endpoints require push access, so repos you do not own are skipped.
EOF
  exit 0
}

cmd_traffic_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --user)       need_arg "--user" "${2:-}"; TRAFFIC_TARGET="$2"; TRAFFIC_TARGET_TYPE="user"; shift 2 ;;
      --org)        need_arg "--org" "${2:-}"; TRAFFIC_TARGET="$2"; TRAFFIC_TARGET_TYPE="org"; shift 2 ;;
      --repo)       need_arg "--repo" "${2:-}"; TRAFFIC_REPO="$2"; shift 2 ;;
      --per)        need_arg "--per" "${2:-}"; TRAFFIC_PER="$2"; shift 2 ;;
      --sort)       need_arg "--sort" "${2:-}"; TRAFFIC_SORT="$2"; shift 2 ;;
      --top)        need_arg "--top" "${2:-}"; TRAFFIC_TOP="$2"; shift 2 ;;
      --format)     need_arg "--format" "${2:-}"; TRAFFIC_FORMAT="$2"; shift 2 ;;
      --out)        need_arg "--out" "${2:-}"; TRAFFIC_OUT="$2"; shift 2 ;;
      --limit)      need_arg "--limit" "${2:-}"; TRAFFIC_LIMIT="$2"; shift 2 ;;
      --paths)      TRAFFIC_PATHS=true; shift ;;
      --referrers)  TRAFFIC_REFERRERS=true; shift ;;
      --append)     TRAFFIC_APPEND=true; shift ;;
      -v|--verbose) VERBOSE=true; shift ;;
      -h|--help)    cmd_traffic_usage ;;
      *) die "traffic: unknown option: $1" ;;
    esac
  done

  case "$TRAFFIC_PER" in day|week) ;; *) die "traffic: --per must be day or week" ;; esac
  case "$TRAFFIC_SORT" in views|clones) ;; *) die "traffic: --sort must be views or clones" ;; esac
  case "$TRAFFIC_FORMAT" in text|json|csv|md) ;; *) die "traffic: invalid --format '${TRAFFIC_FORMAT}' (use text, json, csv or md)" ;; esac
  [[ "$TRAFFIC_TOP" =~ ^[0-9]+$ ]] || die "traffic: --top must be a whole number"
  [[ "$TRAFFIC_LIMIT" =~ ^[0-9]+$ ]] || die "traffic: --limit must be a whole number"
  [ -n "$TRAFFIC_REPO" ] && [[ "$TRAFFIC_REPO" != */* ]] && die "traffic: --repo must be OWNER/NAME"
  $TRAFFIC_APPEND && [ -z "$TRAFFIC_OUT" ] && die "traffic: --append needs --out FILE"
  $TRAFFIC_APPEND && [ "$TRAFFIC_FORMAT" != "csv" ] && die "traffic: --append only makes sense with --format csv"
  return 0
}

cmd_traffic_main() {
  cmd_traffic_parse_args "$@"
  preflight_check
  skip_init

  if [ -z "$TRAFFIC_TARGET" ]; then
    TRAFFIC_TARGET=$(get_username)
    TRAFFIC_TARGET_TYPE="user"
  fi

  {
    header "Traffic"
    if [ -n "$TRAFFIC_REPO" ]; then
      echo -e "  Repo:   ${BOLD}${TRAFFIC_REPO}${NC}"
    else
      echo -e "  Target: ${BOLD}${TRAFFIC_TARGET}${NC}"
    fi
    echo -e "  Per:    ${BOLD}${TRAFFIC_PER}${NC}"
    echo ""
  } >&2

  local repo_file daily_file totals_file
  repo_file=$(resolve_repo_list "$TRAFFIC_TARGET" "$TRAFFIC_REPO" "$TRAFFIC_LIMIT" "traffic")
  daily_file=$(tmp_new); totals_file=$(tmp_new)

  echo -e "${DIM}Reading traffic for $(count_lines "$repo_file") repo(s)...${NC}" >&2
  local nwo views clones
  while IFS= read -r nwo; do
    [ -z "$nwo" ] && continue
    views=$(gh_api_try "$nwo" "repos/${nwo}/traffic/views?per=${TRAFFIC_PER}") || { scope_hint "repo"; continue; }
    clones=$(gh_api_try "$nwo" "repos/${nwo}/traffic/clones?per=${TRAFFIC_PER}") || continue

    # One row per bucket, views and clones joined on the timestamp.
    jq -rn --argjson v "$views" --argjson c "$clones" --arg repo "$nwo" '
      ( [ ($v.views // [])[]  | {k: .timestamp, vc: .count, vu: .uniques} ]
      + [ ($c.clones // [])[] | {k: .timestamp, cc: .count, cu: .uniques} ] )
      | group_by(.k)
      | map({date: (.[0].k[0:10]),
             views:  (map(.vc // 0) | add), unique_views:  (map(.vu // 0) | add),
             clones: (map(.cc // 0) | add), unique_clones: (map(.cu // 0) | add)})
      | .[] | [$repo, .date, (.views|tostring), (.unique_views|tostring),
               (.clones|tostring), (.unique_clones|tostring)] | @tsv' >> "$daily_file"

    printf '%s\t%s\t%s\t%s\t%s\n' "$nwo" \
      "$(printf '%s' "$views"  | jq -r '.count // 0')" \
      "$(printf '%s' "$views"  | jq -r '.uniques // 0')" \
      "$(printf '%s' "$clones" | jq -r '.count // 0')" \
      "$(printf '%s' "$clones" | jq -r '.uniques // 0')" >> "$totals_file"
  done < "$repo_file"

  if [ "$(count_lines "$totals_file")" -eq 0 ]; then
    echo -e "${YELLOW}No traffic data available.${NC}" >&2
    print_skips
    exit 0
  fi

  # ── Machine-readable: the daily rows are what you historize ────────────────
  if [ "$TRAFFIC_FORMAT" != "text" ]; then
    local rows
    rows=$(awk -F'\t' 'BEGIN {print "["} {printf "%s{\"date\":\"%s\",\"repo\":\"%s\",\"views\":%s,\"unique_views\":%s,\"clones\":%s,\"unique_clones\":%s}", (NR>1?",":""), $2, $1, $3, $4, $5, $6} END {print "]"}' "$daily_file" | jq -c 'sort_by(.date, .repo)')

    if $TRAFFIC_APPEND && [ -f "$TRAFFIC_OUT" ]; then
      local keys new_rows
      keys=$(tmp_new)
      # Existing keys are the first two CSV columns: date then repo.
      awk -F'","' 'NR > 1 {gsub(/^"/, "", $1); print $1 "\t" $2}' "$TRAFFIC_OUT" | sort -u > "$keys"
      new_rows=$(printf '%s' "$rows" | jq -c --rawfile k "$keys" '
        ($k | split("\n") | map(select(length > 0))) as $seen
        | map(select((.date + "\t" + .repo) as $key | ($seen | index($key)) == null))')
      local n_new
      n_new=$(printf '%s' "$new_rows" | jq 'length')
      if [ "$n_new" -eq 0 ]; then
        echo -e "${GREEN}Nothing new — ${TRAFFIC_OUT} is already up to date.${NC}" >&2
      else
        render_rows csv "$new_rows" | tail -n +2 >> "$TRAFFIC_OUT"
        echo -e "${GREEN}Done!${NC} Appended ${BOLD}${n_new}${NC} new row(s) to ${BOLD}${TRAFFIC_OUT}${NC}" >&2
      fi
      print_skips
      exit 0
    fi

    write_output "$TRAFFIC_OUT" "$(render_rows "$TRAFFIC_FORMAT" "$rows")"
    print_skips
    exit 0
  fi

  # ── Text summary ───────────────────────────────────────────────────────────
  local sort_col=2
  [ "$TRAFFIC_SORT" = "clones" ] && sort_col=4
  echo ""
  printf "  ${BOLD}%-45s %8s %8s %8s %8s${NC}\n" "REPOSITORY" "VIEWS" "UNIQUE" "CLONES" "UNIQUE"
  local shown=0 nwo v uv c uc tv=0 tuv=0 tc=0 tuc=0
  while IFS=$'\t' read -r nwo v uv c uc; do
    tv=$((tv + v)); tuv=$((tuv + uv)); tc=$((tc + c)); tuc=$((tuc + uc))
    if [ "$v" -eq 0 ] && [ "$c" -eq 0 ] && ! $VERBOSE; then continue; fi
    if [ "$TRAFFIC_TOP" -gt 0 ] && [ "$shown" -ge "$TRAFFIC_TOP" ]; then continue; fi
    shown=$((shown + 1))
    printf "  %-45s %8s %8s %8s %8s\n" "$nwo" "$v" "$uv" "$c" "$uc"
  done < <(sort -t$'\t' -k${sort_col} -rn "$totals_file")
  printf "  ${DIM}%-45s %8s %8s %8s %8s${NC}\n" "TOTAL" "$tv" "$tuv" "$tc" "$tuc"

  if $TRAFFIC_PATHS || $TRAFFIC_REFERRERS; then
    while IFS= read -r nwo; do
      [ -z "$nwo" ] && continue
      if $TRAFFIC_PATHS; then
        local paths
        paths=$(gh_api_try "$nwo" "repos/${nwo}/traffic/popular/paths") || continue
        if [ "$(printf '%s' "$paths" | jq 'length')" -gt 0 ]; then
          echo ""
          echo -e "  ${BOLD}Top paths — ${nwo}${NC}"
          printf '%s' "$paths" | jq -r '.[0:10][] | "    \(.count)\t\(.uniques)\t\(.path)"' \
            | while IFS=$'\t' read -r cnt uq p; do printf "    %6s %6s  %s\n" "$cnt" "$uq" "$p"; done
        fi
      fi
      if $TRAFFIC_REFERRERS; then
        local refs
        refs=$(gh_api_try "$nwo" "repos/${nwo}/traffic/popular/referrers") || continue
        if [ "$(printf '%s' "$refs" | jq 'length')" -gt 0 ]; then
          echo ""
          echo -e "  ${BOLD}Top referrers — ${nwo}${NC}"
          printf '%s' "$refs" | jq -r '.[0:10][] | "    \(.count)\t\(.uniques)\t\(.referrer)"' \
            | while IFS=$'\t' read -r cnt uq r; do printf "    %6s %6s  %s\n" "$cnt" "$uq" "$r"; done
        fi
      fi
    done < "$repo_file"
  fi

  echo ""
  print_skips
}
# =============================================================================
# COMMAND: notifications
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
NOTIF_REPO=""
NOTIF_REASON=""
NOTIF_TYPE=""
NOTIF_DAYS=""
NOTIF_LIMIT=0
NOTIF_FORMAT="text"
NOTIF_ALL=false
NOTIF_MARK_READ=false
NOTIF_UNSUB=false

NOTIF_REASONS="assign author comment ci_activity invitation manual mention review_requested security_alert state_change subscribed team_mention"

cmd_notifications_usage() {
  cat <<EOF
${BOLD}github-helpers notifications${NC} ${DIM}v${VERSION}${NC} — Triage your notification inbox
                                        ${DIM}(alias: github-helpers notifs)${NC}

${BOLD}USAGE${NC}
  github-helpers notifications [filters]
  github-helpers notifications [filters] --mark-read
  github-helpers notifications --repo OWNER/NAME --all --unsubscribe

${BOLD}FILTERS${NC}
  --repo OWNER/NAME       Only this repository
  --reason REASON         ${DIM}assign, author, comment, ci_activity, invitation, manual,${NC}
                          ${DIM}mention, review_requested, security_alert, state_change,${NC}
                          ${DIM}subscribed, team_mention${NC}
  --type TYPE             Issue, PullRequest, Release, Discussion, CheckSuite...
  --older-than N          Not updated in the last N days
  --unread                Only unread ${DIM}(default)${NC}
  --all                   Include already-read notifications
  --limit N               Cap the number shown

${BOLD}ACTIONS${NC}
  --mark-read             Mark the matched notifications as read
  --unsubscribe           Mute the matched threads permanently

${BOLD}I/O${NC}
  --format FORMAT         text, json, csv or md (default: text)
  --dry-run               Preview only
  -y, --yes               Skip confirmation prompt
  -v, --verbose           Show more detail
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  # clear a week of CI noise
  github-helpers notifications --reason ci_activity --older-than 7 --mark-read --dry-run
  github-helpers notifications --reason ci_activity --older-than 7 --mark-read -y

  # permanently mute every thread in one repo (--all covers read threads too)
  github-helpers notifications --repo owner/repo --all --unsubscribe --mark-read

${BOLD}NOTE${NC}
  gh does not request the 'notifications' scope by default:
    gh auth refresh -h github.com -s notifications

  --unsubscribe sets the thread to "ignored" rather than just dropping the
  subscription, because a plain unsubscribe silently resubscribes you on the
  next comment.
EOF
  exit 0
}

cmd_notifications_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)        need_arg "--repo" "${2:-}"; NOTIF_REPO="$2"; shift 2 ;;
      --reason)      need_arg "--reason" "${2:-}"; NOTIF_REASON="$2"; shift 2 ;;
      --type)        need_arg "--type" "${2:-}"; NOTIF_TYPE="$2"; shift 2 ;;
      --older-than)  need_arg "--older-than" "${2:-}"; NOTIF_DAYS="$2"; shift 2 ;;
      --limit)       need_arg "--limit" "${2:-}"; NOTIF_LIMIT="$2"; shift 2 ;;
      --format)      need_arg "--format" "${2:-}"; NOTIF_FORMAT="$2"; shift 2 ;;
      --unread)      NOTIF_ALL=false; shift ;;
      --all)         NOTIF_ALL=true; shift ;;
      --list)        shift ;;
      --mark-read)   NOTIF_MARK_READ=true; shift ;;
      --unsubscribe) NOTIF_UNSUB=true; shift ;;
      --dry-run)     DRY_RUN=true; shift ;;
      -y|--yes)      AUTO_YES=true; shift ;;
      -v|--verbose)  VERBOSE=true; shift ;;
      -h|--help)     cmd_notifications_usage ;;
      *) die "notifications: unknown option: $1" ;;
    esac
  done

  case "$NOTIF_FORMAT" in text|json|csv|md) ;; *) die "notifications: invalid --format '${NOTIF_FORMAT}' (use text, json, csv or md)" ;; esac
  [ -n "$NOTIF_DAYS" ] && { [[ "$NOTIF_DAYS" =~ ^[0-9]+$ ]] || die "notifications: --older-than must be a whole number of days"; }
  [[ "$NOTIF_LIMIT" =~ ^[0-9]+$ ]] || die "notifications: --limit must be a whole number"
  [ -n "$NOTIF_REPO" ] && [[ "$NOTIF_REPO" != */* ]] && die "notifications: --repo must be OWNER/NAME"
  if [ -n "$NOTIF_REASON" ]; then
    case " $NOTIF_REASONS " in
      *" $NOTIF_REASON "*) ;;
      *) die "notifications: unknown --reason '${NOTIF_REASON}' (valid: ${NOTIF_REASONS// /, })" ;;
    esac
  fi
  if [ "$NOTIF_FORMAT" != "text" ] && { $NOTIF_MARK_READ || $NOTIF_UNSUB; }; then
    die "notifications: --format is for reporting — drop --mark-read/--unsubscribe"
  fi
  return 0
}

cmd_notifications_main() {
  cmd_notifications_parse_args "$@"
  preflight_check
  skip_init

  local out=1
  [ "$NOTIF_FORMAT" != "text" ] && out=2

  local cutoff=""
  [ -n "$NOTIF_DAYS" ] && cutoff=$(cutoff_date "$NOTIF_DAYS" days)

  {
    header "Notifications"
    [ -n "$NOTIF_REPO" ] && echo -e "  Repo:      ${BOLD}${NOTIF_REPO}${NC}"
    [ -n "$NOTIF_REASON" ] && echo -e "  Reason:    ${BOLD}${NOTIF_REASON}${NC}"
    [ -n "$NOTIF_TYPE" ] && echo -e "  Type:      ${BOLD}${NOTIF_TYPE}${NC}"
    [ -n "$cutoff" ] && echo -e "  Older than:${BOLD} ${NOTIF_DAYS}${NC} days (before ${cutoff%%T*})"
    $NOTIF_ALL && echo -e "  Include:   ${BOLD}read and unread${NC}" || echo -e "  Include:   ${BOLD}unread only${NC}"
    $DRY_RUN && echo -e "  Mode:      ${YELLOW}DRY RUN${NC}"
    echo ""
  } >&$out

  # `before=` is a real server-side filter on updated_at, so "older than N
  # days" is a short request instead of a full-inbox download.
  local path="notifications?all=${NOTIF_ALL}&per_page=100"
  [ -n "$NOTIF_REPO" ] && path="repos/${NOTIF_REPO}/notifications?all=${NOTIF_ALL}&per_page=100"
  [ -n "$cutoff" ] && path="${path}&before=${cutoff}"

  local raw
  raw=$(gh_paginate "notifications" "$path") || {
    scope_hint "notifications"
    print_skips
    exit 0
  }

  local rows
  rows=$(printf '%s' "$raw" | jq -c \
    --arg reason "$NOTIF_REASON" --arg type "$NOTIF_TYPE" --arg cutoff "$cutoff" \
    --argjson limit "$NOTIF_LIMIT" '
    [ .[]
      | select($reason == "" or .reason == $reason)
      | select($type   == "" or (.subject.type // "") == $type)
      | select($cutoff == "" or .updated_at < $cutoff)
      | { id: .id,
          repo: (.repository.full_name // "?"),
          reason: .reason,
          type: (.subject.type // "?"),
          title: ((.subject.title // "") | gsub("[\t\n\r]"; " ") | .[0:70]),
          unread: .unread,
          updated: .updated_at,
          age: (((now - (.updated_at | fromdateiso8601)) / 86400) | floor) } ]
    | sort_by(.repo, -.age)
    | (if $limit > 0 then .[0:$limit] else . end)')

  local total
  total=$(printf '%s' "$rows" | jq 'length')
  if [ "$total" -eq 0 ]; then
    echo -e "${GREEN}Inbox clear — nothing matches.${NC}" >&$out
    print_skips
    exit 0
  fi

  if [ "$NOTIF_FORMAT" != "text" ]; then
    render_rows "$NOTIF_FORMAT" "$(printf '%s' "$rows" | jq 'map({repo, reason, type, title, age, unread, updated})')"
    print_skips
    exit 0
  fi

  echo -e "${YELLOW}${total} notification(s)${NC}"
  echo ""
  local last_repo="" repo reason type title age unread rcol reason_pad age_pad type_pad
  while IFS=$'\t' read -r repo reason type title age unread; do
    if [ "$repo" != "$last_repo" ]; then
      [ -n "$last_repo" ] && echo ""
      local n_in_repo
      n_in_repo=$(printf '%s' "$rows" | jq --arg r "$repo" '[.[] | select(.repo == $r)] | length')
      echo -e "  ${BOLD}${repo}${NC} ${DIM}(${n_in_repo})${NC}"
      last_repo="$repo"
    fi
    case "$reason" in
      security_alert)                    rcol="$RED" ;;
      mention|review_requested|assign)   rcol="$YELLOW" ;;
      *)                                 rcol="$DIM" ;;
    esac
    # Pad first, colour after: a colour code inside %-Ns breaks the column.
    printf -v reason_pad '%-16s' "$reason"
    printf -v age_pad    '%4s'   "${age}d"
    printf -v type_pad   '%-13s' "$type"
    echo -e "    ${rcol}${reason_pad}${NC} ${DIM}${age_pad}${NC}  ${type_pad} ${title}"
  done < <(printf '%s' "$rows" | jq -r '.[] | [.repo, .reason, .type, .title, (.age|tostring), (.unread|tostring)] | @tsv')
  echo ""

  if ! $NOTIF_MARK_READ && ! $NOTIF_UNSUB; then
    print_skips
    exit 0
  fi

  if $DRY_RUN; then
    echo -e "${YELLOW}DRY RUN — nothing was changed.${NC}"
    print_skips
    exit 0
  fi

  local -a actions=()
  $NOTIF_UNSUB && actions+=("unsubscribe")
  $NOTIF_MARK_READ && actions+=("mark read")
  local action_str
  action_str=$(printf '%s and ' "${actions[@]}"); action_str="${action_str% and }"
  if ! confirm "${action_str^} ${total} notification(s)?"; then
    echo "Cancelled."
    exit 0
  fi

  # PUT /notifications marks EVERYTHING read up to last_read_at, so it is only
  # equivalent to the selection when no reason/type predicate narrowed it.
  if $NOTIF_MARK_READ && ! $NOTIF_UNSUB && [ -z "$NOTIF_REASON" ] && [ -z "$NOTIF_TYPE" ]; then
    local bulk_path="notifications" stamp
    [ -n "$NOTIF_REPO" ] && bulk_path="repos/${NOTIF_REPO}/notifications"
    stamp="${cutoff:-$(cutoff_date 0 days)}"
    if jq -n --arg t "$stamp" '{last_read_at: $t, read: true}' \
         | gh api --method PUT "$bulk_path" --input - &>/dev/null; then
      echo -e "${GREEN}Done!${NC} Marked everything up to ${BOLD}${stamp%%T*}${NC} as read ${DIM}(1 request)${NC}"
    else
      die "notifications: bulk mark-read failed"
    fi
    print_skips
    exit 0
  fi

  local marked=0 muted=0 fail=0 id
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    if $NOTIF_UNSUB; then
      if jq -n '{ignored: true}' | gh api --method PUT "notifications/threads/${id}/subscription" --input - &>/dev/null; then
        muted=$((muted + 1))
      else
        fail=$((fail + 1))
      fi
    fi
    if $NOTIF_MARK_READ; then
      if gh api --method PATCH "notifications/threads/${id}" &>/dev/null; then
        marked=$((marked + 1))
      else
        fail=$((fail + 1))
      fi
    fi
  done < <(printf '%s' "$rows" | jq -r '.[].id')

  echo ""
  echo -e "${GREEN}Done!${NC} Marked read: ${BOLD}${marked}${NC}, Muted: ${BOLD}${muted}${NC}, Failed: ${BOLD}${fail}${NC}"
  print_skips
}

# =============================================================================
# COMMAND: invite-cleanup
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
INVITE_ORG=""
INVITE_REPO=""
INVITE_DAYS=""
INVITE_DIRECTION="incoming"
INVITE_ACCEPT=false
INVITE_DECLINE=false

cmd_invite_cleanup_usage() {
  cat <<EOF
${BOLD}github-helpers invite-cleanup${NC} ${DIM}v${VERSION}${NC} — Pending repository and org invitations

${BOLD}USAGE${NC}
  github-helpers invite-cleanup
  github-helpers invite-cleanup --accept --repo OWNER/NAME
  github-helpers invite-cleanup --outgoing --org my-company --decline --older-than 30

${BOLD}OPTIONS${NC}
  --incoming              Invitations sent TO you ${DIM}(default)${NC}
  --outgoing              Invitations YOU sent ${DIM}(requires --repo or --org)${NC}
  --repo OWNER/NAME       Restrict to one repository
  --org NAME              Restrict to one organization
  --older-than N          Only invitations older than N days
  --accept                Accept the listed invitations
  --decline               Decline them ${DIM}(revoke, in --outgoing mode)${NC}
  --dry-run               Preview only
  -y, --yes               Skip confirmation prompt
  -v, --verbose           Show more detail
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  github-helpers invite-cleanup
  github-helpers invite-cleanup --accept --repo friend/project
  github-helpers invite-cleanup --decline
  github-helpers invite-cleanup --outgoing --org my-company --older-than 60

${BOLD}NOTE${NC}
  Listing is the default; --accept and --decline are never implicit.

  --outgoing requires --repo or --org. GraphQL exposes no outgoing-invitation
  connection, so a whole-account scan would cost one REST call per repository;
  --org answers in a single call via /orgs/{org}/invitations.

  There is no REST endpoint to DECLINE an organization invitation. Those are
  reported with a link and counted under "Manual", not as failures.
EOF
  exit 0
}

cmd_invite_cleanup_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --org)         need_arg "--org" "${2:-}"; INVITE_ORG="$2"; shift 2 ;;
      --repo)        need_arg "--repo" "${2:-}"; INVITE_REPO="$2"; shift 2 ;;
      --older-than)  need_arg "--older-than" "${2:-}"; INVITE_DAYS="$2"; shift 2 ;;
      --incoming)    INVITE_DIRECTION="incoming"; shift ;;
      --outgoing)    INVITE_DIRECTION="outgoing"; shift ;;
      --accept)      INVITE_ACCEPT=true; shift ;;
      --decline)     INVITE_DECLINE=true; shift ;;
      --dry-run)     DRY_RUN=true; shift ;;
      -y|--yes)      AUTO_YES=true; shift ;;
      -v|--verbose)  VERBOSE=true; shift ;;
      -h|--help)     cmd_invite_cleanup_usage ;;
      *) die "invite-cleanup: unknown option: $1" ;;
    esac
  done

  $INVITE_ACCEPT && $INVITE_DECLINE && die "invite-cleanup: --accept and --decline are mutually exclusive"
  [ -n "$INVITE_DAYS" ] && { [[ "$INVITE_DAYS" =~ ^[0-9]+$ ]] || die "invite-cleanup: --older-than must be a whole number of days"; }
  [ -n "$INVITE_REPO" ] && [[ "$INVITE_REPO" != */* ]] && die "invite-cleanup: --repo must be OWNER/NAME"
  if [ "$INVITE_DIRECTION" = "outgoing" ]; then
    [ -z "$INVITE_ORG" ] && [ -z "$INVITE_REPO" ] \
      && die "invite-cleanup: --outgoing requires --repo or --org (a full-account scan costs one request per repo)"
    $INVITE_ACCEPT && die "invite-cleanup: --accept makes no sense for invitations you sent"
  fi
  return 0
}

cmd_invite_cleanup_main() {
  cmd_invite_cleanup_parse_args "$@"
  preflight_check
  skip_init

  local cutoff=""
  [ -n "$INVITE_DAYS" ] && cutoff=$(cutoff_date "$INVITE_DAYS" days)

  header "Invitations"
  echo -e "  Direction: ${BOLD}${INVITE_DIRECTION}${NC}"
  [ -n "$INVITE_ORG" ] && echo -e "  Org:       ${BOLD}${INVITE_ORG}${NC}"
  [ -n "$INVITE_REPO" ] && echo -e "  Repo:      ${BOLD}${INVITE_REPO}${NC}"
  [ -n "$cutoff" ] && echo -e "  Older than:${BOLD} ${INVITE_DAYS}${NC} days"
  $DRY_RUN && echo -e "  Mode:      ${YELLOW}DRY RUN${NC}"
  echo ""

  local items
  items=$(tmp_new)

  if [ "$INVITE_DIRECTION" = "incoming" ]; then
    local repo_inv org_inv
    repo_inv=$(gh_paginate "repository invitations" "user/repository_invitations?per_page=100") || repo_inv='[]'
    printf '%s' "$repo_inv" | jq -r --arg cutoff "$cutoff" --arg repo "$INVITE_REPO" '
      .[] | select($cutoff == "" or .created_at < $cutoff)
          | select($repo == "" or .repository.full_name == $repo)
          | ["repo", (.id|tostring), .repository.full_name, (.inviter.login // "?"),
             (.permissions // "?"), .created_at, (if .expired then "expired" else "" end)] | @tsv' >> "$items"

    org_inv=$(gh_paginate "org memberships" "user/memberships/orgs?state=pending&per_page=100") || org_inv='[]'
    printf '%s' "$org_inv" | jq -r '
      .[] | select(.state == "pending")
          | ["org", .organization.login, .organization.login, "-", (.role // "member"), "", ""] | @tsv' >> "$items"
  else
    if [ -n "$INVITE_ORG" ]; then
      local oi
      oi=$(gh_paginate "orgs/${INVITE_ORG}/invitations" "orgs/${INVITE_ORG}/invitations?per_page=100") || oi='[]'
      printf '%s' "$oi" | jq -r --arg org "$INVITE_ORG" --arg cutoff "$cutoff" '
        .[] | select($cutoff == "" or .created_at < $cutoff)
            | ["orgout", (.id|tostring), $org, (.login // .email // "?"),
               (.role // "?"), (.created_at // ""), ""] | @tsv' >> "$items"
    fi
    if [ -n "$INVITE_REPO" ]; then
      local ri
      ri=$(gh_paginate "$INVITE_REPO" "repos/${INVITE_REPO}/invitations?per_page=100") || ri='[]'
      printf '%s' "$ri" | jq -r --arg repo "$INVITE_REPO" --arg cutoff "$cutoff" '
        .[] | select($cutoff == "" or .created_at < $cutoff)
            | ["repoout", (.id|tostring), $repo, (.invitee.login // "?"),
               (.permissions // "?"), .created_at, ""] | @tsv' >> "$items"
    fi
  fi

  local total
  total=$(count_lines "$items")
  if [ "$total" -eq 0 ]; then
    echo -e "${GREEN}No pending invitations.${NC}"
    print_skips
    exit 0
  fi

  echo -e "${YELLOW}${total} pending invitation(s)${NC}"
  echo ""
  local kind id subject who perm created flag
  while IFS=$'\t' read -r kind id subject who perm created flag; do
    local label="${created%%T*}"
    [ -n "$flag" ] && label="${label} ${YELLOW}${flag}${NC}"
    case "$kind" in
      repo)     echo -e "  ${DIM}repo${NC}  ${BOLD}${subject}${NC}  from ${who}  ${perm}  ${DIM}${label}${NC}" ;;
      org)      echo -e "  ${DIM}org${NC}   ${BOLD}${subject}${NC}  role ${perm}" ;;
      orgout)   echo -e "  ${DIM}org${NC}   ${BOLD}${subject}${NC}  -> ${who}  ${perm}  ${DIM}${label}${NC}" ;;
      repoout)  echo -e "  ${DIM}repo${NC}  ${BOLD}${subject}${NC}  -> ${who}  ${perm}  ${DIM}${label}${NC}" ;;
    esac
  done < "$items"
  echo ""

  if ! $INVITE_ACCEPT && ! $INVITE_DECLINE; then
    print_skips
    exit 0
  fi
  if $DRY_RUN; then
    echo -e "${YELLOW}DRY RUN — nothing was changed.${NC}"
    print_skips
    exit 0
  fi

  local verb="Accept"
  $INVITE_DECLINE && { verb="Decline"; [ "$INVITE_DIRECTION" = "outgoing" ] && verb="Revoke"; }
  if ! confirm "${verb} ${total} invitation(s)?"; then
    echo "Cancelled."
    exit 0
  fi

  local ok=0 fail=0 manual=0
  while IFS=$'\t' read -r kind id subject who perm created flag; do
    case "${kind}:$($INVITE_ACCEPT && echo accept || echo decline)" in
      repo:accept)
        gh api --method PATCH "user/repository_invitations/${id}" &>/dev/null && ok=$((ok+1)) || fail=$((fail+1)) ;;
      repo:decline)
        gh api --method DELETE "user/repository_invitations/${id}" &>/dev/null && ok=$((ok+1)) || fail=$((fail+1)) ;;
      org:accept)
        jq -n '{state:"active"}' | gh api --method PATCH "user/memberships/orgs/${subject}" --input - &>/dev/null \
          && ok=$((ok+1)) || fail=$((fail+1)) ;;
      org:decline)
        manual=$((manual+1))
        echo -e "  ${DIM}${subject}: declining an org invitation is not exposed by the REST API${NC}"
        echo -e "  ${DIM}  -> https://github.com/orgs/${subject}/invitation${NC}" ;;
      orgout:decline)
        gh api --method DELETE "orgs/${subject}/invitations/${id}" &>/dev/null && ok=$((ok+1)) || fail=$((fail+1)) ;;
      repoout:decline)
        gh api --method DELETE "repos/${subject}/invitations/${id}" &>/dev/null && ok=$((ok+1)) || fail=$((fail+1)) ;;
      *) manual=$((manual+1)) ;;
    esac
  done < "$items"

  echo ""
  echo -e "${GREEN}Done!${NC} ${verb}d: ${BOLD}${ok}${NC}, Manual: ${BOLD}${manual}${NC}, Failed: ${BOLD}${fail}${NC}"
  print_skips
}
# =============================================================================
# COMMAND: org-audit
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
ORG_AUDIT_ORG=""
ORG_AUDIT_FORMAT="text"
ORG_AUDIT_ONLY_2FA=false
ORG_AUDIT_ONLY_ADMINS=false
ORG_AUDIT_FAIL_ON_ISSUES=false
ORG_AUDIT_CHECKS=""

cmd_org_audit_usage() {
  cat <<EOF
${BOLD}github-helpers org-audit${NC} ${DIM}v${VERSION}${NC} — Organization security and membership posture

${BOLD}USAGE${NC}
  github-helpers org-audit --org NAME [options]

${BOLD}OPTIONS${NC}
  --org NAME              Organization to audit ${DIM}(required)${NC}
  --2fa                   Only the two-factor checks
  --admins                Only the owner-count check
  --format FORMAT         text, json or csv (default: text)
  --fail-on-issues        Exit non-zero when the audit finds problems
  -v, --verbose           Show more detail
  -h, --help              Show this help

${BOLD}CHECKS${NC}
  2fa_required            Two-factor enforced organization-wide
  2fa_members             Members with two-factor disabled
  owner_count             Too many, or too few, owners
  outside_collaborators   Number of outside collaborators
  pending_invitations     Stale invitations still outstanding
  default_repo_permission Base permission granted on every new repo
  member_repo_creation    Whether members can create public repos
  teams                   Access managed through teams rather than per person

${BOLD}EXIT CODES${NC} (only with --fail-on-issues)
  0  no problems            2  at least one FAIL
  1  fatal error            3  no FAIL or SKIP, at least one WARN
                            4  no FAIL, but a check could not run (SKIP)
  ${DIM}An incomplete audit outranks a known warning: you cannot know what the${NC}
  ${DIM}check that did not run would have found.${NC}

${BOLD}EXAMPLES${NC}
  github-helpers org-audit --org my-company
  github-helpers org-audit --org my-company --format json | jq .summary
  github-helpers org-audit --org my-company --fail-on-issues   ${DIM}# in CI${NC}

${BOLD}NOTE${NC}
  This is org-level only and never iterates repositories. For per-repository
  outside-collaborator access, use ${BOLD}collaborator-audit${NC}.

  Several endpoints are owner-only; as a plain member most checks report SKIP:
    gh auth refresh -h github.com -s read:org,admin:org
EOF
  exit 0
}

cmd_org_audit_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --org)            need_arg "--org" "${2:-}"; ORG_AUDIT_ORG="$2"; shift 2 ;;
      --format)         need_arg "--format" "${2:-}"; ORG_AUDIT_FORMAT="$2"; shift 2 ;;
      --2fa)            ORG_AUDIT_ONLY_2FA=true; shift ;;
      --admins)         ORG_AUDIT_ONLY_ADMINS=true; shift ;;
      --fail-on-issues) ORG_AUDIT_FAIL_ON_ISSUES=true; shift ;;
      -v|--verbose)     VERBOSE=true; shift ;;
      -h|--help)        cmd_org_audit_usage ;;
      *) die "org-audit: unknown option: $1" ;;
    esac
  done
  [ -z "$ORG_AUDIT_ORG" ] && die "org-audit: --org is required"
  case "$ORG_AUDIT_FORMAT" in text|json|csv) ;; *) die "org-audit: invalid --format '${ORG_AUDIT_FORMAT}' (use text, json or csv)" ;; esac
  return 0
}

# audit_check <id> <PASS|WARN|FAIL|SKIP> <message> [json-value]
# One JSON line per check. Text, JSON, CSV and the exit code are all pure
# functions of this ledger, so they cannot drift, and it survives subshells.
audit_check() {
  jq -nc --arg id "$1" --arg status "$2" --arg message "$3" \
         --argjson value "${4:-null}" \
         '{id:$id, status:$status, message:$message, value:$value}' >> "$ORG_AUDIT_CHECKS"
}

cmd_org_audit_wants() {
  # With no --2fa/--admins selector every check runs.
  if ! $ORG_AUDIT_ONLY_2FA && ! $ORG_AUDIT_ONLY_ADMINS; then return 0; fi
  case "$1" in
    2fa_required|2fa_members) $ORG_AUDIT_ONLY_2FA ;;
    owner_count)              $ORG_AUDIT_ONLY_ADMINS ;;
    *) return 1 ;;
  esac
}

cmd_org_audit_main() {
  cmd_org_audit_parse_args "$@"
  preflight_check
  skip_init
  ORG_AUDIT_CHECKS=$(tmp_new)

  local out=1
  [ "$ORG_AUDIT_FORMAT" != "text" ] && out=2

  {
    header "Org Audit"
    echo -e "  Org: ${BOLD}${ORG_AUDIT_ORG}${NC}"
    echo ""
  } >&$out

  # One request feeds four checks plus the plan line.
  local org_json
  org_json=$(gh_api_try "$ORG_AUDIT_ORG" "orgs/${ORG_AUDIT_ORG}") || {
    scope_hint "read:org,admin:org"
    die "org-audit: cannot read organization '${ORG_AUDIT_ORG}'"
  }

  local members_total=0 mem
  mem=$(gh_paginate "${ORG_AUDIT_ORG} members" "orgs/${ORG_AUDIT_ORG}/members?per_page=100") \
    && members_total=$(printf '%s' "$mem" | jq 'length') || members_total=0

  # ── 1. 2FA enforced org-wide ───────────────────────────────────────────────
  local twofa
  twofa=$(printf '%s' "$org_json" | jq -r '.two_factor_requirement_enabled // "null"')
  if cmd_org_audit_wants 2fa_required; then
    case "$twofa" in
      true)  audit_check 2fa_required PASS "enforced organization-wide" true ;;
      false) audit_check 2fa_required FAIL "not enforced organization-wide" false ;;
      *)     audit_check 2fa_required SKIP "only visible to organization owners" ;;
    esac
  fi

  # ── 2. Members without 2FA (pointless when 2FA is already enforced) ────────
  if cmd_org_audit_wants 2fa_members && [ "$twofa" != "true" ]; then
    local nofa
    if nofa=$(gh_paginate "${ORG_AUDIT_ORG} 2fa_disabled" "orgs/${ORG_AUDIT_ORG}/members?filter=2fa_disabled&per_page=100"); then
      local n
      n=$(printf '%s' "$nofa" | jq 'length')
      if [ "$n" -eq 0 ]; then
        audit_check 2fa_members PASS "every member has two-factor enabled" 0
      else
        audit_check 2fa_members FAIL "${n} member(s) without two-factor: $(printf '%s' "$nofa" | jq -r '.[0:20] | map(.login) | join(", ")')" "$n"
      fi
    else
      audit_check 2fa_members SKIP "owner-only endpoint"
    fi
  elif cmd_org_audit_wants 2fa_members; then
    audit_check 2fa_members PASS "not applicable — two-factor is enforced for everyone" 0
  fi

  # ── 3. Owner count ─────────────────────────────────────────────────────────
  if cmd_org_audit_wants owner_count; then
    local admins
    if admins=$(gh_paginate "${ORG_AUDIT_ORG} admins" "orgs/${ORG_AUDIT_ORG}/members?role=admin&per_page=100"); then
      local n cap
      n=$(printf '%s' "$admins" | jq 'length')
      cap=$(( members_total / 10 )); [ "$cap" -lt 3 ] && cap=3
      if [ "$n" -eq 0 ]; then
        audit_check owner_count FAIL "no owner visible" 0
      elif [ "$n" -eq 1 ]; then
        audit_check owner_count WARN "a single owner — bus factor of one" 1
      elif [ "$n" -gt "$cap" ]; then
        audit_check owner_count WARN "${n} owners for ${members_total} members" "$n"
      else
        audit_check owner_count PASS "${n} owner(s) for ${members_total} members" "$n"
      fi
    else
      audit_check owner_count SKIP "cannot list organization admins"
    fi
  fi

  # ── 4. Outside collaborators ───────────────────────────────────────────────
  if cmd_org_audit_wants outside_collaborators; then
    local oc
    if oc=$(gh_paginate "${ORG_AUDIT_ORG} outside collaborators" "orgs/${ORG_AUDIT_ORG}/outside_collaborators?per_page=100"); then
      local n
      n=$(printf '%s' "$oc" | jq 'length')
      if [ "$n" -eq 0 ]; then
        audit_check outside_collaborators PASS "none" 0
      elif [ "$members_total" -gt 0 ] && [ "$n" -gt "$members_total" ]; then
        audit_check outside_collaborators FAIL "${n} outside collaborators for ${members_total} members" "$n"
      else
        audit_check outside_collaborators WARN "${n} outside collaborator(s) — audit their per-repo access" "$n"
      fi
    else
      audit_check outside_collaborators SKIP "cannot list outside collaborators"
    fi
  fi

  # ── 5. Pending invitations ─────────────────────────────────────────────────
  if cmd_org_audit_wants pending_invitations; then
    local inv
    if inv=$(gh_paginate "${ORG_AUDIT_ORG} invitations" "orgs/${ORG_AUDIT_ORG}/invitations?per_page=100"); then
      local n stale cut
      n=$(printf '%s' "$inv" | jq 'length')
      cut=$(cutoff_date 30 days)
      stale=$(printf '%s' "$inv" | jq --arg c "$cut" '[.[] | select((.created_at // "") < $c)] | length')
      if [ "$n" -eq 0 ]; then
        audit_check pending_invitations PASS "none outstanding" 0
      elif [ "$stale" -gt 0 ]; then
        audit_check pending_invitations WARN "${stale} of ${n} invitation(s) older than 30 days" "$stale"
      else
        audit_check pending_invitations PASS "${n} recent invitation(s)" "$n"
      fi
    else
      audit_check pending_invitations SKIP "cannot list organization invitations"
    fi
  fi

  # ── 6. Default repository permission ───────────────────────────────────────
  if cmd_org_audit_wants default_repo_permission; then
    local perm
    perm=$(printf '%s' "$org_json" | jq -r '.default_repository_permission // "null"')
    case "$perm" in
      none|read) audit_check default_repo_permission PASS "every member gets '${perm}' on new repos" "\"$perm\"" ;;
      write)     audit_check default_repo_permission WARN "every member gets 'write' on new repos" "\"$perm\"" ;;
      admin)     audit_check default_repo_permission FAIL "every member gets 'admin' on new repos" "\"$perm\"" ;;
      *)         audit_check default_repo_permission SKIP "only visible to organization owners" ;;
    esac
  fi

  # ── 7. Member repository creation ──────────────────────────────────────────
  if cmd_org_audit_wants member_repo_creation; then
    local can_pub can_any
    can_pub=$(printf '%s' "$org_json" | jq -r '.members_can_create_public_repositories // "null"')
    can_any=$(printf '%s' "$org_json" | jq -r '.members_can_create_repositories // "null"')
    if [ "$can_pub" = "null" ] && [ "$can_any" = "null" ]; then
      audit_check member_repo_creation SKIP "only visible to organization owners"
    elif [ "$can_pub" = "true" ]; then
      audit_check member_repo_creation WARN "any member can create PUBLIC repositories" true
    else
      audit_check member_repo_creation PASS "members cannot create public repositories" false
    fi
  fi

  # ── 8. Teams ───────────────────────────────────────────────────────────────
  if cmd_org_audit_wants teams; then
    local teams
    if teams=$(gh_paginate "${ORG_AUDIT_ORG} teams" "orgs/${ORG_AUDIT_ORG}/teams?per_page=100"); then
      local n
      n=$(printf '%s' "$teams" | jq 'length')
      if [ "$n" -eq 0 ] && [ "$members_total" -gt 5 ]; then
        audit_check teams WARN "no teams for ${members_total} members — access is managed person by person" 0
      else
        audit_check teams PASS "${n} team(s)" "$n"
      fi
    else
      audit_check teams SKIP "cannot list teams"
    fi
  fi

  # ── Render ─────────────────────────────────────────────────────────────────
  local n_fail n_warn n_skip n_pass
  n_fail=$(grep -c '"status":"FAIL"' "$ORG_AUDIT_CHECKS" || true)
  n_warn=$(grep -c '"status":"WARN"' "$ORG_AUDIT_CHECKS" || true)
  n_skip=$(grep -c '"status":"SKIP"' "$ORG_AUDIT_CHECKS" || true)
  n_pass=$(grep -c '"status":"PASS"' "$ORG_AUDIT_CHECKS" || true)

  case "$ORG_AUDIT_FORMAT" in
    json)
      jq -s --arg org "$ORG_AUDIT_ORG" \
        '{org:$org, checks:., summary:(group_by(.status) | map({key:.[0].status, value:length}) | from_entries)}' \
        "$ORG_AUDIT_CHECKS"
      ;;
    csv)
      jq -s -r '["check","status","message","value"], (.[] | [.id, .status, .message, (.value|tostring)]) | @csv' \
        "$ORG_AUDIT_CHECKS"
      ;;
    text)
      local id status message col pad
      while IFS=$'\t' read -r id status message; do
        case "$status" in
          PASS) col="$GREEN" ;; WARN) col="$YELLOW" ;; FAIL) col="$RED" ;; *) col="$DIM" ;;
        esac
        printf -v pad '%-4s' "$status"
        printf -v id_pad '%-24s' "$id"
        echo -e "  ${col}${pad}${NC}  ${id_pad} ${message}"
        [ "$id" = "outside_collaborators" ] && [ "$status" != "PASS" ] \
          && echo -e "        ${DIM}-> github-helpers collaborator-audit --org ${ORG_AUDIT_ORG}${NC}"
      done < <(jq -r '[.id, .status, .message] | @tsv' "$ORG_AUDIT_CHECKS")

      local seats filled
      seats=$(printf '%s' "$org_json" | jq -r '.plan.seats // empty')
      filled=$(printf '%s' "$org_json" | jq -r '.plan.filled_seats // empty')
      # Free plans report seats: 0, which would render as "150/0".
      if [ -n "$filled" ]; then
        echo ""
        if [ -n "$seats" ] && [ "$seats" -gt 0 ] 2>/dev/null; then
          echo -e "  ${DIM}INFO  plan: $(printf '%s' "$org_json" | jq -r '.plan.name // "?"') — ${filled}/${seats} seats filled${NC}"
        else
          echo -e "  ${DIM}INFO  plan: $(printf '%s' "$org_json" | jq -r '.plan.name // "?"') — ${filled} member(s)${NC}"
        fi
      fi
      echo ""
      echo -e "  ${GREEN}PASS ${n_pass}${NC}   ${YELLOW}WARN ${n_warn}${NC}   ${RED}FAIL ${n_fail}${NC}   ${DIM}SKIP ${n_skip}${NC}"
      ;;
  esac

  print_skips

  # Precedence FAIL > SKIP > WARN. An incomplete audit outranks a known
  # warning: you do not know what the check that did not run would have found.
  local code=0
  if $ORG_AUDIT_FAIL_ON_ISSUES; then
    if   [ "$n_fail" -gt 0 ]; then code=2
    elif [ "$n_skip" -gt 0 ]; then code=4
    elif [ "$n_warn" -gt 0 ]; then code=3
    fi
  fi
  exit "$code"
}
# =============================================================================
# COMMAND: follow-audit
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
FA_NOT_FOLLOWING_BACK=false
FA_NOT_FOLLOWED_BY_ME=false
FA_MUTUALS=false
FA_UNFOLLOW=false
FA_EXCLUDE=""
FA_INACTIVE=""
FA_FORMAT="text"
FA_OUT="unfollow.txt"
FA_SAVE_LIST=false
FA_FROM=""
FA_LIMIT=0

cmd_follow_audit_usage() {
  cat <<EOF
${BOLD}github-helpers follow-audit${NC} ${DIM}v${VERSION}${NC} — Who follows you back, and who does not
                                        ${DIM}(alias: github-helpers follow)${NC}

${BOLD}USAGE${NC}
  github-helpers follow-audit
  github-helpers follow-audit --not-following-back --inactive 365
  github-helpers follow-audit --not-following-back --unfollow --dry-run

${BOLD}SELECTORS${NC}
  --not-following-back    You follow them, they do not follow you ${DIM}(default view)${NC}
  --not-followed-by-me    They follow you, you do not follow back
  --mutuals               Mutual follows

${BOLD}FILTERS${NC}
  --exclude FILE          Logins never to unfollow, one per line ${DIM}(# comments ok)${NC}
  --inactive N            No push to a public repo of theirs in N days
  --limit N               Cap the number listed

${BOLD}ACTION${NC}
  --unfollow              Unfollow ${DIM}(only applies to --not-following-back)${NC}

${BOLD}I/O${NC}
  --dry-run               Preview only — writes an annotated list
  --out FILE              List file (default: ${FA_OUT}), or report file with --format
  --save-list             Save the list even outside --dry-run
  --from FILE             Unfollow the logins listed in FILE
  --format FORMAT         text, json, csv or md (default: text)

${BOLD}FLAGS${NC}
  -y, --yes               Skip confirmation prompt
  -v, --verbose           Show more detail
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  github-helpers follow-audit
  github-helpers follow-audit --not-followed-by-me
  github-helpers follow-audit --format csv --out follows.csv
  github-helpers follow-audit --not-following-back --exclude keep.txt --unfollow --dry-run

${BOLD}NOTE${NC}
  The default is read-only. Unfollowing needs --unfollow, and goes through the
  dry-run -> edit the file -> --from loop so a human reads every login first.

  --inactive measures the last push to a PUBLIC repository they own. Someone
  working only in private repos will look inactive; it is a hint, not proof.

  Unfollowing requires the 'user:follow' scope:
    gh auth refresh -h github.com -s user:follow
EOF
  exit 0
}

cmd_follow_audit_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --exclude)             need_arg "--exclude" "${2:-}"; FA_EXCLUDE="$2"; shift 2 ;;
      --inactive)            need_arg "--inactive" "${2:-}"; FA_INACTIVE="$2"; shift 2 ;;
      --limit)               need_arg "--limit" "${2:-}"; FA_LIMIT="$2"; shift 2 ;;
      --format)              need_arg "--format" "${2:-}"; FA_FORMAT="$2"; shift 2 ;;
      --out)                 need_arg "--out" "${2:-}"; FA_OUT="$2"; FA_SAVE_LIST=true; shift 2 ;;
      --from)                need_arg "--from" "${2:-}"; FA_FROM="$2"; shift 2 ;;
      --not-following-back)  FA_NOT_FOLLOWING_BACK=true; shift ;;
      --not-followed-by-me)  FA_NOT_FOLLOWED_BY_ME=true; shift ;;
      --mutuals)             FA_MUTUALS=true; shift ;;
      --unfollow)            FA_UNFOLLOW=true; shift ;;
      --save-list)           FA_SAVE_LIST=true; shift ;;
      --dry-run)             DRY_RUN=true; shift ;;
      -y|--yes)              AUTO_YES=true; shift ;;
      -v|--verbose)          VERBOSE=true; shift ;;
      -h|--help)             cmd_follow_audit_usage ;;
      *) die "follow-audit: unknown option: $1" ;;
    esac
  done

  case "$FA_FORMAT" in text|json|csv|md) ;; *) die "follow-audit: invalid --format '${FA_FORMAT}' (use text, json, csv or md)" ;; esac
  [ -n "$FA_INACTIVE" ] && { [[ "$FA_INACTIVE" =~ ^[0-9]+$ ]] || die "follow-audit: --inactive must be a whole number of days"; }
  [[ "$FA_LIMIT" =~ ^[0-9]+$ ]] || die "follow-audit: --limit must be a whole number"

  # A silently-missing whitelist is the disaster case for this command.
  [ -n "$FA_EXCLUDE" ] && [ ! -f "$FA_EXCLUDE" ] && die "follow-audit: file not found: ${FA_EXCLUDE}"
  [ -n "$FA_FROM" ] && [ ! -f "$FA_FROM" ] && die "follow-audit: file not found: ${FA_FROM}"

  if $FA_UNFOLLOW && { $FA_NOT_FOLLOWED_BY_ME || $FA_MUTUALS; }; then
    die "follow-audit: --unfollow only applies to --not-following-back"
  fi
  if [ "$FA_FORMAT" != "text" ] && { $FA_UNFOLLOW || $DRY_RUN; }; then
    die "follow-audit: --format is for reporting — drop --unfollow/--dry-run"
  fi
  # Default view.
  if ! $FA_NOT_FOLLOWING_BACK && ! $FA_NOT_FOLLOWED_BY_ME && ! $FA_MUTUALS; then
    FA_NOT_FOLLOWING_BACK=true
  fi
  return 0
}

# cmd_follow_audit_fetch <following|followers> -> TSV: login  reciprocal  followers  last_push
# GraphQL answers "do they follow me back" inside the same page, so
# --not-following-back never has to fetch the followers list at all.
cmd_follow_audit_fetch() {
  local which="$1" has_next="true" fetched=0 rc result recip
  local -a cursor_arg=("-F" "cursor=null")
  [ "$which" = "following" ] && recip="isFollowingViewer" || recip="viewerIsFollowing"

  while [ "$has_next" = "true" ]; do
    rc=0
    result=$(gh_api_retry graphql -f query="
      query(\$cursor: String) {
        viewer {
          ${which}(first: 100, after: \$cursor) {
            totalCount
            pageInfo { hasNextPage endCursor }
            nodes {
              login
              ${recip}
              followers { totalCount }
              repositories(first: 1, ownerAffiliations: [OWNER], privacy: PUBLIC,
                           orderBy: {field: PUSHED_AT, direction: DESC}) { nodes { pushedAt } }
            }
          }
        }
      }" "${cursor_arg[@]}") || rc=$?

    local gql_error
    gql_error=$(printf '%s' "$result" | jq -r '.errors[0].message // empty' 2>/dev/null || true)
    [ -n "$gql_error" ] && warn "GitHub API: ${gql_error}"
    if [ "$rc" -ne 0 ] && [ -z "$gql_error" ]; then
      die "follow-audit: GraphQL request failed"
    fi

    printf '%s' "$result" | jq -r --arg w "$which" --arg r "$recip" '
      .data.viewer[$w].nodes[]? |
      [ .login, (.[$r] | tostring), (.followers.totalCount | tostring),
        (.repositories.nodes[0].pushedAt // "") ] | @tsv'

    local count total
    count=$(printf '%s' "$result" | jq --arg w "$which" '.data.viewer[$w].nodes | length' 2>/dev/null || echo 0)
    total=$(printf '%s' "$result" | jq --arg w "$which" '.data.viewer[$w].totalCount' 2>/dev/null || echo 0)
    fetched=$((fetched + count))
    $VERBOSE && [ "$count" -gt 0 ] && echo -e "  ${DIM}Fetched ${fetched}/${total} ${which}...${NC}" >&2

    has_next=$(printf '%s' "$result" | jq -r --arg w "$which" '.data.viewer[$w].pageInfo.hasNextPage' 2>/dev/null || echo false)
    local end_cursor
    end_cursor=$(printf '%s' "$result" | jq -r --arg w "$which" '.data.viewer[$w].pageInfo.endCursor // empty' 2>/dev/null || true)
    [ -z "$end_cursor" ] && break
    cursor_arg=("-f" "cursor=${end_cursor}")
  done
}

cmd_follow_audit_unfollow() {
  local list_file="$1" total ok=0 fail=0 login
  total=$(sed 's/#.*//' "$list_file" | awk 'NF' | wc -l | tr -d ' ')
  if [ "$total" -eq 0 ]; then
    echo -e "${GREEN}Nobody to unfollow.${NC}"
    exit 0
  fi
  echo -e "${YELLOW}${total} account(s) to unfollow${NC}"
  if ! confirm "Unfollow ${total} account(s)?"; then
    echo "Cancelled."
    exit 0
  fi
  while IFS= read -r login; do
    [ -z "$login" ] && continue
    if gh api --method DELETE "user/following/${login}" &>/dev/null; then
      ok=$((ok + 1))
      $VERBOSE && echo -e "  ${GREEN}UNFOLLOWED${NC} ${login}"
    else
      fail=$((fail + 1))
      echo -e "  ${RED}FAILED${NC}     ${login}"
    fi
  done < <(sed 's/#.*//' "$list_file" | awk 'NF {print $1}')
  echo ""
  echo -e "${GREEN}Done!${NC} Unfollowed: ${BOLD}${ok}${NC}, Failed: ${BOLD}${fail}${NC}"
}

cmd_follow_audit_main() {
  cmd_follow_audit_parse_args "$@"
  preflight_check
  skip_init

  local out=1
  [ "$FA_FORMAT" != "text" ] && out=2
  { header "Follow Audit"; } >&$out

  if [ -n "$FA_FROM" ]; then
    echo -e "  From: ${BOLD}${FA_FROM}${NC}"
    echo ""
    cmd_follow_audit_unfollow "$FA_FROM"
    exit 0
  fi

  local excl_file
  excl_file=$(tmp_new)
  if [ -n "$FA_EXCLUDE" ]; then
    sed 's/#.*//' "$FA_EXCLUDE" | awk 'NF {print tolower($1)}' | sort -u > "$excl_file"
    echo -e "  Excluded: ${BOLD}$(count_lines "$excl_file")${NC} ${DIM}(from ${FA_EXCLUDE})${NC}" >&$out
  fi

  local cutoff=""
  [ -n "$FA_INACTIVE" ] && cutoff=$(cutoff_date "$FA_INACTIVE" days)

  echo -e "${DIM}Fetching follow graph...${NC}" >&$out
  local following_file followers_file
  following_file=$(tmp_new)
  cmd_follow_audit_fetch following > "$following_file"

  local n_following n_mutual n_notback
  n_following=$(count_lines "$following_file")
  n_mutual=$(awk -F'\t' '$2=="true"' "$following_file" | wc -l | tr -d ' ')
  n_notback=$((n_following - n_mutual))

  local rows_file
  rows_file=$(tmp_new)
  if $FA_NOT_FOLLOWING_BACK; then
    awk -F'\t' -v OFS='\t' '$2=="false" {print $1, "not-following-back", $3, $4}' "$following_file" >> "$rows_file"
  fi
  if $FA_MUTUALS; then
    awk -F'\t' -v OFS='\t' '$2=="true" {print $1, "mutual", $3, $4}' "$following_file" >> "$rows_file"
  fi
  if $FA_NOT_FOLLOWED_BY_ME; then
    followers_file=$(tmp_new)
    cmd_follow_audit_fetch followers > "$followers_file"
    awk -F'\t' -v OFS='\t' '$2=="false" {print $1, "not-followed-by-me", $3, $4}' "$followers_file" >> "$rows_file"
  fi

  # Excluded logins are dropped from the actionable set entirely.
  if [ -s "$excl_file" ]; then
    local kept
    kept=$(tmp_new)
    awk -F'\t' 'NR==FNR {x[$1]; next} !(tolower($1) in x)' "$excl_file" "$rows_file" > "$kept"
    mv "$kept" "$rows_file"
  fi
  if [ -n "$cutoff" ]; then
    local kept
    kept=$(tmp_new)
    awk -F'\t' -v c="$cutoff" '$4 == "" || $4 < c' "$rows_file" > "$kept"
    mv "$kept" "$rows_file"
  fi
  if [ "$FA_LIMIT" -gt 0 ]; then
    local kept
    kept=$(tmp_new)
    head -n "$FA_LIMIT" "$rows_file" > "$kept"
    mv "$kept" "$rows_file"
  fi

  {
    echo ""
    echo -e "  Following: ${BOLD}${n_following}${NC}   Mutuals: ${BOLD}${n_mutual}${NC}   Not following back: ${BOLD}${n_notback}${NC}"
    echo ""
  } >&$out

  local total
  total=$(count_lines "$rows_file")
  if [ "$total" -eq 0 ]; then
    echo -e "${GREEN}Nothing matches.${NC}" >&$out
    print_skips
    exit 0
  fi

  if [ "$FA_FORMAT" != "text" ]; then
    local payload outfile=""
    $FA_SAVE_LIST && outfile="$FA_OUT"
    payload=$(jq -R -s 'split("\n") | map(select(length > 0) | split("\t")
      | {login: .[0], relationship: .[1], followers: (.[2] | tonumber),
         last_public_push: (.[3] // ""),
         url: ("https://github.com/" + .[0])})' < "$rows_file")
    write_output "$outfile" "$(render_rows "$FA_FORMAT" "$payload")"
    print_skips
    exit 0
  fi

  printf "  ${BOLD}%-24s %-20s %10s  %s${NC}\n" "LOGIN" "RELATIONSHIP" "FOLLOWERS" "LAST PUBLIC PUSH"
  local login rel fol push
  while IFS=$'\t' read -r login rel fol push; do
    printf "  %-24s %-20s %10s  %s\n" "$login" "$rel" "$fol" "${push%%T*}"
  done < "$rows_file"
  echo ""
  echo -e "  ${BOLD}${total}${NC} account(s)"

  if ! $FA_UNFOLLOW; then
    print_skips
    exit 0
  fi

  local list_file
  if $DRY_RUN || $FA_SAVE_LIST; then
    list_file="$FA_OUT"
  else
    list_file=$(tmp_new)
  fi
  awk -F'\t' '{printf "%s  # %s followers · last public push %s\n", $1, $3, ($4 == "" ? "never" : substr($4, 1, 10))}' \
    "$rows_file" > "$list_file"

  echo ""
  if $DRY_RUN; then
    echo -e "${YELLOW}DRY RUN — nobody was unfollowed.${NC}"
    echo -e "List saved to: ${BOLD}${list_file}${NC}"
    echo -e "Review it, then run:"
    echo -e "  ${BOLD}github-helpers follow-audit --from ${list_file}${NC}"
    print_skips
    exit 0
  fi

  cmd_follow_audit_unfollow "$list_file"
  print_skips
}
# =============================================================================
# COMMAND: bulk-merge
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
BULK_MERGE_TARGET=""
BULK_MERGE_TARGET_TYPE=""
BULK_MERGE_REPO=""
BULK_MERGE_AUTHOR="app/dependabot"
BULK_MERGE_LABEL=""
BULK_MERGE_TITLE_MATCH=""
BULK_MERGE_STRATEGY="squash"
BULK_MERGE_MAX=10
BULK_MERGE_LIMIT=200
BULK_MERGE_DELETE_BRANCH=false
BULK_MERGE_NO_CHECKS=false
BULK_MERGE_ALLOW_UNSTABLE=false
BULK_MERGE_PATCH_ONLY=false
BULK_MERGE_MINOR_ONLY=false

cmd_bulk_merge_usage() {
  cat <<EOF
${BOLD}github-helpers bulk-merge${NC} ${DIM}v${VERSION}${NC} — Merge green dependency-update PRs in batch

${BOLD}USAGE${NC}
  github-helpers bulk-merge --dry-run
  github-helpers bulk-merge --patch-only -y

${BOLD}TARGET${NC}
  --user NAME             Target user (default: authenticated user)
  --org NAME              Target organization
  --repo OWNER/NAME       Single repository
  --limit N               Max repos to scan (default: ${BULK_MERGE_LIMIT})

${BOLD}SELECTION${NC}
  --author LOGIN          PR author (default: ${BULK_MERGE_AUTHOR}; try app/renovate)
  --label NAME            Only PRs carrying this label
  --title-match REGEX     Only PRs whose title matches
  --patch-only            Only patch bumps (1.2.3 -> 1.2.4)
  --minor-only            Only patch and minor bumps, never major
  --max N                 Max PRs merged per repo (default: ${BULK_MERGE_MAX})

${BOLD}SAFETY${NC}
  --no-checks             Merge even when checks have not passed ${DIM}(dangerous)${NC}
  --allow-unstable        Allow UNSTABLE ${DIM}(non-required checks failing)${NC}
  --strategy S            squash, merge or rebase (default: ${BULK_MERGE_STRATEGY})
  --delete-branch         Delete the head branch after merging

${BOLD}FLAGS${NC}
  --dry-run               Preview only, merge nothing
  -y, --yes               Skip confirmation prompt
  -v, --verbose           Show PRs that were skipped and why
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  github-helpers bulk-merge --dry-run
  github-helpers bulk-merge --patch-only --delete-branch -y
  github-helpers bulk-merge --author app/renovate --minor-only --dry-run
  github-helpers bulk-merge --repo me/proj --max 50

${BOLD}NOTE${NC}
  This writes to default branches. Checks must pass unless you pass
  --no-checks, drafts are always skipped, and only mergeStateStatus CLEAN is
  merged — DIRTY, BLOCKED, BEHIND and UNKNOWN never are. Every PR that will be
  merged is listed before the single confirmation.
EOF
  exit 0
}

cmd_bulk_merge_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --user)           need_arg "--user" "${2:-}"; BULK_MERGE_TARGET="$2"; BULK_MERGE_TARGET_TYPE="user"; shift 2 ;;
      --org)            need_arg "--org" "${2:-}"; BULK_MERGE_TARGET="$2"; BULK_MERGE_TARGET_TYPE="org"; shift 2 ;;
      --repo)           need_arg "--repo" "${2:-}"; BULK_MERGE_REPO="$2"; shift 2 ;;
      --author)         need_arg "--author" "${2:-}"; BULK_MERGE_AUTHOR="$2"; shift 2 ;;
      --label)          need_arg "--label" "${2:-}"; BULK_MERGE_LABEL="$2"; shift 2 ;;
      --title-match)    need_arg "--title-match" "${2:-}"; BULK_MERGE_TITLE_MATCH="$2"; shift 2 ;;
      --strategy)       need_arg "--strategy" "${2:-}"; BULK_MERGE_STRATEGY="$2"; shift 2 ;;
      --max)            need_arg "--max" "${2:-}"; BULK_MERGE_MAX="$2"; shift 2 ;;
      --limit)          need_arg "--limit" "${2:-}"; BULK_MERGE_LIMIT="$2"; shift 2 ;;
      --delete-branch)  BULK_MERGE_DELETE_BRANCH=true; shift ;;
      --no-checks)      BULK_MERGE_NO_CHECKS=true; shift ;;
      --allow-unstable) BULK_MERGE_ALLOW_UNSTABLE=true; shift ;;
      --patch-only)     BULK_MERGE_PATCH_ONLY=true; shift ;;
      --minor-only)     BULK_MERGE_MINOR_ONLY=true; shift ;;
      --dry-run)        DRY_RUN=true; shift ;;
      -y|--yes)         AUTO_YES=true; shift ;;
      -v|--verbose)     VERBOSE=true; shift ;;
      -h|--help)        cmd_bulk_merge_usage ;;
      *) die "bulk-merge: unknown option: $1" ;;
    esac
  done

  case "$BULK_MERGE_STRATEGY" in squash|merge|rebase) ;; *) die "bulk-merge: --strategy must be squash, merge or rebase" ;; esac
  [[ "$BULK_MERGE_MAX" =~ ^[0-9]+$ ]] || die "bulk-merge: --max must be a whole number"
  [[ "$BULK_MERGE_LIMIT" =~ ^[0-9]+$ ]] || die "bulk-merge: --limit must be a whole number"
  [ -n "$BULK_MERGE_REPO" ] && [[ "$BULK_MERGE_REPO" != */* ]] && die "bulk-merge: --repo must be OWNER/NAME"
  $BULK_MERGE_PATCH_ONLY && $BULK_MERGE_MINOR_ONLY && die "bulk-merge: --patch-only and --minor-only are mutually exclusive"
  if [ -n "$BULK_MERGE_TITLE_MATCH" ]; then
    jq -n --arg p "$BULK_MERGE_TITLE_MATCH" '"" | test($p)' >/dev/null 2>&1 \
      || die "bulk-merge: --title-match is not a valid regex: ${BULK_MERGE_TITLE_MATCH}"
  fi
  return 0
}

# cmd_bulk_merge_bump_kind "<pr title>" -> major | minor | patch | unknown
# Pure: parses the semver bump out of a Dependabot or Renovate title. Accepts
# one to three version components, because GitHub Action tags are often bare
# majors ("from 4 to 7") and those are still major bumps.
#   "Bump foo from 1.2.3 to 1.2.4"              -> patch
#   "Bump actions/checkout from 4 to 7"         -> major
#   "Bump jest and @types/jest"                 -> unknown
# unknown is the safe answer: --patch-only and --minor-only both exclude it.
cmd_bulk_merge_bump_kind() {
  local title="$1"
  if [[ "$title" =~ [Ff]rom[[:space:]]+v?([0-9]+)(\.([0-9]+))?(\.([0-9]+))?[^[:space:]]*[[:space:]]+to[[:space:]]+v?([0-9]+)(\.([0-9]+))?(\.([0-9]+))? ]]; then
    if   [ "${BASH_REMATCH[1]}"    != "${BASH_REMATCH[6]}" ];    then printf 'major'
    elif [ "${BASH_REMATCH[3]:-0}" != "${BASH_REMATCH[8]:-0}" ]; then printf 'minor'
    else printf 'patch'
    fi
    return 0
  fi
  printf 'unknown'
}

cmd_bulk_merge_main() {
  cmd_bulk_merge_parse_args "$@"
  preflight_check
  skip_init

  if [ -z "$BULK_MERGE_TARGET" ]; then
    BULK_MERGE_TARGET=$(get_username)
    BULK_MERGE_TARGET_TYPE="user"
  fi

  header "Bulk Merge"
  if [ -n "$BULK_MERGE_REPO" ]; then
    echo -e "  Repo:     ${BOLD}${BULK_MERGE_REPO}${NC}"
  else
    echo -e "  Target:   ${BOLD}${BULK_MERGE_TARGET}${NC}"
  fi
  echo -e "  Author:   ${BOLD}${BULK_MERGE_AUTHOR}${NC}"
  echo -e "  Strategy: ${BOLD}${BULK_MERGE_STRATEGY}${NC}"
  $BULK_MERGE_PATCH_ONLY && echo -e "  Bumps:    ${BOLD}patch only${NC}"
  $BULK_MERGE_MINOR_ONLY && echo -e "  Bumps:    ${BOLD}patch and minor only${NC}"
  $BULK_MERGE_NO_CHECKS && echo -e "  Checks:   ${RED}NOT required${NC}"
  $DRY_RUN && echo -e "  Mode:     ${YELLOW}DRY RUN${NC}"
  echo ""

  local repo_file cand_file
  repo_file=$(resolve_repo_list "$BULK_MERGE_TARGET" "$BULK_MERGE_REPO" "$BULK_MERGE_LIMIT" "bulk-merge")
  cand_file=$(tmp_new)

  echo -e "${DIM}Scanning $(count_lines "$repo_file") repo(s)...${NC}"
  local nwo prs
  while IFS= read -r nwo; do
    [ -z "$nwo" ] && continue
    prs=$(gh pr list --repo "$nwo" --author "$BULK_MERGE_AUTHOR" --state open --limit 100 \
            --json number,title,mergeable,mergeStateStatus,isDraft,labels,createdAt,headRefName 2>/dev/null) \
      || { skip_note "$nwo" "cannot list pull requests"; continue; }
    [ -z "$prs" ] && continue

    printf '%s' "$prs" | jq -r \
      --arg repo "$nwo" --arg label "$BULK_MERGE_LABEL" --arg tm "$BULK_MERGE_TITLE_MATCH" \
      --argjson allowUnstable "$BULK_MERGE_ALLOW_UNSTABLE" --argjson noChecks "$BULK_MERGE_NO_CHECKS" '
      map(select(.isDraft | not))
      | map(select($label == "" or ([.labels[].name] | index($label))))
      | map(select($tm == "" or (.title | test($tm))))
      | map(. + {verdict:
          (if .mergeable != "MERGEABLE" then "blocked: mergeable=" + (.mergeable // "?")
           elif .mergeStateStatus == "CLEAN" then "ok"
           elif .mergeStateStatus == "UNSTABLE" then
             (if $allowUnstable or $noChecks then "ok" else "blocked: UNSTABLE (non-required checks failing)" end)
           elif $noChecks and (["DIRTY","UNKNOWN"] | index(.mergeStateStatus) | not) then "ok"
           else "blocked: " + (.mergeStateStatus // "?") end)})
      | .[] | [$repo, (.number|tostring), .title, .verdict, .headRefName] | @tsv' >> "$cand_file"
  done < "$repo_file"

  # Semver gate and per-repo cap, applied in bash so the parser stays testable.
  local filtered
  filtered=$(tmp_new)
  local repo num title verdict branch kind
  declare -A per_repo=()
  while IFS=$'\t' read -r repo num title verdict branch; do
    kind=$(cmd_bulk_merge_bump_kind "$title")
    if $BULK_MERGE_PATCH_ONLY && [ "$kind" != "patch" ]; then
      $VERBOSE && echo -e "  ${DIM}skip ${repo}#${num}: ${kind} bump${NC}"
      continue
    fi
    if $BULK_MERGE_MINOR_ONLY && [ "$kind" != "patch" ] && [ "$kind" != "minor" ]; then
      $VERBOSE && echo -e "  ${DIM}skip ${repo}#${num}: ${kind} bump${NC}"
      continue
    fi
    if [ "$verdict" != "ok" ]; then
      $VERBOSE && echo -e "  ${DIM}skip ${repo}#${num}: ${verdict}${NC}"
      continue
    fi
    per_repo["$repo"]=$(( ${per_repo["$repo"]:-0} + 1 ))
    if [ "${per_repo["$repo"]}" -gt "$BULK_MERGE_MAX" ]; then
      $VERBOSE && echo -e "  ${DIM}skip ${repo}#${num}: over --max ${BULK_MERGE_MAX}${NC}"
      continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "$num" "$title" "$kind" "$branch" >> "$filtered"
  done < "$cand_file"

  local total
  total=$(count_lines "$filtered")
  if [ "$total" -eq 0 ]; then
    echo -e "${GREEN}No mergeable pull requests match.${NC}"
    print_skips
    exit 0
  fi

  echo ""
  echo -e "${YELLOW}${total} pull request(s) ready to merge${NC}"
  echo ""
  printf "  ${BOLD}%-34s %6s %-7s %s${NC}\n" "REPOSITORY" "PR" "BUMP" "TITLE"
  while IFS=$'\t' read -r repo num title kind branch; do
    printf "  %-34s %6s %-7s %s\n" "$repo" "#${num}" "$kind" "${title:0:60}"
  done < "$filtered"
  echo ""

  if $DRY_RUN; then
    echo -e "${YELLOW}DRY RUN — nothing was merged.${NC}"
    print_skips
    exit 0
  fi

  if ! confirm "Merge ${total} pull request(s) into their default branches?"; then
    echo "Cancelled."
    exit 0
  fi

  local merged=0 fail=0
  local -a merge_flags=("--${BULK_MERGE_STRATEGY}")
  $BULK_MERGE_DELETE_BRANCH && merge_flags+=("--delete-branch")
  while IFS=$'\t' read -r repo num title kind branch; do
    if gh pr merge "$num" --repo "$repo" "${merge_flags[@]}" &>/dev/null; then
      merged=$((merged + 1))
      echo -e "  ${GREEN}MERGED${NC}  ${repo}#${num} ${DIM}${title:0:50}${NC}"
    else
      fail=$((fail + 1))
      echo -e "  ${RED}FAILED${NC}  ${repo}#${num} ${DIM}${title:0:50}${NC}"
    fi
  done < "$filtered"

  echo ""
  echo -e "${GREEN}Done!${NC} Merged: ${BOLD}${merged}${NC}, Failed: ${BOLD}${fail}${NC}"
  print_skips
}
# =============================================================================
# COMMAND: backup
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
BACKUP_OUT=""
BACKUP_TARGET=""
BACKUP_TARGET_TYPE=""
BACKUP_REPO=""
BACKUP_GIT=true
BACKUP_METADATA=true
BACKUP_MODE="bundle"
BACKUP_GISTS=false
BACKUP_ASSETS=false
BACKUP_INCLUDE_FORKS=false
BACKUP_LIMIT=1000
BACKUP_RESUME=false
BACKUP_VERIFY_DIR=""
BACKUP_JOURNAL=""

cmd_backup_usage() {
  cat <<EOF
${BOLD}github-helpers backup${NC} ${DIM}v${VERSION}${NC} — Export repositories and their metadata locally

${BOLD}USAGE${NC}
  github-helpers backup [options]
  github-helpers backup --verify DIR

${BOLD}OPTIONS${NC}
  --out DIR               Destination (default: github-backup-YYYY-MM-DD)
  --user NAME             Target user (default: authenticated user)
  --org NAME              Target organization
  --repo OWNER/NAME       Single repository
  --no-git                Skip git data
  --no-metadata           Skip issues, PRs, releases, labels, milestones
  --mirror                Keep a bare mirror instead of a bundle
  --gists                 Also back up your gists
  --assets                Also download release binaries ${DIM}(can be large)${NC}
  --include-forks         Include forks (excluded by default)
  --limit N               Max repos (default: ${BACKUP_LIMIT})
  --resume                Skip repos already recorded as done
  --verify DIR            Check an existing backup against its manifest
  -v, --verbose           Show every artifact
  -h, --help              Show this help

${BOLD}LAYOUT${NC}
  DIR/manifest.json                    counts, timestamps, checksums
  DIR/.repos.jsonl                     append-only journal, drives --resume
  DIR/<owner>/<repo>/repo.bundle       git history (or repo.git/ with --mirror)
  DIR/<owner>/<repo>/wiki.bundle       wiki, when one exists
  DIR/<owner>/<repo>/issues.json       issues only, pull requests stripped out
  DIR/<owner>/<repo>/pulls.json
  DIR/<owner>/<repo>/issue_comments.json
  DIR/<owner>/<repo>/review_comments.json
  DIR/<owner>/<repo>/{releases,labels,milestones,metadata}.json
  DIR/gists/<id>/                      with --gists

${BOLD}EXAMPLES${NC}
  github-helpers backup --repo me/proj --out /tmp/bk
  github-helpers backup --gists
  github-helpers backup --org my-company --mirror --out /backups/org
  github-helpers backup --resume --out github-backup-2026-07-27
  github-helpers backup --verify /tmp/bk

${BOLD}NOTE${NC}
  Every file is written as .part and renamed on success, so the presence of a
  final file proves the write completed — that is what makes --resume safe.

  --resume trusts the journal and will not notice a file you deleted or
  corrupted afterwards. Use --verify for integrity, --resume for interruptions.

  issues.json holds the opening message but NOT the thread; the conversation
  lives in issue_comments.json and review_comments.json, which are the biggest
  omission in a naive backup.

  ${BOLD}Not included:${NC} Git LFS objects, release binaries (unless --assets),
  Actions logs, Projects, Discussions and Packages.

  Exits 2 if any repository produced no artifacts at all.
EOF
  exit 0
}

cmd_backup_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --out)            need_arg "--out" "${2:-}"; BACKUP_OUT="$2"; shift 2 ;;
      --user)           need_arg "--user" "${2:-}"; BACKUP_TARGET="$2"; BACKUP_TARGET_TYPE="user"; shift 2 ;;
      --org)            need_arg "--org" "${2:-}"; BACKUP_TARGET="$2"; BACKUP_TARGET_TYPE="org"; shift 2 ;;
      --repo)           need_arg "--repo" "${2:-}"; BACKUP_REPO="$2"; shift 2 ;;
      --limit)          need_arg "--limit" "${2:-}"; BACKUP_LIMIT="$2"; shift 2 ;;
      --verify)         need_arg "--verify" "${2:-}"; BACKUP_VERIFY_DIR="$2"; shift 2 ;;
      --no-git)         BACKUP_GIT=false; shift ;;
      --no-metadata)    BACKUP_METADATA=false; shift ;;
      --mirror)         BACKUP_MODE="mirror"; shift ;;
      --bundle)         BACKUP_MODE="bundle"; shift ;;
      --gists)          BACKUP_GISTS=true; shift ;;
      --assets)         BACKUP_ASSETS=true; shift ;;
      --include-forks)  BACKUP_INCLUDE_FORKS=true; shift ;;
      --resume)         BACKUP_RESUME=true; shift ;;
      -v|--verbose)     VERBOSE=true; shift ;;
      -h|--help)        cmd_backup_usage ;;
      *) die "backup: unknown option: $1" ;;
    esac
  done

  [ -n "$BACKUP_VERIFY_DIR" ] && return 0
  [[ "$BACKUP_LIMIT" =~ ^[0-9]+$ ]] || die "backup: --limit must be a whole number"
  [ -n "$BACKUP_REPO" ] && [[ "$BACKUP_REPO" != */* ]] && die "backup: --repo must be OWNER/NAME"
  $BACKUP_GIT || $BACKUP_METADATA || die "backup: nothing to back up (--no-git and --no-metadata)"
  $BACKUP_ASSETS && ! $BACKUP_METADATA && die "backup: --assets needs the release metadata (drop --no-metadata)"
  [ -z "$BACKUP_OUT" ] && BACKUP_OUT="github-backup-$(date -u +%Y-%m-%d)"
  return 0
}

# backup_save <dest> <content> — atomic write; echoes a JSON file record.
backup_save() {
  local dest="$1" content="$2"
  printf '%s' "$content" > "${dest}.part" || return 1
  mv "${dest}.part" "$dest" || return 1
  jq -nc --arg path "$dest" --argjson bytes "$(wc -c < "$dest" | tr -d ' ')" \
         --arg sha "$(sha256_of "$dest")" '{path:$path, bytes:$bytes, sha256:$sha}'
}

# cmd_backup_one <nwo> <root> — writes one repo, echoes its journal line.
cmd_backup_one() {
  local nwo="$1" root="$2" dir="${2}/${1}" ok=0 failed=0
  local files="" artifacts="" json rec
  mkdir -p "$dir"

  fetch_artifact() { # <name> <api path> [jq filter]
    local name="$1" path="$2" filter="${3:-.}" body dest="${dir}/$1.json"
    if $BACKUP_RESUME && [ -f "$dest" ]; then
      artifacts="${artifacts}$(jq -nc --arg n "$name" '{key:$n, value:{status:"skipped-resume"}}')"$'\n'
      return 0
    fi
    if ! body=$(gh_paginate "${nwo}:${name}" "$path"); then
      artifacts="${artifacts}$(jq -nc --arg n "$name" '{key:$n, value:{status:"skipped"}}')"$'\n'
      failed=$((failed + 1))
      return 1
    fi
    body=$(printf '%s' "$body" | jq "$filter")
    rec=$(backup_save "$dest" "$body") || { failed=$((failed + 1)); return 1; }
    files="${files}${rec}"$'\n'
    artifacts="${artifacts}$(jq -nc --arg n "$name" --argjson c "$(printf '%s' "$body" | jq 'length')" \
      '{key:$n, value:{status:"ok", count:$c}}')"$'\n'
    ok=$((ok + 1))
    $VERBOSE && echo -e "      ${DIM}${name}: $(printf '%s' "$body" | jq 'length')${NC}" >&2
    return 0
  }

  # ── Metadata ───────────────────────────────────────────────────────────────
  if $BACKUP_METADATA; then
    local meta
    if meta=$(gh_api_try "${nwo}:metadata" "repos/${nwo}"); then
      rec=$(backup_save "${dir}/metadata.json" "$(printf '%s' "$meta" | jq '.')") && {
        files="${files}${rec}"$'\n'; ok=$((ok + 1)); }
    else
      failed=$((failed + 1))
    fi
    # direction=asc keeps pagination stable: with the default desc order an
    # item created mid-run shifts every later page.
    # GET /issues returns pull requests too; they carry a pull_request key.
    fetch_artifact issues          "repos/${nwo}/issues?state=all&direction=asc&per_page=100" \
                                   'map(select(has("pull_request") | not))' || true
    fetch_artifact pulls           "repos/${nwo}/pulls?state=all&direction=asc&per_page=100" || true
    fetch_artifact issue_comments  "repos/${nwo}/issues/comments?per_page=100" || true
    fetch_artifact review_comments "repos/${nwo}/pulls/comments?per_page=100" || true
    fetch_artifact releases        "repos/${nwo}/releases?per_page=100" || true
    fetch_artifact labels          "repos/${nwo}/labels?per_page=100" || true
    fetch_artifact milestones      "repos/${nwo}/milestones?state=all&per_page=100" || true

    if $BACKUP_ASSETS && [ -f "${dir}/releases.json" ]; then
      local tag aname aurl adir
      while IFS=$'\t' read -r tag aname aurl; do
        [ -z "$aurl" ] && continue
        adir="${dir}/releases/${tag}"
        mkdir -p "$adir"
        [ -f "${adir}/${aname}" ] && continue
        if gh api -H "Accept: application/octet-stream" "$aurl" > "${adir}/${aname}.part" 2>/dev/null; then
          mv "${adir}/${aname}.part" "${adir}/${aname}"
          $VERBOSE && echo -e "      ${DIM}asset ${tag}/${aname}${NC}" >&2
        else
          rm -f "${adir}/${aname}.part"
          skip_note "${nwo} asset ${tag}/${aname}" "download failed"
        fi
      done < <(jq -r '.[] | .tag_name as $t | .assets[]? | [$t, .name, ("repos/'"${nwo}"'/releases/assets/" + (.id|tostring))] | @tsv' "${dir}/releases.json")
    fi
  fi

  # ── Git ────────────────────────────────────────────────────────────────────
  if $BACKUP_GIT; then
    local target="${dir}/repo.bundle"
    [ "$BACKUP_MODE" = "mirror" ] && target="${dir}/repo.git"
    if $BACKUP_RESUME && [ -e "$target" ]; then
      : # already there
    elif [ "$BACKUP_MODE" = "mirror" ]; then
      rm -rf "${target}.part"
      if git_mirror_clone "$nwo" "${target}.part" 2>/dev/null; then
        rm -rf "$target"; mv "${target}.part" "$target"; ok=$((ok + 1))
      else
        rm -rf "${target}.part"; failed=$((failed + 1)); skip_note "$nwo" "git mirror failed"
      fi
    else
      local tmpdir="${dir}/.mirror.tmp"
      rm -rf "$tmpdir"
      if git_mirror_clone "$nwo" "$tmpdir" 2>/dev/null; then
        local brc=0
        git_bundle_from_mirror "$tmpdir" "${target}.part" || brc=$?
        if [ "$brc" -eq 0 ]; then
          mv "${target}.part" "$target"
          rec=$(jq -nc --arg path "$target" --argjson bytes "$(wc -c < "$target" | tr -d ' ')" \
                       --arg sha "$(sha256_of "$target")" '{path:$path, bytes:$bytes, sha256:$sha}')
          files="${files}${rec}"$'\n'
          ok=$((ok + 1))
        elif [ "$brc" -eq 2 ]; then
          $VERBOSE && echo -e "      ${DIM}git: empty repository, no bundle${NC}" >&2
        else
          rm -f "${target}.part"; failed=$((failed + 1)); skip_note "$nwo" "git bundle failed"
        fi
        rm -rf "$tmpdir"
      else
        rm -rf "$tmpdir"; failed=$((failed + 1)); skip_note "$nwo" "git clone failed"
      fi
    fi

    # Wiki: has_wiki only means the feature is on, not that content exists.
    # gh repo clone cannot take the .wiki suffix, so this one uses git directly.
    if [ ! -f "${dir}/wiki.bundle" ] && git clone --mirror --quiet "https://github.com/${nwo}.wiki.git" "${dir}/.wiki.tmp" 2>/dev/null; then
      if git_bundle_from_mirror "${dir}/.wiki.tmp" "${dir}/wiki.bundle.part"; then
        mv "${dir}/wiki.bundle.part" "${dir}/wiki.bundle"
        ok=$((ok + 1))
      else
        rm -f "${dir}/wiki.bundle.part"
      fi
      rm -rf "${dir}/.wiki.tmp"
    fi
  fi

  local status="ok"
  [ "$failed" -gt 0 ] && status="partial"
  [ "$ok" -eq 0 ] && status="failed"

  jq -nc --arg nwo "$nwo" --arg status "$status" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson files "$(printf '%s' "$files" | jq -sc '.')" \
    --argjson artifacts "$(printf '%s' "$artifacts" | jq -sc 'from_entries')" \
    '{nwo:$nwo, status:$status, backed_up_at:$at, files:$files, artifacts:$artifacts}'
}

cmd_backup_verify() {
  # Two statements on purpose: bash declares every name in a `local` list
  # before evaluating any assignment, so `local a="$1" b="${a}"` reads an
  # unset `a` and trips `set -u`.
  local dir="$1"
  local manifest="${dir}/manifest.json"
  [ -f "$manifest" ] || die "backup: no manifest.json in ${dir}"

  header "Backup Verify"
  echo -e "  Dir: ${BOLD}${dir}${NC}"
  echo ""

  local okc=0 missing=0 mismatch=0 path bytes sha actual
  while IFS=$'\t' read -r path bytes sha; do
    [ -z "$path" ] && continue
    if [ ! -f "$path" ]; then
      missing=$((missing + 1)); echo -e "  ${RED}MISSING${NC}   ${path}"; continue
    fi
    actual=$(sha256_of "$path")
    if [ "$actual" != "$sha" ]; then
      mismatch=$((mismatch + 1)); echo -e "  ${RED}MISMATCH${NC}  ${path}"; continue
    fi
    okc=$((okc + 1))
    $VERBOSE && echo -e "  ${GREEN}OK${NC}        ${path}"
  done < <(jq -r '.repos[]?.files[]? | [.path, (.bytes|tostring), .sha256] | @tsv' "$manifest")

  local failed_repos
  failed_repos=$(jq -r '[.repos[]? | select(.status == "failed")] | length' "$manifest")

  echo ""
  echo -e "${GREEN}Verified:${NC} ${BOLD}${okc}${NC} file(s), Missing: ${BOLD}${missing}${NC}, Mismatched: ${BOLD}${mismatch}${NC}, Failed repos: ${BOLD}${failed_repos}${NC}"
  if [ "$missing" -gt 0 ] || [ "$mismatch" -gt 0 ] || [ "$failed_repos" -gt 0 ]; then
    exit 2
  fi
  exit 0
}

cmd_backup_main() {
  cmd_backup_parse_args "$@"
  preflight_check
  skip_init

  [ -n "$BACKUP_VERIFY_DIR" ] && cmd_backup_verify "$BACKUP_VERIFY_DIR"

  command -v git &>/dev/null || $BACKUP_GIT && { command -v git &>/dev/null || die "backup: git is required (or pass --no-git)"; }

  if [ -z "$BACKUP_TARGET" ]; then
    BACKUP_TARGET=$(get_username)
    BACKUP_TARGET_TYPE="user"
  fi

  header "Backup"
  if [ -n "$BACKUP_REPO" ]; then
    echo -e "  Repo:   ${BOLD}${BACKUP_REPO}${NC}"
  else
    echo -e "  Target: ${BOLD}${BACKUP_TARGET}${NC}"
  fi
  echo -e "  Out:    ${BOLD}${BACKUP_OUT}${NC}"
  echo -e "  Git:    ${BOLD}$($BACKUP_GIT && echo "$BACKUP_MODE" || echo "skipped")${NC}"
  echo -e "  Meta:   ${BOLD}$($BACKUP_METADATA && echo included || echo skipped)${NC}"
  $BACKUP_RESUME && echo -e "  Mode:   ${CYAN}RESUME${NC}"
  echo ""

  mkdir -p "$BACKUP_OUT" || die "backup: cannot create ${BACKUP_OUT}"
  BACKUP_JOURNAL="${BACKUP_OUT}/.repos.jsonl"
  touch "$BACKUP_JOURNAL"

  local remaining
  remaining=$(gh api rate_limit --jq '.resources.core.remaining' 2>/dev/null || echo "?")
  echo -e "  ${DIM}Rate limit: ${remaining} requests remaining${NC}"

  local repo_file
  if [ -n "$BACKUP_REPO" ]; then
    repo_file=$(tmp_new); printf '%s\n' "$BACKUP_REPO" > "$repo_file"
  else
    repo_file=$(tmp_new)
    local -a flags=("--limit" "$BACKUP_LIMIT")
    $BACKUP_INCLUDE_FORKS || flags+=("--source")
    gh repo list "$BACKUP_TARGET" --json nameWithOwner "${flags[@]}" --jq '.[].nameWithOwner' > "$repo_file" \
      || die "backup: failed to list repos for ${BACKUP_TARGET}"
  fi

  local total done_n=0 nwo line status
  total=$(count_lines "$repo_file")
  echo -e "Backing up ${BOLD}${total}${NC} repo(s)..."
  echo ""

  local n_ok=0 n_partial=0 n_failed=0
  while IFS= read -r nwo; do
    [ -z "$nwo" ] && continue
    done_n=$((done_n + 1))
    # The journal is consulted before any request, so a run that died at repo
    # 180 of 200 resumes without re-fetching the first 179.
    if $BACKUP_RESUME && grep -qF "\"nwo\":\"${nwo}\",\"status\":\"ok\"" "$BACKUP_JOURNAL" 2>/dev/null; then
      echo -e "  ${DIM}[${done_n}/${total}] SKIP     ${nwo} (already done)${NC}"
      continue
    fi
    line=$(cmd_backup_one "$nwo" "$BACKUP_OUT") || line=""
    if [ -z "$line" ]; then
      line=$(jq -nc --arg nwo "$nwo" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
              '{nwo:$nwo, status:"failed", backed_up_at:$at, files:[], artifacts:{}}')
    fi
    printf '%s\n' "$line" >> "$BACKUP_JOURNAL"
    status=$(printf '%s' "$line" | jq -r '.status')
    case "$status" in
      ok)      n_ok=$((n_ok + 1));      echo -e "  ${GREEN}[${done_n}/${total}] OK${NC}       ${nwo}" ;;
      partial) n_partial=$((n_partial + 1)); echo -e "  ${YELLOW}[${done_n}/${total}] PARTIAL${NC}  ${nwo}" ;;
      *)       n_failed=$((n_failed + 1)); echo -e "  ${RED}[${done_n}/${total}] FAILED${NC}   ${nwo}" ;;
    esac
  done < "$repo_file"

  # ── Gists ──────────────────────────────────────────────────────────────────
  local n_gists=0
  if $BACKUP_GISTS; then
    echo ""
    echo -e "${DIM}Backing up gists...${NC}"
    local gists gid gdir
    if gists=$(gh_paginate "gists" "gists?per_page=100"); then
      mkdir -p "${BACKUP_OUT}/gists"
      printf '%s' "$gists" | jq '.' > "${BACKUP_OUT}/gists/index.json"
      while IFS= read -r gid; do
        [ -z "$gid" ] && continue
        gdir="${BACKUP_OUT}/gists/${gid}"
        mkdir -p "$gdir"
        if [ ! -f "${gdir}/gist.bundle" ]; then
          if git clone --mirror --quiet "https://gist.github.com/${gid}.git" "${gdir}/.tmp" 2>/dev/null; then
            git_bundle_from_mirror "${gdir}/.tmp" "${gdir}/gist.bundle.part" \
              && mv "${gdir}/gist.bundle.part" "${gdir}/gist.bundle" \
              || rm -f "${gdir}/gist.bundle.part"
            rm -rf "${gdir}/.tmp"
          else
            skip_note "gist ${gid}" "clone failed"
          fi
        fi
        n_gists=$((n_gists + 1))
      done < <(printf '%s' "$gists" | jq -r '.[].id')
      echo -e "  ${GREEN}${n_gists}${NC} gist(s)"
    fi
  fi

  # ── Manifest, assembled from the journal ───────────────────────────────────
  jq -s --arg version "$VERSION" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg target "$BACKUP_TARGET" --arg ttype "${BACKUP_TARGET_TYPE:-user}" \
        --argjson gists "$n_gists" \
        --argjson opts "$(jq -nc --argjson git "$BACKUP_GIT" --arg mode "$BACKUP_MODE" \
            --argjson metadata "$BACKUP_METADATA" --argjson gists "$BACKUP_GISTS" \
            --argjson assets "$BACKUP_ASSETS" --argjson forks "$BACKUP_INCLUDE_FORKS" \
            '{git:$git, mode:$mode, metadata:$metadata, gists:$gists, assets:$assets, include_forks:$forks}')" '
    { tool: "github-helpers", version: $version, schema: 1,
      completed_at: $at,
      target: {type: $ttype, name: $target},
      options: $opts,
      totals: {
        repos: length,
        ok:      ([.[] | select(.status == "ok")]      | length),
        partial: ([.[] | select(.status == "partial")] | length),
        failed:  ([.[] | select(.status == "failed")]  | length),
        gists: $gists,
        bytes: ([.[].files[]?.bytes] | add // 0)
      },
      repos: . }' "$BACKUP_JOURNAL" > "${BACKUP_OUT}/manifest.json.part" \
    && mv "${BACKUP_OUT}/manifest.json.part" "${BACKUP_OUT}/manifest.json"

  local bytes
  bytes=$(jq -r '.totals.bytes' "${BACKUP_OUT}/manifest.json")
  echo ""
  echo -e "${GREEN}Done!${NC} OK: ${BOLD}${n_ok}${NC}, Partial: ${BOLD}${n_partial}${NC}, Failed: ${BOLD}${n_failed}${NC}, Size: ${BOLD}$(human_bytes "$bytes")${NC}"
  echo -e "Manifest: ${BOLD}${BACKUP_OUT}/manifest.json${NC}"
  echo -e "Verify with: ${BOLD}github-helpers backup --verify ${BACKUP_OUT}${NC}"
  print_skips

  [ "$n_failed" -gt 0 ] && exit 2
  exit 0
}
# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

main() {
  # Pre-process global flags
  local -a args=()
  for arg in "$@"; do
    case "$arg" in
      --no-color) disable_colors ;;
      *) args+=("$arg") ;;
    esac
  done
  set -- "${args[@]+"${args[@]}"}"

  if [ $# -eq 0 ]; then
    usage
    exit 0
  fi

  local command="$1"
  shift

  case "$command" in
    unstar)                cmd_unstar_main "$@" ;;
    clone-org)             cmd_clone_org_main "$@" ;;
    cleanup-forks|forks)   cmd_cleanup_forks_main "$@" ;;
    sync-forks)            cmd_sync_forks_main "$@" ;;
    cache-cleanup)         cmd_cache_cleanup_main "$@" ;;
    artifact-cleanup)      cmd_artifact_cleanup_main "$@" ;;
    run-cleanup)           cmd_run_cleanup_main "$@" ;;
    gist|gists)            cmd_gist_main "$@" ;;
    traffic)               cmd_traffic_main "$@" ;;
    notifications|notifs)  cmd_notifications_main "$@" ;;
    invite-cleanup)        cmd_invite_cleanup_main "$@" ;;
    org-audit)             cmd_org_audit_main "$@" ;;
    follow-audit|follow)   cmd_follow_audit_main "$@" ;;
    bulk-merge)            cmd_bulk_merge_main "$@" ;;
    backup)                cmd_backup_main "$@" ;;
    cleanup-branches)      cmd_cleanup_branches_main "$@" ;;
    archive-repos)         cmd_archive_repos_main "$@" ;;
    repo-audit|audit)      cmd_repo_audit_main "$@" ;;
    stats)                 cmd_stats_main "$@" ;;
    bulk-topic)            cmd_bulk_topic_main "$@" ;;
    workflow-status|ci)    cmd_workflow_status_main "$@" ;;
    sync-labels)           cmd_sync_labels_main "$@" ;;
    export-stars)          cmd_export_stars_main "$@" ;;
    rename-default-branch) cmd_rename_default_branch_main "$@" ;;
    secret-audit)          cmd_secret_audit_main "$@" ;;
    license-check)         cmd_license_check_main "$@" ;;
    dependabot-enable)     cmd_dependabot_enable_main "$@" ;;
    mirror)                cmd_mirror_main "$@" ;;
    release-cleanup)       cmd_release_cleanup_main "$@" ;;
    vulnerability-check)   cmd_vulnerability_check_main "$@" ;;
    branch-protection)     cmd_branch_protection_main "$@" ;;
    stale-issues)          cmd_stale_issues_main "$@" ;;
    bulk-settings)         cmd_bulk_settings_main "$@" ;;
    webhook-audit)         cmd_webhook_audit_main "$@" ;;
    cleanup-packages)      cmd_cleanup_packages_main "$@" ;;
    collaborator-audit)    cmd_collaborator_audit_main "$@" ;;
    repo-template)         cmd_repo_template_main "$@" ;;
    pr-cleanup)            cmd_pr_cleanup_main "$@" ;;
    activity-report)       cmd_activity_report_main "$@" ;;
    version|-V|--version)  echo "github-helpers v${VERSION}" ;;
    help|-h|--help)        usage ;;
    *)
      echo -e "${RED}Unknown command: ${command}${NC}" >&2
      echo "" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
