# github-helpers

[![Release](https://img.shields.io/github/v/release/maxgfr/github-helpers)](https://github.com/maxgfr/github-helpers/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Homebrew](https://img.shields.io/badge/homebrew-maxgfr%2Ftap-orange)](https://github.com/maxgfr/homebrew-tap)

GitHub maintenance toolkit — a single CLI for common GitHub bulk operations. Pure bash, zero dependencies beyond `gh` and `jq`.

## Install

```bash
brew install maxgfr/tap/github-helpers
```

Or manually:

```bash
curl -fsSL https://raw.githubusercontent.com/maxgfr/github-helpers/main/script.sh -o /usr/local/bin/github-helpers
chmod +x /usr/local/bin/github-helpers
```

### Requirements

- [gh](https://cli.github.com) — GitHub CLI (authenticated via `gh auth login`)
- [jq](https://jqlang.github.io/jq/) — JSON processor

## Commands

| Command | Description |
|---|---|
| [`unstar`](#unstar--clean-up-your-github-stars) | Filter & bulk-unstar repos |
| [`cleanup-forks`](#cleanup-forks--remove-unmodified-forks) | Delete forks with 0 commits ahead |
| [`cleanup-branches`](#cleanup-branches--delete-merged-or-stale-branches) | Delete merged/stale remote branches |
| [`archive-repos`](#archive-repos--archive-inactive-repos) | Batch archive inactive repos |
| [`repo-audit`](#repo-audit--scan-repos-for-common-issues) | Check for missing LICENSE, README, etc. |
| [`stats`](#stats--github-profile-stats) | Dashboard: repos, stars, languages |
| [`workflow-status`](#workflow-status--ci-workflow-overview) | Latest CI status across repos |
| [`clone-org`](#clone-org--clone-all-repos-from-a-github-org-or-user) | Clone/pull all repos from an org or user |
| [`bulk-topic`](#bulk-topic--add-or-remove-topics-in-batch) | Add/remove topics in batch |
| [`sync-labels`](#sync-labels--sync-issue-labels-from-a-template-repo) | Sync issue labels across repos |
| [`export-stars`](#export-stars--export-starred-repos) | Export stars to JSON/CSV/Markdown |
| [`rename-default-branch`](#rename-default-branch--rename-default-branch-across-repos) | Rename master→main in batch |
| [`secret-audit`](#secret-audit--list-secrets-and-env-vars) | List Actions secrets & variables |
| [`license-check`](#license-check--check-and-add-license-files) | Check/add LICENSE files |
| [`dependabot-enable`](#dependabot-enable--enable-dependabot-on-repos) | Enable Dependabot in batch |
| [`mirror`](#mirror--mirror-repos-to-another-remote) | Mirror repos to GitLab/Bitbucket/etc. |
| [`release-cleanup`](#release-cleanup--delete-old-releases) | Delete old releases, keep N latest |

---

### Cleanup & maintenance

#### `unstar` — Clean up your GitHub stars

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

| Flag | Description |
|---|---|
| `--commit-before DATE` | Last commit was before this date (YYYY-MM-DD) |
| `--commit-after DATE` | Last commit was after this date |
| `--activity-before DATE` | Last push was before this date |
| `--activity-after DATE` | Last push was after this date |
| `--archived` / `--not-archived` | Filter by archive status |
| `--any` | Match if ANY filter hits (OR, **default**) |
| `--all` | Match if ALL filters hit (AND) |
| `--dry-run` | Preview only, saves list to file |
| `--out FILE` | Output file (default: `unstar-repos.txt`) |
| `--from FILE` | Unstar from a previous dry-run file |

#### `cleanup-forks` — Remove unmodified forks

Delete forks with 0 commits ahead of the parent repo.

```bash
github-helpers cleanup-forks --dry-run
github-helpers cleanup-forks -y
```

#### `cleanup-branches` — Delete merged or stale branches

Clean up remote branches across one or many repos.

```bash
# Merged branches on a single repo
github-helpers cleanup-branches --repo maxgfr/my-repo --dry-run

# Stale branches (no commit in 90 days) across an org
github-helpers cleanup-branches --org my-company --stale-days 90 --dry-run

# Exclude release branches
github-helpers cleanup-branches --user maxgfr --exclude "release|hotfix" --dry-run
```

| Flag | Description |
|---|---|
| `--repo OWNER/REPO` | Single repository |
| `--org NAME` / `--user NAME` | All repos in org or user |
| `--merged` | Delete only merged branches (default) |
| `--stale-days N` | Delete branches with no commits in N days |
| `--exclude PATTERN` | Exclude branches matching regex |

#### `archive-repos` — Archive inactive repos

Batch archive repos with no push activity in N months.

```bash
github-helpers archive-repos --inactive-months 24 --dry-run
github-helpers archive-repos --org my-company --inactive-months 12 -y
```

| Flag | Description |
|---|---|
| `--user NAME` / `--org NAME` | Target (default: authenticated user) |
| `--inactive-months N` | Inactivity threshold (default: 12) |
| `--language LANG` | Filter by language |
| `--topic TOPIC` | Filter by topic |

---

### Audit & visibility

#### `repo-audit` — Scan repos for common issues

Check repos for missing LICENSE, README, description, or topics.

```bash
github-helpers repo-audit
github-helpers repo-audit --org my-company
github-helpers repo-audit --language Shell -v
```

| Flag | Description |
|---|---|
| `--user NAME` / `--org NAME` | Target (default: authenticated user) |
| `--language LANG` | Filter by language |
| `--topic TOPIC` | Filter by topic |
| `--limit N` | Max repos to scan |

#### `stats` — GitHub profile stats

Quick dashboard: repo count, total stars/forks, top languages, most starred, least active.

```bash
github-helpers stats
github-helpers stats --org my-company
```

#### `workflow-status` — CI workflow overview

See the latest CI run status for all your repos at a glance.

```bash
github-helpers workflow-status
github-helpers workflow-status --org my-company --failed
github-helpers workflow-status --limit 50
```

| Flag | Description |
|---|---|
| `--user NAME` / `--org NAME` | Target (default: authenticated user) |
| `--limit N` | Max repos to scan (default: 30) |
| `--failed` | Show only repos with failed workflows |

---

### Bulk operations

#### `clone-org` — Clone all repos from a GitHub org or user

```bash
github-helpers clone-org --org my-company --ssh --not-archived
github-helpers clone-org --user octocat --source --language Go
github-helpers clone-org --org my-company --dir ~/projects --pull
```

| Flag | Description |
|---|---|
| `--org NAME` / `--user NAME` | Target (one required) |
| `--dir PATH` | Clone destination (default: `.`) |
| `--ssh` | Clone via SSH instead of HTTPS |
| `--pull` | Pull existing repos instead of skipping |
| `--archived` / `--not-archived` | Filter by archive status |
| `--fork` / `--source` | Filter by fork status |
| `--visibility TYPE` | `public`, `private`, or `internal` |
| `--language LANG` | Filter by primary language |
| `--topic TOPIC` | Filter by topic |
| `--limit N` | Max repos to clone |

#### `bulk-topic` — Add or remove topics in batch

```bash
github-helpers bulk-topic --add shell --language Shell --dry-run
github-helpers bulk-topic --remove deprecated --topic deprecated -y
github-helpers bulk-topic --add cli --pattern "^maxgfr/(git-|package-)" --dry-run
```

| Flag | Description |
|---|---|
| `--add TOPIC` | Add topic to matching repos |
| `--remove TOPIC` | Remove topic from matching repos |
| `--user NAME` / `--org NAME` | Target (default: authenticated user) |
| `--language LANG` | Filter by language |
| `--topic TOPIC` | Filter by existing topic |
| `--pattern PATTERN` | Filter by name (grep regex) |

#### `sync-labels` — Sync issue labels from a template repo

```bash
github-helpers sync-labels --from maxgfr/template --to maxgfr/my-repo --dry-run
github-helpers sync-labels --from maxgfr/template --org my-company -y
```

| Flag | Description |
|---|---|
| `--from OWNER/REPO` | Source repo with template labels |
| `--to OWNER/REPO` | Single target repo |
| `--org NAME` / `--user NAME` | Apply to all repos |

#### `export-stars` — Export starred repos

```bash
github-helpers export-stars --format json --out stars.json
github-helpers export-stars --format csv --out stars.csv
github-helpers export-stars --format md
```

| Flag | Description |
|---|---|
| `--format FORMAT` | `json`, `csv`, or `md` (default: json) |
| `--out FILE` | Output file (default: stdout) |

#### `rename-default-branch` — Rename default branch across repos

```bash
github-helpers rename-default-branch --from master --to main --dry-run
github-helpers rename-default-branch --org my-company --dry-run
github-helpers rename-default-branch --repo maxgfr/old-repo -y
```

| Flag | Description |
|---|---|
| `--from NAME` | Current branch name (default: master) |
| `--to NAME` | New branch name (default: main) |
| `--repo OWNER/REPO` | Single repo |
| `--user NAME` / `--org NAME` | Target (default: authenticated user) |

#### `secret-audit` — List secrets and env vars

```bash
github-helpers secret-audit
github-helpers secret-audit --org my-company
github-helpers secret-audit --repo maxgfr/my-repo -v
```

| Flag | Description |
|---|---|
| `--user NAME` / `--org NAME` | Target (default: authenticated user) |
| `--repo OWNER/REPO` | Single repo |
| `--limit N` | Max repos to scan |

#### `license-check` — Check and add LICENSE files

```bash
github-helpers license-check
github-helpers license-check --add --template MIT --dry-run
github-helpers license-check --org my-company --add --template Apache-2.0 -y
```

| Flag | Description |
|---|---|
| `--user NAME` / `--org NAME` | Target (default: authenticated user) |
| `--add` | Add LICENSE to repos missing one |
| `--template SPDX` | License template (e.g., MIT, Apache-2.0) |

#### `dependabot-enable` — Enable Dependabot on repos

```bash
github-helpers dependabot-enable --dry-run
github-helpers dependabot-enable --ecosystems npm,github-actions --schedule weekly
github-helpers dependabot-enable --org my-company -y
```

| Flag | Description |
|---|---|
| `--user NAME` / `--org NAME` | Target (default: authenticated user) |
| `--ecosystems LIST` | Comma-separated ecosystems (default: auto-detect) |
| `--schedule FREQ` | `daily`, `weekly`, `monthly` (default: weekly) |

#### `mirror` — Mirror repos to another remote

```bash
github-helpers mirror --repo maxgfr/my-repo --target "git@gitlab.com:maxgfr/{name}.git" --dry-run
github-helpers mirror --user maxgfr --target "git@gitlab.com:maxgfr/{name}.git" -y
```

| Flag | Description |
|---|---|
| `--repo OWNER/REPO` | Single repo |
| `--user NAME` / `--org NAME` | All repos from user/org |
| `--target URL` | Target URL template with `{name}` placeholder |
| `--dir PATH` | Temp directory for bare clones |

#### `release-cleanup` — Delete old releases

```bash
github-helpers release-cleanup --repo maxgfr/my-repo --keep 5 --dry-run
github-helpers release-cleanup --user maxgfr --pre-only --keep 3 -y
```

| Flag | Description |
|---|---|
| `--repo OWNER/REPO` | Single repo |
| `--user NAME` / `--org NAME` | All repos |
| `--keep N` | Releases to keep (default: 5) |
| `--pre-only` | Only delete pre-releases |

---

### Common flags

All commands support these flags:

| Flag | Description |
|---|---|
| `--no-color` | Disable colored output (also respects `NO_COLOR` env var) |
| `--dry-run` | Preview changes without applying |
| `-y, --yes` | Skip confirmation prompt |
| `-v, --verbose` | Detailed output |
| `-h, --help` | Show help |

## Contributing

```bash
git clone https://github.com/maxgfr/github-helpers.git
cd github-helpers
chmod +x script.sh
./script.sh --help
```

This project uses [semantic-release](https://semantic-release.gitbook.io/) — commit messages drive versioning:

- `feat: ...` → minor bump (1.x.0)
- `fix: ...` → patch bump (1.0.x)
- `feat!: ...` or `BREAKING CHANGE:` → major bump (x.0.0)

## License

MIT
