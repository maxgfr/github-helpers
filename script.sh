#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# github-helpers — GitHub maintenance toolkit
# Subcommands: unstar, clone-org, cleanup-forks, cleanup-branches,
#              archive-repos, repo-audit, stats, bulk-topic,
#              workflow-status, sync-labels, export-stars,
#              rename-default-branch, secret-audit, license-check,
#              dependabot-enable, mirror, release-cleanup,
#              vulnerability-check, branch-protection, stale-issues,
#              bulk-settings, webhook-audit, cleanup-packages,
#              collaborator-audit, repo-template, pr-cleanup,
#              activity-report
# =============================================================================

VERSION="1.3.1"

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
  release-cleanup     Delete old releases
  pr-cleanup          Find and close abandoned pull requests
  cleanup-packages    Delete old GitHub Package versions
  stale-issues        Find and close stale issues/PRs

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
  activity-report     Generate activity summary for a period

  ${BOLD}Bulk operations${NC}
  clone-org           Clone all repos from a GitHub org or user
  bulk-topic          Add or remove topics across multiple repos
  sync-labels         Sync issue labels from a template repo
  export-stars        Export starred repos to JSON/CSV/Markdown
  rename-default-branch  Rename default branch across repos
  dependabot-enable   Enable Dependabot on repos
  mirror              Mirror repos to another remote
  bulk-settings       Apply repo settings in batch
  repo-template       Sync settings from a template repo

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
      --format)    EXPORT_STARS_FORMAT="$2"; shift 2 ;;
      --out)       EXPORT_STARS_OUT="$2"; shift 2 ;;
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
      --from)      RENAME_BRANCH_FROM="$2"; shift 2 ;;
      --to)        RENAME_BRANCH_TO="$2"; shift 2 ;;
      --user)      RENAME_BRANCH_TARGET="$2"; RENAME_BRANCH_TARGET_TYPE="user"; shift 2 ;;
      --org)       RENAME_BRANCH_TARGET="$2"; RENAME_BRANCH_TARGET_TYPE="org"; shift 2 ;;
      --repo)      RENAME_BRANCH_REPO="$2"; shift 2 ;;
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

  if ! $AUTO_YES; then
    read -rp "Rename default branch on ${total} repos? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Cancelled."
      exit 0
    fi
  fi

  local success=0 fail=0
  echo "$matching_json" | jq -r '.[].nameWithOwner' | while IFS= read -r nwo; do
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
  done

  echo ""
  echo -e "${GREEN}Done!${NC}"
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
      --user)      SECRET_AUDIT_TARGET="$2"; SECRET_AUDIT_TARGET_TYPE="user"; shift 2 ;;
      --org)       SECRET_AUDIT_TARGET="$2"; SECRET_AUDIT_TARGET_TYPE="org"; shift 2 ;;
      --repo)      SECRET_AUDIT_REPO="$2"; shift 2 ;;
      --limit)     SECRET_AUDIT_LIMIT="$2"; shift 2 ;;
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
      --user)       LICENSE_CHECK_TARGET="$2"; LICENSE_CHECK_TARGET_TYPE="user"; shift 2 ;;
      --org)        LICENSE_CHECK_TARGET="$2"; LICENSE_CHECK_TARGET_TYPE="org"; shift 2 ;;
      --template)   LICENSE_CHECK_TEMPLATE="$2"; shift 2 ;;
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

  if ! $AUTO_YES; then
    read -rp "Add '${LICENSE_CHECK_TEMPLATE}' license to ${without_license} repos? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Cancelled."
      exit 0
    fi
  fi

  local encoded_body
  encoded_body=$(echo -n "$license_body" | base64)

  local success=0 fail=0
  echo "$missing_repos" | while IFS= read -r nwo; do
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
  done

  echo ""
  echo -e "${GREEN}Done!${NC}"
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
      --user)        DEPENDABOT_TARGET="$2"; DEPENDABOT_TARGET_TYPE="user"; shift 2 ;;
      --org)         DEPENDABOT_TARGET="$2"; DEPENDABOT_TARGET_TYPE="org"; shift 2 ;;
      --ecosystems)  DEPENDABOT_ECOSYSTEMS="$2"; shift 2 ;;
      --schedule)    DEPENDABOT_SCHEDULE="$2"; shift 2 ;;
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

  echo "$repos_json" | jq -c '.[]' | while IFS= read -r repo; do
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
  done

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

  if ! $AUTO_YES; then
    read -rp "Enable Dependabot on ${enable_count} repos? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Cancelled."
      rm -f "$list_file"
      exit 0
    fi
  fi

  echo ""
  local success=0 fail=0
  while IFS='|' read -r nwo eco_list; do
    [ -z "$nwo" ] && continue

    IFS=',' read -ra ecosystems <<< "$eco_list"
    local config_content
    config_content=$(cmd_dependabot_enable_build_config "$DEPENDABOT_SCHEDULE" "${ecosystems[@]}")

    local encoded_content
    encoded_content=$(echo -e "$config_content" | base64)

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
      --repo)      MIRROR_REPO="$2"; shift 2 ;;
      --user)      MIRROR_TARGET="$2"; MIRROR_TARGET_TYPE="user"; shift 2 ;;
      --org)       MIRROR_TARGET="$2"; MIRROR_TARGET_TYPE="org"; shift 2 ;;
      --target)    MIRROR_URL_TEMPLATE="$2"; shift 2 ;;
      --dir)       MIRROR_DIR="$2"; shift 2 ;;
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

  if ! $AUTO_YES; then
    read -rp "Mirror ${total} repos? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Cancelled."
      exit 0
    fi
  fi

  # Create mirror directory
  mkdir -p "$MIRROR_DIR"

  local success=0 fail=0
  echo "$repo_list_json" | jq -r '.[] | "\(.nameWithOwner)\t\(.name)"' | while IFS=$'\t' read -r nwo repo_name; do
    [ -z "$nwo" ] && continue

    local target_url="${MIRROR_URL_TEMPLATE//\{name\}/$repo_name}"
    local clone_path="${MIRROR_DIR}/${repo_name}.git"

    echo -e "  ${BOLD}${nwo}${NC}"

    # Clone bare
    $VERBOSE && echo -e "    ${DIM}Cloning bare...${NC}"
    rm -rf "$clone_path"
    if ! git clone --bare "https://github.com/${nwo}.git" "$clone_path" 2>/dev/null; then
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
  done

  echo ""
  echo -e "${GREEN}Done!${NC}"
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
      --repo)       RELEASE_CLEANUP_REPO="$2"; shift 2 ;;
      --user)       RELEASE_CLEANUP_TARGET="$2"; RELEASE_CLEANUP_TARGET_TYPE="user"; shift 2 ;;
      --org)        RELEASE_CLEANUP_TARGET="$2"; RELEASE_CLEANUP_TARGET_TYPE="org"; shift 2 ;;
      --keep)       RELEASE_CLEANUP_KEEP="$2"; shift 2 ;;
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
  local tmpfile
  tmpfile=$(mktemp)
  trap 'rm -f "$tmpfile"' EXIT

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

  if ! $DRY_RUN && ! $AUTO_YES; then
    read -rp "Delete ${total_to_delete} releases? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Cancelled."
      exit 0
    fi
    echo ""
  fi

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
      --repo)      VULN_CHECK_REPO="$2"; shift 2 ;;
      --user)      VULN_CHECK_TARGET="$2"; VULN_CHECK_TARGET_TYPE="user"; shift 2 ;;
      --org)       VULN_CHECK_TARGET="$2"; VULN_CHECK_TARGET_TYPE="org"; shift 2 ;;
      --severity)  VULN_CHECK_SEVERITY="$2"; shift 2 ;;
      --limit)     VULN_CHECK_LIMIT="$2"; shift 2 ;;
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
      --repo)                   BRANCH_PROT_REPO="$2"; shift 2 ;;
      --user)                   BRANCH_PROT_TARGET="$2"; BRANCH_PROT_TARGET_TYPE="user"; shift 2 ;;
      --org)                    BRANCH_PROT_TARGET="$2"; BRANCH_PROT_TARGET_TYPE="org"; shift 2 ;;
      --enforce)                BRANCH_PROT_ENFORCE=true; shift ;;
      --require-reviews)        BRANCH_PROT_REVIEWS="$2"; shift 2 ;;
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
  local tmpfile
  tmpfile=$(mktemp)
  trap 'rm -f "$tmpfile"' EXIT

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

    if ! $DRY_RUN && ! $AUTO_YES; then
      read -rp "Apply branch protection to ${enforce_count} repos? [y/N] " confirm
      if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        exit 0
      fi
      echo ""
    fi

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
      --repo)      STALE_ISSUES_REPO="$2"; shift 2 ;;
      --user)      STALE_ISSUES_TARGET="$2"; STALE_ISSUES_TARGET_TYPE="user"; shift 2 ;;
      --org)       STALE_ISSUES_TARGET="$2"; STALE_ISSUES_TARGET_TYPE="org"; shift 2 ;;
      --days)      STALE_ISSUES_DAYS="$2"; shift 2 ;;
      --type)      STALE_ISSUES_TYPE="$2"; shift 2 ;;
      --label)     STALE_ISSUES_LABEL="$2"; shift 2 ;;
      --close)     STALE_ISSUES_CLOSE=true; shift ;;
      --comment)   STALE_ISSUES_COMMENT="$2"; shift 2 ;;
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
  local cutoff_date="$2"

  # Process issues
  if [ "$STALE_ISSUES_TYPE" = "all" ] || [ "$STALE_ISSUES_TYPE" = "issue" ]; then
    local -a issue_flags=(--repo "$nwo" --state open --json number,title,updatedAt --limit 200)
    [ -n "$STALE_ISSUES_LABEL" ] && issue_flags+=(--label "$STALE_ISSUES_LABEL")

    local issues_json
    issues_json=$(gh issue list "${issue_flags[@]}" 2>/dev/null || echo "[]")

    echo "$issues_json" | jq -c --arg cutoff "$cutoff_date" '.[] | select(.updatedAt < $cutoff)' | while IFS= read -r item; do
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

    echo "$prs_json" | jq -c --arg cutoff "$cutoff_date" '.[] | select(.updatedAt < $cutoff)' | while IFS= read -r item; do
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

  # Calculate cutoff date
  local cutoff_date
  if [[ "$OSTYPE" == "darwin"* ]]; then
    cutoff_date=$(date -v-"${STALE_ISSUES_DAYS}"d -u +"%Y-%m-%dT%H:%M:%SZ")
  else
    cutoff_date=$(date -u -d "${STALE_ISSUES_DAYS} days ago" +"%Y-%m-%dT%H:%M:%SZ")
  fi

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

  if $STALE_ISSUES_CLOSE && ! $DRY_RUN && ! $AUTO_YES; then
    read -rp "Close stale issues/PRs? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Cancelled."
      exit 0
    fi
    echo ""
  fi

  while IFS= read -r nwo; do
    [ -z "$nwo" ] && continue
    echo -e "  ${BOLD}${nwo}${NC}"
    cmd_stale_issues_process_repo "$nwo" "$cutoff_date"
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
      --user)                   BULK_SETTINGS_TARGET="$2"; BULK_SETTINGS_TARGET_TYPE="user"; shift 2 ;;
      --org)                    BULK_SETTINGS_TARGET="$2"; BULK_SETTINGS_TARGET_TYPE="org"; shift 2 ;;
      --language)               BULK_SETTINGS_LANGUAGE="$2"; shift 2 ;;
      --topic)                  BULK_SETTINGS_TOPIC="$2"; shift 2 ;;
      --pattern)                BULK_SETTINGS_PATTERN="$2"; shift 2 ;;
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
  total=$(echo "$repo_list" | grep -c '.' || echo "0")

  if [ "$total" -eq 0 ]; then
    echo -e "${GREEN}No repos found.${NC}"
    exit 0
  fi

  echo -e "Found ${BOLD}${total}${NC} repos"
  echo ""

  if ! $DRY_RUN && ! $AUTO_YES; then
    read -rp "Apply settings to ${total} repos? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Cancelled."
      exit 0
    fi
    echo ""
  fi

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
      --repo)      WEBHOOK_AUDIT_REPO="$2"; shift 2 ;;
      --user)      WEBHOOK_AUDIT_TARGET="$2"; WEBHOOK_AUDIT_TARGET_TYPE="user"; shift 2 ;;
      --org)       WEBHOOK_AUDIT_TARGET="$2"; WEBHOOK_AUDIT_TARGET_TYPE="org"; shift 2 ;;
      --limit)     WEBHOOK_AUDIT_LIMIT="$2"; shift 2 ;;
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
      --user)      CLEANUP_PKG_TARGET="$2"; CLEANUP_PKG_TARGET_TYPE="user"; shift 2 ;;
      --org)       CLEANUP_PKG_TARGET="$2"; CLEANUP_PKG_TARGET_TYPE="org"; shift 2 ;;
      --type)      CLEANUP_PKG_TYPE="$2"; shift 2 ;;
      --package)   CLEANUP_PKG_PACKAGE="$2"; shift 2 ;;
      --keep)      CLEANUP_PKG_KEEP="$2"; shift 2 ;;
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

  if ! $DRY_RUN && ! $AUTO_YES; then
    read -rp "Clean up old versions (keeping ${CLEANUP_PKG_KEEP} per package)? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Cancelled."
      exit 0
    fi
    echo ""
  fi

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
      --org)        COLLAB_AUDIT_TARGET="$2"; COLLAB_AUDIT_TARGET_TYPE="org"; shift 2 ;;
      --user)       COLLAB_AUDIT_TARGET="$2"; COLLAB_AUDIT_TARGET_TYPE="user"; shift 2 ;;
      --permission) COLLAB_AUDIT_PERMISSION="$2"; shift 2 ;;
      --limit)      COLLAB_AUDIT_LIMIT="$2"; shift 2 ;;
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
      --from)            REPO_TEMPLATE_FROM="$2"; shift 2 ;;
      --user)            REPO_TEMPLATE_TARGET="$2"; REPO_TEMPLATE_TARGET_TYPE="user"; shift 2 ;;
      --org)             REPO_TEMPLATE_TARGET="$2"; REPO_TEMPLATE_TARGET_TYPE="org"; shift 2 ;;
      --language)        REPO_TEMPLATE_LANGUAGE="$2"; shift 2 ;;
      --topic)           REPO_TEMPLATE_TOPIC="$2"; shift 2 ;;
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
  total=$(echo "$repo_list" | grep -c '.' || echo "0")

  if [ "$total" -eq 0 ]; then
    echo -e "${GREEN}No target repos found.${NC}"
    exit 0
  fi

  echo -e "Found ${BOLD}${total}${NC} target repos"
  echo ""

  if ! $DRY_RUN && ! $AUTO_YES; then
    read -rp "Apply template to ${total} repos? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Cancelled."
      exit 0
    fi
    echo ""
  fi

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
      --repo)           PR_CLEANUP_REPO="$2"; shift 2 ;;
      --user)           PR_CLEANUP_TARGET="$2"; PR_CLEANUP_TARGET_TYPE="user"; shift 2 ;;
      --org)            PR_CLEANUP_TARGET="$2"; PR_CLEANUP_TARGET_TYPE="org"; shift 2 ;;
      --days)           PR_CLEANUP_DAYS="$2"; shift 2 ;;
      --draft-only)     PR_CLEANUP_DRAFT_ONLY=true; shift ;;
      --close)          PR_CLEANUP_CLOSE=true; shift ;;
      --comment)        PR_CLEANUP_COMMENT="$2"; shift 2 ;;
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
  local cutoff_date="$2"

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
  stale_prs=$(echo "$prs_json" | jq -c --arg cutoff "$cutoff_date" "[.[] | ${filter}]")

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

  # Calculate cutoff date
  local cutoff_date
  if [[ "$OSTYPE" == "darwin"* ]]; then
    cutoff_date=$(date -v-"${PR_CLEANUP_DAYS}"d -u +"%Y-%m-%dT%H:%M:%SZ")
  else
    cutoff_date=$(date -u -d "${PR_CLEANUP_DAYS} days ago" +"%Y-%m-%dT%H:%M:%SZ")
  fi

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

  if $PR_CLEANUP_CLOSE && ! $DRY_RUN && ! $AUTO_YES; then
    read -rp "Close stale PRs? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Cancelled."
      exit 0
    fi
    echo ""
  fi

  while IFS= read -r nwo; do
    [ -z "$nwo" ] && continue
    echo -e "  ${BOLD}${nwo}${NC}"
    cmd_pr_cleanup_process_repo "$nwo" "$cutoff_date"
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
      --user)    ACTIVITY_REPORT_TARGET="$2"; ACTIVITY_REPORT_TARGET_TYPE="user"; shift 2 ;;
      --org)     ACTIVITY_REPORT_TARGET="$2"; ACTIVITY_REPORT_TARGET_TYPE="org"; shift 2 ;;
      --since)   ACTIVITY_REPORT_SINCE="$2"; shift 2 ;;
      --until)   ACTIVITY_REPORT_UNTIL="$2"; shift 2 ;;
      --format)  ACTIVITY_REPORT_FORMAT="$2"; shift 2 ;;
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
