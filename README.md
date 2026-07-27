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
| [`cleanup-forks`](#cleanup-forks--audit-forks-delete-only-the-inactive-ones) | Audit forks; delete only inactive ones |
| [`sync-forks`](#sync-forks--update-your-forks-from-their-upstream) | Update your forks from their upstream |
| [`cleanup-branches`](#cleanup-branches--delete-merged-or-stale-branches) | Delete merged/stale remote branches |
| [`archive-repos`](#archive-repos--archive-inactive-repos) | Batch archive inactive repos |
| [`release-cleanup`](#release-cleanup--delete-old-releases) | Delete old releases, keep N latest |
| [`pr-cleanup`](#pr-cleanup--find-and-close-abandoned-prs) | Close abandoned pull requests |
| [`cleanup-packages`](#cleanup-packages--delete-old-package-versions) | Delete old GitHub Package versions |
| [`stale-issues`](#stale-issues--find-and-close-stale-issues) | Find/close stale issues and PRs |
| [`cache-cleanup`](#cache-cleanup--purge-github-actions-caches) | Purge Actions caches (10 GB/repo quota) |
| [`artifact-cleanup`](#artifact-cleanup--delete-github-actions-artifacts) | Delete Actions artifacts |
| [`run-cleanup`](#run-cleanup--delete-old-workflow-runs) | Delete old workflow runs and their logs |
| [`gist`](#gist--list-export-and-bulk-delete-your-gists) | List, export and bulk-delete gists |
| [`notifications`](#notifications--triage-your-notification-inbox) | Triage and bulk-clear your inbox |
| [`invite-cleanup`](#invite-cleanup--pending-repository-and-org-invitations) | List, accept or decline pending invitations |
| [`repo-audit`](#repo-audit--scan-repos-for-common-issues) | Check for missing LICENSE, README, etc. |
| [`stats`](#stats--github-profile-stats) | Dashboard: repos, stars, languages |
| [`workflow-status`](#workflow-status--ci-workflow-overview) | Latest CI status across repos |
| [`secret-audit`](#secret-audit--list-secrets-and-env-vars) | List Actions secrets & variables |
| [`license-check`](#license-check--check-and-add-license-files) | Check/add LICENSE files |
| [`vulnerability-check`](#vulnerability-check--audit-dependabot-alerts) | Audit Dependabot vulnerability alerts |
| [`branch-protection`](#branch-protection--audit-or-enforce-branch-protection) | Audit/enforce branch protection rules |
| [`webhook-audit`](#webhook-audit--list-webhooks-across-repos) | List webhooks across repos |
| [`collaborator-audit`](#collaborator-audit--audit-outside-collaborators) | Audit outside collaborators and permissions |
| [`activity-report`](#activity-report--generate-activity-summary) | Activity summary for a period |
| [`traffic`](#traffic--snapshot-repo-views-and-clones) | Snapshot views and clones (14-day window) |
| [`org-audit`](#org-audit--org-level-security-and-membership-posture) | Org security and membership posture |
| [`follow-audit`](#follow-audit--who-follows-you-back-and-who-does-not) | Who follows you back, and who does not |
| [`clone-org`](#clone-org--clone-all-repos-from-a-github-org-or-user) | Clone/pull all repos from an org or user |
| [`bulk-topic`](#bulk-topic--add-or-remove-topics-in-batch) | Add/remove topics in batch |
| [`sync-labels`](#sync-labels--sync-issue-labels-from-a-template-repo) | Sync issue labels across repos |
| [`export-stars`](#export-stars--export-starred-repos) | Export stars to JSON/CSV/Markdown |
| [`rename-default-branch`](#rename-default-branch--rename-default-branch-across-repos) | Rename master→main in batch |
| [`dependabot-enable`](#dependabot-enable--enable-dependabot-on-repos) | Enable Dependabot in batch |
| [`mirror`](#mirror--mirror-repos-to-another-remote) | Mirror repos to GitLab/Bitbucket/etc. |
| [`bulk-settings`](#bulk-settings--apply-repo-settings-in-batch) | Apply repo settings in batch |
| [`repo-template`](#repo-template--sync-settings-from-a-template-repo) | Sync settings from a template repo |
| [`bulk-merge`](#bulk-merge--merge-green-dependency-update-prs-in-batch) | Merge green dependency-update PRs |
| [`backup`](#backup--export-repos-and-their-metadata-locally) | Export repos and metadata locally |

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
| `--save-list` | Save the matched list even outside `--dry-run` |
| `--from FILE` | Unstar from a previous dry-run file |

#### `cleanup-forks` — Audit forks, delete only the inactive ones

Alias: `github-helpers forks`. A fork is **kept** when any activity signal fires — every
protection is on by default and has an explicit opt-out.

```bash
# read-only audit, with the reason for every fork
github-helpers forks --report -v

# preview, review the list, then execute
github-helpers cleanup-forks --older-than 180 --dry-run
vim cleanup-forks.txt
github-helpers cleanup-forks --from cleanup-forks.txt
```

| Protection (on by default) | Opt out with |
|---|---|
| An open pull request from the fork | `--ignore-open-prs` |
| Own commits on **any** branch | `--default-branch-only` |
| Stars, watchers, or forks of the fork | `--ignore-popularity` |
| Pushed or created within N days | `--older-than 0` |
| Archived fork | `--include-archived` |
| Upstream gone or private (orphan) | `--include-orphans` |

| Flag | Description |
|---|---|
| `--user NAME` / `--org NAME` | Target (default: authenticated user) |
| `--older-than N` | Only forks untouched for N days (default: 30) |
| `--report` | Audit only — classify everything, never delete |
| `--format table\|json\|csv` | Report format (default: table) |
| `--max-branches N` | Protect, without verifying, above N branches (max 100) |
| `--out FILE` / `--save-list` / `--from FILE` | Review-then-execute loop |
| `--no-verify` | With `--from`, skip re-checking protections (dangerous) |
| `--limit N` | Max forks to examine (default: 1000) |

Deleting a fork permanently closes any pull request opened from it, so open PRs protect a
fork by default. Anything that cannot be fully resolved is reported as `SKIP` and never
deleted. Orphans need a second confirmation because their divergence cannot be verified.

Deletion needs the `delete_repo` scope: `gh auth refresh -h github.com -s delete_repo`.

#### `sync-forks` — Update your forks from their upstream

```bash
github-helpers sync-forks --dry-run
github-helpers sync-forks
github-helpers sync-forks --repo me/my-fork --branch main
```

| Flag | Description |
|---|---|
| `--user NAME` / `--org NAME` | Target (default: authenticated user) |
| `--repo OWNER/NAME` | Sync a single fork |
| `--branch NAME` | Branch to sync (default: each fork's default branch) |
| `--limit N` | Max forks to examine (default: 1000) |

Reports `SYNCED` / `UP-TO-DATE` / `CONFLICT` / `SKIPPED` per fork. No confirmation prompt:
`merge-upstream` only fast-forwards or merges **from** the upstream, so it never discards
your work. Archived forks and orphans are skipped.

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

#### `pr-cleanup` — Find and close abandoned PRs

Find and optionally close pull requests with no activity in N days.

```bash
github-helpers pr-cleanup --repo maxgfr/my-repo --days 60
github-helpers pr-cleanup --org my-company --draft-only --days 30
github-helpers pr-cleanup --repo maxgfr/my-repo --close --delete-branch --dry-run
```

| Flag | Description |
|---|---|
| `--repo OWNER/REPO` | Single repo |
| `--user NAME` / `--org NAME` | Target (default: authenticated user) |
| `--days N` | Days without activity (default: 90) |
| `--draft-only` | Only target draft PRs |
| `--close` | Close abandoned PRs |
| `--comment TEXT` | Comment before closing |
| `--delete-branch` | Delete head branch after closing |

#### `cleanup-packages` — Delete old package versions

Delete old GitHub Package versions, keeping the N most recent.

```bash
github-helpers cleanup-packages --type container --keep 3 --dry-run
github-helpers cleanup-packages --org my-company --type npm --keep 10
github-helpers cleanup-packages --type container --package myapp --keep 1
```

| Flag | Description |
|---|---|
| `--user NAME` / `--org NAME` | Target (default: authenticated user) |
| `--type TYPE` | Package type: npm, maven, rubygems, docker, nuget, container (required) |
| `--package NAME` | Specific package name (default: all) |
| `--keep N` | Versions to keep per package (default: 5) |

#### `stale-issues` — Find and close stale issues

Find and optionally close issues and PRs with no activity in N days.

```bash
github-helpers stale-issues --repo maxgfr/my-repo --days 180
github-helpers stale-issues --org my-company --type pr --days 60
github-helpers stale-issues --repo maxgfr/my-repo --close --comment "Closing as stale" --dry-run
```

| Flag | Description |
|---|---|
| `--repo OWNER/REPO` | Single repo |
| `--user NAME` / `--org NAME` | Target (default: authenticated user) |
| `--days N` | Days without activity (default: 90) |
| `--type TYPE` | Filter: `issue`, `pr`, `all` (default: all) |
| `--label LABEL` | Filter by label |
| `--close` | Close stale issues/PRs |
| `--comment TEXT` | Comment before closing |

---

#### `cache-cleanup` — Purge GitHub Actions caches

Each repository has a 10 GB Actions cache quota. Reports the bytes reclaimed.

```bash
github-helpers cache-cleanup --dry-run
github-helpers cache-cleanup --older-than 30 -y
github-helpers cache-cleanup --repo me/proj --keep 5
github-helpers cache-cleanup --org my-company --larger-than 500MB --dry-run
```

| Flag | Description |
|---|---|
| `--older-than N` | Caches not accessed for N days |
| `--key PATTERN` | Cache key matches this regex |
| `--ref REF` | Only caches for this ref |
| `--larger-than SIZE` | `100MB`, `1.5GiB`, `500K`… |
| `--keep N` | Keep the N most recently accessed per repo |
| `--user` / `--org` / `--repo` / `--limit` | Targeting (`--limit` defaults to 200 repos) |

#### `artifact-cleanup` — Delete GitHub Actions artifacts

```bash
github-helpers artifact-cleanup --dry-run
github-helpers artifact-cleanup --older-than 14 -y
github-helpers artifact-cleanup --repo me/proj --larger-than 200MB
```

| Flag | Description |
|---|---|
| `--older-than N` | Artifacts created more than N days ago |
| `--name PATTERN` | Artifact name matches this regex |
| `--branch NAME` | Only artifacts from runs on this branch |
| `--larger-than SIZE` | `100MB`, `1.5GiB`… |
| `--expired` | Only already-expired artifacts |

Expired artifacts no longer count against billed storage, so deleting them reclaims
nothing. They are excluded by default; `--expired` selects only them, for tidiness.

#### `run-cleanup` — Delete old workflow runs

```bash
github-helpers run-cleanup --older-than 90 --dry-run
github-helpers run-cleanup --keep 10 -y
github-helpers run-cleanup --conclusion failure --older-than 30
github-helpers run-cleanup --repo me/proj --workflow ci.yml --keep 5
```

| Flag | Description |
|---|---|
| `--older-than N` | Runs created more than N days ago |
| `--keep N` | Keep the N most recent runs **of each workflow** |
| `--conclusion C` | `success`, `failure`, `cancelled`, `skipped`… |
| `--branch NAME` / `--workflow NAME` | Narrow further |

`--keep` is per workflow, not per repo: a noisy workflow would otherwise wipe out the
history of a rarely-run one. Deleting a run also deletes **its logs and artifacts** — to
reclaim storage while keeping the history, use `artifact-cleanup`. Queued and in-progress
runs are never deleted. At least one of `--older-than`, `--keep` or `--conclusion` is
required.

#### `gist` — List, export and bulk-delete your gists

Alias: `github-helpers gists`.

```bash
github-helpers gist
github-helpers gist --format csv --out gists.csv
github-helpers gist --empty --no-description --delete --dry-run
github-helpers gist --from gist-delete.txt
```

| Flag | Description |
|---|---|
| `--public` / `--secret` | Filter by visibility |
| `--older-than N` | Created more than N days ago |
| `--untouched N` | Not updated in N days |
| `--empty` | All files empty or whitespace-only |
| `--no-description` | No description |
| `--match PATTERN` | Regex on the description or any filename |
| `--starred` | Operate on gists you starred (read-only) |
| `--delete` | Delete the matches (requires at least one filter) |
| `--format text\|json\|csv\|md`, `--out FILE` | Export |
| `--dry-run` / `--save-list` / `--from FILE` | Review-then-execute loop |

Filters are **ANDed**, unlike `unstar`'s default OR — you are building a deletion set, and
an OR would be a trap. `--empty` reads file sizes from the listing for free and only
fetches the content of gists whose largest file is under 64 bytes. The generated list is
annotated, because a bare 32-hex gist id tells a human nothing.

#### `notifications` — Triage your notification inbox

Alias: `github-helpers notifs`.

```bash
# clear a week of CI noise
github-helpers notifications --reason ci_activity --older-than 7 --mark-read --dry-run
github-helpers notifications --reason ci_activity --older-than 7 --mark-read -y

# permanently mute every thread in one repo
github-helpers notifications --repo owner/repo --all --unsubscribe --mark-read
```

| Flag | Description |
|---|---|
| `--repo OWNER/NAME` | Only this repository |
| `--reason REASON` | `ci_activity`, `mention`, `review_requested`, `security_alert`… |
| `--type TYPE` | `Issue`, `PullRequest`, `Release`, `Discussion`, `CheckSuite`… |
| `--older-than N` | Not updated in the last N days |
| `--unread` / `--all` | Unread only (default), or include read |
| `--mark-read` | Mark the matches as read |
| `--unsubscribe` | Mute the matched threads permanently |
| `--format text\|json\|csv\|md` | Export |

`gh` does not request the `notifications` scope by default:
`gh auth refresh -h github.com -s notifications`.

`--unsubscribe` sets the thread to *ignored* rather than just dropping the subscription,
because a plain unsubscribe resubscribes you on the next comment.

#### `invite-cleanup` — Pending repository and org invitations

```bash
github-helpers invite-cleanup
github-helpers invite-cleanup --accept --repo friend/project
github-helpers invite-cleanup --outgoing --org my-company --decline --older-than 60
```

| Flag | Description |
|---|---|
| `--incoming` / `--outgoing` | Invitations to you (default), or ones you sent |
| `--repo OWNER/NAME` / `--org NAME` | Restrict the scope |
| `--older-than N` | Only invitations older than N days |
| `--accept` / `--decline` | Never implicit; listing is the default |

`--outgoing` requires `--repo` or `--org`: GraphQL exposes no outgoing-invitation
connection, so a whole-account scan would cost one request per repository, while `--org`
answers in one. There is no REST endpoint to **decline** an org invitation — those are
reported with a link and counted as `Manual`.

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

#### `vulnerability-check` — Audit Dependabot alerts

Scan repos for open Dependabot vulnerability alerts, grouped by severity.

```bash
github-helpers vulnerability-check
github-helpers vulnerability-check --org my-company --severity critical
github-helpers vulnerability-check --repo maxgfr/my-repo -v
```

| Flag | Description |
|---|---|
| `--repo OWNER/REPO` | Single repo |
| `--user NAME` / `--org NAME` | Target (default: authenticated user) |
| `--severity LEVEL` | Filter: critical, high, medium, low |
| `--limit N` | Max repos to scan |

#### `branch-protection` — Audit or enforce branch protection

Check which repos lack branch protection on their default branch, and optionally enforce rules.

```bash
github-helpers branch-protection
github-helpers branch-protection --org my-company
github-helpers branch-protection --enforce --require-reviews 2 --dry-run
github-helpers branch-protection --repo maxgfr/my-repo --enforce -y
```

| Flag | Description |
|---|---|
| `--repo OWNER/REPO` | Single repo |
| `--user NAME` / `--org NAME` | Target (default: authenticated user) |
| `--enforce` | Apply protection rules (default: audit only) |
| `--require-reviews N` | Required approving reviews (default: 1) |
| `--require-status-checks` | Require status checks to pass |
| `--allow-force-push` | Allow force push (default: disallow) |

#### `webhook-audit` — List webhooks across repos

List all configured webhooks with their URL, events, and status.

```bash
github-helpers webhook-audit
github-helpers webhook-audit --org my-company -v
github-helpers webhook-audit --repo maxgfr/my-repo
```

| Flag | Description |
|---|---|
| `--repo OWNER/REPO` | Single repo |
| `--user NAME` / `--org NAME` | Target (default: authenticated user) |
| `--limit N` | Max repos to scan |

#### `collaborator-audit` — Audit outside collaborators

List outside collaborators and their permission levels across repos.

```bash
github-helpers collaborator-audit --org my-company
github-helpers collaborator-audit --org my-company --permission admin
github-helpers collaborator-audit --user maxgfr
```

| Flag | Description |
|---|---|
| `--org NAME` / `--user NAME` | Target (required) |
| `--permission LEVEL` | Filter: admin, write, read |
| `--limit N` | Max repos to scan |

#### `activity-report` — Generate activity summary

Generate a summary of PRs, issues, and repo activity for a given period.

```bash
github-helpers activity-report
github-helpers activity-report --org my-company --since 2025-01-01
github-helpers activity-report --since 2025-06-01 --until 2025-06-30 --format json
github-helpers activity-report --user octocat --format csv
```

| Flag | Description |
|---|---|
| `--user NAME` / `--org NAME` | Target (default: authenticated user) |
| `--since DATE` | Start date YYYY-MM-DD (default: 30 days ago) |
| `--until DATE` | End date YYYY-MM-DD (default: today) |
| `--format FORMAT` | `text`, `json`, `csv` (default: text) |

---

#### `traffic` — Snapshot repo views and clones

GitHub only keeps **14 days** of traffic data, so the point is to build your own history.

```bash
github-helpers traffic
github-helpers traffic --sort clones --top 10
github-helpers traffic --repo me/proj --paths --referrers

# cron this: appends only rows the file does not already have
github-helpers traffic --format csv --out traffic.csv --append
```

| Flag | Description |
|---|---|
| `--per day\|week` | Granularity (default: day) |
| `--sort views\|clones` | Sort the summary |
| `--top N` | Only the top N repos |
| `--paths` / `--referrers` | Most visited paths, top referring sites |
| `--format text\|json\|csv\|md`, `--out FILE` | Export |
| `--append` | Append only new `(date, repo)` rows — idempotent |

These endpoints need push access, so repos you do not own are skipped.

#### `org-audit` — Org-level security and membership posture

```bash
github-helpers org-audit --org my-company
github-helpers org-audit --org my-company --format json | jq .summary
github-helpers org-audit --org my-company --fail-on-issues   # in CI
```

| Check | Reports |
|---|---|
| `2fa_required` | Two-factor enforced organization-wide |
| `2fa_members` | Members with two-factor disabled |
| `owner_count` | Too many owners, or a bus factor of one |
| `outside_collaborators` | How many, with a pointer to `collaborator-audit` |
| `pending_invitations` | Invitations still outstanding after 30 days |
| `default_repo_permission` | Base permission granted on every new repo |
| `member_repo_creation` | Whether members can create public repos |
| `teams` | Access managed through teams rather than per person |

| Exit code | With `--fail-on-issues` |
|---|---|
| `0` | No problems |
| `1` | Fatal error (missing `--org`, org not found) |
| `2` | At least one FAIL |
| `4` | No FAIL, but a check could not run (SKIP) |
| `3` | No FAIL or SKIP, at least one WARN |

SKIP outranks WARN on purpose: an incomplete audit is worse than a known warning, because
you cannot know what the check that did not run would have found.

This is org-level only and never iterates repositories — that is the boundary with
`collaborator-audit`. Several endpoints are owner-only:
`gh auth refresh -h github.com -s read:org,admin:org`.

#### `follow-audit` — Who follows you back, and who does not

Alias: `github-helpers follow`. Read-only by default.

```bash
github-helpers follow-audit
github-helpers follow-audit --not-followed-by-me
github-helpers follow-audit --format csv --out follows.csv
github-helpers follow-audit --not-following-back --exclude keep.txt --unfollow --dry-run
```

| Flag | Description |
|---|---|
| `--not-following-back` | You follow them, they do not follow you (default view) |
| `--not-followed-by-me` | They follow you, you do not follow back |
| `--mutuals` | Mutual follows |
| `--exclude FILE` | Logins never to unfollow, one per line |
| `--inactive N` | No push to a public repo of theirs in N days |
| `--unfollow` | Unfollow (only with `--not-following-back`) |
| `--format text\|json\|csv\|md`, `--out FILE` | Export |

`--inactive` measures the last push to a **public** repository they own. Someone working
only in private repos will look inactive; it is a hint, not proof.

`--exclude` fails loudly if the file is missing — a silently-empty whitelist is the
disaster case here. Unfollowing goes through the dry-run → edit → `--from` loop so a human
reads every login first, and needs the `user:follow` scope.

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

#### `bulk-settings` — Apply repo settings in batch

Enable or disable repo features in bulk: wiki, issues, projects, discussions, auto-merge, delete-branch-on-merge.

```bash
github-helpers bulk-settings --disable-wiki --language TypeScript --dry-run
github-helpers bulk-settings --enable-delete-branch --enable-auto-merge --org my-company
github-helpers bulk-settings --disable-projects --disable-wiki --topic archived --dry-run
```

| Flag | Description |
|---|---|
| `--enable-wiki` / `--disable-wiki` | Toggle wiki |
| `--enable-issues` / `--disable-issues` | Toggle issues |
| `--enable-projects` / `--disable-projects` | Toggle projects |
| `--enable-discussions` / `--disable-discussions` | Toggle discussions |
| `--enable-auto-merge` / `--disable-auto-merge` | Toggle auto-merge |
| `--enable-delete-branch` / `--disable-delete-branch` | Toggle delete branch on merge |
| `--user NAME` / `--org NAME` | Target (default: authenticated user) |
| `--language LANG` | Filter by language |
| `--topic TOPIC` | Filter by topic |
| `--pattern PATTERN` | Filter by repo name (grep regex) |

#### `repo-template` — Sync settings from a template repo

Copy settings, labels, and/or branch protection rules from a template repo to other repos.

```bash
github-helpers repo-template --from maxgfr/template --sync-labels --dry-run
github-helpers repo-template --from maxgfr/template --all --org my-company
github-helpers repo-template --from maxgfr/template --sync-settings --topic typescript
```

| Flag | Description |
|---|---|
| `--from OWNER/REPO` | Template repo (required) |
| `--user NAME` / `--org NAME` | Target (default: authenticated user) |
| `--sync-settings` | Sync repo settings |
| `--sync-labels` | Sync issue labels |
| `--sync-protection` | Sync branch protection rules |
| `--all` | Sync everything |
| `--language LANG` | Filter target repos by language |
| `--topic TOPIC` | Filter target repos by topic |

---

#### `bulk-merge` — Merge green dependency-update PRs in batch

```bash
github-helpers bulk-merge --dry-run
github-helpers bulk-merge --patch-only --delete-branch -y
github-helpers bulk-merge --author app/renovate --minor-only --dry-run
```

| Flag | Description |
|---|---|
| `--author LOGIN` | PR author (default: `app/dependabot`) |
| `--label NAME` / `--title-match REGEX` | Narrow the selection |
| `--patch-only` / `--minor-only` | Filter by the semver bump in the title |
| `--max N` | Max PRs merged per repo (default: 10) |
| `--strategy squash\|merge\|rebase` | Merge strategy (default: squash) |
| `--delete-branch` | Delete the head branch after merging |
| `--no-checks` | Merge even when checks have not passed (dangerous) |
| `--allow-unstable` | Allow `UNSTABLE` (non-required checks failing) |

**This writes to default branches.** Checks must pass unless you pass `--no-checks`,
drafts are always skipped, and only `mergeStateStatus == CLEAN` is merged — `DIRTY`,
`BLOCKED`, `BEHIND` and `UNKNOWN` never are. Every PR is listed before the single
confirmation. Titles whose bump cannot be parsed count as `unknown`, which both
`--patch-only` and `--minor-only` exclude.

#### `backup` — Export repos and their metadata locally

```bash
github-helpers backup --repo me/proj --out /tmp/bk
github-helpers backup --gists
github-helpers backup --org my-company --mirror --out /backups/org
github-helpers backup --verify /tmp/bk
```

| Flag | Description |
|---|---|
| `--out DIR` | Destination (default: `github-backup-YYYY-MM-DD`) |
| `--no-git` / `--no-metadata` | Take only one half |
| `--mirror` | Keep a bare mirror instead of a bundle |
| `--gists` | Also back up your gists |
| `--assets` | Also download release binaries (can be large) |
| `--include-forks` | Include forks (excluded by default) |
| `--resume` | Skip repos already recorded as done |
| `--verify DIR` | Check an existing backup against its manifest |

```
DIR/manifest.json                 counts, timestamps, sha256 per file
DIR/.repos.jsonl                  append-only journal, drives --resume
DIR/<owner>/<repo>/repo.bundle    git history (or repo.git/ with --mirror)
DIR/<owner>/<repo>/issues.json    issues only, pull requests stripped out
DIR/<owner>/<repo>/issue_comments.json, review_comments.json, pulls.json, …
```

`issues.json` holds the opening message but **not** the thread — the conversation lives in
`issue_comments.json` and `review_comments.json`, the biggest omission in a naive backup.

Every file is written as `.part` and renamed on success, so the presence of a final file
proves the write completed; that is what makes `--resume` safe. `--verify` re-checks every
sha256 and exits `2` on any missing or mismatched file.

**Not included:** Git LFS objects, release binaries (unless `--assets`), Actions logs,
Projects, Discussions and Packages.

### Common flags

All commands support these flags:

| Flag | Description |
|---|---|
| `--no-color` | Disable colored output (also respects `NO_COLOR` env var) |
| `--dry-run` | Preview changes without applying |
| `-y, --yes` | Skip confirmation prompt |
| `-v, --verbose` | Detailed output |
| `-h, --help` | Show help |

## License

MIT
