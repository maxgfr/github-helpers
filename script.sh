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
  clone-org     Clone all repositories from a GitHub organization

${BOLD}FLAGS${NC}
  --version     Show version
  --help        Show this help

${BOLD}EXAMPLES${NC}
  github-helpers unstar --archived --dry-run
  github-helpers clone-org --org my-company --ssh

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
CLONE_ORG_NAME=""
CLONE_ORG_DIR="."
CLONE_ORG_DRY_RUN=false
CLONE_ORG_SSH=false
CLONE_ORG_ARCHIVED=""
CLONE_ORG_VISIBILITY=""
CLONE_ORG_LIMIT=0

cmd_clone_org_usage() {
  cat <<EOF
${BOLD}github-helpers clone-org${NC} ${DIM}v${VERSION}${NC} — Clone all repos from a GitHub org

${BOLD}USAGE${NC}
  github-helpers clone-org --org NAME [options]

${BOLD}REQUIRED${NC}
  --org NAME              GitHub organization name

${BOLD}OPTIONS${NC}
  --dir PATH              Clone destination directory (default: current dir)
  --ssh                   Clone via SSH instead of HTTPS
  --archived              Only clone archived repos
  --not-archived          Only clone non-archived repos
  --visibility TYPE       Filter by visibility: public, private, internal
  --limit N               Maximum number of repos to clone (default: all)
  --dry-run               List repos without cloning
  -y, --yes               Skip confirmation prompt
  -v, --verbose           Show detailed output
  -h, --help              Show this help

${BOLD}EXAMPLES${NC}
  # List all repos in an org (dry-run)
  github-helpers clone-org --org my-company --dry-run

  # Clone all non-archived repos via SSH
  github-helpers clone-org --org my-company --ssh --not-archived

  # Clone into a specific directory
  github-helpers clone-org --org my-company --dir ~/projects/my-company

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
      --org)           CLONE_ORG_NAME="$2"; shift 2 ;;
      --dir)           CLONE_ORG_DIR="$2"; shift 2 ;;
      --ssh)           CLONE_ORG_SSH=true; shift ;;
      --archived)      CLONE_ORG_ARCHIVED="true"; shift ;;
      --not-archived)  CLONE_ORG_ARCHIVED="false"; shift ;;
      --visibility)    CLONE_ORG_VISIBILITY="$2"; shift 2 ;;
      --limit)         CLONE_ORG_LIMIT="$2"; shift 2 ;;
      --dry-run)       CLONE_ORG_DRY_RUN=true; shift ;;
      -y|--yes)        AUTO_YES=true; shift ;;
      -v|--verbose)    VERBOSE=true; shift ;;
      -h|--help)       cmd_clone_org_usage ;;
      *) die "clone-org: unknown option: $1" ;;
    esac
  done

  if [ -z "$CLONE_ORG_NAME" ]; then
    die "clone-org: --org NAME is required"
  fi
}

cmd_clone_org_list_repos() {
  local limit="${CLONE_ORG_LIMIT}"
  if [ "$limit" -eq 0 ]; then
    limit=9999
  fi

  local -a flags=("--json" "nameWithOwner,sshUrl,url,isArchived,name" "--limit" "$limit")

  if [ "$CLONE_ORG_ARCHIVED" = "true" ]; then
    flags+=("--archived")
  elif [ "$CLONE_ORG_ARCHIVED" = "false" ]; then
    flags+=("--no-archived")
  fi

  if [ -n "$CLONE_ORG_VISIBILITY" ]; then
    flags+=("--visibility" "$CLONE_ORG_VISIBILITY")
  fi

  gh repo list "$CLONE_ORG_NAME" "${flags[@]}" 2>/dev/null || {
    die "Failed to list repos for org '${CLONE_ORG_NAME}'. Check the org name and your permissions."
  }
}

cmd_clone_org_main() {
  cmd_clone_org_parse_args "$@"
  preflight_check

  echo -e "${BOLD}${CYAN}Clone Org Repos${NC} ${DIM}v${VERSION}${NC}"
  echo -e "${DIM}─────────────────────────────────────────────${NC}"
  echo -e "  Org:  ${BOLD}${CLONE_ORG_NAME}${NC}"
  echo -e "  Dir:  ${BOLD}$(cd "$CLONE_ORG_DIR" 2>/dev/null && pwd || echo "$CLONE_ORG_DIR")${NC}"
  if $CLONE_ORG_SSH; then
    echo -e "  Mode: ${BOLD}SSH${NC}"
  else
    echo -e "  Mode: ${BOLD}HTTPS${NC}"
  fi
  if $CLONE_ORG_DRY_RUN; then
    echo -e "  Mode: ${YELLOW}DRY RUN${NC} (no clones)"
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
  echo "$repos_json" | jq -r '.[] | [.nameWithOwner, (.isArchived | tostring)] | @tsv' | \
    while IFS=$'\t' read -r nwo archived; do
      local suffix=""
      if [ "$archived" = "true" ]; then
        suffix=" ${DIM}(archived)${NC}"
      fi
      echo -e "  ${DIM}•${NC} ${nwo}${suffix}"
    done
  echo ""

  # ── Dry-run stop ────────────────────────────────────────────────────────
  if $CLONE_ORG_DRY_RUN; then
    echo -e "${YELLOW}DRY RUN — no repos were cloned.${NC}"
    exit 0
  fi

  # ── Confirm ─────────────────────────────────────────────────────────────
  if ! $AUTO_YES; then
    read -rp "Clone $total repos into ${CLONE_ORG_DIR}? [y/N] " confirm
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

  local cloned=0 skip=0 failed=0
  while IFS=$'\t' read -r nwo ssh_url repo_name; do
    local target_dir="${CLONE_ORG_DIR}/${repo_name}"

    if [ -d "$target_dir" ]; then
      skip=$((skip + 1))
      $VERBOSE && echo -e "  ${DIM}SKIP${NC} ${nwo} (already exists)"
      continue
    fi

    if $CLONE_ORG_SSH; then
      if git clone --quiet "$ssh_url" "$target_dir" 2>/dev/null; then
        cloned=$((cloned + 1))
        echo -e "  ${GREEN}CLONED${NC} ${nwo}"
      else
        failed=$((failed + 1))
        echo -e "  ${RED}FAILED${NC} ${nwo}"
      fi
    else
      if gh repo clone "$nwo" "$target_dir" -- --quiet 2>/dev/null; then
        cloned=$((cloned + 1))
        echo -e "  ${GREEN}CLONED${NC} ${nwo}"
      else
        failed=$((failed + 1))
        echo -e "  ${RED}FAILED${NC} ${nwo}"
      fi
    fi
  done < "$repo_list"

  echo ""
  echo -e "${GREEN}Done!${NC} Cloned: ${BOLD}${cloned}${NC}, Skipped: ${BOLD}${skip}${NC}, Failed: ${BOLD}${failed}${NC}"
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

main() {
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
