#!/usr/bin/env bash
# =============================================================================
# github-helpers-test — unit tests for github-helpers
# Run: github-helpers-test
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
if [ -f "$SCRIPT_DIR/script.sh" ]; then
  SCRIPT_PATH="$SCRIPT_DIR/script.sh"
else
  SCRIPT_PATH="$SCRIPT_DIR/github-helpers"
fi
PASS=0 FAIL=0 TOTAL=0

RED=$'\033[0;31m' GREEN=$'\033[0;32m' YELLOW=$'\033[1;33m'
BOLD=$'\033[1m' DIM=$'\033[2m' NC=$'\033[0m'

# ── Test helpers ─────────────────────────────────────────────────────────────

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}PASS${NC} $label"
  else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}FAIL${NC} $label"
    echo -e "       expected: ${BOLD}${expected}${NC}"
    echo -e "       actual:   ${BOLD}${actual}${NC}"
  fi
}

assert_match() {
  local label="$1" pattern="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" =~ $pattern ]]; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}PASS${NC} $label"
  else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}FAIL${NC} $label"
    echo -e "       pattern:  ${BOLD}${pattern}${NC}"
    echo -e "       actual:   ${BOLD}${actual}${NC}"
  fi
}

assert_exit_code() {
  local label="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$expected" -eq "$actual" ]; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}PASS${NC} $label"
  else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}FAIL${NC} $label"
    echo -e "       expected exit: ${BOLD}${expected}${NC}"
    echo -e "       actual exit:   ${BOLD}${actual}${NC}"
  fi
}

# Source only the functions we need (skip main execution).
# We create a wrapper that sources the script in a subshell with main() stubbed.
setup_env() {
  # Reset filter globals
  FILTER_COMMIT_BEFORE=""
  FILTER_COMMIT_AFTER=""
  FILTER_ACTIVITY_BEFORE=""
  FILTER_ACTIVITY_AFTER=""
  FILTER_ARCHIVED=""
  FILTER_MODE="any"
  FROM_FILE=""
  OUT_FILE="unstar-repos.txt"
  SAVE_LIST=false
  AUTO_YES=false
  VERBOSE=false
  DRY_RUN=false
  NO_COLOR=1
  RED='' GREEN='' YELLOW='' CYAN='' BOLD='' DIM='' NC=''
  declare -g -a REASONS=()
}

# Source the script up to the main call (we override main/preflight_check)
source_helpers() {
  # Override functions that would exit or require gh
  eval "$(sed '
    s/^main "\$@"$/# main "$@"/
    s/^  if ! command -v gh/  if false \&\& command -v gh/
    s/^  if ! command -v jq/  if false \&\& command -v jq/
    s/^  if ! gh auth status/  if false \&\& gh auth status/
  ' "$SCRIPT_PATH")"
}

# =============================================================================
# TEST SUITES
# =============================================================================

echo -e "${BOLD}github-helpers test suite${NC}"
echo -e "${DIM}─────────────────────────────────────────────${NC}"
echo ""

# ── 1. need_arg ──────────────────────────────────────────────────────────────
echo -e "${BOLD}1. need_arg (missing argument guard)${NC}"

source_helpers
setup_env

# need_arg with a value should succeed
output=$(need_arg "--flag" "value" 2>&1) && rc=0 || rc=$?
assert_exit_code "need_arg with value succeeds" 0 $rc

# need_arg with empty value should fail
output=$(need_arg "--flag" "" 2>&1) && rc=0 || rc=$?
assert_exit_code "need_arg with empty string fails" 1 $rc
assert_match "need_arg error mentions flag name" "flag.*requires" "$output"

# need_arg with no second arg should fail
output=$(need_arg "--flag" 2>&1) && rc=0 || rc=$?
assert_exit_code "need_arg with missing arg fails" 1 $rc

echo ""

# ── 2. cmd_unstar_parse_args ─────────────────────────────────────────────────
echo -e "${BOLD}2. cmd_unstar_parse_args${NC}"

setup_env
cmd_unstar_parse_args --commit-before 2024-01-01 --archived
assert_eq "commit-before parsed" "2024-01-01T00:00:00Z" "$FILTER_COMMIT_BEFORE"
assert_eq "archived flag parsed" "true" "$FILTER_ARCHIVED"

setup_env
cmd_unstar_parse_args --activity-after 2023-06-15 --not-archived --all
assert_eq "activity-after parsed" "2023-06-15T00:00:00Z" "$FILTER_ACTIVITY_AFTER"
assert_eq "not-archived parsed" "false" "$FILTER_ARCHIVED"
assert_eq "all mode parsed" "all" "$FILTER_MODE"

setup_env
cmd_unstar_parse_args --commit-before 2024-01-01 --dry-run --out results.txt
assert_eq "dry-run parsed" "true" "$DRY_RUN"
assert_eq "custom out-file parsed" "results.txt" "$OUT_FILE"

# Missing value should fail
setup_env
output=$(cmd_unstar_parse_args --commit-before 2>&1) && rc=0 || rc=$?
assert_exit_code "missing date value fails" 1 $rc
assert_match "error mentions flag" "commit-before.*requires" "$output"

# No filters should fail
setup_env
output=$(cmd_unstar_parse_args --dry-run 2>&1) && rc=0 || rc=$?
assert_exit_code "no filters fails" 1 $rc

# --save-list flag
setup_env
cmd_unstar_parse_args --archived --save-list
assert_eq "--save-list parsed" "true" "$SAVE_LIST"

# --out implies --save-list
setup_env
cmd_unstar_parse_args --archived --out mylist.txt
assert_eq "--out sets SAVE_LIST" "true" "$SAVE_LIST"
assert_eq "--out sets OUT_FILE" "mylist.txt" "$OUT_FILE"

# default: SAVE_LIST is false
setup_env
cmd_unstar_parse_args --archived
assert_eq "SAVE_LIST defaults to false" "false" "$SAVE_LIST"

echo ""

# ── 3. cmd_unstar_matches_filters ────────────────────────────────────────────
echo -e "${BOLD}3. cmd_unstar_matches_filters (filter logic)${NC}"

# archived filter
setup_env
FILTER_ARCHIVED="true"
cmd_unstar_matches_filters "owner/repo" "2024-01-01T00:00:00Z" "true" "2024-01-01T00:00:00Z" && result=0 || result=1
assert_exit_code "archived=true matches archived repo" 0 $result
assert_eq "archived reason set" "archived" "${REASONS[0]}"

setup_env
FILTER_ARCHIVED="true"
cmd_unstar_matches_filters "owner/repo" "2024-01-01T00:00:00Z" "false" "2024-01-01T00:00:00Z" && result=0 || result=1
assert_exit_code "archived=true rejects non-archived repo" 1 $result

# not-archived filter
setup_env
FILTER_ARCHIVED="false"
cmd_unstar_matches_filters "owner/repo" "2024-01-01T00:00:00Z" "false" "2024-01-01T00:00:00Z" && result=0 || result=1
assert_exit_code "not-archived matches non-archived repo" 0 $result
assert_eq "not-archived reason set" "not archived" "${REASONS[0]}"

# commit-before filter
setup_env
FILTER_COMMIT_BEFORE="2024-01-01T00:00:00Z"
cmd_unstar_matches_filters "owner/repo" "" "false" "2023-06-15T10:00:00Z" && result=0 || result=1
assert_exit_code "commit-before matches older commit" 0 $result

setup_env
FILTER_COMMIT_BEFORE="2024-01-01T00:00:00Z"
cmd_unstar_matches_filters "owner/repo" "" "false" "2024-06-15T10:00:00Z" && result=0 || result=1
assert_exit_code "commit-before rejects newer commit" 1 $result

# commit-before with no commit date (empty repo)
setup_env
FILTER_COMMIT_BEFORE="2024-01-01T00:00:00Z"
cmd_unstar_matches_filters "owner/repo" "" "false" "" && result=0 || result=1
assert_exit_code "commit-before matches empty commit date" 0 $result
assert_eq "reason for empty commit" "commit: none" "${REASONS[0]}"

# activity-after filter
setup_env
FILTER_ACTIVITY_AFTER="2024-01-01T00:00:00Z"
cmd_unstar_matches_filters "owner/repo" "2024-06-01T00:00:00Z" "false" "" && result=0 || result=1
assert_exit_code "activity-after matches newer push" 0 $result

setup_env
FILTER_ACTIVITY_AFTER="2024-01-01T00:00:00Z"
cmd_unstar_matches_filters "owner/repo" "2023-06-01T00:00:00Z" "false" "" && result=0 || result=1
assert_exit_code "activity-after rejects older push" 1 $result

# AND mode (--all): all filters must match
setup_env
FILTER_MODE="all"
FILTER_ARCHIVED="true"
FILTER_COMMIT_BEFORE="2024-01-01T00:00:00Z"
cmd_unstar_matches_filters "owner/repo" "" "true" "2023-06-15T00:00:00Z" && result=0 || result=1
assert_exit_code "all mode: both match → pass" 0 $result

setup_env
FILTER_MODE="all"
FILTER_ARCHIVED="true"
FILTER_COMMIT_BEFORE="2024-01-01T00:00:00Z"
cmd_unstar_matches_filters "owner/repo" "" "false" "2023-06-15T00:00:00Z" && result=0 || result=1
assert_exit_code "all mode: one misses → fail" 1 $result

# OR mode (--any): any filter match is enough
setup_env
FILTER_MODE="any"
FILTER_ARCHIVED="true"
FILTER_COMMIT_BEFORE="2024-01-01T00:00:00Z"
cmd_unstar_matches_filters "owner/repo" "" "false" "2023-06-15T00:00:00Z" && result=0 || result=1
assert_exit_code "any mode: one matches → pass" 0 $result

setup_env
FILTER_MODE="any"
FILTER_ARCHIVED="true"
FILTER_COMMIT_BEFORE="2024-01-01T00:00:00Z"
cmd_unstar_matches_filters "owner/repo" "" "false" "2025-06-15T00:00:00Z" && result=0 || result=1
assert_exit_code "any mode: none match → fail" 1 $result

echo ""

# ── 4. DRY_RUN global isolation ──────────────────────────────────────────────
echo -e "${BOLD}4. DRY_RUN global default${NC}"

setup_env
assert_eq "DRY_RUN starts false" "false" "$DRY_RUN"

# After sourcing, DRY_RUN should still be false (shared state init)
source_helpers
assert_eq "DRY_RUN false after source" "false" "$DRY_RUN"

echo ""

# ── 5. Temp file cleanup (no unstar-repos.txt in non-dry-run) ────────────────
echo -e "${BOLD}5. OUT_FILE not created in non-dry-run mode${NC}"

# We mirror the script's RESULTFILE logic:
#   if DRY_RUN or SAVE_LIST → use OUT_FILE
#   else → use temp file
result_file_logic() {
  if $DRY_RUN || $SAVE_LIST; then
    RESULTFILE="$OUT_FILE"
  else
    RESULTFILE=$(mktemp)
  fi
}

setup_env
DRY_RUN=true
OUT_FILE="/tmp/test-unstar-dry-$$.txt"
result_file_logic
assert_eq "dry-run: RESULTFILE equals OUT_FILE" "$OUT_FILE" "$RESULTFILE"

setup_env
DRY_RUN=false
OUT_FILE="/tmp/test-unstar-nodry-$$.txt"
result_file_logic
[ "$RESULTFILE" != "$OUT_FILE" ] && temp_ok=0 || temp_ok=1
assert_exit_code "non-dry-run: RESULTFILE is a temp file (not OUT_FILE)" 0 $temp_ok
rm -f "$RESULTFILE"

setup_env
DRY_RUN=false
SAVE_LIST=true
OUT_FILE="/tmp/test-unstar-savelist-$$.txt"
result_file_logic
assert_eq "--save-list: RESULTFILE equals OUT_FILE" "$OUT_FILE" "$RESULTFILE"

setup_env
DRY_RUN=false
SAVE_LIST=false
OUT_FILE="/tmp/test-unstar-nosave-$$.txt"
result_file_logic
[ "$RESULTFILE" != "$OUT_FILE" ] && temp_ok=0 || temp_ok=1
assert_exit_code "no --save-list: RESULTFILE is temp" 0 $temp_ok
rm -f "$RESULTFILE"

echo ""

# ── 6. base64 encoding (no line wrapping) ────────────────────────────────────
echo -e "${BOLD}6. base64 encoding (macOS line wrapping fix)${NC}"

# Simulate what the script does: large content should produce single-line base64
test_content=$(head -c 200 /dev/urandom | base64 | tr -d '\n')
encoded=$(echo -n "$test_content" | base64 | tr -d '\n')
line_count=$(echo "$encoded" | wc -l | tr -d ' ')
assert_eq "base64 output is single line" "1" "$line_count"
has_newline=$(echo -n "$encoded" | tr -cd '\n' | wc -c | tr -d ' ')
assert_eq "base64 output has no embedded newlines" "0" "$has_newline"

echo ""

# ── 7. Date validation in parse_args ─────────────────────────────────────────
echo -e "${BOLD}7. Date validation${NC}"

setup_env
output=$(cmd_unstar_parse_args --commit-before "not-a-date" 2>&1) && rc=0 || rc=$?
assert_exit_code "invalid date format rejected" 1 $rc
assert_match "error mentions invalid date" "invalid date" "$output"

setup_env
cmd_unstar_parse_args --commit-before "2024-06-15"
assert_eq "valid date accepted" "2024-06-15T00:00:00Z" "$FILTER_COMMIT_BEFORE"

echo ""

# ── 8. --from with missing file ──────────────────────────────────────────────
echo -e "${BOLD}8. --from file validation${NC}"

setup_env
output=$(cmd_unstar_parse_args --from "/tmp/nonexistent-file-$$" 2>&1) && rc=0 || rc=$?
assert_exit_code "--from with missing file fails" 1 $rc
assert_match "error mentions file not found" "file not found" "$output"

# --from with existing file should succeed
tmpfile=$(mktemp)
echo "owner/repo" > "$tmpfile"
setup_env
cmd_unstar_parse_args --from "$tmpfile"
assert_eq "--from with existing file succeeds" "$tmpfile" "$FROM_FILE"
rm -f "$tmpfile"

echo ""

# ── 9. Pipe subshell fix verification ────────────────────────────────────────
echo -e "${BOLD}9. Process substitution preserves counters${NC}"

# Simulate the fixed pattern: while ... done < <(echo ... | ...)
count=0
while IFS= read -r line; do
  count=$((count + 1))
done < <(printf '%s\n' "a" "b" "c")
assert_eq "process substitution counter works" "3" "$count"

# Verify the OLD broken pattern would lose the counter
count=0
printf '%s\n' "a" "b" "c" | while IFS= read -r line; do
  count=$((count + 1))
done
assert_eq "pipe subshell counter stays 0 (verifying the bug)" "0" "$count"

echo ""

# ── 11. Shared helpers ───────────────────────────────────────────────────────
echo -e "${BOLD}11. Shared helpers${NC}"
setup_env

# cutoff_date: exact values are time-dependent, so assert shape and ordering.
assert_match "cutoff_date emits an ISO-8601 Z timestamp" \
  '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$(cutoff_date 30 days)"
assert_match "cutoff_date accepts months" \
  '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$(cutoff_date 6 months)"
older=$(cutoff_date 2 days); newer=$(cutoff_date 1 days)
[[ "$older" < "$newer" ]] && ord=0 || ord=1
assert_exit_code "cutoff_date output sorts lexicographically by age" 0 $ord
(cutoff_date abc days) &>/dev/null && rc=0 || rc=1
assert_exit_code "cutoff_date rejects a non-numeric count" 1 $rc
(cutoff_date 5 weeks) &>/dev/null && rc=0 || rc=1
assert_exit_code "cutoff_date rejects an unknown unit" 1 $rc

# parse_size / human_bytes
assert_eq "parse_size plain bytes"    "100"        "$(parse_size 100)"
assert_eq "parse_size 500K"           "512000"     "$(parse_size 500K)"
assert_eq "parse_size 100MB"          "104857600"  "$(parse_size 100MB)"
assert_eq "parse_size fractional GiB" "1610612736" "$(parse_size 1.5GiB)"
(parse_size 12ZB) &>/dev/null && rc=0 || rc=1
assert_exit_code "parse_size rejects an unknown unit" 1 $rc
(parse_size "") &>/dev/null && rc=0 || rc=1
assert_exit_code "parse_size rejects an empty value" 1 $rc
assert_eq "human_bytes under 1K"  "512 B"   "$(human_bytes 512)"
assert_eq "human_bytes KB"        "1.0 KB"  "$(human_bytes 1024)"
assert_eq "human_bytes GB"        "1.2 GB"  "$(human_bytes 1288490188)"
assert_eq "human_bytes on garbage" "0 B"    "$(human_bytes abc)"

# count_lines: `grep -c '.' f || echo 0` prints "0\n0" on an empty file.
empty_file=$(mktemp); : > "$empty_file"
assert_eq "count_lines on an empty file is a single 0" "0" "$(count_lines "$empty_file")"
printf 'a\n\nb\n' > "$empty_file"
assert_eq "count_lines ignores blank lines" "2" "$(count_lines "$empty_file")"
assert_eq "count_lines on a missing file is 0" "0" "$(count_lines /nonexistent-zz)"
rm -f "$empty_file"

# confirm: honours --yes and --dry-run, and defaults to no.
setup_env
AUTO_YES=false DRY_RUN=false
confirm "x" </dev/null && rc=0 || rc=1
assert_exit_code "confirm defaults to no on empty input" 1 $rc
echo y | confirm "x" && rc=0 || rc=1
assert_exit_code "confirm accepts y" 0 $rc
echo n | confirm "x" && rc=0 || rc=1
assert_exit_code "confirm rejects n" 1 $rc
AUTO_YES=true DRY_RUN=false
confirm "x" </dev/null && rc=0 || rc=1
assert_exit_code "confirm auto-proceeds under --yes" 0 $rc
AUTO_YES=false DRY_RUN=true
confirm "x" </dev/null && rc=0 || rc=1
assert_exit_code "confirm auto-proceeds under --dry-run" 0 $rc
setup_env

# render_rows
ROWS='[{"a":"x","b":1},{"a":"y","b":2}]'
assert_eq "render_rows csv header follows key order" '"a","b"' "$(render_rows csv "$ROWS" | head -1)"
assert_eq "render_rows csv row" '"y","2"' "$(render_rows csv "$ROWS" | tail -1)"
assert_eq "render_rows md header" '| a | b |' "$(render_rows md "$ROWS" | head -1)"
assert_eq "render_rows on an empty array emits nothing" "" "$(render_rows csv '[]')"
assert_eq "render_rows flattens newlines in csv" '"a b","1"' \
  "$(render_rows csv '[{"a":"a\nb","b":1}]' | tail -1)"

echo ""

# ── 12. cleanup-forks: the fail-safe classifier ─────────────────────────────
echo -e "${BOLD}12. cleanup-forks fail-safe classifier${NC}"
setup_env
CUT="2026-01-01T00:00:00Z"
OLD="2025-01-01T00:00:00Z"
NEW="2026-07-01T00:00:00Z"
verdict() { cmd_cleanup_forks_cheap_verdict "$@" | cut -f1; }

CLEANUP_FORKS_INCLUDE_ORPHANS=false
CLEANUP_FORKS_INCLUDE_ARCHIVED=false
CLEANUP_FORKS_IGNORE_POPULARITY=false

assert_eq "clean, old, unpopular fork goes to the API probe" "PROBE" \
  "$(verdict u/a p/a false false false 0 0 0 "$OLD" "$OLD" "$CUT")"
assert_eq "orphan is protected by default" "PROTECTED" \
  "$(verdict u/a '' false false false 0 0 0 "$OLD" "$OLD" "$CUT")"
assert_eq "stars protect" "PROTECTED" \
  "$(verdict u/a p/a false false false 3 0 0 "$OLD" "$OLD" "$CUT")"
assert_eq "watchers protect" "PROTECTED" \
  "$(verdict u/a p/a false false false 0 0 1 "$OLD" "$OLD" "$CUT")"
assert_eq "being forked by others protects" "PROTECTED" \
  "$(verdict u/a p/a false false false 0 2 0 "$OLD" "$OLD" "$CUT")"
assert_eq "archived is protected by default" "PROTECTED" \
  "$(verdict u/a p/a true false false 0 0 0 "$OLD" "$OLD" "$CUT")"
assert_eq "locked repo is always protected" "PROTECTED" \
  "$(verdict u/a p/a false true false 0 0 0 "$OLD" "$OLD" "$CUT")"
assert_eq "a recent push protects" "PROTECTED" \
  "$(verdict u/a p/a false false false 0 0 0 "$NEW" "$OLD" "$CUT")"
assert_eq "a recent creation protects" "PROTECTED" \
  "$(verdict u/a p/a false false false 0 0 0 "$OLD" "$NEW" "$CUT")"
assert_eq "an empty star count is unreadable, not zero" "SKIPPED" \
  "$(verdict u/a p/a false false false '' 0 0 "$OLD" "$OLD" "$CUT")"
assert_eq "a null star count is unreadable" "SKIPPED" \
  "$(verdict u/a p/a false false false null 0 0 "$OLD" "$OLD" "$CUT")"
assert_eq "missing timestamps are unreadable" "SKIPPED" \
  "$(verdict u/a p/a false false false 0 0 0 '' '' "$CUT")"
assert_eq "a malformed record is skipped" "SKIPPED" \
  "$(verdict '' p/a false false false 0 0 0 "$OLD" "$OLD" "$CUT")"

CLEANUP_FORKS_INCLUDE_ORPHANS=true
assert_eq "--include-orphans lets an orphan reach the probe" "PROBE" \
  "$(verdict u/a '' false false false 0 0 0 "$OLD" "$OLD" "$CUT")"
CLEANUP_FORKS_INCLUDE_ORPHANS=false
CLEANUP_FORKS_IGNORE_POPULARITY=true
assert_eq "--ignore-popularity drops the star guard" "PROBE" \
  "$(verdict u/a p/a false false false 99 9 9 "$OLD" "$OLD" "$CUT")"
CLEANUP_FORKS_IGNORE_POPULARITY=false

# THE invariant: this function must never be able to authorise a deletion.
bad=0
for par in "" "p/a"; do for arch in true false; do for lock in true false; do
  for st in "" null -1 0 5 abc; do for pu in "" "$OLD" "$NEW"; do
    for orph in true false; do
      CLEANUP_FORKS_INCLUDE_ORPHANS=$orph
      [ "$(verdict u/a "$par" "$arch" "$lock" false "$st" 0 0 "$pu" '' "$CUT")" = "DELETABLE" ] \
        && bad=$((bad + 1))
    done
  done; done; done; done; done
assert_eq "cheap_verdict never emits DELETABLE (288 degenerate inputs)" "0" "$bad"
CLEANUP_FORKS_INCLUDE_ORPHANS=false

echo ""

# ── 13. Pure parsers ─────────────────────────────────────────────────────────
echo -e "${BOLD}13. Pure parsers${NC}"
setup_env
assert_eq "semver patch bump"                "patch"   "$(cmd_bulk_merge_bump_kind 'Bump lodash from 4.17.20 to 4.17.21')"
assert_eq "semver minor bump"                "minor"   "$(cmd_bulk_merge_bump_kind 'Bump actions/checkout from 3.1.0 to 3.2.0')"
assert_eq "semver major bump"                "major"   "$(cmd_bulk_merge_bump_kind 'Bump express from 4.18.2 to 5.0.0')"
assert_eq "semver bare major tags"           "major"   "$(cmd_bulk_merge_bump_kind 'bump actions/setup-node from 4 to 7')"
assert_eq "semver partial versions"          "minor"   "$(cmd_bulk_merge_bump_kind 'bump actions/checkout from 4 to 4.1')"
assert_eq "semver prerelease suffix"         "patch"   "$(cmd_bulk_merge_bump_kind 'Bump @types/node from 20.1.0-beta.1 to 20.1.1')"
assert_eq "semver grouped update is unknown" "unknown" "$(cmd_bulk_merge_bump_kind 'Bump the npm group with 3 updates')"
assert_eq "semver unrelated title"           "unknown" "$(cmd_bulk_merge_bump_kind 'Update README')"

# The batch query builder must omit compare() for orphans and pass names as
# GraphQL variables rather than interpolating them into the query text.
cmd_cleanup_forks_build_batch_query $'u/a\x1fp/a\x1fmain\x1fmain' $'u/b\x1f\x1f\x1fmain'
assert_eq "batch query has one alias per fork" "2" "$(printf '%s' "$CF_QUERY" | grep -c 'repository(owner:')"
assert_eq "batch query omits compare for the orphan" "1" "$(printf '%s' "$CF_QUERY" | grep -c 'compare(headRef:')"
assert_eq "repo names travel as GraphQL variables" "-f o0=u -f n0=a -f h0=p:main -f o1=u -f n1=b" "${CF_GQL_ARGS[*]}"
assert_match "batch meta records the parent per alias" '"f1":\{"nwo":"u/b","parent":""' "$CF_BATCH_META"

echo ""
# ── 10. Script syntax check ─────────────────────────────────────────────────
echo -e "${BOLD}10. Script integrity${NC}"

bash -n "$SCRIPT_PATH" 2>/dev/null && syntax_ok=0 || syntax_ok=1
assert_exit_code "bash -n syntax check passes" 0 $syntax_ok

# Verify need_arg is present in all shift 2 lines
shift2_total=$(grep -c 'shift 2 ;;' "$SCRIPT_PATH")
needarg_total=$(grep -c 'need_arg.*shift 2 ;;' "$SCRIPT_PATH")
assert_eq "all shift-2 cases have need_arg guard (${needarg_total}/${shift2_total})" "$shift2_total" "$needarg_total"

# Verify no local variables in EXIT traps
bad_traps=$(grep -c "trap.*rm.*\"\$[a-z]" "$SCRIPT_PATH" || true)
assert_eq "no traps referencing bare local vars" "0" "$bad_traps"

# Confirmations must go through confirm(); the only `read -rp` left is its own.
raw_prompts=$(grep -c 'read -rp' "$SCRIPT_PATH" || true)
assert_eq "no hand-rolled confirmation prompts" "1" "$raw_prompts"

# Repo deletion is irreversible: keep it to a single, reviewable call site.
delete_sites=$(grep -c 'gh repo delete' "$SCRIPT_PATH" || true)
assert_eq "exactly one 'gh repo delete' call site" "1" "$delete_sites"

# The original bug: GNU `date --iso-8601=seconds` emits `+00:00` where BSD
# emits `Z`. Every consumer compares lexicographically against GitHub's `Z`
# timestamps and `+` sorts before `Z`, so results were skewed on Linux only.
iso_flag=$(grep -c -- '--iso-8601' "$SCRIPT_PATH" || true)
assert_eq "no --iso-8601 date formatting" "0" "$iso_flag"

# ISO-8601 `Z` timestamps come from exactly two places: the two branches of
# cutoff_date (N units ago) and `date -u` for "now". Anything else would be a
# new hand-rolled, platform-dependent date computation.
# `+FORMAT` produces a timestamp; `-jf FORMAT` parses one, so only the former
# counts as date arithmetic.
produced=$(grep -c 'date .*+"\?%Y-%m-%dT%H:%M:%SZ' "$SCRIPT_PATH" | tr -d ' ')
now_stamps=$(grep -c 'date -u +%Y-%m-%dT%H:%M:%SZ' "$SCRIPT_PATH" | tr -d ' ')
assert_eq "ISO-Z arithmetic lives only in cutoff_date" "2" "$((produced - now_stamps))"

# Every dispatched command must have a matching usage function.
missing_usage=0
while IFS= read -r fn; do
  grep -q "^${fn%_main}_usage()" "$SCRIPT_PATH" || { missing_usage=$((missing_usage + 1)); echo "       no usage for $fn"; }
done < <(grep -oE 'cmd_[a-z_]+_main' "$SCRIPT_PATH" | sort -u)
assert_eq "every command has a usage function" "0" "$missing_usage"

# New commands must not install their own EXIT trap: it would replace the
# global tmp_cleanup one and leak every file allocated through tmp_new.
own_traps=$(grep -c "trap .* EXIT" "$SCRIPT_PATH" || true)
assert_eq "EXIT traps stay at the documented count" "6" "$own_traps"

echo ""

# ── Results ──────────────────────────────────────────────────────────────────
echo -e "${DIM}─────────────────────────────────────────────${NC}"
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}All ${TOTAL} tests passed!${NC}"
else
  echo -e "${RED}${BOLD}${FAIL}/${TOTAL} tests failed${NC}"
fi

exit "$FAIL"
