#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# github-helpers — GitHub maintenance toolkit
# Subcommands: unstar, clone-org, cleanup-forks, cleanup-branches,
#              archive-repos, repo-audit, stats, bulk-topic,
#              workflow-status, sync-labels
# =============================================================================

VERSION="1.2.0"

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

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

# =============================================================================
# SHARED UTILITIES
# =============================================================================

die() {
  echo -e "${RED}Error: $1${NC}" >&2
  exit 1
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

# ── Top-level usage ──────────────────────────────────────────────────────────
usage() {
  cat <<EOF
${BOLD}github-helpers${NC} ${DIM}v${VERSION}${NC} — GitHub maintenance toolkit

${BOLD}USAGE${NC}
  github-helpers <command> [options]

${BOLD}COMMANDS${NC}
  ${BOLD}Cleanup & maintenance${NC}
  unstar              Clean up your GitHub stars (filter & bulk-unstar)
  cleanup-forks       Remove forks you never modified (0 commits ahead)
  cleanup-branches    Delete merged or stale remote branches
  archive-repos       Archive inactive repos in batch

  ${BOLD}Audit & visibility${NC}
  repo-audit          Scan repos for missing LICENSE, README, description, topics
  stats               Quick GitHub profile stats dashboard
  workflow-status     Overview of latest CI workflow runs

  ${BOLD}Bulk operations${NC}
  clone-org           Clone all repos from a GitHub org or user
  bulk-topic          Add or remove topics across multiple repos
  sync-labels         Sync issue labels from a template repo

${BOLD}FLAGS${NC}
  --no-color    Disable colored output
  --version     Show version
  --help        Show this help

${BOLD}EXAMPLES${NC}
  github-helpers unstar --archived --dry-run
  github-helpers cleanup-forks --dry-run
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
DRY_RUN=false

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
  --out FILE              Output file for dry-run list (default: unstar-repos.txt)
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
      --commit-before)   FILTER_COMMIT_BEFORE="${2}T00:00:00Z"; shift 2 ;;
      --commit-after)    FILTER_COMMIT_AFTER="${2}T00:00:00Z";  shift 2 ;;
      --activity-before) FILTER_ACTIVITY_BEFORE="${2}T00:00:00Z"; shift 2 ;;
      --activity-after)  FILTER_ACTIVITY_AFTER="${2}T00:00:00Z"; shift 2 ;;
      --archived)        FILTER_ARCHIVED="true";  shift ;;
      --not-archived)    FILTER_ARCHIVED="false"; shift ;;
      --any)             FILTER_MODE="any"; shift ;;
      --all)             FILTER_MODE="all"; shift ;;
      --from)            FROM_FILE="$2"; shift 2 ;;
      --out)             OUT_FILE="$2"; shift 2 ;;
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
  total=$(grep -c '.' "$list_file" 2>/dev/null || echo "0")

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

  if ! $AUTO_YES; then
    read -rp "Unstar all $total repos? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Cancelled."
      exit 0
    fi
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
  local DATAFILE
  DATAFILE=$(mktemp)
  trap 'rm -f "$DATAFILE"' EXIT

  echo -e "${DIM}Fetching starred repos...${NC}"
  cmd_unstar_fetch_starred_repos "$USERNAME" > "$DATAFILE"
  echo ""

  # ── Apply filters ────────────────────────────────────────────────────────
  local MATCHFILE
  MATCHFILE=$(mktemp)
  trap 'rm -f "$DATAFILE" "$MATCHFILE"' EXIT

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
  total=$(sort -u "$MATCHFILE" | grep -c '.' 2>/dev/null || echo "0")

  if [ "$total" -eq 0 ]; then
    echo -e "${GREEN}No repos matched your filters. Your stars are clean!${NC}"
    exit 0
  fi

  echo -e "${YELLOW}Found ${total} repos matching your filters${NC} (scanned ${total_fetched}, skipped ${skipped})"
  echo ""

  # Save sorted list to output file
  sort -u "$MATCHFILE" | grep '.' > "$OUT_FILE"

  if ! $VERBOSE; then
    echo -e "${BOLD}Repos to unstar:${NC}"
    while IFS= read -r repo; do
      echo -e "  ${DIM}•${NC} $repo"
    done < "$OUT_FILE"
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
  if ! $AUTO_YES; then
    read -rp "Unstar all $total repos? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Cancelled."
      echo -e "List saved to: ${BOLD}${OUT_FILE}${NC}"
      exit 0
    fi
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
  done < "$OUT_FILE"

  echo ""
  echo -e "${GREEN}Done!${NC} Unstarred: ${BOLD}${count}${NC}, Failed: ${BOLD}${failed}${NC}"
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
      --org)           CLONE_ORG_TARGET="$2"; CLONE_ORG_TARGET_TYPE="org"; shift 2 ;;
      --user)          CLONE_ORG_TARGET="$2"; CLONE_ORG_TARGET_TYPE="user"; shift 2 ;;
      --dir)           CLONE_ORG_DIR="$2"; shift 2 ;;
      --ssh)           CLONE_ORG_SSH=true; shift ;;
      --pull)          CLONE_ORG_PULL=true; shift ;;
      --archived)      CLONE_ORG_ARCHIVED="true"; shift ;;
      --not-archived)  CLONE_ORG_ARCHIVED="false"; shift ;;
      --fork)          CLONE_ORG_FORK="true"; shift ;;
      --source)        CLONE_ORG_FORK="false"; shift ;;
      --visibility)    CLONE_ORG_VISIBILITY="$2"; shift 2 ;;
      --language)      CLONE_ORG_LANGUAGE="$2"; shift 2 ;;
      --topic)         CLONE_ORG_TOPIC="$2"; shift 2 ;;
      --limit)         CLONE_ORG_LIMIT="$2"; shift 2 ;;
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
  if ! $AUTO_YES; then
    local action="Clone"
    $CLONE_ORG_PULL && action="Clone/pull"
    read -rp "${action} ${total} repos into ${CLONE_ORG_DIR}? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Cancelled."
      exit 0
    fi
  fi

  # ── Create target directory ─────────────────────────────────────────────
  mkdir -p "$CLONE_ORG_DIR"

  # ── Clone loop ──────────────────────────────────────────────────────────
  local repo_list
  repo_list=$(mktemp)
  trap 'rm -f "$repo_list"' EXIT

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

cmd_cleanup_forks_usage() {
  cat <<EOF
${BOLD}github-helpers cleanup-forks${NC} ${DIM}v${VERSION}${NC} — Remove forks you never modified

${BOLD}USAGE${NC}
  github-helpers cleanup-forks [options]

${BOLD}OPTIONS${NC}
  --dry-run               List forks without deleting
  -y, --yes               Skip confirmation prompt
  -v, --verbose           Show detailed output (commits ahead/behind)
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  github-helpers cleanup-forks --dry-run
  github-helpers cleanup-forks -y
EOF
  exit 0
}

cmd_cleanup_forks_main() {
  local dry_run=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run)    dry_run=true; shift ;;
      -y|--yes)     AUTO_YES=true; shift ;;
      -v|--verbose) VERBOSE=true; shift ;;
      -h|--help)    cmd_cleanup_forks_usage ;;
      *) die "cleanup-forks: unknown option: $1" ;;
    esac
  done

  preflight_check
  local USERNAME
  USERNAME=$(get_username)

  echo -e "${BOLD}${CYAN}Cleanup Forks${NC} ${DIM}v${VERSION}${NC}"
  echo -e "${DIM}─────────────────────────────────────────────${NC}"
  echo -e "  User: ${BOLD}${USERNAME}${NC}"
  if $dry_run; then
    echo -e "  Mode: ${YELLOW}DRY RUN${NC}"
  fi
  echo ""

  echo -e "${DIM}Fetching forked repos...${NC}"
  local forks_json
  forks_json=$(gh repo list "$USERNAME" --fork --json nameWithOwner,parent --limit 9999 2>/dev/null) || {
    die "Failed to list forks"
  }

  local total
  total=$(echo "$forks_json" | jq 'length')

  if [ "$total" -eq 0 ]; then
    echo -e "${GREEN}No forks found.${NC}"
    exit 0
  fi

  echo -e "Found ${BOLD}${total}${NC} forks. Checking for unmodified ones..."
  echo ""

  local -a deletable=()
  local idx=0

  while IFS=$'\t' read -r nwo parent; do
    idx=$((idx + 1))
    local prefix="${DIM}[${idx}/${total}]${NC}"

    # Check if fork is ahead of parent
    local comparison
    comparison=$(gh api "repos/${nwo}/compare/HEAD...HEAD" --jq '.ahead_by' 2>/dev/null || echo "")

    # Use the parent's default branch for comparison
    local ahead=0
    comparison=$(gh api "repos/${nwo}" --jq '.parent.full_name as $p | .default_branch as $b | "\($p):\($b)"' 2>/dev/null || echo "")
    if [ -n "$comparison" ]; then
      local parent_ref="${comparison}"
      ahead=$(gh api "repos/${nwo}/compare/${parent_ref}...${USERNAME}:HEAD" --jq '.ahead_by' 2>/dev/null || echo "-1")
    fi

    if [ "$ahead" = "0" ]; then
      deletable+=("$nwo")
      echo -e "  ${prefix} ${YELLOW}UNMODIFIED${NC}  ${nwo} ${DIM}(0 commits ahead)${NC}"
    else
      if $VERBOSE; then
        echo -e "  ${prefix} ${GREEN}MODIFIED${NC}    ${nwo} ${DIM}(${ahead} commits ahead)${NC}"
      fi
    fi
  done < <(echo "$forks_json" | jq -r '.[] | [.nameWithOwner, (.parent.nameWithOwner // "")] | @tsv')

  echo ""

  if [ ${#deletable[@]} -eq 0 ]; then
    echo -e "${GREEN}All forks have modifications. Nothing to clean up!${NC}"
    exit 0
  fi

  echo -e "${YELLOW}Found ${#deletable[@]} unmodified forks${NC}"

  if $dry_run; then
    echo ""
    echo -e "${YELLOW}DRY RUN — no forks were deleted.${NC}"
    echo -e "Unmodified forks:"
    for repo in "${deletable[@]}"; do
      echo -e "  ${DIM}•${NC} $repo"
    done
    exit 0
  fi

  echo ""
  if ! $AUTO_YES; then
    read -rp "Delete ${#deletable[@]} unmodified forks? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Cancelled."
      exit 0
    fi
  fi

  local deleted=0 fail=0
  for repo in "${deletable[@]}"; do
    if gh repo delete "$repo" --yes 2>/dev/null; then
      deleted=$((deleted + 1))
      echo -e "  ${GREEN}DELETED${NC}  $repo"
    else
      fail=$((fail + 1))
      echo -e "  ${RED}FAILED${NC}   $repo"
    fi
  done

  echo ""
  echo -e "${GREEN}Done!${NC} Deleted: ${BOLD}${deleted}${NC}, Failed: ${BOLD}${fail}${NC}"
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
      --user)             target="$2"; target_type="user"; shift 2 ;;
      --org)              target="$2"; target_type="org"; shift 2 ;;
      --inactive-months)  inactive_months="$2"; shift 2 ;;
      --language)         language="$2"; shift 2 ;;
      --topic)            topic="$2"; shift 2 ;;
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

  local cutoff_date
  cutoff_date=$(date -v-"${inactive_months}"m +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
    date -d "${inactive_months} months ago" --iso-8601=seconds 2>/dev/null || \
    die "Cannot compute date. Provide --inactive-months as a number.")

  echo -e "${BOLD}${CYAN}Archive Repos${NC} ${DIM}v${VERSION}${NC}"
  echo -e "${DIM}─────────────────────────────────────────────${NC}"
  echo -e "  Target:   ${BOLD}${target}${NC}"
  echo -e "  Inactive: ${BOLD}>${inactive_months} months${NC} (before ${cutoff_date%%T*})"
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
  inactive_json=$(echo "$repos_json" | jq --arg cutoff "$cutoff_date" '[.[] | select(.pushedAt < $cutoff)]')

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

  if ! $AUTO_YES; then
    read -rp "Archive ${total} repos? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Cancelled."
      exit 0
    fi
  fi

  local archived=0 fail=0
  echo "$inactive_json" | jq -r '.[].nameWithOwner' | while IFS= read -r nwo; do
    if gh repo archive "$nwo" --yes 2>/dev/null; then
      archived=$((archived + 1))
      echo -e "  ${GREEN}ARCHIVED${NC}  $nwo"
    else
      fail=$((fail + 1))
      echo -e "  ${RED}FAILED${NC}    $nwo"
    fi
  done

  echo ""
  echo -e "${GREEN}Done!${NC}"
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
      --user)      target="$2"; target_type="user"; shift 2 ;;
      --org)       target="$2"; target_type="org"; shift 2 ;;
      --language)  language="$2"; shift 2 ;;
      --topic)     topic="$2"; shift 2 ;;
      --limit)     limit="$2"; shift 2 ;;
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
      --user) target="$2"; target_type="user"; shift 2 ;;
      --org)  target="$2"; target_type="org"; shift 2 ;;
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
      --add)       action="add"; topic_value="$2"; shift 2 ;;
      --remove)    action="remove"; topic_value="$2"; shift 2 ;;
      --user)      target="$2"; target_type="user"; shift 2 ;;
      --org)       target="$2"; target_type="org"; shift 2 ;;
      --language)  language="$2"; shift 2 ;;
      --topic)     filter_topic="$2"; shift 2 ;;
      --pattern)   pattern="$2"; shift 2 ;;
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

  if ! $AUTO_YES; then
    read -rp "${action^} topic '${topic_value}' on ${count} repos? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Cancelled."
      exit 0
    fi
  fi

  local success=0 fail=0
  echo "$filtered_repos" | jq -r '.[].nameWithOwner' | while IFS= read -r nwo; do
    if gh repo edit "$nwo" --"${action}-topic" "$topic_value" 2>/dev/null; then
      success=$((success + 1))
      echo -e "  ${GREEN}OK${NC}     $nwo"
    else
      fail=$((fail + 1))
      echo -e "  ${RED}FAILED${NC} $nwo"
    fi
  done

  echo ""
  echo -e "${GREEN}Done!${NC}"
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
      --repo)        target="$2"; target_type="repo"; shift 2 ;;
      --org)         target="$2"; target_type="org"; shift 2 ;;
      --user)        target="$2"; target_type="user"; shift 2 ;;
      --merged)      mode="merged"; shift ;;
      --stale-days)  mode="stale"; stale_days="$2"; shift 2 ;;
      --exclude)     exclude="$2"; shift 2 ;;
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
      --user)      target="$2"; target_type="user"; shift 2 ;;
      --org)       target="$2"; target_type="org"; shift 2 ;;
      --limit)     limit="$2"; shift 2 ;;
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
      --from)      from_repo="$2"; shift 2 ;;
      --to)        to_repo="$2"; to_type="repo"; shift 2 ;;
      --org)       to_target="$2"; to_type="org"; shift 2 ;;
      --user)      to_target="$2"; to_type="user"; shift 2 ;;
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

  if ! $AUTO_YES; then
    read -rp "Sync ${label_count} labels to ${#targets[@]} repos? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Cancelled."
      exit 0
    fi
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
      if gh api --method PATCH "repos/${target_nwo}/labels/${name}" \
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
    cleanup-forks)         cmd_cleanup_forks_main "$@" ;;
    cleanup-branches)      cmd_cleanup_branches_main "$@" ;;
    archive-repos)         cmd_archive_repos_main "$@" ;;
    repo-audit|audit)      cmd_repo_audit_main "$@" ;;
    stats)                 cmd_stats_main "$@" ;;
    bulk-topic)            cmd_bulk_topic_main "$@" ;;
    workflow-status|ci)    cmd_workflow_status_main "$@" ;;
    sync-labels)           cmd_sync_labels_main "$@" ;;
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
