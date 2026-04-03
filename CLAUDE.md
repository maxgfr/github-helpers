# CLAUDE.md

Guidelines for working on this project with Claude Code.

## Project overview

`github-helpers` is a multi-command bash CLI tool for GitHub maintenance tasks. Everything lives in a single `script.sh` file.

## Architecture

- **Single file**: All commands are in `script.sh` — no separate files.
- **Subcommand routing**: `main()` dispatches to `cmd_<name>_main()` via a `case` statement.
- **Naming convention**: Each command's functions are prefixed `cmd_<name>_` (e.g., `cmd_unstar_usage`, `cmd_unstar_parse_args`, `cmd_unstar_main`).
- **Shared utilities** at the top: `die()`, `preflight_check()`, `get_username()`, `disable_colors()`.
- **Global state**: Variables like `AUTO_YES`, `VERBOSE`, `DRY_RUN` are globals — only one command runs per invocation.
- **Colors**: ANSI codes in variables (`RED`, `GREEN`, etc.), auto-disabled when not a TTY or `NO_COLOR` is set.

## Adding a new command

1. Add a defaults section: `CMD_NAME_VAR=""` etc.
2. Add `cmd_<name>_usage()`, `cmd_<name>_parse_args()`, `cmd_<name>_main()`.
3. Add the command to the `case` in `main()`.
4. Add a help line in `usage()`.
5. Add a smoke test in `.github/workflows/check-program.yml` (`./script.sh <name> --help`).

## Key conventions

- All destructive operations require `--dry-run` support and confirmation prompts (unless `-y`).
- Use `gh` CLI for all GitHub API interactions — never raw `curl` with tokens.
- Use `jq` for JSON parsing.
- Prefer `gh repo list` (handles pagination) over manual `gh api` pagination when listing repos.
- Use GraphQL (`gh api graphql`) only when REST/`gh` commands don't provide the needed data (e.g., starred repos with commit dates).
- `--org NAME` / `--user NAME` pattern for targeting orgs or users.
- Common filters: `--archived`, `--not-archived`, `--fork`, `--source`, `--language`, `--topic`, `--visibility`, `--limit`.

## Release process

- Commits to `main` trigger `semantic-release` via GitHub Actions.
- `feat:` → minor bump, `fix:` → patch bump, `feat!:` → major bump.
- `.version-hook.sh` updates `VERSION="..."` in `script.sh`.
- Homebrew formula in `maxgfr/homebrew-tap` (`Formula/github-helpers.rb`) auto-updates daily via a workflow.

## Testing

There are no unit tests. CI runs smoke tests: every `<command> --help` must exit 0, unknown commands must exit 1. Test locally with:

```bash
./script.sh --help
./script.sh <command> --help
./script.sh <command> --dry-run [required-flags]
```

## Dependencies

- `gh` (GitHub CLI) — authenticated
- `jq` — JSON processor
- `git` — for clone-org
- Standard POSIX tools (`mktemp`, `sort`, `grep`, etc.)
