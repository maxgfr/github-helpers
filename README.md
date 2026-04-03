# github-helpers

GitHub maintenance toolkit — a single CLI for common GitHub bulk operations.

## Install

```bash
brew install maxgfr/tap/github-helpers
```

Or manually:

```bash
git clone https://github.com/maxgfr/github-helpers.git
chmod +x github-helpers/script.sh
cp github-helpers/script.sh /usr/local/bin/github-helpers
```

### Requirements

- [gh](https://cli.github.com) — GitHub CLI (authenticated via `gh auth login`)
- [jq](https://jqlang.github.io/jq/) — JSON processor

## Commands

### `unstar` — Clean up your GitHub stars

Filter and bulk-unstar repos by last commit date, last push date, or archived status.

```bash
# Preview: repos with no commit since 2024 OR archived
github-helpers unstar --commit-before 2024-01-01 --archived --dry-run -v

# Edit the generated list, then execute
vim unstar-repos.txt
github-helpers unstar --from unstar-repos.txt

# One-shot: unstar all archived repos
github-helpers unstar --archived -y
```

**Filters** (combine as many as needed):

| Flag | Description |
|---|---|
| `--commit-before DATE` | Last commit was before this date (YYYY-MM-DD) |
| `--commit-after DATE` | Last commit was after this date (YYYY-MM-DD) |
| `--activity-before DATE` | Last push was before this date (YYYY-MM-DD) |
| `--activity-after DATE` | Last push was after this date (YYYY-MM-DD) |
| `--archived` | Only archived repos |
| `--not-archived` | Only non-archived repos |

**Logic**:

| Flag | Description |
|---|---|
| `--any` | Match if ANY filter hits (OR, **default**) |
| `--all` | Match if ALL filters hit (AND) |

**I/O**:

| Flag | Description |
|---|---|
| `--dry-run` | Preview only, saves list to file |
| `--out FILE` | Output file (default: `unstar-repos.txt`) |
| `--from FILE` | Unstar from a previous dry-run file |

### `clone-org` — Clone all repos from a GitHub organization

```bash
# List all repos in an org (dry-run)
github-helpers clone-org --org my-company --dry-run

# Clone all non-archived repos via SSH
github-helpers clone-org --org my-company --ssh --not-archived

# Clone into a specific directory
github-helpers clone-org --org my-company --dir ~/projects/my-company

# Clone only public repos, no confirmation
github-helpers clone-org --org my-company --visibility public -y
```

**Options**:

| Flag | Description |
|---|---|
| `--org NAME` | **(required)** GitHub organization name |
| `--dir PATH` | Clone destination (default: `.`) |
| `--ssh` | Clone via SSH instead of HTTPS |
| `--archived` | Only archived repos |
| `--not-archived` | Only non-archived repos |
| `--visibility TYPE` | `public`, `private`, or `internal` |
| `--limit N` | Max repos to clone |
| `--dry-run` | List repos without cloning |

### Common flags

| Flag | Description |
|---|---|
| `-y, --yes` | Skip confirmation prompt |
| `-v, --verbose` | Detailed output |
| `-h, --help` | Show help |

## License

MIT
