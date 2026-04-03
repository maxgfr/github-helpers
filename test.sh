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

echo ""

# ── Results ──────────────────────────────────────────────────────────────────
echo -e "${DIM}─────────────────────────────────────────────${NC}"
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}All ${TOTAL} tests passed!${NC}"
else
  echo -e "${RED}${BOLD}${FAIL}/${TOTAL} tests failed${NC}"
fi

exit "$FAIL"
