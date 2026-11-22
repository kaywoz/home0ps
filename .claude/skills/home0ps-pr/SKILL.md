---
name: home0ps-pr
description: PR routine for kaywoz/home0ps. Use before pushing to an existing PR branch, before writing any PR description, for the project board check that ends every PR, and after a PR is merged. Holds the board rules and the tested commands for board reads and writes.
---

# home0ps PR routine

Steps in order. CLAUDE.md §4 and §5 still apply in full; this skill adds the
commands. Commands marked **tested** have run successfully for kaywoz.

## 1. Before every push to an existing PR branch

Gate the push on the PR being open, in the same command (MISTAKES.md,
"pushed to a merged PR", three times):

```bash
# session checkout (shell)
[ "$(gh pr view N -R kaywoz/home0ps --json state --jq .state)" = OPEN ] && git push origin BRANCH
```

Where `gh` can't read PRs (cloud sessions), check the PR's `state` with the
GitHub MCP `pull_request_read` (`method: get`) first and push only on `open`.
Not open → new branch from `origin/main`, new PR.

After every commit: `git show --stat HEAD` matches what the PR description
claims; `git status` clean before switching branches.

## 2. PR description

Headings in this order (CLAUDE.md §5). Generic wording only, no device,
host or account names (§4):

```markdown
## What changed
## Source of truth
## Secrets / env
## Assumptions
## Flagged
## Project board
## Rollback
```

Write "Project board" last, after step 3.

## 3. Board check (last step of every PR)

### Rules (moved from CLAUDE.md §6 unchanged)

kaywoz tracks work on the user-owned GitHub Project
`https://github.com/users/kaywoz/projects/4` (items are mostly issues in
this repo). Status options: `backlog`, `selected`, `done`, `wont do`.

- **The board check is the last step of every PR in this repo**, after the
  work is committed, pushed and the PR description written. List the open
  items (`backlog`, `selected`, no status) with
  `gh project item-list 4 --owner kaywoz` and compare them with what the PR
  actually does. Say whether one matches. Link it only after kaywoz
  confirms the match: then add `Closes kaywoz/home0ps#N` to the PR body and
  set the item to `selected`.
- Every PR description ends (before rollback) with a **"Project board"**
  section: the matched item number, or "No matching item".
- **Closing**: the PR body carries `Closes kaywoz/home0ps#N`, so the issue
  closes when kaywoz merges, and the board's built-in "Item closed" workflow
  sets it to `done`. Don't set `done` by hand for issues. Never close an
  item before its PR is merged. Draft items (no issue) are set to `done` by
  hand after merge.
- **No match**: every task is tracked as an issue. Open one (generic title,
  no device names), add it to the board, set it to `selected`, and link it
  from the PR(s): `Closes kaywoz/home0ps#N` on the PR that finishes the task,
  `Part of kaywoz/home0ps#N` on earlier ones. No need to ask first.
- Status has two options named `done`; use option id `98236657` (the one
  in use) until the duplicate is removed.
- The board is public and some item titles name devices. Refer to items by
  number only in branches, commits and PRs (§4) — never copy titles.
- **Reads** use the normal `gh` login (`gh project item-list|view|field-list`).
  **Writes** go through `.claude/gh-project.sh <gh project args>`, which uses
  a classic token (scopes `project`, `read:org`, `read:discussion`) from the
  macOS Keychain service `gh-project-token`. Fine-grained tokens can't write
  to user-owned projects. Never print the token or pass it on the command
  line.

### Which session can do what

- **Mac session** (kaywoz's checkout): reads with `gh project`, writes with
  `.claude/gh-project.sh`. Run the commands below yourself.
- **Cloud session**: `gh project` doesn't work and the Keychain isn't there.
  Read open issues with
  `gh api -X GET search/issues -f q='repo:kaywoz/home0ps is:issue is:open' -f per_page=100 --jq '.items[] | "#\(.number) \(.title)"'`
  (issues only, not draft items or other repos; say so in the PR). Open
  issues with the GitHub MCP. Hand kaywoz the write commands below as
  copy-paste blocks labelled `# admin Mac, home0ps checkout (shell)`.

### Read the open items (Mac)

```bash
gh project item-list 4 --owner kaywoz --limit 300 --format json
```

Read `content.repository`, `content.number` and `status` from the JSON.
Items come from several repos: always refer to them as `owner/repo#N`, and
pass `-R owner/repo` to every `gh issue` write. Check the title matches
before closing anything (MISTAKES.md, issue closed in the wrong repo).

### Add an issue to the board (**tested**)

```bash
# admin Mac, home0ps checkout (shell)
.claude/gh-project.sh item-add 4 --owner kaywoz --url https://github.com/kaywoz/home0ps/issues/N
```

Expect: `Added item`.

### Set an item's Status (**tested** with `selected`)

Replace `N` with the issue number and `selected` with the status name
(`backlog`, `selected`, `wont do`). Draft items have no number: this command
doesn't cover them (untested; take the item `id` from the item-list JSON and
use option id `98236657` for `done`).

```bash
# admin Mac, home0ps checkout (shell)
P=$(gh project view 4 --owner kaywoz --format json --jq .id) &&
I=$(gh project item-list 4 --owner kaywoz --format json --limit 300 \
  --jq '.items[] | select(.content.repository=="kaywoz/home0ps" and .content.number==N) | .id') &&
F=$(gh project field-list 4 --owner kaywoz --format json --jq '.fields[] | select(.name=="Status") | .id') &&
O=$(gh project field-list 4 --owner kaywoz --format json \
  --jq '.fields[] | select(.name=="Status") | .options[] | select(.name=="selected") | .id') &&
[ -n "$P" ] && [ -n "$I" ] && [ -n "$F" ] && [ -n "$O" ] &&
.claude/gh-project.sh item-edit --project-id "$P" --id "$I" --field-id "$F" --single-select-option-id "$O" &&
echo "set to selected"
```

Expect: `set to selected`. No output means a lookup came back empty.

## 4. After merge

- Stop watching the PR and cancel any scheduled check-in for it.
- Confirm every commit reached `main`:
  `git fetch origin main && git merge-base --is-ancestor HEAD origin/main && echo "all on main"`.
- Draft items (no issue): set to `done` by hand (option id `98236657`).
  Issues: nothing, the merge closes them.
