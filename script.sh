#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# github-helpers — GitHub maintenance toolkit
# Subcommands: unstar, clone-org
# =============================================================================

VERSION="1.0.0"

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
  unstar        Clean up your GitHub stars (filter & bulk-unstar)
  clone-org     Clone all repos from a GitHub org or user

${BOLD}FLAGS${NC}
  --no-color    Disable colored output
  --version     Show version
  --help        Show this help

${BOLD}EXAMPLES${NC}
  github-helpers unstar --archived --dry-run
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
