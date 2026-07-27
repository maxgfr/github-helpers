# CLAUDE.md

Guidelines for working on this project with Claude Code.

## Project overview

`github-helpers` is a multi-command bash CLI tool for GitHub maintenance tasks. Everything lives in a single `script.sh` file.

## Architecture

- **Single file**: All commands are in `script.sh` — no separate files. This is a distribution constraint: Homebrew and the curl installer drop one executable, so splitting would require a build step.
- **Subcommand routing**: `main()` dispatches to `cmd_<name>_main()` via a `case` statement.
- **Naming convention**: Each command's functions are prefixed `cmd_<name>_` (e.g., `cmd_unstar_usage`, `cmd_unstar_parse_args`, `cmd_unstar_main`).
- **Global state**: Variables like `AUTO_YES`, `VERBOSE`, `DRY_RUN` are globals — only one command runs per invocation.
- **Colors**: ANSI codes in `$'...'` variables (`RED`, `GREEN`, etc.), auto-disabled when not a TTY or `NO_COLOR` is set. IMPORTANT: use `$'\033[...'` (not `'\033[...'`) so colors work in `cat <<EOF` heredocs.

## Shared utilities

Defined at the top of `script.sh`. **Use them — do not re-implement.**

| Helper | Purpose |
|---|---|
| `die "msg"` / `warn "msg"` | Fatal / non-fatal, both to stderr |
| `need_arg "--flag" "$2"` | Required on every valued flag (enforced by `test.sh`) |
| `preflight_check` | `gh`, `jq`, `gh auth status` |
| `get_username` | Authenticated login |
| `confirm "prompt"` | Returns 0/1, honours `--yes` and `--dry-run` |
| `cutoff_date N days\|months\|years` | ISO-8601 UTC, cross-platform |
| `parse_size 100MB` / `human_bytes N` | Byte sizes, base 1024 |
| `count_lines FILE` | Non-blank line count, always one integer |
| `tmp_new` | Temp file registered with the single global EXIT trap |
| `skip_init` / `skip_note` / `print_skips` | Degraded-access bookkeeping |
| `scope_hint "scopes"` | One-shot `gh auth refresh` hint after a 403 |
| `gh_api_retry` / `gh_api_try` / `gh_paginate` | API access with backoff and skip handling |
| `require_scope delete_repo` | Token scope check (permissive when unknowable) |
| `list_repos` / `resolve_repo_list` | Repo enumeration |
| `hr` / `header "Title"` / `render_rows` / `write_output` | Output |
| `git_mirror_clone` / `git_bundle_from_mirror` / `sha256_of` | Git and checksums |

## Cross-cutting rules

These are binding on new commands and enforced by `test.sh` where possible.

- **Confirmations go through `confirm`**, always in a conditional context (`if ! confirm "…"; then`). A bare call would trip `set -e` when the user declines. No hand-rolled `read -rp`.
- **Chrome to stderr, payload to stdout** for any command with `--format`, so `… --format json | jq` works and `2>/dev/null` silences the rest.
- **Never `die` on one target.** A 403/404 on a single repo calls `skip_note` and continues; `print_skips` summarises at the end.
- **No silent truncation.** When `--limit` caps a sweep, say so.
- **`done < file` or `done < <(…)`, never `… | while`** — a pipeline runs the loop in a subshell and loses every counter.
- **No per-command `trap … EXIT`.** It would replace the global `tmp_cleanup` trap; allocate through `tmp_new` instead.
- **Destructive commands** need `--dry-run`, a preview, and a confirmation whose text states the real count. Prefer the `unstar` review-then-execute loop (`--dry-run` writes a list, `--from` re-reads it) for anything irreversible.
- **Fail safe.** Initialise a verdict to the *safe* value and only write the destructive one at the end of a fully resolved path. See `cmd_cleanup_forks_cheap_verdict`, which can never emit `DELETABLE`.
- Use `gh` for all GitHub API interactions — never raw `curl` with tokens. Use `jq` for JSON.
- Use GraphQL (`gh api graphql`) only when REST/`gh` cannot provide the data (starred repos with commit dates, fork divergence across branches, follower reciprocity).
- `--org NAME` / `--user NAME` for targeting; common filters `--archived`, `--not-archived`, `--fork`, `--source`, `--language`, `--topic`, `--visibility`, `--limit`.

## Bash traps that bit us

- `grep -c '.' f || echo 0` prints `0\n0` on an empty file: `grep -c` prints `0` **and** exits 1, so the fallback fires too. Use `count_lines`.
- `local a="$1" b="${a}/x"` trips `set -u`: bash declares every name in a `local` list before evaluating any assignment, so `$a` is still unset. Split into two statements.
- `VAR=$(f)` where `f` sets globals silently discards them — command substitution is a subshell. Return through a global instead (see `cmd_cleanup_forks_build_batch_query`).
- `[...] | index(.field)` in jq evaluates `.field` against the *array*, not the object. Bind it first: `.field as $x | [...] | index($x)`.
- `${BOOL:+value}` fires when `BOOL` holds the string `"false"`, which is non-empty. Use `$BOOL && x=value`.
- `awk` follows `LC_NUMERIC`, so `printf "%.1f"` emits a comma under a French locale. Prefix with `LC_ALL=C`.
- Colour codes inside a `%-Ns` printf field break the padding. Pad first (`printf -v`), colour after.

## Adding a new command

1. Add a defaults section: `CMD_NAME_VAR=""` etc.
2. Add `cmd_<name>_usage()`, `cmd_<name>_parse_args()`, `cmd_<name>_main()`.
3. Add the command to the `case` in `main()`.
4. Add a help line in `usage()` and to the header comment.
5. Add a smoke test in `.github/workflows/check-program.yml` (`./script.sh <name> --help`), plus a negative test for any validation the parser does.
6. Add unit tests in `test.sh` for any pure function (parsers, classifiers, formatters).
7. Add documentation in `README.md`: a row in the commands table and a section with usage examples and a flags table.

## Release process

- Commits to `main` trigger `semantic-release` via GitHub Actions.
- `feat:` → minor bump, `fix:` → patch bump, `feat!:` → major bump.
- `.version-hook.sh` updates `VERSION="..."` in `script.sh`.
- Homebrew formula in `maxgfr/homebrew-tap` (`Formula/github-helpers.rb`) auto-updates daily via a workflow.

## Testing

`test.sh` holds the unit tests (114 of them, all offline). It sources `script.sh` with `main "$@"` and the preflight checks neutralised by `sed`, then calls functions in-process. CI runs it plus a `--help` smoke test per command.

Suite 10 is a set of grep-based invariants over the whole script: `bash -n`, `need_arg` on every `shift 2`, no lowercase locals in traps, no raw `read -rp`, a single `gh repo delete` call site, ISO date arithmetic only in `cutoff_date`, a usage function per command, and a pinned EXIT-trap count.

```bash
bash -n script.sh
./test.sh
./script.sh --help
./script.sh <command> --help
./script.sh <command> --dry-run [required-flags]
```

## Commands (39 total)

**Cleanup & maintenance**: `unstar`, `cleanup-forks` (alias `forks`), `sync-forks`, `cleanup-branches`, `archive-repos`, `release-cleanup`, `pr-cleanup`, `cleanup-packages`, `stale-issues`, `cache-cleanup`, `artifact-cleanup`, `run-cleanup`, `gist` (alias `gists`), `notifications` (alias `notifs`), `invite-cleanup`
**Audit & visibility**: `repo-audit` (alias `audit`), `stats`, `workflow-status` (alias `ci`), `secret-audit`, `license-check`, `vulnerability-check`, `branch-protection`, `webhook-audit`, `collaborator-audit`, `activity-report`, `traffic`, `org-audit`, `follow-audit` (alias `follow`)
**Bulk operations**: `clone-org`, `bulk-topic`, `sync-labels`, `export-stars`, `rename-default-branch`, `dependabot-enable`, `mirror`, `bulk-settings`, `repo-template`, `bulk-merge`, `backup`

## Dependencies

- `gh` (GitHub CLI) — authenticated. Some commands need extra scopes and say so on their first 403: `delete_repo` (cleanup-forks), `notifications`, `user:follow` (follow-audit), `read:org`/`admin:org` (org-audit).
- `jq` — JSON processor
- `git` — for clone-org, mirror, backup
- `bash` 4+ (`${var^}`, `declare -A`)
- Standard POSIX tools (`mktemp`, `sort`, `grep`, `awk`, `base64`, etc.)
