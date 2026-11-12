---
name: github-helpers
description: Drive the github-helpers CLI to maintain a GitHub account or organization in bulk — download or back up every repo (public and private) locally, clean up stars, forks, branches, releases, packages, caches, artifacts, workflow runs, gists, notifications and invitations, audit repos, CI, secrets, licenses, vulnerabilities, branch protection, webhooks, collaborators and orgs, and apply bulk changes (topics, labels, settings, default branch, Dependabot, mirroring, merging dependency PRs). Use when the user wants to do something across many GitHub repos at once, or asks for a GitHub cleanup, audit, backup, or a local copy of their repos in case GitHub goes down.
---

# github-helpers

`github-helpers` is a single bash CLI (wrapping `gh` and `jq`) with 44 subcommands
for bulk GitHub maintenance. This skill tells you how to run it safely.

## Setup

1. Check it is installed: `command -v github-helpers`. If not, install it:
   - macOS / Linuxbrew: `brew install maxgfr/tap/github-helpers`
   - otherwise:
     ```bash
     curl -fsSL https://raw.githubusercontent.com/maxgfr/github-helpers/main/script.sh -o /usr/local/bin/github-helpers
     chmod +x /usr/local/bin/github-helpers
     ```
2. It needs `gh` (authenticated: `gh auth status`), `jq`, `git` and bash 4+.
   If `gh` is not logged in, ask the user to run `gh auth login` themselves —
   it is interactive. If the error says the rate limit is exhausted, the login
   is fine: do not ask for a re-login, wait for the reset time it prints.
   `github-helpers status` shows every quota and costs nothing to run.
3. Some commands need extra token scopes and print a hint on their first 403,
   e.g. `gh auth refresh -h github.com -s delete_repo`. Relay the hint to the
   user; do not run `gh auth refresh` without asking, it opens a browser flow.

## Rules

- **Never guess flags.** Run `github-helpers <command> --help` first; every
  command documents its flags, defaults and examples there.
- **Destructive commands: dry-run, show, ask, then execute.** Anything that
  deletes, closes, archives, unstars, unfollows, merges or changes settings
  must first run with `--dry-run`. Show the user what would change (count and
  a sample), get an explicit yes, and only then run it for real. Pass `-y`
  only after that yes — it skips the CLI's own confirmation prompt.
- **Prefer the review loop** where a command offers it (`unstar`,
  `cleanup-forks`, `cleanup-branches`, `packages`): `--dry-run` writes a list
  file, the user can edit it, then `--from FILE` executes exactly that list.
- **Machine-readable output**: commands that take `--format json|csv|md` (not
  all do — check `--help`) write the payload to stdout and progress to stderr,
  so `github-helpers <cmd> --format json 2>/dev/null | jq …` is safe to parse.
- **Partial failures are normal.** A 403/404 on one repo is skipped and
  summarised at the end ("Skipped: N"), not fatal. `backup` and `download`
  exit `2` when some repos failed; report which ones.
- **Targeting** is the same everywhere: `--org NAME` / `--user NAME`, a single
  `--repo OWNER/NAME`, and the filters `--archived`, `--not-archived`, `--fork`,
  `--source`, `--language`, `--topic`, `--visibility`, `--limit` where they apply.
- Long sweeps (hundreds of repos) take minutes; run them in the background or
  warn the user rather than letting a tool call time out.

## Commands

Cleanup & maintenance:

| Command | What it does |
|---|---|
| `unstar` | Filter stars (archived, last commit/activity date) and bulk-unstar |
| `cleanup-forks` (`forks`) | Audit forks; delete only those with zero activity |
| `sync-forks` | Update forks from their upstream |
| `cleanup-branches` | Delete merged, squash-merged or stale branches |
| `archive-repos` | Archive inactive repos |
| `release-cleanup` | Delete old releases, keep the N latest |
| `pr-cleanup` | Close abandoned pull requests |
| `cleanup-packages` | Delete old package versions |
| `packages` (`pkgs`) | List packages, flag orphaned/renamed ones, delete whole ones |
| `stale-issues` | Find and close stale issues/PRs |
| `cache-cleanup` | Purge Actions caches |
| `artifact-cleanup` | Delete Actions artifacts |
| `run-cleanup` | Delete old workflow runs and their logs |
| `gist` (`gists`) | List, export and bulk-delete gists |
| `notifications` (`notifs`) | Triage and bulk-clear the notification inbox |
| `invite-cleanup` | List, accept or decline pending invitations |

Audit & visibility (read-only):

| Command | What it does |
|---|---|
| `repo-audit` (`audit`) | Missing LICENSE, README, description, topics |
| `stats` | Profile/org dashboard: repos, stars, languages |
| `workflow-status` (`ci`) | Latest CI run per repo |
| `secret-audit` | Actions secrets and variables across repos |
| `license-check` | Check (and optionally add) LICENSE files |
| `vulnerability-check` | Dependabot alerts across repos |
| `branch-protection` | Audit or enforce branch protection |
| `webhook-audit` | Webhooks across repos |
| `collaborator-audit` | Outside collaborators and permissions |
| `org-audit` | Org security and membership posture |
| `follow-audit` (`follow`) | Who follows back, and who does not |
| `activity-report` | Activity summary for a period |
| `traffic` | Views and clones (14-day window) |
| `inbox` (`recap`) | What is waiting on the user: replies, reviews, new issues |
| `branches` (`branch-status`) | Open branches, ahead/behind the default branch |
| `status` | Login, token scopes and API rate limits; free, works at quota 0 |

Bulk operations:

| Command | What it does |
|---|---|
| `download` (`dl`) | Local copy of every repo the user can access, refreshed on rerun |
| `backup` | Dated snapshot of repos plus issues, PRs, releases metadata |
| `clone-org` | Working-copy clones of one org or user |
| `mirror` | Push mirrors to another remote (GitLab, Bitbucket…) |
| `bulk-topic` | Add/remove topics |
| `sync-labels` | Sync issue labels from a template repo |
| `export-stars` | Export stars to JSON/CSV/Markdown |
| `rename-default-branch` | Rename the default branch across repos |
| `dependabot-enable` | Enable Dependabot |
| `bulk-settings` | Apply repo settings in batch |
| `repo-template` | Sync settings from a template repo |
| `bulk-merge` | Merge green dependency-update PRs |

## Recipes

Keep a local copy of everything, in case GitHub goes down:

```bash
github-helpers download --dir ~/github-archive --dry-run   # count + size estimate
github-helpers download --dir ~/github-archive -y          # clone; rerun to refresh
```

`download` covers the user's own repos, every org they belong to and the repos
they collaborate on, public and private, as bare mirrors (all branches, tags
and PR refs) in `DIR/<owner>/<repo>.git`. `--org NAME` / `--user NAME` narrow it,
`--checkout` gives working copies, `--wikis` adds wikis. Reruns only fetch.
Nothing local is ever deleted; repos gone from GitHub are listed at the end.
For issues, PRs and release metadata as well, use `backup`.

Restore a repo from the copy: `git clone ~/github-archive/<owner>/<repo>.git`.

Clean up stars, reviewing before acting:

```bash
github-helpers unstar --archived --dry-run   # writes unstar-repos.txt
# show the list to the user, let them edit it, then:
github-helpers unstar --from unstar-repos.txt
```

Get data back as JSON (only commands whose `--help` lists `--format`, e.g.
`inbox`, `branches`, `activity-report`, `export-stars`, `follow-audit`, `gist`):

```bash
github-helpers branches --format json 2>/dev/null | jq '.[0]'
```

What needs the user's attention today: `github-helpers inbox`.
